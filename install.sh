#!/bin/bash
set -e

# ================= GitHub 配置 =================
GITHUB_USER="cpb66666"
GITHUB_REPO="proxy-shaper"
BRANCH="main"
# ===============================================

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}"
CONFIG_FILE="/etc/proxy-shaper.conf"
BIN_FILE="/usr/local/bin/proxy-shaper.sh"
SERVICE_FILE="/etc/systemd/system/proxy-shaper.service"

exec < /dev/tty

if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本！"
    exit 1
fi

install_dependencies() {
    echo "正在检查并安装系统依赖 (nftables, iproute2, python3, curl)..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y nftables iproute2 python3 curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y nftables iproute python3 curl
    fi
}

pull_shaper_script() {
    echo "获取核心控制脚本..."
    if [ -f "./proxy-shaper.sh" ]; then
        cp ./proxy-shaper.sh "$BIN_FILE"
    else
        curl -fsSL "${RAW_URL}/proxy-shaper.sh" -o "$BIN_FILE"
    fi
    chmod +x "$BIN_FILE"
}

setup_systemd() {
    cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=Rolling Window Per-IP Proxy Shaper Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/proxy-shaper.sh daemon
ExecStop=/usr/local/bin/proxy-shaper.sh stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable proxy-shaper.service
    systemctl restart proxy-shaper.service
}

install_plan1() {
    echo "--------------------------------------------------"
    echo "应用默认参数 1:"
    echo " - 检查频率: 每 1 分钟"
    echo " - 统计窗口: 向前滚动 5 分钟"
    echo " - 正常带宽: 10 Mbps"
    echo " - 触发阈值: 400 MB / 5 分钟 (上行+下行合并)"
    echo " - 触发限速: 10 Mbps"
    echo " - 限速时长: 1 小时 (到期恢复全速继续滚动)"
    echo "--------------------------------------------------"
    install_dependencies
    pull_shaper_script

    cat <<EOF > "$CONFIG_FILE"
CHECK_INTERVAL=60
WINDOW_MINUTES=5
THRESHOLD_MB=400
PENALTY_SPEED="10mbit"
PENALTY_HOURS=1
EOF

    setup_systemd
    echo "默认方案 1 安装成功并已后台启动！"
}

install_plan2() {
    echo "--------------------------------------------------"
    echo "应用默认参数 2:"
    echo " - 检查频率: 每 1 分钟"
    echo " - 统计窗口: 向前滚动 5 分钟"
    echo " - 正常带宽: 20 Mbps"
    echo " - 触发阈值: 800 MB / 5 分钟 (上行+下行合并)"
    echo " - 触发限速: 20 Mbps"
    echo " - 限速时长: 1 小时 (到期恢复全速继续滚动)"
    echo "--------------------------------------------------"
    install_dependencies
    pull_shaper_script

    cat <<EOF > "$CONFIG_FILE"
CHECK_INTERVAL=60
WINDOW_MINUTES=5
THRESHOLD_MB=800
PENALTY_SPEED="20mbit"
PENALTY_HOURS=1
EOF

    setup_systemd
    echo "默认方案 2 安装成功并已后台启动！"
}

install_custom() {
    echo "--------------------------------------------------"
    echo " 配置自定义滚动限速参数 (直接回车保留默认值)"
    echo "--------------------------------------------------"
    
    read -p "1. 触发阈值流量 (单位: MB / 5分钟) [默认 400]: " in_mb
    in_mb=${in_mb:-400}

    read -p "2. 触发惩罚后限速带宽 (单位: Mbps) [默认 10]: " in_speed
    in_speed=${in_speed:-10}

    read -p "3. 限速持续时长 (单位: 小时) [默认 1]: " in_hours
    in_hours=${in_hours:-1}

    read -p "4. 统计滚动窗口 (单位: 分钟) [默认 5]: " in_win
    in_win=${in_win:-5}

    echo "--------------------------------------------------"
    echo "确认配置: 滚动 ${in_win}分钟 | 阈值 ${in_mb}MB | 限速 ${in_speed}Mbps | 惩罚 ${in_hours}小时"
    echo "--------------------------------------------------"

    install_dependencies
    pull_shaper_script

    cat <<EOF > "$CONFIG_FILE"
CHECK_INTERVAL=60
WINDOW_MINUTES=$in_win
THRESHOLD_MB=$in_mb
PENALTY_SPEED="${in_speed}mbit"
PENALTY_HOURS=$in_hours
EOF

    setup_systemd
    echo "自定义配置安装成功并已启动！"
}

uninstall() {
    echo "正在卸载服务并清理所有网络规则..."
    systemctl stop proxy-shaper.service 2>/dev/null || true
    systemctl disable proxy-shaper.service 2>/dev/null || true
    if [ -f "$BIN_FILE" ]; then
        "$BIN_FILE" stop 2>/dev/null || true
    fi
    rm -f "$SERVICE_FILE" "$BIN_FILE" "$CONFIG_FILE" "/run/proxy-shaper-status.json"
    systemctl daemon-reload
    echo "服务已彻底卸载，网络流控已完全恢复原速！"
}

show_status() {
    if [ -f "$BIN_FILE" ]; then
        "$BIN_FILE" status
    else
        echo "限速服务尚未安装！"
    fi
}

manual_reset() {
    if [ -f "$BIN_FILE" ]; then
        "$BIN_FILE" reset
    else
        echo "限速服务尚未安装！"
    fi
}

show_menu() {
    clear
    echo "=================================================="
    echo "       Linux 单 IP 滚动窗口动态限速管理面板       "
    echo "=================================================="
    echo " 1. 安装/切换 默认方案 1 (10M基准: 5分钟超400M限速10M 1小时)"
    echo " 2. 安装/切换 默认方案 2 (20M基准: 5分钟超800M限速20M 1小时)"
    echo " 3. 安装/切换 自定义参数 (自定义窗口/阈值/限速/时长)"
    echo " 4. 查看当前实时流量统计与被限速 IP"
    echo " 5. 手动重置所有处于惩罚状态的 IP"
    echo " 6. 卸载限速服务 (清除所有规则恢复原速)"
    echo " 0. 退出菜单"
    echo "=================================================="
    read -p "请输入选项 [0-6]: " choice

    case "$choice" in
        1) install_plan1 ;;
        2) install_plan2 ;;
        3) install_custom ;;
        4) show_status ;;
        5) manual_reset ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0-6" ;;
    esac
}

show_menu
