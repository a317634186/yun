# yun · 云播放器

像 PikPak 一样：复制一个磁力链接 → 云端离线下载 → 转存到你的 OneDrive / Google Drive → 网页直接在线播放。

基于 [AList](https://github.com/alist-org/alist) + Aria2 官方一体镜像，Docker 部署。**安装只要一条命令，装完之后所有操作（登录、挂载云盘、下载、播放）全部在网页里点击完成，不需要碰代码。**

## 第 1 步 · 安装（VPS 上执行一条命令）

```bash
curl -fsSL https://raw.githubusercontent.com/a317634186/yun/main/install.sh | bash
```

全自动：自动装 Docker（国内 VPS 自动切换镜像源）→ 启动云播放器 → 设置管理员密码 → 配置好离线下载，全程不用输入任何东西。

装完屏幕上会显示三样东西，**截图保存**：

```
访问地址: http://你的VPS_IP:5244
管理员账号: admin
管理员密码: xxxxxxxxxxxxxxxx
```

> 如果 curl 方式下载不了，用备选方式：
> ```bash
> git clone https://github.com/a317634186/yun && cd yun && bash menu.sh
> ```
> 然后按数字 `1` 安装。
>
> 记得去云服务器控制台的**安全组**放行 `5244` 端口，否则网页打不开。

## 第 2 步 · 网页登录

浏览器打开 `http://你的VPS_IP:5244`：

1. 点击页面**左下角的「登录」按钮**
2. 用户名 `admin`，密码是安装完成时屏幕上显示的（忘记密码见下方）

## 第 3 步 · 添加云盘（网页里点几下）

1. 登录后点右上角**头像 → 管理**，进入可视化后台
2. 左侧 **存储 → 添加存储**
3. 选择你的网盘，按页面提示授权登录自己的账号：

| 网盘 | 操作 |
|---|---|
| **OneDrive**（最简单） | 驱动选 `OneDrive`，点页面的链接 → 微软账号登录 → 把得到的令牌粘贴回输入框 → 保存 |
| **Google Drive** | 驱动选 `Google Drive`；需要先到 [Google 云控制台](https://console.cloud.google.com/apis/credentials)免费创建一个 OAuth 客户端（类型选"桌面应用"，并开启 Drive API），把 client_id / secret 填进来，再点链接授权 |

保存后回到首页，就能看到你的云盘文件夹了。

## 日常使用（全部在网页里）

**下载种子：**
1. 首页右上角 **≡ 菜单 → 离线下载**
2. 粘贴磁力链接（`magnet:?xt=...`）或上传 .torrent 文件 → 确定

**看进度 / 播放：**
- 左侧 `downloads` 文件夹里实时看到下载进度（镜像已内置高速下载配置：64 分片、单服务器 16 连接、自动更新 tracker 列表）
- 下载完成 → 勾选文件 → **复制/移动** 到云盘目录（走官方 API 上传，不占用 VPS 空间）
- 点击云盘里的视频文件直接在线播放（mp4/webm/mkv 都支持）

**播放速度说明：**
- 播放默认走 OneDrive / Google Drive **官方 CDN 直链**，速度是微软/谷歌 CDN 的速度，不消耗 VPS 带宽，一般秒开
- 如果某个文件加载慢：播放页右下角可以**切换播放器**（ArtPlayer / ExoPlayer / iframe）再试
- 云盘很慢时可在 后台 → 存储 → 编辑该云盘 → 打开 **Web 代理**（用 VPS 中转，VPS 带宽好才有用）

## 管理（VPS 上执行 `bash menu.sh`）

```
  1. 安装（全自动，装完显示密码）
  2. 更新          ← 有新版本时执行
  3. 重启/启动服务
  4. 停止服务
  5. 查看运行状态
  6. 查看日志
  7. 重置密码 / 改端口    ← 忘记管理员密码用这个
  8. 卸载
```

忘记密码：`cd ~/yun && bash menu.sh` → `7` → `1`，输入新密码即可。

## 常见问题

| 问题 | 处理 |
|---|---|
| 网页打不开 | 云厂商安全组放行 5244 端口；`bash menu.sh` 选 6 看日志 |
| 磁力下载没速度 | 种子冷门，属正常现象；换热门种子测试 |
| 云盘挂载失败 | token 过期，后台 → 存储 → 编辑 → 重新获取令牌 |
| VPS 磁盘满 | 转存到云盘后，删除 `downloads` 文件夹里的本地文件 |
| 播放卡顿 | 见上方"播放速度说明"切换播放器 |

## 目录结构

```
yun/
├── install.sh            # 一键安装脚本（curl 调用的就是它）
├── menu.sh               # 管理菜单
├── docker-compose.yml    # AList 官方 + Aria2 一体镜像编排
├── .env.example          # 配置模板（端口）
├── data/                 # AList 数据（运行时生成）
└── downloads/            # 离线下载目录（运行时生成）
```

## 致谢

- [AList](https://github.com/alist-org/alist) — 网盘挂载与网页管理
- [aria2](https://github.com/aria2/aria2) / [P3TERX 配置](https://github.com/P3TERX/aria2.conf) — 高速下载引擎与调优配置

## 免责声明

本项目仅提供网盘挂载与下载工具的部署配置，请遵守所在地区法律法规及网盘服务条款使用。
