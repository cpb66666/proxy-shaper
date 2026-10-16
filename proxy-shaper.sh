#!/bin/bash

CONFIG_FILE="/etc/proxy-shaper.conf"
STATUS_FILE="/run/proxy-shaper-status.json"

# 默认兜底配置
CHECK_INTERVAL=60          # 检查频率：每 1 分钟 (60秒)
WINDOW_MINUTES=5           # 统计窗口：向前滚动 5 分钟
THRESHOLD_MB=400           # 触发阈值：400 MB
PENALTY_SPEED="10mbit"     # 触发后限速：10 Mbps
PENALTY_HOURS=1            # 限速时长：1 小时

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

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
    [ -z "$active_iface" ] && active_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
    echo "$active_iface"
}

detect_ssh_ports() {
    local ports=$(ss -tlnp 2>/dev/null | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "${ports:-22}"
}

setup_network() {
    IFACE=$(detect_interface)
    [ -z "$IFACE" ] && { echo "错误: 未找到有效出网网卡"; exit 1; }
    SSH_PORTS=$(detect_ssh_ports)

    # 1. 初始化 tc HTB 根队列
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root handle 1: htb default 1
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit

    # 2. 初始化 nftables 统计表（增加 timeout 属性）
    nft delete table ip proxy_shaper 2>/dev/null || true
    
    local ssh_port_rules=""
    IFS=',' read -ra P_ARR <<< "$SSH_PORTS"
    for p in "${P_ARR[@]}"; do
        [ -n "$p" ] && ssh_port_rules="${ssh_port_rules}tcp dport $p return; tcp sport $p return; "
    done

    nft -f - <<EOF
table ip proxy_shaper {
    set client_traffic {
        type ipv4_addr
        flags dynamic, timeout
        timeout 5m
        counter
    }
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip saddr { 127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_port_rules
        ct state new fib daddr type local ct mark set 0x99;
        ct mark 0x99 update @client_traffic { ip saddr timeout 5m counter };
    }
    chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        ip daddr { 127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_port_rules
        ct mark 0x99 update @client_traffic { ip daddr timeout 5m counter };
    }
}
EOF
}

clean_network() {
    IFACE=$(detect_interface)
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    nft delete table ip proxy_shaper 2>/dev/null || true
    rm -f "$STATUS_FILE"
}

run_daemon() {
    setup_network
    export IFACE=$(detect_interface)
    export CHECK_INTERVAL="$CHECK_INTERVAL"
    export WINDOW_MINUTES="$WINDOW_MINUTES"
    export THRESHOLD_MB="$THRESHOLD_MB"
    export PENALTY_SPEED="$PENALTY_SPEED"
    export PENALTY_HOURS="$PENALTY_HOURS"
    export STATUS_FILE="$STATUS_FILE"

    exec python3 -u - << 'PYEOF'
import os, sys, time, json, subprocess, re

iface = os.environ.get("IFACE", "eth0")
check_interval = int(os.environ.get("CHECK_INTERVAL", 60))
window_sec = int(os.environ.get("WINDOW_MINUTES", 5)) * 60
threshold_bytes = int(os.environ.get("THRESHOLD_MB", 400)) * 1024 * 1024
penalty_speed = os.environ.get("PENALTY_SPEED", "10mbit")
penalty_duration = int(os.environ.get("PENALTY_HOURS", 1)) * 3600
status_file = os.environ.get("STATUS_FILE", "/run/proxy-shaper-status.json")

history = {}     # ip -> list of (timestamp, bytes)
penalties = {}   # ip -> {"until": timestamp, "class_id": int}
free_class_ids = set(range(100, 2000))

def run_cmd(cmd):
    return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def get_traffic():
    res = run_cmd("nft list set ip proxy_shaper client_traffic 2>/dev/null")
    if res.returncode != 0:
        return {}
    data = {}
    pattern = re.compile(r'(\d+\.\d+\.\d+\.\d+)(?:[^\n]*?)counter\s+packets\s+\d+\s+bytes\s+(\d+)')
    for match in pattern.finditer(res.stdout):
        ip = match.group(1)
        b = int(match.group(2))
        data[ip] = b
    return data

def apply_shaping(ip, class_id):
    run_cmd(f"tc class add dev {iface} parent 1: classid 1:{class_id} htb rate {penalty_speed} ceil {penalty_speed}")
    run_cmd(f"tc qdisc add dev {iface} parent 1:{class_id} handle {class_id}: fq_codel")
    run_cmd(f"tc filter add dev {iface} parent 1:0 protocol ip prio 1 u32 match ip dst {ip}/32 flowid 1:{class_id}")

def remove_shaping(ip, class_id):
    run_cmd(f"tc filter del dev {iface} parent 1:0 protocol ip prio 1 u32 match ip dst {ip}/32 flowid 1:{class_id} 2>/dev/null")
    run_cmd(f"tc qdisc del dev {iface} parent 1:{class_id} 2>/dev/null")
    run_cmd(f"tc class del dev {iface} parent 1: classid 1:{class_id} 2>/dev/null")

while True:
    now = time.time()
    current_traffic = get_traffic()
    status_list = []

    # 1. 检查已惩罚 IP 是否到期解封
    expired_ips = [ip for ip, info in penalties.items() if now >= info["until"]]
    for ip in expired_ips:
        cid = penalties[ip]["class_id"]
        remove_shaping(ip, cid)
        free_class_ids.add(cid)
        del penalties[ip]
        if ip in current_traffic:
            history[ip] = [(now, current_traffic[ip])]

    # 2. 滚动窗口更新与超量判定
    for ip, total_b in current_traffic.items():
        if ip not in history:
            history[ip] = [(now, total_b)]
        else:
            history[ip].append((now, total_b))

        # 移出超出滚动窗口 (5分钟) 的旧采样
        history[ip] = [entry for entry in history[ip] if now - entry[0] <= window_sec]

        oldest_b = history[ip][0][1]
        delta_b = total_b - oldest_b

        # 触发限速
        if delta_b >= threshold_bytes and ip not in penalties:
            if free_class_ids:
                cid = free_class_ids.pop()
                penalties[ip] = {"until": now + penalty_duration, "class_id": cid}
                apply_shaping(ip, cid)

        is_penalized = ip in penalties
        rem = int(penalties[ip]["until"] - now) if is_penalized else 0
        
        # 仅将有实际流量（>= 0.05MB）或当前正在被限速的 IP 写入展示文件
        mb_delta = round(delta_b / 1024 / 1024, 2)
        if mb_delta >= 0.05 or is_penalized:
            status_list.append({
                "ip": ip,
                "window_mb": mb_delta,
                "is_penalized": is_penalized,
                "remaining_sec": rem
            })

    # 3. 及时清理在 nftables 中已超时被销毁且不在惩罚名单中的 IP 历史
    inactive_ips = [ip for ip in list(history.keys()) if ip not in current_traffic and ip not in penalties]
    for ip in inactive_ips:
        del history[ip]

    # 保存快照供 status 查看
    try:
        with open(status_file, "w") as f:
            json.dump({
                "iface": iface,
                "window_min": int(window_sec / 60),
                "threshold_mb": int(threshold_bytes / 1024 / 1024),
                "penalty_speed": penalty_speed,
                "penalty_hours": int(penalty_duration / 3600),
                "clients": status_list
            }, f)
    except Exception:
        pass

    time.sleep(check_interval)
PYEOF
}

show_status() {
    if [ ! -f "$STATUS_FILE" ]; then
        echo "限速监控服务正在启动中或暂无活跃流量数据，请等待 1 分钟后重试。"
        exit 0
    fi
    python3 - << 'PYEOF'
import json, os

try:
    with open("/run/proxy-shaper-status.json") as f:
        data = json.load(f)
except Exception:
    print("读取状态快照失败！")
    exit(0)

print("=" * 80)
print(f" 网卡: {data['iface']} | 统计窗口: {data['window_min']}分钟 | 触发阈值: {data['threshold_mb']}MB | 限速: {data['penalty_speed']} | 惩罚时长: {data['penalty_hours']}小时")
print("=" * 80)
print(f"{'客户端 IP':<20} {'5分钟总流量(上行+下行)':<26} {'当前状态':<18} {'剩余限速时间'}")
print("-" * 80)

clients = data.get("clients", [])
if not clients:
    print("当前暂无活跃连接或所有扫描探测流量均低于 0.05MB。")
else:
    for c in clients:
        status_str = f"已限速 ({data['penalty_speed']})" if c["is_penalized"] else "正常 (全速)"
        rem_str = f"{c['remaining_sec'] // 60}分{c['remaining_sec'] % 60}秒" if c["is_penalized"] else "-"
        print(f"{c['ip']:<20} {str(c['window_mb']) + ' MB':<26} {status_str:<18} {rem_str}")
print("=" * 80)
PYEOF
}

manual_reset() {
    echo "正在重置所有限速并清空历史状态..."
    systemctl restart proxy-shaper.service
    echo "全部 IP 已恢复正常全速，统计窗口已重置！"
}

case "$1" in
    daemon) run_daemon ;;
    start) systemctl start proxy-shaper.service ;;
    stop) clean_network ;;
    restart) systemctl restart proxy-shaper.service ;;
    reset) manual_reset ;;
    status) show_status ;;
    *) echo "用法: $0 {start|stop|restart|reset|status|daemon}" ;;
esac
