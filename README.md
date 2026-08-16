# yun · 云播放器（种子直接播）

复制一个磁力链接 → VPS 云端下载 → 网页直接在线播放。

**不需要任何网盘账号**，文件就存在 VPS 硬盘上，下载完点开就看。基于 [AList](https://github.com/alist-org/alist) + Aria2 官方一体镜像，Docker 部署，安装一条命令。

## 使用就三步

### 第 1 步 · 安装（VPS 上执行一条命令）

```bash
curl -fsSL https://raw.githubusercontent.com/a317634186/yun/main/install.sh | bash
```

全自动，不用输入任何东西。装完屏幕上会显示**网址、账号 admin、密码**，截图保存。

> 记得在云服务器控制台的**安全组**放行 `5244` 端口，否则网页打不开。
> curl 下载不了脚本的话（DNS 问题先按 [这个方法](#常见问题) 修），备选：
> ```bash
> git clone https://github.com/a317634186/yun && cd yun && bash menu.sh
> ```

### 第 2 步 · 登录网页

浏览器打开 `http://你的VPS_IP:5244`，点**左下角「登录」**，账号 `admin` + 安装时显示的密码。

### 第 3 步 · 粘磁力 → 直接看

1. 首页右上角 **≡ 菜单 → 离线下载**，粘贴磁力链接（`magnet:?xt=...`）→ 确定
2. 左侧 **`downloads`** 文件夹里看下载进度（内置高速配置：64 分片、16 连接、自动 tracker）
3. 下载完成，**直接点击视频文件就能播放**（mp4/webm/mkv 都支持）
4. 看完勾选删除，释放磁盘

没有任何网盘、任何账号授权、任何代码操作。

## 存储与流量说明（重要）

- 文件存在 **VPS 硬盘**上：容量上限 = VPS 磁盘大小（`df -h /root` 查看），记得定期删
- **播放走 VPS 流量**：看一部 10GB 的电影大约消耗 10GB 流量，注意 VPS 的流量配额
- 想长期保存大文件？见下面"可选：挂载网盘扩容"

## 可选：挂载网盘扩容（不需要可跳过）

VPS 磁盘不够用时，可以把 OneDrive / Google Drive 挂载进来当仓库，下载完成后在网页里把文件**复制/移动**到云盘（走 API 上传），VPS 磁盘清空继续下：

1. 登录后点右上角**头像 → 管理** → 左侧 **存储 → 添加存储**

| 网盘 | 操作 |
|---|---|
| **OneDrive**（最简单） | 驱动选 `OneDrive`，点页面链接 → 微软账号登录 → 令牌粘贴回输入框 → 保存 |
| **Google Drive** | 驱动选 `Google Drive`；先到 [Google 云控制台](https://console.cloud.google.com/apis/credentials)免费建 OAuth 客户端（"桌面应用"，开启 Drive API），填 client_id / secret 后点链接授权 |

2. 挂载后，云盘里的视频也是直接点开播放（走微软/谷歌官方 CDN 直链，不耗 VPS 流量）
3. 播放卡顿时：播放页右下角**切换播放器**（ArtPlayer / ExoPlayer / iframe）

## 管理（VPS 上执行 `bash menu.sh`）

```
  1. 安装          5. 查看运行状态
  2. 更新          6. 查看日志
  3. 重启/启动     7. 重置密码 / 改端口
  4. 停止服务      8. 卸载
```

忘记密码：`cd ~/yun && bash menu.sh` → `7` → `1`。

## 常见问题

| 问题 | 处理 |
|---|---|
| 网页打不开 | 云厂商安全组放行 5244 端口；`bash menu.sh` 选 6 看日志 |
| 装脚本时 `Could not resolve host: raw.githubusercontent.com` | VPS 的 DNS 坏了，执行：`systemctl disable --now systemd-resolved 2>/dev/null; rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf` 后重试 |
| 磁力下载没速度 | 种子冷门，属正常现象；换热门种子测试 |
| VPS 磁盘满 | 删除 `downloads` 里看完的文件，或挂载网盘转存 |
| 播放卡顿 | 切换播放器；或确认 VPS 带宽是否被跑满 |

## 目录结构

```
yun/
├── install.sh            # 一键安装脚本（curl 调用的就是它）
├── menu.sh               # 管理菜单
├── docker-compose.yml    # AList 官方 + Aria2 一体镜像编排
├── .env.example          # 配置模板（端口）
├── data/                 # AList 数据（运行时生成）
└── downloads/            # 下载存放目录（运行时生成）
```

## 致谢

- [AList](https://github.com/alist-org/alist) — 网页文件管理与播放器
- [aria2](https://github.com/aria2/aria2) / [P3TERX 配置](https://github.com/P3TERX/aria2.conf) — 高速下载引擎与调优配置

## 免责声明

本项目仅提供下载与播放工具的部署配置，请遵守所在地区法律法规使用。
