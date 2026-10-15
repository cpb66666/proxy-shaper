#!/bin/bash

# 读取配置文件
CONFIG_FILE="/etc/proxy-shaper.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 兜底默认值
BURST_SPEED="${BURST_SPEED:-50mbit}"
PENALTY_SPEED="${PENALTY_SPEED:-10mbit}"
BYTES_TRIGGER="${BYTES_TRIGGER:-314572800}"
PENALTY_TIMEOUT="${PENALTY_TIMEOUT:-21600}"
SET_NAME="penalty_ips"

# 智能探测当前真实出网网卡
detect_interface() {
    local candidates=($(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker[0-9]*|br-[0-9a-f]+|veth.*|wg.*|tun[0-9]*|tap[0-9]*)$'))
    
    if [ ${#candidates[@]} -le 1 ]; then
        echo "${candidates[0]:-$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)}"
        return
    fi

    local max_tx=0
    local active_iface=""
    declare -A tx_start
    for iface in "${candidates[@]}"; do
        tx_start[$iface]=$(grep "$iface:" /proc/net/dev | awk '{print $10}')
    done

    sleep 1

    for iface in "${candidates[@]}"; do
        local tx_end=$(grep "$iface:" /proc/net/dev | awk '{print $10}')
        local diff=$((tx_end - tx_start[$iface]))
        if [ $diff -gt $max_tx ]; then
            max_tx=$diff
            active_iface=$iface
        fi
    done

    if [ -z "$active_iface" ]; then
        active_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
    fi

    echo "$active_iface"
}

# 动态探测当前 SSH 端口
detect_ssh_ports() {
    local ports=$(ss -tlnp 2>/dev/null | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "${ports:-22}"
}

start() {
    IFACE=$(detect_interface)
    if [ -z "$IFACE" ]; then
        echo "错误: 未能识别到出网网卡！"
        exit 1
    fi
    SSH_PORTS=$(detect_ssh_ports)
    echo "出网网卡: $IFACE | 放行 SSH 端口: $SSH_PORTS"
    echo "当前策略: 突发 $BURST_SPEED | 惩罚 $PENALTY_SPEED | 阈值 $((BYTES_TRIGGER / 1024 / 1024))MB | 惩罚周期 $((PENALTY_TIMEOUT / 3600))小时"

    ipset create $SET_NAME hash:ip timeout "$PENALTY_TIMEOUT" -exist

    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -o "$IFACE" -j SHAPER_RULES 2>/dev/null || true
    iptables -t mangle -F SHAPER_RULES 2>/dev/null || true
    iptables -t mangle -X SHAPER_RULES 2>/dev/null || true

    tc qdisc add dev "$IFACE" root handle 1: htb default 30
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate 1000mbit
    tc class add dev "$IFACE" parent 1:1 classid 1:30 htb rate 1000mbit

    # 通道 1:10 突发
    tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate 20mbit ceil "$BURST_SPEED"
    tc qdisc add dev "$IFACE" parent 1:10 handle 10: fq_codel

    # 通道 1:20 惩罚
    tc class add dev "$IFACE" parent 1:1 classid 1:20 htb rate 2mbit ceil "$PENALTY_SPEED"
    tc qdisc add dev "$IFACE" parent 1:20 handle 20: fq_codel

    tc filter add dev "$IFACE" parent 1:0 protocol ip prio 1 handle 1 fw flowid 1:10
    tc filter add dev "$IFACE" parent 1:0 protocol ip prio 2 handle 2 fw flowid 1:20

    iptables -t mangle -N SHAPER_RULES
    iptables -t mangle -A POSTROUTING -o "$IFACE" -j SHAPER_RULES

    # 放行本地与 SSH
    iptables -t mangle -A SHAPER_RULES -d 127.0.0.1 -j RETURN
    IFS=',' read -ra P_ARR <<< "$SSH_PORTS"
    for p in "${P_ARR[@]}"; do
        [ -n "$p" ] && iptables -t mangle -A SHAPER_RULES -p tcp --sport "$p" -j RETURN
    done

    # 超过阈值加入惩罚集
    iptables -t mangle -A SHAPER_RULES -m connbytes --connbytes "$BYTES_TRIGGER": --connbytes-dir original --connbytes-mode bytes -j SET --add-set $SET_NAME dst
    iptables -t mangle -A SHAPER_RULES -m set --match-set $SET_NAME dst -j MARK --set-mark 2
    iptables -t mangle -A SHAPER_RULES -m mark --mark 0 -j MARK --set-mark 1

    echo "流控规则已成功加载！"
}

stop() {
    IFACE=$(detect_interface)
    echo "清理网卡 $IFACE 的流控规则..."
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -o "$IFACE" -j SHAPER_RULES 2>/dev/null || true
    iptables -t mangle -F SHAPER_RULES 2>/dev/null || true
    iptables -t mangle -X SHAPER_RULES 2>/dev/null || true
    ipset destroy $SET_NAME 2>/dev/null || ipset flush $SET_NAME 2>/dev/null || true
}

reset() {
    echo "手动清空限速惩罚池..."
    ipset flush $SET_NAME 2>/dev/null || true
    echo "所有受惩罚 IP 已恢复初始速度！"
}

status() {
    IFACE=$(detect_interface)
    echo "=== 出网网卡: $IFACE ==="
    echo "=== 被限速 IP 列表及解封倒计时 (秒) ==="
    ipset list $SET_NAME 2>/dev/null | grep -E '^[0-9]' || echo "当前没有被惩罚的 IP"
    echo ""
    echo "=== tc 队列与流量统计 ==="
    tc -s class show dev "$IFACE"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    reset) reset ;;
    status) status ;;
    *) echo "用法: $0 {start|stop|restart|reset|status}" ;;
esac
