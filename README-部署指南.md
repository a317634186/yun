# 云网页播放器（AList + Aria2）

开源版 "PikPak"：在 VPS 上提交磁力/种子链接 → Aria2 离线下载 → 转存到 OneDrive / Google Drive → 网页直接在线播放。

## 架构

```
浏览器 ──→ AList Web UI (http://你的VPS IP:5244)
             ├─ 离线下载：粘贴磁力/种子 → Aria2 下载到 VPS 临时目录
             ├─ 云盘挂载：OneDrive / Google Drive（OAuth 授权）
             └─ 内置播放器：mp4/webm 直接播，mkv 大多也能播
```

## 一、部署（在 VPS 上执行）

前提：VPS 已装 Docker 和 Docker Compose（`curl -fsSL https://get.docker.com | sh`）。

```bash
# 1. 上传本项目文件到 VPS（或直接 git clone / scp）
mkdir -p ~/cloud-player && cd ~/cloud-player
# 把 docker-compose.yml 和 .env 放到这里

# 2. 修改 .env 里的 ARIA2_RPC_SECRET 为随机字符串
vim .env

# 3. 启动
docker compose up -d

# 4. 查看管理员初始密码
docker exec alist ./alist admin

# 5.（可选）修改管理员密码
docker exec alist ./alist admin set 你的新密码
```

然后在云厂商安全组放行 **5244** 端口，浏览器打开 `http://VPS公网IP:5244`，用 admin + 密码登录。

> 强烈建议：后台 → 设置 → 站点，关闭游客访问或设置强密码，不要让服务裸奔公网。

## 二、挂载云盘

登录后进入 **管理 → 存储 → 添加存储**：

### OneDrive（简单）
1. 驱动选 `OneDrive`（个人版）或 `OneDriveAPP`
2. 刷新令牌：点击页面上的链接，用微软账号登录授权，把得到的 refresh token 粘贴进来
3. 挂载路径填 `/onedrive`，保存即可

### Google Drive
1. 需要先自建 OAuth 客户端（免费）：
   - 打开 https://console.cloud.google.com/apis/credentials
   - 新建项目 → 创建 OAuth 客户端 ID（类型选"桌面应用"）
   - 开启 Google Drive API（https://console.cloud.google.com/apis/library/drive.googleapis.com）
   - 把 client_id 和 client_secret 记下来
   - **OAuth 同意屏添加测试用户（你的 Gmail）**
2. AList 添加存储 → 驱动选 `Google Drive` → 填 client_id / client_secret → 点链接获取 refresh token 粘贴
3. 挂载路径 `/gdrive`，保存

> Google 授权页需要在浏览器能访问 Google 的环境下打开；授权完成后 VPS 走 API 直连一般没问题。

## 三、配置离线下载（Aria2）

镜像已内置 Aria2，只需在 AList 后台填 RPC 信息：

1. **管理 → 设置 → 离线下载**：
   - Aria2 RPC 地址：`http://127.0.0.1:6800/jsonrpc`（同容器内）
   - Aria2 RPC 密钥：`.env` 里你设置的 `ARIA2_RPC_SECRET`
   - 下载目录：`/opt/aria2/downloads`
2. 保存后，网页主界面点右上角 **更多 → 离线下载**，粘贴磁力链接（`magnet:?xt=...`）或 .torrent 文件链接即可开始下载。

## 四、下载完成后转存云盘并播放

1. 下载完成后，文件出现在本地存储 `/downloads` 目录下
2. 勾选文件 → **复制/移动** 到 `/onedrive` 或 `/gdrive`（AList 会通过 API 上传到云盘）
3. 到云盘目录里点击视频文件即可在线播放：
   - **mp4 / webm**：直接播放
   - **mkv**：AList 内置播放器大多可以直出（依赖浏览器解码能力）；若无法播放，见下方扩展
4. 上传完成后可删除本地临时文件释放 VPS 磁盘

## 五、可选扩展

### 用域名 + HTTPS（推荐）
在 compose 里加一个 Caddy 反代：

```yaml
  caddy:
    image: caddy:latest
    restart: always
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
    # Caddyfile 内容一行：player.example.com { reverse_proxy alist:5244 }
```

### mkv 转码播放（VPS 配置 ≥2核 时）
加一个 Jellyfin 容器，把云盘通过 rclone 挂载给它，实现转码播放。或者直接在播放器界面切换"使用 ExoPlayer / 使用 iframe"试试。

## 常见问题

| 问题 | 处理 |
|---|---|
| 打不开网页 | 检查安全组 5244 端口；`docker logs alist` 看报错 |
| 磁力下载没速度 | 种子冷门或 VPS 出口被限，属正常；换热门种子测试 |
| aria2 连不上 | 确认后台 RPC 密钥与 `.env` 一致；改完后重启容器 `docker compose restart` |
| 云盘挂载失败 | OneDrive/Google token 过期，进存储编辑页重新获取 refresh token |
| 磁盘爆满 | 删除 `./downloads` 下已转存的文件 |
