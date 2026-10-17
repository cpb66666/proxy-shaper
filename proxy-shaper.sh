#!/bin/bash

CONFIG_FILE="/etc/proxy-shaper.conf"
STATUS_FILE="/run/proxy-shaper-status.json"

# 默认配置
CHECK_INTERVAL=60          # 检查频率：每 1 分钟 (60秒)
WINDOW_MINUTES=5            # 统计窗口：向前滚动 5 分钟
THRESHOLD_MB=400            # 触发阈值：400 MB
PENALTY_SPEED="10mbit"      # 每个受罚 IP 的独立限速上限：10 Mbps
PENALTY_HOURS=1             # 限速时长：1 小时

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

    # 1. 初始化 tc HTB 队列与独立限速桶 (256个独立槽位)
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root handle 1: htb default 1
    # 默认通道 1:1 (正常流量全速 1000M)
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit

    # 创建 256 个独立的惩罚通道 (1:100 ~ 1:355)，每个通道独占 PENALTY_SPEED
    for i in $(seq 0 255); do
        local cid=$((100 + i))
        local mark_hex=$(printf "0x%x" $cid)
        tc class add dev "$IFACE" parent 1: classid "1:$cid" htb rate 2mbit ceil "$PENALTY_SPEED"
        tc qdisc add dev "$IFACE" parent "1:$cid" handle "$cid:" fq_codel
        tc filter add dev "$IFACE" parent 1:0 protocol ip prio 1 handle "$mark_hex" fw flowid "1:$cid"
    done

    # 2. 初始化 nftables 统计与打标表
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
        timeout 30m
        counter
    }
    set penalty_set {
        type ipv4_addr
        flags dynamic
    }
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip saddr { 127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_port_rules
        update @client_traffic { ip saddr timeout 30m counter }
    }
    chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        ip daddr { 127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_port_rules
        update @client_traffic { ip daddr timeout 30m counter }
        # 命中受罚列表：基于 IP 哈希映射到 100~355 之间的标记，导入独立限速通道
        ip daddr @penalty_set meta mark set (jhash ip daddr mod 256) + 100
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
import os, sys, time, json, subprocess

iface = os.environ.get("IFACE", "eth0")
check_interval = int(os.environ.get("CHECK_INTERVAL", 60))
window_sec = int(os.environ.get("WINDOW_MINUTES", 5)) * 60
threshold_bytes = int(os.environ.get("THRESHOLD_MB", 400)) * 1024 * 1024
penalty_speed = os.environ.get("PENALTY_SPEED", "10mbit")
penalty_duration = int(os.environ.get("PENALTY_HOURS", 1)) * 3600
status_file = os.environ.get("STATUS_FILE", "/run/proxy-shaper-status.json")

history = {}     # ip -> list of [timestamp, bytes]
penalties = {}   # ip -> expire_timestamp
last_sample = {} # ip -> [last_time, last_bytes]

def run_cmd(cmd):
    return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def get_traffic():
    # 使用 nft 原生 JSON 解析，极大提高解析性能并降低 CPU 开销
    res = run_cmd("nft -j list set ip proxy_shaper client_traffic 2>/dev/null")
    if res.returncode != 0 or not res.stdout.strip():
        return {}
    data = {}
    try:
        nft_json = json.loads(res.stdout)
        for item in nft_json.get("nftables", []):
            if "set" in item:
                elements = item["set"].get("elem", [])
                for elem in elements:
                    if isinstance(elem, dict) and "elem" in elem:
                        val = elem["elem"].get("val")
                        b = elem["elem"].get("counter", {}).get("bytes", 0)
                        if val:
                            data[val] = b
                    elif isinstance(elem, str):
                        data[elem] = 0
    except Exception:
        pass
    return data

def sync_nft_penalty(ip_list):
    run_cmd("nft flush set ip proxy_shaper penalty_set 2>/dev/null")
    if ip_list:
        elements = ",".join(ip_list)
        run_cmd(f"nft add element ip proxy_shaper penalty_set {{ {elements} }} 2>/dev/null")

while True:
    now = time.time()
    current_traffic = get_traffic()
    status_list = []
    penalties_changed = False

    # 1. 检查并清理过期的惩罚 IP
    expired_ips = [ip for ip, exp_time in penalties.items() if now >= exp_time]
    for ip in expired_ips:
        del penalties[ip]
        penalties_changed = True
        if ip in current_traffic:
            history[ip] = [[now, current_traffic[ip]]]

    # 2. 遍历流量，滚动窗口计算
    for ip, total_b in current_traffic.items():
        cur_rate_mbps = 0.0
        if ip in last_sample:
            dt = now - last_sample[ip][0]
            db = total_b - last_sample[ip][1]
            if dt > 0 and db >= 0:
                cur_rate_mbps = round((db * 8) / (dt * 1000 * 1000), 2)
        last_sample[ip] = [now, total_b]

        if ip not in history:
            history[ip] = [[now, total_b]]
        else:
            history[ip].append([now, total_b])

        cutoff = now - window_sec
        history[ip] = [pt for pt in history[ip] if pt[0] >= cutoff]

        if len(history[ip]) == 1:
            delta_b = 0
        else:
            oldest_b = history[ip][0][1]
            delta_b = max(0, total_b - oldest_b)

        # 触发惩罚判定
        if delta_b >= threshold_bytes and ip not in penalties:
            penalties[ip] = now + penalty_duration
            penalties_changed = True

        is_penalized = ip in penalties
        rem = int(penalties[ip] - now) if is_penalized else 0
        window_mb = round(delta_b / 1024 / 1024, 2)

        if window_mb >= 1.0 or is_penalized:
            status_list.append({
                "ip": ip,
                "window_mb": window_mb,
                "cur_rate_mbps": cur_rate_mbps,
                "is_penalized": is_penalized,
                "remaining_sec": rem
            })

    # 同步状态到 nftables 集合
    if penalties_changed:
        sync_nft_penalty(list(penalties.keys()))

    # 按 5 分钟流量倒序排序
    status_list.sort(key=lambda x: x["window_mb"], reverse=True)

    # 3. 内存回收：清理由于内核 30m timeout 超时已不在当前流量统计中且未受罚的 IP
    current_ips = set(current_traffic.keys())
    inactive_ips = [ip for ip in list(history.keys()) if ip not in current_ips and ip not in penalties]
    for ip in inactive_ips:
        history.pop(ip, None)
        last_sample.pop(ip, None)

    # 4. 导出快照
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
        echo "限速监控服务正在启动中或暂无流量数据，请稍等几十秒后再试。"
        exit 0
    fi
    python3 - << 'PYEOF'
import json

try:
    with open("/run/proxy-shaper-status.json") as f:
        data = json.load(f)
except Exception:
    print("读取状态快照失败！")
    exit(0)

print("=" * 88)
print(f" 网卡: {data['iface']} | 统计窗口: {data['window_min']}分钟 | 触发阈值: {data['threshold_mb']}MB | 独立限速: {data['penalty_speed']} | 惩罚时长: {data['penalty_hours']}小时")
print("=" * 88)
print(f"{'客户端 IP':<18} {'5分钟总流量':<16} {'实时速率':<14} {'当前状态':<18} {'剩余限速时间'}")
print("-" * 88)

clients = data.get("clients", [])
if not clients:
    print("当前暂无活跃流量记录 (已自动过滤 < 1.0 MB 的空闲 IP)。")
else:
    for c in clients:
        status_str = f"已限速 ({data['penalty_speed']})" if c["is_penalized"] else "正常 (全速)"
        rem_str = f"{c['remaining_sec'] // 60}分{c['remaining_sec'] % 60}秒" if c["is_penalized"] else "-"
        rate_str = f"{c.get('cur_rate_mbps', 0.0)} Mbps"
        print(f"{c['ip']:<18} {str(c['window_mb']) + ' MB':<16} {rate_str:<14} {status_str:<18} {rem_str}")
print("=" * 88)
PYEOF
}

manual_reset() {
    echo "正在重置所有限速并清空历史状态..."
    nft flush set ip proxy_shaper penalty_set 2>/dev/null || true
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
