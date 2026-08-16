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

get_port() {
    local p
    p=$(sed -n 's/^PORT=//p' .env 2>/dev/null | tr -d '"' | tail -1)
    echo "${p:-5244}"
}

set_env() { # $1=变量名 $2=值
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
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
    # 离线下载（Aria2）设置：镜像内置 aria2 无需密钥
    curl -s --max-time 10 -X PUT "$base/api/admin/setting/list" \
        -H "Authorization: $token" -H 'Content-Type: application/json' \
        -d '[{"key":"aria2.rpc.url","value":"http://localhost:6800/jsonrpc"},{"key":"aria2.rpc.secret","value":""},{"key":"aria2.down.dir","value":"/root/Download"}]' \
        2>/dev/null | grep -q '"code":200' && ok=1
    # 让下载目录在网页首页可见（挂载为 /downloads）
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
    local port; port=$(get_port)

    if [ "$fresh" -eq 1 ]; then
        info "开始安装（端口 $port）..."
    else
        warn "检测到已有数据，将保留原有配置，仅重建容器"
    fi
    $SUDO $DC up -d || { error "启动失败，查看日志: bash menu.sh logs"; return 1; }

    if command -v curl >/dev/null 2>&1; then
        info "等待 AList 启动..."
        local up=0
        for _ in $(seq 1 30); do
            if curl -s --connect-timeout 3 -o /dev/null "http://127.0.0.1:${port}"; then up=1; break; fi
            sleep 2
        done
        [ "$up" = "1" ] || warn "服务 60 秒内未就绪，可能仍在启动，稍后请用菜单 6 查看日志"
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
            echo -e "管理员密码: ${CYAN}${admin_pw}${PLAIN}（请截图保存，忘记可用菜单 7→2 重置）"
            info "正在自动配置离线下载..."
            if auto_configure "$admin_pw" "$port"; then
                info "离线下载已配置好，打开网页就能直接用（剩下的设置全部在网页里完成）"
            else
                print_manual_config
            fi
        else
            warn "设置密码失败，初始密码如下（请尽快登录修改）："
            $SUDO docker exec alist ./alist admin 2>/dev/null
            print_manual_config
        fi
    else
        echo "管理员密码: 你之前设置的密码（忘记可用菜单 7→2 重置）"
    fi
    echo
    echo -e "接下来：浏览器打开上面的网址 → 左下角${CYAN}登录${PLAIN} → 首页${CYAN}离线下载${PLAIN}粘贴磁力链接"
    echo -e "下载完成后在 ${CYAN}downloads${PLAIN} 文件夹里直接点击播放（不需要任何网盘）"
    warn "请确认云厂商安全组已放行 ${port} 端口"
}

do_update() {
    require_compose || return 1
    if [ -d .git ]; then
        info "拉取最新代码..."
        git pull --ff-only || warn "代码更新失败（网络原因），继续更新镜像"
    fi
    info "拉取最新镜像..."
    $SUDO $DC pull
    info "重启服务..."
    $SUDO $DC up -d --remove-orphans
    info "更新完成"
}

do_restart() {
    require_compose || return 1
    $SUDO $DC up -d && $SUDO $DC restart
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
    if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^alist$'; then
        info "alist 容器运行中"
    else
        warn "alist 容器未在运行"
    fi
    echo; info "下载目录占用:"; $SUDO du -sh "$(pwd)/downloads" 2>/dev/null || echo "  （暂无下载数据）"
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

    read -rp "是否删除数据（云盘挂载配置/下载的文件）？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO rm -rf data downloads .env
        info "数据目录与 .env 已删除"
    else
        info "保留数据目录：$(pwd)/data $(pwd)/downloads"
    fi

    read -rp "是否删除 Docker 镜像？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO docker image rm xhofe/alist-aria2:latest 2>/dev/null
        info "镜像已删除"
    fi
    info "卸载完成"
}

config_menu() {
    require_compose || return 1
    while true; do
        echo
        echo -e "${CYAN}====== 配置管理 ======${PLAIN}"
        echo " 1. 重置管理员密码（忘记密码用这个）"
        echo " 2. 修改访问端口"
        echo " 0. 返回主菜单"
        read -rp "请选择: " c
        case "$c" in
            1)
                read -rp "输入新密码: " pw
                [ -n "$pw" ] || { warn "密码不能为空"; continue; }
                $SUDO docker exec alist ./alist admin set "$pw" \
                    && info "密码已重置，用新密码登录网页即可" || error "重置失败"
                ;;
            2)
                read -rp "输入新端口 (1-65535): " port
                case "$port" in
                    ''|*[!0-9]*) warn "端口必须是数字"; continue ;;
                esac
                [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { warn "端口范围不合法"; continue; }
                set_env PORT "$port"
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
        echo -e "${CYAN}     yun 云播放器管理  (AList + Aria2)${PLAIN}"
        echo -e "${CYAN}     github.com/a317634186/yun${PLAIN}"
        echo -e "${CYAN}════════════════════════════════════════${PLAIN}"
        echo "  1. 安装（全自动，装完显示密码）"
        echo "  2. 更新"
        echo "  3. 重启/启动服务"
        echo "  4. 停止服务"
        echo "  5. 查看运行状态"
        echo "  6. 查看日志"
        echo "  7. 重置密码 / 改端口"
        echo "  8. 卸载"
        echo "  0. 退出"
        read -rp "请选择: " c
        case "$c" in
            1) do_install ;;
            2) do_update ;;
            3) do_restart ;;
            4) do_stop ;;
            5) do_status ;;
            6) do_logs ;;
            7) config_menu ;;
            8) do_uninstall ;;
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
    stop)      do_stop ;;
    status)    do_status ;;
    logs)      do_logs ;;
    config)    config_menu ;;
    uninstall) do_uninstall ;;
    menu)      main_menu ;;
    *) echo "用法: bash menu.sh [install|update|restart|stop|status|logs|config|uninstall]" ;;
esac
