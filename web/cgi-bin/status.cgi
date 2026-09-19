#!/system/bin/sh

MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/status.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"error":"module common library not found"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json
load_config

IFACE=$(get_hotspot_iface)
# 原生热点网关：排除模块固定管理别名，避免 get_iface_ip 读到 192.168.43.1 造成 NAT 网段误判
NATIVE_IP=$(get_native_hotspot_ip "$IFACE")
[ -z "$NATIVE_IP" ] && NATIVE_IP=$(get_iface_ip "$IFACE")
IP=$(get_management_ip "$IFACE")
SSID=$(b64url_decode "$SSID_B64")
RUNNING=false
if [ -n "$IFACE" ] && [ -n "$IP" ] && softap_state_ok "$IFACE"; then
  RUNNING=true
else
  RUNNING=false
fi
DESIRED=$("$BB" head -n 1 "$DESIRED_FILE" 2>/dev/null)
[ "$DESIRED" = "1" ] || DESIRED=0
CSRF=$(read_csrf_token)
read_operation

get_battery_cached

# 低电量提醒快照（15 秒 tick 由服务端写入；未启用时 also 返回阈值配置）
LB_EN=${LOWBATT_ENABLE:-0}
LB_TH=${LOWBATT_THRESHOLD:-20}
LB_LEVEL=--
LB_POWER=0
LB_LATCH=none
LB_REASON=disabled
LB_CHECKED=0
if [ -r "$DATA_DIR/lowbatt.status" ]; then
  while IFS= read -r l; do
    case "$l" in
      level=*) LB_LEVEL=${l#level=} ;;
      power=*) LB_POWER=${l#power=} ;;
      threshold=*) LB_TH=${l#threshold=} ;;
      latch=*) LB_LATCH=${l#latch=} ;;
      reason=*) LB_REASON=${l#reason=} ;;
      checked=*) LB_CHECKED=${l#checked=} ;;
    esac
  done < "$DATA_DIR/lowbatt.status"
fi

check_tethering "$IFACE"
get_sysinfo
get_sim_state
get_cell_stats
read_usage
read_traffic_stats

# 手机套餐进度：percent（0-100，已超限按 100+）、remaining MB
PLAN_PERCENT=-1
PLAN_REMAIN=0
PLAN_PERIOD_USED=0
PLAN_PERIOD_DAY=
plan_usage_percent
if [ "$PLAN_PERCENT" -ge 0 ] 2>/dev/null; then
  plan_total_mb
  PLAN_REMAIN=$((PLAN_TOTAL * 1048576 - PLAN_PERIOD_BYTES))
  [ "$PLAN_REMAIN" -lt 0 ] && PLAN_REMAIN=0
  PLAN_REMAIN=$((PLAN_REMAIN / 1048576))
fi

# 距下次结算日剩余天数（后端按真实月天数计算，前端不再假设 30 天）
PLAN_DAYS_LEFT=0
_PD=${DATA_PLAN_DAY:-1}
case "$_PD" in ''|*[!0-9]*) _PD=1 ;; esac
_DD=$(/system/bin/date +%d 2>/dev/null); _DD=$((10#$_DD))
_YY=$(/system/bin/date +%Y 2>/dev/null); _MM=$(/system/bin/date +%m 2>/dev/null)
case "$_MM" in
  01|03|05|07|08|10|12) _LDM=31 ;;
  04|06|09|11) _LDM=30 ;;
  02) _YY=$((10#$_YY)); if [ $((_YY%400)) -eq 0 ] || { [ $((_YY%4)) -eq 0 ] && [ $((_YY%100)) -ne 0 ]; }; then _LDM=29; else _LDM=28; fi ;;
  *) _LDM=30 ;;
esac
_eff=$_PD; [ "$_eff" -gt "$_LDM" ] && _eff=$_LDM
if [ "$_DD" -lt "$_eff" ]; then
  PLAN_DAYS_LEFT=$((_eff-$_DD))
else
  case "$_MM" in
    12) _NM=01; _NY=$((_YY+1)) ;;
    *) _NM=$((10#$_MM+1)); _NM="0$_NM"; _NM=${_NM: -2}; _NY=$_YY ;;
  esac
  case "$_NM" in
    01|03|05|07|08|10|12) _NLDM=31 ;;
    04|06|09|11) _NLDM=30 ;;
    02) _NYI=$((10#$_NY)); if [ $((_NYI%400)) -eq 0 ] || { [ $((_NYI%4)) -eq 0 ] && [ $((_NYI%100)) -ne 0 ]; }; then _NLDM=29; else _NLDM=28; fi ;;
    *) _NLDM=30 ;;
  esac
  _eff2=$_PD; [ "$_eff2" -gt "$_NLDM" ] && _eff2=$_NLDM
  PLAN_DAYS_LEFT=$((_LDM-_DD+_eff2))
fi

IDLE_LEFT=$(cat "$IDLE_FILE" 2>/dev/null | "$BB" tr -d ' ')
case "$IDLE_LEFT" in ''|*[!0-9]*) IDLE_LEFT=0 ;; esac

# 客户端列表（合并流量统计）
# P1-82：状态接口保持只读——统计链 RETURN 计数规则的维护已移至 service.sh 主循环，
# 页面访问不再触发 iptables 写入，多页面同时浏览也不会竞争防火墙。

# 渠道健康 JSON：{"send":ts,"ok":ts,"err":"","fails":n,"masked":""}
health_json() {
  CH=$1
  H=$(read_health "$CH")
  HS=$("$BB" cut -d'|' -f1 <<EOF
$H
EOF
)
  HO=$("$BB" cut -d'|' -f2 <<EOF
$H
EOF
)
  HE=$("$BB" cut -d'|' -f3 <<EOF
$H
EOF
)
  HF=$("$BB" cut -d'|' -f4 <<EOF
$H
EOF
)
  case "$HS" in ''|*[!0-9]*) HS=0 ;; esac
  case "$HO" in ''|*[!0-9]*) HO=0 ;; esac
  case "$HF" in ''|*[!0-9]*) HF=0 ;; esac
  MASK=
  case "$CH" in
    pp)
      if [ -n "${PUSHPLUS_TOKEN_B64:-}" ]; then
        M=$(b64url_decode "$PUSHPLUS_TOKEN_B64" 2>/dev/null)
        MASK="****${M#"${M%????}"}"
      fi ;;
    dt)
      if [ -n "${DINGTALK_WEBHOOK_B64:-}" ]; then
        W=$(b64url_decode "$DINGTALK_WEBHOOK_B64" 2>/dev/null)
        TOK=$(printf '%s' "$W" | "$BB" sed -n 's/.*access_token=//p' | "$BB" head -c 200)
        [ -n "$TOK" ] && MASK="https://oapi.dingtalk.com/robot/send?access_token=****${TOK#"${TOK%????}"}"
      fi ;;
  esac
  printf '{"send":%s,"ok":%s,"err":"%s","fails":%s,"masked":"%s"}' "$HS" "$HO" "$(json_escape "$HE")" "$HF" "$(json_escape "$MASK")"
}

build_clients() {
  FIRST=1
  list_clients "$IFACE" | while IFS='|' read -r CLIENT_IP CLIENT_MAC CLIENT_STATE; do
    [ -z "$CLIENT_IP" ] && continue
    RU=$(get_client_usage "$CLIENT_MAC")
    RX=$(printf '%s\n' "$RU" | "$BB" cut -d'|' -f1)
    TX=$(printf '%s\n' "$RU" | "$BB" cut -d'|' -f2)
    [ -z "$RX" ] && RX=0
    [ -z "$TX" ] && TX=0
    if [ "$FIRST" = "0" ]; then printf ','; fi
    FIRST=0
    VENDOR=$(mac_vendor "$("$BB" printf '%s' "$CLIENT_MAC" | "$BB" tr 'a-f' 'A-F')")
    NOTE=$(get_device_note "$CLIENT_MAC")
    RATE=$(get_rate_limit "$CLIENT_MAC")
    case "$RATE" in ''|*[!0-9]*) RATE=0 ;; esac
    HIST=$(client_stats_read "$CLIENT_MAC")
    HF=$("$BB" cut -d'|' -f1 <<EOF
$HIST
EOF
)
    HL=$("$BB" cut -d'|' -f2 <<EOF
$HIST
EOF
)
    HO=$("$BB" cut -d'|' -f3 <<EOF
$HIST
EOF
)
    case "$HF" in ''|*[!0-9]*) HF=0 ;; esac
    case "$HL" in ''|*[!0-9]*) HL=0 ;; esac
    case "$HO" in ''|*[!0-9]*) HO=0 ;; esac
    printf '{"ip":"%s","mac":"%s","state":"%s","rx":%s,"tx":%s,"vendor":"%s","note":"%s","rate":%s,"first":%s,"last":%s,"online":%s}' \
      "$(json_escape "$CLIENT_IP")" "$(json_escape "$CLIENT_MAC")" "$(json_escape "$CLIENT_STATE")" "$RX" "$TX" "$(json_escape "$VENDOR")" "$(json_escape "$NOTE")" "$RATE" "$HF" "$HL" "$HO"
  done
}

# 历史设备列表（known_macs ∪ device_notes），含在线标记与备注
build_history() {
  FIRST=1
  # P1-46：仅活跃邻居状态（REACHABLE/DELAY/PROBE）标记在线，避免 ARP 残留导致历史设备误显示在线
  ONLINE_MACS=$(list_clients "$IFACE" 2>/dev/null | "$BB" awk -F'|' '$3=="REACHABLE"||$3=="DELAY"||$3=="PROBE"{print $2}')
  ALL_MACS=$(cat "$KNOWN_MACS" 2>/dev/null)
  if [ -f "$DEVICE_NOTES" ]; then
    ALL_MACS=$(printf '%s\n%s\n' "$ALL_MACS" "$("$BB" cut -d'|' -f1 "$DEVICE_NOTES" 2>/dev/null)")
  fi
  printf '%s\n' "$ALL_MACS" | "$BB" awk 'NF' | sort -u | while IFS= read -r MAC; do
    valid_mac "$MAC" || continue
    NOTE=$(get_device_note "$MAC")
    ONL=false
    case " $ONLINE_MACS " in *" $MAC "*) ONL=true ;; esac
    HIST=$(client_stats_read "$MAC")
    HF=$("$BB" cut -d'|' -f1 <<EOF
$HIST
EOF
)
    HL=$("$BB" cut -d'|' -f2 <<EOF
$HIST
EOF
)
    HO=$("$BB" cut -d'|' -f3 <<EOF
$HIST
EOF
)
    case "$HF" in ''|*[!0-9]*) HF=0 ;; esac
    case "$HL" in ''|*[!0-9]*) HL=0 ;; esac
    case "$HO" in ''|*[!0-9]*) HO=0 ;; esac
    if [ "$FIRST" = "0" ]; then printf ','; fi
    FIRST=0
    printf '{"mac":"%s","note":"%s","online":%s,"first":%s,"last":%s,"onlineSec":%s}' "$(json_escape "$MAC")" "$(json_escape "$NOTE")" "$ONL" "$HF" "$HL" "$HO"
  done
}

# 黑名单数组
build_blocked() {
  FIRST=1
  for mac in $BLOCKED_MACS; do
    valid_mac "$mac" || continue
    if [ "$FIRST" = "0" ]; then printf ','; fi
    FIRST=0
    printf '"%s"' "$(json_escape "$mac")"
  done
}

# 近 11 天日流量 JSON 数组（v1.5.10：按字节输出，前端换算 MB/GB/TB）
build_traffic_days() {
  F=1
  printf '%s\n' "$TRAFFIC_DAYS" | while IFS='|' read -r D BYTES; do
    [ -z "$D" ] && continue
    case "$BYTES" in ''|*[!0-9]*) BYTES=0 ;; esac
    if [ "$F" = "0" ]; then printf ','; fi
    F=0
    printf '{"d":"%s","bytes":%s}\n' "$(json_escape "$D")" "$BYTES"
  done
}

# 历史账期：按月聚合最近 6 个月
build_traffic_history() {
  [ -f "$TRAFFIC_DAILY" ] || { printf '[]'; return; }
  local _h
  _h=$("$BB" awk -F'|' '
    { ym=substr($1,1,6); b=$2+0; sum[ym]+=b; days[ym]++ }
    END {
      n=0
      for (ym in sum) { arr[n]=ym; n++ }
      for (i=0;i<n;i++) for(j=i+1;j<n;j++) if(arr[i]<arr[j]){t=arr[i];arr[i]=arr[j];arr[j]=t}
      out=""
      for (i=0;i<n && i<6;i++){
        if(i>0) out=out ","
        out=out "{\"month\":\"" arr[i] "\",\"bytes\":" sum[arr[i]] ",\"days\":" days[arr[i]] "}"
      }
      printf "[" out "]"
    }
  ' "$TRAFFIC_DAILY" 2>/dev/null)
  [ -z "$_h" ] && _h='[]'
  printf '%s' "$_h"
}

printf '{'
MOD_VERSION=$("$BB" sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | "$BB" head -n1)
case "$MOD_VERSION" in ''|*[!0-9.]*) MOD_VERSION=-- ;; esac
read_device_info
printf '"ok":true,"version":"%s","deviceModel":"%s","osVersion":"%s","running":%s,' \
  "$MOD_VERSION" "$(json_escape "$DEVICE_MODEL")" "$(json_escape "$OS_VERSION")" "$RUNNING"
printf '"ssid":"%s","passwordSet":%s,"security":"%s","band":"%s","channel":%s,' \
  "$(json_escape "$SSID")" "$([ -n "$PASS_B64" ] && echo true || echo false)" "$(json_escape "$SECURITY")" "$(json_escape "$BAND")" "${CHANNEL:-0}"
printf '"maxClients":%s,"keepalive":%s,"idleShutdown":%s,"holdOff":%s,' "${MAX_CLIENTS:-0}" "$([ "${KEEPALIVE:-1}" = "1" ] && echo true || echo false)" "${IDLE_SHUTDOWN:-0}" "$([ "${HOLD_OFF:-0}" = "1" ] && echo true || echo false)"
printf '"sched":{"enable":%s,"on":"%s","off":"%s","mode":"%s","onWd":"%s","offWd":"%s","onWe":"%s","offWe":"%s"},' \
  "$([ "${SCHED_ENABLE:-0}" = "1" ] && echo true || echo false)" "$(json_escape "${SCHED_ON:-2300}")" "$(json_escape "${SCHED_OFF:-0700}")" "$(json_escape "${SCHED_MODE:-daily}")" "$(json_escape "${SCHED_ON_WD:-2300}")" "$(json_escape "${SCHED_OFF_WD:-0700}")" "$(json_escape "${SCHED_ON_WE:-2300}")" "$(json_escape "${SCHED_OFF_WE:-0700}")"
printf '"autostart":%s,"iface":"%s","ip":"%s","nativeIp":"%s","port":%s,"battery":%s,"charging":%s,' \
  "$([ "$AUTOSTART" = "1" ] && echo true || echo false)" "$(json_escape "$IFACE")" "$(json_escape "$IP")" "$(json_escape "$NATIVE_IP")" "$PORT" "$BATTERY" "$CHARGING"
printf '"desired":%s,"csrf":"%s","operation":{"state":"%s","time":%s,"message":"%s"},' \
  "$([ "$DESIRED" = "1" ] && echo true || echo false)" "$(json_escape "$CSRF")" "$(json_escape "$OP_STATE")" "$OP_TIME" "$(json_escape "$OP_MESSAGE")"
CFG_SAVED=$(cat "$DATA_DIR/config.saved" 2>/dev/null | "$BB" tr -d '\r\n')
printf '"cfgSaved":"%s",' "$(json_escape "$CFG_SAVED")"
printf '"activeClientCount":%s,"connectedClientCount":%s,"manualOff":%s,' "$(count_online_clients "$IFACE")" "$(count_connected_clients "$IFACE")" "$([ -f "$MANUAL_OFF_FILE" ] && echo true || echo false)"
printf '"tether":{"fwd":%s,"nat":%s,"hotspotNat":%s,"pkts":%s},' "$TETHER_FWD" "$TETHER_NAT" "$TETHER_HOTSPOT_NAT" "$TETHER_PKTS"
printf '"sys":{"memTotal":%s,"memAvail":%s,"load":"%s","uptime":"%s","storTotal":%s,"storAvail":%s,"thermal":"%s"},' \
  "${SYS_MEM_TOTAL:-0}" "${SYS_MEM_AVAIL:-0}" "$(json_escape "$SYS_LOAD")" "$(json_escape "$SYS_UPTIME")" "${SYS_STOR_TOTAL:-0}" "${SYS_STOR_AVAIL:-0}" "$(json_escape "$SYS_THERMAL")"
printf '"sim":{"operator":"%s","data":%s,"signal":"%s"},' "$(json_escape "$SIM_OPERATOR")" "${SIM_DATA:-0}" "$(json_escape "$SIM_SIGNAL")"
printf '"cell":{"rx":%s,"tx":%s},' "$CELL_RX" "$CELL_TX"
printf '"usage":{"bytes":%s,"mb":%s,"limitMb":%s,"limitAction":"%s","over":%s},' "$USAGE_BYTES" "$USAGE_MB" "${DATA_PLAN_MB:-0}" "${DATA_LIMIT_ACTION:-stop}" "$USAGE_OVER"
# 信号面板与自动关闭原因
get_signal_info
case "$SIG_RSRP" in ''|*[!0-9-]*) SIG_RSRP=0; SIG_LEVEL= ;; *) SIG_LEVEL=$(signal_level "$SIG_RSRP") ;; esac
STOP_REASON=$(cat "$STOP_REASON_FILE" 2>/dev/null | "$BB" tr -d ' \r\n')
case "$STOP_REASON" in '') STOP_REASON= ;; esac
count_sms_stats
  printf '"smsQueued":%s,"smsRetrying":%s,' "$SMS_QUEUED" "$SMS_RETRYING"
CHAIN_UP=$($IPT -L mifi_up -n -v -x 2>/dev/null | "$BB" awk 'NR>2 && $1 ~ /^[0-9]+$/ {s+=$2} END {print s+0}')
CHAIN_DN=$($IPT -L mifi_dn -n -v -x 2>/dev/null | "$BB" awk 'NR>2 && $1 ~ /^[0-9]+$/ {s+=$2} END {print s+0}')
# v1.5.10：today/month 输出字节（前端 formatTrafficMb(d/1048576) 换算），不再丢失小流量
TRAFFIC_SINCE=$("$BB" cut -d'|' -f1 "$TRAFFIC_BASE" 2>/dev/null)
printf '"traffic":{"today":%s,"month":%s,"todayValid":%s,"monthValid":%s,"plan":%s,"planPercent":%s,"planRemain":%s,"chainUp":%s,"chainDn":%s,"planDay":%s,"daysLeft":%s,"periodUsed":%s,"periodStart":"%s","since":"%s","days":[%s],"history":%s},' "$TRAFFIC_TODAY_BYTES" "$TRAFFIC_MONTH_BYTES" "$TRAFFIC_TODAY_VALID" "$TRAFFIC_MONTH_VALID" "$PLAN_TOTAL" "$PLAN_PERCENT" "$PLAN_REMAIN" "$CHAIN_UP" "$CHAIN_DN" "${DATA_PLAN_DAY:-1}" "$PLAN_DAYS_LEFT" "$PLAN_PERIOD_USED" "$(json_escape "$PLAN_PERIOD_DAY")" "$(json_escape "$TRAFFIC_SINCE")" "$(build_traffic_days)" "$(build_traffic_history)"
printf '"smsFwd":{"on":%s,"keyword":%s,"senders":%s,"keywordText":"%s","sendersText":"%s"},' "$([ "${SMS_FWD:-0}" = "1" ] && echo true || echo false)" "$([ -n "${SMS_FWD_KEYWORD_B64:-}" ] && echo true || echo false)" "$([ -n "${SMS_FWD_SENDERS_B64:-}" ] && echo true || echo false)" "$(json_escape "${SMS_FWD_KEYWORD:-}")" "$(json_escape "${SMS_FWD_SENDERS:-}")"
printf '"lowbatt":{"enable":%s,"threshold":%s,"level":"%s","power":%s,"latch":"%s","reason":"%s","checked":%s},' "$([ "$LB_EN" = "1" ] && echo true || echo false)" "$LB_TH" "$(json_escape "$LB_LEVEL")" "$LB_POWER" "$(json_escape "$LB_LATCH")" "$(json_escape "$LB_REASON")" "$LB_CHECKED"
printf '"idleLeft":%s,' "$IDLE_LEFT"
printf '"notify":{"pp":%s,"dt":%s,"dtsec":%s,"limit":%s,"hotspotEvt":%s,"thresholds":"%s"},' \
  "$([ -n "${PUSHPLUS_TOKEN_B64:-}" ] && echo true || echo false)" "$([ -n "${DINGTALK_WEBHOOK_B64:-}" ] && echo true || echo false)" "$([ -n "${DINGTALK_SECRET_B64:-}" ] && echo true || echo false)" "$([ "${NOTIFY_LIMIT:-1}" = "1" ] && echo true || echo false)" "$([ "${NOTIFY_HOTSPOT_EVT:-1}" = "1" ] && echo true || echo false)" "${NOTIFY_TRAFFIC_THRESHOLDS:-80,90,100}"
printf '"notifyHealth":{"pp":%s,"dt":%s,"sms":%s},' \
  "$(health_json pp)" "$(health_json dt)" "$(health_json sms)"
printf '"signal":{"network":"%s","operator":"%s","sim":"%s","band":"%s","pci":%s,"rsrp":%s,"rsrq":%s,"sinr":%s,"level":"%s"},' \
  "$(json_escape "$SIG_NETWORK")" "$(json_escape "$SIG_OPERATOR")" "$(json_escape "$SIG_SIM")" "$(json_escape "$SIG_BAND")" "${SIG_PCI:-0}" "${SIG_RSRP:-0}" "${SIG_RSRQ:-0}" "${SIG_SINR:-0}" "$(json_escape "$SIG_LEVEL")"
printf '"auto":{"desired":%s,"keepalive":%s,"idleMin":%s,"sched":%s,"stopReason":"%s","limitAction":"%s"},' \
  "$([ "$DESIRED" = "1" ] && echo true || echo false)" "$([ "${KEEPALIVE:-0}" = "1" ] && echo true || echo false)" "${IDLE_SHUTDOWN:-0}" "$([ "${SCHED_ENABLE:-0}" = "1" ] && echo true || echo false)" "$(json_escape "$STOP_REASON")" "${DATA_LIMIT_ACTION:-stop}"
printf '"blocked":[%s],' "$(build_blocked)"
printf '"history":['
build_history
printf '],"clients":['
build_clients
printf ']}'
