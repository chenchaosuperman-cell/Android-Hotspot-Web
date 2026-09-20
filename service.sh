#!/system/bin/sh

MODDIR=${0%/*}
DATA_DIR=/data/adb/xiaomi14_mifi_web
CONFIG="$DATA_DIR/config.conf"
HTTP_CONF="$DATA_DIR/httpd.conf"
LOG="$DATA_DIR/service.log"
PIDFILE="$DATA_DIR/httpd.pid"
SUPERVISOR_PIDFILE="$DATA_DIR/supervisor.pid"
DESIRED_FILE="$DATA_DIR/desired_state"
MANUAL_OFF_FILE="$DATA_DIR/manual_off"
CSRF_FILE="$DATA_DIR/csrf.token"
OP_STATUS="$DATA_DIR/operation.status"
STABLE_IP=192.168.43.1

mkdir -p "$DATA_DIR"
chmod 0700 "$DATA_DIR"
touch "$LOG"
chmod 0600 "$LOG"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done
sleep 5

. "$MODDIR/lib/common.sh"
# 模块目录去重自检（v1.7.0）：清理与当前模块同 id 的残留目录，
# 修复 KSU 管理器下滑模块列表闪退（重复 id → LazyColumn key 冲突）
dedup_dup_modules

# 旧版文本队列 → 目录式队列（一次性迁移，升级兼容）
migrate_legacy_queues

# 服务级 PID 锁（P1-12）：确保旧 supervisor 完全退出后再启动，避免新旧守护竞争
if [ -f "$SUPERVISOR_PIDFILE" ]; then
  OLD_PID=$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null)
  case "$OLD_PID" in ''|*[!0-9]*) OLD_PID=0 ;; esac
  W=0
  while [ "$OLD_PID" -gt 1 ] && [ -r "/proc/$OLD_PID/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null | "$BB" grep -q 'mifi_web/service.sh'; do
    if [ "$W" -ge 10 ]; then kill -9 "$OLD_PID" 2>/dev/null; break; fi
    kill "$OLD_PID" 2>/dev/null
    W=$((W + 1))
    sleep 1
  done
fi
echo $$ > "$SUPERVISOR_PIDFILE"
chmod 0600 "$SUPERVISOR_PIDFILE"


if [ -z "$BB" ] || [ ! -x "$BB" ]; then
  echo "$(date) ERROR: KernelSU BusyBox not found" >> "$LOG"
  exit 1
fi

if ! "$BB" --list 2>/dev/null | "$BB" grep -qx httpd; then
  echo "$(date) ERROR: BusyBox httpd applet is unavailable" >> "$LOG"
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'EOF'
SSID_B64=WGlhb21pMTQtTWlGaQ
PASS_B64=ODc2NTQzMjE
SECURITY=wpa2
BAND=2
AUTOSTART=1
PORT=8080
CHANNEL=0
MAX_CLIENTS=0
KEEPALIVE=1
IDLE_SHUTDOWN=0
SCHED_ENABLE=0
SCHED_ON=2300
SCHED_OFF=0700
SCHED_MODE=daily
SCHED_ON_WD=2300
SCHED_OFF_WD=0700
SCHED_ON_WE=2300
SCHED_OFF_WE=0700
DATA_PLAN_MB=0
DATA_PLAN_DAY=1
DATA_LIMIT_ACTION=stop
LOWBATT_ENABLE=0
LOWBATT_THRESHOLD=20
BLOCKED_MACS=
PUSHPLUS_TOKEN_B64=
DINGTALK_WEBHOOK_B64=
DINGTALK_SECRET_B64=
NOTIFY_TRAFFIC_THRESHOLDS=80,90,100
NOTIFY_LIMIT=1
SMS_FWD=0
SMS_FWD_KEYWORD_B64=
SMS_FWD_SENDERS_B64=
PROXY_ENABLE=0
PROXY_SUB_B64=
PROXY_MODE=auto
PROXY_BLOCK_QUIC=1
EOF
  chmod 0600 "$CONFIG"
fi

if [ ! -f "$HTTP_CONF" ]; then
  ADMIN_PASS=admin
  if [ -r "$MODDIR/.admin_pwd" ]; then
    ADMIN_PASS=$(cat "$MODDIR/.admin_pwd" 2>/dev/null | tr -d ' \r\n')
    case "$ADMIN_PASS" in ''|*[!A-Za-z0-9._@!-]*) ADMIN_PASS=admin ;; esac
    rm -f "$MODDIR/.admin_pwd"
  fi
  cat > "$HTTP_CONF" <<EOF
/:admin:$ADMIN_PASS
*.cgi:/system/bin/sh
EOF
  chmod 0600 "$HTTP_CONF"
else
  # Android's /data mount and SELinux policy can prevent BusyBox httpd from
  # execve(2)-ing a CGI shell script through its shebang.  Explicitly mapping
  # .cgi to /system/bin/sh makes httpd invoke the system shell as interpreter
  # and is required for the API endpoints to work reliably under KernelSU.
  if ! "$BB" grep -q '^\*\.cgi:/system/bin/sh$' "$HTTP_CONF" 2>/dev/null; then
    printf '*%s\n' '.cgi:/system/bin/sh' >> "$HTTP_CONF"
  fi
  chmod 0600 "$HTTP_CONF"
fi

# Web 管理页访问控制（v1.7.1）：仅允许本机(lo)、热点接口与 USB 共享接口访问管理端口，
# 其余接口（蜂窝数据等）一律 DROP。规则由 supervisor 主循环周期性校验保活
# （Android netd 在热点启停时可能清空自定义 INPUT 规则）。
ensure_web_fw() {
  [ -n "$PORT" ] || PORT=8080
  $IPT -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null || $IPT -A INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null
  $IPT -C INPUT -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || $IPT -I INPUT -i lo -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  for IFACE in wlan0 wlan1 wlan2 wlan3 wlan4 ap0 rndis0 usb0 eth0; do
    $IPT -C INPUT -i "$IFACE" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || $IPT -I INPUT -i "$IFACE" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
  done
}

if [ ! -s "$CSRF_FILE" ]; then
  "$BB" od -An -N24 -tx1 /dev/urandom 2>/dev/null | "$BB" tr -d ' \r\n' > "$CSRF_FILE"
  chmod 0600 "$CSRF_FILE"
fi

if [ ! -f "$OP_STATUS" ]; then
  {
    printf 'STATE=idle\n'
    printf 'TIME=0\n'
    printf 'MESSAGE_B64=\n'
  } > "$OP_STATUS"
  chmod 0600 "$OP_STATUS"
fi

load_config
check_version_upgrade
# 升级后首次运行：清理 v1.5.2 及更早版本遗留的无 comment 80 端口规则（只执行一次）
migrate_port80_once
migrate_removed_once
# 启动时清理上次异常退出可能残留的通知 busy 标记，避免后续通知被静默丢弃
rm -f "$DATA_DIR/notify.busy" 2>/dev/null
# P1-55/P1-56：清理可能残留的序号锁/健康写锁（mkdir 原子目录，正常退出自行删除）
rm -rf "$DATA_DIR/notify.seq.lock" 2>/dev/null
rm -rf "$NOTIFY_HEALTH_LOCK" 2>/dev/null

# 定时多组：按模式返回生效的开/关时间（HHMM）。
start_hotspot() {
  load_config
  SSID=$(b64url_decode "$SSID_B64")
  PASS=$(b64url_decode "$PASS_B64")
  # Do not redirect cmd's file descriptors directly to /data/adb. On this
  # HyperOS build, WifiShellCommand can fail its Binder transaction when the
  # remote service receives such an FD. Capture through an anonymous pipe and
  # append the text afterwards instead.
  STOP_OUT=$(/system/bin/cmd wifi stop-softap 2>&1)
  STOP_RC=$?
  printf '%s stop-softap rc=%s\n%s\n' "$(date)" "$STOP_RC" "$STOP_OUT" >> "$LOG"
  sleep 1
  START_OUT=$(run_softap "$SSID" "$SECURITY" "$PASS" "$BAND" "$CHANNEL" "$MAX_CLIENTS" 2>&1)
  START_RC=$?
  printf '%s start-softap rc=%s\n%s\n' "$(date)" "$START_RC" "$START_OUT" >> "$LOG"
  if [ "$START_RC" -eq 0 ]; then
    AP_IFACE=$(get_hotspot_iface)
    # 综合验证（P1-13）：接口 + IP + 系统 SoftAP 状态
    # P1-8(1.5.11)：再尽力核验实际 SSID/安全/频段/信道；返回 2=明确不匹配 → 日志告警（不回滚）
    if [ -n "$AP_IFACE" ] && softap_state_ok "$AP_IFACE"; then
      verify_softap_config "$SSID" "$SECURITY" "$BAND" "$CHANNEL"
      VRC=$?
      if [ "$VRC" = "2" ]; then
        echo "$(date) start-softap: SoftAP 参数核验不匹配（期望 ssid=$SSID band=$BAND ch=$CHANNEL，系统返回 ssid=$SNAP_AP_SSID band=$SNAP_AP_BAND ch=$SNAP_AP_CHANNEL），请人工确认实际生效配置" >> "$LOG"
      fi
      add_management_alias "$AP_IFACE"
      flush_stats_chain
      ensure_stats_chain "$AP_IFACE"
      apply_blacklist "$AP_IFACE"
      ensure_usage_chain "$AP_IFACE"
      apply_rate_limits "$AP_IFACE"
      # 启动成功：清空关闭原因（P1-7），记录由模块托管（P2-14）
      rm -f "$STOP_REASON_FILE"
      printf '1\n' > "$MANAGED_FILE"
      chmod 0600 "$MANAGED_FILE"
      return 0
    fi
    # cmd 成功但系统状态未就绪：宽限 3 秒再确认
    printf '%s start-softap rc=0 but hotspot not verified, rechecking\n' "$(date)" >> "$LOG"
    sleep 3
    AP_IFACE=$(get_hotspot_iface)
    if [ -n "$AP_IFACE" ] && softap_state_ok "$AP_IFACE"; then
      verify_softap_config "$SSID" "$SECURITY" "$BAND" "$CHANNEL"
      VRC=$?
      if [ "$VRC" = "2" ]; then
        echo "$(date) start-softap: SoftAP 参数核验不匹配（期望 ssid=$SSID band=$BAND ch=$CHANNEL，系统返回 ssid=$SNAP_AP_SSID band=$SNAP_AP_BAND ch=$SNAP_AP_CHANNEL），请人工确认实际生效配置" >> "$LOG"
      fi
      add_management_alias "$AP_IFACE"
      flush_stats_chain
      ensure_stats_chain "$AP_IFACE"
      apply_blacklist "$AP_IFACE"
      ensure_usage_chain "$AP_IFACE"
      apply_rate_limits "$AP_IFACE"
      rm -f "$STOP_REASON_FILE"
      printf '1\n' > "$MANAGED_FILE"
      chmod 0600 "$MANAGED_FILE"
      return 0
    fi
  fi
  # 启动失败（P0-3）：期望状态改回关闭，记录失败原因，避免保活每 15 秒持续重试
  printf '%s start-softap failed rc=%s, desired set to off\n' "$(date)" "$START_RC" >> "$LOG"
  printf '0\n' > "$DESIRED_FILE"
  chmod 0600 "$DESIRED_FILE"
  printf 'error\n' > "$STOP_REASON_FILE" 2>/dev/null
  chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
  return 1
}

start_httpd() {
  if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID=0 ;; esac
    if [ "$OLD_PID" -gt 1 ] && [ -r "/proc/$OLD_PID/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$OLD_PID/cmdline" | "$BB" grep -q 'httpd'; then
      kill "$OLD_PID" 2>/dev/null
    fi
  fi
  echo "$(date) Starting Web UI on port $PORT" >> "$LOG"
  "$BB" httpd -f -p "$PORT" -h "$MODDIR/web" -c "$HTTP_CONF" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  chmod 0600 "$PIDFILE"
}

if [ -f "$SUPERVISOR_PIDFILE" ]; then
  OLD_SUPERVISOR=$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null)
  case "$OLD_SUPERVISOR" in ''|*[!0-9]*) OLD_SUPERVISOR=0 ;; esac
  if [ "$OLD_SUPERVISOR" -gt 1 ] && [ "$OLD_SUPERVISOR" != "$$" ] && [ -r "/proc/$OLD_SUPERVISOR/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$OLD_SUPERVISOR/cmdline" | "$BB" grep -q 'mifi_web.*service.sh'; then
    kill "$OLD_SUPERVISOR" 2>/dev/null
  fi
fi
echo $$ > "$SUPERVISOR_PIDFILE"
chmod 0600 "$SUPERVISOR_PIDFILE"

# MANUAL_OFF 是“本次开机”的临时状态：手机开机后 120 秒内由 init 拉起时清除；
# 模块服务单独重启（restart_module）不清除，保留用户本次开机的选择。
_UP_SEC=$(/system/bin/cat /proc/uptime 2>/dev/null | "$BB" awk '{print int($1)}')
case "$_UP_SEC" in ''|*[!0-9]*) _UP_SEC=999 ;; esac
if [ "$_UP_SEC" -lt 120 ]; then
  rm -f "$MANUAL_OFF_FILE" 2>/dev/null
fi

# 开机自启：仅在真正手机开机（uptime<120s，已清 MANUAL_OFF）且 AUTOSTART=1 时启动；
# 单独重启模块服务保留 MANUAL_OFF，不重新拉起热点。
if [ "$AUTOSTART" = "1" ] && [ ! -e "$MANUAL_OFF_FILE" ]; then
  echo "$(date) autostart: starting" >> "$LOG"
  echo 1 > "$DESIRED_FILE"
  start_hotspot || echo 0 > "$DESIRED_FILE"
else
  echo 0 > "$DESIRED_FILE"
fi
chmod 0600 "$DESIRED_FILE"
start_httpd

# 初始化管理地址：热点在则绑热点，否则绑 lo
_INIT_IFACE=$(get_hotspot_iface)
if [ -n "$_INIT_IFACE" ] && softap_state_ok "$_INIT_IFACE"; then
  switch_management_to_hotspot "$_INIT_IFACE"
else
  ensure_management_loopback
fi

# Keep both the LAN admin page and the desired hotspot state alive.
# HyperOS reports a 600-second idle SoftAP shutdown timeout; the watchdog
# restarts it when keepalive is enabled. Schedule and idle shutdown are
# evaluated on the same 15-second tick.
TICK=0
IDLE_SECS=0
while true; do
  sleep 5
  # Web 管理页访问控制保活（每轮校验，被框架清空后自动重建）
  ensure_web_fw

  # 处理 CGI 提交的控制任务（由常驻进程执行，避免 CGI 子进程被杀）
  if [ -s "$CONTROL_REQUEST" ]; then
    CONTROL_ACTION=$("$BB" head -n 1 "$CONTROL_REQUEST" 2>/dev/null)
    rm -f "$CONTROL_REQUEST"
    case "$CONTROL_ACTION" in
      stop)
        echo "$(date) supervisor: processing hotspot stop request" >> "$LOG"
        if stop_hotspot_real; then
          printf '0\n' > "$DESIRED_FILE"
          chmod 0600 "$DESIRED_FILE"
          printf 'manual\n' > "$STOP_REASON_FILE"
          chmod 0600 "$STOP_REASON_FILE"
          : > "$MANUAL_OFF_FILE"
          chmod 0600 "$MANUAL_OFF_FILE"
          : > "$SKIP_WINDOW_FILE"
          write_operation success "热点已实际关闭，本次开机内不会自动拉起"
        else
          printf '1\n' > "$DESIRED_FILE"
          chmod 0600 "$DESIRED_FILE"
          rm -f "$MANUAL_OFF_FILE" "$SKIP_WINDOW_FILE" "$STOP_REASON_FILE"
          write_operation error "热点关闭失败：系统仍检测到热点运行"
        fi
        release_operation_lock
        ;;
      *)
        write_operation error "未知控制任务"
        release_operation_lock
        ;;
    esac
  fi

  HTTP_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -z "$HTTP_PID" ] || ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "$(date) Web UI exited; restarting" >> "$LOG"
    start_httpd
  fi

  TICK=$((TICK + 1))
  if [ "$TICK" -ge 3 ]; then
    TICK=0
    load_config
    DESIRED=$(cat "$DESIRED_FILE" 2>/dev/null)
    [ "$DESIRED" = "1" ] || DESIRED=0
    IFACE=$(get_hotspot_iface)
    if [ -n "$IFACE" ] && softap_state_ok "$IFACE"; then
      switch_management_to_hotspot "$IFACE"
    else
      ensure_management_loopback
    fi

    # 科学上网守护：每 30 秒检查一次。核心/API 异常时 fail-open，避免热点被残留规则锁死。
    PROXY_SUP_TICK=$(( ${PROXY_SUP_TICK:-0} + 1 ))
    if [ "$PROXY_SUP_TICK" -ge 2 ]; then
      PROXY_SUP_TICK=0
      if [ "${PROXY_ENABLE:-0}" = "1" ]; then
        if proxy_is_running && proxy_api_ready; then
          # 核心活着但 provider 没有真实节点时绝不挂透明代理，避免“国内能开、国外全断”。
          if ! proxy_provider_ready; then
            proxy_health_write true false 0
            proxy_teardown_iptables
            proxy_set_error "subscription_loaded_no_nodes"
            proxy_write_state "subscription_error"
          else
            proxy_health_write true true "$(proxy_provider_node_count)"

            # 手机本机代理独立于热点接口。开关打开时守护 OUTPUT 链，关闭时确保彻底移除。
            if [ "${PROXY_SELF:-0}" = "1" ]; then
              if ! proxy_self_iptables_ok; then
                proxy_log "supervisor: resync self proxy iptables"
                proxy_sync_self_iptables >/dev/null 2>&1 || proxy_self_set_error "self_iptables_resync_failed"
              else
                proxy_self_clear_error
              fi
            else
              proxy_teardown_self_iptables
              proxy_self_clear_error
            fi

            if [ "${PROXY_SCOPE:-both}" = "self" ]; then
              proxy_teardown_hotspot_iptables
              if [ "${PROXY_SELF:-0}" = "1" ] && proxy_self_iptables_ok; then
                proxy_clear_error
                proxy_write_state "running"
              else
                proxy_set_error "self_iptables_resync_failed"
                proxy_write_state "firewall_error"
              fi
            elif [ -n "$IFACE" ]; then
              if ! proxy_iptables_ok "$IFACE"; then
                proxy_log "supervisor: resync hotspot iptables iface=$IFACE"
                if proxy_sync_iptables; then
                  proxy_clear_error
                  proxy_write_state "running"
                else
                  proxy_set_error "iptables_resync_failed"
                  proxy_write_state "firewall_error"
                  proxy_teardown_hotspot_iptables
                fi
              elif [ "$(proxy_read_state)" != "running" ]; then
                proxy_clear_error
                proxy_write_state "running"
              fi
            else
              proxy_teardown_hotspot_iptables
              proxy_clear_error
              if [ "${PROXY_SELF:-0}" = "1" ] && proxy_self_iptables_ok; then
                proxy_write_state "running"
              else
                proxy_write_state "waiting_hotspot"
              fi
            fi
          fi
        else
          proxy_health_write false false 0
          proxy_teardown_iptables
          proxy_log "supervisor: mihomo down, scheduling restart"
          proxy_start_async >/dev/null 2>&1 || proxy_log "supervisor: could not schedule restart"
        fi
      else
        if proxy_is_running || $IPT -t nat -L MIFI_PROXY >/dev/null 2>&1 || $IPT -t nat -L MIFI_PROXY_SELF >/dev/null 2>&1; then
          proxy_stop >/dev/null 2>&1
        fi
      fi
    fi

    # 定时开关：窗口内保持开启，窗口外关闭（开启时覆盖手动状态）
    # 跨午夜归属（P1-10）：周五 23:00–周六 07:00 的窗口，周六凌晨仍属于周五计划
    if [ "$SCHED_ENABLE" = "1" ]; then
      NOW=$(now_hhmm)
      set -- $(sched_info)
      T_ON=$1; T_OFF=$2; Y_ON=$3; Y_OFF=$4
      if sched_in_window "$T_ON" "$T_OFF" "$Y_ON" "$Y_OFF" "$NOW"; then
        if [ "$DESIRED" != "1" ] && [ ! -e "$MANUAL_OFF_FILE" ] && [ ! -e "$SKIP_WINDOW_FILE" ]; then
          echo "$(date) schedule: in window, starting" >> "$LOG"
          echo 1 > "$DESIRED_FILE"
          if start_hotspot; then
            IFACE=$(get_hotspot_iface)
    if [ -n "$IFACE" ] && softap_state_ok "$IFACE"; then
      switch_management_to_hotspot "$IFACE"
    else
      ensure_management_loopback
    fi
            DESIRED=1
          else
            IFACE=
            DESIRED=0
          fi
        elif [ -e "$MANUAL_OFF_FILE" ] && [ "$DESIRED" != "1" ]; then
          echo "$(date) schedule: in window but manual_off (this boot), skip auto start" >> "$LOG"
        fi
      else
        # P1-5(1.5.11) 出窗关闭：
        #  a) 今天有计划且不在窗口内 → 关闭；
        #  b) 今天无计划，但昨天存在跨午夜窗口且已过结束时间（如周五23:00开、周六07:00关）→ 关闭；
        #  c) 昨天窗口非跨午夜、今天无计划 → 不干预。
        # 注意：此处不再 continue——短信、低电量、流量归档、通知重试等后台公共任务必须继续运行
        SHOULD_CLOSE=0
        if [ "$T_ON" != "0" ] && [ "$T_OFF" != "0" ]; then
          SHOULD_CLOSE=1
        elif [ "$Y_ON" != "0" ] && [ "$Y_OFF" != "0" ] && [ "$Y_OFF" -lt "$Y_ON" ]; then
          SHOULD_CLOSE=1
        fi
        if [ "$SHOULD_CLOSE" = "1" ] && [ "$DESIRED" = "1" ]; then
          echo "$(date) schedule: out of window, stopping" >> "$LOG"
          /system/bin/cmd wifi stop-softap >> "$LOG" 2>&1
          remove_management_alias "$IFACE"
          echo 0 > "$DESIRED_FILE"
          printf 'schedule\n' > "$STOP_REASON_FILE" 2>/dev/null
          chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
          DESIRED=0
          IFACE=
        fi
        rm -f "$IDLE_FILE" "$IDLE_SINCE" "$SKIP_WINDOW_FILE"
      fi
    fi

    # 保活：期望开启但热点掉了就重启（保活关闭时不自动重启）
    if [ "$DESIRED" = "1" ] && [ "$KEEPALIVE" = "1" ] && [ -z "$IFACE" ] && [ ! -e "$MANUAL_OFF_FILE" ]; then
      echo "$(date) SoftAP is down while desired; restarting" >> "$LOG"
      if start_hotspot; then
        IFACE=$(get_hotspot_iface)
    if [ -n "$IFACE" ] && softap_state_ok "$IFACE"; then
      switch_management_to_hotspot "$IFACE"
    else
      ensure_management_loopback
    fi
        echo "$(date) keepalive: hotspot recovered" >> "$LOG"
        # 10分钟内不重复发"热点已自动恢复"通知
        RECOVER_NOTIFY_FILE="$DATA_DIR/recover_notify_ts"
        NOW_S=$($DATE_CMD +%s 2>/dev/null || date +%s)
        LAST_RECOVER=$(cat "$RECOVER_NOTIFY_FILE" 2>/dev/null)
        case "$LAST_RECOVER" in ''|*[!0-9]*) LAST_RECOVER=0 ;; esac
        if [ $((NOW_S - LAST_RECOVER)) -gt 600 ]; then
          printf '%s\n' "$NOW_S" > "$RECOVER_NOTIFY_FILE"
          chmod 0600 "$RECOVER_NOTIFY_FILE" 2>/dev/null
          [ "${NOTIFY_HOTSPOT_EVT:-1}" = "1" ] && notify_all_async "热点已自动恢复" "时间: $(date '+%m-%d %H:%M')" 2>/dev/null &
        fi
      else
        IFACE=
        DESIRED=0
        echo "$(date) keepalive: start failed, desired reset to off" >> "$LOG"
        [ "${NOTIFY_HOTSPOT_EVT:-1}" = "1" ] && notify_all_async "热点启动失败" "时间: $(date '+%m-%d %H:%M') 保活重启失败，热点已关闭，需手动开启" 2>/dev/null &
      fi
    fi

    rotate_log

    if [ -n "$IFACE" ]; then
      add_management_alias "$IFACE"
      ensure_stats_chain "$IFACE"
      apply_blacklist "$IFACE"
      ensure_usage_chain "$IFACE"
      apply_rate_limits "$IFACE"
      CLIENTS=$(list_clients "$IFACE")
      # P1-82：统计链 RETURN 计数规则维护移入后台主循环（状态接口保持只读）
      CLIENT_IPS=$(printf '%s\n' "$CLIENTS" | "$BB" cut -d'|' -f1)
      update_stats_rules "$IFACE" $CLIENT_IPS
      # 新设备接入提醒：在线 MAC 未在 known_macs 中则记录并写日志
      for CLINE in $CLIENTS; do
        NMAC=$(printf '%s' "$CLINE" | "$BB" cut -d'|' -f2)
        [ -z "$NMAC" ] && continue
        # 客户端历史：仅 REACHABLE/DELAY/PROBE 活跃状态累计在线时长（ARP 缓存补全不算）
        CS=$(printf '%s' "$CLINE" | "$BB" cut -d'|' -f3)
        case "$CS" in REACHABLE|DELAY|PROBE) client_stats_touch "$NMAC" 15 ;; esac
        if ! "$BB" grep -qx "$NMAC" "$KNOWN_MACS" 2>/dev/null; then
          NVENDOR=$(mac_vendor "$("$BB" printf '%s' "$NMAC" | "$BB" tr 'a-f' 'A-F')")
          NIP=$(printf '%s' "$CLINE" | "$BB" cut -d'|' -f1)
          echo "$(date) new client: $NIP $NMAC ${NVENDOR:-unknown}" >> "$LOG"
          printf '%s\n' "$NMAC" >> "$KNOWN_MACS"
          chmod 0600 "$KNOWN_MACS"
        fi
      done
    fi

    # 热点转发流量累计（无条件：供限额判断与按日/月度统计使用，热点关闭时也累计；
    # 计数链被系统清理时自动从 0 重新开始）
    accumulate_usage
    # 客户端流量按 MAC 持久化（设备换 IP / 离线后累计仍保留）
    # 注意：必须在 cleanup_stats_rules 之前，否则设备刚离线时其统计规则先被删除，
    # 最后一个轮询周期的计数来不及写入累计文件（漏记）。
    persist_client_usage "$IFACE"
    # 统计链过期规则清理：已不在线的 IP 从链中移除（在持久化之后执行）
    if [ -n "$IFACE" ]; then
      cleanup_stats_rules $(printf '%s\n' "$CLIENTS" | "$BB" cut -d'|' -f1)
    fi

    # 流量限额：本账期用量达到套餐自动关热点（DATA_LIMIT_ACTION=notify 时仅提醒不关闭）。
    # P0-24：按账期用量（PLAN_PERIOD_BYTES）判断，不再按历史总累计——新账期开始后旧流量不会误触发。
    # P0-25：100% 通知统一由下方“账期分级提醒”发送（合并“限额用尽”文案），此处不再重复发通知。
    plan_usage_percent
    if [ "$DESIRED" = "1" ] && [ "$PLAN_TOTAL" -gt 0 ] 2>/dev/null && [ "$PLAN_PERCENT" -ge 100 ] 2>/dev/null; then
      if [ "${DATA_LIMIT_ACTION:-stop}" != "notify" ]; then
        echo "$(date) data limit reached (账期 ${PLAN_PERIOD_BYTES}B >= ${PLAN_TOTAL}MB), stopping" >> "$LOG"
        /system/bin/cmd wifi stop-softap >> "$LOG" 2>&1
        remove_management_alias "$IFACE"
        echo 0 > "$DESIRED_FILE"
        printf 'limit\n' > "$STOP_REASON_FILE" 2>/dev/null
        chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
        rm -f "$IDLE_FILE"
      fi
    fi

    # 账期分级提醒：达到 80/90/100% 各通知一次；统一受 NOTIFY_LIMIT 开关控制（P0-26）。
    # 100% 通知合并“限额用尽”文案（P0-25），不再与上方限额判断重复发送。
    if [ "$PLAN_TOTAL" -gt 0 ] 2>/dev/null; then
      plan_usage_percent
      # 账期跨期（起始日变化）时重置分级标记，新账期重新按 80/90/100% 提醒
      if [ -n "$PLAN_PERIOD_DAY" ]; then
        LAST_PD=$(cat "$PLAN_PERIOD_FILE" 2>/dev/null | "$BB" tr -d ' \r\n')
        if [ "$LAST_PD" != "$PLAN_PERIOD_DAY" ]; then
          printf '%s\n' "$PLAN_PERIOD_DAY" > "$PLAN_PERIOD_FILE" 2>/dev/null
          chmod 0600 "$PLAN_PERIOD_FILE" 2>/dev/null
          rm -f "$PLAN_TH_MARK"
        fi
      fi
      if [ "$PLAN_PERCENT" -ge 0 ] 2>/dev/null; then
        if [ "${NOTIFY_LIMIT:-1}" = "1" ]; then
          MARKED=$(cat "$PLAN_TH_MARK" 2>/dev/null)
          case "$MARKED" in ''|*[!0-9\ ]*) MARKED= ;; esac
          for TH in $(printf '%s' "${NOTIFY_TRAFFIC_THRESHOLDS:-80,90,100}" | "$BB" tr ',' ' '); do
            case "$TH" in ''|*[!0-9]*) continue ;; esac
            [ "$TH" -ge 1 ] && [ "$TH" -le 100 ] || continue
            if [ "$PLAN_PERCENT" -ge "$TH" ] 2>/dev/null; then
              if ! printf '%s' " $MARKED " | "$BB" grep -q " $TH "; then
                if [ "$TH" = "100" ]; then
                  if [ "${DATA_LIMIT_ACTION:-stop}" != "notify" ]; then
                    MSG="本账期流量已达 100%
热点已自动关闭"
                  else
                    MSG="本账期流量已达 100%（超限操作：仅提醒，热点保持运行）"
                  fi
                else
                  MSG="本账期已用流量达到 ${TH}%"
                fi
                notify_all_async "流量提醒(${TH}%)" "$MSG
已用: ${PLAN_PERCENT}%
时间: $(/system/bin/date '+%m-%d %H:%M')"
                printf '%s %s\n' "$MARKED" "$TH" > "$PLAN_TH_MARK" 2>/dev/null
                chmod 0600 "$PLAN_TH_MARK" 2>/dev/null
                MARKED="$MARKED $TH"
              fi
            fi
          done
        fi
      fi
    fi

    # 流量按日/月度统计（跨日归档、保留 11 天；基于累计文件，与限额逻辑独立）
    accumulate_daily

    # 短信转发（新短信 → 已配置的 PushPlus/钉钉）
    if [ "${SMS_FWD:-0}" = "1" ]; then
      check_sms_forward
    fi

    # 低电量提醒（放电中电量低于阈值时推送一次；同一轮只提醒一次，充电或电量回升后恢复）
    lowbatt_tick

    # 通知队列周期兜底：失败重试的消息在退避到期后由这里再触发（每 60 秒）
    NOTIFY_TICK=$(( ${NOTIFY_TICK:-0} + 1 ))
    if [ "$NOTIFY_TICK" -ge 4 ]; then
      NOTIFY_TICK=0
      drain_notify_queue >/dev/null 2>&1 &
    fi

    # 空闲自动关闭：在线客户端为 0 连续达到设定分钟数则关闭。
    # 前置条件：热点确实在运行（IFACE 非空），否则交给保活逻辑处理，
    # 避免热点启动失败时被误判为"无客户端"而永久关闭（DESIRED 置 0）。
    # 定时开启时由定时逻辑接管开关，跳过空闲自关，避免"空闲关闭→定时又拉起"拉锯。
    SCHED_IN_WINDOW=0
    if [ "${SCHED_ENABLE:-0}" = "1" ]; then
      set -- $(sched_info)
      T_ON=$1; T_OFF=$2; Y_ON=$3; Y_OFF=$4
      sched_in_window "$T_ON" "$T_OFF" "$Y_ON" "$Y_OFF" "$(now_hhmm)" && SCHED_IN_WINDOW=1
    fi
    if [ "$DESIRED" = "1" ] && [ -n "$IFACE" ] && [ "$SCHED_IN_WINDOW" = "0" ] && [ "${IDLE_SHUTDOWN:-0}" -gt 0 ]; then
      CNT=$(count_connected_clients "$IFACE")
      if [ "$CNT" -eq 0 ]; then
        # 空闲开始时间戳持久化（P1-22）：模块/服务重启后计时延续，不会归零
        NOW_S=$($DATE_CMD +%s 2>/dev/null)
        case "$NOW_S" in ''|*[!0-9]*) NOW_S=0 ;; esac
        if [ ! -f "$IDLE_SINCE" ]; then
          printf '%s\n' "$NOW_S" > "$IDLE_SINCE"
          chmod 0600 "$IDLE_SINCE"
        fi
        SINCE=$(cat "$IDLE_SINCE" 2>/dev/null | "$BB" tr -d ' \r\n')
        case "$SINCE" in ''|*[!0-9]*) SINCE=$NOW_S ;; esac
        IDLE_SECS=$((NOW_S - SINCE))
        [ "$IDLE_SECS" -lt 0 ] && IDLE_SECS=0
        LIMIT_S=$((IDLE_SHUTDOWN * 60))
        if [ "$IDLE_SECS" -ge "$LIMIT_S" ]; then
          rm -f "$IDLE_FILE" "$IDLE_SINCE"
          echo "$(date) idle shutdown: no clients for ${IDLE_SHUTDOWN}m" >> "$LOG"
          /system/bin/cmd wifi stop-softap >> "$LOG" 2>&1
          remove_management_alias "$IFACE"
          echo 0 > "$DESIRED_FILE"
          printf 'idle\n' > "$STOP_REASON_FILE" 2>/dev/null
          chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
          IDLE_SECS=0
        else
          # 倒计时预告：剩余分钟（向上取整，最少 1），status.cgi 读取并在页面提示
          LEFT=$(((LIMIT_S - IDLE_SECS + 59) / 60))
          [ "$LEFT" -lt 1 ] && LEFT=1
          printf '%s\n' "$LEFT" > "$IDLE_FILE"
          chmod 0600 "$IDLE_FILE"
        fi
      else
        IDLE_SECS=0
        rm -f "$IDLE_FILE" "$IDLE_SINCE"
      fi
    else
      rm -f "$IDLE_FILE" "$IDLE_SINCE"
    fi
  fi
done
