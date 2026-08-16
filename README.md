# yun · 云播放器

粘贴磁力链接 → 云端下载 → 网页直接播放。

**界面就三样东西：一个链接输入口、一个播放器、一份播放记录。** 不需要任何网盘账号，文件存在 VPS 硬盘上，下载完点开就看。基于 [AList](https://github.com/alist-org/alist) + Aria2 + 自带极简前端页，Docker 一键部署。

## 使用就三步

### 第 1 步 · 安装（VPS 上执行一条命令）

```bash
curl -fsSL https://raw.githubusercontent.com/a317634186/yun/main/install.sh | bash
```

全自动，不用输入任何东西。装完屏幕上会显示**网址、账号 admin、密码**，截图保存。

> 记得在云服务器控制台的**安全组**放行 `5244` 端口，否则网页打不开。
> 提示 `Could not resolve host`（DNS 问题）先执行：
> ```bash
> systemctl disable --now systemd-resolved 2>/dev/null; rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
> ```

### 第 2 步 · 打开网页，输入密码

浏览器打开 `http://你的VPS_IP:5244`，就是登录页：账号 `admin` + 安装时显示的密码（浏览器会记住，下次自动登录）。

### 第 3 步 · 粘链接 → 等下载 → 直接看

1. 顶部输入框**粘贴磁力链接**（`magnet:?xt=...` 或 .torrent 文件的下载链接）→ 点「添加下载」
2. 「下载列表」实时显示进度条（内置高速下载：64 分片、16 连接、自动 tracker）
3. 下载完成出现在「已完成文件」，**点击直接播放**（mp4/webm/mkv）
4. 「播放记录」自动记录看到哪了，下次点击**从上次位置继续**；看完的标 ✅

## 存储与流量说明

- 容量上限 = VPS 硬盘大小（`df -h /root` 查看），看完在列表里点删除即可
- **播放走 VPS 流量**：看 10GB 电影约耗 10GB 流量，注意流量配额

## 可选功能

- **挂载网盘扩容**：VPS 磁盘不够时，访问 `http://IP:5244/@login` 打开原版 AList 管理后台 → 存储 → 添加 OneDrive / Google Drive，把文件转存到云盘长期保存（云盘里的视频也是直接点开播放）
- **多文件种子**：下载后的文件夹目前需在原版后台（`/@login`）里进入播放单个视频

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
| 登录一直转圈/失败 | 用 `bash menu.sh` 选 7→1 重置密码后重试 |
| 磁力下载没速度 | 种子冷门，属正常现象；换热门种子测试 |
| VPS 磁盘满 | 网页里删除看完的文件，或挂载网盘转存 |
| 播放卡顿 | 刷新重试；确认 VPS 带宽是否被跑满 |

## 目录结构

```
yun/
├── install.sh            # 一键安装脚本
├── menu.sh               # 管理菜单
├── web/index.html        # 播放器前端页面（输入框+播放器+记录）
├── nginx.conf            # 前端页面 + 接口/视频反代配置
├── docker-compose.yml    # alist + web 两个容器编排
├── .env.example          # 配置模板（端口）
├── data/                 # AList 数据（运行时生成）
└── downloads/            # 下载存放目录（运行时生成）
```

## 致谢

- [AList](https://github.com/alist-org/alist) — 后端 API 与文件服务
- [aria2](https://github.com/aria2/aria2) / [P3TERX 配置](https://github.com/P3TERX/aria2.conf) — 高速下载引擎与调优配置
- [nginx](https://nginx.org) — 前端承载与反代

## 免责声明

本项目仅提供下载与播放工具的部署配置，请遵守所在地区法律法规使用。
