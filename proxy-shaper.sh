#!/bin/bash

CONFIG_FILE="/etc/proxy-shaper.conf"
STATUS_FILE="/run/proxy-shaper-status.json"
IFB_DEV="ifb0"

# 默认配置
CHECK_INTERVAL=60          # 检查频率：每 1 分钟 (60秒)
WINDOW_MINUTES=5           # 统计窗口：向前滚动 5 分钟
THRESHOLD_MB=400           # 触发阈值：400 MB
PENALTY_SPEED="10mbit"     # 每个受罚 IP 独立上限：10 Mbps
PENALTY_HOURS=1            # 限速时长：1 小时

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

detect_interface() {
    local candidates=($(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|ifb[0-9]*|docker[0-9]*|br-[0-9a-f]+|veth.*|wg.*|tun[0-9]*|tap[0-9]*)$'))
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

    # 0. 关闭网卡硬件分载 (防止 50KB+ 巨型聚合包冲破 TC 令牌桶)
    ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true

    # 1. 初始化物理网卡 tc HTB 根队列 (控制出站/客户端下载)
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root handle 1: htb default 1
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit

    # 2. 初始化 IFB 虚拟网卡队列 (控制入站/客户端上传)
    modprobe ifb numifbs=1 2>/dev/null || true
    ip link set dev "$IFB_DEV" up 2>/dev/null || true

    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    tc qdisc add dev "$IFACE" handle ffff: ingress
    tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV"

    tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
    tc qdisc add dev "$IFB_DEV" root handle 1: htb default 1
    tc class add dev "$IFB_DEV" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit

    # 3. 初始化 nftables 统计表 (基于 ct direction 仅统计外部连入的真实客户端 IP)
    nft delete table ip proxy_shaper 2>/dev/null || true

    local ssh_in_rules=""
    local ssh_out_rules=""
    IFS=',' read -ra P_ARR <<< "$SSH_PORTS"
    for p in "${P_ARR[@]}"; do
        if [ -n "$p" ]; then
            ssh_in_rules="${ssh_in_rules}tcp dport $p return; "
            ssh_out_rules="${ssh_out_rules}tcp sport $p return; "
        fi
    done

    nft -f - <<EOF
table ip proxy_shaper {
    set client_traffic {
        type ipv4_addr
        flags dynamic, timeout
        timeout 30m
        counter
    }

    chain input {
        type filter hook input priority mangle; policy accept;
        ip saddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_in_rules
        ct direction original update @client_traffic { ip saddr counter }
    }

    chain output {
        type filter hook output priority mangle; policy accept;
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return;
        $ssh_out_rules
        ct direction reply update @client_traffic { ip daddr counter }
    }
}
EOF
}

clean_network() {
    IFACE=$(detect_interface)
    if [ -n "$IFACE" ]; then
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
        ethtool -K "$IFACE" tso on gso on gro on 2>/dev/null || true
    fi
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
    ip link set dev "$IFB_DEV" down 2>/dev/null || true
    nft delete table ip proxy_shaper 2>/dev/null || true
    rm -f "$STATUS_FILE"
}

run_daemon() {
    setup_network
    export IFACE=$(detect_interface)
    export IFB_DEV="$IFB_DEV"
    export CHECK_INTERVAL="$CHECK_INTERVAL"
    export WINDOW_MINUTES="$WINDOW_MINUTES"
    export THRESHOLD_MB="$THRESHOLD_MB"
    export PENALTY_SPEED="$PENALTY_SPEED"
    export PENALTY_HOURS="$PENALTY_HOURS"
    export STATUS_FILE="$STATUS_FILE"

    exec python3 -u - << 'PYEOF'
import os, sys, time, json, subprocess, re

iface = os.environ.get("IFACE", "eth0")
ifb_dev = os.environ.get("IFB_DEV", "ifb0")
check_interval = int(os.environ.get("CHECK_INTERVAL", 60))
window_sec = int(os.environ.get("WINDOW_MINUTES", 5)) * 60
threshold_bytes = int(os.environ.get("THRESHOLD_MB", 400)) * 1024 * 1024
penalty_speed = os.environ.get("PENALTY_SPEED", "10mbit")
penalty_duration = int(os.environ.get("PENALTY_HOURS", 1)) * 3600
status_file = os.environ.get("STATUS_FILE", "/run/proxy-shaper-status.json")

history = {}         # ip -> list of [timestamp, bytes]
penalties = {}       # ip -> {"until": expire_ts, "class_id": int}
last_sample = {}     # ip -> [timestamp, bytes]
free_class_ids = set(range(100, 2000)) # 独占通道池 (同时作为独立的 prio 编号)

def run_cmd(cmd):
    return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def apply_tc_limit(ip, cid):
    # 先清理可能残留的同编号规则
    remove_tc_limit(cid)

    # 1. 物理网卡 (控制客户端下载 Egress: 匹配目标地址 dst)
    run_cmd(f"tc class add dev {iface} parent 1: classid 1:{cid} htb rate {penalty_speed} ceil {penalty_speed} burst 15k cburst 15k")
    run_cmd(f"tc qdisc add dev {iface} parent 1:{cid} handle {cid}: fq_codel limit 1024")
    run_cmd(f"tc filter add dev {iface} parent 1:0 protocol ip prio {cid} u32 match ip dst {ip}/32 flowid 1:{cid}")

    # 2. IFB 虚拟网卡 (控制客户端上传 Ingress: 匹配源地址 src)
    run_cmd(f"tc class add dev {ifb_dev} parent 1: classid 1:{cid} htb rate {penalty_speed} ceil {penalty_speed} burst 15k cburst 15k")
    run_cmd(f"tc qdisc add dev {ifb_dev} parent 1:{cid} handle {cid}: fq_codel limit 1024")
    run_cmd(f"tc filter add dev {ifb_dev} parent 1:0 protocol ip prio {cid} u32 match ip src {ip}/32 flowid 1:{cid}")

def remove_tc_limit(cid):
    # 按顺序卸载：先按独立 prio 删 filter -> 再删 qdisc -> 最后删 class
    run_cmd(f"tc filter del dev {iface} parent 1:0 prio {cid} 2>/dev/null")
    run_cmd(f"tc qdisc del dev {iface} parent 1:{cid} 2>/dev/null")
    run_cmd(f"tc class del dev {iface} classid 1:{cid} 2>/dev/null")

    run_cmd(f"tc filter del dev {ifb_dev} parent 1:0 prio {cid} 2>/dev/null")
    run_cmd(f"tc qdisc del dev {ifb_dev} parent 1:{cid} 2>/dev/null")
    run_cmd(f"tc class del dev {ifb_dev} classid 1:{cid} 2>/dev/null")

def get_traffic():
    data = {}
    # 优先使用 JSON 解析
    res = run_cmd("nft -j list set ip proxy_shaper client_traffic 2>/dev/null")
    if res.returncode == 0 and res.stdout.strip():
        try:
            nft_json = json.loads(res.stdout)
            for item in nft_json.get("nftables", []):
                container = item.get("element") or item.get("set")
                if container:
                    elements = container.get("elem", [])
                    for elem in elements:
                        ip = None
                        b = 0
                        if isinstance(elem, dict):
                            inner = elem.get("elem", elem)
                            ip = inner.get("val") if isinstance(inner, dict) else None
                            ctr = inner.get("counter") if isinstance(inner, dict) else None
                            if not ctr and isinstance(elem, dict):
                                ctr = elem.get("counter")
                            if ctr and isinstance(ctr, dict):
                                b = ctr.get("bytes", 0)
                        elif isinstance(elem, str):
                            ip = elem
                        if ip:
                            data[ip] = b
        except Exception:
            data = {}

    # 兜底：正则文本提取，100% 容错防空
    if not data:
        text_res = run_cmd("nft list set ip proxy_shaper client_traffic 2>/dev/null")
        if text_res.returncode == 0 and text_res.stdout.strip():
            pattern = re.compile(r'(\d+\.\d+\.\d+\.\d+)[^\n]*?bytes\s+(\d+)')
            for match in pattern.finditer(text_res.stdout):
                data[match.group(1)] = int(match.group(2))

    return data

while True:
    now = time.time()
    current_traffic = get_traffic()
    status_list = []

    # 1. 检查并清理过期的限速 IP，解封并销毁其专属队列
    expired_ips = [ip for ip, info in penalties.items() if now >= info["until"]]
    for ip in expired_ips:
        cid = penalties[ip]["class_id"]
        remove_tc_limit(cid)
        free_class_ids.add(cid)
        del penalties[ip]
        if ip in current_traffic:
            history[ip] = [[now, current_traffic[ip]]]

    # 2. 遍历统计流量，滚动窗口计算
    for ip, total_b in current_traffic.items():
        cur_rate_mbps = 0.0
        if ip in last_sample:
            dt = now - last_sample[ip][0]
            db = total_b - last_sample[ip][1]
            if dt > 0 and db >= 0:
                cur_rate_mbps = round((db * 8) / (dt * 1000 * 1000), 2)
        last_sample[ip] = [now, total_b]

        # 首次发现 IP 时，将上一采样点设为 0，确保首个周期的增量即刻呈现
        if ip not in history:
            history[ip] = [[now - check_interval, 0], [now, total_b]]
        else:
            history[ip].append([now, total_b])

        cutoff = now - window_sec
        history[ip] = [pt for pt in history[ip] if pt[0] >= cutoff]

        oldest_b = history[ip][0][1]
        delta_b = max(0, total_b - oldest_b)

        # 触发限速：分配独占 classid 并下发双向规则
        if delta_b >= threshold_bytes and ip not in penalties:
            if free_class_ids:
                cid = free_class_ids.pop()
                penalties[ip] = {"until": now + penalty_duration, "class_id": cid}
                apply_tc_limit(ip, cid)

        is_penalized = ip in penalties
        rem = int(penalties[ip]["until"] - now) if is_penalized else 0
        window_mb = round(delta_b / 1024 / 1024, 2)

        # 5 分钟流量 >= 0.05MB 或处于限速中的 IP 均予展示
        if window_mb >= 0.05 or is_penalized:
            status_list.append({
                "ip": ip,
                "window_mb": window_mb,
                "cur_rate_mbps": cur_rate_mbps,
                "is_penalized": is_penalized,
                "remaining_sec": rem
            })

    status_list.sort(key=lambda x: x["window_mb"], reverse=True)

    # 3. 内存回收：清理内核中已超时回收且不在惩罚名单中的 IP 缓存
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
    print("当前暂无活跃流量记录 (已自动过滤 < 0.05 MB 的空闲 IP)。")
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
