#!/system/bin/sh

DATA_DIR=/data/adb/xiaomi_mifi_web

# 先读黑名单再清理 iptables：卸载后残留的 MAC DROP 规则会让被拉黑设备继续断网
# P1-90：卸载脚本同样不 source 配置文件（避免执行注入内容），只提取黑名单字段
BLOCKED_MACS=
if [ -r "$DATA_DIR/config.conf" ]; then
  BLOCKED_MACS=$(/system/bin/sed -n 's/^BLOCKED_MACS=//p' "$DATA_DIR/config.conf" 2>/dev/null | head -n 1)
fi
# P2-14：仅当热点由本模块托管时才关闭，避免卸载误关用户自行开启的热点
MANAGED=
if [ -r "$DATA_DIR/hotspot_managed" ]; then
  MANAGED=$(cat "$DATA_DIR/hotspot_managed" 2>/dev/null)
fi
# P1-77：优先清理模块记录过的热点接口，再做安全枚举（wlan[1-9]+），避免漏清非标准命名
USED_IFACE=
for F in "$DATA_DIR/usage_iface" "$DATA_DIR/hotspot_iface"; do
  if [ -r "$F" ]; then
    USED_IFACE=$(cat "$F" 2>/dev/null | tr -d ' \r\n')
    [ -n "$USED_IFACE" ] && break
  fi
done
IFACES="$USED_IFACE"
for IFACE in $(/system/bin/ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wlan[1-9][0-9]*$/ {print $2}'); do
  case " $IFACES " in *" $IFACE "*) : ;; *) IFACES="$IFACES $IFACE" ;; esac
done
for IFACE in $IFACES; do
  [ -z "$IFACE" ] && continue
  # P1-76：卸载清理限速 qdisc（记录过的热点接口）
  TC=/system/bin/tc
  [ -x "$TC" ] || TC=$(command -v tc 2>/dev/null)
  if [ -n "$TC" ] && [ -x "$TC" ]; then
    "$TC" qdisc del dev "$IFACE" root 2>/dev/null || true
  fi
  for mac in $BLOCKED_MACS; do
    /system/bin/iptables -D FORWARD -i "$IFACE" -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
    /system/bin/iptables -D INPUT -i "$IFACE" -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
  done
  /system/bin/iptables -D FORWARD -i "$IFACE" -j mifi_stats 2>/dev/null || true
  /system/bin/iptables -D FORWARD -i "$IFACE" -j mifi_up 2>/dev/null || true
  /system/bin/iptables -D FORWARD -o "$IFACE" -j mifi_dn 2>/dev/null || true
  /system/bin/ip addr del 192.168.43.1/32 dev "$IFACE" 2>/dev/null || true
done
# P1-75：清空并删除模块统计链（含 FORWARD 引用已在上方移除）
for CHAIN in mifi_stats mifi_up mifi_dn; do
  /system/bin/iptables -F "$CHAIN" 2>/dev/null || true
  /system/bin/iptables -X "$CHAIN" 2>/dev/null || true
done
if [ -f "$DATA_DIR/httpd.pid" ]; then
  PID=$(cat "$DATA_DIR/httpd.pid" 2>/dev/null)
  case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
  [ "$PID" -gt 1 ] && [ -r "/proc/$PID/cmdline" ] && tr '\000' ' ' < "/proc/$PID/cmdline" | grep -q 'httpd' && kill "$PID" 2>/dev/null
fi
if [ -f "$DATA_DIR/supervisor.pid" ]; then
  PID=$(cat "$DATA_DIR/supervisor.pid" 2>/dev/null)
  case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
  [ "$PID" -gt 1 ] && [ -r "/proc/$PID/cmdline" ] && tr '\000' ' ' < "/proc/$PID/cmdline" | grep -q 'xiaomi_mifi_web.*/service.sh' && kill "$PID" 2>/dev/null
fi
# 科学上网清理：先撤透明代理/QUIC 规则，再停止 Mihomo，避免卸载后热点断网。
PROXY_IFACE=$(cat "$DATA_DIR/proxy/iface" 2>/dev/null | tr -d ' \r\n')
for IFACE in $PROXY_IFACE wlan2 wlan3 wlan4; do
  [ -n "$IFACE" ] || continue
  while /system/bin/iptables -t nat -C PREROUTING -i "$IFACE" -j MIFI_PROXY 2>/dev/null; do
    /system/bin/iptables -t nat -D PREROUTING -i "$IFACE" -j MIFI_PROXY 2>/dev/null || break
  done
  while /system/bin/iptables -t filter -C FORWARD -i "$IFACE" -j MIFI_BLOCK_QUIC 2>/dev/null; do
    /system/bin/iptables -t filter -D FORWARD -i "$IFACE" -j MIFI_BLOCK_QUIC 2>/dev/null || break
  done
done
# 兼容 beta2 遗留的无接口限制规则
while /system/bin/iptables -t nat -C PREROUTING -j MIFI_PROXY 2>/dev/null; do
  /system/bin/iptables -t nat -D PREROUTING -j MIFI_PROXY 2>/dev/null || break
done
while /system/bin/iptables -t filter -C FORWARD -j MIFI_BLOCK_QUIC 2>/dev/null; do
  /system/bin/iptables -t filter -D FORWARD -j MIFI_BLOCK_QUIC 2>/dev/null || break
done
/system/bin/iptables -t nat -F MIFI_PROXY 2>/dev/null || true
/system/bin/iptables -t nat -X MIFI_PROXY 2>/dev/null || true
/system/bin/iptables -t filter -F MIFI_BLOCK_QUIC 2>/dev/null || true
/system/bin/iptables -t filter -X MIFI_BLOCK_QUIC 2>/dev/null || true
if [ -r "$DATA_DIR/proxy/mihomo.pid" ]; then
  MPID=$(cat "$DATA_DIR/proxy/mihomo.pid" 2>/dev/null)
  case "$MPID" in ''|*[!0-9]*) MPID=0 ;; esac
  [ "$MPID" -gt 1 ] 2>/dev/null && kill "$MPID" 2>/dev/null || true
fi

if [ "$MANAGED" = "1" ]; then
  /system/bin/cmd wifi stop-softap >/dev/null 2>&1
fi
rm -rf "$DATA_DIR"
