#!/system/bin/sh

DATA_DIR=/data/adb/xiaomi14_mifi_web
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables

# ── v1.7.7：全量清理（跨厂商接口 + 独立链 + IPv6）────────────────────
# 原则：
# 1) 接口来源 = 模块运行期记录（usage_iface / hotspot_iface / proxy/iface）优先，
#    再做跨厂商宽枚举（wlan*/ap*/softap*/swlan*/apbr*/rndis*/usb*），不写死 wlan0-4。
# 2) 所有模块自建链（mifi_acl / mifi_stats / mifi_up / mifi_dn / MIFI_WEB /
#    mifi_ipv6 / MIFI_PROXY / MIFI_PROXY_SELF / MIFI_BLOCK_QUIC / MIFI_SELF_BLOCK_QUIC）
#    先摘引用跳转、再 -F、再 -X。
# 3) 固定管理地址 192.168.43.1 别名：热点接口 + lo 双路径清理。
# 4) IPv6 链同步清理（command -v 探测，避免部分 ROM 无 ip6tables）。

# 先读黑名单再清理 iptables：卸载后残留的 MAC DROP 规则会让被拉黑设备继续断网
BLOCKED_MACS=
if [ -r "$DATA_DIR/config.conf" ]; then
  BLOCKED_MACS=$(/system/bin/sed -n 's/^BLOCKED_MACS=//p' "$DATA_DIR/config.conf" 2>/dev/null | head -n 1)
fi
ALLOWED_MACS=
if [ -r "$DATA_DIR/config.conf" ]; then
  ALLOWED_MACS=$(/system/bin/sed -n 's/^ALLOWED_MACS=//p' "$DATA_DIR/config.conf" 2>/dev/null | head -n 1)
fi
# 仅当热点由本模块托管时才关闭，避免卸载误关用户自行开启的热点
MANAGED=
if [ -r "$DATA_DIR/hotspot_managed" ]; then
  MANAGED=$(cat "$DATA_DIR/hotspot_managed" 2>/dev/null)
fi

# ── 接口集合：记录优先 + 宽枚举 ──
IFACES=
# v1.7.9：清除已删除的"热点异常提醒"防重复时间戳残留
rm -f "$DATA_DIR/recover_notify_ts" 2>/dev/null
for F in "$DATA_DIR/usage_iface" "$DATA_DIR/hotspot_iface" "$DATA_DIR/proxy/iface"; do
  if [ -r "$F" ]; then
    V=$(cat "$F" 2>/dev/null | tr -d ' \r\n')
    [ -n "$V" ] && case " $IFACES " in *" $V "*) : ;; *) IFACES="$IFACES $V" ;; esac
  fi
done
# 跨厂商接口枚举（wlan*/ap*/softap*/swlan*/apbr* + USB 共享）
for IFACE in $(/system/bin/ip -o link show 2>/dev/null | awk -F': ' '
  $2 ~ /^wlan[0-9]+$/ || $2 ~ /^ap[0-9]+$/ || $2 ~ /^softap[0-9]+$/ ||
  $2 ~ /^swlan[0-9]+$/ || $2 ~ /^apbr[0-9]+$/ || $2 ~ /^rndis[0-9]+$/ || $2 ~ /^usb[0-9]+$/ {print $2}'); do
  case " $IFACES " in *" $IFACE "*) : ;; *) IFACES="$IFACES $IFACE" ;; esac
done

# ── 按接口清理：限速 qdisc / MAC 规则 / 统计链引用 / 固定别名 ──
for IFACE in $IFACES; do
  [ -z "$IFACE" ] && continue
  TC=/system/bin/tc
  [ -x "$TC" ] || TC=$(command -v tc 2>/dev/null)
  if [ -n "$TC" ] && [ -x "$TC" ]; then
    "$TC" qdisc del dev "$IFACE" root 2>/dev/null || true
  fi
  for mac in $BLOCKED_MACS; do
    case "$mac" in
      [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) : ;;
      *) continue ;;
    esac
    /system/bin/iptables -D FORWARD -i "$IFACE" -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
    /system/bin/iptables -D INPUT -i "$IFACE" -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
  done
  for mac in $ALLOWED_MACS; do
    case "$mac" in
      [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) : ;;
      *) continue ;;
    esac
    /system/bin/iptables -D mifi_acl -i "$IFACE" -m mac --mac-source "$mac" -j RETURN 2>/dev/null || true
  done
  # 独立链跳转引用（FORWARD 方向）
  while /system/bin/iptables -C FORWARD -i "$IFACE" -j mifi_acl 2>/dev/null; do
    /system/bin/iptables -D FORWARD -i "$IFACE" -j mifi_acl 2>/dev/null || break
  done
  while /system/bin/iptables -C FORWARD -i "$IFACE" -j mifi_stats 2>/dev/null; do
    /system/bin/iptables -D FORWARD -i "$IFACE" -j mifi_stats 2>/dev/null || break
  done
  while /system/bin/iptables -C FORWARD -i "$IFACE" -j mifi_up 2>/dev/null; do
    /system/bin/iptables -D FORWARD -i "$IFACE" -j mifi_up 2>/dev/null || break
  done
  while /system/bin/iptables -C FORWARD -o "$IFACE" -j mifi_dn 2>/dev/null; do
    /system/bin/iptables -D FORWARD -o "$IFACE" -j mifi_dn 2>/dev/null || break
  done
  # 固定管理地址别名（热点接口 + lo）
  /system/bin/ip addr del 192.168.43.1/32 dev "$IFACE" 2>/dev/null || true
  /system/bin/ip addr del 192.168.43.1/32 dev lo 2>/dev/null || true
done
# 全局 FORWARD 跳转兜底（旧版无接口限制规则）
while /system/bin/iptables -C FORWARD -j mifi_acl 2>/dev/null; do
  /system/bin/iptables -D FORWARD -j mifi_acl 2>/dev/null || break
done
while /system/bin/iptables -C FORWARD -j mifi_stats 2>/dev/null; do
  /system/bin/iptables -D FORWARD -j mifi_stats 2>/dev/null || break
done

# ── Web 管理页访问控制：独立链 MIFI_WEB（IPv4/IPv6）+ 旧版直插规则 ──
WEB_PORTS=8080
if [ -r "$DATA_DIR/web_fw_port" ]; then
  _WF=$(/system/bin/cat "$DATA_DIR/web_fw_port" 2>/dev/null | tr -d ' \r\n')
  case "$_WF" in ''|*[!0-9]*) : ;; *) WEB_PORTS="$WEB_PORTS $_WF" ;; esac
fi
if [ -r "$DATA_DIR/config.conf" ]; then
  _WP=$(/system/bin/sed -n 's/^PORT=//p' "$DATA_DIR/config.conf" 2>/dev/null | head -n 1)
  case "$_WP" in ''|*[!0-9]*) : ;; *) WEB_PORTS="$WEB_PORTS $_WP" ;; esac
fi
while /system/bin/iptables -C INPUT -j MIFI_WEB 2>/dev/null; do
  /system/bin/iptables -D INPUT -j MIFI_WEB 2>/dev/null || break
done
/system/bin/iptables -F MIFI_WEB 2>/dev/null || true
/system/bin/iptables -X MIFI_WEB 2>/dev/null || true
if [ -x "$IPT6" ] || command -v "$IPT6" >/dev/null 2>&1; then
  while "$IPT6" -C INPUT -j MIFI_WEB 2>/dev/null; do
    "$IPT6" -D INPUT -j MIFI_WEB 2>/dev/null || break
  done
  "$IPT6" -F MIFI_WEB 2>/dev/null || true
  "$IPT6" -X MIFI_WEB 2>/dev/null || true
fi
DONE_WP=
for WP in $WEB_PORTS; do
  case " $DONE_WP " in *" $WP "*) continue ;; esac
  DONE_WP="$DONE_WP $WP"
  for IFACE in $IFACES wlan0 ap0 rndis0 usb0 eth0 lo; do
    /system/bin/iptables -D INPUT -i "$IFACE" -p tcp --dport "$WP" -j ACCEPT 2>/dev/null || true
  done
  /system/bin/iptables -D INPUT -p tcp --dport "$WP" -j DROP 2>/dev/null || true
done

# ── 统计链 / MAC 链 / IPv6 管控链 ──
for CHAIN in mifi_stats mifi_up mifi_dn mifi_acl; do
  /system/bin/iptables -F "$CHAIN" 2>/dev/null || true
  /system/bin/iptables -X "$CHAIN" 2>/dev/null || true
done
if [ -x "$IPT6" ] || command -v "$IPT6" >/dev/null 2>&1; then
  # v1.7.9：mifi_ipv6 按热点接口挂 FORWARD 跳转（fw6_ensure -i $iface），
  # 必须先按接口逐个摘除带接口引用，再摘全局引用，否则 -X 删链会因引用残留失败。
  for IFACE in $IFACES; do
    [ -n "$IFACE" ] || continue
    while "$IPT6" -C FORWARD -i "$IFACE" -j mifi_ipv6 2>/dev/null; do
      "$IPT6" -D FORWARD -i "$IFACE" -j mifi_ipv6 2>/dev/null || break
    done
  done
  while "$IPT6" -C FORWARD -j mifi_ipv6 2>/dev/null; do
    "$IPT6" -D FORWARD -j mifi_ipv6 2>/dev/null || break
  done
  "$IPT6" -F mifi_ipv6 2>/dev/null || true
  "$IPT6" -X mifi_ipv6 2>/dev/null || true
fi

# ── 后台进程 ──
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

# ── 科学上网清理：透明代理 / QUIC / 本机代理 / Mihomo ──
PROXY_IFACE=$(cat "$DATA_DIR/proxy/iface" 2>/dev/null | tr -d ' \r\n')
for IFACE in $PROXY_IFACE $IFACES; do
  [ -n "$IFACE" ] || continue
  while /system/bin/iptables -t nat -C PREROUTING -i "$IFACE" -j MIFI_PROXY 2>/dev/null; do
    /system/bin/iptables -t nat -D PREROUTING -i "$IFACE" -j MIFI_PROXY 2>/dev/null || break
  done
  while /system/bin/iptables -t filter -C FORWARD -i "$IFACE" -j MIFI_BLOCK_QUIC 2>/dev/null; do
    /system/bin/iptables -t filter -D FORWARD -i "$IFACE" -j MIFI_BLOCK_QUIC 2>/dev/null || break
  done
done
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
while /system/bin/iptables -t nat -C OUTPUT -j MIFI_PROXY_SELF 2>/dev/null; do
  /system/bin/iptables -t nat -D OUTPUT -j MIFI_PROXY_SELF 2>/dev/null || break
done
/system/bin/iptables -t nat -F MIFI_PROXY_SELF 2>/dev/null || true
/system/bin/iptables -t nat -X MIFI_PROXY_SELF 2>/dev/null || true
while /system/bin/iptables -t filter -C OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null; do
  /system/bin/iptables -t filter -D OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null || break
done
/system/bin/iptables -t filter -F MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
/system/bin/iptables -t filter -X MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
if [ -r "$DATA_DIR/proxy/mihomo.pid" ]; then
  MPID=$(cat "$DATA_DIR/proxy/mihomo.pid" 2>/dev/null)
  case "$MPID" in ''|*[!0-9]*) MPID=0 ;; esac
  [ "$MPID" -gt 1 ] 2>/dev/null && kill "$MPID" 2>/dev/null || true
fi

if [ "$MANAGED" = "1" ]; then
  /system/bin/cmd wifi stop-softap >/dev/null 2>&1
fi
rm -rf "$DATA_DIR"
