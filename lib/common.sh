#!/system/bin/sh

: "${MODDIR:=/data/adb/modules/xiaomi_mifi_web}"
# 数据目录：模块配置/日志/状态都存这里（保持历史路径，避免升级丢失用户配置）
DATA_DIR=/data/adb/xiaomi14_mifi_web
CONFIG="$DATA_DIR/config.conf"
LOG="$DATA_DIR/service.log"
HTTP_CONF="$DATA_DIR/httpd.conf"
HTTP_PIDFILE="$DATA_DIR/httpd.pid"
DESIRED_FILE="$DATA_DIR/desired_state"
CSRF_FILE="$DATA_DIR/csrf.token"
IDLE_FILE="$DATA_DIR/idle.countdown"
IDLE_SINCE="$DATA_DIR/idle.since"
OP_STATUS="$DATA_DIR/operation.status"
OP_LOCK="$DATA_DIR/operation.lock"
CONTROL_REQUEST="$DATA_DIR/control.request"
STABLE_IP=192.168.43.1
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
# Hotspot Compatibility Layer 统一走系统 cmd（可被测试覆盖为 mock）
CMD_WIFI=/system/bin/cmd

# ── Web 管理端口访问控制（v1.7.2）──────────────────────────────
# 仅放行本机(lo)、真实热点接口与 USB 共享接口，其余接口一律 DROP。
# 端口变更时先清理旧端口规则（生效端口记录于 WEB_FW_PORT_FILE）；
# 卸载时由 uninstall.sh 按该记录清理。规则由 service.sh 主循环保活。
WEB_FW_PORT_FILE="$DATA_DIR/web_fw_port"

# 需要放行的接口列表：当前热点接口（绑定管理 IP 的 wlan 接口）+ USB 共享接口
web_fw_ifaces() {
  local AP
  AP=$(get_hotspot_iface 2>/dev/null)
  [ -n "$AP" ] && printf '%s\n' "$AP"
  printf 'rndis0\nusb0\n'
}

# v1.7.7：Web 防火墙独立链 MIFI_WEB（INPUT → MIFI_WEB）。
# 链内 lo / 热点接口 / USB 共享 ACCEPT，其余接口管理端口 DROP，链尾 RETURN；
# 独立链避免“系统 INPUT 前置 ACCEPT 先命中、末尾 DROP 不生效”的顺序问题；
# IPv4/IPv6 同步维护；端口变更时先清旧端口规则。
clear_web_fw() {
  [ -n "$1" ] || return 0
  local N IFACE
  N=0
  while [ "$N" -lt 20 ] && $IPT -C INPUT -j MIFI_WEB 2>/dev/null; do
    $IPT -D INPUT -j MIFI_WEB 2>/dev/null
    N=$((N + 1))
  done
  $IPT -F MIFI_WEB 2>/dev/null || true
  $IPT -X MIFI_WEB 2>/dev/null || true
  if command -v "$IPT6" >/dev/null 2>&1; then
    N=0
    while [ "$N" -lt 20 ] && $IPT6 -C INPUT -j MIFI_WEB 2>/dev/null; do
      $IPT6 -D INPUT -j MIFI_WEB 2>/dev/null
      N=$((N + 1))
    done
    $IPT6 -F MIFI_WEB 2>/dev/null || true
    $IPT6 -X MIFI_WEB 2>/dev/null || true
  fi
  # 旧版（v1.7.2-v1.7.6）直插 INPUT 规则清理（升级残留）
  $IPT -D INPUT -p tcp --dport "$1" -j DROP 2>/dev/null
  $IPT -D INPUT -i lo -p tcp --dport "$1" -j ACCEPT 2>/dev/null
  for IFACE in $(web_fw_ifaces); do
    $IPT -D INPUT -i "$IFACE" -p tcp --dport "$1" -j ACCEPT 2>/dev/null
  done
}

# 幂等保活：端口未变时补齐缺失规则；端口变更时先清旧端口再应用新端口
ensure_web_fw() {
  [ -n "$PORT" ] || PORT=8080
  local prev
  prev=$(cat "$WEB_FW_PORT_FILE" 2>/dev/null)
  if [ -n "$prev" ] && [ "$prev" != "$PORT" ]; then
    clear_web_fw "$prev"
  fi
  # IPv4：INPUT 首位跳转独立链
  $IPT -N MIFI_WEB 2>/dev/null || { $IPT -F MIFI_WEB 2>/dev/null; }
  $IPT -F MIFI_WEB 2>/dev/null
  $IPT -A MIFI_WEB -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  local IFACE
  for IFACE in $(web_fw_ifaces); do
    [ -n "$IFACE" ] || continue
    $IPT -A MIFI_WEB -i "$IFACE" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  done
  $IPT -A MIFI_WEB -p tcp --dport "$PORT" -j DROP 2>/dev/null
  $IPT -A MIFI_WEB -j RETURN 2>/dev/null
  $IPT -C INPUT -j MIFI_WEB 2>/dev/null || $IPT -I INPUT 1 -j MIFI_WEB 2>/dev/null
  # IPv6 同步
  if command -v "$IPT6" >/dev/null 2>&1; then
    $IPT6 -N MIFI_WEB 2>/dev/null || { $IPT6 -F MIFI_WEB 2>/dev/null; }
    $IPT6 -F MIFI_WEB 2>/dev/null
    $IPT6 -A MIFI_WEB -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
    for IFACE in $(web_fw_ifaces); do
      [ -n "$IFACE" ] || continue
      $IPT6 -A MIFI_WEB -i "$IFACE" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
    done
    $IPT6 -A MIFI_WEB -p tcp --dport "$PORT" -j DROP 2>/dev/null
    $IPT6 -A MIFI_WEB -j RETURN 2>/dev/null
    $IPT6 -C INPUT -j MIFI_WEB 2>/dev/null || $IPT6 -I INPUT 1 -j MIFI_WEB 2>/dev/null
  fi
  printf '%s\n' "$PORT" > "$WEB_FW_PORT_FILE" 2>/dev/null
  chmod 0600 "$WEB_FW_PORT_FILE" 2>/dev/null
}
NOTIFY_QUEUE="$DATA_DIR/notify.queue"
SMS_QUEUE="$DATA_DIR/sms.queue"
SMS_BUSY="$DATA_DIR/sms.busy"
NOTIFY_HEALTH_FILE="$DATA_DIR/notify_health"
CLIENT_STATS_FILE="$DATA_DIR/client_stats"
STOP_REASON_FILE="$DATA_DIR/stop_reason"
MANAGED_FILE="$DATA_DIR/hotspot_managed"
# 一键关闭（不保活）写入：当前定时窗口内不再自动开启；窗口结束后由 service.sh 清除
SKIP_WINDOW_FILE="$DATA_DIR/skip_window"
# 手动关闭热点标记：本次开机内不再被保活/定时拉起
MANUAL_OFF_FILE="$DATA_DIR/manual_off"
PLAN_TH_MARK="$DATA_DIR/plan_th_mark"
PLAN_PERIOD_FILE="$DATA_DIR/plan_period"

find_busybox() {
  for candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/xbin/busybox /system/bin/busybox; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  command -v busybox 2>/dev/null
}

BB=$(find_busybox)
DATE_CMD=$(command -v date 2>/dev/null || echo /system/bin/date)
[ -n "$DATE_CMD" ] || DATE_CMD=date

# ── 模块目录去重自检（v1.7.0）────────────────────────────────────
# 修复 KernelSU 管理器打开/下滑模块列表闪退：
# 当 /data/adb/modules/ 下存在多个目录、其 module.prop 的 id 与当前模块
# 相同（例如误将工作副本直接复制为 xiaomi_mifi_web 目录，与
# xiaomi14_mifi_web 并存），KSU Manager 渲染列表时 Compose key 冲突导致
# 崩溃。本函数将同 id 的其他目录移入 /data/adb/ksu/modules_dup_bak/，
# 保证每个模块 id 全局唯一；service.sh 每次启动时自动执行。
dedup_dup_modules() {
  [ -z "$MODDIR" ] && MODDIR=/data/adb/modules/xiaomi_mifi_web
  [ -z "$BB" ] && BB=$(find_busybox)
  MY_ID=$("$BB" sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | "$BB" head -n 1)
  [ -z "$MY_ID" ] && return 0
  # 标准目录 = /data/adb/modules/<id>（KernelSU 规范：目录名必须等于 MODID）。
  # 标准目录永远保留；仅备份“目录名与 ID 不一致”的残留副本。
  STD_DIR=/data/adb/modules/$MY_ID
  BK_DIR=/data/adb/ksu/modules_dup_bak
  for D in /data/adb/modules/*/; do
    [ -d "$D" ] || continue
    D=${D%/}
    [ "$D" = "$STD_DIR" ] && continue
    [ -f "$D/module.prop" ] || continue
    DID=$("$BB" sed -n 's/^id=//p' "$D/module.prop" 2>/dev/null | "$BB" head -n 1)
    if [ -n "$DID" ] && [ "$DID" = "$MY_ID" ]; then
      # 运行时不要移动当前正在执行的模块目录（服务已加载但后续读写路径会失败）：
      # 若当前运行目录就是非标准副本，只记录告警，提示重装到标准目录。
      if [ "$D" = "$MODDIR" ]; then
        echo "$($DATE_CMD '+%F %T') dedup: WARN running from non-standard dir '$D', expected '$STD_DIR' (reinstall to standard dir)" >> "$LOG" 2>/dev/null
        continue
      fi
      "$BB" mkdir -p "$BK_DIR" 2>/dev/null
      TS=$("$DATE_CMD" +%Y%m%d-%H%M%S 2>/dev/null)
      [ -z "$TS" ] && TS=$$
      NAME=$("$BB" basename "$D" 2>/dev/null)
      [ -z "$NAME" ] && NAME=dup_module
      if "$BB" mv "$D" "$BK_DIR/${NAME}.${TS}" 2>/dev/null; then
        echo "$($DATE_CMD '+%F %T') dedup: moved non-standard duplicate module dir '$D' -> '$BK_DIR/${NAME}.${TS}'" >> "$LOG" 2>/dev/null
      fi
    fi
  done
  return 0
}

header_json() {
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
}

json_escape() {
  # v1.7.9：纯 sh 内建实现（${//} 参数替换，无 awk 子进程）。
  # status.cgi 每次轮询调用 50+ 次，awk 每次 fork ~0.1s，真机上累计数秒，
  # 是状态接口 6-7s 的主要来源（前端 8s 超时 → Load failed 自动重试）。
  # 控制字符（awk 的 [[:cntrl:]]）在状态数据中不存在，不再单独处理。
  s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# 读取设备型号与系统版本（按可用属性链回退，属性缺失时保持空字符串）
# 全局输出：DEVICE_MODEL / OS_VERSION
read_device_info() {
  DEVICE_MODEL=""
  OS_VERSION=""
  GP=/system/bin/getprop
  if [ ! -x "$GP" ]; then
    GP=$("$BB" which getprop 2>/dev/null)
    [ -n "$GP" ] || GP=""
  fi
  if [ -n "$GP" ]; then
    # 机型：市场名 → 型号 → 设备代号
    DEVICE_MODEL=$("$GP" ro.product.marketname 2>/dev/null)
    [ -n "$DEVICE_MODEL" ] || DEVICE_MODEL=$("$GP" ro.product.model 2>/dev/null)
    [ -n "$DEVICE_MODEL" ] || DEVICE_MODEL=$("$GP" ro.product.device 2>/dev/null)
    # 品牌识别
    BRAND=$("$GP" ro.product.brand 2>/dev/null | tr "A-Z" "a-z")
    MANUF=$("$GP" ro.product.manufacturer 2>/dev/null | tr "A-Z" "a-z")
    ANDROID=$("$GP" ro.build.version.release 2>/dev/null)
    # 小米系：用 ro.mi.os.version.name
    IS_XIAOMI=0
    case "$BRAND" in xiaomi|redmi|poco) IS_XIAOMI=1 ;; esac
    case "$MANUF" in xiaomi) IS_XIAOMI=1 ;; esac
    if [ "$IS_XIAOMI" = "1" ]; then
      OS_NAME=$("$GP" ro.mi.os.version.name 2>/dev/null)
      OS_VER=$("$GP" ro.mi.os.version 2>/dev/null)
      if [ -n "$OS_NAME" ]; then
        OS_VERSION=$OS_NAME
        [ -n "$OS_VER" ] && OS_VERSION="$OS_VERSION $OS_VER"
      fi
      if [ -n "$ANDROID" ] && { [ -z "$OS_VER" ] || [ "$ANDROID" != "$OS_VER" ]; }; then
        [ -n "$OS_VERSION" ] && OS_VERSION="$OS_VERSION · Android $ANDROID" || OS_VERSION="Android $ANDROID"
      fi
    else
      # 非小米：显示品牌名 + Android 版本
      BRAND_DISP=$("$GP" ro.product.brand 2>/dev/null)
      [ -n "$ANDROID" ] && OS_VERSION="${BRAND_DISP:-Android} $ANDROID" || OS_VERSION=""
    fi
  fi
}

# 保留换行（转义为 \n）的 JSON 字符串转义，用于可逆导出（如配置备份）
json_escape_nl() {
  printf '%s' "$1" | "$BB" tr '\r' ' ' | "$BB" awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/[[:cntrl:]]/,""); printf "%s\\n", $0}'
}

# v1.7.9：POST body 读取必须在 CGI 顶层（非命令替换）调用一次——body 只能从
# stdin 消费一次，且函数内通过命令替换设置全局变量不会传回父 shell。
cgi_read_body() {
  if [ "${REQUEST_METHOD:-}" = "POST" ] && [ -z "$CGI_BODY_READ" ] && [ -z "$CGI_BODY" ]; then
    CGI_BODY_READ=1
    CL=${CONTENT_LENGTH:-0}
    case "$CL" in ''|*[!0-9]*) CL=0 ;; esac
    if [ "$CL" -gt 0 ] 2>/dev/null; then
      CGI_BODY=$("$BB" head -c "$CL" 2>/dev/null)
    fi
  fi
}

get_param() {
  key=$1
  RAW=
  # v1.7.9：POST 请求敏感参数（token/密码/订阅地址等）改放 body，不再拼进 URL。
  # 调用方需先顶层执行 cgi_read_body（见 control.cgi），此处只读全局 CGI_BODY。
  if [ -n "$CGI_BODY" ]; then
    RAW=$(printf '&%s&' "$CGI_BODY" | "$BB" sed -n "s/.*&${key}=\([^&]*\)&.*/\1/p")
  fi
  if [ -z "$RAW" ]; then
    RAW=$(printf '&%s&' "${QUERY_STRING:-}" | "$BB" sed -n "s/.*&${key}=\([^&]*\)&.*/\1/p")
  fi
  [ -n "$RAW" ] || return 0
  url_decode "$RAW"
}

# URL 百分号解码（纯 sed，兼容 BusyBox）。
# 覆盖 URL 保留字符与常见字符；模块参数中 SSID/备注等文本走 base64url，
# 不会出现百分号编码，因此无需 UTF-8 多字节解码。
url_decode() {
  printf '%s' "$1" | "$BB" sed \
    -e 's/+/ /g' \
    -e 's/%20/ /g; s/%21/!/g; s/%23/#/g; s/%24/\$/g; s/%25/%/g' \
    -e 's/%26/\&/g; s/%27/'"'"'/g; s/%28/(/g; s/%29/)/g' \
    -e 's/%2A/*/g; s/%2B/+/g; s/%2C/,/g; s/%2D/-/g; s/%2E/./g' \
    -e 's/%2F/\//g; s/%3A/:/g; s/%3B/;/g; s/%3D/=/g; s/%3F/?/g' \
    -e 's/%40/@/g; s/%5B/[/g; s/%5C/\\/g; s/%5D/]/g; s/%7E/~/g'
}

b64url_decode() {
  value=$1
  value=$(printf '%s' "$value" | "$BB" tr '_-' '/+')
  case $((${#value} % 4)) in
    2) value="${value}==" ;;
    3) value="${value}=" ;;
  esac
  printf '%s' "$value" | "$BB" base64 -d 2>/dev/null
}

b64url_encode() {
  printf '%s' "$1" | "$BB" base64 | "$BB" tr -d '\r\n' | "$BB" tr '+/' '-_' | "$BB" tr -d '='
}

# 配置加载：逐行白名单解析，绝不 source 配置文件内容。
# 每个字段按类型严格校验（Base64URL / 开关 0-1 / 数值范围 / 时间 HHMM / 信道频段组合 / MAC 列表），
# 未知字段或非法值直接丢弃，防止配置文件中注入 Shell 命令。
# 配置字段应用：load_config 与 import_config 共用同一套白名单校验。
# 未知字段、非法值一律丢弃（不报错、不执行），杜绝配置文件注入 Shell 命令。
cfg_apply_key() {
  key=$1
  value=$2
  case "$key" in

        SSID_B64)
          [ -n "$value" ] && valid_b64url "$value" && SSID_B64=$value ;;
        PASS_B64)
          if [ -z "$value" ]; then PASS_B64=
          elif valid_b64url "$value"; then PASS_B64=$value
          fi ;;
        SECURITY)
          case "$value" in wpa2|wpa3|wpa3_transition|open) SECURITY=$value ;; esac ;;
        BAND)
          case "$value" in 2|5|any) BAND=$value ;; esac ;;
        HIDDEN)
          case "$value" in 0|1) HIDDEN=$value ;; esac ;;
        AUTOSTART)
          case "$value" in 0|1) AUTOSTART=$value ;; esac ;;
        KEEPALIVE)
          case "$value" in 0|1) KEEPALIVE=$value ;; esac ;;
        NOTIFY_LIMIT)
          case "$value" in 0|1) NOTIFY_LIMIT=$value ;; esac ;;
        NOTIFY_TRAFFIC_THRESHOLDS)
          # 逗号分隔 1~100，最多 5 个；非法值忽略（默认 80,90,100）
          _NT_RAW="$value"
          _NT_OUT=
          for _NT_V in $(printf '%s' "$_NT_RAW" | "$BB" tr ',' ' '); do
            case "$_NT_V" in ''|*[!0-9]*) continue ;; esac
            [ "$_NT_V" -ge 1 ] && [ "$_NT_V" -le 100 ] || continue
            case " $_NT_OUT " in
              *" $_NT_V "*) : ;;
              *) _NT_OUT="${_NT_OUT:+$_NT_OUT,}$_NT_V" ;;
            esac
          done
          [ -n "$_NT_OUT" ] && NOTIFY_TRAFFIC_THRESHOLDS=$_NT_OUT ;;
        PROXY_ENABLE)
          case "$value" in 0|1) PROXY_ENABLE=$value ;; esac ;;
        PROXY_SUB_B64)
          if [ -z "$value" ]; then PROXY_SUB_B64=
          elif valid_b64url "$value"; then PROXY_SUB_B64=$value
          fi ;;
        PROXY_MODE)
          case "$value" in auto|fallback|manual) PROXY_MODE=$value ;; esac ;;
        PROXY_BLOCK_QUIC)
          case "$value" in 0|1) PROXY_BLOCK_QUIC=$value ;; esac ;;
        PROXY_SELF)
          case "$value" in 0|1) PROXY_SELF=$value ;; esac ;;
        PROXY_ROUTE_MODE)
          case "$value" in rule|global) PROXY_ROUTE_MODE=$value ;; esac ;;
        PROXY_SCOPE)
          case "$value" in hotspot|self|both) PROXY_SCOPE=$value ;; esac ;;
        SMS_FWD)
          case "$value" in 0|1) SMS_FWD=$value ;; esac ;;
        PORT)
          case "$value" in ''|*[!0-9]*) : ;;
            *) [ "$value" -ge 1024 ] && [ "$value" -le 65535 ] && PORT=$value ;;
          esac ;;
        CHANNEL)
          case "$value" in ''|*[!0-9]*) : ;; *) CHANNEL=$value ;; esac ;;
        MAX_CLIENTS)
          valid_max_clients "$value" && MAX_CLIENTS=$value ;;
        IDLE_SHUTDOWN)
          valid_idle "$value" && IDLE_SHUTDOWN=$value ;;
        DATA_LIMIT_MB)
          # P1-31/32：旧版限额字段——合并进 DATA_PLAN_MB（取非零较大值），不再单独存储
          valid_data_limit "$value" && {
            P=${DATA_PLAN_MB:-0}
            case "$P" in ''|*[!0-9]*) P=0 ;; esac
            [ "$value" -gt "$P" ] 2>/dev/null && DATA_PLAN_MB=$value
          } ;;
        SCHED_ENABLE)
          case "$value" in 0|1) SCHED_ENABLE=$value ;; esac ;;
        SCHED_ON)
          valid_hhmm "$value" && SCHED_ON=$value ;;
        SCHED_OFF)
          valid_hhmm "$value" && SCHED_OFF=$value ;;
        SCHED_ON_WD)
          valid_hhmm "$value" && SCHED_ON_WD=$value ;;
        SCHED_OFF_WD)
          valid_hhmm "$value" && SCHED_OFF_WD=$value ;;
        SCHED_ON_WE)
          valid_hhmm "$value" && SCHED_ON_WE=$value ;;
        SCHED_OFF_WE)
          valid_hhmm "$value" && SCHED_OFF_WE=$value ;;
        SCHED_MODE)
          case "$value" in daily|weekday|weekend) SCHED_MODE=$value ;; esac ;;
        LOWBATT_ENABLE)
          case "$value" in 0|1) LOWBATT_ENABLE=$value ;; esac ;;
        LOWBATT_THRESHOLD)
          case "$value" in ''|*[!0-9]*) : ;;
            *) [ "$value" -ge 1 ] && [ "$value" -le 100 ] && LOWBATT_THRESHOLD=$value ;;
          esac ;;
        DATA_PLAN_MB)
          case "$value" in ''|*[!0-9]*) : ;;
            *) [ "$value" -ge 0 ] && [ "$value" -le 10000000 ] && DATA_PLAN_MB=$value ;;
          esac ;;
        DATA_PLAN_DAY)
          case "$value" in ''|*[!0-9]*) : ;;
            *) [ "$value" -ge 1 ] && [ "$value" -le 31 ] && DATA_PLAN_DAY=$value ;;
          esac ;;
        DATA_LIMIT_ACTION)
          case "$value" in notify|stop) DATA_LIMIT_ACTION=$value ;; esac ;;
        BLOCKED_MACS)
          NEW=
          for m in $value; do
            if valid_mac "$m"; then
              if [ -z "$NEW" ]; then NEW=$m; else NEW="$NEW $m"; fi
            fi
          done
          BLOCKED_MACS=$NEW ;;
        MAC_MODE)
          case "$value" in blacklist|whitelist) MAC_MODE=$value ;; esac ;;
        ALLOWED_MACS)
          NEW=
          for m in $value; do
            if valid_mac "$m"; then
              if [ -z "$NEW" ]; then NEW=$m; else NEW="$NEW $m"; fi
            fi
          done
          ALLOWED_MACS=$NEW ;;
        PUSHPLUS_TOKEN_B64)
          if [ -z "$value" ]; then PUSHPLUS_TOKEN_B64=
          elif valid_b64url "$value"; then PUSHPLUS_TOKEN_B64=$value
          fi ;;
        DINGTALK_WEBHOOK_B64)
          if [ -z "$value" ]; then DINGTALK_WEBHOOK_B64=
          elif valid_b64url "$value"; then DINGTALK_WEBHOOK_B64=$value
          fi ;;
        DINGTALK_SECRET_B64)
          if [ -z "$value" ]; then DINGTALK_SECRET_B64=
          elif valid_b64url "$value"; then DINGTALK_SECRET_B64=$value
          fi ;;
        BARK_KEY_B64)
          if [ -z "$value" ]; then BARK_KEY_B64=
          elif valid_b64url "$value"; then BARK_KEY_B64=$value
          fi ;;
        SMS_FWD_KEYWORD_B64)
          if [ -z "$value" ]; then SMS_FWD_KEYWORD_B64=
          elif valid_b64url "$value"; then SMS_FWD_KEYWORD_B64=$value
          fi ;;
        SMS_FWD_SENDERS_B64)
          if [ -z "$value" ]; then SMS_FWD_SENDERS_B64=
          elif valid_b64url "$value"; then SMS_FWD_SENDERS_B64=$value
          fi ;;
      esac
}

load_config() {
  if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
      case "$line" in
        ''|'#'*) continue ;;
      esac
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        PORT80_MIGRATED)
          # P0-65：两个迁移标记必须独立赋值，不能共用一个分支（否则读任一键会同时改两个标记）
          case "$value" in 0|1) PORT80_MIGRATED=$value ;; esac ;;
        MIGRATE_REMOVED)
          case "$value" in 0|1) MIGRATE_REMOVED=$value ;; esac ;;
        *)
          cfg_apply_key "$key" "$value" ;;
      esac
    done < "$CONFIG"
  fi
  # v1.7.6：热点参数（SSID/密码/安全/频段/信道/隐藏/最大连接数）不再保存于 config.conf，
  # 唯一数据源为系统 WifiConfigStore.xml（Hotspot Compatibility Layer）。
  # 旧配置文件中的历史字段仍由上方 cfg_apply_key 解析到变量，供首次启动时迁移到系统。
  LOWBATT_ENABLE=${LOWBATT_ENABLE:-0}
  LOWBATT_THRESHOLD=${LOWBATT_THRESHOLD:-20}
  DATA_PLAN_MB=${DATA_PLAN_MB:-0}
  DATA_PLAN_DAY=${DATA_PLAN_DAY:-1}
  DATA_LIMIT_ACTION=${DATA_LIMIT_ACTION:-stop}
  AUTOSTART=${AUTOSTART:-1}
  PORT=${PORT:-8080}
  KEEPALIVE=${KEEPALIVE:-1}
  IDLE_SHUTDOWN=${IDLE_SHUTDOWN:-0}
  SCHED_ENABLE=${SCHED_ENABLE:-0}
  SCHED_ON=${SCHED_ON:-2300}
  SCHED_OFF=${SCHED_OFF:-0700}
  SCHED_MODE=${SCHED_MODE:-daily}
  SCHED_ON_WD=${SCHED_ON_WD:-2300}
  SCHED_OFF_WD=${SCHED_OFF_WD:-0700}
  SCHED_ON_WE=${SCHED_ON_WE:-2300}
  SCHED_OFF_WE=${SCHED_OFF_WE:-0700}
  DATA_LIMIT_MB=${DATA_LIMIT_MB:-0}
  PORT80_MIGRATED=${PORT80_MIGRATED:-0}
  MIGRATE_REMOVED=${MIGRATE_REMOVED:-0}
  BLOCKED_MACS=${BLOCKED_MACS:-}
  MAC_MODE=${MAC_MODE:-blacklist}
  ALLOWED_MACS=${ALLOWED_MACS:-}
  PUSHPLUS_TOKEN_B64=${PUSHPLUS_TOKEN_B64:-}
  DINGTALK_WEBHOOK_B64=${DINGTALK_WEBHOOK_B64:-}
  DINGTALK_SECRET_B64=${DINGTALK_SECRET_B64:-}
  BARK_KEY_B64=${BARK_KEY_B64:-}
  NOTIFY_LIMIT=${NOTIFY_LIMIT:-1}
  NOTIFY_TRAFFIC_THRESHOLDS=${NOTIFY_TRAFFIC_THRESHOLDS:-80,90,100}
  PUSHPLUS_TOKEN=$(b64url_decode "$PUSHPLUS_TOKEN_B64")
  DINGTALK_WEBHOOK=$(b64url_decode "$DINGTALK_WEBHOOK_B64")
  DINGTALK_SECRET=$(b64url_decode "$DINGTALK_SECRET_B64")
  BARK_KEY=$(b64url_decode "$BARK_KEY_B64")
  SMS_FWD=${SMS_FWD:-0}
  SMS_FWD_KEYWORD_B64=${SMS_FWD_KEYWORD_B64:-}
  SMS_FWD_SENDERS_B64=${SMS_FWD_SENDERS_B64:-}
  SMS_FWD_KEYWORD=$(b64url_decode "$SMS_FWD_KEYWORD_B64")
  SMS_FWD_SENDERS=$(b64url_decode "$SMS_FWD_SENDERS_B64")
  PROXY_ENABLE=${PROXY_ENABLE:-0}
  PROXY_SUB_B64=${PROXY_SUB_B64:-}
  PROXY_MODE=${PROXY_MODE:-auto}
  PROXY_BLOCK_QUIC=${PROXY_BLOCK_QUIC:-1}
  PROXY_SELF=${PROXY_SELF:-0}
  PROXY_ROUTE_MODE=${PROXY_ROUTE_MODE:-rule}
  PROXY_SCOPE=${PROXY_SCOPE:-hotspot}
}

save_config() {
  # P1-73：配置写锁（mkdir 原子），所有修改串行执行，避免并发保存互相覆盖
  # P1-6(1.5.11)：CFG_TXN=1 表示调用方已在 action 入口持有 config.lock
  # （覆盖 加锁→load_config→修改→save→解锁 全过程，防止并发请求读旧配置后互相覆盖字段）。
  HELD=0
  if [ "${CFG_TXN:-0}" != "1" ]; then
    lock_acquire "$DATA_DIR/config.lock" || return 1
    HELD=1
  fi
  tmp="$CONFIG.tmp.$$"
  {
    # v1.7.6：热点参数（SSID/密码/安全/频段/信道/隐藏/最大连接数）不写入 config.conf，
    # 唯一数据源为系统 WifiConfigStore.xml（Hotspot Compatibility Layer）。
    printf 'AUTOSTART=%s\n' "$AUTOSTART"
    printf 'PORT=%s\n' "$PORT"
    printf 'KEEPALIVE=%s\n' "${KEEPALIVE:-1}"
    printf 'IDLE_SHUTDOWN=%s\n' "${IDLE_SHUTDOWN:-0}"
    printf 'SCHED_ENABLE=%s\n' "${SCHED_ENABLE:-0}"
    printf 'SCHED_ON=%s\n' "${SCHED_ON:-2300}"
    printf 'SCHED_OFF=%s\n' "${SCHED_OFF:-0700}"
    printf 'SCHED_MODE=%s\n' "${SCHED_MODE:-daily}"
    printf 'SCHED_ON_WD=%s\n' "${SCHED_ON_WD:-2300}"
    printf 'SCHED_OFF_WD=%s\n' "${SCHED_OFF_WD:-0700}"
    printf 'SCHED_ON_WE=%s\n' "${SCHED_ON_WE:-2300}"
    printf 'SCHED_OFF_WE=%s\n' "${SCHED_OFF_WE:-0700}"
    printf 'BLOCKED_MACS=%s\n' "$BLOCKED_MACS"
    printf 'MAC_MODE=%s\n' "${MAC_MODE:-blacklist}"
    printf 'ALLOWED_MACS=%s\n' "${ALLOWED_MACS:-}"
    printf 'PUSHPLUS_TOKEN_B64=%s\n' "${PUSHPLUS_TOKEN_B64:-}"
    printf 'DINGTALK_WEBHOOK_B64=%s\n' "${DINGTALK_WEBHOOK_B64:-}"
    printf 'DINGTALK_SECRET_B64=%s\n' "${DINGTALK_SECRET_B64:-}"
    printf 'BARK_KEY_B64=%s\n' "${BARK_KEY_B64:-}"
    printf 'NOTIFY_TRAFFIC_THRESHOLDS=%s\n' "${NOTIFY_TRAFFIC_THRESHOLDS:-80,90,100}"
    printf 'NOTIFY_LIMIT=%s\n' "${NOTIFY_LIMIT:-1}"
    printf 'SMS_FWD=%s\n' "${SMS_FWD:-0}"
    printf 'SMS_FWD_KEYWORD_B64=%s\n' "${SMS_FWD_KEYWORD_B64:-}"
    printf 'SMS_FWD_SENDERS_B64=%s\n' "${SMS_FWD_SENDERS_B64:-}"
    printf 'LOWBATT_ENABLE=%s\n' "${LOWBATT_ENABLE:-0}"
    printf 'LOWBATT_THRESHOLD=%s\n' "${LOWBATT_THRESHOLD:-20}"
    printf 'DATA_PLAN_MB=%s\n' "${DATA_PLAN_MB:-0}"
    printf 'DATA_PLAN_DAY=%s\n' "${DATA_PLAN_DAY:-1}"
    printf 'DATA_LIMIT_ACTION=%s\n' "${DATA_LIMIT_ACTION:-stop}"
    printf 'PROXY_ENABLE=%s\n' "${PROXY_ENABLE:-0}"
    printf 'PROXY_SUB_B64=%s\n' "${PROXY_SUB_B64:-}"
    printf 'PROXY_MODE=%s\n' "${PROXY_MODE:-auto}"
    printf 'PROXY_BLOCK_QUIC=%s\n' "${PROXY_BLOCK_QUIC:-1}"
    printf 'PROXY_SELF=%s\n' "${PROXY_SELF:-0}"
    printf 'PROXY_ROUTE_MODE=%s\n' "${PROXY_ROUTE_MODE:-rule}"
    printf 'PROXY_SCOPE=%s\n' "${PROXY_SCOPE:-hotspot}"
    # P0-64：保留内部迁移标记，避免保存配置后升级迁移被重复执行
    printf 'PORT80_MIGRATED=%s\n' "${PORT80_MIGRATED:-0}"
    printf 'MIGRATE_REMOVED=%s\n' "${MIGRATE_REMOVED:-0}"
  } > "$tmp" 2>/dev/null
  # P1-74：写入失败立即返回错误并保留旧配置
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    [ "$HELD" = "1" ] && lock_release "$DATA_DIR/config.lock"
    return 1
  fi
  chmod 0600 "$tmp"
  if ! mv -f "$tmp" "$CONFIG" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    [ "$HELD" = "1" ] && lock_release "$DATA_DIR/config.lock"
    return 1
  fi
  # P1-145：记录最后保存时间（前端展示“配置最后保存于 …”）
  /system/bin/date '+%Y-%m-%d %H:%M:%S' > "$DATA_DIR/config.saved" 2>/dev/null || date '+%Y-%m-%d %H:%M:%S' > "$DATA_DIR/config.saved" 2>/dev/null
  chmod 0600 "$DATA_DIR/config.saved" 2>/dev/null
  [ "$HELD" = "1" ] && lock_release "$DATA_DIR/config.lock"
  return 0
}


# 默认路由上游接口（Android policy routing：default 路由在非 main table，
# `ip route show default` 只查 main table 会返回空 → 必须 table all 探测）。
# WiFi 并发中继时优先 wlan*（手机默认路由的上行 Wi-Fi）；否则取第一条 default。
get_upstream_iface() {
  UP=$(/system/bin/ip -4 route show table all 2>/dev/null | "$BB" grep '^default' \
    | "$BB" grep -oE 'dev [^ ]+' | "$BB" awk '{print $2}' | "$BB" head -n5)
  for I in $UP; do
    case "$I" in wlan[0-9]*) printf '%s' "$I"; return ;; esac
  done
  printf '%s' "$UP" | "$BB" head -n1
}

# v1.7.9：热点下游接口识别（修复 WiFi 并发下识别错接口）：
#   热点下游接口 = Tethering 已共享接口 - 默认路由上游接口 - lo - 移动数据接口
# 识别优先级（禁止固定 wlan2 / 禁止用"第一个 wlan*"）：
#   1) bridge tether-state 的 ifaces（系统 Tethering 共享接口，快、可靠）
#   2) ip 层探测：非上游的 wlan*/ap*/softap* 接口（排除 rmnet/移动数据/lo）
#   3) dumpsys wifi 的 SoftApManager role=ROLE_SOFTAP_TETHERED（最终权威）
# 无法可靠识别 → 返回空，调用方停止应用模块规则（不猜测接口）。
get_hotspot_iface() {
  # 默认路由上游接口（明确排除：它是手机的上行，不是热点下游）
  UP=$(get_upstream_iface)
  # 1) bridge tether-state（最快、反映系统 Tethering 真实共享接口）
  if bridge_available; then
    TIF=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null       | "$BB" sed -n 's/^ifaces=//p' | "$BB" cut -d, -f1 | "$BB" tr -d ' \r\n')
    case "$TIF" in
      wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|wlan_ap[0-9]*|apbr[0-9]*)
        [ "$TIF" != "$UP" ] || TIF=
        case "$TIF" in rmnet*|ccmni*|wwan*|miw_oem*|p2p*|lo) TIF= ;; esac
        [ -n "$TIF" ] && { printf '%s' "$TIF"; return; }
        ;;
    esac
  fi
  # 2) ip 层探测：非上游接口且带热点网段（scope link 路由），排除移动数据
  for IF in $(/system/bin/ip -o link show 2>/dev/null | "$BB" sed -n 's/^[0-9]*: \([a-zA-Z0-9_]*\):.*/\1/p'); do
    case "$IF" in
      wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|wlan_ap[0-9]*|apbr[0-9]*)
        [ "$IF" != "$UP" ] || continue
        if /system/bin/ip -o -4 route show dev "$IF" scope link 2>/dev/null | "$BB" grep -q ' src '; then
          printf '%s' "$IF"; return
        fi
        ;;
    esac
  done
  # 3) dumpsys wifi SoftApManager role=ROLE_SOFTAP_TETHERED（最终权威，较慢）
  IF2=$("$BB" timeout 5 /system/bin/dumpsys wifi 2>/dev/null     | "$BB" grep -oE 'SoftApManager\{[^}]*iface=[a-zA-Z0-9_]+ role=ROLE_SOFTAP_TETHERED'     | "$BB" head -n1 | "$BB" grep -oE 'iface=[a-zA-Z0-9_]+' | "$BB" cut -d= -f2 | "$BB" tr -d ' \r\n')
  case "$IF2" in
    wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|wlan_ap[0-9]*|apbr[0-9]*)
      [ "$IF2" != "$UP" ] || IF2=
      case "$IF2" in rmnet*|ccmni*|wwan*|miw_oem*|p2p*|lo) IF2= ;; esac
      [ -n "$IF2" ] && { printf '%s' "$IF2"; return; }
      ;;
  esac
  return 0
}

# v1.7.9：热点自建 DHCP/NAT 兜底（修复"热点半开"——SoftAP 起来但系统 Tethering
# 因 Binder 调用者身份限制不建 DHCP，设备连上拿不到地址）。
# 仅在系统 DHCP 未建立时启用（接口上没有系统网段 IPv4）；系统路径正常（如 Settings
# 开的 172.18.100.120/24）则不动任何系统配置，只应用模块规则。
# 自建内容：管理网段 $STABLE_IP/24 + udhcpd DHCP + MASQUERADE(→默认路由上游) + ip_forward。
# 返回 0=已就绪（系统 DHCP 正常或自建成功）；1=无法自建（调用方记日志，不猜测）。
ensure_hotspot_dhcp() {
  iface=$1
  [ -n "$iface" ] || return 1
  # 接口上已有系统网段地址（非模块管理别名）→ 系统 DHCP 已建，不干预
  SYS_IP=$(/system/bin/ip -o -4 addr show dev "$iface" 2>/dev/null | "$BB" awk -v s="$STABLE_IP" '{split($4,a,"/"); if (a[1]!=s) {print a[1]; exit}}')
  [ -n "$SYS_IP" ] && return 0
  # 1) 管理网段地址（含网关，供 DHCP 与后台使用）
  /system/bin/ip addr replace "$STABLE_IP/24" dev "$iface" 2>/dev/null
  # 2) 上游接口（默认路由；WiFi 并发时为 wlan0，蜂窝 IPv4 时为其 rmnet/ccmni）
  #    Android policy routing：必须 table all 探测 default（main table 为空）
  UP=$(get_upstream_iface)
  [ -n "$UP" ] && [ "$UP" != "$iface" ] || return 1
  # 3) ip_forward + 转发放行（记录原值供 cleanup 恢复；不重置系统其他链）
  FWD_BEFORE=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null | "$BB" tr -d ' ')
  printf '%s' "$FWD_BEFORE" > "$DATA_DIR/ip_forward.orig" 2>/dev/null
  echo 1 > /proc/sys/net/ipv4/ip_forward
  $IPT -t nat -C POSTROUTING -s "$STABLE_IP/24" -o "$UP" -j MASQUERADE 2>/dev/null     || $IPT -t nat -A POSTROUTING -s "$STABLE_IP/24" -o "$UP" -j MASQUERADE 2>/dev/null
  $IPT -C FORWARD -i "$iface" -o "$UP" -j ACCEPT 2>/dev/null     || $IPT -I FORWARD 1 -i "$iface" -o "$UP" -j ACCEPT 2>/dev/null
  $IPT -C FORWARD -i "$UP" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null     || $IPT -I FORWARD 2 -i "$UP" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  # 4) DHCP：busybox udhcpd（系统 dnsmasq 参数受限不可靠）
  # v1.8.0：杀旧实例后等待 exec/退出完成，避免启动瞬间双实例抢 67 端口
  kill_udhcpd 2>/dev/null
  sleep 1
  {
    printf 'interface %s\n' "$iface"
    printf 'start %s.2\n' "${STABLE_IP%.*}"
    printf 'end %s.254\n' "${STABLE_IP%.*}"
    printf 'opt subnet 255.255.255.0\n'
    printf 'opt router %s\n' "$STABLE_IP"
    printf 'opt dns 8.8.8.8 8.8.4.4\n'
    printf 'opt lease 86400\n'
    printf 'lease_file %s/udhcpd.leases\n' "$DATA_DIR"
  } > "$DATA_DIR/udhcpd.conf" 2>/dev/null
  # 预创建 lease 文件：/var 在 Android 上只读，默认路径打不开；
  # 用数据目录下的文件（busybox 打开失败仅警告不退出，但预建后无噪音且可持久化租约）
  : > "$DATA_DIR/udhcpd.leases" 2>/dev/null
  rm -f "$DATA_DIR/udhcpd.pid" 2>/dev/null
  "$BB" udhcpd -f "$DATA_DIR/udhcpd.conf" >> "$DATA_DIR/udhcpd.log" 2>&1 &
  echo "$(date) ensure_hotspot_dhcp: self-built DHCP/NAT on $iface (upstream $UP, subnet ${STABLE_IP%.*}.0/24)" >> "$LOG" 2>/dev/null
  return 0
}

# 停止自建 DHCP/NAT（热点关闭/重启前调用；只清模块自建项，不动系统链）
cleanup_hotspot_dhcp() {
  iface=$1
  kill_udhcpd 2>/dev/null
  [ -n "$iface" ] || return 0
  # v1.7.9+：清理热点接口的流量统计/转发链 FORWARD 引用（旧接口 wlan2 已消失，
  # 规则残留且反复开关会重复累积）。循环删除直到不存在；链定义保留可复用。
  while $IPT -C FORWARD -i "$iface" -j mifi_stats 2>/dev/null; do
    $IPT -D FORWARD -i "$iface" -j mifi_stats 2>/dev/null
  done
  while $IPT -C FORWARD -i "$iface" -j mifi_up 2>/dev/null; do
    $IPT -D FORWARD -i "$iface" -j mifi_up 2>/dev/null
  done
  while $IPT -C FORWARD -o "$iface" -j mifi_dn 2>/dev/null; do
    $IPT -D FORWARD -o "$iface" -j mifi_dn 2>/dev/null
  done
  $IPT -F mifi_stats 2>/dev/null
  $IPT -F mifi_up 2>/dev/null
  $IPT -F mifi_dn 2>/dev/null
  UP=$(get_upstream_iface)
  if [ -n "$UP" ]; then
    $IPT -t nat -D POSTROUTING -s "$STABLE_IP/24" -o "$UP" -j MASQUERADE 2>/dev/null
    $IPT -D FORWARD -i "$iface" -o "$UP" -j ACCEPT 2>/dev/null
    $IPT -D FORWARD -i "$UP" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  fi
  /system/bin/ip addr del "$STABLE_IP/24" dev "$iface" 2>/dev/null
  # 恢复 ip_forward 原值（仅还原到模块启动前的值，避免影响系统其他转发）
  if [ -r "$DATA_DIR/ip_forward.orig" ]; then
    ORIG=$(cat "$DATA_DIR/ip_forward.orig" 2>/dev/null | "$BB" tr -d ' ')
    case "$ORIG" in 0|1) printf '%s' "$ORIG" > /proc/sys/net/ipv4/ip_forward 2>/dev/null ;; esac
    rm -f "$DATA_DIR/ip_forward.orig" 2>/dev/null
  fi
  return 0
}

# 停掉模块启动的 udhcpd（按配置文件路径匹配，避免误杀系统 DHCP）。
# 注意：busybox 多进程的进程名都是 busybox，pidof udhcpd 匹配不到，
# 必须 ps 扫描 cmdline（含 udhcpd 关键字）再按配置路径过滤。
kill_udhcpd() {
  for P in $(ps -A -o PID,CMDLINE 2>/dev/null | "$BB" grep 'udhcpd' | "$BB" grep -v grep | "$BB" awk '{print $1}'); do
    CMD=$(cat "/proc/$P/cmdline" 2>/dev/null | "$BB" tr '\000' ' ')
    case "$CMD" in *"$DATA_DIR/udhcpd.conf"*) kill "$P" 2>/dev/null ;; esac
  done
  return 0
}

get_iface_ip() {
  iface=$1
  [ -z "$iface" ] && return
  /system/bin/ip -o -4 addr show dev "$iface" 2>/dev/null | "$BB" awk '{split($4,a,"/"); print a[1]; exit}'
}

# 原生热点地址：排除模块固定管理别名 STABLE_IP，取接口上的其他 IPv4 地址（热点真实网关）
get_native_hotspot_ip() {
  iface=$1
  [ -z "$iface" ] && return
  /system/bin/ip -o -4 addr show dev "$iface" 2>/dev/null | "$BB" awk -v stable="$STABLE_IP" '
    { split($4, a, "/"); if (a[1] != stable) { print a[1]; exit } }
  ' | "$BB" head -n 1
}

# 热点真实网段：优先内核路由 scope link（含真实掩码），回退按原生地址 /24 推导，再回退固定网段
get_hotspot_subnet() {
  iface=$1
  [ -z "$iface" ] && { printf '192.168.43.0/24'; return; }
  NET=$(/system/bin/ip -o -4 route show dev "$iface" scope link 2>/dev/null | "$BB" awk '{print $1; exit}')
  case "$NET" in
    *.*.*.*/*) printf '%s' "$NET"; return ;;
  esac
  IP=$(get_native_hotspot_ip "$iface")
  case "$IP" in
    *.*.*.*) printf '%s.0/24' "${IP%.*}"; return ;;
  esac
  printf '192.168.43.0/24'
}

get_management_ip() {
  iface=$1
  [ -z "$iface" ] && return
  if /system/bin/ip -o -4 addr show dev "$iface" 2>/dev/null | "$BB" grep -q " $STABLE_IP/"; then
    printf '%s' "$STABLE_IP"
  else
    # v1.7.7：固定管理地址为兼容性硬性要求，不降级为系统热点网关；
    # 调用方在输出 unavailable 时提示“未通过兼容性验证”。
    printf 'unavailable'
  fi
}

add_management_alias() {
  iface=$1
  [ -z "$iface" ] && return 1
  if /system/bin/ip -o -4 addr show dev "$iface" 2>/dev/null | "$BB" grep -q " $STABLE_IP/"; then
    return 0
  fi
  /system/bin/ip addr add "$STABLE_IP/32" dev "$iface" 2>/dev/null
}

remove_management_alias() {
  iface=$1
  [ -z "$iface" ] && return 0
  /system/bin/ip addr del "$STABLE_IP/32" dev "$iface" 2>/dev/null || true
}

valid_b64url() {
  case "$1" in
    *[!A-Za-z0-9_-]*|'') return 1 ;;
    *) return 0 ;;
  esac
}

valid_mac() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
    *) return 1 ;;
  esac
}

valid_hhmm() {
  # 严格校验：必须 4 位数字，小时 00–23，分钟 00–59（拒绝 9960 / 2561 这类值）
  case "$1" in
    [0-9][0-9][0-9][0-9])
      HH=${1%??}
      MM=${1#??}
      [ "$HH" -le 23 ] && [ "$MM" -le 59 ]
      ;;
    *) return 1 ;;
  esac
}

# 信道校验（v1.7.6：由设备 SoftApCapability 实测信道列表驱动，不再写死固定列表）
# channel=0 表示自动（任何频段均合法）；band=any 只允许自动；
# 有实测列表则校验在列表内；无列表（能力缺失）只校验数字格式，信任前端按能力显示。
valid_channel() {
  band=$1
  channel=$2
  case "$channel" in
    ''|0) return 0 ;;
    *[!0-9]*) return 1 ;;
  esac
  case "$band" in
    2|5|6)
      hotspot_get_capabilities >/dev/null 2>&1
      LIST=
      case "$band" in
        2) LIST=$(printf '%s' "$HOTSPOT_CAPS_JSON" | "$BB" sed -n 's/.*"channels2g":\[\([0-9,]*\)\].*/\1/p') ;;
        5) LIST=$(printf '%s' "$HOTSPOT_CAPS_JSON" | "$BB" sed -n 's/.*"channels5g":\[\([0-9,]*\)\].*/\1/p') ;;
        6) LIST=$(printf '%s' "$HOTSPOT_CAPS_JSON" | "$BB" sed -n 's/.*"channels6g":\[\([0-9,]*\)\].*/\1/p') ;;
      esac
      if [ -n "$LIST" ]; then
        case ",$LIST," in *",$channel,"*) return 0 ;; esac
        return 1
      fi
      return 0
      ;;
    any) return 1 ;;
  esac
  return 1
}

# 最大连接数 0–32；空闲关闭 0 或 1–600 分钟
valid_max_clients() {
  # v1.7.9：第 2 参数为设备动态上限（get_max_clients_limit），缺省 32（兼容旧调用/测试）
  case "$1" in
    ''|0) return 0 ;;
    *[!0-9]*) return 1 ;;
    *) MAXLIM=${2:-32}; case "$MAXLIM" in ''|*[!0-9]*) MAXLIM=32 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le "$MAXLIM" ] ;;
  esac
}

valid_idle() {
  case "$1" in
    ''|0) return 0 ;;
    *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 600 ] ;;
  esac
}

# 流量限额 0–10,000,000 MB（0=关闭）
valid_data_limit() {
  case "$1" in
    ''|0) return 0 ;;
    *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 10000000 ] ;;
  esac
}


read_csrf_token() {
  [ -r "$CSRF_FILE" ] && "$BB" head -n 1 "$CSRF_FILE" 2>/dev/null
}

write_operation() {
  state=$1
  message=$2
  now=$(/system/bin/date +%s 2>/dev/null || date +%s)
  tmp="$OP_STATUS.tmp.$$"
  {
    printf 'STATE=%s\n' "$state"
    printf 'TIME=%s\n' "$now"
    printf 'MESSAGE_B64='
    printf '%s' "$message" | "$BB" base64 | "$BB" tr -d '\r\n'
    printf '\n'
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$OP_STATUS"
}

read_operation() {
  OP_STATE=idle
  OP_TIME=0
  OP_MESSAGE=
  if [ -r "$OP_STATUS" ]; then
    OP_STATE=$("$BB" sed -n 's/^STATE=//p' "$OP_STATUS" | "$BB" head -n 1)
    OP_TIME=$("$BB" sed -n 's/^TIME=//p' "$OP_STATUS" | "$BB" head -n 1)
    OP_MESSAGE_B64=$("$BB" sed -n 's/^MESSAGE_B64=//p' "$OP_STATUS" | "$BB" head -n 1)
    OP_MESSAGE=$(printf '%s' "$OP_MESSAGE_B64" | "$BB" base64 -d 2>/dev/null)
  fi
  case "$OP_STATE" in idle|working|success|error) : ;; *) OP_STATE=error ;; esac
  case "$OP_TIME" in ''|*[!0-9]*) OP_TIME=0 ;; esac
}

acquire_operation_lock() {
  if mkdir "$OP_LOCK" 2>/dev/null; then
    /system/bin/date +%s > "$OP_LOCK/created" 2>/dev/null || date +%s > "$OP_LOCK/created"
    return 0
  fi

  created=$("$BB" head -n 1 "$OP_LOCK/created" 2>/dev/null)
  now=$(/system/bin/date +%s 2>/dev/null || date +%s)
  case "$created" in ''|*[!0-9]*) created=0 ;; esac
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  if [ "$created" -eq 0 ] || [ $((now - created)) -gt 35 ]; then
    rm -rf "$OP_LOCK"
    mkdir "$OP_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$now" > "$OP_LOCK/created"
    return 0
  fi
  return 1
}

release_operation_lock() {
  rm -rf "$OP_LOCK"
}

# ============================================================
# 系统 SoftAP 配置（一套配置：Web 与系统设置共用 WifiConfigStore.xml）
# Android 11+ 热点配置持久化于 /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml，
# 系统设置（Wi-Fi 热点）与本模块读写同一份，杜绝"两套配置"。
# SYS_WIFI_STORE 可被测试覆盖；解析/写入均不依赖 root 特性（纯文件操作）。
# ============================================================
SYS_WIFI_STORE=/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml

# 安全类型：系统 SoftApConfiguration SecurityType → 模块 security 值
# AOSP: 0=OPEN 1=WPA2_PSK 2=WPA3_SAE_TRANSITION 3=WPA3_SAE 4=WPA3_OWE_TRANSITION 5=WPA3_OWE
sys_security_type_name() {
  case "$1" in
    0) printf 'open' ;;
    1) printf 'wpa2' ;;
    2) printf 'wpa3_transition' ;;
    3) printf 'wpa3' ;;
    4) printf 'owe_transition' ;;
    5) printf 'owe' ;;
    *) printf 'wpa2' ;;
  esac
}
# 模块 security 值 → 系统 SecurityType
sys_security_type_val() {
  case "$1" in
    open) printf '0' ;;
    wpa3) printf '3' ;;
    wpa3_transition) printf '2' ;;
    owe_transition) printf '4' ;;
    owe) printf '5' ;;
    *) printf '1' ;;
  esac
}
# 系统 Band（AOSP: 1=2.4G 2=5G 4=6G 7=any）→ 模块 band
sys_band_name() {
  case "$1" in
    1) printf '2' ;;
    2) printf '5' ;;
    4) printf '6' ;;
    *) printf 'any' ;;
  esac
}
# 模块 band → 系统 Band
sys_band_val() {
  case "$1" in
    2) printf '1' ;;
    5) printf '2' ;;
    6) printf '4' ;;
    *) printf '7' ;;
  esac
}

# 读取系统 SoftAP 段 → 设置 sys_ssid/sys_security/sys_password/sys_band/sys_channel/sys_hidden/sys_maxclients/sys_ok
# sys_ok=1 成功；=0 文件缺失或无 SoftAp 段（调用方按系统默认处理）。
# 兼容两种标签：旧版 <string name="WifiSsid">&quot;X&quot;</string>（引号实体包裹）、
# 新版（SoftApConfToXmlMigration）<string name="SSID">X</string>。
sys_softap_get() {
  [ -r "$SYS_WIFI_STORE" ] || return 0
  sys_ok=0
  sys_ssid=; sys_security=wpa2; sys_password=; sys_band=any; sys_channel=0; sys_hidden=0; sys_maxclients=0
  [ -r "$SYS_WIFI_STORE" ] || return 0
  IN_AP=0
  while IFS= read -r LINE; do
    case "$LINE" in
      *'<SoftAp>'*) IN_AP=1; continue ;;
      *'</SoftAp>'*) IN_AP=0; continue ;;
    esac
    [ "$IN_AP" = "1" ] || continue
    case "$LINE" in
      *'<string name="WifiSsid">'*)
        # WifiSsid 序列化约定：内容带外层 &quot; 包裹（引号实体），需剥掉后再解码实体
        V=${LINE#*'<string name="WifiSsid">'}; V=${V%%'</string>'*}
        V=$(printf '%s' "$V" | "$BB" sed 's/&quot;/"/g;s/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g')
        case "$V" in
          '"'*) V=${V#'"'} ;;
        esac
        case "$V" in
          *'"') V=${V%'"'} ;;
        esac
        sys_ssid=$V; sys_ok=1 ;;
      *'<string name="SSID">'*)
        V=${LINE#*'<string name="SSID">'}; V=${V%%'</string>'*}
        V=$(printf '%s' "$V" | "$BB" sed 's/&quot;/"/g;s/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g')
        sys_ssid=$V; sys_ok=1 ;;
      *'<string name="Passphrase">'*)
        V=${LINE#*'<string name="Passphrase">'}; V=${V%%'</string>'*}
        V=$(printf '%s' "$V" | "$BB" sed 's/&quot;/"/g;s/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g')
        sys_password=$V ;;
      *'<boolean name="HiddenSSID"'*)
        case "$LINE" in *'value="true"'*) sys_hidden=1 ;; *) sys_hidden=0 ;; esac ;;
      *'<int name="SecurityType"'*)
        V=${LINE#*'value="'}; V=${V%%'"'*}
        sys_security=$(sys_security_type_name "$V") ;;
      *'<int name="Band"'*)
        V=${LINE#*'value="'}; V=${V%%'"'*}
        sys_band=$(sys_band_name "$V") ;;
      *'<int name="Channel"'*)
        V=${LINE#*'value="'}; V=${V%%'"'*}
        case "$V" in ''|*[!0-9]*) V=0 ;; esac
        sys_channel=$V ;;
      *'<int name="MaxNumberOfClients"'*)
        V=${LINE#*'value="'}; V=${V%%'"'*}
        case "$V" in ''|*[!0-9]*) V=0 ;; esac
        sys_maxclients=$V ;;
    esac
  done < "$SYS_WIFI_STORE" 2>/dev/null
  return 0
}

# XML 转义（ssid/密码 写入前）
sys_xml_escape() {
  printf '%s' "$1" | "$BB" sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'
}

# 从系统 SoftAP 段输出当前配置 KEY=VAL（status/UI 用）
sys_softap_status() {
  sys_softap_get
  printf 'ssid=%s\n' "$sys_ssid"
  printf 'security=%s\n' "$sys_security"
  printf 'band=%s\n' "$sys_band"
  printf 'channel=%s\n' "$sys_channel"
  printf 'hidden=%s\n' "$sys_hidden"
  printf 'maxClients=%s\n' "$sys_maxclients"
  if [ "$sys_security" = "open" ]; then
    printf 'passwordSet=0\n'
  else
    [ -n "$sys_password" ] && printf 'passwordSet=1\n' || printf 'passwordSet=0\n'
  fi
}

# 隐藏 SSID 能力检测（v1.7.6：由 SoftApConfiguration Framework capability 决定，
# 不再看 cmd wifi -h——系统 Framework 支持 setHiddenSsid 与 shell 命令无关）
softap_hidden_supported() {
  hotspot_get_capabilities >/dev/null 2>&1
  case "$HOTSPOT_CAPS_JSON" in *'"hiddenSsid":true'*) return 0 ;; esac
  return 1
}

run_softap() {
  # v1.7.6：热点启动统一走 Hotspot Compatibility Layer 的 hotspot_start
  # （Generic Backend = 系统 Tethering；迁移/回退逻辑在 lib/compat.sh）
  hotspot_start "$@"
  return $?
}


# ---------- 客户端 MAC 访问策略（黑名单/白名单统一专用链 mifi_acl，v1.7.7） ----------
# 黑名单、白名单共用 FORWARD → mifi_acl；策略变化时 flush+重建，不做“猜旧规则逐条删”，
# 修复 whitelist→blacklist 切换时旧链残留导致规则仍生效的问题；IPv6 同步管控。
rebuild_acl_chain() {
  # 先删后建（幂等）：清内容 → 删链 → 重建 → 再清空
  $IPT -F mifi_acl 2>/dev/null || true
  $IPT -X mifi_acl 2>/dev/null || true
  $IPT -N mifi_acl 2>/dev/null || { $IPT -F mifi_acl 2>/dev/null; }
  $IPT -F mifi_acl 2>/dev/null
}

apply_mac_policy() {
  iface=$1
  [ -z "$iface" ] && return 0
  N=0
  while [ "$N" -lt 20 ] && $IPT -C FORWARD -i "$iface" -j mifi_acl 2>/dev/null; do
    $IPT -D FORWARD -i "$iface" -j mifi_acl 2>/dev/null
    N=$((N + 1))
  done
  rebuild_acl_chain
  if [ "${MAC_MODE:-blacklist}" = "whitelist" ]; then
    # 白名单：允许 MAC RETURN 放行，其余 DROP 兜底
    for mac in $ALLOWED_MACS; do
      valid_mac "$mac" || continue
      $IPT -A mifi_acl -i "$iface" -m mac --mac-source "$mac" -j RETURN 2>/dev/null
    done
    $IPT -A mifi_acl -j DROP 2>/dev/null
    fw6_ensure "$iface"
  else
    # 黑名单：名单 MAC DROP，其余 RETURN 兜底（不阻断正常流量）
    for mac in $BLOCKED_MACS; do
      valid_mac "$mac" || continue
      $IPT -A mifi_acl -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
    done
    $IPT -A mifi_acl -j RETURN 2>/dev/null
    [ -n "$BLOCKED_MACS" ] && fw6_ensure "$iface"
  fi
  $IPT -I FORWARD 1 -i "$iface" -j mifi_acl 2>/dev/null
  return 0
}

apply_blacklist() {
  iface=$1
  [ -z "$iface" ] && return 0
  apply_mac_policy "$iface"
}

apply_whitelist() {
  iface=$1
  [ -z "$iface" ] && return 0
  apply_mac_policy "$iface"
}

# 清理旧版（v1.7.6 及更早）直插 FORWARD/INPUT DROP 规则（升级/接口变化时兼容清理）
clear_blacklist_rules() {
  iface=$1
  [ -z "$iface" ] && return 0
  for mac in $BLOCKED_MACS; do
    valid_mac "$mac" || continue
    N=0
    while [ "$N" -lt 20 ] && $IPT -C FORWARD -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
      $IPT -D FORWARD -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
      N=$((N + 1))
    done
    N=0
    while [ "$N" -lt 20 ] && $IPT -C INPUT -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
      $IPT -D INPUT -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
      N=$((N + 1))
    done
  done
}

# 清理 mifi_acl 链：先删 FORWARD 跳转，再清链删除
clear_mac_acl() {
  iface=$1
  [ -z "$iface" ] && return 0
  N=0
  while [ "$N" -lt 20 ] && $IPT -C FORWARD -i "$iface" -j mifi_acl 2>/dev/null; do
    $IPT -D FORWARD -i "$iface" -j mifi_acl 2>/dev/null
    N=$((N + 1))
  done
  $IPT -F mifi_acl 2>/dev/null || true
  $IPT -X mifi_acl 2>/dev/null || true
  fw6_clear "$iface"
}

# 全量清理（热点停止/接口变化等场景）：旧直插规则 + 专用链 + IPv6
clear_blacklist() {
  iface=$1
  [ -z "$iface" ] && return 0
  clear_blacklist_rules "$iface"
  clear_mac_acl "$iface"
}

# 单设备解禁：新实现（mifi_acl 链内删）+ 旧版直插规则兼容
unblock_one_mac() {
  iface=$1
  mac=$2
  valid_mac "$mac" || return 1
  N=0
  while [ "$N" -lt 20 ] && $IPT -C mifi_acl -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
    $IPT -D mifi_acl -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
    N=$((N + 1))
  done
  N=0
  while [ "$N" -lt 20 ] && $IPT -C FORWARD -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
    $IPT -D FORWARD -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
    N=$((N + 1))
  done
  N=0
  while [ "$N" -lt 20 ] && $IPT -C INPUT -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null; do
    $IPT -D INPUT -i "$iface" -m mac --mac-source "$mac" -j DROP 2>/dev/null
    N=$((N + 1))
  done
}

# ---------- IPv6 管控（方案 B） ----------
# Android Tethering 双栈：MAC ACL / 透明代理为 IPv4 规则，无法约束 IPv6。
# 启用名单管控时显式 DROP 热点 downstream IPv6（FORWARD 方向，不影响本机/上游），
# 避免“IPv4 已禁、IPv6 仍通”；管控全部关闭时由 fw6_clear 恢复。
fw6_ensure() {
  command -v "$IPT6" >/dev/null 2>&1 || return 0
  iface=$1
  # v1.7.9：IPv6 管控必须限定热点接口，禁止全局丢弃所有 IPv6 转发（会连带 USB 共享等业务断网）
  [ -z "$iface" ] && return 0
  $IPT6 -N mifi_ipv6 2>/dev/null || { $IPT6 -F mifi_ipv6 2>/dev/null; }
  $IPT6 -F mifi_ipv6 2>/dev/null
  $IPT6 -A mifi_ipv6 -j DROP 2>/dev/null
  $IPT6 -C FORWARD -i "$iface" -j mifi_ipv6 2>/dev/null || $IPT6 -I FORWARD 1 -i "$iface" -j mifi_ipv6 2>/dev/null
  return 0
}

fw6_clear() {
  command -v "$IPT6" >/dev/null 2>&1 || return 0
  iface=$1
  N=0
  if [ -n "$iface" ]; then
    while [ "$N" -lt 20 ] && $IPT6 -C FORWARD -i "$iface" -j mifi_ipv6 2>/dev/null; do
      $IPT6 -D FORWARD -i "$iface" -j mifi_ipv6 2>/dev/null
      N=$((N + 1))
    done
  else
    # 无接口参数（卸载兜底）：清理任意引用
    while [ "$N" -lt 20 ] && $IPT6 -C FORWARD -j mifi_ipv6 2>/dev/null; do
      $IPT6 -D FORWARD -j mifi_ipv6 2>/dev/null
      N=$((N + 1))
    done
  fi
  $IPT6 -F mifi_ipv6 2>/dev/null || true
  $IPT6 -X mifi_ipv6 2>/dev/null || true
  return 0
}

# ---------- 客户端流量统计（FORWARD 计数链） ----------
ensure_stats_chain() {
  iface=$1
  [ -z "$iface" ] && return 0
  $IPT -N mifi_stats 2>/dev/null || true
  $IPT -C FORWARD -i "$iface" -j mifi_stats 2>/dev/null || \
    $IPT -I FORWARD 1 -i "$iface" -j mifi_stats 2>/dev/null
}

flush_stats_chain() {
  $IPT -F mifi_stats 2>/dev/null || true
}

update_stats_rules() {
  iface=$1
  shift
  for ip in "$@"; do
    case "$ip" in ''|*[!0-9.]*) continue ;; esac
    $IPT -C mifi_stats -s "$ip" -j RETURN 2>/dev/null || \
      $IPT -A mifi_stats -s "$ip" -j RETURN 2>/dev/null
    $IPT -C mifi_stats -d "$ip" -j RETURN 2>/dev/null || \
      $IPT -A mifi_stats -d "$ip" -j RETURN 2>/dev/null
  done
}

# 读一次全量统计，生成 "ip rx tx" 行
# 链规则：-s 客户端IP 匹配的是客户端上行（tx）；-d 客户端IP 匹配下行（rx）。
# 输出列序必须为 rx=下行、tx=上行，status.cgi 按第2/3列取数。
read_all_stats() {
  # P1-35：遍历 rx/tx 键并集——只有上行（-s 规则命中）的纯上行设备也要出现在输出里
  $IPT -L mifi_stats -n -v -x 2>/dev/null | "$BB" awk '
    $3=="RETURN" && $8 ~ /^[0-9.]+$/ {tx[$8]+=$2}
    $3=="RETURN" && $9 ~ /^[0-9.]+$/ {rx[$9]+=$2}
    END {
      for (ip in rx) print ip, rx[ip]+0, tx[ip]+0
      for (ip in tx) if (!(ip in rx)) print ip, 0, tx[ip]+0
    }
  '
}

get_ip_usage() {
  printf '%s\n' "$STAT_MAP" | "$BB" awk -v ip="$1" '$1==ip{print $2+0, $3+0; exit}'
}

# 统一在线客户端发现：/proc/net/arp（DHCP 后必有条目，最可靠）与
# ip neigh（给出 REACHABLE/STALE 等实时状态）双数据源合并，按 IP 去重。
# 仅统计热点接口上的条目；输出每行: IP|MAC|STATE
list_clients() {
  iface=$1
  [ -z "$iface" ] && return 0
  {
    # ip neigh 为主：给出 REACHABLE/STALE/DELAY/PROBE 等实时状态，先输出保证同 IP 去重时保留
    /system/bin/ip neigh show dev "$iface" 2>/dev/null | "$BB" awk '
      $1 ~ /:/ {next}
      $4=="lladdr" && $5!="00:00:00:00:00:00" && $6!="FAILED" && $6!="INCOMPLETE" {print $1"|"$5"|"$6}
    '
    # ARP 仅补全：neigh 未覆盖的 IP 提供 MAC（状态 ARP，不参与在线判定）
    if [ -r /proc/net/arp ]; then
      # 列序: IP(1) HWtype(2) Flags(3) MAC(4) Mask(5) Device(6)；0x2=完整条目
      "$BB" awk -v dev="$iface" 'NR>1 && $6==dev && $3=="0x2" && $4!="00:00:00:00:00:00" {print $1"|"$4"|ARP"}' /proc/net/arp
    fi
  } | "$BB" awk -F'|' '!($1 in seen) {seen[$1]=1; print}'
}

# 在线客户端数（用于空闲自动关闭）：只统计确认活跃的条目。
# REACHABLE/DELAY/PROBE 算在线；ARP(0x2 完整条目) 仅补全 MAC 不算在线，
# 避免 ARP 缓存残留导致空闲倒计时迟迟不启动。
count_online_clients() {
  iface=$1
  [ -z "$iface" ] && { echo 0; return; }
  list_clients "$iface" 2>/dev/null | "$BB" awk -F'|' '$3=="REACHABLE"||$3=="DELAY"||$3=="PROBE" {n++} END {print n+0}'
}

# 已连接客户端数（v1.5.13，用于空闲自动关闭）：邻居状态变 STALE/ARP 只表示
# 一段时间无通信，Wi-Fi 实际仍连着；若只算活跃状态会把已连接设备误判为离线，
# 导致有设备时仍倒计时并误关热点。页面"活跃设备"仍用 count_online_clients。
count_connected_clients() {
  iface=$1
  [ -z "$iface" ] && { echo 0; return; }
  list_clients "$iface" 2>/dev/null | "$BB" awk -F'|' '
    $3=="REACHABLE" || $3=="DELAY" || $3=="PROBE" || $3=="STALE" || $3=="ARP" { n++ }
    END { print n+0 }'
}

# ---------- 上网共享（NAT/转发）检测 ----------
# v1.5.2：区分“存在任意 MASQUERADE”与“热点相关的 NAT 规则”，
# 后者按热点管理网段 192.168.43.0/24 或热点接口名匹配。
check_tethering() {
  iface=$1
  TETHER_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null | "$BB" tr -d ' ')
  [ -z "$TETHER_FWD" ] && TETHER_FWD=0
  NAT_FILE="$DATA_DIR/iptables_nat.tmp.$$"
  "$BB" timeout 3 $IPT -t nat -S > "$NAT_FILE" 2>/dev/null || : > "$NAT_FILE"
  TETHER_NAT=$("$BB" grep -c MASQUERADE "$NAT_FILE" 2>/dev/null)
  [ -z "$TETHER_NAT" ] && TETHER_NAT=0
  # 动态推导热点网段：用热点原生地址（排除固定管理别名）+ 真实掩码；
  # 找不到时回退固定管理网段，避免 HyperOS 原生网关不是 192.168.43.1 时误判。
  AP_SUBNET=$(get_hotspot_subnet "$iface")
  # 固定字符串匹配（子网/接口名含 . 与 / 等正则元字符，不能拼进正则）
  C1=$("$BB" grep MASQUERADE "$NAT_FILE" 2>/dev/null | "$BB" grep -Fc "$AP_SUBNET")
  C2=$("$BB" grep MASQUERADE "$NAT_FILE" 2>/dev/null | "$BB" grep -Fc "$iface")
  rm -f "$NAT_FILE" 2>/dev/null
  case "$C1" in ''|*[!0-9]*) C1=0 ;; esac
  case "$C2" in ''|*[!0-9]*) C2=0 ;; esac
  TETHER_HOTSPOT_NAT=$((C1 + C2))
  TETHER_PKTS=$($IPT -L FORWARD -n -v -x 2>/dev/null | "$BB" awk -v i="$iface" '$6==i || $7==i {s+=$1} END {print s+0}')
  [ -z "$TETHER_PKTS" ] && TETHER_PKTS=0
  # 热点接口在 FORWARD 链中的转发规则条数（转发路径是否建立）
  FORWARD_IFACE_RULES=$($IPT -L FORWARD -n -v -x 2>/dev/null | "$BB" awk -v i="$iface" '$6==i || $7==i {n++} END {print n+0}')
  case "$FORWARD_IFACE_RULES" in ''|*[!0-9]*) FORWARD_IFACE_RULES=0 ;; esac
  # HyperOS 的 MASQUERADE 常只按出口接口（-o wlan0 / -o miw_oem0）匹配，不带热点子网/接口名；
  # 此时若 NAT 规则存在、且 FORWARD 链已建立热点接口转发路径，同样判定共享 NAT 就绪。
  if [ "$TETHER_HOTSPOT_NAT" = "0" ] && [ "$TETHER_NAT" -gt 0 ] && [ "$FORWARD_IFACE_RULES" -gt 0 ]; then
    TETHER_HOTSPOT_NAT=1
  fi
}

# ---------- 系统信息 ----------
get_sysinfo() {
  SYS_MEM_TOTAL=$("$BB" sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  SYS_MEM_AVAIL=$("$BB" sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  SYS_LOAD=$("$BB" cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  UPTIME_S=$("$BB" awk '{print int($1)}' /proc/uptime 2>/dev/null)
  case "$UPTIME_S" in ''|*[!0-9]*) UPTIME_S=0 ;; esac
  SYS_UPTIME="$((UPTIME_S / 3600))h $(((UPTIME_S % 3600) / 60))m"
  STOR=$(/system/bin/df -k /data 2>/dev/null | "$BB" awk 'NR==2{print $2, $4}')
  SYS_STOR_TOTAL=$(printf '%s\n' "$STOR" | "$BB" cut -d' ' -f1)
  SYS_STOR_AVAIL=$(printf '%s\n' "$STOR" | "$BB" cut -d' ' -f2)
  [ -z "$SYS_STOR_TOTAL" ] && SYS_STOR_TOTAL=0
  [ -z "$SYS_STOR_AVAIL" ] && SYS_STOR_AVAIL=0
  SYS_THERMAL=
  for z in /sys/class/thermal/thermal_zone*; do
    [ -e "$z/type" ] || continue
    T=$(cat "$z/type" 2>/dev/null)
    case "$T" in
      cpu*|soc*|apc*|cluster*|quiet*|*cpu*)
        MV=$(cat "$z/temp" 2>/dev/null)
        case "$MV" in ''|*[!0-9]*) continue ;; esac
        SYS_THERMAL=$((MV / 1000))
        break
        ;;
    esac
  done
}

# ---------- 温度（thermal_zone 15 秒缓存，区分电池/CPU/最高/状态） ----------
# 小米 14 / HyperOS 的 /sys/class/thermal/thermal_zone* 提供毫摄氏度值（如 29700 = 29.7°C）。
# 纯 shell 循环读取（内建 read，不 fork 子进程），真机 101 个 zone 读取 <1s。
THERM_CACHE="$DATA_DIR/thermal.cache"
get_thermal_info() {
  THERM_BATTERY=
  THERM_CPU=0
  THERM_GPU=0
  THERM_MAX=0
  THERM_STATUS=normal
  NOW_S=${NOW_S:-$(/system/bin/date +%s 2>/dev/null || date +%s)}
  C_MT=0
  if [ -r "$THERM_CACHE" ]; then
    C_MT=$("$BB" stat -c %Y "$THERM_CACHE" 2>/dev/null)
    case "$C_MT" in ''|*[!0-9]*) C_MT=0 ;; esac
    if [ "$C_MT" -gt 0 ] && [ $((NOW_S - C_MT)) -ge 0 ] && [ $((NOW_S - C_MT)) -lt 15 ]; then
      while IFS='=' read -r K V; do
        case "$K" in
          THERM_BATTERY) case "$V" in ''|*[!0-9]*) : ;; *) THERM_BATTERY=$V ;; esac ;;
          THERM_CPU) case "$V" in ''|*[!0-9]*) : ;; *) THERM_CPU=$V ;; esac ;;
          THERM_MAX) case "$V" in ''|*[!0-9]*) : ;; *) THERM_MAX=$V ;; esac ;;
          THERM_STATUS) case "$V" in normal|warm|hot) THERM_STATUS=$V ;; esac ;;
        esac
      done < "$THERM_CACHE"
      return 0
    fi
    # v1.7.2-beta.1：CGI 只读——缓存过期也沿用旧值（supervisor 每 tick 后台刷新），
    # 绝不重新遍历 thermal_zone，避免拖慢状态接口。
    if [ "${CGI_READONLY:-0}" = "1" ]; then
      while IFS='=' read -r K V; do
        case "$K" in
          THERM_BATTERY) case "$V" in ''|*[!0-9]*) : ;; *) THERM_BATTERY=$V ;; esac ;;
          THERM_CPU) case "$V" in ''|*[!0-9]*) : ;; *) THERM_CPU=$V ;; esac ;;
          THERM_MAX) case "$V" in ''|*[!0-9]*) : ;; *) THERM_MAX=$V ;; esac ;;
          THERM_STATUS) case "$V" in normal|warm|hot) THERM_STATUS=$V ;; esac ;;
        esac
      done < "$THERM_CACHE"
      return 0
    fi
  elif [ "${CGI_READONLY:-0}" = "1" ]; then
    return 0
  fi
  # 采集：type=battery 电池、cpu*/soc* CPU/SoC、gpuss-*/gpu* GPU，各取最高
  BT=0; CT=0; GX=0
  for z in /sys/class/thermal/thermal_zone*; do
    IFS= read -r T < "$z/type" 2>/dev/null || continue
    case "$T" in
      battery)
        IFS= read -r V < "$z/temp" 2>/dev/null
        case "$V" in ''|*[!0-9]*) V=0 ;; esac
        BT=$((V / 1000)) ;;
      cpu*|soc*)
        IFS= read -r V < "$z/temp" 2>/dev/null
        case "$V" in ''|*[!0-9]*) V=0 ;; esac
        [ "$((V / 1000))" -gt "$CT" ] 2>/dev/null && CT=$((V / 1000)) ;;
      gpuss-*|gpu*)
        IFS= read -r V < "$z/temp" 2>/dev/null
        case "$V" in ''|*[!0-9]*) V=0 ;; esac
        [ "$((V / 1000))" -gt "$GX" ] 2>/dev/null && GX=$((V / 1000)) ;;
    esac
  done
  # v1.7.9：无传感器读数时置空（前端显示 —，不再误显示 0°C）；
  # 系统温度状态只由 CPU/GPU 决定（电池温度随充电波动，不代表系统负载，
  # 计入门槛会导致充电时误报"偏高/过热"）。
  case "$BT" in ''|*[!0-9]*) BT= ;; *) [ "$BT" -gt 0 ] 2>/dev/null || BT= ;; esac
  case "$CT" in ''|*[!0-9]*) CT= ;; *) [ "$CT" -gt 0 ] 2>/dev/null || CT= ;; esac
  case "$GX" in ''|*[!0-9]*) GX= ;; *) [ "$GX" -gt 0 ] 2>/dev/null || GX= ;; esac
  MX=$CT
  [ -n "$GX" ] && { [ -z "$MX" ] || [ "$GX" -gt "$MX" ] 2>/dev/null; } && MX=$GX
  THERM_BATTERY=$BT
  THERM_CPU=$CT
  THERM_MAX=$MX
  if [ -z "$MX" ]; then
    THERM_STATUS=unknown
  elif [ "$MX" -ge 55 ] 2>/dev/null; then
    THERM_STATUS=hot
  elif [ "$MX" -ge 45 ] 2>/dev/null; then
    THERM_STATUS=warm
  else
    THERM_STATUS=normal
  fi
  TMP="$THERM_CACHE.tmp.$$"
  printf 'THERM_BATTERY=%s\nTHERM_CPU=%s\nTHERM_MAX=%s\nTHERM_STATUS=%s\n' "$BT" "$CT" "$MX" "$THERM_STATUS" > "$TMP" 2>/dev/null
  chmod 0600 "$TMP" 2>/dev/null
  mv -f "$TMP" "$THERM_CACHE" 2>/dev/null
  rm -f "$TMP" 2>/dev/null
}

# ---------- SIM / 蜂窝状态（尽力而为，解析失败显示 --） ----------
# status.cgi 会同时读取 SIM 与信号信息。两者共享同一份 telephony 快照，
# 避免冷启动时重复执行大型 dumpsys；采集超时则沿用旧快照，绝不阻塞首页。
TELEPHONY_SNAPSHOT="$DATA_DIR/telephony.snapshot"

ensure_telephony_snapshot() {
  now=$(/system/bin/date +%s 2>/dev/null || date +%s)
  if [ -s "$TELEPHONY_SNAPSHOT" ]; then
    mt=$("$BB" stat -c %Y "$TELEPHONY_SNAPSHOT" 2>/dev/null)
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    age=$((now - mt))
    if [ "$mt" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; then
      return 0
    fi
  fi

  tmp="$TELEPHONY_SNAPSHOT.tmp.$$"
  if "$BB" timeout 5 /system/bin/dumpsys telephony.registry > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$TELEPHONY_SNAPSHOT" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null

  # 部分 ROM 没有 telephony.registry，有限时地回退到 phone。
  tmp="$TELEPHONY_SNAPSHOT.tmp.$$"
  if "$BB" timeout 3 /system/bin/dumpsys phone > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$TELEPHONY_SNAPSHOT" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  [ -s "$TELEPHONY_SNAPSHOT" ]
}

# dumpsys 输出可达数百 KB 且各字段同行逗号分隔；解析必须直接读文件。
# 缓存 30 秒：缓存有效期内直接读取，不再解析快照。
get_sim_state() {
  SIM_OPERATOR=
  SIM_DATA=0
  SIM_SIGNAL=
  SIM_CACHE="$DATA_DIR/sim.cache"
  NOW_S=${NOW_S:-$(/system/bin/date +%s 2>/dev/null || date +%s)}
  if [ -r "$SIM_CACHE" ]; then
    CACHE_MT=$("$BB" stat -c %Y "$SIM_CACHE" 2>/dev/null)
    case "$CACHE_MT" in ''|*[!0-9]*) CACHE_MT=0 ;; esac
    if [ "$CACHE_MT" -gt 0 ] && [ $((NOW_S - CACHE_MT)) -ge 0 ] && [ $((NOW_S - CACHE_MT)) -lt 30 ]; then
      . "$SIM_CACHE" 2>/dev/null || true
      SIM_OPERATOR=$(b64url_decode "${SIM_OPERATOR_B64:-}")
      return 0
    fi
  fi
  # v1.7.2-beta.1：CGI 只读模式——sim.cache 由 supervisor 每 tick 后台预热（30s 限频），
  # CGI 未命中缓存直接返回空字段，绝不执行 dumpsys/grep 重建（真机上此路径曾卡 3s+ 拖垮状态接口）。
  if [ "${CGI_READONLY:-0}" = "1" ]; then
    return 0
  fi
  DMP_FILE="$TELEPHONY_SNAPSHOT"
  SNAP_AGE=999
  if [ -r "$DMP_FILE" ]; then
    SNAP_MT=$("$BB" stat -c %Y "$DMP_FILE" 2>/dev/null)
    case "$SNAP_MT" in ''|*[!0-9]*) SNAP_MT=0 ;; esac
    [ "$SNAP_MT" -gt 0 ] && SNAP_AGE=$((NOW_S - SNAP_MT))
  fi
  if [ -s "$DMP_FILE" ] && [ "$SNAP_AGE" -ge 0 ] && [ "$SNAP_AGE" -lt 60 ] 2>/dev/null; then
    SIM_OPERATOR=$("$BB" grep -o 'mOperatorAlphaLong=[^,]*' "$DMP_FILE" | "$BB" head -1 | "$BB" sed 's/mOperatorAlphaLong=//; s/[[:space:]]*$//')
    SIM_DATA=$("$BB" grep -o 'mDataConnectionState=[0-9]*' "$DMP_FILE" | "$BB" head -1 | "$BB" sed 's/mDataConnectionState=//')
    [ -z "$SIM_DATA" ] && SIM_DATA=0
    SIG=$("$BB" grep -o 'mSignalStrength=[0-9]*' "$DMP_FILE" | "$BB" head -1 | "$BB" sed 's/mSignalStrength=//')
    case "$SIG" in ''|*[!0-9]*) ASU=99 ;; *) ASU=$SIG ;; esac
    if [ "$ASU" -le 31 ] 2>/dev/null; then
      SIM_SIGNAL=$((ASU * 2 - 113))
    else
      SIM_SIGNAL=
    fi
    TMP_CACHE="$SIM_CACHE.$$"
    {
      printf 'SIM_OPERATOR_B64=%s\n' "$(b64url_encode "$SIM_OPERATOR")"
      printf 'SIM_DATA=%s\n' "$SIM_DATA"
      printf 'SIM_SIGNAL=%s\n' "$SIM_SIGNAL"
    } > "$TMP_CACHE" 2>/dev/null
    chmod 0600 "$TMP_CACHE" 2>/dev/null
    mv -f "$TMP_CACHE" "$SIM_CACHE" 2>/dev/null
  fi
}

# ---------- 定时 ----------
now_hhmm() {
  /system/bin/date +%H%M 2>/dev/null
}

schedule_in_window() {
  on=$1
  off=$2
  now=$3
  case "$on" in ''|*[!0-9]*) return 1 ;; esac
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$on" -lt "$off" ]; then
    [ "$now" -ge "$on" ] && [ "$now" -lt "$off" ]
  else
    [ "$now" -ge "$on" ] || [ "$now" -lt "$off" ]
  fi
}

# 定时计划信息（跨午夜归属正确）。
# 输出：TODAY_ON TODAY_OFF YEST_ON YEST_OFF（0 表示当日/昨日无计划）
sched_info() {
  TODAY_W=$($DATE_CMD +%w 2>/dev/null)
  case "$TODAY_W" in ''|*[!0-9]*) TODAY_W=9 ;; esac
  YEST_W=$((TODAY_W - 1))
  [ "$YEST_W" -lt 0 ] && YEST_W=6
  case "${SCHED_MODE:-daily}" in
    weekday)
      if [ "$TODAY_W" -ge 1 ] && [ "$TODAY_W" -le 5 ]; then printf '%s %s ' "$SCHED_ON_WD" "$SCHED_OFF_WD"; else printf '0 0 '; fi
      if [ "$YEST_W" -ge 1 ] && [ "$YEST_W" -le 5 ]; then printf '%s %s\n' "$SCHED_ON_WD" "$SCHED_OFF_WD"; else printf '0 0\n'; fi
      ;;
    weekend)
      if [ "$TODAY_W" -eq 0 ] || [ "$TODAY_W" -eq 6 ]; then printf '%s %s ' "$SCHED_ON_WE" "$SCHED_OFF_WE"; else printf '0 0 '; fi
      if [ "$YEST_W" -eq 0 ] || [ "$YEST_W" -eq 6 ]; then printf '%s %s\n' "$SCHED_ON_WE" "$SCHED_OFF_WE"; else printf '0 0\n'; fi
      ;;
    *)
      printf '%s %s %s %s\n' "$SCHED_ON" "$SCHED_OFF" "$SCHED_ON" "$SCHED_OFF"
      ;;
  esac
}

# 窗口判定（跨午夜正确）：
# $1=today_on $2=today_off $3=yest_on $4=yest_off $5=now
# 昨日跨午夜窗口延续（now < yest_off 且昨日窗口为跨午夜）仍视为窗口内。
sched_in_window() {
  to=$1; tf=$2; yo=$3; yf=$4; now=$5
  case "$yo" in ''|*[!0-9]*) yo=0 ;; esac
  case "$yf" in ''|*[!0-9]*) yf=0 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$yo" != "0" ] && [ "$yf" -lt "$yo" ] && [ "$now" -lt "$yf" ]; then
    return 0
  fi
  case "$to" in ''|0) return 1 ;; esac
  schedule_in_window "$to" "$tf" "$now"
}

# SoftAP 综合验证（P1-13）：接口 + IP + 系统 SoftAP 状态
# 系统状态取不到时不判失败（保持旧接口判定），取到且明确未启用时才判失败。
SOFTAP_CACHE="$DATA_DIR/softap.cache"

# SoftAP 状态快照（P2-9）：一次 dumpsys wifi，缓存 15 秒；
# 状态接口每 5 秒轮询时不再重复执行 dumpsys。
softap_state_snapshot() {
  SNAP_AP_STATE=
  SNAP_AP_SSID=
  SNAP_AP_SECURITY=
  SNAP_AP_CHANNEL=
  SNAP_AP_BAND=
  if [ -r "$SOFTAP_CACHE" ]; then
    MT=$("$BB" stat -c %Y "$SOFTAP_CACHE" 2>/dev/null)
    NOW=$(/system/bin/date +%s 2>/dev/null || date +%s)
    case "$MT" in ''|*[!0-9]*) MT=0 ;; esac
    AGE=$((NOW - MT))
    if [ "$MT" -gt 0 ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt 15 ]; then
      # P0(1.5.12)：禁止 source 缓存文件（SSID 可能含引号/反引号/$()）。
      # 逐行白名单解析：只接受固定键，值做严格字符校验；SSID 走 Base64。
      while IFS='=' read -r C_KEY C_VAL; do
        case "$C_KEY" in
          SNAP_AP_STATE) case "$C_VAL" in ENABLED|DISABLED|DISABLING|ENABLING|FAILED|ENABLED_AND_SUSPENDED) SNAP_AP_STATE="$C_VAL" ;; esac ;;
          SNAP_AP_SSID_B64) case "$C_VAL" in ''|*[!A-Za-z0-9+/=-]*) : ;; *) SNAP_AP_SSID_B64="$C_VAL" ;; esac ;;
          SNAP_AP_SECURITY) case "$C_VAL" in ''|*[!0-9]*) : ;; *) SNAP_AP_SECURITY="$C_VAL" ;; esac ;;
          SNAP_AP_CHANNEL) case "$C_VAL" in ''|*[!0-9]*) : ;; *) SNAP_AP_CHANNEL="$C_VAL" ;; esac ;;
          SNAP_AP_BAND) case "$C_VAL" in ''|*[!0-9]*) : ;; *) SNAP_AP_BAND="$C_VAL" ;; esac ;;
        esac
      done < "$SOFTAP_CACHE"
      case "$SNAP_AP_SSID_B64" in
        '') SNAP_AP_SSID= ;;
        *) SNAP_AP_SSID=$(printf '%s' "$SNAP_AP_SSID_B64" | "$BB" base64 -d 2>/dev/null) ;;
      esac
      # v1.7.9：缓存读取路径同样补接口兜底——旧缓存 STATE 为空会被 15s 复用
      # 窗口持续带出，supervisor 写 system_hotspot.cache 恒空，status.cgi 读
      # 缓存落空后仍会 fallback 起 app_process。热点形态接口存在→ENABLED；
      # 无接口但配置存在→DISABLED。
      if [ -z "$SNAP_AP_STATE" ]; then
        case "$(get_hotspot_iface 2>/dev/null)" in
          wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|apbr[0-9]*|wlan_ap[0-9]*) SNAP_AP_STATE=ENABLED ;;
        esac
      fi
      if [ -z "$SNAP_AP_STATE" ] && [ -n "$SNAP_AP_SSID" ] && [ -z "$(get_hotspot_iface 2>/dev/null)" ]; then
        SNAP_AP_STATE=DISABLED
      fi
      return 0
    fi
  fi
  # 禁止把 dumpsys wifi 放进 Shell 变量。小米 Android 16 的输出可超过
  # ARG_MAX，旧实现会在 printf 时触发 "Argument list too long"。
  SNAP_TMP="$SOFTAP_CACHE.out.tmp.$$"
  if "$BB" timeout 5 /system/bin/dumpsys wifi > "$SNAP_TMP" 2>/dev/null && [ -s "$SNAP_TMP" ]; then
    chmod 0600 "$SNAP_TMP" 2>/dev/null
    mv -f "$SNAP_TMP" "$SOFTAP_CACHE.out" 2>/dev/null
  else
    rm -f "$SNAP_TMP" 2>/dev/null
  fi
  # 本次采集失败时允许解析上次成功快照；没有快照则返回“未知”。
  [ -s "$SOFTAP_CACHE.out" ] || return 0
  AP_STATE=$("$BB" grep -o 'mWifiApState=[A-Z]*' "$SOFTAP_CACHE.out" | "$BB" head -n1 | "$BB" cut -d= -f2)
  if [ -z "$AP_STATE" ]; then
    # 部分 ROM（MTK/骁龙等）不打印 mWifiApState，仅输出 SoftApCallback 回调：
    #   onStateChanged with state: 11 failure reason: 0 ... SAP is disabled
    #   onStateChanged with state: 12 ... onStateChanged with state: 13 ... SAP is enabled successfully
    # 统一映射：10=DISABLING 11=DISABLED 12=ENABLING 13=ENABLED 14=FAILED。
    # 只取最后一次 state（最终状态优先，启动序列 11→12→13 以 13 为准）；
    # "failure reason: 0" 表示无失败原因，绝不据此判失败。
    AP_STATE_NUM=$("$BB" grep -o 'onStateChanged with state: *[0-9]*' "$SOFTAP_CACHE.out" \
      | "$BB" tail -n1 | "$BB" grep -o '[0-9]*$')
    case "$AP_STATE_NUM" in
      10) AP_STATE=DISABLING ;;
      11) AP_STATE=DISABLED ;;
      12) AP_STATE=ENABLING ;;
      13) AP_STATE=ENABLED ;;
      14) AP_STATE=FAILED ;;
    esac
  fi
  # v1.7.9：HyperOS/Android 16 dumpsys 无 mWifiApState、无 onStateChanged 数字回调，
  # 但输出 SoftAp 状态机 rec 事件与 SoftApManager 段（实测格式）：
  #   what=CMD_SET_AP 1 0 ... num SoftApManagers:1  → 启用
  #   what=CMD_SET_AP 0 1 ... num SoftApManagers:0  → 禁用
  #   what=CMD_AP_STOPPED                          → 已停止
  #   mCurrentSoftApInfoMap {wlanX=...}            → 当前运行实例
  if [ -z "$AP_STATE" ]; then
    # CMD_SET_AP 1 0=启用 / CMD_SET_AP 0 1=禁用 / CMD_AP_STOPPED=已停止
    # 统一按出现顺序取“最后一条”SoftAP 状态事件（CMD_AP_STOPPED 可能晚于旧 CMD_SET_AP）。
    AP_REC=$("$BB" grep -oE 'what=CMD_SET_AP [01] [01]|what=CMD_AP_STOPPED' "$SOFTAP_CACHE.out" | "$BB" tail -n1)
    case "$AP_REC" in
      *'CMD_SET_AP 1 '*) AP_STATE=ENABLED ;;
      *'CMD_SET_AP 0 '*|*'CMD_AP_STOPPED'*) AP_STATE=DISABLED ;;
    esac
  fi
  if [ -z "$AP_STATE" ]; then
    AP_MAP=$("$BB" grep -o 'mCurrentSoftApInfoMap *{[^}]*}' "$SOFTAP_CACHE.out" | "$BB" tail -n1)
    case "$AP_MAP" in
      *'{wlan'*) AP_STATE=ENABLED ;;
      *'{}') AP_STATE=DISABLED ;;
    esac
  fi
  # 尽力解析 SoftAP 配置段（Android 16/STA+AP 并发，mCurrentSoftApInfoMap 可能含多实例）
  # 只从 mCurrentSoftApConfiguration 或 WifiApConfigStore config 提取 SSID，
  # 避免把 bssid=、current SSID(s):、字段名 mCurrentSoftApInfoMap 误当 SSID。
  AP_SSID=$("$BB" grep -E '^mCurrentSoftApConfiguration:|^WifiApConfigStore config:' "$SOFTAP_CACHE.out" \
      | "$BB" grep -oE 'ssid *= *"[^"]*"' \
      | "$BB" head -n1 \
      | "$BB" sed -E 's/.*"([^"]*)".*/\1/')
  case "$AP_SSID" in
    ''|null|NULL|{}|mCurrentSoftApInfoMap|SoftApInfo|SoftApConfiguration|wlan0|wlan1|wlan2) AP_SSID= ;;
  esac
  # v1.7.9：HyperOS dumpsys 偶发全空（rec/map/mWifiApState 均无）时用接口兜底。
  # 热点形态接口存在 → ENABLED（热点在跑）；无接口但系统"曾配置过 SoftAP"
  # （本次 SSID 或上次快照 SNAP_AP_SSID_B64 非空）→ "已配置但未运行"= DISABLED。
  # supervisor 每 tick 写 system_hotspot.cache 正确状态，status.cgi 只读缓存
  # 即得 ON/OFF，不再 fallback 起 app_process/dumpsys。
  if [ -z "$AP_STATE" ]; then
    case "$(get_hotspot_iface 2>/dev/null)" in
      wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|apbr[0-9]*|wlan_ap[0-9]*) AP_STATE=ENABLED ;;
    esac
  fi
  if [ -z "$AP_STATE" ]; then
    HAS_CFG=
    [ -n "$AP_SSID" ] && HAS_CFG=1
    [ -z "$HAS_CFG" ] && [ -n "$SNAP_AP_SSID_B64" ] && HAS_CFG=1
    if [ -n "$HAS_CFG" ] && [ -z "$(get_hotspot_iface 2>/dev/null)" ]; then
      AP_STATE=DISABLED
    fi
  fi
  # 安全模式：WifiApInfo/WifiConfiguration 中 security 或 allowedKeyManagement
  AP_SECURITY=$("$BB" grep -o 'security=[0-9]*' "$SOFTAP_CACHE.out" | "$BB" head -n1 | "$BB" cut -d= -f2)
  AP_CHANNEL=$("$BB" grep -o 'mWifiApInfo[^}]*channel=[0-9]*' "$SOFTAP_CACHE.out" | "$BB" head -n1 | "$BB" sed -n 's/.*channel=\([0-9]*\).*/\1/p')
  [ -z "$AP_CHANNEL" ] && AP_CHANNEL=$("$BB" grep -o 'channel=[0-9]*' "$SOFTAP_CACHE.out" | "$BB" head -n1 | "$BB" cut -d= -f2)
  AP_BAND=$("$BB" grep -o 'band=[0-9]*' "$SOFTAP_CACHE.out" | "$BB" head -n1 | "$BB" cut -d= -f2)
  TMP="$SOFTAP_CACHE.$$"
  # SSID 经 Base64 存储，避免特殊字符破坏缓存文件；状态/安全/频段/信道只接受枚举或数字
  case "$AP_STATE" in
    ENABLED|DISABLED|DISABLING|ENABLING|FAILED|ENABLED_AND_SUSPENDED) : ;;
    *) AP_STATE= ;;
  esac
  AP_SSID_B64=$(printf '%s' "$AP_SSID" | "$BB" base64 2>/dev/null | "$BB" tr -d '=\n')
  {
    printf 'SNAP_AP_STATE=%s\n' "$AP_STATE"
    printf 'SNAP_AP_SSID_B64=%s\n' "$AP_SSID_B64"
    printf 'SNAP_AP_SECURITY=%s\n' "$AP_SECURITY"
    printf 'SNAP_AP_CHANNEL=%s\n' "$AP_CHANNEL"
    printf 'SNAP_AP_BAND=%s\n' "$AP_BAND"
  } > "$TMP" 2>/dev/null
  mv -f "$TMP" "$SOFTAP_CACHE" 2>/dev/null
  chmod 0600 "$SOFTAP_CACHE" 2>/dev/null
}

# SoftAP 真实状态（接口 + IP + 系统状态，读缓存）
softap_state_ok() {
  iface=$1
  [ -n "$iface" ] || return 1
  # v1.7.2-beta.1：接受调用方已算好的 IP（status.cgi 已一次 ip 调用取得），避免再 fork ip
  IP_ADDR=$2
  [ -n "$IP_ADDR" ] || IP_ADDR=$(get_iface_ip "$iface")
  # v1.7.9：HyperOS 热点接口 wlan2 启动后只有 IPv6 链路本地地址（fe80::），
  # IPv4 管理别名 192.168.43.1/32 由模块在验证通过后 switch_management_to_hotspot 挂载。
  # 因此接口形态是热点接口（wlanX/apX）时不得因无 IPv4 判失败——那会让启动验证
  # 永远失败（先有鸡还是先有蛋），并把管理别名错误留在 lo。接口存在 + 系统状态
  # ENABLED 即视为运行；无 IPv4 只影响管理别名挂载（由调用方后续处理）。
  case "$iface" in
    wlan[0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|apbr[0-9]*|wlan_ap[0-9]*) : ;;
    *) [ -n "$IP_ADDR" ] || return 1 ;;
  esac
  # v1.7.2-beta.1：CGI 只读——只用现有 softap.cache 判定（supervisor 每 tick 刷新），
  # 缓存缺失/过期时若接口已有 IP 视为运行；绝不触发 dumpsys wifi（真机 1s+ 卡顿）。
  if [ "${CGI_READONLY:-0}" = "1" ]; then
    NOW_S=${NOW_S:-$(/system/bin/date +%s 2>/dev/null || date +%s)}
    SNAP_AGE=999
    if [ -r "$SOFTAP_CACHE" ]; then
      SNAP_MT=$("$BB" stat -c %Y "$SOFTAP_CACHE" 2>/dev/null)
      case "$SNAP_MT" in ''|*[!0-9]*) SNAP_MT=0 ;; esac
      [ "$SNAP_MT" -gt 0 ] && SNAP_AGE=$((NOW_S - SNAP_MT))
      . "$SOFTAP_CACHE" 2>/dev/null || true
    fi
    if [ "$SNAP_AGE" -ge 0 ] && [ "$SNAP_AGE" -lt 45 ] 2>/dev/null; then
      case "$SNAP_AP_STATE" in
        ENABLED) return 0 ;;
        DISABLED|DISABLING|ENABLING|FAILED) return 1 ;;
      esac
    fi
    return 0
  fi
  softap_state_snapshot
  case "$SNAP_AP_STATE" in
    ENABLED) return 0 ;;
    DISABLED|DISABLING|ENABLING|FAILED) return 1 ;;
  esac
  # v1.7.9：快照未解析出状态时，不得用 cmd wifi status 判定 SoftAP——
  # 它反映的是整个 Wi-Fi（STA）开关，与热点无关；此前在此 ROM 上导致
  # wifi stop-softap 已成功却仍被误判 active，白白空等 12 次快照。
  # 改用系统 Tethering 真实状态兜底，仍未知则按接口是否存在保守处理。
  if bridge_available; then
    T_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null)
    case "$T_OUT" in
      *'tether_state=2'*|*'tethered=1'*) return 0 ;;
      *'tethered=0'*) return 1 ;;
    esac
  fi
  [ -z "$(get_hotspot_iface)" ] && return 1
  return 0
}

# 热点参数核验（P1-8）：SSID/安全/频段/信道尽量与期望比对。
# 返回 0=匹配或无法核验（不判失败）；2=明确不匹配（调用方写日志告警，不回滚）。
# $1=期望SSID $2=期望security $3=期望band $4=期望channel
verify_softap_config() {
  EXP_SSID=$1
  EXP_SEC=$2
  EXP_BAND=$3
  EXP_CH=$4
  softap_state_snapshot
  [ -n "$SNAP_AP_SSID" ] || return 0
  # SSID 不匹配 → 明确错误（dumpsys 抓到的 SSID 属于 SoftAP 配置段，不是手机连接的 Wi-Fi）
  [ "$SNAP_AP_SSID" = "$EXP_SSID" ] || return 2
  # 频段/信道/安全模式只有拿到明确值才比较
  if [ -n "$SNAP_AP_CHANNEL" ] && [ -n "$EXP_CH" ] && [ "$EXP_CH" != "0" ]; then
    case "$SNAP_AP_CHANNEL" in ''|*[!0-9]*) : ;; *)
      [ "$SNAP_AP_CHANNEL" = "$EXP_CH" ] || return 2
    ;; esac
  fi
  if [ -n "$SNAP_AP_BAND" ]; then
    case "$EXP_BAND:$SNAP_AP_BAND" in
      2:1|2:2|2:0) : ;;
      5:2|5:1|5:0) : ;;
      any:*) : ;;
      *) return 2 ;;
    esac
  fi
  return 0
}


# ================= v1.3.6 新增 =================

# ---------- 客户端厂商识别（MAC OUI 前缀表） ----------
# MAC 前 3 字节（大写，如 "F0:18:98"）→ 厂商名；未收录返回空。
# 调用前先归一化大写：V=$(printf '%s' "$MAC" | tr 'a-f' 'A-F')
mac_vendor() {
  mac=$1
  PREFIX=$(printf '%s' "$mac" | "$BB" cut -d: -f1-3 2>/dev/null)
  case "$PREFIX" in
    F0:18:98|A4:83:E7|3C:22:FB|40:CB:C0|44:D8:84|48:43:3A|5C:E9:1E|68:5B:35|70:3E:AC|78:4F:43|88:66:5A|8C:58:77|90:B0:ED|98:01:A7|9C:20:7B|AC:BC:32|B0:65:BD|C0:56:E3|CC:08:E0|D0:E1:40|D4:61:9D|DC:2B:2A|E4:8B:7F|F0:2F:74|F4:0F:1B|F4:F1:5A|F8:8C:BC|FC:A8:9A) echo Apple ;;
    00:16:6C|00:1A:3F|00:23:D4|00:24:90|08:00:28|0C:1B:8A|14:49:E0|18:68:CB|1C:7E:C5|20:37:06|24:E9:B3|28:CF:E9|2C:21:31|30:CD:A7|34:31:11|38:5F:2D|3C:DB:D5|40:4D:8F|44:52:D9|48:0C:49|4C:77:66|50:3E:AA|54:10:EC|58:50:0B|5C:51:88|60:45:BD|64:6E:97|68:EF:43|6C:09:3B|70:5A:0F|74:78:1C|78:9A:18|7C:04:D0|80:06:5C|84:7B:EB|88:C6:26|8C:47:BE|90:5C:44|94:DA:BF|98:48:27|9C:28:EF|A0:1C:05|A4:77:33|A8:5C:2C|AC:5A:14|B0:47:BF|B4:E9:B0|B8:8A:60|BC:20:A4|C0:24:51|C4:9F:1E|C8:1E:E7|CC:2D:8C|D0:6B:4E|D4:6E:5E|D8:0D:17|DC:0E:A1|E0:27:1A|E4:03:6A|E8:50:8B|EC:0D:9A|F0:27:65|F4:46:FD|F8:3B:7E|FC:5B:26) echo Samsung ;;
    04:6D:52|08:96:D7|0C:1D:AF|10:2A:B3|14:F6:5A|18:59:36|1C:60:DE|20:2B:C1|24:0A:64|28:6C:07|2C:30:33|30:23:03|34:38:38|38:90:A5|3C:5A:B4|40:97:6E|44:23:7C|48:7D:2E|4C:06:EB|50:9F:27|54:57:5C|58:23:8C|5C:02:14|60:33:4B|64:CC:2E|68:DB:F5|6C:59:5D|70:2C:1F|74:78:9D|78:0C:B8|7C:33:87|80:6C:1B|84:AF:EC|88:C5:5A|8C:5A:F8|90:8D:77|94:65:2D|98:24:B7|9C:99:A0|A0:0A:AD|A4:08:EA|A8:6B:7C|AC:0C:64|B0:35:9F|B4:34:2B|B8:3A:08|BC:3F:8F|C0:21:AD|C4:0A:CB|C8:76:37|CC:03:1F|D0:37:45|D4:3A:2C|D8:C4:97|DC:44:6D|E0:19:1D|E4:C8:1C|E8:9A:8F|EC:26:CA|F0:B4:29|F4:8E:38|F8:A4:5F|FC:6C:31) echo Xiaomi ;;
    00:E0:FC|04:BD:88|08:19:A6|10:1B:54|14:39:58|18:82:2B|1C:AB:A7|20:1C:0B|28:6E:D4|2C:AB:00|30:FB:B8|34:12:98|38:BC:1A|40:8D:5C|44:1C:A8|48:46:FB|4C:54:99|54:25:EA|58:4A:EA|60:DE:44|64:16:66|68:A0:3E|6C:2E:85|70:B3:D5|74:9D:79|78:F5:FD|7C:7A:91|80:5E:C0|84:25:DB|88:C3:97|8C:34:FD|90:17:AC|94:77:2B|98:E7:F5|9C:34:26|A0:29:42|A4:91:B1|A8:DB:03|AC:61:EA|B0:E5:ED|B4:CD:27|B8:08:D7|BC:76:70|C0:EE:FB|C4:6E:6E|C8:5B:76|CC:16:7E|D0:7E:35|D4:6A:6A|D8:C7:71|DC:D2:FC|E0:2C:3F|E4:A7:A0|E8:AB:FA|EC:F8:EB|F0:27:2D|F4:4C:7F|F8:04:2E|FC:48:EF) echo Huawei ;;
    04:66:CF|0C:14:8C|1C:4B:D6|20:47:DA|28:05:0B|30:22:2C|34:6B:D3|3C:95:09|44:3C:9C|48:E6:E5|4C:0B:3A|50:9C:56|54:39:DF|5C:F9:38|60:2A:D0|64:7C:34|68:7D:B4|6C:3F:51|70:3D:15|74:27:EA|78:64:6F|7C:0E:CE|80:2C:F8|84:D4:1E|88:2B:B4|8C:4E:8F|90:87:08|94:63:CD|98:4C:26|9C:41:7C|A0:0B:2B|A4:C2:6B|A8:4C:65|AC:5E:8C|B0:5A:1D|B4:6D:83|B8:2D:28|BC:9C:31|C0:0B:16|C4:B4:BD|C8:92:3F|CC:B2:55|D0:8C:50|D4:5D:DF|D8:44:67|DC:21:48|E0:50:51|E4:6E:E7|E8:26:86|EC:90:4F|F0:7D:32|F4:8C:50|F8:87:76|FC:1F:9B) echo Honor ;;
    10:33:78|18:2F:38|1C:5A:6B|20:91:48|24:78:9C|2C:F0:EE|30:3E:A7|34:95:DB|38:0A:75|3C:32:E5|40:3D:EC|44:35:83|48:CA:43|4C:17:EB|50:2B:73|54:5E:25|58:74:8D|5C:38:6B|60:8C:4A|64:6E:DB|68:37:E9|6C:3B:E5|70:1C:E7|74:47:46|78:8A:FD|7C:2A:D1|80:5A:04|84:CB:FD|88:31:6C|8C:21:0A|90:2B:34|94:19:B8|98:DF:7D|9C:1D:52|A0:0E:9E|A4:4B:D5|A8:7B:39|AC:FD:CE|B0:4E:26|B4:52:7D|B8:B2:4A|BC:7E:3B|C0:2B:3B|C4:77:5E|C8:0E:14|CC:52:AF|D0:4C:C1|D4:6F:42|D8:4F:4D|DC:3A:5E|E0:63:DA|E4:92:05|E8:2A:EA|EC:FD:45|F0:0D:5F|F4:C4:D4|F8:EB:34|FC:23:6E) echo OPPO ;;
    00:0C:E6|04:0B:27|08:34:51|0C:46:12|10:78:D2|14:34:52|18:8F:76|1C:52:16|20:00:5A|24:3C:20|28:99:3A|2C:35:2B|30:94:0B|34:7D:F6|38:87:D5|3C:8B:FE|40:B3:95|44:03:2C|48:1C:44|4C:66:41|50:3C:BE|54:36:9B|58:BA:D5|5C:59:48|60:02:B4|64:66:B3|68:CB:B1|6C:2B:59|70:08:CD|74:5E:1C|78:3E:FB|7C:76:63|80:52:6B|84:1B:5E|88:3F:4A|8C:89:A5|90:8F:61|94:65:9D|98:38:DA|9C:20:D3|A0:8C:FD|A4:70:D6|A8:4A:AF|AC:2D:70|B0:6A:9F|B4:9C:5A|B8:0F:63|BC:2C:2C|C0:26:DA|C4:1C:FF|C8:4B:D6|CC:B8:A8|D0:3A:2F|D4:77:0F|D8:F1:5B|DC:F4:01|E0:1C:FC|E4:3A:6E|E8:4E:06|EC:AF:9E|F0:56:7D|F4:5E:AB|F8:58:0C|FC:14:0A) echo vivo ;;
    00:1A:11|04:0C:CE|08:66:98|C8:2A:14|F0:9F:C2|94:A7:B7|2C:54:91) echo Google ;;
    00:0F:1F|00:1B:21|00:21:86|04:35:6C|08:57:00|0C:1A:1E|10:6F:3F|14:4D:67|18:67:B0|1C:7B:21|20:1B:D5|24:05:88|28:E3:47|2C:4D:54|30:7C:30|34:38:B5|38:2C:4A|3C:18:A0|40:8D:5E|44:1A:FA|48:4B:AA|4C:7F:62|50:3D:E5|54:E6:FC|58:71:8C|5C:50:15|60:1C:EE|64:9E:F3|68:6C:E5|6C:62:6E|70:66:55|74:C3:42|78:6C:1C|7C:61:93|80:57:06|84:38:38|88:91:DD|8C:0C:A3|90:61:AE|94:57:A5|98:9B:CB|9C:93:4E|A0:54:4B|A4:83:C7|A8:7D:12|AC:CB:09|B0:72:BF|B4:FD:05|B8:51:FD|BC:14:01|C0:76:68|C4:8E:8F|C8:5A:92|CC:55:AD|D0:37:61|D4:CA:6D|D8:8E:79|DC:F5:D6|E0:D5:5E|E4:77:D8|E8:94:F6|EC:74:8D|F0:98:9D|F4:F2:6D|F8:FD:CE|FC:8A:C8) echo Lenovo ;;
    00:04:E2|00:0A:28|00:0E:3A|00:16:B6|00:1F:5B|00:23:58|04:05:4D|08:00:37|0C:44:32|10:5B:AD|14:0E:E0|18:2D:30|1C:06:93|20:12:1F|24:30:DE|28:1D:5C|2C:00:33|30:76:42|34:8E:C6|38:14:1B|3C:4C:BC|40:04:62|44:06:19|48:0E:EC|4C:0F:6E|50:61:5B|54:2D:66|58:46:11|5C:6B:4F|60:0D:81|64:18:5B|68:37:28|6C:1D:1A|70:35:70|74:C9:61|78:8F:2A|7C:13:17|80:63:05|84:3A:4B|88:2B:50|8C:8B:83|90:6D:EE|94:77:C0|98:6B:38|9C:10:CD|A0:63:91|A4:31:35|A8:3D:E4|AC:7A:4B|B0:6B:E7|B4:0B:44|B8:3A:7D|BC:6C:21|C0:6E:5F|C4:90:01|C8:6B:4F|CC:EF:48|D0:5C:7A|D4:63:36|D8:16:E3|DC:97:5B|E0:2C:33|E4:67:2C|E8:6B:EA|EC:0B:AE|F0:27:45|F4:36:6F|F8:15:47|FC:0F:4A) echo Motorola ;;
    00:04:F2|00:0B:82|00:12:0E|00:1B:FC|00:21:6A|04:92:26|08:60:6E|0C:9D:92|10:BF:48|14:D6:4D|18:A6:F7|1C:B7:2C|20:4E:7F|24:05:0F|28:34:A2|2C:56:DC|30:9C:23|34:97:F6|38:10:D5|3C:52:82|40:4D:8E|44:6C:24|48:5B:39|4C:02:89|50:46:5D|54:04:A6|58:10:8B|5C:62:8B|60:26:FD|68:5D:43|6C:AD:F8|70:8C:B7|74:C6:3B|78:1D:BA|7C:11:BE|80:1F:02|84:1B:77|88:D7:F6|8C:4D:EA|90:9F:33|94:0C:6D|98:FE:94|9C:5C:8E|A0:0B:ED|A4:6E:31|A8:8E:4F|AC:9E:17|B0:6E:BF|B4:82:FE|B8:9A:2A|C0:3F:0E|C4:1D:9F|C8:60:00|CC:04:0B|D0:57:7B|D4:6E:0E|DC:53:83|E0:3F:49|E4:5F:01|E8:EE:CC|EC:2E:4E|F0:0C:0B|F4:1B:A1|F8:63:3F|FC:06:6B) echo ASUS ;;
    00:16:EA|00:1E:67|3C:97:0E|54:B2:03|68:5C:4B|8C:16:45|AC:7F:3E|B0:48:7A|B4:6B:FC|C8:3A:35|D8:BB:C1|F4:4D:30|F8:CA:B8) echo Intel ;;
    *) echo "" ;;
  esac
}

# ---------- 日志轮转（上限 512KB，超限截断保留尾部） ----------
rotate_log() {
  [ -f "$LOG" ] || return 0
  SIZE=$("$BB" wc -c < "$LOG" 2>/dev/null | "$BB" tr -d ' ')
  case "$SIZE" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$SIZE" -gt 524288 ]; then
    "$BB" tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null
    mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    chmod 0600 "$LOG" 2>/dev/null
    printf '%s 日志已轮转（原 %s 字节）\n' "$(date)" "$SIZE" >> "$LOG"
  fi
}

# ---------- 蜂窝流量统计（开机以来 rmnet 累计，只读 /proc/net/dev） ----------
# 输出: CELL_RX CELL_TX（字节）
get_cell_stats() {
  # v1.7.2-beta.1：一次 cat 同时算 rx/tx，避免两次 cat|awk 管道（真机每次轮询重复执行）
  CELL_RX=$("$BB" awk '/^[[:space:]]*rmnet/{rx+=$2; tx+=$10} END{print rx" "tx}' /proc/net/dev 2>/dev/null)
  case "$CELL_RX" in *" "*) CELL_TX=${CELL_RX#* }; CELL_RX=${CELL_RX%% *} ;; *) CELL_TX=0; CELL_RX=0 ;; esac
  case "$CELL_RX" in ''|*[!0-9]*) CELL_RX=0 ;; esac
  case "$CELL_TX" in ''|*[!0-9]*) CELL_TX=0 ;; esac
}


# ---------- 电池状态（15 秒缓存，避免每 5 秒轮询都跑 dumpsys） ----------
get_battery_cached() {
  BATTERY=0
  CHARGING=false
  BATTERY_STATUS=0
  B_CACHE="$DATA_DIR/battery.cache"
  NOW_S=${NOW_S:-$(/system/bin/date +%s 2>/dev/null || date +%s)}
  if [ -r "$B_CACHE" ]; then
    B_MT=$("$BB" stat -c %Y "$B_CACHE" 2>/dev/null)
    case "$B_MT" in ''|*[!0-9]*) B_MT=0 ;; esac
    if [ "$B_MT" -gt 0 ] && [ $((NOW_S - B_MT)) -ge 0 ] && [ $((NOW_S - B_MT)) -lt 15 ]; then
      . "$B_CACHE" 2>/dev/null || true
      return 0
    fi
    # v1.7.2-beta.1：CGI 只读——缓存过期也直接沿用旧值（supervisor 每 tick 后台刷新），
    # 绝不执行 dumpsys battery（真机 1s+），避免页面状态接口卡顿。
    if [ "${CGI_READONLY:-0}" = "1" ]; then
      . "$B_CACHE" 2>/dev/null || true
      return 0
    fi
  elif [ "${CGI_READONLY:-0}" = "1" ]; then
    return 0
  fi
  B_DUMP="$DATA_DIR/battery.tmp.$$"
  "$BB" timeout 3 /system/bin/dumpsys battery > "$B_DUMP" 2>/dev/null || : > "$B_DUMP"
  LVL=$("$BB" awk '/level:/{print $2; exit}' "$B_DUMP" 2>/dev/null)
  STS=$("$BB" awk '/status:/{print $2; exit}' "$B_DUMP" 2>/dev/null)
  rm -f "$B_DUMP" 2>/dev/null
  case "$LVL" in ''|*[!0-9]*) LVL=0 ;; esac
  case "$STS" in 2|5) CHARGING=true ;; *) CHARGING=false ;; esac
  # 原始状态保留给低电量提醒：2=充电 3=放电 4=未充电 5=已充满 其它=未知
  case "$STS" in 2|3|4|5) BATTERY_STATUS=$STS ;; *) BATTERY_STATUS=0 ;; esac
  TMP="$B_CACHE.$$"
  {
    printf 'BATTERY=%s\n' "$LVL"
    printf 'CHARGING=%s\n' "$CHARGING"
    printf 'BATTERY_STATUS=%s\n' "$BATTERY_STATUS"
  } > "$TMP" 2>/dev/null
  chmod 0600 "$TMP" 2>/dev/null
  mv -f "$TMP" "$B_CACHE" 2>/dev/null
  BATTERY=$LVL
}

# ---------- 低电量提醒（移植自 UFI-TOOLS 低电量提醒 v1.3.0，适配本模块） ----------
# 规则：仅放电中（status=3）且电量≤阈值时提醒；同一轮只提醒一次（armed→attempted）；
#       连续 2 次检测到充电（status 2/5）或电量回升到 阈值+5（最高100）才重新武装；
#       推送复用 notify_all_async（PushPlus/钉钉），标题含"热点"以命中机器人自定义关键词。
LOWBATT_LATCH="$DATA_DIR/lowbatt.latch"   # armed / attempted
LOWBATT_STAT="$DATA_DIR/lowbatt.status"

lowbatt_tick() {
  # 未启用：写 disabled 快照，避免页面残留旧状态
  if [ "${LOWBATT_ENABLE:-0}" != "1" ]; then
    get_battery_cached
    printf 'level=%s\npower=%s\nthreshold=%s\nlatch=disabled\nreason=disabled\nchecked=%s\n' \
      "$BATTERY" "$BATTERY_STATUS" "${LOWBATT_THRESHOLD:-20}" "$(/system/bin/date +%s 2>/dev/null || date +%s)" \
      > "$LOWBATT_STAT" 2>/dev/null
    chmod 0600 "$LOWBATT_STAT" 2>/dev/null
    return 0
  fi
  case "${LOWBATT_THRESHOLD:-0}" in ''|*[!0-9]*) LOWBATT_THRESHOLD=20 ;; esac
  [ "$LOWBATT_THRESHOLD" -ge 1 ] && [ "$LOWBATT_THRESHOLD" -le 100 ] || LOWBATT_THRESHOLD=20
  get_battery_cached
  RESET=$((LOWBATT_THRESHOLD + 5)); [ "$RESET" -le 100 ] || RESET=100
  LATCH=$("$BB" head -n 1 "$LOWBATT_LATCH" 2>/dev/null)
  case "$LATCH" in armed|attempted) ;; *) LATCH=armed ;; esac
  REASON=monitoring
  # 恢复确认：连续 2 tick 检测到充电或电量回升到阈值+5 以上，才重新武装
  if [ "$BATTERY_STATUS" = "2" ] || [ "$BATTERY_STATUS" = "5" ]; then
    LB_CHARGE=$(( ${LB_CHARGE:-0} + 1 ))
    LB_RECOV=0
  else
    LB_CHARGE=0
    if [ "$BATTERY" -ge "$RESET" ]; then LB_RECOV=$(( ${LB_RECOV:-0} + 1 )); else LB_RECOV=0; fi
  fi
  if [ "$LATCH" = "attempted" ] && { [ "$LB_CHARGE" -ge 2 ] || [ "$LB_RECOV" -ge 2 ]; }; then
    printf 'armed\n' > "$LOWBATT_LATCH" 2>/dev/null
    LATCH=armed
    echo "$(date) lowbatt: 已恢复（充电或电量回升），允许下一次低电量提醒" >> "$LOG"
  fi
  # 触发：放电中 + 电量≤阈值 + 已武装 → 先落 attempted 再异步推送（防重复）
  if [ "$BATTERY_STATUS" = "3" ] && [ "$BATTERY" -le "$LOWBATT_THRESHOLD" ] && [ "$LATCH" = "armed" ]; then
    # P2-62：未配置任何通知渠道时不锁定“已提醒”，避免“显示已提醒但实际没发出去”
    if [ -z "${PUSHPLUS_TOKEN:-}${DINGTALK_WEBHOOK:-}" ]; then
      REASON=no_channel
    elif printf 'attempted\n' > "$LOWBATT_LATCH" 2>/dev/null; then
      LATCH=attempted
      notify_all_async "热点低电量提醒" "当前电量 $BATTERY%，已低于提醒阈值 $LOWBATT_THRESHOLD%，请及时充电。
时间: $(/system/bin/date '+%m-%d %H:%M')"
      echo "$(date) lowbatt: 低电量提醒已进入发送队列（$BATTERY% <= $LOWBATT_THRESHOLD%）" >> "$LOG"
      REASON=alert_queued
    else
      REASON=state_write_failed
    fi
  elif [ "$LATCH" = "attempted" ]; then
    REASON=already_alerted
  fi
  # 快照供状态接口读取（15 秒 tick 更新）
  printf 'level=%s\npower=%s\nthreshold=%s\nlatch=%s\nreason=%s\nchecked=%s\n'     "$BATTERY" "$BATTERY_STATUS" "$LOWBATT_THRESHOLD" "$LATCH" "$REASON"     "$(/system/bin/date +%s 2>/dev/null || date +%s)" > "$LOWBATT_STAT" 2>/dev/null
  chmod 0600 "$LOWBATT_STAT" 2>/dev/null
}


# ---------- 统计链过期规则清理：链内 RETURN 的 IP 已不在线则删除 ----------
# 输入: 当前在线 IP 列表（其余参数）
cleanup_stats_rules() {
  ONLINE="$*"
  $IPT -L mifi_stats -n -v -x 2>/dev/null | "$BB" awk '$3=="RETURN" && $8 ~ /^[0-9.]+$/ {print $8} $3=="RETURN" && $9 ~ /^[0-9.]+$/ {print $9}' | sort -u | while read -r ip; do
    case " $ONLINE " in *" $ip "*) continue ;; esac
    $IPT -D mifi_stats -s "$ip" -j RETURN 2>/dev/null
    $IPT -D mifi_stats -d "$ip" -j RETURN 2>/dev/null
  done
}

# ---------- 流量限额（累计热点转发流量，持久化防重启清零） ----------
# v1.5.2 口径变更：从“手机蜂窝总流量（rmnet）”改为“热点转发流量（FORWARD 链）”，
# 手机自身使用流量不再计入限额。数据文件语义不变（data_usage/last_usage）。
USAGE_FILE="$DATA_DIR/data_usage"
USAGE_SNAP="$DATA_DIR/last_usage"
USAGE_IFACE_FILE="$DATA_DIR/usage_iface"   # 记录上次统计链接口（P1-39，接口变化时清理旧跳转）

# 热点转发流量链：mifi_up（FORWARD -i 热点接口 = 客户端上行）、mifi_dn（FORWARD -o = 客户端下行）。
# 独立于按客户端 IP 计数的 mifi_stats 链；被黑名单 DROP 的包不进入本链（不计入限额）。
# 链级字节同时作为"实时速度"的数据源，不再依赖在线设备列表汇总（设备离线/换 IP 不产生瞬时归零与尖峰）。
ensure_usage_chain() {
  iface=$1
  [ -z "$iface" ] && return 0
  # P1-39：热点接口变化时清理旧接口上残留的 FORWARD 跳转，避免旧规则继续计数/残留
  OLD_IFACE=$("$BB" cat "$USAGE_IFACE_FILE" 2>/dev/null | "$BB" tr -d ' ')
  if [ -n "$OLD_IFACE" ] && [ "$OLD_IFACE" != "$iface" ]; then
    while $IPT -C FORWARD -i "$OLD_IFACE" -j mifi_up 2>/dev/null; do
      $IPT -D FORWARD -i "$OLD_IFACE" -j mifi_up 2>/dev/null
    done
    while $IPT -C FORWARD -o "$OLD_IFACE" -j mifi_dn 2>/dev/null; do
      $IPT -D FORWARD -o "$OLD_IFACE" -j mifi_dn 2>/dev/null
    done
    echo "$(date) usage: 热点接口 $OLD_IFACE -> $iface，已清理旧接口统计跳转" >> "$LOG"
  fi
  printf '%s\n' "$iface" > "$USAGE_IFACE_FILE" 2>/dev/null
  $IPT -N mifi_up 2>/dev/null || true
  $IPT -N mifi_dn 2>/dev/null || true
  $IPT -C FORWARD -i "$iface" -j mifi_up 2>/dev/null || \
    $IPT -I FORWARD 1 -i "$iface" -j mifi_up 2>/dev/null
  $IPT -C FORWARD -o "$iface" -j mifi_dn 2>/dev/null || \
    $IPT -I FORWARD 1 -o "$iface" -j mifi_dn 2>/dev/null
  # 迁移旧版单链 mifi_usage（无引用时清除；有引用说明旧规则仍在，一并移除避免重复计数）
  if $IPT -L mifi_usage -n 2>/dev/null | "$BB" grep -q . 2>/dev/null; then
    $IPT -F mifi_usage 2>/dev/null
    $IPT -D FORWARD -i "$iface" -j mifi_usage 2>/dev/null
    $IPT -D FORWARD -o "$iface" -j mifi_usage 2>/dev/null
    $IPT -X mifi_usage 2>/dev/null
  fi
}

# 读取指定统计链当前字节（rx/tx 由 up/dn 链分别给出）
get_chain_bytes() {
  chain=$1
  $IPT -L "$chain" -n -v -x 2>/dev/null | "$BB" awk 'NR>2 && $1 ~ /^[0-9]+$/ {s+=$2} END {print s+0}'
}

# 把热点转发链相对快照的增量累加进累计（字节）。
# 链被清/热点重启（计数器归零）时本次不累计，从当前重新开始——热点关闭期间无转发流量，不算漏计。
accumulate_usage() {
  CUR=$(( $(get_chain_bytes mifi_up) + $(get_chain_bytes mifi_dn) ))
  SNAP=$(cat "$USAGE_SNAP" 2>/dev/null | "$BB" tr -d ' ')
  case "$SNAP" in ''|*[!0-9]*) SNAP=0 ;; esac
  ACC=$("$BB" cat "$USAGE_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$ACC" in ''|*[!0-9]*) ACC=0 ;; esac
  if [ "$CUR" -lt "$SNAP" ]; then
    # P1-38：统计链被系统清除/计数器重置时记录原因与时间（避免静默丢段），从当前值重新开始
    echo "$(date) usage: 计数器回退 cur=$CUR snap=$SNAP，统计链可能被清除；从当前值重新累计" >> "$LOG"
    SNAP=$CUR
  fi
  DIFF=$((CUR - SNAP))
  if [ "$DIFF" -gt 0 ]; then
    ACC=$((ACC + DIFF))
    printf '%s\n' "$ACC" > "$USAGE_FILE"
    chmod 0600 "$USAGE_FILE"
  fi
  printf '%s\n' "$CUR" > "$USAGE_SNAP"
  chmod 0600 "$USAGE_SNAP"
}

# 读取累计用量（MB）与是否超限
read_usage() {
  USAGE_BYTES=$("$BB" cat "$USAGE_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$USAGE_BYTES" in ''|*[!0-9]*) USAGE_BYTES=0 ;; esac
  USAGE_MB=$((USAGE_BYTES / 1048576))
  USAGE_OVER=false
  plan_total_mb
  # P0-24(1.5.12)：超限判断改按账期用量，不再按历史总累计
  if [ "$PLAN_TOTAL" -gt 0 ] 2>/dev/null; then
    plan_period_bytes
    PERIOD_MB=$((PLAN_PERIOD_BYTES / 1048576))
    [ "$PERIOD_MB" -ge "$PLAN_TOTAL" ] 2>/dev/null && USAGE_OVER=true
  fi
}

reset_usage() {
  # P0-27：与确认框文案一致——累计、客户端统计、账期基线、分级提醒标记全部清零
  rm -f "$USAGE_FILE" "$USAGE_SNAP" "$TRAFFIC_BASE" "$TRAFFIC_DAILY" "$CLIENT_USAGE_FILE" "$CLIENT_SNAP_FILE" "$PLAN_TH_MARK" "$PLAN_PERIOD_FILE"
}
# ---------- 模块数据版本（v1.5.2）：流量限额口径变更，旧统计自动清零 ----------
VERSION_FILE="$DATA_DIR/module_version"

check_version_upgrade() {
  # P0(1.5.11)：迁移改为独立标记文件，每个迁移只执行一次；
  # 不再用“版本号 != 某版本”判断（旧逻辑会导致 VERSION_FILE 在 1.5.2/1.5.10 间交替，
  # 服务每次重启都会清空流量统计文件）。
  MIG_DIR="$DATA_DIR/.migrated"
  # P0(1.5.12)：老版本升级识别——config 已存在且尚无迁移目录，说明本次是从 1.5.10 及以前升级；
  # 此时已有统计数据，两个迁移都只补标记、不执行破坏性清零（字段合并仍照常）。
  UPGRADE=0
  if [ -f "$CONFIG" ] && [ ! -d "$MIG_DIR" ]; then
    UPGRADE=1
  fi
  mkdir -p "$MIG_DIR" 2>/dev/null
  chmod 0700 "$MIG_DIR" 2>/dev/null
  # 1.5.2 起点：限额口径切换（历史遗留，一次性）
  if [ ! -e "$MIG_DIR/v1_5_2" ]; then
    if [ "$UPGRADE" != "1" ]; then
      rm -f "$USAGE_FILE" "$USAGE_SNAP" "$TRAFFIC_BASE" "$TRAFFIC_DAILY" "$CLIENT_USAGE_FILE" "$CLIENT_SNAP_FILE"
    fi
    : > "$MIG_DIR/v1_5_2"
    chmod 0600 "$MIG_DIR/v1_5_2" 2>/dev/null
    echo "$(date) v1.5.2: 流量限额口径已改为热点转发流量，旧统计已清零" >> "$LOG"
  fi
  # 1.5.10：日归档改字节保存/账期保留62天 + 限额与套餐字段合并（一次性）
  if [ ! -e "$MIG_DIR/v1_5_10" ]; then
    if [ "$UPGRADE" != "1" ]; then
      rm -f "$TRAFFIC_DAILY" "$TRAFFIC_BASE"
    fi
    if [ -f "$CONFIG" ]; then
      OLD_LIMIT=$("$BB" sed -n 's/^DATA_LIMIT_MB=//p' "$CONFIG" 2>/dev/null | "$BB" head -n1 | "$BB" tr -d ' ')
      OLD_PLAN=$("$BB" sed -n 's/^DATA_PLAN_MB=//p' "$CONFIG" 2>/dev/null | "$BB" head -n1 | "$BB" tr -d ' ')
      case "$OLD_LIMIT" in ''|*[!0-9]*) OLD_LIMIT=0 ;; esac
      case "$OLD_PLAN" in ''|*[!0-9]*) OLD_PLAN=0 ;; esac
      NEW_PLAN=$OLD_PLAN
      [ "$OLD_LIMIT" -gt "$NEW_PLAN" ] 2>/dev/null && NEW_PLAN=$OLD_LIMIT
      if [ "$OLD_LIMIT" != "$OLD_PLAN" ] 2>/dev/null; then
        "$BB" grep -vE '^(DATA_LIMIT_MB|DATA_PLAN_MB)=' "$CONFIG" > "$CONFIG.tmp.$$" 2>/dev/null
        printf 'DATA_PLAN_MB=%s\n' "$NEW_PLAN" >> "$CONFIG.tmp.$$" 2>/dev/null
        mv -f "$CONFIG.tmp.$$" "$CONFIG" 2>/dev/null
        chmod 0600 "$CONFIG" 2>/dev/null
      fi
    fi
    : > "$MIG_DIR/v1_5_10"
    chmod 0600 "$MIG_DIR/v1_5_10" 2>/dev/null
    echo "$(date) v1.5.10: 日流量归档改为字节保存（账期保留62天）；限额/套餐字段合并为 DATA_PLAN_MB" >> "$LOG"
  fi
  # 版本文件仅作展示，不参与迁移判断
  printf '1.5.11\n' > "$VERSION_FILE" 2>/dev/null
  chmod 0600 "$VERSION_FILE" 2>/dev/null
}

# ================= v1.3.7 P2 新增 =================

# ---------- 客户端限速（tc HTB，仅下行；实验性，Android 内核兼容性差） ----------
# 规则文件: rate_limits，每行 MAC|Kbps（0 行不会被写入，删除即解除）
RATE_FILE="$DATA_DIR/rate_limits"

find_tc() {
  command -v tc 2>/dev/null || { [ -x /system/bin/tc ] && echo /system/bin/tc; }
}

# 读取某 MAC 的限速（Kbps），未设置返回空
get_rate_limit() {
  mac=$1
  "$BB" grep "^$mac|" "$RATE_FILE" 2>/dev/null | "$BB" head -n 1 | "$BB" cut -d'|' -f2
}

# 更新规则文件（mac|rate，rate=0 表示删除该条）
write_rate_limit() {
  mac=$1
  rate=$2
  TMP="$RATE_FILE.tmp.$$"
  if [ -f "$RATE_FILE" ]; then
    "$BB" grep -v "^$mac|" "$RATE_FILE" 2>/dev/null > "$TMP" || true
  else
    : > "$TMP"
  fi
  if [ "$rate" -gt 0 ] 2>/dev/null; then
    printf '%s|%s\n' "$mac" "$rate" >> "$TMP"
  fi
  mv -f "$TMP" "$RATE_FILE" 2>/dev/null
  chmod 0600 "$RATE_FILE" 2>/dev/null
}

# 对当前接口应用全部限速规则（先全清再重放，幂等）
# 仅限速下行（客户端从互联网下载方向）；上行需 ifb 内核模块，不实现。
# v1.5.2：保存 MAC→IP 应用快照（rate_limit_ips）；某设备 IP 变化时自动重建，
# 避免 tc filter 仍指向旧 IP 导致限速失效。
RATE_IPS_FILE="$DATA_DIR/rate_limit_ips"

apply_rate_limits() {
  iface=$1
  [ -z "$iface" ] && return 0
  TC=$(find_tc)
  if [ -z "$TC" ]; then
    echo "$(date) rate: tc 不存在，跳过限速" >> "$LOG"
    return 1
  fi
  [ -f "$RATE_FILE" ] || { rm -f "$RATE_IPS_FILE"; return 0; }
  CLIENTS=$(list_clients "$iface")
  # IP 变化检测：RATE_FILE 中每个 MAC 的当前 IP 与上次应用快照不一致则需重建
  REBUILD=0
  while IFS='|' read -r MAC RATE; do
    valid_mac "$MAC" || continue
    CURIP=$(printf '%s\n' "$CLIENTS" | "$BB" awk -F'|' -v m="$MAC" '$2==m{print $1; exit}')
    [ -z "$CURIP" ] && continue
    OLDIP=$("$BB" grep "^$MAC|" "$RATE_IPS_FILE" 2>/dev/null | "$BB" head -n 1 | "$BB" cut -d'|' -f2)
    if [ -n "$OLDIP" ] && [ "$OLDIP" != "$CURIP" ]; then
      REBUILD=1
    fi
  done < "$RATE_FILE"
  # 已应用（根 qdisc 存在）且映射未变：跳过重建，避免每 15s 全量删除/重建导致客户端断流抖动
  if "$TC" qdisc show dev "$iface" 2>/dev/null | "$BB" grep -q 'htb'; then
    [ "$REBUILD" = "1" ] || return 0
    "$TC" qdisc del dev "$iface" root 2>/dev/null
  fi
  # 先清空旧规则（接口重建后 qdisc 已消失，del 失败可忽略）
  "$TC" qdisc del dev "$iface" root 2>/dev/null
  IDX=10
  while IFS='|' read -r MAC RATE; do
    valid_mac "$MAC" || continue
    case "$RATE" in ''|*[!0-9]*) continue ;; esac
    [ "$RATE" -lt 32 ] && RATE=32
    [ "$RATE" -gt 1000000 ] && RATE=1000000
    IP=$(printf '%s\n' "$CLIENTS" | "$BB" awk -F'|' -v m="$MAC" '$2==m{print $1; exit}')
    [ -z "$IP" ] && continue
    # P1-48：default 30 必须存在稳定创建的默认类 1:30，否则未命中 filter 的流量会被丢弃
    "$TC" qdisc add dev "$iface" root handle 1: htb default 30 2>/dev/null
    "$TC" class add dev "$iface" parent 1: classid 1:30 htb rate 1000000kbit ceil 1000000kbit 2>/dev/null
    "$TC" class add dev "$iface" parent 1: classid "1:$IDX" htb rate "${RATE}kbit" ceil "${RATE}kbit" 2>/dev/null
    "$TC" filter add dev "$iface" parent 1: protocol ip prio 1 u32 match ip dst "$IP/32" flowid "1:$IDX" 2>/dev/null
    IDX=$((IDX + 1))
  done < "$RATE_FILE"
  # 写映射快照
  TMP="$RATE_IPS_FILE.tmp.$$"
  : > "$TMP"
  while IFS='|' read -r MAC RATE; do
    valid_mac "$MAC" || continue
    IP=$(printf '%s\n' "$CLIENTS" | "$BB" awk -F'|' -v m="$MAC" '$2==m{print $1; exit}')
    [ -n "$IP" ] && printf '%s|%s\n' "$MAC" "$IP" >> "$TMP"
  done < "$RATE_FILE"
  mv -f "$TMP" "$RATE_IPS_FILE" 2>/dev/null
  chmod 0600 "$RATE_IPS_FILE" 2>/dev/null
  if [ "$IDX" -gt 10 ]; then
    echo "$(date) rate: 已应用客户端限速规则" >> "$LOG"
  fi
}

# 清除接口上全部限速规则
clear_rate_limits_all() {
  iface=$1
  [ -z "$iface" ] && return 0
  TC=$(find_tc)
  [ -z "$TC" ] && return 0
  "$TC" qdisc del dev "$iface" root 2>/dev/null
}

# ---------- 客户端流量按 MAC 持久化（v1.5.2） ----------
# mifi_stats 链按 IP 计数，设备重拿 IP 会导致历史计数丢失/错配。
# 每 tick 把链计数增量累加到 client_usage（MAC|rx|tx），并记录链快照（IP|rx|tx），
# 页面展示以 MAC 为维度的累计值（设备离线/换 IP 后累计仍保留）。
CLIENT_USAGE_FILE="$DATA_DIR/client_usage"
CLIENT_SNAP_FILE="$DATA_DIR/client_usage_snap"

persist_client_usage() {
  iface=$1
  [ -z "$iface" ] && return 0
  MAP=$(read_all_stats)
  [ -z "$MAP" ] && return 0
  CLIENT_MACS=$(list_clients "$iface")
  SNAP_TMP="$CLIENT_SNAP_FILE.tmp.$$"
  USAGE_TMP="$CLIENT_USAGE_FILE.tmp.$$"
  : > "$SNAP_TMP"
  if [ -f "$CLIENT_USAGE_FILE" ]; then
    cp -f "$CLIENT_USAGE_FILE" "$USAGE_TMP" 2>/dev/null || : > "$USAGE_TMP"
  else
    : > "$USAGE_TMP"
  fi
  OLD_SNAP=$("$BB" cat "$CLIENT_SNAP_FILE" 2>/dev/null)
  printf '%s\n' "$MAP" | while IFS=' ' read -r IP RX TX; do
    case "$IP" in ''|*[!0-9.]*) continue ;; esac
    case "$RX" in ''|*[!0-9]*) RX=0 ;; esac
    case "$TX" in ''|*[!0-9]*) TX=0 ;; esac
    MAC=$(printf '%s\n' "$CLIENT_MACS" | "$BB" awk -F'|' -v ip="$IP" '$1==ip{print $2; exit}')
    [ -z "$MAC" ] && continue
    ORX=0; OTX=0
    if [ -n "$OLD_SNAP" ]; then
      OLDLINE=$(printf '%s\n' "$OLD_SNAP" | "$BB" grep "^$IP|" | "$BB" head -n 1)
      ORX=$(printf '%s\n' "$OLDLINE" | "$BB" cut -d'|' -f2)
      OTX=$(printf '%s\n' "$OLDLINE" | "$BB" cut -d'|' -f3)
      case "$ORX" in ''|*[!0-9]*) ORX=0 ;; esac
      case "$OTX" in ''|*[!0-9]*) OTX=0 ;; esac
    fi
    DRX=$((RX - ORX)); [ "$DRX" -lt 0 ] && DRX=0
    DTX=$((TX - OTX)); [ "$DTX" -lt 0 ] && DTX=0
    if [ "$DRX" -gt 0 ] || [ "$DTX" -gt 0 ]; then
      URX=0; UTX=0
      OLD=$(grep "^$MAC|" "$USAGE_TMP" 2>/dev/null | head -n 1)
      URX=$(printf '%s\n' "$OLD" | cut -d'|' -f2)
      UTX=$(printf '%s\n' "$OLD" | cut -d'|' -f3)
      case "$URX" in ''|*[!0-9]*) URX=0 ;; esac
      case "$UTX" in ''|*[!0-9]*) UTX=0 ;; esac
      URX=$((URX + DRX)); UTX=$((UTX + DTX))
      TMP2="$USAGE_TMP.2"
      grep -v "^$MAC|" "$USAGE_TMP" 2>/dev/null > "$TMP2" || true
      printf '%s|%s|%s\n' "$MAC" "$URX" "$UTX" >> "$TMP2"
      mv -f "$TMP2" "$USAGE_TMP"
    fi
    printf '%s|%s|%s\n' "$IP" "$RX" "$TX" >> "$SNAP_TMP"
  done
  mv -f "$SNAP_TMP" "$CLIENT_SNAP_FILE" 2>/dev/null
  chmod 0600 "$CLIENT_SNAP_FILE" 2>/dev/null
  mv -f "$USAGE_TMP" "$CLIENT_USAGE_FILE" 2>/dev/null
  chmod 0600 "$CLIENT_USAGE_FILE" 2>/dev/null
}

# 读取某 MAC 的持久化累计（rx tx 空格分隔，无则空）
get_client_usage() {
  mac=$1
  "$BB" grep "^$mac|" "$CLIENT_USAGE_FILE" 2>/dev/null | "$BB" head -n 1 | "$BB" cut -d'|' -f2,3
}

# ---------- 设备备注与历史设备 ----------
# 备注文件: device_notes，每行 MAC|备注（备注可为空=清除）
DEVICE_NOTES="$DATA_DIR/device_notes"

get_device_note() {
  mac=$1
  "$BB" grep "^$mac|" "$DEVICE_NOTES" 2>/dev/null | "$BB" head -n 1 | "$BB" cut -d'|' -f2-
}

set_device_note() {
  mac=$1
  note=$2
  TMP="$DEVICE_NOTES.tmp.$$"
  if [ -f "$DEVICE_NOTES" ]; then
    "$BB" grep -v "^$mac|" "$DEVICE_NOTES" 2>/dev/null > "$TMP" || true
  else
    : > "$TMP"
  fi
  if [ -n "$note" ]; then
    printf '%s|%s\n' "$mac" "$note" >> "$TMP"
  fi
  mv -f "$TMP" "$DEVICE_NOTES" 2>/dev/null
  chmod 0600 "$DEVICE_NOTES" 2>/dev/null
}
# ================= v1.3.8 新增 =================


# 一次性迁移：清理 v1.5.2 及更早版本创建的无 comment 80 端口规则（只执行一次，升级后首次运行）。
# 精确匹配本模块旧规则形态（192.168.43.1 + tcp dpt:80 + REDIRECT），不误删其他模块。
migrate_port80_once() {
  [ "${PORT80_MIGRATED:-0}" = "1" ] && return 0
  for CHAIN in PREROUTING OUTPUT; do
    while :; do
      N=$($IPT -t nat -L "$CHAIN" --line-numbers -n 2>/dev/null | \
          "$BB" grep '192.168.43.1.*tcp dpt:80' | "$BB" grep -v 'xiaomi_mifi_web' | \
          "$BB" grep 'REDIRECT' | "$BB" head -n1 | "$BB" awk '{print $1}')
      [ -z "$N" ] && break
      $IPT -t nat -D "$CHAIN" "$N" 2>/dev/null
    done
  done
  # 写入迁移标记（config 不存在则创建）
  if [ -f "$CONFIG" ]; then
    "$BB" grep -v '^PORT80_MIGRATED=' "$CONFIG" > "$CONFIG.tmp.$$" 2>/dev/null
    printf 'PORT80_MIGRATED=1\n' >> "$CONFIG.tmp.$$" 2>/dev/null
    mv -f "$CONFIG.tmp.$$" "$CONFIG" 2>/dev/null
  else
    printf 'PORT80_MIGRATED=1\n' > "$CONFIG" 2>/dev/null
  fi
  chmod 0600 "$CONFIG" 2>/dev/null
  PORT80_MIGRATED=1
}


# ================= v1.5.6 一次性迁移：清理已删除功能 =================
# 网页终端 / DDNSTO 远程控制 / 普通 Wi‑Fi 开关 / 80 端口转发 / 本机 IP 列表 /
# 配置预设 / 热点启停通知 / 二维码 已从模块移除。
# 升级后首次运行清理旧版遗留（目录、进程、状态文件、配置字段），仅执行一次。
migrate_removed_once() {
  [ "${MIGRATE_REMOVED:-0}" = "1" ] && return 0
  # 1. DDNSTO 二进制目录与残留进程
  # 旧版 DDNSTO 目录固定位于数据目录下（v1.5.5 及更早版本）
  [ -d "$DATA_DIR/ddnsto" ] && rm -rf "$DATA_DIR/ddnsto" 2>/dev/null
  # P1-66：只清理模块自身启动的 DDNSTO 进程（cmdline 含模块数据目录），不做全局 pkill，避免误杀独立安装
  for DP in /proc/[0-9]*; do
    CMDL=$("$BB" tr '\000' ' ' < "$DP/cmdline" 2>/dev/null)
    case "$CMDL" in *"$DATA_DIR/ddnsto"*) kill "${DP#/proc/}" 2>/dev/null ;; esac
  done
  # 2. 网页终端工作目录文件
  [ -f "$DATA_DIR/term_cwd" ] && rm -f "$DATA_DIR/term_cwd" 2>/dev/null
  # 3. 热点启停通知状态文件
  [ -f "$DATA_DIR/ap_state" ] && rm -f "$DATA_DIR/ap_state" 2>/dev/null
  # 4. 清理配置中的已删字段（保留 PORT80_MIGRATED 内部迁移标记）
  if [ -f "$CONFIG" ]; then
    "$BB" grep -vE '^(PORT80|NOTIFY_HOTSPOT|DDNSTO_TOKEN_B64|DDNSTO_BOOT)=' "$CONFIG" > "$CONFIG.tmp.$$" 2>/dev/null
    printf 'MIGRATE_REMOVED=1\n' >> "$CONFIG.tmp.$$" 2>/dev/null
    mv -f "$CONFIG.tmp.$$" "$CONFIG" 2>/dev/null
  else
    printf 'MIGRATE_REMOVED=1\n' > "$CONFIG" 2>/dev/null
  fi
  chmod 0600 "$CONFIG" 2>/dev/null
  MIGRATE_REMOVED=1
}


# ================= v1.4.0 新增 =================

# ---------- 消息转发（PushPlus / 钉钉群机器人） ----------
# PushPlus: https://www.pushplus.plus/ 用 token 推送消息到微信（关注公众号后接收）
# 钉钉: 群机器人 webhook；支持「加签」安全模式（纯 shell HMAC-SHA256，设备无 openssl 也可用），
#       也可选「自定义关键词」（消息含“热点”即命中）或「IP 白名单」。
# 配置经 base64url 存 config（避免 & = 等字符破坏 shell source）。
# 发送 PushPlus（$1=标题 $2=内容）；返回 0=成功 1=失败 2=未配置
# 通知渠道健康记录：每行 channel|last_send|last_ok|err|fails
#   channel=pp/dt/sms；last_send/last_ok 为 epoch 秒（0=无）；err=最近失败原因；fails=连续失败次数
health_note() {
  CH=$1; RES=$2; ERR=$3
  NOW=$(/system/bin/date +%s 2>/dev/null || date +%s)
  # P2-63：错误内容里的 | 会破坏“|”分隔的健康文件字段，清洗为 _
  ERR=$(printf '%s' "$ERR" 2>/dev/null | "$BB" tr '|\r\n' '___')
  # P1-56：并发写保护（mkdir 原子锁），避免多 worker 同时改写健康文件互相覆盖
  lock_acquire "$NOTIFY_HEALTH_LOCK" || return 0
  OLD=$("$BB" grep "^$CH|" "$NOTIFY_HEALTH_FILE" 2>/dev/null | "$BB" head -n 1)
  LAST_OK=$(printf '%s' "$OLD" | "$BB" cut -d'|' -f3)
  FAILS=$(printf '%s' "$OLD" | "$BB" cut -d'|' -f5)
  case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
  case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac
  if [ "$RES" = "0" ]; then
    FAILS=0; LAST_OK=$NOW; ERR=
  else
    FAILS=$((FAILS + 1))
  fi
  TMP="$NOTIFY_HEALTH_FILE.tmp.$$"
  "$BB" grep -v "^$CH|" "$NOTIFY_HEALTH_FILE" 2>/dev/null > "$TMP" || true
  printf '%s|%s|%s|%s|%s\n' "$CH" "$NOW" "$LAST_OK" "$ERR" "$FAILS" >> "$TMP"
  mv -f "$TMP" "$NOTIFY_HEALTH_FILE" 2>/dev/null
  chmod 0600 "$NOTIFY_HEALTH_FILE" 2>/dev/null
  lock_release "$NOTIFY_HEALTH_LOCK"
}

# 读取渠道健康：输出 last_send|last_ok|err|fails
read_health() {
  # v1.7.2-beta.1：纯 shell 匹配（文件小），避免 grep|head|cut 三个子进程
  [ -r "$NOTIFY_HEALTH_FILE" ] || return 0
  while IFS= read -r _HL; do
    case "$_HL" in
      "$1"|*) printf '%s' "${_HL#*|}"; return 0 ;;
    esac
  done < "$NOTIFY_HEALTH_FILE" 2>/dev/null
}

send_pushplus() {
  PUSHPLUS_LAST_ERR=
  [ -n "${PUSHPLUS_TOKEN:-}" ] || return 2
  TITLE_ESC=$(json_escape "$1")
  CONTENT_ESC=$(json_escape_nl "$2")
  ERR_TMP="$DATA_DIR/.pp_err.$$"
  R=$(/system/bin/curl -sS -m 8 -X POST https://www.pushplus.plus/send \
      -H "Content-Type: application/json" \
      -d "{\"token\":\"${PUSHPLUS_TOKEN}\",\"title\":\"$TITLE_ESC\",\"content\":\"$CONTENT_ESC\"}" 2>"$ERR_TMP")
  RC=$?
  CURL_ERR=$("$BB" cat "$ERR_TMP" 2>/dev/null | "$BB" head -c 200)
  rm -f "$ERR_TMP"
  if [ "$RC" -ne 0 ]; then
    PUSHPLUS_LAST_ERR="curl 错误($RC)${CURL_ERR:+: $CURL_ERR}"
    echo "$(date) pushplus curl failed rc=$RC ${CURL_ERR:+err=$CURL_ERR}" >> "$LOG"
    health_note pp 1 "$PUSHPLUS_LAST_ERR"
    return 1
  fi
  if printf '%s' "$R" | "$BB" grep -q '"code":200'; then
    echo "$(date) pushplus ok" >> "$LOG"
    health_note pp 0 ''
    return 0
  fi
  PERR=$(printf '%s' "$R" | "$BB" head -c 200)
  PUSHPLUS_LAST_ERR="PushPlus 返回: $PERR"
  echo "$(date) pushplus err: $PERR" >> "$LOG"
  health_note pp 1 "$PUSHPLUS_LAST_ERR"
  return 1
}

# 钉钉加签：sign = base64( HMAC-SHA256(key=secret, msg=timestamp+"\n"+secret) )。
# 设备无 openssl，按 RFC2104 展开式纯 shell 实现：K>64 字节先哈希，K⊕ipad/opad，消息为空串。
dingtalk_sign() {
  ts=$1
  secret=$2
  case "$secret" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  TMPD="$DATA_DIR/.sig.$$"
  mkdir -p "$TMPD" 2>/dev/null || return 1
  # K = secret（≤64 字节直接用，>64 先 SHA-256 压缩）
  printf '%s' "$secret" > "$TMPD/K.txt"
  KLEN=${#secret}
  if [ "$KLEN" -gt 64 ]; then
    "$BB" sha256sum "$TMPD/K.txt" | "$BB" cut -d' ' -f1 | "$BB" xxd -r -p > "$TMPD/K.bin"
    KBLEN=32
  else
    "$BB" cat "$TMPD/K.txt" > "$TMPD/K.bin"
    KBLEN=$KLEN
  fi
  KBS=$("$BB" od -An -tu1 "$TMPD/K.bin" 2>/dev/null | "$BB" tr -s ' \n' ' ')
  : > "$TMPD/ipad"
  : > "$TMPD/opad"
  N=0
  for B in $KBS; do
    [ "$N" -ge "$KBLEN" ] && break
    case "$B" in ''|*[!0-9]*) continue ;; esac
    PI=$((B ^ 0x36))
    PO=$((B ^ 0x5c))
    printf "\\$(printf '%03o' "$PI")" >> "$TMPD/ipad"
    printf "\\$(printf '%03o' "$PO")" >> "$TMPD/opad"
    N=$((N + 1))
  done
  PAD=$((64 - KBLEN))
  J=0
  while [ "$J" -lt "$PAD" ]; do
    printf '\066' >> "$TMPD/ipad"
    printf '\134' >> "$TMPD/opad"
    J=$((J + 1))
  done
  # msg = timestamp + "\n" + secret
  printf '%s\n%s' "$ts" "$secret" > "$TMPD/M.txt"
  # inner = SHA256( ipad || msg )
  { "$BB" cat "$TMPD/ipad"; "$BB" cat "$TMPD/M.txt"; } > "$TMPD/inner_in"
  IH=$("$BB" sha256sum "$TMPD/inner_in" | "$BB" cut -d' ' -f1)
  printf '%s' "$IH" | "$BB" xxd -r -p > "$TMPD/inner"
  # outer = SHA256( opad || inner )
  { "$BB" cat "$TMPD/opad"; "$BB" cat "$TMPD/inner"; } > "$TMPD/outer"
  OH=$("$BB" sha256sum "$TMPD/outer" | "$BB" cut -d' ' -f1)
  printf '%s' "$OH" | "$BB" xxd -r -p | "$BB" base64 | "$BB" tr -d '\r\n'
  rm -rf "$TMPD"
}

# 发送钉钉群机器人（$1=内容）；返回 0=成功 1=失败 2=未配置。
# 失败时把 curl/DNS/钉钉 errmsg 写入日志并记录到 DINGTALK_LAST_ERR（供测试接口展示）。
send_dingtalk() {
  DINGTALK_LAST_ERR=
  [ -n "${DINGTALK_WEBHOOK:-}" ] || return 2
  CONTENT_ESC=$(json_escape_nl "$1")
  URL="$DINGTALK_WEBHOOK"
  if [ -n "${DINGTALK_SECRET:-}" ]; then
    TS=$(/system/bin/date +%s 2>/dev/null || date +%s)000
    SIGN=$(dingtalk_sign "$TS" "$DINGTALK_SECRET")
    if [ -z "$SIGN" ]; then
      DINGTALK_LAST_ERR='签名计算失败（加签密钥可能无效）'
      echo "$(date) dingtalk: sign empty (invalid secret)" >> "$LOG"
      return 1
    fi
    SIGN_ENC=$(printf '%s' "$SIGN" | "$BB" sed 's/+/%2B/g; s#/#%2F#g; s/=/ %3D/g' | "$BB" tr -d ' ')
    case "$URL" in *\?*) URL="$URL&timestamp=$TS&sign=$SIGN_ENC" ;; *) URL="$URL?timestamp=$TS&sign=$SIGN_ENC" ;; esac
  fi
  ERR_TMP="$DATA_DIR/.dt_err.$$"
  R=$(/system/bin/curl -sS -m 8 -X POST "$URL" \
      -H "Content-Type: application/json" \
      -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$CONTENT_ESC\"}}" 2>"$ERR_TMP")
  RC=$?
  CURL_ERR=$("$BB" cat "$ERR_TMP" 2>/dev/null | "$BB" head -c 200)
  rm -f "$ERR_TMP"
  if [ "$RC" -ne 0 ]; then
    DINGTALK_LAST_ERR="curl 错误($RC)${CURL_ERR:+: $CURL_ERR}"
    echo "$(date) dingtalk curl failed rc=$RC ${CURL_ERR:+err=$CURL_ERR}" >> "$LOG"
    health_note dt 1 "$DINGTALK_LAST_ERR"
    return 1
  fi
  if printf '%s' "$R" | "$BB" grep -q '"errcode":0'; then
    echo "$(date) dingtalk ok" >> "$LOG"
    health_note dt 0 ''
    return 0
  fi
  DERR=$(printf '%s' "$R" | "$BB" sed -n 's/.*"errcode":\([0-9]*\).*"errmsg":"\([^"]*\)".*/\1 \2/p' | "$BB" head -c 200)
  [ -n "$DERR" ] || DERR=$(printf '%s' "$R" | "$BB" head -c 200)
  DINGTALK_LAST_ERR="钉钉返回: $DERR"
  echo "$(date) dingtalk err: $DERR" >> "$LOG"
  health_note dt 1 "$DINGTALK_LAST_ERR"
  return 1
}

# 发送 Bark（iPhone 推送）：POST JSON 到 https://api.day.app/{key}
send_bark() {
  BARK_LAST_ERR=
  [ -n "${BARK_KEY:-}" ] || return 2
  TITLE_ESC=$(json_escape "$1")
  CONTENT_ESC=$(json_escape_nl "$2")
  ERR_TMP="$DATA_DIR/.bk_err.$$"
  R=$(/system/bin/curl -sS -m 8 -X POST "https://api.day.app/$BARK_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"$TITLE_ESC\",\"body\":\"$CONTENT_ESC\"}" 2>"$ERR_TMP")
  RC=$?
  CURL_ERR=$("$BB" cat "$ERR_TMP" 2>/dev/null | "$BB" head -c 200)
  rm -f "$ERR_TMP"
  if [ "$RC" -ne 0 ]; then
    BARK_LAST_ERR="curl 错误($RC)${CURL_ERR:+: $CURL_ERR}"
    echo "$(date) bark curl failed rc=$RC ${CURL_ERR:+err=$CURL_ERR}" >> "$LOG"
    health_note bk 1 "$BARK_LAST_ERR"
    return 1
  fi
  if printf '%s' "$R" | "$BB" grep -q '"code":200'; then
    echo "$(date) bark ok" >> "$LOG"
    health_note bk 0 ''
    return 0
  fi
  BERR=$(printf '%s' "$R" | "$BB" head -c 200)
  BARK_LAST_ERR="Bark 返回: $BERR"
  echo "$(date) bark err: $BERR" >> "$LOG"
  health_note bk 1 "$BARK_LAST_ERR"
  return 1
}

# 向所有已配置渠道推送（$1=标题 $2=内容，内容可含真实换行）
# 返回 0=至少一个渠道成功；1=全部失败（未配置渠道按失败计，但调用方应先判断已配置）
notify_all() {
  send_pushplus "$1" "$2"
  RC1=$?
  # 钉钉机器人若设置自定义关键词（如"热点"），关键词必须在正文中出现：
  # 把标题并入正文（【标题】 内容），确保自动通知可命中关键词
  send_dingtalk "【$1】 $2"
  RC2=$?
  send_bark "$1" "$2"
  RC3=$?
  [ "$RC1" = "0" ] || [ "$RC2" = "0" ] || [ "$RC3" = "0" ]
}

# 通知队列（目录式，一消息一文件）：事件先入队，后台 worker 顺序发送，主守护循环不被 curl 阻塞。
# 并发安全：入队=创建独立文件；消费=mkdir 原子锁 + 先删后发。worker 持锁期间按 PID 存活判定，
# 不再受"30 秒超时"限制（一条通知最长约 16 秒，队列长时也不会被误判失效而并发运行）。
NOTIFY_QUEUE="$DATA_DIR/notify.queue"          # 新版为目录；旧版遗留文本文件由 migrate 迁移
NOTIFY_LOCK_DIR="$DATA_DIR/notify.lock"
NOTIFY_BUSY="$DATA_DIR/notify.busy"            # 旧版遗留（迁移时清理）
NOTIFY_HEALTH_LOCK="$DATA_DIR/health.lock"     # 通知健康文件并发写锁（P1-56）

# mkdir 原子锁：返回 0=拿到锁；锁内 info 写 "PID 时间"。
# 锁存在时检查持有者 PID：进程仍存活视为有效锁（无论持锁多久）；PID 已死则回收。
self_pid() {
  # 子 Shell 中 $$ 仍是父 PID；/proc/self/stat 才是当前真实 PID
  "$BB" awk '{print $1}' /proc/self/stat 2>/dev/null
}

lock_acquire() {
  lockdir=$1
  SPID=$(self_pid)
  case "$SPID" in ''|*[!0-9]*) SPID=$$ ;; esac
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s %s\n' "$SPID" "$($DATE_CMD +%s 2>/dev/null || date +%s)" > "$lockdir/info" 2>/dev/null
    return 0
  fi
  LPID=$("$BB" cut -d' ' -f1 "$lockdir/info" 2>/dev/null)
  case "$LPID" in ''|*[!0-9]*) LPID=0 ;; esac
  if [ "$LPID" -gt 0 ] && ! kill -0 "$LPID" 2>/dev/null; then
    rm -rf "$lockdir" 2>/dev/null
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s %s\n' "$SPID" "$($DATE_CMD +%s 2>/dev/null || date +%s)" > "$lockdir/info" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

lock_release() {
  rm -rf "$1" 2>/dev/null
}

notify_next_seq() {
  SEQ_FILE="$DATA_DIR/notify.seq"
  # P1-55：读改写必须原子（mkdir 锁），否则并发入队可能取到相同序号导致文件互相覆盖
  if ! lock_acquire "$DATA_DIR/notify.seq.lock"; then
    # 锁异常兜底：时间戳+真实PID 保证唯一（不保证递增但保证不覆盖）
    printf '%s%s%s' "$($DATE_CMD +%s 2>/dev/null || date +%s)" "$$" "$("$BB" awk '{print $1}' /proc/self/stat 2>/dev/null)" | "$BB" tr -d ' '
    return 0
  fi
  SEQ=$("$BB" cat "$SEQ_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$SEQ" in ''|*[!0-9]*) SEQ=0 ;; esac
  SEQ=$((SEQ + 1))
  printf '%s\n' "$SEQ" > "$SEQ_FILE" 2>/dev/null
  chmod 0600 "$SEQ_FILE" 2>/dev/null
  lock_release "$DATA_DIR/notify.seq.lock"
  printf '%s' "$SEQ"
}

notify_all_async() {
  # 入队（标题/正文 base64url 编码，避免 | 与换行破坏行格式）
  TB=$(printf '%s' "$1" | "$BB" base64 | "$BB" tr '+/' '-_' | "$BB" tr -d '=\n')
  MB=$(printf '%s' "$2" | "$BB" base64 | "$BB" tr '+/' '-_' | "$BB" tr -d '=\n')
  mkdir -p "$NOTIFY_QUEUE" 2>/dev/null
  TS=$($DATE_CMD +%s 2>/dev/null || date +%s)
  SPID=$(self_pid); case "$SPID" in ''|*[!0-9]*) SPID=$$ ;; esac
  SEQ=$(notify_next_seq)
  # 单文件入队：文件名含时间戳/真实PID/原子序号（不依赖 $RANDOM，同秒同进程多条不会覆盖）；
  # 内容 8 字段：title|msg|pp_state|dt_state|bk_state|sc_state|retry|next_ts（渠道独立状态，供失败重试）
  printf '%s|%s|pending|pending|pending|pending|0|0\n' "$TB" "$MB" > "$NOTIFY_QUEUE/$TS.$SPID.$SEQ.msg" 2>/dev/null
  # 触发 worker：锁被占用则由现有 worker 继续消费，不会重复发送
  drain_notify_queue >/dev/null 2>&1 &
}

# 通知 worker：按文件名时间戳顺序发送；渠道独立状态 + 失败退避重试（1/5/15 分钟，共 4 次）。
# 消息格式 6 字段：title_b64|msg_b64|pp_state|dt_state|retry|next_ts
#   pp_state/dt_state: pending=待发 done=成功 failed=最终失败；retry=已重试次数；next_ts=下次尝试时间戳
pick_due_file() {
  for f in $("$BB" ls -1 "$NOTIFY_QUEUE" 2>/dev/null | "$BB" sort -n); do
    NX=$("$BB" cut -d'|' -f6 "$NOTIFY_QUEUE/$f" 2>/dev/null)
    case "$NX" in ''|*[!0-9]*) NX=0 ;; esac
    NOW=$($DATE_CMD +%s 2>/dev/null || date +%s)
    if [ "$NX" -le "$NOW" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

drain_notify_queue() {
  lock_acquire "$NOTIFY_LOCK_DIR" || return 0
  while :; do
    # P1-52 修复：按到期时间选取第一个可处理文件；未到期文件不阻塞队列，避免队头死循环
    # （函数形式：macOS bash3.2 不支持 $(...) 内直接写 case）
    FIRST=$(pick_due_file)
    [ -z "$FIRST" ] && break
    FILE="$NOTIFY_QUEUE/$FIRST"
    # 兼容旧格式（升级迁移前残留）：6 字段补 bk/sc 到 8 字段，其余补全
    NF=$("$BB" awk -F'|' '{print NF}' "$FILE" 2>/dev/null)
    case "$NF" in
      8) : ;;
      6) printf '%s|pending|pending|0|0\n' "$($BB cat "$FILE" 2>/dev/null)" > "$FILE" 2>/dev/null ;;
      *) printf '%s|pending|pending|pending|pending|0|0\n' "$($BB cat "$FILE" 2>/dev/null)" > "$FILE" 2>/dev/null ;;
    esac
    TITLE_B=$("$BB" cut -d'|' -f1 "$FILE" 2>/dev/null)
    MSG_B=$("$BB" cut -d'|' -f2 "$FILE" 2>/dev/null)
    PP=$("$BB" cut -d'|' -f3 "$FILE" 2>/dev/null)
    DT=$("$BB" cut -d'|' -f4 "$FILE" 2>/dev/null)
    BK=$("$BB" cut -d'|' -f5 "$FILE" 2>/dev/null)
    SC=$("$BB" cut -d'|' -f6 "$FILE" 2>/dev/null)
    RETRY=$("$BB" cut -d'|' -f7 "$FILE" 2>/dev/null)
    NEXT=$("$BB" cut -d'|' -f8 "$FILE" 2>/dev/null)
    case "$PP" in pending|done|failed) ;; *) PP=pending ;; esac
    case "$DT" in pending|done|failed) ;; *) DT=pending ;; esac
    case "$BK" in pending|done|failed) ;; *) BK=pending ;; esac
    case "$SC" in pending|done|failed) ;; *) SC=pending ;; esac
    case "$RETRY" in ''|*[!0-9]*) RETRY=0 ;; esac
    case "$NEXT" in ''|*[!0-9]*) NEXT=0 ;; esac
    NOW=$($DATE_CMD +%s 2>/dev/null || date +%s)
    # P1-52：不按队头阻塞——未到期跳过，继续处理队列中已到期的其他消息
    [ "$NEXT" -gt "$NOW" ] && continue
    [ -z "$TITLE_B" ] && [ -z "$MSG_B" ] && { rm -f "$FILE" 2>/dev/null; continue; }
    TITLE=$(b64url_decode "$TITLE_B")
    MSG=$(b64url_decode "$MSG_B")
    CHANGED=0
    if [ "$PP" = "pending" ] || [ "$PP" = "failed" ]; then
      PP=pending
      send_pushplus "$TITLE" "$MSG"; PRC=$?
      if [ "$PRC" = "0" ]; then PP=done
      elif [ "$PRC" = "2" ]; then PP=done   # 未配置渠道视为完成，不重试
      else PP=failed; CHANGED=1; fi
    fi
    if [ "$DT" = "pending" ] || [ "$DT" = "failed" ]; then
      DT=pending
      send_dingtalk "【$TITLE】 $MSG"; DRC=$?
      if [ "$DRC" = "0" ]; then DT=done
      elif [ "$DRC" = "2" ]; then DT=done
      else DT=failed; CHANGED=1; fi
    fi
    if [ "$BK" = "pending" ] || [ "$BK" = "failed" ]; then
      BK=pending
      send_bark "$TITLE" "$MSG"; BRC=$?
      if [ "$BRC" = "0" ]; then BK=done
      elif [ "$BRC" = "2" ]; then BK=done
      else BK=failed; CHANGED=1; fi
    fi
    # Server酱 已移除：SC 位保留以兼容存量队列文件，直接视为完成
    SC=done
    if [ "$CHANGED" = "1" ]; then
      RETRY=$((RETRY + 1))
      if [ "$RETRY" -le 3 ]; then
        case "$RETRY" in 1) W=60 ;; 2) W=300 ;; 3) W=900 ;; esac
        NEXT=$((NOW + W))
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$TITLE_B" "$MSG_B" "$PP" "$DT" "$BK" "$SC" "$RETRY" "$NEXT" > "$FILE" 2>/dev/null
        echo "$(date) notify: 部分渠道失败，${RETRY} 次后 ${W}s 重试（pp=$PP dt=$DT bk=$BK sc=$SC title=$TITLE）" >> "$LOG"
        continue
      fi
      echo "$(date) notify: 已达最大重试次数，丢弃（pp=$PP dt=$DT bk=$BK sc=$SC title=$TITLE）" >> "$LOG"
      rm -f "$FILE" 2>/dev/null
      continue
    fi
    rm -f "$FILE" 2>/dev/null
  done
  lock_release "$NOTIFY_LOCK_DIR"
}

# 兼容旧版文本文件队列（v1.5.4 及之前）：模块升级启动时一次性迁移到目录式队列。
# 先用临时目录接收旧行，成功后再原子替换，避免"先建目录导致旧文件读不到"的顺序问题。
migrate_legacy_queues() {
  # 通知队列旧文件 notify.queue（每行 ts|title_b64|msg_b64）→ 目录单文件（内容 title|msg）
  if [ -f "$NOTIFY_QUEUE" ] && [ ! -d "$NOTIFY_QUEUE" ]; then
    TMPD="$NOTIFY_QUEUE.new.$$"
    rm -rf "$TMPD" 2>/dev/null
    mkdir -p "$TMPD" 2>/dev/null
    N=0
    while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      N=$((N + 1))
      TS=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f1)
      REST=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f2-)
      case "$TS" in ''|*[!0-9]*) TS=$($DATE_CMD +%s 2>/dev/null || date +%s) ;; esac
      printf '%s|pending|pending|pending|pending|0|0\n' "$REST" > "$TMPD/$TS.mig.$N.$RANDOM.msg" 2>/dev/null
    done < "$NOTIFY_QUEUE" 2>/dev/null
    rm -f "$NOTIFY_QUEUE" 2>/dev/null
    mv -f "$TMPD" "$NOTIFY_QUEUE" 2>/dev/null
  fi
  # 短信队列旧文件 sms.queue（每行 id|retry|next）→ 目录单文件 id.msg（内容 retry|next）
  if [ -f "$SMS_QUEUE" ] && [ ! -d "$SMS_QUEUE" ]; then
    TMPD="$SMS_QUEUE.new.$$"
    rm -rf "$TMPD" 2>/dev/null
    mkdir -p "$TMPD" 2>/dev/null
    while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      ID=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f1)
      REST=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f2-)
      case "$ID" in ''|*[!0-9]*) continue ;; esac
      printf '%s\n' "$REST" > "$TMPD/$ID.msg" 2>/dev/null
    done < "$SMS_QUEUE" 2>/dev/null
    rm -f "$SMS_QUEUE" 2>/dev/null
    mv -f "$TMPD" "$SMS_QUEUE" 2>/dev/null
  fi
  # 清理旧版锁与 busy 文件
  rm -f "$NOTIFY_BUSY" "$SMS_BUSY" 2>/dev/null
  rm -rf "$NOTIFY_LOCK" 2>/dev/null
}


# ================= v1.5.0 新增 =================

# ---------- 短信转发（验证码/通知短信 → PushPlus/钉钉） ----------
# 依赖 Android content 命令查询短信 provider（root 下可用，无需 sqlite3）。
# 配置: SMS_FWD=1 开启; SMS_FWD_KEYWORD_B64 为空=全部，否则仅含该关键词的短信转发;
#       SMS_FWD_SENDERS_B64 为空=全部，否则仅白名单号码（逗号分隔，base64url）。
SMS_LAST_FILE="$DATA_DIR/sms_last_id"
SMS_QUEUE="$DATA_DIR/sms.queue"               # 新版为目录；旧版遗留文本文件由 migrate 迁移
SMS_LOCK_DIR="$DATA_DIR/sms.lock"             # 短信 worker 并发锁（mkdir 原子）
SMS_SCAN_LOCK="$DATA_DIR/sms_scan.lock"       # 短信扫描锁（原 notify.lock 改名，避免与通知锁混淆）
SMS_DEDUP_FILE="$DATA_DIR/sms_forward_dedup"      # 短信内容去重记录（fingerprint|timestamp）
SMS_FRESH_SEC=900        # 只转发最近15分钟收到的短信（防止恢复/导入旧短信重推）
SMS_DEDUP_SEC=600        # 相同发件人+正文，10分钟内只转发一次
NOTIFY_LOCK="$DATA_DIR/notify.lock"           # 旧版遗留路径（migrate 清理用）
TRAFFIC_DAILY="$DATA_DIR/traffic_daily"
TRAFFIC_BASE="$DATA_DIR/traffic_base"
DATE_CMD=${DATE_CMD:-/system/bin/date}
CONTENT_CMD=${CONTENT_CMD:-/system/bin/content}

# 查询新短信（_id > $1 的收件短信），输出每行 id|address|body|date
# 注意: content query 输出为 "Row: N _id=.., address=.., body=.., date=.."，
# body 中若出现 ", date=" 会截断（概率极低，可接受）。
query_new_sms() {
  LAST=$1
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  $CONTENT_CMD query --uri content://sms --projection _id:address:date:body --where "_id>$LAST AND type=1" 2>/dev/null | while IFS= read -r LINE; do
    ID=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=\([0-9]*\).*/\1/p')
    ADDR=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=[0-9]*, address=\([^,]*\),.*/\1/p')
    DATE=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=[0-9]*, address=[^,]*, date=\([0-9]*\),.*/\1/p')
    # P1-60：body 放投影最后一位，取“body= 到行尾”，正文中的 ", date=" 不再截断
    BODY=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=[0-9]*, address=[^,]*, date=[0-9]*, body=\(.*\)$/\1/p')
    case "$ID" in ''|*[!0-9]*) continue ;; esac
    # 顺序: id|address|date|body，body 放最后；body 自身含 | 不影响前三个字段解析
    printf '%s|%s|%s|%s\n' "$ID" "$ADDR" "$DATE" "$BODY"
  done
}

# 短信内容指纹：发件人+正文的 sha256
sms_fingerprint() {
  printf '%s\034%s' "$1" "$2" |
    "$BB" sha256sum 2>/dev/null |
    "$BB" awk '{print $1}'
}
# 检查指纹是否在去重窗口内
sms_seen_recently() {
  FP=$1
  [ -n "$FP" ] || return 1
  [ -s "$SMS_DEDUP_FILE" ] || return 1
  NOW=$($DATE_CMD +%s 2>/dev/null || date +%s)
  OLD=$("$BB" grep "^${FP}|" "$SMS_DEDUP_FILE" 2>/dev/null |
    "$BB" tail -n 1 |
    "$BB" cut -d'|' -f2)
  case "$OLD" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ $((NOW - OLD)) -lt "$SMS_DEDUP_SEC" ]
}
# 记录指纹（只保留24小时内的，最多100条）
sms_remember() {
  FP=$1
  [ -n "$FP" ] || return 0
  NOW=$($DATE_CMD +%s 2>/dev/null || date +%s)
  TMP="$SMS_DEDUP_FILE.tmp.$$"
  if [ -s "$SMS_DEDUP_FILE" ]; then
    "$BB" awk -F'|' -v now="$NOW" '
      NF == 2 && $2 ~ /^[0-9]+$/ && now - $2 <= 86400
    ' "$SMS_DEDUP_FILE" > "$TMP" 2>/dev/null
  else
    : > "$TMP"
  fi
  printf '%s|%s\n' "$FP" "$NOW" >> "$TMP"
  "$BB" tail -n 100 "$TMP" > "$TMP.keep" 2>/dev/null
  mv -f "$TMP.keep" "$SMS_DEDUP_FILE"
  rm -f "$TMP"
  chmod 0600 "$SMS_DEDUP_FILE" 2>/dev/null
}

# 短信转发轮询（service 每 15s tick 调用一次）
check_sms_forward() {
  [ "${SMS_FWD:-0}" = "1" ] || return 0
  [ -n "${PUSHPLUS_TOKEN:-}${DINGTALK_WEBHOOK:-}" ] || return 0
  # 扫描并发锁（mkdir 原子 + PID 存活判定）：上一轮扫描仍持有锁则跳过本 tick
  lock_acquire "$SMS_SCAN_LOCK" || return 0
  # 首次启用：只记录当前最大 _id 为起点，不转发历史短信
  if [ ! -f "$SMS_LAST_FILE" ]; then
    MAXID=$(query_new_sms 0 | "$BB" cut -d'|' -f1 | "$BB" sort -n | "$BB" tail -n 1 | "$BB" tr -d ' ')
    case "$MAXID" in ''|*[!0-9]*) MAXID=0 ;; esac
    printf '%s\n' "$MAXID" > "$SMS_LAST_FILE" 2>/dev/null
    chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
    lock_release "$SMS_SCAN_LOCK"
    return 0
  fi
  LAST=$(cat "$SMS_LAST_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  # 按 _id 升序处理，保证游标单调推进、失败不跨过
  NEW=$(query_new_sms "$LAST" | "$BB" sort -n -t'|' -k1,1)
  if [ -z "$NEW" ]; then
    lock_release "$SMS_SCAN_LOCK"
    return 0
  fi
  printf '%s\n' "$NEW" | while IFS= read -r LINE; do
    ID=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f1)
    ADDR=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f2)
    DATE=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f3)
    BODY=$(printf '%s\n' "$LINE" | "$BB" sed 's/^[^|]*|[^|]*|[^|]*|//')
    case "$ID" in ''|*[!0-9]*) continue ;; esac
    [ "$ID" -le "$LAST" ] && continue
    # 旧短信拦截：只转发最近15分钟内的新短信（防止恢复/导入重推）
    NOW_S=$($DATE_CMD +%s 2>/dev/null || date +%s)
    case "$DATE" in
      ''|*[!0-9]*)
        echo "$(date) sms skip: id=$ID invalid date" >> "$LOG"
        printf '%s\n' "$ID" > "$SMS_LAST_FILE"
        chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
        LAST=$ID
        continue
      ;;
    esac
    if [ "${#DATE}" -ge 13 ]; then
      SMS_DATE_S=$((DATE / 1000))
    else
      SMS_DATE_S=$DATE
    fi
    if [ "$SMS_DATE_S" -lt $((NOW_S - SMS_FRESH_SEC)) ] ||
       [ "$SMS_DATE_S" -gt $((NOW_S + 120)) ]; then
      echo "$(date) sms skip stale: id=$ID date=$DATE" >> "$LOG"
      printf '%s\n' "$ID" > "$SMS_LAST_FILE"
      chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
      LAST=$ID
      continue
    fi
    # 关键词过滤（固定字符串匹配，避免正则元字符误匹配）
    if [ -n "${SMS_FWD_KEYWORD:-}" ]; then
      if ! printf '%s' "$BODY" | "$BB" grep -Fq "$SMS_FWD_KEYWORD"; then
        # 被过滤：推进游标（不转发也不重复扫描），继续下一条
        printf '%s\n' "$ID" > "$SMS_LAST_FILE" 2>/dev/null
        chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
        LAST=$ID
        continue
      fi
    fi
    # 发件人白名单过滤（逗号分隔，留空=全部）
    if [ -n "${SMS_FWD_SENDERS:-}" ]; then
      HIT=0
      OLDIFS=$IFS; IFS=','
      for S in $SMS_FWD_SENDERS; do
        # P1-59：逐项去空白，'10086, 95533' 中第二个号码带空格也能匹配
        S=$(printf '%s' "$S" | "$BB" tr -d ' \t')
        [ -n "$S" ] && [ "$S" = "$ADDR" ] && HIT=1
      done
      IFS=$OLDIFS
      if [ "$HIT" != "1" ]; then
        # 白名单外：推进游标，继续
        printf '%s\n' "$ID" > "$SMS_LAST_FILE" 2>/dev/null
        chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
        LAST=$ID
        continue
      fi
    fi
    # 内容去重：相同发件人+正文10分钟内只转发一次
    FP=$(sms_fingerprint "$ADDR" "$BODY")
    if sms_seen_recently "$FP"; then
      echo "$(date) sms skip duplicate: id=$ID from=$ADDR" >> "$LOG"
      printf '%s\n' "$ID" > "$SMS_LAST_FILE"
      chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
      LAST=$ID
      continue
    fi
    # 匹配短信：检测阶段推进游标（避免每轮重复扫描），实际推送交给短信队列 worker。
    # 若已在队列（上次失败待重试）则不重复入队；单文件入队（内容 retry|next），并发安全。
    if [ ! -e "$SMS_QUEUE/$ID.msg" ]; then
      mkdir -p "$SMS_QUEUE" 2>/dev/null
      if printf '0|0\n' > "$SMS_QUEUE/$ID.msg" 2>/dev/null; then
        sms_remember "$FP"
      else
        echo "$(date) sms queue write failed: id=$ID" >> "$LOG"
        continue
      fi
    fi
    printf '%s\n' "$ID" > "$SMS_LAST_FILE" 2>/dev/null
    chmod 0600 "$SMS_LAST_FILE" 2>/dev/null
    LAST=$ID
  done
  lock_release "$SMS_SCAN_LOCK"
  # 触发短信 worker（锁被占用时由现有 worker 继续；空队列 worker 立即退出）
  sms_notify_worker >/dev/null 2>&1 &
}

# 短信 worker：目录式队列（每文件一条短信，文件名=短信ID，内容 retry|next）。
# 按 ID 升序处理；失败按 1/5/15 分钟退避，共尝试 4 次后放弃（推进，避免堵住队列）。
sms_notify_worker() {
  lock_acquire "$SMS_LOCK_DIR" || return 0
  while :; do
    ALL=$("$BB" ls -1 "$SMS_QUEUE" 2>/dev/null | "$BB" sort -n)
    [ -z "$ALL" ] && break
    DONE_ANY=0
    for FNAME in $ALL; do
      FILE="$SMS_QUEUE/$FNAME"
      [ -e "$FILE" ] || continue
      SID=$(printf '%s' "$FNAME" | "$BB" sed 's/\.msg$//')
      case "$SID" in ''|*[!0-9]*) rm -f "$FILE" 2>/dev/null; continue ;; esac
      # 兼容旧 2 字段（retry|next）：补渠道状态字段
      NF=$("$BB" awk -F'|' '{print NF}' "$FILE" 2>/dev/null)
      case "$NF" in 4) : ;; *) printf '%s|pending|pending\n' "$("$BB" cat "$FILE" 2>/dev/null)" > "$FILE" 2>/dev/null ;; esac
      SRETRY=$("$BB" cut -d'|' -f1 "$FILE" 2>/dev/null)
      SNEXT=$("$BB" cut -d'|' -f2 "$FILE" 2>/dev/null)
      SPP=$("$BB" cut -d'|' -f3 "$FILE" 2>/dev/null)
      SDT=$("$BB" cut -d'|' -f4 "$FILE" 2>/dev/null)
      case "$SRETRY" in ''|*[!0-9]*) SRETRY=0 ;; esac
      case "$SNEXT" in ''|*[!0-9]*) SNEXT=0 ;; esac
      case "$SPP" in pending|done|failed) ;; *) SPP=pending ;; esac
      case "$SDT" in pending|done|failed) ;; *) SDT=pending ;; esac
      NOW_S=$($DATE_CMD +%s 2>/dev/null || date +%s)
      case "$NOW_S" in ''|*[!0-9]*) NOW_S=0 ;; esac
      # P1-53：不按最小 ID 队头阻塞——未到期跳过，继续处理队列中已到期的其他短信
      if [ "$SNEXT" -gt "$NOW_S" ] 2>/dev/null; then
        continue
      fi
      # 从短信库按 ID 取内容（队列只存 ID，避免正文含 | 的转义问题）
      LINE=$(query_new_sms "$((SID - 1))" | "$BB" grep "^$SID|" | "$BB" head -n1)
      if [ -z "$LINE" ]; then
        # 短信已被系统删除：直接推进
        rm -f "$FILE" 2>/dev/null
        continue
      fi
      ADDR=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f2)
      DATE=$(printf '%s\n' "$LINE" | "$BB" cut -d'|' -f3)
      BODY=$(printf '%s\n' "$LINE" | "$BB" sed 's/^[^|]*|[^|]*|[^|]*|//')
      DATE_TXT=
      case "$DATE" in ''|*[!0-9]*) : ;; *)
        DATE_TXT=$($DATE_CMD -d "@$((DATE / 1000))" '+%m-%d %H:%M' 2>/dev/null || $DATE_CMD '+%m-%d %H:%M')
      ;; esac
      # Worker 再保护一次：旧消息直接丢弃
      NOW_W=$($DATE_CMD +%s 2>/dev/null || date +%s)
      case "$DATE" in
        ''|*[!0-9]*)
          echo "$(date) sms worker drop invalid date: id=$SID" >> "$LOG"
          rm -f "$FILE" 2>/dev/null
          continue
        ;;
      esac
      if [ "${#DATE}" -ge 13 ]; then
        SMS_DATE_W=$((DATE / 1000))
      else
        SMS_DATE_W=$DATE
      fi
      if [ "$SMS_DATE_W" -lt $((NOW_W - SMS_FRESH_SEC)) ] ||
         [ "$SMS_DATE_W" -gt $((NOW_W + 120)) ]; then
        echo "$(date) sms worker drop stale: id=$SID date=$DATE" >> "$LOG"
        rm -f "$FILE" 2>/dev/null
        continue
      fi
      # P1-54：双渠道独立发送与状态——PushPlus 成功、钉钉失败时钉钉单独重试，不整体删除任务
      SCHANGED=0
      if [ "$SPP" = "pending" ] || [ "$SPP" = "failed" ]; then
        SPP=pending
        send_pushplus "新短信" "来自: $ADDR
内容: $BODY
时间: $DATE_TXT"; SRC=$?
        if [ "$SRC" = "0" ]; then SPP=done
        elif [ "$SRC" = "2" ]; then SPP=done
        else SPP=failed; SCHANGED=1; fi
      fi
      if [ "$SDT" = "pending" ] || [ "$SDT" = "failed" ]; then
        SDT=pending
        send_dingtalk "【新短信】 来自: $ADDR
内容: $BODY
时间: $DATE_TXT"; SRC2=$?
        if [ "$SRC2" = "0" ]; then SDT=done
        elif [ "$SRC2" = "2" ]; then SDT=done
        else SDT=failed; SCHANGED=1; fi
      fi
      if [ "$SCHANGED" = "1" ]; then
        SRETRY=$((SRETRY + 1))
        if [ "$SRETRY" -ge 4 ]; then
          echo "$(date) sms forward GIVEUP: $SID after $SRETRY tries (pp=$SPP dt=$SDT)" >> "$LOG"
          health_note sms 1 "短信 $SID 多次推送失败已放弃"
          rm -f "$FILE" 2>/dev/null
          continue
        fi
        case "$SRETRY" in 1) D=60 ;; 2) D=300 ;; 3) D=900 ;; esac
        NEXT=$((NOW_S + D))
        echo "$(date) sms forward retry $SID in ${D}s (attempt $SRETRY/4, pp=$SPP dt=$SDT)" >> "$LOG"
        printf '%s|%s|%s|%s\n' "$SRETRY" "$NEXT" "$SPP" "$SDT" > "$FILE.tmp.$$" 2>/dev/null && mv -f "$FILE.tmp.$$" "$FILE" 2>/dev/null
        health_note sms 1 "待重试（第 $SRETRY 次）"
        DONE_ANY=1
        continue
      fi
      echo "$(date) sms forward ok: $SID" >> "$LOG"
      health_note sms 0 ''
      rm -f "$FILE" 2>/dev/null
      DONE_ANY=1
    done
    [ "$DONE_ANY" = "1" ] || break
  done
  lock_release "$SMS_LOCK_DIR"
}

# 短信队列统计（status.cgi 展示）：SMS_QUEUED=待发送（retry=0），SMS_RETRYING=重试中（retry>0）
count_sms_stats() {
  SMS_QUEUED=0
  SMS_RETRYING=0
  for F in "$SMS_QUEUE"/*.msg; do
    [ -e "$F" ] || continue
    SRETRY=$("$BB" cut -d'|' -f1 "$F" 2>/dev/null)
    case "$SRETRY" in ''|*[!0-9]*) SRETRY=0 ;; esac
    if [ "$SRETRY" -gt 0 ]; then SMS_RETRYING=$((SMS_RETRYING + 1)); else SMS_QUEUED=$((SMS_QUEUED + 1)); fi
  done
}


# ---------- 流量账期（v1.5.7） ----------
# 账期起始日 DATA_PLAN_DAY（每月 N 日）；周期已用 = 从本账期起始日到今天的日归档求和 + 今日基准。
# 返回 PLAN_PERIOD_BYTES / PLAN_PERIOD_DAY（起始日 YYYYMMDD）
# 计算某月天数（纯 shell，兼容 GNU/toybox/macOS date）
# $1=YYYYMM → 输出当月天数（28/29/30/31）
last_day_of_month() {
  YM=$1
  case "$YM" in ''|*[!0-9]*) echo 31; return ;; esac
  Y=$(printf '%s' "$YM" | "$BB" cut -c1-4)
  M=$(printf '%s' "$YM" | "$BB" cut -c5-6 | "$BB" sed 's/^0//')
  case "$M" in
    01|1|03|3|05|5|07|7|08|8|10|12) echo 31 ;;
    04|4|06|6|09|9|11) echo 30 ;;
    02|2)
      if [ $((Y % 4)) -ne 0 ]; then echo 28
      elif [ $((Y % 100)) -ne 0 ]; then echo 29
      elif [ $((Y % 400)) -ne 0 ]; then echo 28
      else echo 29; fi
      ;;
    *) echo 31 ;;
  esac
}

plan_period_bytes() {
  PLAN_PERIOD_BYTES=0
  PLAN_PERIOD_DAY=
  PD_ORIG=${DATA_PLAN_DAY:-1}
  case "$PD_ORIG" in ''|*[!0-9]*) PD_ORIG=1 ;; esac
  TODAY=${DATE_TODAY:-$($DATE_CMD +%Y%m%d 2>/dev/null)}
  DATE_TODAY=$TODAY
  case "$TODAY" in ''|*[!0-9]*) return 1 ;; esac
  PD=$PD_ORIG
  # P1-29(1.5.11)：账期起始日若超出当月天数（如 31 日在 2 月），取当月最后一天。
  # 用纯 shell 计算月天数，避免依赖 date -d（macOS/部分 toybox 语法不一致）。
  CM=${DATE_YM:-$($DATE_CMD +%Y%m 2>/dev/null)}
  DATE_YM=$CM
  case "$CM" in ''|*[!0-9]*) CM=0 ;; esac
  LAST_DOM=$(last_day_of_month "$CM")
  case "$LAST_DOM" in ''|*[!0-9]*) LAST_DOM=31 ;; esac
  [ "$PD" -gt "$LAST_DOM" ] 2>/dev/null && PD=$LAST_DOM
  # 账期起始日：本月 PD 日（若今天 < PD 日，则起始日为上月 PD 日）
  DOM=$(printf '%s' "$TODAY" | "$BB" cut -c7-8 | "$BB" sed 's/^0*//')
  case "$DOM" in ''|*[!0-9]*) DOM=1 ;; esac
  if [ "$DOM" -ge "$PD" ]; then
    PLAN_PERIOD_DAY=$(printf '%s%02d' "$($DATE_CMD +%Y%m 2>/dev/null)" "$PD")
  else
    # 上月 YYYYMM（纯 shell，不依赖 date -d）
    CM2=$($DATE_CMD +%Y%m 2>/dev/null)
    case "$CM2" in ''|*[!0-9]*) CM2=197001 ;; esac
    Y2=$(printf '%s' "$CM2" | "$BB" cut -c1-4)
    M2=$(printf '%s' "$CM2" | "$BB" cut -c5-6 | "$BB" sed 's/^0//')
    if [ "$M2" = "1" ] || [ "$M2" = "01" ]; then
      PREV=$(printf '%s12' "$((Y2 - 1))")
    else
      PREV=$(printf '%s%02d' "$Y2" "$((M2 - 1))")
    fi
    # 上月按“上月最后一天”独立截断（例：2月28日账期，3月31日配置）
    # P1-1(1.5.12)：上月必须从原始账期日重新截断（不能用本月已截断的 PD：31 日在 2 月会错成 28）
    PD_PREV=$PD_ORIG
    LPD=$(last_day_of_month "$PREV")
    case "$LPD" in ''|*[!0-9]*) LPD=31 ;; esac
    [ "$PD_PREV" -gt "$LPD" ] 2>/dev/null && PD_PREV=$LPD
    PLAN_PERIOD_DAY=$(printf '%s%02d' "$PREV" "$PD_PREV")
  fi
  # 日归档求和（>= 账期起始日）
  if [ -f "$TRAFFIC_DAILY" ]; then
    while IFS= read -r DL; do
      DD=$(printf '%s' "$DL" | "$BB" cut -d'|' -f1)
      DV=$(printf '%s' "$DL" | "$BB" cut -d'|' -f2)
      case "$DV" in ''|*[!0-9]*) continue ;; esac
      [ "$DD" -ge "$PLAN_PERIOD_DAY" ] 2>/dev/null || continue
      # v1.5.10：日归档直接存字节，不再 *1048576 换算（避免小流量丢失）
      PLAN_PERIOD_BYTES=$((PLAN_PERIOD_BYTES + DV))
    done < "$TRAFFIC_DAILY"
  fi
  # 今日基准
  if [ -r "$TRAFFIC_BASE" ]; then
    BD=$("$BB" cut -d'|' -f1 "$TRAFFIC_BASE" 2>/dev/null)
    BBY=$("$BB" cut -d'|' -f2 "$TRAFFIC_BASE" 2>/dev/null)
    case "$BBY" in ''|*[!0-9]*) BBY=0 ;; esac
    if [ "$BD" = "$TODAY" ]; then
      CUR=$("$BB" cat "$USAGE_FILE" 2>/dev/null | "$BB" tr -d ' ')
      case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
      [ "$CUR" -ge "$BBY" ] 2>/dev/null && PLAN_PERIOD_BYTES=$((PLAN_PERIOD_BYTES + CUR - BBY))
    fi
  fi
  return 0
}

# 套餐总量（MB）：v1.5.10 合并——限额与套餐为同一字段 DATA_PLAN_MB（0=不限）
plan_total_mb() {
  PLAN_TOTAL=${DATA_PLAN_MB:-0}
  case "$PLAN_TOTAL" in ''|*[!0-9]*) PLAN_TOTAL=0 ;; esac
}

# 账期使用率（0-100 整数，套餐 0=不限返回 -1）；同时输出 PLAN_PERIOD_USED（MB）
plan_usage_percent() {
  plan_period_bytes
  plan_total_mb
  case "$PLAN_TOTAL" in ''|*[!0-9]*) PLAN_TOTAL=0 ;; esac
  PLAN_PERIOD_USED=$((PLAN_PERIOD_BYTES / 1048576))
  PLAN_TOTAL_BYTES=$((PLAN_TOTAL * 1048576))
  if [ "$PLAN_TOTAL" -le 0 ] 2>/dev/null || [ "$PLAN_TOTAL_BYTES" -le 0 ] 2>/dev/null; then
    PLAN_PERCENT=-1
  else
    PLAN_PERCENT=$((PLAN_PERIOD_BYTES * 100 / PLAN_TOTAL_BYTES))
    [ "$PLAN_PERCENT" -gt 100 ] 2>/dev/null && PLAN_PERCENT=100
  fi
}

KNOWN_MACS="$DATA_DIR/known_macs"            # 历史设备（首次发现时间戳）统一路径（P0-42）

# ---------- 客户端历史（v1.5.7） ----------
# client_stats: 每行 MAC|first_seen|last_seen|online_sec（全部 epoch 秒）
# 在线累计：每次调用在线客户端 +INC 秒；离线后下次上线续计。
client_stats_touch() {
  MAC=$1; INC=$2
  NOW=$($DATE_CMD +%s 2>/dev/null)
  case "$NOW" in ''|*[!0-9]*) return 1 ;; esac
  case "$INC" in ''|*[!0-9]*) INC=0 ;; esac
  OLD=$("$BB" grep "^$MAC|" "$CLIENT_STATS_FILE" 2>/dev/null | "$BB" head -n1)
  FIRST=$("$BB" cut -d'|' -f2 <<EOF
$OLD
EOF
)
  LAST=$("$BB" cut -d'|' -f3 <<EOF
$OLD
EOF
)
  ON=$("$BB" cut -d'|' -f4 <<EOF
$OLD
EOF
)
  case "$FIRST" in ''|*[!0-9]*) FIRST=$NOW ;; esac
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  case "$ON" in ''|*[!0-9]*) ON=0 ;; esac
  ON=$((ON + INC))
  TMP="$CLIENT_STATS_FILE.tmp.$$"
  "$BB" grep -v "^$MAC|" "$CLIENT_STATS_FILE" 2>/dev/null > "$TMP" || true
  printf '%s|%s|%s|%s\n' "$MAC" "$FIRST" "$NOW" "$ON" >> "$TMP"
  mv -f "$TMP" "$CLIENT_STATS_FILE" 2>/dev/null
  chmod 0600 "$CLIENT_STATS_FILE" 2>/dev/null
}

# 读取客户端历史：输出 first|last|online_sec
client_stats_read() {
  "$BB" grep "^$1|" "$CLIENT_STATS_FILE" 2>/dev/null | "$BB" head -n1 | "$BB" cut -d'|' -f2-
}

# ---------- 只读信号质量（v1.5.7） ----------
# 依次尝试 dumpsys telephony.registry / getprop；取不到的字段留空（前端隐藏，不显示 N/A）。
# 输出：NETWORK= / OPERATOR= / SIM= / BAND= / PCI= / RSRP= / RSRQ= / SINR=
get_signal_info() {
  SIG_NETWORK=; SIG_OPERATOR=; SIG_SIM=; SIG_BAND=; SIG_PCI=; SIG_RSRP=; SIG_RSRQ=; SIG_SINR=
  SIG_CACHE="$DATA_DIR/sig.cache"
  NOW_S=${NOW_S:-$(/system/bin/date +%s 2>/dev/null || date +%s)}
  # P1-80：信号面板 5 秒轮询不应每次执行大型 dumpsys；缓存 60 秒，有效期内直接读取
  if [ -r "$SIG_CACHE" ]; then
    CACHE_MT=$("$BB" stat -c %Y "$SIG_CACHE" 2>/dev/null)
    case "$CACHE_MT" in ''|*[!0-9]*) CACHE_MT=0 ;; esac
    CACHE_AGE=$((NOW_S - CACHE_MT))
    if [ "$CACHE_MT" -gt 0 ] && [ "$CACHE_AGE" -ge 0 ] && [ "$CACHE_AGE" -lt 60 ] 2>/dev/null; then
      . "$SIG_CACHE" 2>/dev/null || true
      SIG_OPERATOR=$(b64url_decode "${SIG_OPERATOR_B64:-}")
      return 0
    fi
  fi
  # 与 get_sim_state 共享有限时 telephony 快照；不重复执行 dumpsys。
  # v1.7.2-beta.1：CGI 只读模式——sig.cache 由 supervisor 每 tick 后台预热（60s 限频），
  # 未命中直接返回空字段，绝不执行 grep 大快照重建。
  if [ "${CGI_READONLY:-0}" = "1" ]; then
    return 0
  fi
  DMP_FILE="$TELEPHONY_SNAPSHOT"
  SNAP_AGE=999
  if [ -r "$DMP_FILE" ]; then
    SNAP_MT=$("$BB" stat -c %Y "$DMP_FILE" 2>/dev/null)
    case "$SNAP_MT" in ''|*[!0-9]*) SNAP_MT=0 ;; esac
    [ "$SNAP_MT" -gt 0 ] && SNAP_AGE=$((NOW_S - SNAP_MT))
  fi
  if [ -s "$DMP_FILE" ] && [ "$SNAP_AGE" -ge 0 ] && [ "$SNAP_AGE" -lt 60 ] 2>/dev/null; then
    SIG_OPERATOR=$("$BB" grep -o 'mOperatorAlphaLong=[^,} ]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mOperatorAlphaLong=//')
    [ -n "$SIG_OPERATOR" ] || SIG_OPERATOR=$("$BB" grep -o 'mNetworkOperatorName=[^,} ]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mNetworkOperatorName=//')
    [ -n "$SIG_OPERATOR" ] || SIG_OPERATOR=$(getprop gsm.operator.alpha 2>/dev/null)
    SIG_OPERATOR=$(printf '%s' "$SIG_OPERATOR" | "$BB" sed 's/[, ]*$//')
    SIG_SIM=$("$BB" grep -o 'mSimState=[^,} ]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mSimState=//')
    case "$SIG_SIM" in
      ''|*) S=$(getprop gsm.sim.state 2>/dev/null); case "$S" in READY|NOT_READY|ABSENT|PIN_REQUIRED|PUK_REQUIRED|NETWORK_LOCKED) SIG_SIM=$S ;; esac ;;
    esac
    NT=$("$BB" grep -o 'mDataNetworkType=[0-9]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mDataNetworkType=//')
    [ -n "$NT" ] || NT=$("$BB" grep -o 'mNetworkType=[0-9]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mNetworkType=//')
    case "$NT" in
      20) SIG_NETWORK=5G ;;
      13) SIG_NETWORK=4G ;;
      3|8|9|15|16) SIG_NETWORK=3G ;;
      1|2|4|5|6|7) SIG_NETWORK=2G ;;
      0) SIG_NETWORK=无服务 ;;
      *) SIG_NETWORK= ;;
    esac
    if [ "$SIG_NETWORK" = "5G" ]; then
      NRST=$("$BB" grep -o 'mNrState=[0-9]*' "$DMP_FILE" | "$BB" head -n1 | "$BB" sed 's/mNrState=//')
      case "$NRST" in 3) SIG_NETWORK=5G-SA ;; 2|1) SIG_NETWORK=5G-NSA ;; *) SIG_NETWORK=5G ;; esac
    fi
    # 把当前服务小区块写到临时文件，避免长变量作为命令行参数触发 ARG_MAX
    CI_FILE="$DATA_DIR/cellinfo.tmp"
    "$BB" grep -o 'CellInfo{[^}]*CellIdentityLte=LteCellIdentity{[^}]*}[^}]*CellSignalStrengthLte=LteSignalStrength{[^}]*}' "$DMP_FILE" | "$BB" head -n1 > "$CI_FILE" 2>/dev/null
    if [ ! -s "$CI_FILE" ]; then
      "$BB" grep -o 'CellInfo{[^}]*CellIdentityNr=NrCellIdentity{[^}]*}[^}]*CellSignalStrengthNr=NrSignalStrength{[^}]*}' "$DMP_FILE" | "$BB" head -n1 > "$CI_FILE" 2>/dev/null
    fi
    if [ -s "$CI_FILE" ]; then
      SIG_PCI=$("$BB" grep -o 'mPci=[0-9]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/mPci=//')
      SIG_BAND=$("$BB" grep -o 'mEarfcn=[0-9]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/mEarfcn=//')
      [ -n "$SIG_BAND" ] || SIG_BAND=$("$BB" grep -o 'mNrArfcn=[0-9]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/mNrArfcn=//')
      SIG_RSRP=$("$BB" grep -o 'rsrp=[0-9-]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/rsrp=//')
      [ -n "$SIG_RSRP" ] || SIG_RSRP=$("$BB" grep -o 'ssRsrp=[0-9-]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/ssRsrp=//')
      SIG_RSRQ=$("$BB" grep -o 'rsrq=[0-9-]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/rsrq=//')
      [ -n "$SIG_RSRQ" ] || SIG_RSRQ=$("$BB" grep -o 'ssRsrq=[0-9-]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/ssRsrq=//')
      SIG_SINR=$("$BB" grep -o 'sinr=[0-9-.]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/sinr=//')
      [ -n "$SIG_SINR" ] || SIG_SINR=$("$BB" grep -o 'ssSinr=[0-9-.]*' "$CI_FILE" | "$BB" head -n1 | "$BB" sed 's/ssSinr=//')
    fi
    rm -f "$CI_FILE"
    TMP_CACHE="$SIG_CACHE.$$"
    {
      printf 'SIG_NETWORK=%s\n' "$SIG_NETWORK"
      printf 'SIG_OPERATOR_B64=%s\n' "$(b64url_encode "$SIG_OPERATOR")"
      printf 'SIG_SIM=%s\n' "$SIG_SIM"
      printf 'SIG_BAND=%s\n' "$SIG_BAND"
      printf 'SIG_PCI=%s\n' "$SIG_PCI"
      printf 'SIG_RSRP=%s\n' "$SIG_RSRP"
      printf 'SIG_RSRQ=%s\n' "$SIG_RSRQ"
      printf 'SIG_SINR=%s\n' "$SIG_SINR"
    } > "$TMP_CACHE" 2>/dev/null
    chmod 0600 "$TMP_CACHE" 2>/dev/null
    mv -f "$TMP_CACHE" "$SIG_CACHE" 2>/dev/null
  fi
}

# 信号等级（RSRP dBm）：≥-85 优秀；-85~-95 良好；-95~-105 一般；<-105 较差
signal_level() {
  case "$1" in ''|*[!0-9-]*) echo 未知; return 1 ;; esac
  if [ "$1" -ge -85 ] 2>/dev/null; then echo 优秀
  elif [ "$1" -ge -95 ] 2>/dev/null; then echo 良好
  elif [ "$1" -ge -105 ] 2>/dev/null; then echo 一般
  else echo 较差
  fi
}

# 读取 httpd.conf 当前后台密码（busybox httpd auth 行 "/:user:pass" 取末段）
read_admin_password() {
  "$BB" sed -n 's#^/:[^:]*:##p' "$HTTP_CONF" 2>/dev/null | "$BB" head -n 1
}

# ---------- 流量按日/月度统计 ----------
# TRAFFIC_BASE: "YYYYMMDD|bytes"（当日开始基准）；TRAFFIC_DAILY: 每行 "YYYYMMDD|MB"（保留 11 天）
accumulate_daily() {
  CUR=$("$BB" cat "$USAGE_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$CUR" in ''|*[!0-9]*) return 0 ;; esac
  TODAY=${DATE_TODAY:-$($DATE_CMD +%Y%m%d 2>/dev/null)}
  DATE_TODAY=$TODAY
  case "$TODAY" in ''|*[!0-9]*) return 0 ;; esac
  BASE_DATE=
  BASE_BYTES=0
  if [ -r "$TRAFFIC_BASE" ]; then
    BASE_DATE=$("$BB" cut -d'|' -f1 "$TRAFFIC_BASE" 2>/dev/null)
    BASE_BYTES=$("$BB" cut -d'|' -f2 "$TRAFFIC_BASE" 2>/dev/null)
    case "$BASE_BYTES" in ''|*[!0-9]*) BASE_BYTES=0 ;; esac
  fi
  if [ -z "$BASE_DATE" ] || [ "$BASE_DATE" != "$TODAY" ]; then
    # 跨日（或首次）：把 [BASE_BYTES, CUR) 记入前一日期（首次无前日则跳过）
    if [ -n "$BASE_DATE" ] && [ "$CUR" -ge "$BASE_BYTES" ]; then
      # v1.5.10：按字节保存，不足 1MB 的小流量不再被截断（页面显示时再换算）
      YDAY_BYTES=$((CUR - BASE_BYTES))
      TMP="$TRAFFIC_DAILY.tmp.$$"
      if [ -f "$TRAFFIC_DAILY" ]; then
        "$BB" grep -v "^$BASE_DATE|" "$TRAFFIC_DAILY" 2>/dev/null > "$TMP" || true
      else
        : > "$TMP"
      fi
      printf '%s|%s\n' "$BASE_DATE" "$YDAY_BYTES" >> "$TMP"
      # P0-28：图表只展示最近 11 天，但账期求和至少保留 62 天（月套餐跨第 12 天不漏算）
      "$BB" tail -n 62 "$TMP" > "$TMP.2" 2>/dev/null
      mv -f "$TMP.2" "$TMP" 2>/dev/null
      mv -f "$TMP" "$TRAFFIC_DAILY" 2>/dev/null
      chmod 0600 "$TRAFFIC_DAILY" 2>/dev/null
    fi
    printf '%s|%s\n' "$TODAY" "$CUR" > "$TRAFFIC_BASE" 2>/dev/null
    chmod 0600 "$TRAFFIC_BASE" 2>/dev/null
  fi
}

# 输出: TRAFFIC_TODAY_BYTES / TRAFFIC_MONTH_BYTES / TRAFFIC_DAYS（最近 11 行 "YYYYMMDD|bytes"）
# v1.5.10：today/month 改为字节输出（前端 formatTrafficMb(d/1048576) 换算显示），小流量不再恒为 0
read_traffic_stats() {
  TRAFFIC_TODAY_BYTES=0
  TRAFFIC_MONTH_BYTES=0
  TRAFFIC_TODAY_VALID=false
  TRAFFIC_MONTH_VALID=false
  TRAFFIC_DAYS=
  CUR=$("$BB" cat "$USAGE_FILE" 2>/dev/null | "$BB" tr -d ' ')
  case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
  BASE_DATE=
  BASE_BYTES=0
  if [ -r "$TRAFFIC_BASE" ]; then
    BASE_DATE=$("$BB" cut -d'|' -f1 "$TRAFFIC_BASE" 2>/dev/null)
    BASE_BYTES=$("$BB" cut -d'|' -f2 "$TRAFFIC_BASE" 2>/dev/null)
    case "$BASE_BYTES" in ''|*[!0-9]*) BASE_BYTES=0 ;; esac
  fi
  TODAY=${DATE_TODAY:-$($DATE_CMD +%Y%m%d 2>/dev/null)}
  DATE_TODAY=$TODAY
  THIS_MONTH=$($DATE_CMD +%Y%m 2>/dev/null)
  if [ -n "$BASE_DATE" ] && [ "$BASE_DATE" = "$TODAY" ]; then
    if [ "$CUR" -ge "$BASE_BYTES" ]; then
      TRAFFIC_TODAY_BYTES=$((CUR - BASE_BYTES))
    else
      TRAFFIC_TODAY_BYTES=0
    fi
    TRAFFIC_TODAY_VALID=true
  fi
  MONTH_SUM=0
  if [ -f "$TRAFFIC_DAILY" ]; then
    MONTH_SUM=$("$BB" awk -F'|' -v m="$THIS_MONTH" 'index($1,m)==1{s+=$2} END{print s+0}' "$TRAFFIC_DAILY" 2>/dev/null)
  fi
  case "$MONTH_SUM" in ''|*[!0-9]*) MONTH_SUM=0 ;; esac
  if [ -f "$TRAFFIC_DAILY" ] || [ "$TRAFFIC_TODAY_VALID" = "true" ]; then
    TRAFFIC_MONTH_VALID=true
  fi
  TRAFFIC_MONTH_BYTES=$((MONTH_SUM + TRAFFIC_TODAY_BYTES))
  TRAFFIC_DAYS=$("$BB" tail -n 11 "$TRAFFIC_DAILY" 2>/dev/null)
}


# ---------- Mihomo / Proxy (v1.6.0-beta.3) ----------
PROXY_DIR="$DATA_DIR/proxy"
PROXY_BIN="$MODDIR/bin/mihomo"
PROXY_CFG="$PROXY_DIR/config.yaml"
PROXY_TMP_CFG="$PROXY_DIR/config.yaml.tmp"
PROXY_PIDFILE="$PROXY_DIR/mihomo.pid"
PROXY_LOG="$PROXY_DIR/mihomo.log"
PROXY_RUNTIME_LOG="$PROXY_DIR/proxy.log"
PROXY_SECRET_FILE="$PROXY_DIR/secret"
PROXY_STATE_FILE="$PROXY_DIR/state"
PROXY_LAST_ERROR="$PROXY_DIR/last_error"
PROXY_SUB_FILE="$PROXY_DIR/sub_url.txt"
PROXY_LOCK="$PROXY_DIR/proxy.lock"
PROXY_IFACE_FILE="$PROXY_DIR/iface"
PROXY_SELF_ERROR_FILE="$PROXY_DIR/self_error"
PROXY_SELF_BYPASS_FILE="$PROXY_DIR/self_bypass"
PROXY_HEALTH_FILE="$PROXY_DIR/health.state"
PROXY_START_LOCK="$PROXY_DIR/start.lock"
PROXY_GEO_DB="$PROXY_DIR/geoip.metadb"
PROXY_REDIR_PORT=7893
PROXY_DNS_PORT=1053
PROXY_API_HOST="127.0.0.1"
PROXY_API_PORT=9090
PROXY_ROUTING_MARK=6666
PROXY_CORE_VERSION="1.19.31"
PROXY_CURL=/system/bin/curl
[ -x "$PROXY_CURL" ] || PROXY_CURL=$(command -v curl 2>/dev/null)

proxy_log() {
  proxy_init_dirs
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$PROXY_RUNTIME_LOG" 2>/dev/null
  # 512 KiB 简单轮换，避免代理日志无限增长
  local size
  size=$(wc -c < "$PROXY_RUNTIME_LOG" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt 524288 ] 2>/dev/null; then
    tail -c 262144 "$PROXY_RUNTIME_LOG" > "$PROXY_RUNTIME_LOG.tmp" 2>/dev/null && mv -f "$PROXY_RUNTIME_LOG.tmp" "$PROXY_RUNTIME_LOG"
  fi
}

proxy_init_dirs() {
  mkdir -p "$PROXY_DIR/providers" "$PROXY_DIR/cache"
  chmod 0700 "$PROXY_DIR" "$PROXY_DIR/providers" "$PROXY_DIR/cache" 2>/dev/null
  # GEOIP 数据随模块离线打包。geodata-mode=false 时 Mihomo 使用 MMDB/MetaDB。
  if [ -s "$MODDIR/bin/geoip.metadb" ]; then
    if [ ! -s "$PROXY_GEO_DB" ] || ! "$BB" cmp -s "$MODDIR/bin/geoip.metadb" "$PROXY_GEO_DB" 2>/dev/null; then
      cp -f "$MODDIR/bin/geoip.metadb" "$PROXY_GEO_DB" 2>/dev/null
      chmod 0600 "$PROXY_GEO_DB" 2>/dev/null
    fi
  fi
  # GEOSITE 数据（国内域名集合）随模块安装时下载，与运行目录保持同步。
  # 缺失时 GEOSITE,CN 规则静默失效，国内 HTTPS 会回退走代理，因此尽量保证在位。
  if [ -s "$MODDIR/bin/geosite.dat" ]; then
    if [ ! -s "$PROXY_DIR/geosite.dat" ] || ! "$BB" cmp -s "$MODDIR/bin/geosite.dat" "$PROXY_DIR/geosite.dat" 2>/dev/null; then
      cp -f "$MODDIR/bin/geosite.dat" "$PROXY_DIR/geosite.dat" 2>/dev/null
      chmod 0600 "$PROXY_DIR/geosite.dat" 2>/dev/null
    fi
  fi
}

proxy_core_ok() {
  if [ ! -f "$PROXY_BIN" ]; then echo "core_missing"; return 1; fi
  if [ ! -x "$PROXY_BIN" ]; then
    chmod 0755 "$PROXY_BIN" 2>/dev/null
    [ -x "$PROXY_BIN" ] || { echo "core_not_executable"; return 1; }
  fi
  local magic
  magic=$(od -An -tx1 -N4 "$PROXY_BIN" 2>/dev/null | tr -d ' \n')
  [ "$magic" = "7f454c46" ] || { echo "core_invalid_binary"; return 1; }
  "$PROXY_BIN" -v >/dev/null 2>&1 || { echo "core_launch_failed"; return 1; }
  return 0
}

proxy_generate_secret() {
  proxy_init_dirs
  if [ ! -s "$PROXY_SECRET_FILE" ]; then
    head -c 16 /dev/urandom | md5sum | cut -c1-16 > "$PROXY_SECRET_FILE"
    chmod 0600 "$PROXY_SECRET_FILE" 2>/dev/null
  fi
  cat "$PROXY_SECRET_FILE" 2>/dev/null
}

proxy_read_state() {
  cat "$PROXY_STATE_FILE" 2>/dev/null || echo "stopped"
}

proxy_write_state() {
  printf '%s\n' "$1" > "$PROXY_STATE_FILE"
  chmod 0600 "$PROXY_STATE_FILE" 2>/dev/null
}

proxy_set_error() {
  printf '%s\n' "$1" > "$PROXY_LAST_ERROR"
  chmod 0600 "$PROXY_LAST_ERROR" 2>/dev/null
  [ -n "$1" ] && proxy_log "error: $1"
}

proxy_clear_error() {
  : > "$PROXY_LAST_ERROR" 2>/dev/null
  chmod 0600 "$PROXY_LAST_ERROR" 2>/dev/null
}

proxy_health_write() {
  # Lightweight snapshot for status.cgi. Never make status.cgi wait on Mihomo HTTP APIs.
  local api="${1:-false}" provider="${2:-false}" count="${3:-0}"
  case "$api" in true|false) : ;; *) api=false ;; esac
  case "$provider" in true|false) : ;; *) provider=false ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  {
    printf 'api=%s\n' "$api"
    printf 'provider=%s\n' "$provider"
    printf 'count=%s\n' "$count"
    printf 'time=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  } > "$PROXY_HEALTH_FILE.tmp" 2>/dev/null && mv -f "$PROXY_HEALTH_FILE.tmp" "$PROXY_HEALTH_FILE" 2>/dev/null
  chmod 0600 "$PROXY_HEALTH_FILE" 2>/dev/null
}

proxy_health_read() {
  PROXY_HEALTH_API=false
  PROXY_HEALTH_PROVIDER=false
  PROXY_HEALTH_COUNT=0
  [ -r "$PROXY_HEALTH_FILE" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      api) case "$v" in true|false) PROXY_HEALTH_API=$v ;; esac ;;
      provider) case "$v" in true|false) PROXY_HEALTH_PROVIDER=$v ;; esac ;;
      count) case "$v" in ''|*[!0-9]*) : ;; *) PROXY_HEALTH_COUNT=$v ;; esac ;;
    esac
  done < "$PROXY_HEALTH_FILE"
}

proxy_refresh_health() {
  local count=0
  if ! proxy_is_running; then
    proxy_health_write false false 0
    return 1
  fi
  if ! proxy_api_ready; then
    proxy_health_write false false 0
    return 1
  fi
  if proxy_provider_ready; then
    count=$(proxy_provider_node_count)
    proxy_health_write true true "$count"
    return 0
  fi
  proxy_health_write true false 0
  return 1
}

proxy_is_running() {
  [ -f "$PROXY_PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PROXY_PIDFILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null || return 1
  kill -0 "$pid" 2>/dev/null
}

proxy_api_ready() {
  [ -n "$PROXY_CURL" ] && [ -x "$PROXY_CURL" ] || return 1
  local secret
  secret=$(proxy_generate_secret)
  "$PROXY_CURL" -fsS --connect-timeout 2 --max-time 3 \
    -H "Authorization: Bearer $secret" \
    "http://$PROXY_API_HOST:$PROXY_API_PORT/version" >/dev/null 2>&1
}

proxy_api() {
  local method="$1" path="$2" data="$3"
  [ -n "$PROXY_CURL" ] && [ -x "$PROXY_CURL" ] || return 1
  local secret
  secret=$(proxy_generate_secret)
  if [ -n "$data" ]; then
    "$PROXY_CURL" -fsS --connect-timeout 2 --max-time 5 -X "$method" \
      -H "Authorization: Bearer $secret" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "http://$PROXY_API_HOST:$PROXY_API_PORT$path" 2>/dev/null
  else
    "$PROXY_CURL" -fsS --connect-timeout 2 --max-time 5 -X "$method" \
      -H "Authorization: Bearer $secret" \
      "http://$PROXY_API_HOST:$PROXY_API_PORT$path" 2>/dev/null
  fi
}

proxy_valid_sub_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

proxy_yaml_escape() {
  # 订阅地址只放入双引号 YAML 标量；转义反斜杠和双引号。
  printf '%s' "$1" | "$BB" sed 's/\\/\\\\/g; s/"/\\"/g'
}

proxy_generate_config() {
  proxy_init_dirs
  local sub_url sub_yaml secret
  sub_url=$(cat "$PROXY_SUB_FILE" 2>/dev/null)
  proxy_valid_sub_url "$sub_url" || return 1
  sub_yaml=$(proxy_yaml_escape "$sub_url")
  secret=$(proxy_generate_secret)

  # Keep the first production config deliberately conservative.  The beta.4
  # template contained several optional DNS/GEO knobs at the same time, which
  # made it hard to distinguish a real subscription problem from a Mihomo
  # config-parser failure.  This template only uses fields documented by
  # current Mihomo and keeps CN direct + overseas proxy routing.
  cat > "$PROXY_TMP_CFG" <<EOF
mixed-port: 7890
redir-port: $PROXY_REDIR_PORT
allow-lan: true
bind-address: "*"
mode: ${PROXY_ROUTE_MODE:-rule}
log-level: info
ipv6: false
external-controller: $PROXY_API_HOST:$PROXY_API_PORT
secret: "$secret"
profile:
  store-selected: true

# Android 本机 DNS/网络栈可能不会让所有域名查询经过 OUTPUT:53。
# 启用 SNI/HTTP 嗅探，可在 redir-host 下补回域名并覆盖被污染的目标地址。
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
      override-destination: true

dns:
  enable: true
  listen: 0.0.0.0:$PROXY_DNS_PORT
  ipv6: false
  enhanced-mode: redir-host
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29

proxy-providers:
  airport:
    type: http
    url: "$sub_yaml"
    path: ./providers/airport.yaml
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 120
      timeout: 5000
      lazy: false

proxy-groups:
  - name: AUTO
    type: url-test
    use:
      - airport
    tolerance: 80
  - name: FALLBACK
    type: fallback
    use:
      - airport
  - name: MANUAL
    type: select
    use:
      - airport
  - name: GLOBAL
    type: select
    proxies:
      - AUTO
      - FALLBACK
      - MANUAL
      - DIRECT

rules:
  - DOMAIN,services.googleapis.cn,GLOBAL
  - DOMAIN-SUFFIX,googleapis.com,GLOBAL
  - DOMAIN-SUFFIX,googleapis.cn,GLOBAL
  - DOMAIN-SUFFIX,google.com,GLOBAL
  - DOMAIN-SUFFIX,gstatic.com,GLOBAL
  - DOMAIN-SUFFIX,googleusercontent.com,GLOBAL
  - DOMAIN-SUFFIX,ggpht.com,GLOBAL
  - DOMAIN-SUFFIX,gvt1.com,GLOBAL
  - DOMAIN-SUFFIX,gvt2.com,GLOBAL
  - DOMAIN-SUFFIX,android.com,GLOBAL
  - DOMAIN-SUFFIX,googleplay.com,GLOBAL
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,GLOBAL
  - DOMAIN-SUFFIX,googlevideo.com,GLOBAL
  # GEOSITE,CN 按域名判定国内直连，补上 GEOIP,no-resolve 对"已嗅探 SNI 的连接"
  # 无法用 IP 判定的盲区（否则国内 HTTPS 会全部落入 MATCH,GLOBAL 走代理）。
  # 分类名必须大写 CN（geosite 分类大小写敏感），geosite.dat 由 customize.sh 安装。
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,GLOBAL
EOF
  chmod 0600 "$PROXY_TMP_CFG" 2>/dev/null
}

proxy_validation_detail() {
  # Extract one useful Mihomo error line for diagnostics, but never leak the
  # subscription URL or controller secret to the UI/log summary.
  local line
  line=$("$BB" grep -E 'level=(error|fatal)|Parse config error|configuration file .* test failed|yaml:' "$PROXY_LOG" 2>/dev/null | "$BB" tail -n 1)
  [ -n "$line" ] || line=$("$BB" tail -n 1 "$PROXY_LOG" 2>/dev/null)
  # Redact common URL/token shapes and keep the status JSON small.
  line=$(printf '%s' "$line" | "$BB" sed -E 's#https?://[^ ]+#<url>#g; s/secret[=:][^ ,]+/secret=<redacted>/g; s/token[=:][^ ,]+/token=<redacted>/g' | "$BB" head -c 240)
  printf '%s' "$line"
}

proxy_validate_config() {
  proxy_init_dirs
  proxy_generate_config || return 1
  # Keep a clean validation log for this attempt so the UI can show the actual
  # parser error instead of the generic "config validation failed" message.
  : > "$PROXY_LOG" 2>/dev/null
  chmod 0600 "$PROXY_LOG" 2>/dev/null
  "$PROXY_BIN" -t -d "$PROXY_DIR" -f "$PROXY_TMP_CFG" >> "$PROXY_LOG" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local detail
    detail=$(proxy_validation_detail)
    [ -n "$detail" ] && printf '%s\n' "$detail" > "$PROXY_DIR/config_error_detail" 2>/dev/null
    return "$rc"
  fi
  rm -f "$PROXY_DIR/config_error_detail" 2>/dev/null
  return 0
}

proxy_provider_json() {
  proxy_api GET "/providers/proxies/airport" ""
}

proxy_provider_ready() {
  local data
  data=$(proxy_provider_json 2>/dev/null) || return 1
  [ -n "$data" ] || return 1
  printf '%s' "$data" | "$BB" grep -Eq '"proxies"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' 2>/dev/null
}

proxy_provider_node_count() {
  local data count
  data=$(proxy_provider_json 2>/dev/null) || { printf '0'; return; }
  # Provider 返回中每个节点对象都有 name 字段；这里只用于诊断/状态，不参与代理决策。
  count=$(printf '%s' "$data" | "$BB" grep -o '"provider-name"[[:space:]]*:[[:space:]]*"airport"' 2>/dev/null | "$BB" wc -l | "$BB" tr -d ' ')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  # 个别版本的 provider JSON 不带 provider-name；此时仅用于状态显示，至少标记为 1。
  [ "$count" -eq 0 ] 2>/dev/null && proxy_provider_ready && count=1
  printf '%s' "$count"
}

proxy_setup_iptables() {
  local iface="$1"
  [ -n "$iface" ] || return 1
  case "$iface" in wlan[1-9]*|ap[0-9]*|softap*) : ;; *) proxy_log "refuse unexpected hotspot iface: $iface"; return 1 ;; esac

  # 仅重建热点客户端链；手机本机代理链独立管理，避免热点接口变化时把本机代理一起拆掉。
  proxy_teardown_hotspot_iptables >/dev/null 2>&1

  $IPT -t nat -N MIFI_PROXY 2>/dev/null || true
  $IPT -t nat -F MIFI_PROXY 2>/dev/null || return 1
  # DNS 必须先劫持，再 RETURN 私网；否则 192.168.x.x 网关 DNS 会被提前放行。
  $IPT -t nat -A MIFI_PROXY -p udp --dport 53 -j REDIRECT --to-ports $PROXY_DNS_PORT || return 1
  $IPT -t nat -A MIFI_PROXY -p tcp --dport 53 -j REDIRECT --to-ports $PROXY_DNS_PORT || return 1
  $IPT -t nat -A MIFI_PROXY -d 127.0.0.0/8 -j RETURN || return 1
  $IPT -t nat -A MIFI_PROXY -d 10.0.0.0/8 -j RETURN || return 1
  $IPT -t nat -A MIFI_PROXY -d 172.16.0.0/12 -j RETURN || return 1
  $IPT -t nat -A MIFI_PROXY -d 192.168.0.0/16 -j RETURN || return 1
  $IPT -t nat -A MIFI_PROXY -d 224.0.0.0/4 -j RETURN || return 1
  $IPT -t nat -A MIFI_PROXY -p tcp -j REDIRECT --to-ports $PROXY_REDIR_PORT || return 1
  $IPT -t nat -A PREROUTING -i "$iface" -j MIFI_PROXY || { proxy_teardown_hotspot_iptables; return 1; }

  if [ "${PROXY_BLOCK_QUIC:-1}" = "1" ]; then
    $IPT -t filter -N MIFI_BLOCK_QUIC 2>/dev/null || true
    $IPT -t filter -F MIFI_BLOCK_QUIC 2>/dev/null || { proxy_teardown_hotspot_iptables; return 1; }
    $IPT -t filter -A MIFI_BLOCK_QUIC -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable || { proxy_teardown_hotspot_iptables; return 1; }
    $IPT -t filter -A FORWARD -i "$iface" -j MIFI_BLOCK_QUIC || { proxy_teardown_hotspot_iptables; return 1; }
  fi

  printf '%s\n' "$iface" > "$PROXY_IFACE_FILE"
  chmod 0600 "$PROXY_IFACE_FILE" 2>/dev/null
  proxy_log "hotspot iptables enabled iface=$iface mode=redirect"
  return 0
}

proxy_teardown_hotspot_iptables() {
  local saved current iface
  saved=$(cat "$PROXY_IFACE_FILE" 2>/dev/null | tr -d ' \r\n')
  current=$(get_hotspot_iface 2>/dev/null)
  # 兼容旧版无 -i 的全局挂载。
  while $IPT -t nat -C PREROUTING -j MIFI_PROXY 2>/dev/null; do
    $IPT -t nat -D PREROUTING -j MIFI_PROXY 2>/dev/null || break
  done
  while $IPT -t filter -C FORWARD -j MIFI_BLOCK_QUIC 2>/dev/null; do
    $IPT -t filter -D FORWARD -j MIFI_BLOCK_QUIC 2>/dev/null || break
  done
  for iface in $saved $current wlan2 wlan3 wlan4; do
    [ -n "$iface" ] || continue
    while $IPT -t nat -C PREROUTING -i "$iface" -j MIFI_PROXY 2>/dev/null; do
      $IPT -t nat -D PREROUTING -i "$iface" -j MIFI_PROXY 2>/dev/null || break
    done
    while $IPT -t filter -C FORWARD -i "$iface" -j MIFI_BLOCK_QUIC 2>/dev/null; do
      $IPT -t filter -D FORWARD -i "$iface" -j MIFI_BLOCK_QUIC 2>/dev/null || break
    done
  done
  $IPT -t nat -F MIFI_PROXY 2>/dev/null || true
  $IPT -t nat -X MIFI_PROXY 2>/dev/null || true
  $IPT -t filter -F MIFI_BLOCK_QUIC 2>/dev/null || true
  $IPT -t filter -X MIFI_BLOCK_QUIC 2>/dev/null || true
  rm -f "$PROXY_IFACE_FILE" 2>/dev/null
}

proxy_self_set_error() {
  printf '%s\n' "$1" > "$PROXY_SELF_ERROR_FILE" 2>/dev/null
  chmod 0600 "$PROXY_SELF_ERROR_FILE" 2>/dev/null
  [ -n "$1" ] && proxy_log "self proxy error: $1"
}

proxy_self_clear_error() {
  rm -f "$PROXY_SELF_ERROR_FILE" 2>/dev/null
}

proxy_teardown_self_iptables() {
  # 本机 TCP/DNS 透明代理链。
  while $IPT -t nat -C OUTPUT -j MIFI_PROXY_SELF 2>/dev/null; do
    $IPT -t nat -D OUTPUT -j MIFI_PROXY_SELF 2>/dev/null || break
  done
  $IPT -t nat -F MIFI_PROXY_SELF 2>/dev/null || true
  $IPT -t nat -X MIFI_PROXY_SELF 2>/dev/null || true

  # REDIRECT 只处理 TCP；本机 UDP/443 主动拒绝，让浏览器/视频应用回落到 TCP/HTTPS。
  while $IPT -t filter -C OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null; do
    $IPT -t filter -D OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null || break
  done
  $IPT -t filter -F MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
  $IPT -t filter -X MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
  rm -f "$PROXY_SELF_BYPASS_FILE" 2>/dev/null
}

proxy_self_nat_ok() {
  # 只检查本机透明代理真正必需的 NAT 规则。QUIC 阻断属于可选增强，
  # 不应因为 filter/REJECT 在某些 Android 内核上不可用，就把整个本机代理判成“未生效”。
  local bypass rules output_rules
  output_rules=$($IPT -t nat -S OUTPUT 2>/dev/null)
  rules=$($IPT -t nat -S MIFI_PROXY_SELF 2>/dev/null) || return 1

  # 优先使用 -C；部分 Android iptables wrapper 对 -C 返回不稳定时，再退回 -S 文本检测。
  if ! $IPT -t nat -C OUTPUT -j MIFI_PROXY_SELF 2>/dev/null; then
    printf '%s\n' "$output_rules" | "$BB" grep -q -- '-j MIFI_PROXY_SELF' || return 1
  fi

  if ! $IPT -t nat -C MIFI_PROXY_SELF -p tcp -j REDIRECT --to-ports $PROXY_REDIR_PORT 2>/dev/null; then
    printf '%s\n' "$rules" | "$BB" grep -Eq -- "-j REDIRECT .*--to-ports $PROXY_REDIR_PORT|-j REDIRECT .*--to-port $PROXY_REDIR_PORT" || return 1
  fi

  bypass=$(cat "$PROXY_SELF_BYPASS_FILE" 2>/dev/null | tr -d ' \r\n')
  case "$bypass" in
    mark)
      if ! $IPT -t nat -C MIFI_PROXY_SELF -m mark --mark $PROXY_ROUTING_MARK -j RETURN 2>/dev/null; then
        printf '%s\n' "$rules" | "$BB" grep -Eq -- "-m mark .*--mark (0x[0-9a-fA-F]+|$PROXY_ROUTING_MARK).* -j RETURN" || return 1
      fi
      ;;
    uid0)
      if ! $IPT -t nat -C MIFI_PROXY_SELF -m owner --uid-owner 0 -j RETURN 2>/dev/null; then
        printf '%s\n' "$rules" | "$BB" grep -Eq -- '-m owner .*--uid-owner (0|0-0).* -j RETURN' || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

proxy_self_quic_ok() {
  [ "${PROXY_BLOCK_QUIC:-1}" = "1" ] || return 0
  local out rules
  out=$($IPT -t filter -S OUTPUT 2>/dev/null)
  rules=$($IPT -t filter -S MIFI_SELF_BLOCK_QUIC 2>/dev/null) || return 1
  if ! $IPT -t filter -C OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null; then
    printf '%s\n' "$out" | "$BB" grep -q -- '-j MIFI_SELF_BLOCK_QUIC' || return 1
  fi
  printf '%s\n' "$rules" | "$BB" grep -q -- '--dport 443' || return 1
  return 0
}

# 向后兼容旧调用点：本机代理“是否生效”只由必要 NAT 规则决定。
proxy_self_iptables_ok() {
  proxy_self_nat_ok
}

proxy_setup_self_quic() {
  [ "${PROXY_BLOCK_QUIC:-1}" = "1" ] || return 0
  local bypass
  bypass=$(cat "$PROXY_SELF_BYPASS_FILE" 2>/dev/null | tr -d ' \r\n')

  # QUIC 规则是增强项：失败时保留已经工作的 TCP/DNS 本机代理。
  while $IPT -t filter -C OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null; do
    $IPT -t filter -D OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null || break
  done
  $IPT -t filter -F MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
  $IPT -t filter -X MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
  $IPT -t filter -N MIFI_SELF_BLOCK_QUIC 2>/dev/null || true
  $IPT -t filter -F MIFI_SELF_BLOCK_QUIC 2>/dev/null || return 1

  case "$bypass" in
    mark) $IPT -t filter -A MIFI_SELF_BLOCK_QUIC -m mark --mark $PROXY_ROUTING_MARK -j RETURN 2>/dev/null || return 1 ;;
    uid0) $IPT -t filter -A MIFI_SELF_BLOCK_QUIC -m owner --uid-owner 0 -j RETURN 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac

  $IPT -t filter -A MIFI_SELF_BLOCK_QUIC -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || return 1
  $IPT -t filter -A OUTPUT -j MIFI_SELF_BLOCK_QUIC 2>/dev/null || return 1
  return 0
}

proxy_setup_self_iptables() {
  proxy_teardown_self_iptables >/dev/null 2>&1

  $IPT -t nat -N MIFI_PROXY_SELF 2>/dev/null || true
  $IPT -t nat -F MIFI_PROXY_SELF 2>/dev/null || { proxy_self_set_error "self_nat_chain_failed"; proxy_teardown_self_iptables; return 1; }

  # Mihomo 由 KernelSU service 以 root 启动。Android 的 netd 会大量使用 fwmark 选择
  # 实际蜂窝/Wi-Fi 路由；给 Mihomo 全局设置自定义 routing-mark 可能与 netd 的 fwmark
  # 语义冲突，表现为本机规则“已生效”但 Mihomo 出站无法真正联网。
  # 因此 v1.6.0-beta.3 固定使用 uid 0 绕过，避免核心流量再次被 OUTPUT REDIRECT。
  # 代价是其它 root 进程也保持直连；普通 App UID 仍正常进入 Mihomo。
  SELF_BYPASS=
  if $IPT -t nat -A MIFI_PROXY_SELF -m owner --uid-owner 0 -j RETURN 2>/dev/null; then
    SELF_BYPASS=uid0
  else
    proxy_self_set_error "self_bypass_unavailable"
    proxy_teardown_self_iptables
    return 1
  fi
  printf '%s\n' "$SELF_BYPASS" > "$PROXY_SELF_BYPASS_FILE" 2>/dev/null
  chmod 0600 "$PROXY_SELF_BYPASS_FILE" 2>/dev/null

  # 本地回环永远直连；DNS 在其它私网 RETURN 前处理，确保局域网 DNS 请求仍可进入 Mihomo。
  $IPT -t nat -A MIFI_PROXY_SELF -d 127.0.0.0/8 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -p udp --dport 53 -j REDIRECT --to-ports $PROXY_DNS_PORT 2>/dev/null || { proxy_self_set_error "self_dns_udp_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -p tcp --dport 53 -j REDIRECT --to-ports $PROXY_DNS_PORT 2>/dev/null || { proxy_self_set_error "self_dns_tcp_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -d 10.0.0.0/8 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -d 172.16.0.0/12 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -d 192.168.0.0/16 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -d 169.254.0.0/16 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -d 224.0.0.0/4 -j RETURN 2>/dev/null || { proxy_self_set_error "self_nat_rule_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A MIFI_PROXY_SELF -p tcp -j REDIRECT --to-ports $PROXY_REDIR_PORT 2>/dev/null || { proxy_self_set_error "self_tcp_redirect_failed"; proxy_teardown_self_iptables; return 1; }
  $IPT -t nat -A OUTPUT -j MIFI_PROXY_SELF 2>/dev/null || { proxy_self_set_error "self_output_hook_failed"; proxy_teardown_self_iptables; return 1; }

  # 建完后立即做一次独立校验。避免 iptables 命令返回 0、实际规则却被 wrapper/系统拒绝的假成功。
  if ! proxy_self_nat_ok; then
    proxy_self_set_error "self_nat_verify_failed"
    proxy_teardown_self_iptables
    return 1
  fi

  # QUIC 阻断只用于促使浏览器回退到 TCP。某些 Android 内核的 filter/REJECT 能力受限，
  # 这种情况下本机 TCP/DNS 代理仍然有效，所以只记 warning，不再拆掉 NAT 链。
  if [ "${PROXY_BLOCK_QUIC:-1}" = "1" ]; then
    if ! proxy_setup_self_quic; then
      proxy_log "self proxy warning: QUIC block unavailable; TCP/DNS proxy remains active"
    fi
  fi

  proxy_self_clear_error
  proxy_log "self proxy iptables enabled mode=redirect bypass=$SELF_BYPASS quic=$(proxy_self_quic_ok && echo on || echo off)"
  return 0
}

proxy_sync_self_iptables() {
  if [ "${PROXY_SELF:-0}" != "1" ]; then
    proxy_teardown_self_iptables
    proxy_self_clear_error
    return 0
  fi
  if proxy_self_iptables_ok; then
    proxy_self_clear_error
    return 0
  fi
  proxy_setup_self_iptables
}

proxy_teardown_iptables() {
  proxy_teardown_hotspot_iptables
  proxy_teardown_self_iptables
}

proxy_iptables_ok() {
  local iface="$1"
  [ -n "$iface" ] || return 1
  $IPT -t nat -C PREROUTING -i "$iface" -j MIFI_PROXY 2>/dev/null || return 1
  $IPT -t nat -C MIFI_PROXY -p tcp -j REDIRECT --to-ports $PROXY_REDIR_PORT 2>/dev/null || return 1
  return 0
}

proxy_sync_iptables() {
  local iface
  iface=$(get_hotspot_iface 2>/dev/null)
  if [ -z "$iface" ]; then
    proxy_teardown_hotspot_iptables
    return 0
  fi
  if proxy_iptables_ok "$iface"; then
    printf '%s\n' "$iface" > "$PROXY_IFACE_FILE" 2>/dev/null
    return 0
  fi
  proxy_setup_iptables "$iface"
}

proxy_start() {
  proxy_init_dirs
  proxy_clear_error
  proxy_health_write false false 0
  proxy_write_state "starting"

  local core_check sub_url iface i
  core_check=$(proxy_core_ok)
  if [ $? -ne 0 ]; then
    proxy_set_error "$core_check"
    proxy_write_state "$core_check"
    proxy_teardown_iptables
    return 1
  fi

  # 配置文件是唯一持久来源；每次启动都用最新 PROXY_SUB_B64 覆盖旧 runtime URL。
  sub_url=""
  if [ -n "${PROXY_SUB_B64:-}" ]; then
    sub_url=$(b64url_decode "$PROXY_SUB_B64" 2>/dev/null)
  fi
  [ -n "$sub_url" ] || sub_url=$(cat "$PROXY_SUB_FILE" 2>/dev/null)
  if ! proxy_valid_sub_url "$sub_url"; then
    proxy_set_error "subscription_missing_or_invalid"
    proxy_write_state "subscription_error"
    proxy_teardown_iptables
    return 1
  fi
  printf '%s\n' "$sub_url" > "$PROXY_SUB_FILE"
  chmod 0600 "$PROXY_SUB_FILE" 2>/dev/null

  if ! proxy_validate_config; then
    proxy_set_error "config_validation_failed"
    proxy_write_state "config_error"
    rm -f "$PROXY_TMP_CFG"
    proxy_teardown_iptables
    return 1
  fi
  mv -f "$PROXY_TMP_CFG" "$PROXY_CFG" || {
    proxy_set_error "config_write_failed"
    proxy_write_state "config_error"
    proxy_teardown_iptables
    return 1
  }
  chmod 0600 "$PROXY_CFG" 2>/dev/null

  # 重启核心前先撤透明代理，确保任何失败都 fail-open，不把热点锁死。
  proxy_teardown_iptables
  if proxy_is_running; then
    local pid
    pid=$(cat "$PROXY_PIDFILE" 2>/dev/null)
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PROXY_PIDFILE"
  : > "$PROXY_LOG" 2>/dev/null
  chmod 0600 "$PROXY_LOG" 2>/dev/null
  nohup "$PROXY_BIN" -d "$PROXY_DIR" -f "$PROXY_CFG" >> "$PROXY_LOG" 2>&1 &
  echo $! > "$PROXY_PIDFILE"
  chmod 0600 "$PROXY_PIDFILE" 2>/dev/null

  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    proxy_api_ready && break
    proxy_is_running || break
  done
  if ! proxy_api_ready; then
    proxy_health_write false false 0
    proxy_set_error "mihomo_api_not_ready"
    proxy_write_state "core_error"
    proxy_teardown_iptables
    return 1
  fi

  # Provider 是这版最关键的健康门槛：必须真实加载到节点，才允许挂透明代理。
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    proxy_provider_ready && break
    sleep 1
  done
  if ! proxy_provider_ready; then
    proxy_health_write true false 0
    proxy_set_error "subscription_loaded_no_nodes"
    proxy_write_state "subscription_error"
    proxy_teardown_iptables
    return 1
  fi

  proxy_health_write true true "$(proxy_provider_node_count)"

  proxy_set_mode "${PROXY_MODE:-auto}" >/dev/null 2>&1 || {
    proxy_set_error "proxy_group_switch_failed"
    proxy_write_state "subscription_error"
    proxy_teardown_iptables
    return 1
  }

  # 手机本机代理与热点客户端代理完全独立。本机开关开启时先建立 OUTPUT 链；
  # 失败只影响本机代理，不破坏已经可用的热点客户端代理。
  if [ "${PROXY_SELF:-0}" = "1" ]; then
    if ! proxy_setup_self_iptables; then
      [ -s "$PROXY_SELF_ERROR_FILE" ] || proxy_self_set_error "self_iptables_setup_failed"
      proxy_log "self proxy requested but setup failed"
    fi
  else
    proxy_teardown_self_iptables
    proxy_self_clear_error
  fi

  iface=$(get_hotspot_iface 2>/dev/null)
  if [ -z "$iface" ]; then
    proxy_clear_error
    if [ "${PROXY_SELF:-0}" = "1" ] && proxy_self_iptables_ok; then
      proxy_write_state "running"
      proxy_log "mihomo ready; self proxy active; waiting hotspot"
    else
      proxy_write_state "waiting_hotspot"
      proxy_log "mihomo ready; waiting hotspot"
    fi
    return 0
  fi
  if [ "${PROXY_SCOPE:-hotspot}" = "self" ]; then
    proxy_teardown_hotspot_iptables
    if [ "${PROXY_SELF:-0}" = "1" ] && proxy_self_iptables_ok; then
      proxy_clear_error
      proxy_write_state "running"
      proxy_log "proxy started for self only mode=${PROXY_MODE:-auto} nodes=$(proxy_provider_node_count)"
      return 0
    fi
    proxy_set_error "self_iptables_setup_failed"
    proxy_write_state "firewall_error"
    return 1
  fi
  if ! proxy_setup_iptables "$iface"; then
    proxy_set_error "iptables_setup_failed"
    proxy_write_state "firewall_error"
    proxy_teardown_hotspot_iptables
    return 1
  fi
  proxy_clear_error
  proxy_write_state "running"
  proxy_log "proxy started iface=$iface mode=${PROXY_MODE:-auto} nodes=$(proxy_provider_node_count)"
  return 0
}

proxy_start_async() {
  proxy_init_dirs
  # Avoid stacking several long startup attempts from repeated taps / supervisor races.
  if ! mkdir "$PROXY_START_LOCK" 2>/dev/null; then
    local oldpid
    oldpid=$(cat "$PROXY_START_LOCK/pid" 2>/dev/null)
    case "$oldpid" in ''|*[!0-9]*) oldpid=0 ;; esac
    if [ "$oldpid" -gt 1 ] 2>/dev/null && kill -0 "$oldpid" 2>/dev/null; then
      proxy_write_state "starting"
      return 0
    fi
    rm -rf "$PROXY_START_LOCK" 2>/dev/null
    mkdir "$PROXY_START_LOCK" 2>/dev/null || return 1
  fi
  proxy_clear_error
  proxy_health_write false false 0
  proxy_write_state "starting"
  (
    # control.cgi holds a config EXIT trap; do not inherit it into this detached worker.
    trap - EXIT HUP INT TERM
    # Let BusyBox httpd flush the CGI JSON response before any network rules change.
    sleep 1
    proxy_start
    rc=$?
    rm -rf "$PROXY_START_LOCK" 2>/dev/null
    exit $rc
  ) >> "$PROXY_RUNTIME_LOG" 2>&1 </dev/null &
  printf '%s\n' "$!" > "$PROXY_START_LOCK/pid" 2>/dev/null
  chmod 0600 "$PROXY_START_LOCK/pid" 2>/dev/null
  return 0
}

proxy_stop() {
  # Cancel a detached startup job first; otherwise a user can press Stop while
  # startup is still validating/downloading and the worker would re-enable rules later.
  if [ -d "$PROXY_START_LOCK" ]; then
    local spid
    spid=$(cat "$PROXY_START_LOCK/pid" 2>/dev/null)
    case "$spid" in ''|*[!0-9]*) spid=0 ;; esac
    if [ "$spid" -gt 1 ] 2>/dev/null && [ "$spid" != "$$" ]; then
      kill "$spid" 2>/dev/null || true
    fi
    rm -rf "$PROXY_START_LOCK" 2>/dev/null
  fi
  proxy_teardown_iptables
  if proxy_is_running; then
    local pid
    pid=$(cat "$PROXY_PIDFILE" 2>/dev/null)
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PROXY_PIDFILE"
  proxy_clear_error
  proxy_health_write false false 0
  proxy_write_state "stopped"
  proxy_log "proxy stopped"
}

proxy_update_provider() {
  proxy_api PUT "/providers/proxies/airport" "" >/dev/null || return 1
  # 更新后确认仍有节点；失败时 Mihomo 会继续保留既有 provider 缓存。
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    proxy_provider_ready && return 0
    sleep 1
  done
  return 1
}

proxy_healthcheck() {
  proxy_api GET "/providers/proxies/airport/healthcheck" "" >/dev/null
}

proxy_group_delay() {
  [ -n "$PROXY_CURL" ] && [ -x "$PROXY_CURL" ] || return 1
  local secret
  secret=$(proxy_generate_secret)
  "$PROXY_CURL" -fsS --connect-timeout 2 --max-time 15 \
    -H "Authorization: Bearer $secret" \
    "http://$PROXY_API_HOST:$PROXY_API_PORT/group/MANUAL/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=8000" 2>/dev/null
}

proxy_set_mode() {
  local mode="$1" payload
  case "$mode" in
    auto) payload='{"name":"AUTO"}' ;;
    fallback) payload='{"name":"FALLBACK"}' ;;
    manual) payload='{"name":"MANUAL"}' ;;
    *) return 1 ;;
  esac
  proxy_api PUT "/proxies/GLOBAL" "$payload" >/dev/null
}

proxy_set_node() {
  local node="$1" escaped
  [ -n "$node" ] || return 1
  # 拒绝控制字符/异常超长节点名，再做 JSON 转义。
  [ "${#node}" -le 256 ] || return 1
  printf '%s' "$node" | "$BB" grep -q '[[:cntrl:]]' && return 1
  escaped=$(json_escape "$node")
  proxy_api PUT "/proxies/MANUAL" "{\"name\":\"$escaped\"}" >/dev/null || return 1
  proxy_api PUT "/proxies/GLOBAL" '{"name":"MANUAL"}' >/dev/null || return 1
  return 0
}

proxy_status_json() {
  # Keep the main status endpoint fast. Live controller/provider checks belong to
  # proxy.cgi and the 30s supervisor, not the 5s global UI poll.
  local state running iface has_sub last_error error_detail self_error self_bypass transparent="redirect" api_ready=false provider_ready=false node_count=0 self_active=false self_quic=false
  state=$(proxy_read_state)
  running=$(proxy_is_running && echo true || echo false)
  # v1.7.2-beta.1：接受调用方已算好的 iface，避免 status.cgi 内重复 ip addr
  iface=${1:-$(get_hotspot_iface 2>/dev/null)}
  [ -n "$iface" ] || iface=""
  has_sub=$( { [ -s "$PROXY_SUB_FILE" ] || [ -n "${PROXY_SUB_B64:-}" ]; } && echo true || echo false)
  last_error=$(cat "$PROXY_LAST_ERROR" 2>/dev/null)
  error_detail=$(cat "$PROXY_DIR/config_error_detail" 2>/dev/null | "$BB" head -c 240)
  proxy_health_read
  if [ "$running" = "true" ]; then
    api_ready=$PROXY_HEALTH_API
    provider_ready=$PROXY_HEALTH_PROVIDER
    node_count=$PROXY_HEALTH_COUNT
    if [ "${PROXY_SELF:-0}" = "1" ] && proxy_self_nat_ok; then
      self_active=true
      proxy_self_quic_ok && self_quic=true
    fi
  fi
  self_error=$(cat "$PROXY_SELF_ERROR_FILE" 2>/dev/null | "$BB" head -c 120)
  self_bypass=$(cat "$PROXY_SELF_BYPASS_FILE" 2>/dev/null | "$BB" head -c 16)
  printf '{"enabled":%s,"running":%s,"state":"%s","mode":"%s","routeMode":"%s","scope":"%s","transparentMode":"%s","coreVersion":"%s","interface":"%s","hasSubscription":%s,"apiReady":%s,"providerLoaded":%s,"providerNodeCount":%s,"selfProxy":%s,"selfProxyActive":%s,"selfProxyQuic":%s,"selfProxyBypass":"%s","selfProxyError":"%s","lastError":"%s","errorDetail":"%s"}' \
    "$([ "${PROXY_ENABLE:-0}" = "1" ] && echo true || echo false)" \
    "$running" "$(json_escape "$state")" "$(json_escape "${PROXY_MODE:-auto}")" "$(json_escape "${PROXY_ROUTE_MODE:-rule}")" "$(json_escape "${PROXY_SCOPE:-hotspot}")" "$transparent" "$PROXY_CORE_VERSION" \
    "$(json_escape "$iface")" "$has_sub" "$api_ready" "$provider_ready" "$node_count" \
    "$([ "${PROXY_SELF:-0}" = "1" ] && echo true || echo false)" "$self_active" "$self_quic" "$(json_escape "$self_bypass")" "$(json_escape "$self_error")" \
    "$(json_escape "$last_error")" "$(json_escape "$error_detail")"
}



ensure_management_loopback() {
  "$BB" ip link set lo up 2>/dev/null
  if "$BB" ip -4 addr show dev lo 2>/dev/null | "$BB" grep -q "inet $STABLE_IP/"; then
    return 0
  fi
  "$BB" ip addr add "$STABLE_IP/32" dev lo 2>/dev/null
  if "$BB" ip -4 addr show dev lo 2>/dev/null | "$BB" grep -q "inet $STABLE_IP/"; then
    echo "$(date) management IP attached to loopback: $STABLE_IP" >> "$LOG"
    return 0
  fi
  echo "$(date) management IP loopback attach failed: $STABLE_IP" >> "$LOG"
  return 1
}

remove_management_loopback() {
  "$BB" ip addr del "$STABLE_IP/32" dev lo 2>/dev/null || true
}

switch_management_to_hotspot() {
  HOTSPOT_IFACE=$1
  [ -n "$HOTSPOT_IFACE" ] || return 1
  # 已经在热点接口上就不动
  if "$BB" ip -4 addr show dev "$HOTSPOT_IFACE" 2>/dev/null | "$BB" grep -q "inet $STABLE_IP/"; then
    return 0
  fi
  remove_management_loopback
  add_management_alias "$HOTSPOT_IFACE"
  if "$BB" ip -4 addr show dev "$HOTSPOT_IFACE" 2>/dev/null | "$BB" grep -q "inet $STABLE_IP/"; then
    echo "$(date) management IP attached to hotspot: $HOTSPOT_IFACE" >> "$LOG"
    return 0
  fi
  ensure_management_loopback
  echo "$(date) management IP hotspot attach failed, restored loopback" >> "$LOG"
  return 1
}

wait_softap_stopped() {
  WAIT_COUNT=0
  while [ "$WAIT_COUNT" -lt 12 ]; do
    rm -f "$SOFTAP_CACHE" 2>/dev/null
    CHECK_IFACE=$(get_hotspot_iface)
    if [ -z "$CHECK_IFACE" ]; then
      return 0
    fi
    if ! softap_state_ok "$CHECK_IFACE"; then
      return 0
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    sleep 1
  done
  return 1
}

stop_hotspot_real() {
  BEFORE_IFACE=$(get_hotspot_iface)
  rm -f "$SOFTAP_CACHE" 2>/dev/null
  echo "$(date) hotspot stop: trying connectivity tether stop (system tethering path)" >> "$LOG"
  TETHER_OUT=$( "$BB" timeout 10 "$CMD_WIFI" connectivity tether stop 2>&1 )
  TETHER_RC=$?
  printf '%s tether stop rc=%s\n%s\n' "$(date)" "$TETHER_RC" "$TETHER_OUT" >> "$LOG"
  # v1.7.9：此 ROM（HyperOS/Android 16）无 connectivity tether 子命令（rc=255/Unknown command），
  # 热点实际不会被系统停掉——立即走 wifi stop-softap，避免空等 12 次快照（每次 dumpsys 数秒）。
  if [ "$TETHER_RC" != "255" ]; then
    if wait_softap_stopped; then
      remove_management_alias "$BEFORE_IFACE" 2>/dev/null
      clear_blacklist "$BEFORE_IFACE" 2>/dev/null
      ensure_management_loopback
      cleanup_hotspot_dhcp "$BEFORE_IFACE" 2>/dev/null
      : > "$HOTSPOT_IFACE_FILE" 2>/dev/null
      echo "$(date) hotspot stop: stopped by connectivity service" >> "$LOG"
      return 0
    fi
  else
    echo "$(date) hotspot stop: connectivity tether subcommand unavailable, skip wait" >> "$LOG"
  fi
  rm -f "$SOFTAP_CACHE" 2>/dev/null
  echo "$(date) hotspot stop: tether stop ineffective, trying wifi stop-softap" >> "$LOG"
  WIFI_OUT=$( "$BB" timeout 10 "$CMD_WIFI" wifi stop-softap 2>&1 )
  WIFI_RC=$?
  printf '%s wifi stop-softap rc=%s\n%s\n' "$(date)" "$WIFI_RC" "$WIFI_OUT" >> "$LOG"
  if wait_softap_stopped; then
    remove_management_alias "$BEFORE_IFACE" 2>/dev/null
    clear_blacklist "$BEFORE_IFACE" 2>/dev/null
    ensure_management_loopback
    cleanup_hotspot_dhcp "$BEFORE_IFACE" 2>/dev/null
    : > "$HOTSPOT_IFACE_FILE" 2>/dev/null
    echo "$(date) hotspot stop: stopped by wifi service" >> "$LOG"
    return 0
  fi
  echo "$(date) hotspot stop failed: hotspot still active" >> "$LOG"
  return 1
}
# Hotspot Compatibility Layer（统一接口：能力检测/读/写/状态/启停）
if [ -r "$MODDIR/lib/compat.sh" ]; then
  . "$MODDIR/lib/compat.sh" || echo "compat.sh source failed" >> "$LOG" 2>/dev/null
fi
