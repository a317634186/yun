#!/usr/bin/env bash
# yun 云播放器管理菜单（AList + Aria2）
# 用法：bash menu.sh          交互菜单
#       bash menu.sh install  直接执行子命令
set -u
cd "$(dirname "$0")"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
error() { echo -e "${RED}[错误]${PLAIN} $*"; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

DC=""
detect_compose() {
    if $SUDO docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DC="docker-compose"
    fi
}

require_compose() {
    detect_compose
    if [ -z "$DC" ]; then
        error "未检测到 Docker Compose，请先执行安装（菜单 1）"
        return 1
    fi
    $SUDO docker info >/dev/null 2>&1 || { error "Docker 服务未运行"; return 1; }
}

gen_secret() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32; }

get_env() { # $1=变量名 $2=默认值；顺手去掉行尾注释
    local v
    v=$(sed -n "s/^$1=//p" .env 2>/dev/null | tail -1 | sed 's/[[:space:]]*#.*$//' | tr -d '" ')
    echo "${v:-$2}"
}

get_port() { get_env PORT 5244; }

set_env() { # $1=变量名 $2=值
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
}

ask_env() { # $1=变量名 $2=提示 $3=当前值
    local v
    read -rp "$2 [当前 $3]: " v
    [ -n "$v" ] || { info "未修改"; return 1; }
    set_env "$1" "$v"
    info "$1 已改为 $v"
}

# 按 CPU 核数给转码参数一个合理起点，用户可用菜单 10 再调
autotune() {
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    [ "$cores" -ge 1 ] 2>/dev/null || cores=1
    set_env TRANSCODE_JOBS "$([ "$cores" -gt 4 ] && echo 4 || echo "$cores")"
    # 1080p 实时转码对 VPS 挺吃力，宁可保守一点，用户嫌糊再用菜单 10 往上调
    if   [ "$cores" -le 1 ]; then set_env MAX_HEIGHT 480;  set_env X264_PRESET ultrafast
    elif [ "$cores" -le 3 ]; then set_env MAX_HEIGHT 720;  set_env X264_PRESET veryfast
    elif [ "$cores" -le 7 ]; then set_env MAX_HEIGHT 720;  set_env X264_PRESET faster
    else                          set_env MAX_HEIGHT 1080; set_env X264_PRESET veryfast
    fi
    info "已按 ${cores} 核 CPU 自动设置转码参数（上限 $(get_env MAX_HEIGHT 720)p）"
}

MENU_IP=""
get_ip() {
    if [ -z "$MENU_IP" ]; then
        MENU_IP=$(curl -s --max-time 3 http://ifconfig.me 2>/dev/null || true)
    fi
    echo "${MENU_IP:-VPS公网IP}"
}

install_docker() {
    info "未检测到 Docker，开始自动安装（约 1-3 分钟）..."
    if ! curl -fsSL --connect-timeout 15 https://get.docker.com | $SUDO sh; then
        warn "官方源安装失败，尝试阿里云镜像源..."
        curl -fsSL https://get.docker.com | $SUDO sh -s -- --mirror Aliyun || { error "Docker 安装失败，请手动安装后重试"; return 1; }
    fi
    command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker
}

# 安装后自动配置：通过 AList 网页接口写入离线下载设置 + 下载目录
# $1=管理员密码 $2=访问端口；成功返回 0
auto_configure() {
    local base="http://127.0.0.1:$2" token ok=0
    command -v curl >/dev/null 2>&1 || return 1
    token=$(curl -s --connect-timeout 5 --max-time 10 -X POST "$base/api/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$1\"}" 2>/dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || return 1
    # 离线下载（Aria2）设置：键名为 aria2_uri / aria2_secret，镜像内置 aria2 无需密钥
    curl -s --max-time 10 -X PUT "$base/api/admin/setting/list" \
        -H "Authorization: $token" -H 'Content-Type: application/json' \
        -d '[{"key":"aria2_uri","value":"http://localhost:6800/jsonrpc"},{"key":"aria2_secret","value":""}]' \
        2>/dev/null | grep -q '"code":200' && ok=1
    # 让下载目录在网页里可见（挂载为 /downloads）
    curl -s --max-time 10 -X POST "$base/api/admin/storage/create" \
        -H "Authorization: $token" -H 'Content-Type: application/json' \
        -d '{"mount_path":"/downloads","driver":"Local","addition":"{\"root_folder_path\":\"/root/Download\"}"}' \
        2>/dev/null | grep -q '"code":200' || true
    [ "$ok" = 1 ]
}

print_manual_config() {
    warn "自动配置未成功，请在网页里手动设置一次（就一次）："
    echo -e "  登录后 → ${CYAN}管理 → 设置 → 离线下载${PLAIN}"
    echo -e "  Aria2 RPC 地址填 ${CYAN}http://localhost:6800/jsonrpc${PLAIN}，密钥留空，保存即可"
}

# ============ 功能 ============

do_install() {
    command -v docker >/dev/null 2>&1 || install_docker || return 1
    require_compose || return 1

    local fresh=1
    [ -f data/config.db ] && fresh=0

    [ -f .env ] || cp .env.example .env 2>/dev/null || echo "PORT=5244" > .env
    # 直链签名密钥：只在首次生成，之后一直复用
    [ -n "$(get_env STREAM_SECRET '')" ] || set_env STREAM_SECRET "$(gen_secret)"
    [ "$fresh" -eq 1 ] && autotune
    local port; port=$(get_port)

    if [ "$fresh" -eq 1 ]; then
        info "开始安装（端口 $port）..."
    else
        warn "检测到已有数据，将保留原有配置，仅重建容器"
    fi
    info "构建转码服务镜像（首次约 1-3 分钟）..."
    $SUDO $DC up -d --build || { error "启动失败，查看日志: bash menu.sh logs"; return 1; }

    if command -v curl >/dev/null 2>&1; then
        info "等待服务启动..."
        local up=0
        for _ in $(seq 1 30); do
            if curl -s --connect-timeout 3 -o /dev/null "http://127.0.0.1:${port}"; then up=1; break; fi
            sleep 2
        done
        [ "$up" = "1" ] || warn "服务 60 秒内未就绪，可能仍在启动，稍后请用菜单 7 查看日志"
    fi

    echo
    echo -e "${GREEN}══════════════ 安装完成 ══════════════${PLAIN}"
    local ip
    ip=$(curl -s --max-time 5 http://ifconfig.me 2>/dev/null || true)
    echo -e "访问地址: ${CYAN}http://${ip:-VPS公网IP}:${port}${PLAIN}"
    echo -e "管理员账号: ${CYAN}admin${PLAIN}"

    if [ "$fresh" -eq 1 ]; then
        local admin_pw
        admin_pw=$(gen_secret | cut -c1-16)
        if $SUDO docker exec alist ./alist admin set "$admin_pw" >/dev/null 2>&1; then
            echo -e "管理员密码: ${CYAN}${admin_pw}${PLAIN}（请截图保存，忘记可用菜单 8 重置）"
            info "正在自动配置离线下载..."
            if auto_configure "$admin_pw" "$port"; then
                info "离线下载已配置好，打开网页就能直接用"
            else
                print_manual_config
            fi
        else
            warn "设置密码失败，初始密码如下（请尽快登录修改）："
            $SUDO docker exec alist ./alist admin 2>/dev/null
            print_manual_config
        fi
    else
        echo "管理员密码: 你之前设置的密码（忘记可用菜单 8 重置）"
    fi
    echo
    echo -e "接下来：浏览器打开上面的网址 → 输入 admin 和上面的密码登录"
    echo -e "粘贴磁力链接即可下载，完成后直接点击播放（不需要任何网盘）"
    echo -e "需要挂载网盘扩容时，可访问 ${CYAN}http://IP:${port}/@login${PLAIN} 进入原版管理后台"
    warn "请确认云厂商安全组已放行 ${port} 端口"
}

do_update() {
    require_compose || return 1
    if [ -d .git ]; then
        info "拉取最新代码..."
        git pull --ff-only || warn "代码更新失败（网络原因），继续更新镜像"
    fi
    info "拉取最新镜像..."
    if $SUDO $DC pull --help 2>/dev/null | grep -q ignore-buildable; then
        $SUDO $DC pull --ignore-buildable || warn "镜像拉取有失败项，继续"
    else
        $SUDO $DC pull || warn "镜像拉取有失败项，继续"
    fi
    info "重建并重启服务..."
    $SUDO $DC up -d --build --remove-orphans
    info "更新完成"
}

do_restart() {
    require_compose || return 1
    $SUDO $DC up -d --build && $SUDO $DC restart
    info "已启动/重启"
}

do_stop() {
    require_compose || return 1
    $SUDO $DC stop
    info "已停止（重新启动: bash menu.sh restart）"
}

do_status() {
    require_compose || return 1
    $SUDO $DC ps
    local n
    for n in alist yun-caster yun-web; do
        if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$n"; then
            info "$n 运行中"
        else
            warn "$n 未在运行"
        fi
    done
    echo
    info "转码服务自检:"
    $SUDO docker exec yun-caster ffmpeg -version 2>/dev/null | head -1 \
        || warn "  转码服务内取不到 ffmpeg（容器可能没起来，看菜单 7 日志）"
    echo
    info "磁盘占用:"
    $SUDO du -sh "$(pwd)/downloads" 2>/dev/null || echo "  下载目录：暂无数据"
    $SUDO du -sh "$(pwd)/cache" 2>/dev/null     || echo "  分片缓存：暂无数据"
    $SUDO df -h "$(pwd)" 2>/dev/null | tail -1
}

do_logs() {
    require_compose || return 1
    echo -e "${CYAN}—— 下载服务 (alist) ——${PLAIN}"
    $SUDO $DC logs --tail=60 alist
    echo -e "${CYAN}—— 转码播放服务 (caster) ——${PLAIN}"
    $SUDO $DC logs --tail=60 caster
}

do_uninstall() {
    require_compose || return 1
    warn "将停止并删除容器"
    read -rp "确认卸载？(y/N): " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { info "已取消"; return 0; }
    $SUDO $DC down

    read -rp "是否删除数据（配置/下载的文件）？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO rm -rf data downloads cache .env
        info "数据目录、分片缓存与 .env 已删除"
    else
        info "保留数据目录：$(pwd)/data $(pwd)/downloads $(pwd)/cache"
    fi

    read -rp "是否删除 Docker 镜像？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO docker image rm xhofe/alist-aria2:latest nginx:alpine 2>/dev/null
        $SUDO docker image rm "$(basename "$(pwd)")-caster" yun-caster 2>/dev/null
        info "镜像已删除"
    fi
    info "卸载完成"
}

reset_password() {
    require_compose || return 1
    read -rp "输入新的管理员密码: " pw
    [ -n "$pw" ] || { warn "密码不能为空"; return 1; }
    $SUDO docker exec alist ./alist admin set "$pw" \
        && info "密码已重置，用新密码登录网页即可" || error "重置失败（容器未运行？）"
}

play_settings() {
    require_compose || return 1
    [ -f .env ] || cp .env.example .env 2>/dev/null
    while true; do
        echo
        echo -e "${CYAN}—— 播放与清理设置 ——${PLAIN}"
        echo "  1. 转码清晰度上限  MAX_HEIGHT       = $(get_env MAX_HEIGHT 720)p     （CPU 弱就调 480）"
        echo "  2. 转码画质        VIDEO_QUALITY    = $(get_env VIDEO_QUALITY 23)      （18-28，越小越清晰越吃 CPU）"
        echo "  3. 同时转码数      TRANSCODE_JOBS   = $(get_env TRANSCODE_JOBS 2)      （建议等于 CPU 核数）"
        echo "  4. 文件保留小时数  RETENTION_HOURS  = $(get_env RETENTION_HOURS 1)      （0 = 永不自动删）"
        echo "  5. 磁盘占用上限    MAX_DISK_PERCENT = $(get_env MAX_DISK_PERCENT 90)%"
        echo "  6. 分片缓存上限    CACHE_MAX_MB     = $(get_env CACHE_MAX_MB 4096) MB"
        echo "  7. 按 CPU 核数重新自动配置"
        echo "  0. 保存并返回"
        read -rp "改哪一项：" k
        case "$k" in
            1) ask_env MAX_HEIGHT       "输入清晰度上限（480 / 720 / 1080）" "$(get_env MAX_HEIGHT 720)" ;;
            2) ask_env VIDEO_QUALITY    "输入画质数值（18-28）"              "$(get_env VIDEO_QUALITY 23)" ;;
            3) ask_env TRANSCODE_JOBS   "输入同时转码数"                     "$(get_env TRANSCODE_JOBS 2)" ;;
            4) ask_env RETENTION_HOURS  "输入保留小时数（0=永不删）"          "$(get_env RETENTION_HOURS 1)" ;;
            5) ask_env MAX_DISK_PERCENT "输入磁盘占用上限百分比"              "$(get_env MAX_DISK_PERCENT 90)" ;;
            6) ask_env CACHE_MAX_MB     "输入分片缓存上限（MB）"              "$(get_env CACHE_MAX_MB 4096)" ;;
            7) autotune ;;
            0) break ;;
            *) warn "无效选择: $k" ;;
        esac
    done
    info "应用设置..."
    $SUDO $DC up -d && info "已生效（正在播放的页面刷新一下即可）"
}

change_port() {
    require_compose || return 1
    read -rp "输入新端口 (1-65535): " port
    case "$port" in
        ''|*[!0-9]*) warn "端口必须是数字"; return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { warn "端口范围不合法"; return 1; }
    set_env PORT "$port"
    $SUDO $DC up -d
    info "已改为端口 ${port}，请放行安全组后访问 http://$(get_ip):${port}"
}

# ============ 菜单 ============

menu_header() {
    local installed="未安装" running="服务未运行" caster="转码未运行"
    if [ -f data/config.db ] || $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^alist$'; then
        installed="已安装"
    fi
    if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^alist$'; then
        running="服务运行中"
    elif [ "$installed" = "已安装" ]; then
        running="服务已停止"
    fi
    if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'yun-caster'; then
        caster="转码就绪 $(get_env MAX_HEIGHT 720)p"
    fi
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
    echo -e "  ${GREEN}yun 云播放器${PLAIN}  ·  ${installed} · ${running} · ${caster}"
    echo -e "  面板地址: http://$(get_ip):$(get_port)"
    echo -e "${CYAN}------------------------------------------------${PLAIN}"
}

main_menu() {
    while true; do
        command -v clear >/dev/null 2>&1 && clear
        menu_header
        echo "  1. 安装"
        echo "  2. 更新"
        echo "  3. 卸载"
        echo "------------------------------------------------"
        echo "  4. 查看服务状态"
        echo "  5. 重启服务"
        echo "  6. 停止服务"
        echo "  7. 查看日志"
        echo "------------------------------------------------"
        echo "  8. 重置管理员密码"
        echo "  9. 修改访问端口"
        echo " 10. 播放与清理设置（清晰度 / 保留时长 / 磁盘上限）"
        echo "------------------------------------------------"
        echo "  0. 退出"
        echo "------------------------------------------------"
        read -rp "请输入你的选择：" c
        case "$c" in
            1) do_install ;;
            2) do_update ;;
            3) do_uninstall ;;
            4) do_status ;;
            5) do_restart ;;
            6) do_stop ;;
            7) do_logs ;;
            8) reset_password ;;
            9) change_port ;;
            10) play_settings ;;
            0) exit 0 ;;
            *) warn "无效选择: $c" ;;
        esac
        echo
        read -rp "按回车返回菜单..." _
    done
}

case "${1:-menu}" in
    install)   do_install ;;
    update)    do_update ;;
    restart)   do_restart ;;
    stop)      do_stop ;;
    status)    do_status ;;
    logs)      do_logs ;;
    uninstall) do_uninstall ;;
    passwd)    reset_password ;;
    port)      change_port ;;
    settings)  play_settings ;;
    menu)      main_menu ;;
    *) echo "用法: bash menu.sh [install|update|restart|stop|status|logs|uninstall|passwd|port|settings]" ;;
esac
