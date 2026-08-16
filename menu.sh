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
    $SUDO docker info >/dev/null 2>&1 || { error "Docker 服务未运行"; return 1; }
}

gen_secret() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32; }

# 读取 .env 配置（带默认值）
get_port() {
    local p
    p=$(sed -n 's/^PORT=//p' .env 2>/dev/null | tr -d '"' | tail -1)
    echo "${p:-5244}"
}
get_secret() {
    sed -n 's/^ARIA2_RPC_SECRET=//p' .env 2>/dev/null | tr -d '"' | tail -1
}

# 写入/更新 .env 变量
set_env() { # $1=变量名 $2=值
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
}

install_docker() {
    info "未检测到 Docker，开始安装（约 1-3 分钟）..."
    if ! curl -fsSL --connect-timeout 15 https://get.docker.com | $SUDO sh; then
        warn "官方源安装失败，尝试阿里云镜像源..."
        curl -fsSL https://get.docker.com | $SUDO sh -s -- --mirror Aliyun || { error "Docker 安装失败，请手动安装后重试"; return 1; }
    fi
    command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker
}

# 通过 AList API 自动配置离线下载（Aria2）
# $1=管理员密码 $2=RPC密钥 $3=访问端口；成功返回 0
auto_configure_aria2() {
    local base="http://127.0.0.1:$3" token code
    command -v curl >/dev/null 2>&1 || return 1
    token=$(curl -s --connect-timeout 5 --max-time 10 -X POST "$base/api/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$1\"}" 2>/dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || return 1
    code=$(curl -s --connect-timeout 5 --max-time 10 -o /tmp/.yun-alist-api -w '%{http_code}' \
        -X PUT "$base/api/admin/setting/list" \
        -H "Authorization: $token" -H 'Content-Type: application/json' \
        -d "[{\"key\":\"aria2.rpc.url\",\"value\":\"http://127.0.0.1:6800/jsonrpc\"},{\"key\":\"aria2.rpc.secret\",\"value\":\"$2\"},{\"key\":\"aria2.down.dir\",\"value\":\"/opt/aria2/downloads\"}]" 2>/dev/null)
    grep -q '"code":200' /tmp/.yun-alist-api 2>/dev/null && [ "$code" = "200" ]
    local ok=$?
    rm -f /tmp/.yun-alist-api
    return "$ok"
}

print_aria2_manual() { # 手动配置兜底提示
    echo
    warn "自动配置 Aria2 未成功，请在网页后台手动配置一次："
    echo -e "  1. 登录后进入 ${CYAN}管理 → 设置 → 离线下载${PLAIN}"
    echo -e "  2. Aria2 RPC 地址: ${CYAN}http://127.0.0.1:6800/jsonrpc${PLAIN}"
    echo -e "  3. Aria2 RPC 密钥: ${CYAN}$(get_secret)${PLAIN}（保存在 .env 文件中）"
    echo -e "  4. 下载目录: ${CYAN}/opt/aria2/downloads${PLAIN}"
}

# ============ 功能 ============

do_install() {
    command -v docker >/dev/null 2>&1 || install_docker || return 1
    require_compose || return 1

    # 全新安装 or 已有数据
    local fresh=1
    [ -f data/config.db ] && fresh=0

    # 准备 .env
    [ -f .env ] || cp .env.example .env 2>/dev/null || echo "ARIA2_RPC_SECRET=" > .env
    local secret port
    secret=$(get_secret)
    if [ -z "$secret" ] || [ "$secret" = "please-change-me-to-random" ]; then
        secret=$(gen_secret)
        set_env ARIA2_RPC_SECRET "$secret"
        info "已生成随机 RPC 密钥"
    fi
    port=$(get_port)

    if [ "$fresh" -eq 1 ]; then
        info "全新安装，启动容器（端口 $port）..."
    else
        warn "检测到已有数据，将保留原有配置，仅重建容器"
        info "启动容器（端口 $port）..."
    fi
    $SUDO $DC up -d || { error "启动失败，查看日志: bash menu.sh logs"; return 1; }

    # 等待服务就绪
    if command -v curl >/dev/null 2>&1; then
        info "等待 AList 启动..."
        local up=0
        for _ in $(seq 1 30); do
            if curl -s --connect-timeout 3 -o /dev/null "http://127.0.0.1:${port}"; then up=1; break; fi
            sleep 2
        done
        [ "$up" = "1" ] || warn "服务 60 秒内未就绪，可能仍在启动，稍后请用菜单 5 查看日志"
    fi

    echo
    echo -e "${GREEN}══════════════ 安装完成 ══════════════${PLAIN}"
    local ip
    ip=$(curl -s --max-time 5 http://ifconfig.me 2>/dev/null || true)
    echo -e "访问地址: ${CYAN}http://${ip:-VPS公网IP}:${port}${PLAIN}"
    echo -e "管理员账号: ${CYAN}admin${PLAIN}"

    if [ "$fresh" -eq 1 ]; then
        # 全新安装：设置已知密码并尝试自动配置 Aria2
        local admin_pw
        admin_pw=$(gen_secret | cut -c1-16)
        if $SUDO docker exec alist ./alist admin set "$admin_pw" >/dev/null 2>&1; then
            echo -e "管理员密码: ${CYAN}${admin_pw}${PLAIN}（请记牢，也可用菜单 7→2 重置）"
            info "正在自动配置离线下载（Aria2）..."
            if auto_configure_aria2 "$admin_pw" "$secret" "$port"; then
                info "Aria2 已自动配置完成，现在就可以提交磁力链接离线下载了"
            else
                print_aria2_manual
            fi
        else
            warn "设置密码失败，初始密码如下（请尽快登录修改）："
            $SUDO docker exec alist ./alist admin 2>/dev/null || warn "请手动执行: docker exec alist ./alist admin"
            print_aria2_manual
        fi
    else
        echo "管理员密码: 你之前设置的密码（忘记可用菜单 7→2 重置）"
        warn "如后台离线下载未配置，Aria2 RPC 密钥为 .env 中的 ARIA2_RPC_SECRET"
    fi
    echo
    warn "请确认云厂商安全组已放行 ${port} 端口；并在后台 → 设置 → 站点 关闭游客访问"
}

do_update() {
    require_compose || return 1
    if [ -d .git ]; then
        info "拉取最新代码..."
        # .env 已被忽略，本地配置不会冲突；compose 文件若有本地改动则暂存
        $SUDO git stash push -u -m "yun-update-auto" -- docker-compose.yml menu.sh .env.example >/dev/null 2>&1
        git pull --ff-only || warn "代码更新失败（网络或本地改动），继续更新镜像"
        $SUDO git stash pop >/dev/null 2>&1
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
    echo; info "下载目录磁盘占用:"; $SUDO du -sh "$(pwd)/downloads" 2>/dev/null || echo "  （暂无下载数据）"
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

    read -rp "是否删除数据（AList 配置/云盘挂载/下载记录）？(y/N): " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        $SUDO rm -rf data aria2-config downloads .env
        info "数据目录与 .env 已删除"
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
                    || warn "容器未运行或获取失败（若曾修改过密码请使用选项 2 重置）"
                ;;
            2)
                read -rp "输入新密码: " pw
                [ -n "$pw" ] || { warn "密码不能为空"; continue; }
                $SUDO docker exec alist ./alist admin set "$pw" \
                    && info "密码已重置" || error "重置失败"
                ;;
            3)
                local secret
                secret=$(gen_secret)
                set_env ARIA2_RPC_SECRET "$secret"
                $SUDO $DC up -d
                echo -e "${CYAN}新 RPC 密钥: ${secret}${PLAIN}"
                read -rp "输入 AList 管理员密码可自动同步后台配置（回车跳过）: " pw
                if [ -n "$pw" ]; then
                    if auto_configure_aria2 "$pw" "$secret" "$(get_port)"; then
                        info "后台 Aria2 配置已同步"
                    else
                        warn "自动同步失败，请到 后台 → 设置 → 离线下载 手动更新 RPC 密钥"
                    fi
                fi
                ;;
            4)
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
        echo -e "${CYAN}     云播放器管理  (AList + Aria2)${PLAIN}"
        echo -e "${CYAN}     github.com/a317634186/yun${PLAIN}"
        echo -e "${CYAN}════════════════════════════════════════${PLAIN}"
        echo "  1. 安装（首次部署）"
        echo "  2. 更新（拉取最新版并重启）"
        echo "  3. 重启/启动服务"
        echo "  4. 停止服务"
        echo "  5. 查看运行状态"
        echo "  6. 查看日志"
        echo "  7. 配置管理（密码/密钥/端口）"
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
