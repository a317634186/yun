# yun · 云网页播放器

开源版 "PikPak"：在 VPS 上提交磁力/种子链接 → 离线下载 → 转存 OneDrive / Google Drive → 网页直接在线播放。

基于 [AList](https://github.com/alist-org/alist) + [Aria2](https://github.com/aria2/aria2) 一体镜像，Docker 一键部署，自带文本管理菜单。

## 功能特性

- 🧲 **离线下载**：网页粘贴磁力链接 / .torrent，Aria2 在 VPS 上下载
- ☁️ **云盘挂载**：OneDrive、Google Drive 等 30+ 网盘 OAuth 授权挂载（[完整列表](https://alistgo.com/guide/drivers/local.html)）
- ▶️ **在线播放**：内置 ArtPlayer，mp4/webm 直接播，mkv 大多可直出
- 🔄 **转存不占盘**：下载完成后移动到云盘，VPS 只做临时中转
- 🛠 **一键菜单**：`bash menu.sh` 安装 / 更新 / 卸载 / 改密码 / 改端口 / 看日志
- 🐳 **部署简单**：一条 `docker compose up -d`，数据卷持久化，支持反代 HTTPS

## 快速开始

```bash
git clone https://github.com/a317634186/yun && cd yun
bash menu.sh     # 选择 1 安装
```

安装脚本会自动：安装 Docker（含国内镜像源回退）→ 生成随机 RPC 密钥 → 启动容器 → 设置管理员密码 → **自动配置好 Aria2 离线下载**（失败会打印手动配置步骤）。

在云厂商安全组放行 **5244** 端口后，浏览器打开 `http://VPS公网IP:5244` 即可使用。

## 架构与使用流程

```
浏览器 ──→ AList Web UI (http://VPS IP:5244)
             ├─ 离线下载：粘贴磁力/种子 → Aria2 下载到 VPS 临时目录
             ├─ 云盘挂载：OneDrive / Google Drive（OAuth 授权）
             └─ 内置播放器：mp4/webm 直接播，mkv 大多也能播
```

1. 网页右上角 **更多 → 离线下载**，粘贴磁力链接（`magnet:?xt=...`）
2. 等待 Aria2 下载完成（进度在页面可见）
3. 勾选文件 **复制/移动** 到云盘目录（走 API 上传，不长期占用 VPS 磁盘）
4. 点击云盘里的视频文件，在线播放
5. 删除本地临时文件释放磁盘

## 目录结构

```
yun/
├── menu.sh               # 管理菜单（安装/更新/卸载/配置/日志）
├── docker-compose.yml    # AList + Aria2 一体容器编排
├── .env.example          # 配置模板（端口、RPC 密钥）
├── .env                  # 实际配置，安装时自动生成，不入库（已 gitignore）
├── data/                 # AList 数据库与配置（运行时生成）
├── downloads/            # 离线下载临时目录（运行时生成）
└── README.md
```

> 所有本地配置（端口、RPC 密钥）都写在 `.env` 中，`git pull` 更新时不会产生冲突。

---

## 一、部署（在 VPS 上执行）

### 方式一：菜单脚本（推荐）

```bash
git clone https://github.com/a317634186/yun && cd yun
bash menu.sh
```

会显示文本菜单，按数字选择即可：

```
  1. 安装（首次部署）      ← 自动装 Docker、生成密钥、启动、自动配置离线下载
  2. 更新（拉取最新版并重启）
  3. 重启/启动服务
  4. 停止服务
  5. 查看运行状态
  6. 查看日志
  7. 配置管理（密码/密钥/端口）
  8. 卸载
  0. 退出
```

也支持直接执行子命令：`bash menu.sh install`、`bash menu.sh update`、`bash menu.sh config` 等。

### 方式二：手动命令

前提：VPS 已装 Docker 和 Docker Compose（`curl -fsSL https://get.docker.com | sh`）。

```bash
git clone https://github.com/a317634186/yun && cd yun
cp .env.example .env    # 可选：修改 ARIA2_RPC_SECRET / PORT
docker compose up -d
docker exec alist ./alist admin   # 查看管理员初始密码
docker exec alist ./alist admin set 你的新密码   #（可选）修改密码
```

两种方式完成后，在云厂商安全组放行 **5244** 端口，浏览器打开 `http://VPS公网IP:5244`，用 admin + 密码登录。

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

用 `bash menu.sh` 安装的，脚本会**自动完成本节配置**（通过 AList API 写入），无需手动操作；只有自动配置失败时才需要按下面步骤手动填一次：

1. **管理 → 设置 → 离线下载**：
   - Aria2 RPC 地址：`http://127.0.0.1:6800/jsonrpc`（同容器内）
   - Aria2 RPC 密钥：`.env` 里的 `ARIA2_RPC_SECRET`（手动安装的请自己设置一个）
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
| 打不开网页 | 检查安全组 5244 端口；`bash menu.sh` 选 6 看日志 |
| 磁力下载没速度 | 种子冷门或 VPS 出口被限，属正常；换热门种子测试 |
| aria2 连不上 | 确认后台 RPC 密钥与 `.env` 一致；改完后 `bash menu.sh` 选 3 重启 |
| 云盘挂载失败 | OneDrive/Google token 过期，进存储编辑页重新获取 refresh token |
| 磁盘爆满 | 删除 `./downloads` 下已转存的文件 |

## 致谢

- [AList](https://github.com/alist-org/alist) — 网盘挂载与网页文件管理
- [Aria2](https://github.com/aria2/aria2) — 下载引擎
- [alicion/alist-aria2](https://hub.docker.com/r/alicion/alist-aria2) — 一体化 Docker 镜像

## 免责声明

本项目仅提供网盘挂载与下载工具的部署配置，请遵守所在地区法律法规及网盘服务条款使用。
