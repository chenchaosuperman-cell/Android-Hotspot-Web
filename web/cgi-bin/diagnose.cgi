#!/system/bin/sh

MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/diagnose.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"message":"模块公共组件不存在"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json
load_config

IFACE=$(get_hotspot_iface)
IP=$(get_iface_ip "$IFACE")
MIP=$(get_management_ip "$IFACE")
check_tethering "$IFACE"

ALIAS=false
if [ -n "$IFACE" ] && /system/bin/ip -o -4 addr show dev "$IFACE" 2>/dev/null | "$BB" grep -q " $STABLE_IP/"; then
  ALIAS=true
fi

DESIRED=$(cat "$DESIRED_FILE" 2>/dev/null)
[ "$DESIRED" = "1" ] || DESIRED=0

HTTP_PID=$(cat "$HTTP_PIDFILE" 2>/dev/null)
HTTP_ALIVE=false
case "$HTTP_PID" in ''|*[!0-9]*) HTTP_PID=0 ;; esac
if [ "$HTTP_PID" -gt 1 ] && kill -0 "$HTTP_PID" 2>/dev/null; then
  HTTP_ALIVE=true
fi

CSRF_OK=false
[ -s "$CSRF_FILE" ] && CSRF_OK=true

# UI-1(1.5.11)：Root/命令能力真实检测（前端不再写死“正常”）
ROOT_OK=false
if [ "$(id -u 2>/dev/null)" = "0" ]; then
  ROOT_OK=true
else
  if /system/bin/su -c id 2>/dev/null | "$BB" grep -q 'uid=0'; then
    ROOT_OK=true
  fi
fi
CMD_OK=false
if [ -x /system/bin/cmd ] && [ -x "$IPT" ] && [ -x /system/bin/date ]; then
  CMD_OK=true
fi

SELINUX=$(/system/bin/getenforce 2>/dev/null)
[ -z "$SELINUX" ] && SELINUX="unknown"

FW_RULES=$($IPT -L FORWARD -n 2>/dev/null | "$BB" head -20)
NAT_RULES=$($IPT -t nat -S 2>/dev/null | "$BB" grep -c MASQUERADE)

# 客户端发现原始数据（双数据源，便于定位“在线设备为0”）
ARP_RAW=$(cat /proc/net/arp 2>/dev/null | "$BB" head -20)
NEIGH_RAW=$(/system/bin/ip neigh show dev "$IFACE" 2>/dev/null | "$BB" head -20)
CLIENTS_FOUND=$(list_clients "$IFACE" 2>/dev/null | "$BB" head -20)
CLIENTS_COUNT=$(list_clients "$IFACE" 2>/dev/null | "$BB" wc -l | "$BB" tr -d ' ')
case "$CLIENTS_COUNT" in ''|*[!0-9]*) CLIENTS_COUNT=0 ;; esac

LOG_TAIL=$("$BB" tail -n 15 "$LOG" 2>/dev/null)

printf '{'
printf '"ok":true,'
printf '"module":"xiaomi_mifi_web",'
printf '"iface":"%s","ip":"%s","mgmtIp":"%s","alias":%s,' "$(json_escape "$IFACE")" "$(json_escape "$IP")" "$(json_escape "$MIP")" "$ALIAS"
printf '"desired":%s,"keepalive":%s,"idleShutdown":%s,"schedEnable":%s,' \
  "$DESIRED" "$([ "${KEEPALIVE:-1}" = "1" ] && echo true || echo false)" "${IDLE_SHUTDOWN:-0}" "$([ "${SCHED_ENABLE:-0}" = "1" ] && echo true || echo false)"
printf '"tether":{"fwd":%s,"nat":%s,"pkts":%s},' "$TETHER_FWD" "$TETHER_NAT" "$TETHER_PKTS"
printf '"httpd":{"pid":%s,"alive":%s},"csrfOk":%s,"rootOk":%s,"cmdOk":%s,"selinux":"%s",' "$HTTP_PID" "$HTTP_ALIVE" "$CSRF_OK" "$ROOT_OK" "$CMD_OK" "$(json_escape "$SELINUX")"
printf '"forwardRules":"%s","natMasquerade":%s,' "$(json_escape "$FW_RULES")" "$NAT_RULES"
printf '"clientsFound":%s,"clientList":"%s","arpRaw":"%s","neighRaw":"%s",' \
  "$CLIENTS_COUNT" "$(json_escape "$CLIENTS_FOUND")" "$(json_escape "$ARP_RAW")" "$(json_escape "$NEIGH_RAW")"
printf '"log":"%s"' "$(json_escape "$LOG_TAIL")"
printf '}'
