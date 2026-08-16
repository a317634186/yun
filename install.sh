#!/usr/bin/env bash
# yun 云播放器一键安装脚本（小白版）
# 用法：curl -fsSL https://raw.githubusercontent.com/a317634186/yun/main/install.sh | bash
set -e

DIR="$HOME/yun"
REPO="https://github.com/a317634186/yun"

# 确保有 git
if ! command -v git >/dev/null 2>&1; then
    echo "[信息] 安装 git..."
    (apt-get update -y && apt-get install -y git) || yum install -y git || {
        echo "[错误] git 安装失败，请手动安装后重试"; exit 1; }
fi

# 获取/更新项目
if [ -d "$DIR/.git" ]; then
    echo "[信息] 更新项目..."
    git -C "$DIR" pull --ff-only || echo "[警告] 代码更新失败，使用本地版本继续"
else
    rm -rf "$DIR"
    echo "[信息] 下载项目..."
    git clone "$REPO" "$DIR"
fi

# 执行安装（全自动，无需任何输入）
bash "$DIR/menu.sh" install
