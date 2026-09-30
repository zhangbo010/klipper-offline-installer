#!/bin/bash
# ============================================================================
#  网络看门狗（掉线自愈）
#  由 net-watchdog.timer 每 2 分钟触发；网关与外网都不可达时自动重连，
#  仍不行就重启 NetworkManager。适合长期无人值守的打印设备。
#
#  连接名/网关默认自动探测；也可在 net-watchdog.service 里用环境变量覆盖：
#     NW_CONN="<NetworkManager 连接名>"   NW_GW="<网关IP>"   NW_DNS="<探测用DNS>"
# ============================================================================
GW="${NW_GW:-$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')}"
DNS="${NW_DNS:-223.5.5.5}"
LOG="${NW_LOG:-/var/log/net-watchdog.log}"

# 自动取当前活跃的非 lo 连接名
CONN="${NW_CONN:-$(nmcli -t -f NAME,DEVICE,STATE con show 2>/dev/null \
        | awk -F: '$3=="activated" && $2!="lo"{print $1; exit}')}"

ping_ok() { ping -c 1 -W 3 "$1" >/dev/null 2>&1; }

# 网关和外网都通 → 什么都不做（短暂抖动交给 NetworkManager 自愈）
if ping_ok "$GW" && ping_ok "$DNS"; then
    exit 0
fi

# 再等 5 秒给 NM 一点自愈时间
sleep 5
if ping_ok "$GW" && ping_ok "$DNS"; then
    exit 0
fi

{
    echo "[$(date '+%F %T')] network down (gw=${GW:-?} unreachable) -> reconnect '${CONN:-default}'"
    if [ -n "$CONN" ]; then
        nmcli con up "$CONN" 2>&1
    else
        nmcli networking off && sleep 3 && nmcli networking on 2>&1
    fi
    sleep 8
    if ping_ok "$GW"; then
        echo "[$(date '+%F %T')] reconnect OK, ip=$(ip -4 -o addr show scope global | awk '{print $4}' | tr '\n' ' ')"
    else
        echo "[$(date '+%F %T')] reconnect failed -> restarting NetworkManager"
        systemctl restart NetworkManager 2>&1
    fi
    # 只保留最近 200 行
    if [ -f "$LOG" ]; then
        tail -n 200 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
    fi
} >> "$LOG" 2>&1
