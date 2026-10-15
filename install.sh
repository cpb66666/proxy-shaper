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

# 确保在通过管道 curl ... | bash 调用时仍可正常交互输入
exec < /dev/tty

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本！"
    exit 1
fi

install_dependencies() {
    echo "正在检查并安装系统依赖 (ipset, iproute2, iptables, curl)..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y ipset iproute2 iptables curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y ipset iproute iptables curl
    fi
}

pull_shaper_script() {
    echo "正在获取核心限速脚本..."
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
Description=Auto-detect Interface Per-IP Proxy Shaper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/proxy-shaper.sh start
ExecStop=/usr/local/bin/proxy-shaper.sh stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable proxy-shaper.service
    systemctl restart proxy-shaper.service
}

install_default() {
    echo "--------------------------------------------------"
    echo "应用默认策略: 突发 50M | 惩罚 10M | 阈值 300MB | 周期 6小时"
    echo "--------------------------------------------------"
    install_dependencies
    pull_shaper_script

    cat <<EOF > "$CONFIG_FILE"
BURST_SPEED="50mbit"
PENALTY_SPEED="10mbit"
BYTES_TRIGGER="314572800"
PENALTY_TIMEOUT="21600"
EOF

    setup_systemd
    echo "安装成功并已启动！"
    "$BIN_FILE" status
}

install_custom() {
    echo "--------------------------------------------------"
    echo " 配置自定义限速参数 (直接回车保留默认值)"
    echo "--------------------------------------------------"
    
    read -p "1. 正常/突发峰值速度 (单位: Mbps) [默认 50]: " in_burst
    in_burst=${in_burst:-50}
    BURST_SPEED="${in_burst}mbit"

    read -p "2. 长期高占用惩罚速度 (单位: Mbps) [默认 10]: " in_penalty
    in_penalty=${in_penalty:-10}
    PENALTY_SPEED="${in_penalty}mbit"

    read -p "3. 触发惩罚的连接流量阈值 (单位: MB) [默认 300]: " in_mb
    in_mb=${in_mb:-300}
    BYTES_TRIGGER=$((in_mb * 1024 * 1024))

    read -p "4. 惩罚状态持续/重置时间 (单位: 小时) [默认 6]: " in_hours
    in_hours=${in_hours:-6}
    PENALTY_TIMEOUT=$((in_hours * 3600))

    echo "--------------------------------------------------"
    echo "确认配置: 突发 ${BURST_SPEED} | 惩罚 ${PENALTY_SPEED} | 阈值 ${in_mb}MB | 冷却 ${in_hours}小时"
    echo "--------------------------------------------------"

    install_dependencies
    pull_shaper_script

    cat <<EOF > "$CONFIG_FILE"
BURST_SPEED="$BURST_SPEED"
PENALTY_SPEED="$PENALTY_SPEED"
BYTES_TRIGGER="$BYTES_TRIGGER"
PENALTY_TIMEOUT="$PENALTY_TIMEOUT"
EOF

    setup_systemd
    echo "自定义配置安装完成并已启动！"
    "$BIN_FILE" status
}

uninstall() {
    echo "正在卸载限速服务并清除全部网络规则..."
    if [ -f "$BIN_FILE" ]; then
        "$BIN_FILE" stop 2>/dev/null || true
    fi
    systemctl stop proxy-shaper.service 2>/dev/null || true
    systemctl disable proxy-shaper.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN_FILE" "$CONFIG_FILE"
    systemctl daemon-reload
    echo "服务已完全卸载，网络流控规则已全部清除恢复原速！"
}

show_status() {
    if [ -f "$BIN_FILE" ]; then
        "$BIN_FILE" status
    else
        echo "限速服务尚未安装！"
    fi
}

show_menu() {
    clear
    echo "=================================================="
    echo "          Linux 单 IP 代理限速管理面板            "
    echo "=================================================="
    echo " 1. 安装/更新 默认限速 (突发50M/惩罚10M/300MB/6小时)"
    echo " 2. 安装/更新 自定义限速 (自定义各项参数)"
    echo " 3. 卸载限速服务 (清理规则并恢复原速)"
    echo " 4. 查看当前限速状态与在线惩罚 IP"
    echo " 5. 手动重置所有处于惩罚状态的 IP"
    echo " 0. 退出菜单"
    echo "=================================================="
    read -p "请输入选项 [0-5]: " choice

    case "$choice" in
        1) install_default ;;
        2) install_custom ;;
        3) uninstall ;;
        4) show_status ;;
        5) 
            [ -f "$BIN_FILE" ] && "$BIN_FILE" reset || echo "服务未安装！"
            ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0-5" ;;
    esac
}

show_menu
