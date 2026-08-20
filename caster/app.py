#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
yun caster —— 播放服务

职责：
  1. /probe      探测媒体的容器/编码/音轨/字幕，决定「直连」还是「转码」
  2. /hls/*      按需生成 HLS：每个分片一个独立 ffmpeg，可即时拖动、可缓存、可续传
  3. /sub        内嵌字幕与外挂字幕统一转成 WebVTT
  4. /auth/*     给 nginx 的 auth_request 用：校验播放票据 / AList 登录态
  5. 后台线程    按保留时长与磁盘水位清理下载目录，按 LRU 清理分片缓存

只依赖 Python 标准库 + ffmpeg / ffprobe。
"""

import base64
import hashlib
import hmac
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ============================== 配置 ==============================


def _env(key, default=''):
    v = os.environ.get(key)
    return default if v is None or v.strip() == '' else v.strip()


def _env_int(key, default):
    try:
        return int(float(_env(key, str(default))))
    except ValueError:
        return default


def _env_float(key, default):
    try:
        return float(_env(key, str(default)))
    except ValueError:
        return default


FFMPEG = _env('FFMPEG_BIN', 'ffmpeg')
FFPROBE = _env('FFPROBE_BIN', 'ffprobe')

MEDIA_ROOT = _env('MEDIA_ROOT', '/media')          # 下载目录（需可写，清理用）
CACHE_DIR = _env('CACHE_DIR', '/cache')
MOUNT = _env('MOUNT_PREFIX', '/downloads')         # 前端看到的路径前缀
ALIST = _env('ALIST_URL', 'http://alist:5244').rstrip('/')
PORT = _env_int('CASTER_PORT', 8000)

SEG = max(2, _env_int('SEG_SECONDS', 6))           # 分片时长
MAX_HEIGHT = _env_int('MAX_HEIGHT', 720)           # 默认转码高度上限
VIDEO_ENCODER = _env('VIDEO_ENCODER', 'libx264')
X264_PRESET = _env('X264_PRESET', 'veryfast')
QUALITY = _env_int('VIDEO_QUALITY', 23)            # libx264 的 CRF，硬件编码器映射到各自的质量参数
AUDIO_BITRATE = _env('AUDIO_BITRATE', '160k')
HWACCEL = _env('HWACCEL', 'none')                  # none / auto / vaapi / qsv / cuda ...
JOBS = max(1, _env_int('TRANSCODE_JOBS', 2))       # 同时运行的 ffmpeg 数
PREWARM = max(0, _env_int('PREWARM_SEGMENTS', 3))  # 预热后续分片数
SEG_TIMEOUT = max(30, _env_int('SEG_TIMEOUT', SEG * 20))

TICKET_TTL = _env_int('TICKET_TTL', 43200)         # 播放票据有效期（秒）
AUTH_ENFORCE = _env('AUTH_ENFORCE', '1') != '0'

RETENTION_HOURS = _env_float('RETENTION_HOURS', 1)  # 0 = 不自动删下载文件
CLEAN_INTERVAL = max(30, _env_int('CLEAN_INTERVAL', 300))
MAX_DISK_PERCENT = _env_int('MAX_DISK_PERCENT', 90)
CACHE_MAX_MB = _env_int('CACHE_MAX_MB', 4096)

HLS_CACHE = os.path.join(CACHE_DIR, 'hls')
VENDOR_HLSJS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'hls.js')

# 浏览器能直接吃下的组合：容器 + 视频编码 + 音频编码
DIRECT_EXT = {'.mp4', '.m4v', '.mov', '.webm'}
DIRECT_VIDEO = {'h264', 'vp8', 'vp9', 'av1'}
DIRECT_AUDIO = {'aac', 'mp3', 'opus', 'vorbis'}
# 能转成 WebVTT 的文本字幕（图形字幕 PGS/VobSub 转不了，直接不展示）
TEXT_SUB_CODECS = {'subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text', 'stl', 'subviewer'}
SIDECAR_SUB_EXT = {'.srt', '.ass', '.ssa', '.vtt'}   # .sub 是图形字幕，转不成 WebVTT，不展示


def log(*a):
    sys.stdout.write('[caster %s] %s\n' % (time.strftime('%H:%M:%S'), ' '.join(str(x) for x in a)))
    sys.stdout.flush()


# ============================== 票据与鉴权 ==============================


def _load_secret():
    """签名密钥：优先取环境变量，否则在缓存目录里生成并持久化。"""
    s = _env('STREAM_SECRET')
    if s:
        return s.encode('utf-8')
    path = os.path.join(CACHE_DIR, '.secret')
    try:
        with open(path, 'rb') as f:
            data = f.read().strip()
        if data:
            return data
    except OSError:
        pass
    data = base64.urlsafe_b64encode(os.urandom(32)).strip(b'=')
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
        os.chmod(path, 0o600)
    except OSError as e:
        log('警告：密钥无法持久化（重启后旧票据失效）:', e)
    return data


SECRET = _load_secret()


def make_ticket(media_path, ttl=None):
    exp = int(time.time()) + (TICKET_TTL if ttl is None else ttl)
    return '%s.%d' % (_sign(media_path, exp), exp)


def _sign(media_path, exp):
    mac = hmac.new(SECRET, ('%s|%d' % (media_path, exp)).encode('utf-8'), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(mac[:18]).decode('ascii').rstrip('=')


def check_ticket(media_path, ticket):
    if not AUTH_ENFORCE:
        return True
    if not ticket or '.' not in ticket:
        return False
    sig, _, exp_s = ticket.rpartition('.')
    try:
        exp = int(exp_s)
    except ValueError:
        return False
    if exp < time.time():
        return False
    return hmac.compare_digest(sig, _sign(media_path, exp))


_token_cache = {}
_token_lock = threading.Lock()


def alist_authorized(authorization):
    """拿前端的 AList token 去问 AList 本人，结果缓存 60 秒。"""
    if not AUTH_ENFORCE:
        return True
    if not authorization:
        return False
    key = hashlib.sha256(authorization.encode('utf-8', 'replace')).hexdigest()
    now = time.time()
    with _token_lock:
        hit = _token_cache.get(key)
        if hit and now - hit[1] < 60:
            return hit[0]
    ok = False
    try:
        req = urllib.request.Request(ALIST + '/api/me', headers={'Authorization': authorization})
        with urllib.request.urlopen(req, timeout=5) as r:
            ok = json.loads(r.read().decode('utf-8', 'replace')).get('code') == 200
    except Exception:
        ok = False
    with _token_lock:
        if len(_token_cache) > 256:
            _token_cache.clear()
        _token_cache[key] = (ok, now)
    return ok


# ============================== 路径 ==============================


class BadPath(Exception):
    pass


_REAL_ROOT = os.path.realpath(MEDIA_ROOT)


def resolve(media_path):
    """把前端路径 /downloads/a/b.mkv 映射到磁盘路径，并挡住 ../ 越界。"""
    if not media_path or not media_path.startswith(MOUNT + '/'):
        raise BadPath('路径必须以 %s/ 开头' % MOUNT)
    rel = media_path[len(MOUNT) + 1:].lstrip('/')
    full = os.path.realpath(os.path.join(_REAL_ROOT, rel))
    if full != _REAL_ROOT and not full.startswith(_REAL_ROOT + os.sep):
        raise BadPath('路径越界')
    if not os.path.isfile(full):
        raise BadPath('文件不存在（可能还没下载出来，或已被清理）')
    return full


def to_media_path(full):
    rel = os.path.relpath(full, _REAL_ROOT).replace(os.sep, '/')
    return MOUNT + '/' + rel


def url_quote_path(p):
    return '/'.join(urllib.parse.quote(seg, safe='') for seg in p.split('/'))


# 记录「最近被播放过」的文件，清理线程会绕开它们
_touched = {}
_touch_lock = threading.Lock()


def touch(media_path):
    with _touch_lock:
        if len(_touched) > 2000:
            _touched.clear()
        _touched[media_path] = time.time()


def touched_at(media_path):
    with _touch_lock:
        return _touched.get(media_path, 0)


# ============================== 探测 ==============================

_probe_cache = {}
_probe_lock = threading.Lock()


def ffprobe(full):
    """探测结果按 (路径, 大小, mtime) 缓存 —— 边下边播时文件在长大，会自动重新探测。"""
    st = os.stat(full)
    key = (full, st.st_size, int(st.st_mtime))
    with _probe_lock:
        hit = _probe_cache.get(key)
    if hit:
        return hit
    cmd = [FFPROBE, '-v', 'quiet', '-print_format', 'json',
           '-show_format', '-show_streams', '-i', full]
    try:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             timeout=60).stdout
        data = json.loads(out.decode('utf-8', 'replace') or '{}')
    except subprocess.TimeoutExpired:
        raise BadPath('探测超时：文件可能还在下载或已损坏')
    except Exception as e:
        raise BadPath('探测失败：%s' % e)
    if not data.get('streams'):
        raise BadPath('这个文件里没找到可播放的音视频流（下载可能还没开始写入）')
    with _probe_lock:
        if len(_probe_cache) > 200:
            _probe_cache.clear()
        _probe_cache[key] = data
    return data


def _lang_title(stream):
    tags = stream.get('tags') or {}
    lang = tags.get('language') or tags.get('LANGUAGE') or ''
    title = tags.get('title') or tags.get('TITLE') or ''
    return lang, title


def _duration(data):
    d = 0.0
    try:
        d = float((data.get('format') or {}).get('duration') or 0)
    except (TypeError, ValueError):
        d = 0.0
    if d <= 0:
        for s in data.get('streams') or []:
            try:
                d = max(d, float(s.get('duration') or 0))
            except (TypeError, ValueError):
                pass
    return d


def sidecar_subs(full):
    """找同目录下同名的外挂字幕，例如 movie.mkv 配 movie.chs.srt。"""
    d = os.path.dirname(full)
    stem = os.path.splitext(os.path.basename(full))[0].lower()
    found = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return found
    for n in names:
        ext = os.path.splitext(n)[1].lower()
        if ext not in SIDECAR_SUB_EXT:
            continue
        base = os.path.splitext(n)[0].lower()
        if base == stem or base.startswith(stem + '.') or base.startswith(stem + '_'):
            found.append(os.path.join(d, n))
    return found


def probe_info(media_path):
    full = resolve(media_path)
    data = ffprobe(full)
    st = os.stat(full)
    ext = os.path.splitext(full)[1].lower()

    video = None
    audios = []
    subs = []
    for s in data.get('streams') or []:
        kind = s.get('codec_type')
        if kind == 'video' and video is None and s.get('codec_name') not in ('mjpeg', 'png', 'bmp'):
            video = s
        elif kind == 'audio':
            lang, title = _lang_title(s)
            audios.append({
                'index': s.get('index'),
                'codec': s.get('codec_name') or '?',
                'channels': s.get('channels') or 0,
                'lang': lang,
                'title': title,
                'default': bool((s.get('disposition') or {}).get('default')),
            })
        elif kind == 'subtitle' and (s.get('codec_name') or '') in TEXT_SUB_CODECS:
            lang, title = _lang_title(s)
            subs.append({'kind': 'embed', 'index': s.get('index'), 'lang': lang, 'title': title})

    if video is None:
        raise BadPath('这个文件没有视频轨')

    vcodec = (video.get('codec_name') or '?').lower()
    acodec = (audios[0]['codec'] if audios else '').lower()
    duration = _duration(data)
    ticket = make_ticket(media_path)

    # 直连判定：容器、视频、音频三者都在浏览器原生支持范围内
    if ext not in DIRECT_EXT:
        can_direct, reason = False, '容器 %s 浏览器不认，需转封装' % ext.lstrip('.')
    elif vcodec not in DIRECT_VIDEO:
        can_direct, reason = False, '视频编码 %s 浏览器普遍不支持，需转码' % vcodec
    elif audios and acodec not in DIRECT_AUDIO:
        can_direct, reason = False, '音频编码 %s 浏览器放不出声，需转码' % acodec
    else:
        can_direct, reason = True, '原文件浏览器可直接播放'

    for i, sub in enumerate(subs):
        sub['url'] = '/stream/sub?' + urllib.parse.urlencode(
            {'p': media_path, 'i': sub['index'], 'pt': ticket})
        sub['label'] = _sub_label(sub, i + 1)
    for f in sidecar_subs(full):
        item = {'kind': 'file', 'path': to_media_path(f), 'lang': '', 'index': -1,
                'title': os.path.basename(f)}
        item['url'] = '/stream/sub?' + urllib.parse.urlencode(
            {'p': media_path, 'f': item['path'], 'pt': ticket})
        item['label'] = os.path.basename(f)
        subs.append(item)

    for i, a in enumerate(audios):
        bits = [a['lang'] or '音轨%d' % (i + 1)]
        if a['title']:
            bits.append(a['title'])
        bits.append('%s %sch' % (a['codec'], a['channels'] or '?'))
        a['label'] = ' · '.join(bits)

    height = int(video.get('height') or 0)
    heights = [h for h in (480, 720, 1080) if h < height] + ([height] if height else [])
    if not heights:
        heights = [MAX_HEIGHT]
    default_height = min(MAX_HEIGHT, height) if height else MAX_HEIGHT
    if default_height not in heights:
        heights.append(default_height)
    heights = sorted(set(heights))

    default_audio = next((a['index'] for a in audios if a['default']), None)
    if default_audio is None and audios:
        default_audio = audios[0]['index']

    touch(media_path)
    return {
        'path': media_path,
        'name': os.path.basename(full),
        'size': st.st_size,
        'mtime': int(st.st_mtime),
        'duration': round(duration, 3),
        'mode': 'direct' if can_direct else 'hls',
        'reason': reason,
        'video': {'codec': vcodec, 'width': int(video.get('width') or 0), 'height': height},
        'audios': audios,
        'subs': subs,
        'heights': heights,
        'default_height': default_height,
        'default_audio': default_audio,
        'direct_url': '/d' + url_quote_path(media_path) + '?pt=' + urllib.parse.quote(ticket),
        'hls_url': _hls_url(media_path, default_audio, default_height, ticket),
        'ticket': ticket,
        'retention_hours': RETENTION_HOURS,
        'seg_seconds': SEG,
    }


def _sub_label(sub, ordinal):
    if sub.get('title') and sub.get('lang'):
        return '%s (%s)' % (sub['title'], sub['lang'])
    return sub.get('title') or sub.get('lang') or ('字幕%d' % ordinal)


def _hls_url(media_path, audio_index, height, ticket):
    q = {'p': media_path, 'h': height, 'pt': ticket}
    if audio_index is not None:
        q['a'] = audio_index
    return '/stream/hls/index.m3u8?' + urllib.parse.urlencode(q)


# ============================== HLS ==============================

_seg_locks = {}
_seg_locks_guard = threading.Lock()
_ff_slots = threading.BoundedSemaphore(JOBS)
# 预热只用「多出来的那一核」：单核机器不预热，免得抢走前台拖进度条要用的算力
PREWARM_WORKERS = max(0, JOBS - 1)
_prewarm_pool = (ThreadPoolExecutor(max_workers=PREWARM_WORKERS, thread_name_prefix='prewarm')
                 if PREWARM_WORKERS else None)
_prewarm_seen = {}
_prewarm_guard = threading.Lock()


def _seg_lock(key):
    with _seg_locks_guard:
        if len(_seg_locks) > 512:
            for k in [k for k in _seg_locks if not _seg_locks[k].locked()]:
                _seg_locks.pop(k, None)
        lock = _seg_locks.get(key)
        if lock is None:
            lock = _seg_locks[key] = threading.Lock()
        return lock


def variant_dir(media_path, full, audio_index, height):
    """把文件大小算进缓存键：边下边播时文件长大就换一套分片，避免拿到半截数据的旧片。
    分片时长与画质也进键，改了设置不会复用对不上的旧分片。"""
    st = os.stat(full)
    raw = '%s|%d|%s|%s|%d|%s|%s' % (media_path, st.st_size, audio_index, height,
                                    SEG, QUALITY, VIDEO_ENCODER)
    key = hashlib.sha1(raw.encode('utf-8')).hexdigest()[:20]
    return os.path.join(HLS_CACHE, key)


def _quality_flags():
    enc = VIDEO_ENCODER
    if enc in ('libx264', 'libx265'):
        return ['-preset', X264_PRESET, '-crf', str(QUALITY)]
    if 'nvenc' in enc:
        return ['-preset', 'p4', '-rc', 'vbr', '-cq', str(QUALITY), '-b:v', '0']
    if 'qsv' in enc or 'vaapi' in enc:
        return ['-global_quality', str(QUALITY)]
    if 'videotoolbox' in enc:
        return ['-q:v', str(QUALITY)]
    return ['-crf', str(QUALITY)]


def segment_cmd(full, start, dur, audio_index, height, out):
    cmd = [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y']
    if HWACCEL and HWACCEL != 'none':
        cmd += ['-hwaccel', HWACCEL]          # 只做解码加速，滤镜/编码仍走通用路径，最稳
    cmd += ['-ss', '%.3f' % start, '-i', full, '-t', '%.3f' % dur]
    cmd += ['-map', '0:v:0']
    if audio_index is not None:
        cmd += ['-map', '0:%d?' % audio_index]
    else:
        cmd += ['-an']
    cmd += ['-sn', '-dn', '-map_metadata', '-1', '-max_muxing_queue_size', '1024']
    cmd += ['-c:v', VIDEO_ENCODER] + _quality_flags()
    # 转 8bit + 限高：顺手把 10bit HEVC 这类浏览器绝对播不了的源拉回可播范围
    # 高度取偶数，否则 yuv420p 会直接报 "height not divisible by 2"
    cmd += ['-pix_fmt', 'yuv420p', '-profile:v', 'high',
            '-vf', "scale=-2:'2*trunc(min(%d,ih)/2)'" % height,
            '-force_key_frames', 'expr:gte(t,n_forced*%d)' % SEG]
    if audio_index is not None:
        cmd += ['-c:a', 'aac', '-b:a', AUDIO_BITRATE, '-ac', '2', '-ar', '48000']
    # -ss 在 -i 之前 + 转码 = 精确定位，输出时间戳从 0 起，再用 output_ts_offset 拨回全局时间轴，
    # 这样每个分片都能独立生成，拖进度条不用等前面的片
    cmd += ['-f', 'mpegts', '-output_ts_offset', '%.3f' % start,
            '-muxdelay', '0', '-muxpreload', '0', out]
    return cmd


def make_segment(media_path, full, index, audio_index, height, duration):
    vdir = variant_dir(media_path, full, audio_index, height)
    out = os.path.join(vdir, 'seg-%06d.ts' % index)
    if os.path.exists(out) and os.path.getsize(out) > 0:
        os.utime(vdir, None)
        return out
    start = index * SEG
    if duration and start >= duration:
        raise BadPath('分片超出时长范围')
    want = min(float(SEG), duration - start) if duration else float(SEG)
    if want <= 0.05:
        raise BadPath('分片超出时长范围')

    with _seg_lock(out):
        if os.path.exists(out) and os.path.getsize(out) > 0:
            return out
        os.makedirs(vdir, exist_ok=True)
        # 临时名带上线程号：万一同一分片被两个线程同时生成，也只是白干一次，不会写坏文件
        part = '%s.%d.part' % (out, threading.get_ident())
        cmd = segment_cmd(full, start, want, audio_index, height, part)
        with _ff_slots:
            t0 = time.time()
            try:
                p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   timeout=SEG_TIMEOUT)
            except subprocess.TimeoutExpired:
                _unlink(part)
                raise BadPath('转码超时（%ds）：VPS 算力可能不够，试试更低清晰度' % SEG_TIMEOUT)
            cost = time.time() - t0
        err = (p.stderr or b'').decode('utf-8', 'replace').strip()
        if p.returncode != 0 or not os.path.exists(part) or os.path.getsize(part) == 0:
            _unlink(part)
            raise BadPath('转码失败：%s' % (err.splitlines()[-1] if err else '未知错误'))
        os.replace(part, out)
        log('分片 %d/%s 用时 %.1fs %s' % (index, os.path.basename(vdir), cost,
                                        os.path.basename(full)))
        return out


def _unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


def prewarm(media_path, full, index, audio_index, height, duration):
    """提前烤好后面几片，避免播到分片边界卡一下。"""
    if PREWARM <= 0 or _prewarm_pool is None:
        return
    total = seg_count(duration)
    for i in range(index + 1, min(index + 1 + PREWARM, total)):
        key = (media_path, i, audio_index, height)
        with _prewarm_guard:
            if key in _prewarm_seen:
                continue
            if len(_prewarm_seen) > 4096:
                _prewarm_seen.clear()
            _prewarm_seen[key] = 1

        def job(i=i):
            try:
                make_segment(media_path, full, i, audio_index, height, duration)
            except Exception:
                pass
            finally:
                with _prewarm_guard:
                    _prewarm_seen.pop((media_path, i, audio_index, height), None)

        try:
            _prewarm_pool.submit(job)
        except RuntimeError:
            return


def seg_count(duration):
    return max(1, int(math.ceil((duration or 0) / float(SEG)))) if duration else 1


def build_playlist(media_path, duration, audio_index, height, ticket):
    n = seg_count(duration)
    q = {'p': media_path, 'h': height, 'pt': ticket}
    if audio_index is not None:
        q['a'] = audio_index
    qs = urllib.parse.urlencode(q)
    out = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:%d' % SEG,
           '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD',
           '#EXT-X-INDEPENDENT-SEGMENTS']
    for i in range(n):
        seg_len = min(float(SEG), duration - i * SEG) if duration else float(SEG)
        out.append('#EXTINF:%.3f,' % max(seg_len, 0.001))
        out.append('seg-%06d.ts?%s' % (i, qs))
    out += ['#EXT-X-ENDLIST', '']
    return '\n'.join(out)


# ============================== 字幕 ==============================


def extract_vtt(full, stream_index=None):
    """内嵌字幕直接抽；外挂字幕按 UTF-8 → GB18030 → BIG5 依次试，专治中文乱码。"""
    attempts = [None] if stream_index is not None else [None, 'GB18030', 'BIG5']
    last = ''
    for charenc in attempts:
        cmd = [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error']
        if charenc:
            cmd += ['-sub_charenc', charenc]
        cmd += ['-i', full]
        if stream_index is not None:
            cmd += ['-map', '0:%d' % stream_index]
        cmd += ['-f', 'webvtt', 'pipe:1']
        try:
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        except subprocess.TimeoutExpired:
            raise BadPath('字幕提取超时')
        body = p.stdout or b''
        if p.returncode == 0 and b'WEBVTT' in body and len(body) > 24:
            return body
        last = (p.stderr or b'').decode('utf-8', 'replace').strip()
    raise BadPath('字幕提取失败：%s' % (last.splitlines()[-1] if last else '格式不支持'))


# ============================== 清理 ==============================


def _entry_newest_mtime(path):
    if os.path.isfile(path):
        try:
            return os.stat(path).st_mtime
        except OSError:
            return 0
    newest = 0
    for root, _dirs, files in os.walk(path):
        for n in files:
            try:
                newest = max(newest, os.stat(os.path.join(root, n)).st_mtime)
            except OSError:
                pass
    return newest


def _remove_entry(path):
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)
        return True
    except OSError as e:
        log('删除失败', path, e)
        return False


def _top_entries():
    out = []
    try:
        for n in os.listdir(_REAL_ROOT):
            p = os.path.join(_REAL_ROOT, n)
            out.append((p, _entry_newest_mtime(p)))
    except OSError:
        pass
    return out


def _recently_played(path):
    """整个条目里只要有文件最近被播过，就整体留着（正在看的片子不能删）。"""
    keep_window = max(RETENTION_HOURS * 3600, 900)
    now = time.time()
    if os.path.isfile(path):
        return now - touched_at(to_media_path(path)) < keep_window
    for root, _dirs, files in os.walk(path):
        for n in files:
            if now - touched_at(to_media_path(os.path.join(root, n))) < keep_window:
                return True
    return False


def clean_downloads():
    if RETENTION_HOURS <= 0:
        return
    cutoff = time.time() - RETENTION_HOURS * 3600
    for path, newest in _top_entries():
        if newest and newest < cutoff and not _recently_played(path):
            if _remove_entry(path):
                log('过期清理', os.path.basename(path))


def clean_by_disk():
    if MAX_DISK_PERCENT <= 0 or MAX_DISK_PERCENT >= 100:
        return
    try:
        usage = shutil.disk_usage(_REAL_ROOT)
    except OSError:
        return
    if usage.total <= 0:
        return
    used_pct = (usage.total - usage.free) * 100.0 / usage.total
    if used_pct <= MAX_DISK_PERCENT:
        return
    log('磁盘已用 %.1f%%，超过 %d%%，开始按最旧顺序清理' % (used_pct, MAX_DISK_PERCENT))
    for path, _newest in sorted(_top_entries(), key=lambda x: x[1]):
        if _recently_played(path):
            continue
        if not _remove_entry(path):
            continue
        log('磁盘告急清理', os.path.basename(path))
        try:
            usage = shutil.disk_usage(_REAL_ROOT)
        except OSError:
            return
        if (usage.total - usage.free) * 100.0 / usage.total <= MAX_DISK_PERCENT:
            return


def clean_cache():
    if CACHE_MAX_MB <= 0:
        return
    dirs = []
    total = 0
    try:
        names = os.listdir(HLS_CACHE)
    except OSError:
        return
    for n in names:
        d = os.path.join(HLS_CACHE, n)
        if not os.path.isdir(d):
            continue
        size = 0
        try:
            for f in os.listdir(d):
                try:
                    size += os.stat(os.path.join(d, f)).st_size
                except OSError:
                    pass
            mtime = os.stat(d).st_mtime
        except OSError:
            continue
        dirs.append((d, size, mtime))
        total += size
    limit = CACHE_MAX_MB * 1024 * 1024
    if total <= limit:
        return
    for d, size, _mtime in sorted(dirs, key=lambda x: x[2]):
        if total <= limit:
            return
        if _remove_entry(d):
            total -= size
            log('分片缓存清理', os.path.basename(d))


def cleaner_loop():
    while True:
        time.sleep(CLEAN_INTERVAL)
        for fn in (clean_downloads, clean_by_disk, clean_cache):
            try:
                fn()
            except Exception as e:
                log('清理异常', fn.__name__, e)


# ============================== HTTP ==============================


class Handler(BaseHTTPRequestHandler):
    server_version = 'yun-caster'
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass

    # -------- 基础输出 --------

    def _send(self, code, body=b'', ctype='application/json; charset=utf-8', extra=None):
        if isinstance(body, str):
            body = body.encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != 'HEAD' and body:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

    def _err(self, code, msg):
        self._json(code, {'code': code, 'message': msg})

    def _file(self, path, ctype):
        # 先开文件再发响应头：否则文件刚好被清理掉时会发出两份响应，连接就乱了
        try:
            f = open(path, 'rb')
            size = os.fstat(f.fileno()).st_size
        except OSError as e:
            return self._err(404, '读取失败：%s' % e)
        try:
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(size))
            self.send_header('Accept-Ranges', 'none')
            self.send_header('Cache-Control', 'private, max-age=86400')
            self.end_headers()
            if self.command != 'HEAD':
                shutil.copyfileobj(f, self.wfile, 256 * 1024)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            f.close()

    # -------- 路由 --------

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            parsed = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(parsed.query)
            path = parsed.path
            if path == '/health':
                return self.h_health()
            if path == '/probe':
                return self.h_probe(q)
            if path == '/hls/index.m3u8':
                return self.h_playlist(q)
            if path.startswith('/hls/seg-') and path.endswith('.ts'):
                return self.h_segment(path, q)
            if path == '/sub':
                return self.h_sub(q)
            if path == '/hls.js':
                return self.h_hlsjs()
            if path == '/auth/play':
                return self.h_auth_play()
            if path == '/auth/api':
                return self.h_auth_api()
            return self._err(404, '没有这个接口')
        except BadPath as e:
            return self._err(400, str(e))
        except Exception as e:
            log('处理 %s 出错: %r' % (self.path, e))
            return self._err(500, '服务内部错误：%s' % e)

    def _one(self, q, key, default=None):
        v = q.get(key)
        return v[0] if v else default

    def _authed(self, media_path, q):
        if check_ticket(media_path, self._one(q, 'pt', '')):
            return True
        return alist_authorized(self.headers.get('Authorization', ''))

    # -------- 各接口 --------

    def h_health(self):
        # 未登录只给前端排版需要的无害信息；登录后才给 ffmpeg 版本、磁盘占用等运维细节
        out = {'code': 200, 'ok': True, 'retention_hours': RETENTION_HOURS,
               'seg_seconds': SEG, 'max_height': MAX_HEIGHT}
        if not alist_authorized(self.headers.get('Authorization', '')):
            return self._json(200, out)
        try:
            raw = subprocess.run([FFMPEG, '-version'], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10).stdout
            out['ffmpeg'] = raw.decode('utf-8', 'replace').splitlines()[0] if raw else '不可用'
        except Exception:
            out['ffmpeg'] = '不可用'
        try:
            u = shutil.disk_usage(_REAL_ROOT)
            out['disk'] = {'total': u.total, 'free': u.free,
                           'used_percent': round((u.total - u.free) * 100.0 / u.total, 1)}
        except OSError:
            pass
        out.update({'encoder': VIDEO_ENCODER, 'hwaccel': HWACCEL, 'jobs': JOBS,
                    'auth': AUTH_ENFORCE})
        return self._json(200, out)

    def h_probe(self, q):
        media_path = self._one(q, 'p', '')
        if not alist_authorized(self.headers.get('Authorization', '')) \
                and not check_ticket(media_path, self._one(q, 'pt', '')):
            return self._err(401, '请先登录')
        info = probe_info(media_path)
        return self._json(200, {'code': 200, 'data': info})

    def h_playlist(self, q):
        media_path = self._one(q, 'p', '')
        if not self._authed(media_path, q):
            return self._err(401, '播放票据无效或已过期，请重新点击播放')
        full = resolve(media_path)
        data = ffprobe(full)
        duration = _duration(data)
        if duration <= 0:
            return self._err(409, '还读不到视频时长，等下载再多一点再试')
        audio_index = self._audio_index(q, data)
        height = self._height(q)
        touch(media_path)
        body = build_playlist(media_path, duration, audio_index, height,
                             self._one(q, 'pt', '') or make_ticket(media_path))
        return self._send(200, body, 'application/vnd.apple.mpegurl; charset=utf-8')

    def h_segment(self, path, q):
        media_path = self._one(q, 'p', '')
        if not self._authed(media_path, q):
            return self._err(401, '播放票据无效或已过期，请重新点击播放')
        m = re.search(r'seg-(\d+)\.ts$', path)
        if not m:
            return self._err(400, '分片名不合法')
        index = int(m.group(1))
        full = resolve(media_path)
        data = ffprobe(full)
        duration = _duration(data)
        audio_index = self._audio_index(q, data)
        height = self._height(q)
        touch(media_path)
        out = make_segment(media_path, full, index, audio_index, height, duration)
        prewarm(media_path, full, index, audio_index, height, duration)
        return self._file(out, 'video/mp2t')

    def h_sub(self, q):
        media_path = self._one(q, 'p', '')
        if not self._authed(media_path, q):
            return self._err(401, '播放票据无效或已过期')
        full = resolve(media_path)
        side = self._one(q, 'f')
        if side:
            sfull = resolve(side)
            if os.path.dirname(sfull) != os.path.dirname(full):
                return self._err(400, '字幕文件必须和视频同目录')
            if os.path.splitext(sfull)[1].lower() not in SIDECAR_SUB_EXT:
                return self._err(400, '不是支持的字幕格式')
            body = extract_vtt(sfull, None)
        else:
            try:
                idx = int(self._one(q, 'i', ''))
            except ValueError:
                return self._err(400, '缺少字幕轨编号')
            body = extract_vtt(full, idx)
        return self._send(200, body, 'text/vtt; charset=utf-8')

    def h_hlsjs(self):
        if os.path.isfile(VENDOR_HLSJS):
            return self._file(VENDOR_HLSJS, 'application/javascript; charset=utf-8')
        return self._err(404, '本地没有内置 hls.js，前端会自动回退到 CDN')

    def h_auth_play(self):
        """nginx 用：校验 /d/... 的播放票据。"""
        if not AUTH_ENFORCE:
            return self._send(200, b'ok', 'text/plain')
        uri = self.headers.get('X-Original-URI', '')
        parsed = urllib.parse.urlsplit(uri)
        q = urllib.parse.parse_qs(parsed.query)
        raw = urllib.parse.unquote(parsed.path)
        if not raw.startswith('/d' + MOUNT + '/'):
            return self._send(403, b'', 'text/plain')
        media_path = raw[2:]
        if check_ticket(media_path, self._one(q, 'pt', '')) \
                or alist_authorized(self.headers.get('Authorization', '')):
            touch(media_path)
            return self._send(200, b'ok', 'text/plain')
        return self._send(401, b'', 'text/plain')

    def h_auth_api(self):
        """nginx 用：校验 /ls/ 目录列表要求的 AList 登录态。"""
        if not AUTH_ENFORCE:
            return self._send(200, b'ok', 'text/plain')
        if alist_authorized(self.headers.get('Authorization', '')):
            return self._send(200, b'ok', 'text/plain')
        return self._send(401, b'', 'text/plain')

    # -------- 参数 --------

    def _audio_index(self, q, data):
        raw = self._one(q, 'a')
        audio_streams = [s.get('index') for s in (data.get('streams') or [])
                         if s.get('codec_type') == 'audio']
        if raw is not None:
            try:
                want = int(raw)
            except ValueError:
                want = None
            if want in audio_streams:
                return want
        if not audio_streams:
            return None
        for s in data.get('streams') or []:
            if s.get('codec_type') == 'audio' and (s.get('disposition') or {}).get('default'):
                return s.get('index')
        return audio_streams[0]

    def _height(self, q):
        try:
            h = int(self._one(q, 'h', MAX_HEIGHT))
        except ValueError:
            h = MAX_HEIGHT
        return max(144, min(2160, h))


def main():
    os.makedirs(HLS_CACHE, exist_ok=True)
    log('启动：root=%s 编码器=%s 上限=%dp 分片=%ds 并发=%d 保留=%sh 鉴权=%s'
        % (_REAL_ROOT, VIDEO_ENCODER, MAX_HEIGHT, SEG, JOBS, RETENTION_HOURS, AUTH_ENFORCE))
    threading.Thread(target=cleaner_loop, daemon=True).start()
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    srv.daemon_threads = True
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
