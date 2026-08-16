#!/usr/bin/env bash
# 云播放器管理菜单（AList + Aria2）
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
}

container_running() {
    $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^alist$'
}

gen_secret() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32
}

# ============ 功能 ============

do_install() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "未检测到 Docker，开始自动安装（约 1-3 分钟）..."
        curl -fsSL https://get.docker.com | $SUDO sh
        $SUDO systemctl enable --now docker
    fi
    require_compose || return 1

    # 首次安装生成随机 RPC 密钥
    if grep -q "please-change-me-to-random" .env 2>/dev/null; then
        local secret; secret=$(gen_secret)
        sed -i "s/^ARIA2_RPC_SECRET=.*/ARIA2_RPC_SECRET=${secret}/" .env
        info "已生成随机 RPC 密钥并写入 .env"
    fi

    info "启动容器..."
    $SUDO $DC up -d

    # 等待服务就绪
    if command -v curl >/dev/null 2>&1; then
        info "等待 AList 启动..."
        for _ in $(seq 1 30); do
            curl -s -o /dev/null http://127.0.0.1:5244 && break
            sleep 2
        done
    fi

    echo
    info "安装完成！管理员账号：admin"
    echo -e "${CYAN}初始密码：${PLAIN}"
    $SUDO docker exec alist ./alist admin 2>/dev/null || warn "获取密码失败，请执行: docker exec alist ./alist admin"
    echo
    echo -e "访问地址: ${CYAN}http://$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo 'VPS公网IP'):5244${PLAIN}"
    warn "请记得在云厂商安全组放行 5244 端口，并尽快登录后台修改密码"
}

do_update() {
    require_compose || return 1
    if [ -d .git ]; then
        info "拉取最新代码..."
        git pull --ff-only || warn "代码更新失败（本地有改动？），继续更新镜像"
    fi
    info "拉取最新镜像..."
    $SUDO $DC pull
    info "重启服务..."
    $SUDO $DC up -d --remove-orphans
    info "更新完成"
}

do_restart() {
    require_compose || return 1
    $SUDO $DC restart
    info "已重启"
}

do_status() {
    require_compose || return 1
    $SUDO $DC ps
    if container_running; then
        info "运行中，已运行时长: $($SUDO docker exec alist uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F', ' '{print $1}')"
    else
        warn "alist 容器未在运行"
    fi
    echo; info "磁盘占用:"; $SUDO docker system df 2>/dev/null | head -5
}

do_logs() {
    require_compose || return 1
    $SUDO $DC logs --tail=100 alist
}

do_uninstall() {
    require_compose || return 1
    warn "将停止并删除容器"
    read -rp "确认卸载？(y/N): " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { info "已取消"; return 0; }
    $SUDO $DC down

    read -rp "是否删除数据（配置/下载记录）？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        rm -rf data aria2-config downloads
        info "数据目录已删除"
    else
        info "保留数据目录：$(pwd)/data $(pwd)/downloads"
    fi

    read -rp "是否删除 Docker 镜像？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO docker image rm alicion/alist-aria2:latest 2>/dev/null
        info "镜像已删除"
    fi
    info "卸载完成"
}

config_menu() {
    require_compose || return 1
    while true; do
        echo
        echo -e "${CYAN}====== 配置管理 ======${PLAIN}"
        echo " 1. 查看管理员初始密码"
        echo " 2. 重置管理员密码"
        echo " 3. 重新生成 RPC 密钥"
        echo " 4. 修改访问端口"
        echo " 0. 返回主菜单"
        read -rp "请选择: " c
        case "$c" in
            1)
                $SUDO docker exec alist ./alist admin 2>/dev/null \
                    || warn "容器未运行或获取失败"
                ;;
            2)
                read -rp "输入新密码: " pw
                [ -n "$pw" ] || { warn "密码不能为空"; continue; }
                $SUDO docker exec alist ./alist admin set "$pw" \
                    && info "密码已重置" || error "重置失败"
                ;;
            3)
                local secret; secret=$(gen_secret)
                sed -i "s/^ARIA2_RPC_SECRET=.*/ARIA2_RPC_SECRET=${secret}/" .env
                $SUDO $DC up -d
                echo -e "${CYAN}新 RPC 密钥: ${secret}${PLAIN}"
                warn "请同步修改 AList 后台 → 设置 → 离线下载 → Aria2 RPC 密钥"
                ;;
            4)
                read -rp "输入新端口 (1-65535): " port
                case "$port" in
                    ''|*[!0-9]*) warn "端口必须是数字"; continue ;;
                esac
                [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { warn "端口范围不合法"; continue; }
                sed -i -E "s/- \"[0-9]+:5244\"/- \"${port}:5244\"/" docker-compose.yml
                $SUDO $DC up -d
                info "已改为端口 ${port}，请放行安全组后访问 http://VPS公网IP:${port}"
                ;;
            0|*) return 0 ;;
        esac
    done
}

main_menu() {
    while true; do
        echo
        echo -e "${CYAN}════════════════════════════════════════${PLAIN}"
        echo -e "${CYAN}     云播放器管理  (AList + Aria2)${PLAIN}"
        echo -e "${CYAN}     github.com/a317634186/yun${PLAIN}"
        echo -e "${CYAN}════════════════════════════════════════${PLAIN}"
        echo "  1. 安装（首次部署）"
        echo "  2. 更新（拉取最新版并重启）"
        echo "  3. 重启服务"
        echo "  4. 查看运行状态"
        echo "  5. 查看日志"
        echo "  6. 配置管理（密码/密钥/端口）"
        echo "  7. 卸载"
        echo "  0. 退出"
        read -rp "请选择: " c
        case "$c" in
            1) do_install ;;
            2) do_update ;;
            3) do_restart ;;
            4) do_status ;;
            5) do_logs ;;
            6) config_menu ;;
            7) do_uninstall ;;
            0|*) exit 0 ;;
        esac
        echo
        read -rp "按回车返回菜单..." _
    done
}

case "${1:-menu}" in
    install)   do_install ;;
    update)    do_update ;;
    restart)   do_restart ;;
    status)    do_status ;;
    logs)      do_logs ;;
    config)    config_menu ;;
    uninstall) do_uninstall ;;
    menu)      main_menu ;;
    *) echo "用法: bash menu.sh [install|update|restart|status|logs|config|uninstall]" ;;
esac
