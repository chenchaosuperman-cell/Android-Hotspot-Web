#!/system/bin/sh

MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/control.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"message":"模块公共组件不存在"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json

EXPECTED_CSRF=$(read_csrf_token)
# BusyBox httpd builds differ in which HTTP_* headers they expose to CGI.
# Validate a random token in the POST query instead of relying on non-standard
# request headers that may be silently discarded by httpd.
if [ "${REQUEST_METHOD:-}" != "POST" ] || [ -z "$EXPECTED_CSRF" ] || \
   [ "$(get_param token)" != "$EXPECTED_CSRF" ]; then
  printf '{"ok":false,"message":"请求被拒绝"}'
  exit 0
fi

ACTION=$(get_param action)
# P1-6(1.5.11)：配置事务锁——锁覆盖 加锁→load_config→修改→save→解锁 全过程，
# 两个并发请求不会出现“先后读旧配置、后写者覆盖前者字段”的丢失更新。
CFG_TXN=0
# P2(1.5.12)：只读/不写配置的 action（导出、测试通知、读密码、读短信、鉴权）不加锁，
# 避免测试通知十几秒的网络请求阻塞其它设置保存。
case "$ACTION" in
  export_config|test_notify|test_lowbatt|get_password|sms_list)
    : ;;
  *)
    if lock_acquire "$DATA_DIR/config.lock"; then
      CFG_TXN=1
      trap 'lock_release "$DATA_DIR/config.lock"' EXIT
    else
      printf '{"ok":false,"message":"配置正忙，请稍后重试"}'
      exit 0
    fi
    ;;
esac
load_config



# 后台异步重启热点（使用调用方已算好的 NEW_SSID/NEW_SECURITY/NEW_PASS/NEW_BAND/NEW_CHANNEL/NEW_MAX）
# 子 shell 带 trap：任何退出路径都释放操作锁，避免异常残留 120s
# 启动后的参数核验复用 common.sh 的有限时 SoftAP 快照。
# 参数读取在不同 HyperOS 版本上并不稳定；热点接口/IP/系统状态已确认运行时，
# 参数不一致只写告警，不能把已成功启动的热点回滚为失败。
verify_hotspot_params() {
  want_ssid=$1
  want_sec=$2
  want_band=$3
  want_ch=$4
  verify_softap_config "$want_ssid" "$want_sec" "$want_band" "$want_ch"
  rc=$?
  if [ "$rc" = "2" ]; then
    printf '%s hotspot verify warning: reported parameters differ; keep running hotspot\n' "$(date)" >> "$LOG"
  fi
  printf ''
  return 0
}

# 按配置启动并验证热点（P0-1：不再依赖可能为空的 NEW_* 变量）。
# $1=rollback：save_hotspot 传 1（启动失败自动回滚配置），start_softap 传 0。
restart_hotspot_async() {
  ROLLBACK=${1:-0}
  (
    trap 'release_operation_lock' EXIT
    sleep 2
    load_config
    # v1.7.6：系统 SoftApConfiguration 为唯一数据源，run_softap 无参启动
    # （config.conf 残留旧热点字段时，run_softap 内部自动迁移到系统后清除）
    # v1.7.6：停止走系统 Tethering 路径（hotspot_stop → connectivity tether stop）
    hotspot_stop >/dev/null 2>&1
    sleep 1
    # Keep loopback management address until hotspot is ready
    OUT=$(run_softap 2>&1)
    RC=$?
    printf '%s\n' "$OUT" >> "$LOG"
    VERIFY_IFACE=
    VERIFY_IP=
    COUNT=0
    while [ "$COUNT" -lt 12 ]; do
      VERIFY_IFACE=$(get_hotspot_iface)
      VERIFY_IP=$(get_iface_ip "$VERIFY_IFACE")
      [ -n "$VERIFY_IP" ] && break
      COUNT=$((COUNT + 1))
      sleep 1
    done
    OK=0
    if [ "$RC" -eq 0 ] && [ -n "$VERIFY_IP" ] && softap_state_ok "$VERIFY_IFACE"; then
      PARAM_ERR=$(verify_hotspot_params "$SSID" "$SECURITY" "$BAND" "$CHANNEL")
      if [ -z "$PARAM_ERR" ]; then
        OK=1
        switch_management_to_hotspot "$VERIFY_IFACE"
        flush_stats_chain
        ensure_stats_chain "$VERIFY_IFACE"
        apply_mac_policy "$VERIFY_IFACE"
        ensure_usage_chain "$VERIFY_IFACE"
        apply_rate_limits "$VERIFY_IFACE"
        rm -f "$STOP_REASON_FILE"
        printf '1\n' > "$MANAGED_FILE"
        chmod 0600 "$MANAGED_FILE"
        if [ "$(get_management_ip "$VERIFY_IFACE")" = "$STABLE_IP" ]; then
          write_operation success "热点已启动，固定管理地址 $STABLE_IP:$PORT"
        else
          write_operation success "热点已启动，但固定管理地址 $STABLE_IP 未挂载成功（该设备未通过固定管理地址兼容验证）"
        fi
      else
        write_operation error "热点启动失败：$PARAM_ERR"
      fi
    else
      # v1.7.8：页面只展示简洁错误（不把原始 callback/dumpsys 输出塞进红色错误框）；
      # 完整原始输出已写入 $LOG，可到 设置→诊断/日志 查看。
      OUT_FIRST=$(printf '%s\n' "$OUT" | "$BB" sed -n '1p' | "$BB" cut -c1-80 2>/dev/null)
      [ -n "$OUT_FIRST" ] || OUT_FIRST="系统未分配热点接口地址"
      write_operation error "热点启动失败：$OUT_FIRST（详见诊断/日志页）"
    fi
    if [ "$OK" != "1" ]; then
      ensure_management_loopback
      printf '0\n' > "$DESIRED_FILE"
      chmod 0600 "$DESIRED_FILE"
      printf 'error\n' > "$STOP_REASON_FILE" 2>/dev/null
      chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
      if [ "$ROLLBACK" = "1" ] && [ -f "$CONFIG.bak" ]; then
        BAK_MD5=$("$BB" head -n 1 "$CONFIG.bak.md5" 2>/dev/null | "$BB" cut -d' ' -f1)
        CUR_MD5=$("$BB" md5sum "$CONFIG" 2>/dev/null | "$BB" cut -d' ' -f1)
        if [ "$BAK_MD5" = "$CUR_MD5" ]; then
          cp "$CONFIG.bak" "$CONFIG" 2>/dev/null
          chmod 0600 "$CONFIG" 2>/dev/null
          printf '%s hotspot start failed; config rolled back\n' "$(date)" >> "$LOG"
        else
          printf '%s hotspot start failed; config changed during async verify, keep current config\n' "$(date)" >> "$LOG"
        fi
        rm -f "$CONFIG.bak.md5"
      fi
    elif [ "$ROLLBACK" = "1" ]; then
      rm -f "$CONFIG.bak"
    fi
    release_operation_lock
  ) </dev/null >/dev/null 2>&1 &
}

case "$ACTION" in
  start)
    NEW_SSID_B64=$(get_param ssid)
    NEW_PASS_B64=$(get_param password)
    NEW_SECURITY=$(get_param security)
    NEW_BAND=$(get_param band)
    NEW_HIDDEN=$(get_param hidden)
    NEW_AUTOSTART=$(get_param autostart)
    NEW_CHANNEL=$(get_param channel)
    NEW_MAX=$(get_param maxClients)

    valid_b64url "$NEW_SSID_B64" || { printf '{"ok":false,"message":"热点名称格式错误"}'; exit 0; }
    case "$NEW_PASS_B64" in *[!A-Za-z0-9_-]*) printf '{"ok":false,"message":"密码格式错误"}'; exit 0 ;; esac
    case "$NEW_SECURITY" in open|wpa2|wpa3|wpa3_transition) : ;; *) printf '{"ok":false,"message":"不支持的加密方式"}'; exit 0 ;; esac
    case "$NEW_BAND" in 2|5|6|any) : ;; *) printf '{"ok":false,"message":"不支持的频段"}'; exit 0 ;; esac
    case "$NEW_HIDDEN" in 0|1) : ;; *) NEW_HIDDEN=0 ;; esac
    if [ "$NEW_HIDDEN" = "1" ] && ! softap_hidden_supported; then
      printf '{"ok":false,"message":"当前系统不支持隐藏 SSID（SoftApConfiguration 无此能力），已保持广播模式"}'
      exit 0
    fi
    case "$NEW_AUTOSTART" in 0|1) : ;; *) NEW_AUTOSTART=1 ;; esac
    case "$NEW_CHANNEL" in ''|0|any) NEW_CHANNEL=0 ;; *[!0-9]*) printf '{"ok":false,"message":"信道格式错误"}'; exit 0 ;; esac
    valid_channel "$NEW_BAND" "$NEW_CHANNEL" || { printf '{"ok":false,"message":"信道 %s 与频段不匹配（2.4G: 1/3/6/9/11/13；5G: 36/40/44/48/149/153/157/161/165）"}' "$NEW_CHANNEL"; exit 0; }
    case "$NEW_MAX" in ''|0) NEW_MAX=0 ;; *[!0-9]*) printf '{"ok":false,"message":"最大连接数格式错误"}'; exit 0 ;; esac
    valid_max_clients "$NEW_MAX" || { printf '{"ok":false,"message":"最大连接数需在0–32之间"}'; exit 0; }

    NEW_SSID=$(b64url_decode "$NEW_SSID_B64")
    if [ -n "$NEW_PASS_B64" ]; then
      NEW_PASS=$(b64url_decode "$NEW_PASS_B64")
    else
      # v1.7.6：密码留空 = 沿用系统当前密码（唯一数据源）
      hotspot_get_config
      NEW_PASS=$sys_password
    fi
    SSID_LEN=$(printf '%s' "$NEW_SSID" | "$BB" wc -c | "$BB" tr -d ' ')
    PASS_LEN=$(printf '%s' "$NEW_PASS" | "$BB" wc -c | "$BB" tr -d ' ')
    [ "$SSID_LEN" -lt 1 ] || [ "$SSID_LEN" -gt 32 ] && { printf '{"ok":false,"message":"热点名称需为1–32字节"}'; exit 0; }
    if printf '%s' "$NEW_SSID" | "$BB" grep -q '[[:cntrl:]]'; then
      printf '{"ok":false,"message":"热点名称不能包含控制字符"}'
      exit 0
    fi
    if printf '%s' "$NEW_PASS" | "$BB" grep -q '[[:cntrl:]]'; then
      printf '{"ok":false,"message":"热点密码不能包含控制字符"}'
      exit 0
    fi
    if [ "$NEW_SECURITY" != "open" ] && { [ "$PASS_LEN" -lt 8 ] || [ "$PASS_LEN" -gt 63 ]; }; then
      printf '{"ok":false,"message":"请输入8–63位热点密码"}'
      exit 0
    fi

    if ! acquire_operation_lock; then
      printf '{"ok":false,"message":"已有操作正在执行，请稍后再试"}'
      exit 0
    fi

    # v1.7.6：热点参数经 hotspot_set_config 写入系统，不再写入模块 config.conf
    AUTOSTART=$NEW_AUTOSTART
    # 手动开启：解除本次开机手动关闭，恢复自动策略
    rm -f "$MANUAL_OFF_FILE" 2>/dev/null
    HOLD_OFF=0
    rm -f "$SKIP_WINDOW_FILE" 2>/dev/null
    # P0-4：先备份旧配置；启动验证成功后才保留新配置，失败自动回滚
    cp "$CONFIG" "$CONFIG.bak" 2>/dev/null
    # P1-4(1.5.12)：记录备份时配置指纹，异步回滚前对比——期间用户若又改过配置则不回滚
    "$BB" md5sum "$CONFIG" 2>/dev/null | "$BB" cut -d' ' -f1 > "$CONFIG.bak.md5" 2>/dev/null
    save_config || { release_operation_lock; rm -f "$CONFIG.bak" "$CONFIG.bak.md5"; printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    # 一套配置：经 Hotspot Compatibility Layer 调 Framework setSoftApConfiguration 持久化（系统设置 ↔ Web 共用一份）
    if ! hotspot_set_config "$NEW_SSID" "$NEW_SECURITY" "$NEW_PASS" "$NEW_BAND" "$NEW_CHANNEL" "$NEW_HIDDEN" "$NEW_MAX"; then
      release_operation_lock; rm -f "$CONFIG.bak" "$CONFIG.bak.md5"
      printf '{"ok":false,"message":"系统热点配置写入失败（系统 API 未接受），已还原模块配置"}'; exit 0
    fi
    # 热点开着 → 重启一次应用新配置；关着 → 仅持久化（不偷偷开启，下次启动生效）
    softap_state_snapshot 2>/dev/null
    if [ "$SNAP_AP_STATE" = "ENABLED" ]; then
      printf '1\n' > "$DESIRED_FILE"
      chmod 0600 "$DESIRED_FILE"
      write_operation working "正在应用热点配置并验证生效"
      printf '{"ok":true,"message":"配置已保存，正在重启热点应用新配置，结果稍后显示"}'
      restart_hotspot_async 1
    else
      printf '0\n' > "$DESIRED_FILE"
      chmod 0600 "$DESIRED_FILE"
      printf '{"ok":true,"message":"配置已保存（热点当前关闭，下次开启时生效）"}'
    fi
    ;;
  start_softap)
    # 轻量开启：用已保存配置直接启动（不修改热点参数）；手动开启即解除“手动保持关闭”
    if ! acquire_operation_lock; then
      printf '{"ok":false,"message":"已有操作正在执行，请稍后再试"}'
      exit 0
    fi
    rm -f "$MANUAL_OFF_FILE" 2>/dev/null
    HOLD_OFF=0
    rm -f "$SKIP_WINDOW_FILE" 2>/dev/null
    save_config || { release_operation_lock; printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '1\n' > "$DESIRED_FILE"
    chmod 0600 "$DESIRED_FILE"
    write_operation working "正在开启热点"
    printf '{"ok":true,"message":"热点正在启动，结果稍后显示"}'
    restart_hotspot_async 0
    ;;
  stop)
    if ! acquire_operation_lock; then
      printf '{"ok":false,"message":"已有操作正在执行，请稍后再试"}'
      exit 0
    fi
    printf '0\n' > "$DESIRED_FILE"
    chmod 0600 "$DESIRED_FILE"
    printf 'manual\n' > "$STOP_REASON_FILE" 2>/dev/null
    chmod 0600 "$STOP_REASON_FILE" 2>/dev/null
    : > "$MANUAL_OFF_FILE" 2>/dev/null
    chmod 0600 "$MANUAL_OFF_FILE" 2>/dev/null
    : > "$SKIP_WINDOW_FILE" 2>/dev/null
    write_operation working "正在关闭热点"
    REQ_TMP="$CONTROL_REQUEST.$$"
    if ! printf 'stop\n' > "$REQ_TMP" || ! mv -f "$REQ_TMP" "$CONTROL_REQUEST"; then
      rm -f "$REQ_TMP"
      release_operation_lock
      write_operation error "关闭任务提交失败"
      printf '{"ok":false,"message":"关闭任务提交失败"}'
      exit 0
    fi
    chmod 0600 "$CONTROL_REQUEST"
    printf '{"ok":true,"message":"关闭任务已提交"}'
    ;;
  proxy_save)
    SUB_B64=$(get_param sub_b64)
    MODE=$(get_param mode)
    ENABLE=$(get_param enable)
    BLOCK_QUIC=$(get_param block_quic)
    SELF_PROXY=$(get_param self)
    ROUTE_MODE=$(get_param proxyRouteMode)
    PROXY_SCOPE_V=$(get_param proxyScope)
    if [ -n "$SUB_B64" ]; then
      valid_b64url "$SUB_B64" || { printf '{"ok":false,"message":"订阅地址编码无效"}'; exit 0; }
      SUB_URL=$(b64url_decode "$SUB_B64" 2>/dev/null)
      proxy_valid_sub_url "$SUB_URL" || { printf '{"ok":false,"message":"订阅地址必须以 http:// 或 https:// 开头"}'; exit 0; }
      PROXY_SUB_B64="$SUB_B64"
      proxy_init_dirs
      printf '%s\n' "$SUB_URL" > "$PROXY_SUB_FILE"
      chmod 0600 "$PROXY_SUB_FILE" 2>/dev/null
    fi
    [ -n "$MODE" ] && case "$MODE" in auto|fallback|manual) PROXY_MODE="$MODE" ;; *) printf '{"ok":false,"message":"代理模式无效"}'; exit 0 ;; esac
    [ -n "$ENABLE" ] && case "$ENABLE" in 0|1) PROXY_ENABLE="$ENABLE" ;; *) printf '{"ok":false,"message":"代理开关参数无效"}'; exit 0 ;; esac
    [ -n "$BLOCK_QUIC" ] && case "$BLOCK_QUIC" in 0|1) PROXY_BLOCK_QUIC="$BLOCK_QUIC" ;; *) printf '{"ok":false,"message":"QUIC 参数无效"}'; exit 0 ;; esac
    [ -n "$SELF_PROXY" ] && case "$SELF_PROXY" in 0|1) PROXY_SELF="$SELF_PROXY" ;; *) printf '{"ok":false,"message":"本机代理参数无效"}'; exit 0 ;; esac
    [ -n "$ROUTE_MODE" ] && case "$ROUTE_MODE" in rule|global) PROXY_ROUTE_MODE="$ROUTE_MODE" ;; *) printf '{"ok":false,"message":"代理模式无效"}'; exit 0 ;; esac
    if [ -n "$PROXY_SCOPE_V" ]; then
      case "$PROXY_SCOPE_V" in
        hotspot) PROXY_SCOPE=hotspot; PROXY_SELF=0 ;;
        self) PROXY_SCOPE=self; PROXY_SELF=1 ;;
        both) PROXY_SCOPE=both; PROXY_SELF=1 ;;
        *) printf '{"ok":false,"message":"代理范围无效"}'; exit 0 ;;
      esac
    fi
    save_config || { printf '{"ok":false,"message":"代理配置保存失败"}'; exit 0; }
    printf '{"ok":true,"message":"订阅已保存"}'
    ;;
  proxy_start)
    PROXY_ENABLE=1
    save_config || { printf '{"ok":false,"message":"代理配置保存失败"}'; exit 0; }
    # Startup may need config validation + provider download/health check. Never
    # keep the browser CGI request open for tens of seconds; Safari reports that
    # as "Load failed" and the global status poll appears broken at the same time.
    if proxy_start_async; then
      printf '{"ok":true,"message":"正在启动科学上网，请稍候"}'
    else
      printf '{"ok":false,"message":"无法创建代理启动任务"}'
    fi
    ;;
  proxy_stop)
    PROXY_ENABLE=0
    save_config || { printf '{"ok":false,"message":"代理配置保存失败"}'; exit 0; }
    proxy_stop
    printf '{"ok":true,"message":"科学上网已停止"}'
    ;;
  proxy_set_self)
    SELF_PROXY=$(get_param self)
    ROUTE_MODE=$(get_param proxyRouteMode)
    PROXY_SCOPE_V=$(get_param proxyScope)
    case "$SELF_PROXY" in 0|1) : ;; *) printf '{"ok":false,"message":"本机代理参数无效"}'; exit 0 ;; esac
    if [ "$SELF_PROXY" = "1" ]; then
      # 核心未启动/Provider 未就绪时先记住开关；守护进程会在代理就绪后自动应用。
      SELF_APPLIED=0
      if proxy_is_running && proxy_api_ready && proxy_provider_ready; then
        PROXY_SELF=1
        if ! proxy_setup_self_iptables; then
          PROXY_SELF=0
          proxy_teardown_self_iptables
          save_config >/dev/null 2>&1 || true
          ERR=$(cat "$PROXY_SELF_ERROR_FILE" 2>/dev/null | "$BB" head -c 120)
          case "$ERR" in
            self_bypass_unavailable) MSG="系统内核缺少本机透明代理所需的 mark/owner 规则" ;;
            self_nat_chain_failed) MSG="无法创建本机 NAT 链" ;;
            self_dns_udp_failed|self_dns_tcp_failed) MSG="本机 DNS 透明代理规则建立失败" ;;
            self_tcp_redirect_failed) MSG="本机 TCP 重定向规则建立失败" ;;
            self_output_hook_failed) MSG="Android OUTPUT 规则挂载失败" ;;
            self_nat_verify_failed) MSG="本机代理规则建立后校验失败" ;;
            *) MSG="本机网络规则建立失败" ;;
          esac
          printf '{"ok":false,"message":"%s"}' "$(json_escape "$MSG")"
          exit 0
        fi
        SELF_APPLIED=1
      fi
      PROXY_SELF=1
      save_config || { proxy_teardown_self_iptables; printf '{"ok":false,"message":"本机代理设置保存失败"}'; exit 0; }
      if [ "$SELF_APPLIED" = "1" ]; then
        if proxy_self_quic_ok; then
          printf '{"ok":true,"message":"手机本机代理已开启"}'
        else
          printf '{"ok":true,"message":"本机 TCP / DNS 代理已开启（QUIC 降级规则不可用）"}'
        fi
      elif proxy_is_running; then
        printf '{"ok":true,"message":"已保存，代理节点就绪后自动生效"}'
      else
        printf '{"ok":true,"message":"已保存，启动科学上网后生效"}'
      fi
    else
      PROXY_SELF=0
      proxy_teardown_self_iptables
      proxy_self_clear_error
      save_config || { printf '{"ok":false,"message":"本机代理设置保存失败"}'; exit 0; }
      printf '{"ok":true,"message":"手机本机代理已关闭"}'
    fi
    ;;
  proxy_set_mode)
    MODE=$(get_param mode)
    case "$MODE" in auto|fallback|manual) : ;; *) printf '{"ok":false,"message":"代理模式无效"}'; exit 0 ;; esac
    if proxy_set_mode "$MODE"; then
      PROXY_MODE="$MODE"
      save_config || { printf '{"ok":false,"message":"模式已切换但保存失败"}'; exit 0; }
      printf '{"ok":true,"message":"模式已切换"}'
    else
      printf '{"ok":false,"message":"模式切换失败"}'
    fi
    ;;
  proxy_set_node)
    NODE_B64=$(get_param node_b64)
    valid_b64url "$NODE_B64" || { printf '{"ok":false,"message":"节点参数无效"}'; exit 0; }
    NODE=$(b64url_decode "$NODE_B64" 2>/dev/null)
    if [ -n "$NODE" ] && proxy_set_node "$NODE"; then
      PROXY_MODE=manual
      save_config >/dev/null 2>&1 || true
      printf '{"ok":true,"message":"节点已切换"}'
    else
      printf '{"ok":false,"message":"节点切换失败"}'
    fi
    ;;
  proxy_update)
    if proxy_is_running; then
      ( trap - EXIT HUP INT TERM; proxy_update_provider >/dev/null 2>&1; proxy_refresh_health >/dev/null 2>&1 ) >/dev/null 2>&1 </dev/null &
      printf '{"ok":true,"message":"正在更新订阅"}'
    else
      printf '{"ok":false,"message":"请先启动科学上网"}'
    fi
    ;;
  proxy_healthcheck)
    if proxy_is_running; then
      ( trap - EXIT HUP INT TERM; proxy_healthcheck >/dev/null 2>&1; sleep 2; proxy_refresh_health >/dev/null 2>&1 ) >/dev/null 2>&1 </dev/null &
      printf '{"ok":true,"message":"正在测速节点"}'
    else
      printf '{"ok":false,"message":"请先启动科学上网"}'
    fi
    ;;  admin_password)
    NEW_ADMIN_B64=$(get_param password)
    valid_b64url "$NEW_ADMIN_B64" || { printf '{"ok":false,"message":"后台密码格式错误"}'; exit 0; }
    NEW_ADMIN=$(b64url_decode "$NEW_ADMIN_B64")
    ADMIN_LEN=$(printf '%s' "$NEW_ADMIN" | "$BB" wc -c | "$BB" tr -d ' ')
    if [ "$ADMIN_LEN" -lt 6 ] || [ "$ADMIN_LEN" -gt 32 ]; then
      printf '{"ok":false,"message":"后台密码需为6–32位"}'
      exit 0
    fi
    case "$NEW_ADMIN" in
      *[!A-Za-z0-9._@!-]*) printf '{"ok":false,"message":"后台密码仅支持字母、数字和 . _ @ ! -"}'; exit 0 ;;
    esac
    HTTP_TMP="$HTTP_CONF.tmp.$$"
    {
      printf '/:admin:%s\n' "$NEW_ADMIN"
      printf '*%s\n' '.cgi:/system/bin/sh'
    } > "$HTTP_TMP"
    chmod 0600 "$HTTP_TMP"
    mv -f "$HTTP_TMP" "$HTTP_CONF"
    printf '{"ok":true,"message":"后台密码已修改，几秒后请使用新密码重新登录"}'
    (
      sleep 2
      HTTP_PID=$(cat "$HTTP_PIDFILE" 2>/dev/null)
      case "$HTTP_PID" in ''|*[!0-9]*) HTTP_PID=0 ;; esac
      if [ "$HTTP_PID" -gt 1 ] && [ -r "/proc/$HTTP_PID/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$HTTP_PID/cmdline" | "$BB" grep -q 'httpd'; then
        kill "$HTTP_PID" 2>/dev/null
      fi
    ) </dev/null >/dev/null 2>&1 &
    ;;
  block)
    MAC=$(get_param mac)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    AP_IFACE=$(get_hotspot_iface)
    case " $BLOCKED_MACS " in *" $MAC "*) : ;; *)
      BLOCKED_MACS=$(printf '%s %s' "$BLOCKED_MACS" "$MAC" | "$BB" sed 's/^ *//; s/ *$//')
      save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
      # P0-43：只 DROP FORWARD（禁止上网），不再 DROP INPUT（避免阻断管理页访问）
      # P1-44：验证规则真正添加，未生效时明确返回“保存但未生效”
      FORWARD_OK=0
      if $IPT -C FORWARD -i "$AP_IFACE" -m mac --mac-source "$MAC" -j DROP 2>/dev/null; then
        FORWARD_OK=1
      else
        $IPT -I FORWARD 1 -i "$AP_IFACE" -m mac --mac-source "$MAC" -j DROP 2>/dev/null && FORWARD_OK=1
      fi
      if [ "$FORWARD_OK" != "1" ]; then
        printf '{"ok":true,"message":"已保存禁止 %s 上网的配置，但防火墙规则添加失败（内核不支持？）"}' "$(json_escape "$MAC")"
        exit 0
      fi
    ;;
    esac
    printf '{"ok":true,"message":"已禁止 %s 上网（设备仍可连接热点，但无法访问网络）"}' "$(json_escape "$MAC")"
    ;;
  unblock)
    MAC=$(get_param mac)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    AP_IFACE=$(get_hotspot_iface)
    unblock_one_mac "$AP_IFACE" "$MAC"
    BLOCKED_MACS=$(printf '%s' "$BLOCKED_MACS" | "$BB" tr ' ' '\n' | "$BB" grep -v "^$MAC$" | "$BB" tr '\n' ' ' | "$BB" sed 's/ *$//')
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"已解除 %s 的禁止上网"}' "$(json_escape "$MAC")"
    ;;
  toggle_whitelist)
    # 白名单模式设备按钮：在名单内 → 移出；不在 → 加入。立即应用规则。
    MAC=$(get_param mac)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    MAC_U=$(printf '%s' "$MAC" | "$BB" tr 'a-f' 'A-F')
    if printf '%s\n' $ALLOWED_MACS | "$BB" grep -qx "$MAC_U" 2>/dev/null; then
      ALLOWED_MACS=$(printf '%s' "$ALLOWED_MACS" | "$BB" tr ' ' '\n' | "$BB" grep -v "^$MAC_U$" | "$BB" tr '\n' ' ' | "$BB" sed 's/ *$//')
      MSG="已移出白名单"
    else
      ALLOWED_MACS=$(printf '%s %s' "$ALLOWED_MACS" "$MAC_U" | "$BB" sed 's/^ *//;s/ *$//')
      MSG="已加入白名单"
    fi
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    AP_IFACE=$(get_hotspot_iface)
    apply_mac_policy "$AP_IFACE" 2>/dev/null
    printf '{"ok":true,"message":"%s"}' "$(json_escape "$MSG")"
    ;;
  clear_whitelist)
    # 清空白名单属危险操作：清空后所有客户端无法上网（前端已二次确认）
    AP_IFACE=$(get_hotspot_iface)
    clear_mac_acl "$AP_IFACE"
    ALLOWED_MACS=
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"白名单已清空（所有客户端将无法上网）"}'
    ;;
  clear_blacklist)
    AP_IFACE=$(get_hotspot_iface)
    clear_blacklist "$AP_IFACE"
    BLOCKED_MACS=
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"黑名单已清空"}'
    ;;
  clear_log)
    : > "$LOG" 2>/dev/null
    chmod 0600 "$LOG"
    printf '{"ok":true,"message":"日志已清空"}'
    ;;
  export_config)
    if [ -r "$CONFIG" ]; then
      # 必须保留换行（转义为 \n），否则导出的内容无法被 import_config 识别
      printf '{"ok":true,"config":"%s"}' "$(json_escape_nl "$(cat "$CONFIG")")"
    else
      printf '{"ok":false,"message":"配置文件不存在"}'
    fi
    ;;
  import_config)
    # 导入字段校验（与 cfg_apply_key 同一套白名单语义；非法值收集后明确提示，不静默默认）
    check_import_value() {
      k=$1; v=$2
      case "$k" in
        AUTOSTART|KEEPALIVE|NOTIFY_LIMIT|SMS_FWD|SCHED_ENABLE|LOWBATT_ENABLE|PROXY_ENABLE|PROXY_BLOCK_QUIC|PROXY_SELF)
          case "$v" in 0|1) return 0 ;; esac ;;
        NOTIFY_TRAFFIC_THRESHOLDS)
          # 1~5 个逗号分隔的 1~100 整数（如 80,90,100）；v1.7.2：拒绝空段（80,,90 / 80,）
          case "$v" in ''|,*|*,|*,,*|*[!0-9,]*) : ;; *)
            N=0; OK=1
            _LIST=$(printf '%s' "$v" | "$BB" tr ',' ' ')
            for T in $_LIST; do
              case "$T" in ''|*[!0-9]*) OK=0; break ;; esac
              if [ "$T" -lt 1 ] || [ "$T" -gt 100 ]; then OK=0; break; fi
              N=$((N+1))
            done
            if [ "$OK" = 1 ] && [ "$N" -ge 1 ] && [ "$N" -le 5 ]; then return 0; fi
            ;;
          esac ;;
        PROXY_ROUTE_MODE) case "$v" in rule|global) return 0 ;; esac ;;
        PROXY_SCOPE) case "$v" in hotspot|self|both) return 0 ;; esac ;;
        PORT) case "$v" in ''|*[!0-9]*) : ;; *) [ "$v" -ge 1024 ] && [ "$v" -le 65535 ] && return 0 ;; esac ;;
        IDLE_SHUTDOWN) valid_idle "$v" && return 0 ;;
        DATA_LIMIT_MB) valid_data_limit "$v" && return 0 ;;
        SCHED_ON|SCHED_OFF|SCHED_ON_WD|SCHED_OFF_WD|SCHED_ON_WE|SCHED_OFF_WE) valid_hhmm "$v" && return 0 ;;
        SCHED_MODE) case "$v" in daily|weekday|weekend) return 0 ;; esac ;;
        LOWBATT_THRESHOLD) case "$v" in ''|*[!0-9]*) : ;; *) [ "$v" -ge 1 ] && [ "$v" -le 100 ] && return 0 ;; esac ;;
        DATA_PLAN_MB) case "$v" in ''|*[!0-9]*) : ;; *) [ "$v" -ge 0 ] && [ "$v" -le 10000000 ] && return 0 ;; esac ;;
        DATA_PLAN_DAY) case "$v" in ''|*[!0-9]*) : ;; *) [ "$v" -ge 1 ] && [ "$v" -le 31 ] && return 0 ;; esac ;;
        DATA_LIMIT_ACTION) case "$v" in notify|stop) return 0 ;; esac ;;
        PROXY_MODE) case "$v" in auto|fallback|manual) return 0 ;; esac ;;
        PROXY_SUB_B64) [ -z "$v" ] || valid_b64url "$v"; return $? ;;
        *) return 0 ;;
      esac
      return 1
    }
    DATA=$(get_param config)
    valid_b64url "$DATA" || { printf '{"ok":false,"message":"配置内容格式错误"}'; exit 0; }
    PLAIN=$(b64url_decode "$DATA")
    # 兼容导出时的字面 \n（JSON 内换行转义），转回真实换行；真实换行原样保留
    PLAIN=$(printf '%s\n' "$PLAIN" | "$BB" awk '{gsub(/\\n/,"\n"); printf "%s\n", $0}')
    TMP_CFG="$CONFIG.import.$$"
    printf '%s\n' "$PLAIN" > "$TMP_CFG"
    # 只允许明确白名单字段（不直接 source 上传内容），逐行读取赋值；
    # 排除含 shell 元字符的任意内容，避免导入任意变量进入运行环境
    ALLOWED='^(AUTOSTART|PORT|KEEPALIVE|IDLE_SHUTDOWN|SCHED_ENABLE|SCHED_ON|SCHED_OFF|SCHED_MODE|SCHED_ON_WD|SCHED_OFF_WD|SCHED_ON_WE|SCHED_OFF_WE|DATA_LIMIT_MB|BLOCKED_MACS|MAC_MODE|ALLOWED_MACS|PUSHPLUS_TOKEN_B64|DINGTALK_WEBHOOK_B64|DINGTALK_SECRET_B64|BARK_KEY_B64|NOTIFY_LIMIT|NOTIFY_TRAFFIC_THRESHOLDS|SMS_FWD|SMS_FWD_KEYWORD_B64|SMS_FWD_SENDERS_B64|LOWBATT_ENABLE|LOWBATT_THRESHOLD|DATA_PLAN_MB|DATA_PLAN_DAY|DATA_LIMIT_ACTION|PROXY_ENABLE|PROXY_SUB_B64|PROXY_MODE|PROXY_BLOCK_QUIC|PROXY_SELF|PROXY_ROUTE_MODE|PROXY_SCOPE)=[^;&|`$\\]*$'
    "$BB" grep -E "$ALLOWED" "$TMP_CFG" > "$TMP_CFG.clean" 2>/dev/null || true
    if [ ! -s "$TMP_CFG.clean" ]; then
      rm -f "$TMP_CFG" "$TMP_CFG.clean"
      printf '{"ok":false,"message":"配置内容无效"}'
      exit 0
    fi
    mv -f "$TMP_CFG.clean" "$TMP_CFG"
    # 逐行白名单解析（不再 source 上传内容，未知键直接跳过；值已被上方正则排除 shell 元字符）
    # 非法值由 check_import_value 收集（导入仍成功，但明确提示哪些字段未生效），不再静默默认
    INVALID_FIELDS=
    while IFS= read -r CFG_LINE; do
      case "$CFG_LINE" in
        ''|'#'*) continue ;;
      esac
      CFG_KEY=${CFG_LINE%%=*}
      CFG_VAL=${CFG_LINE#*=}
      if check_import_value "$CFG_KEY" "$CFG_VAL"; then
        cfg_apply_key "$CFG_KEY" "$CFG_VAL"
      else
        INVALID_FIELDS="$INVALID_FIELDS $CFG_KEY"
      fi
    done < "$TMP_CFG"
    # v1.7.6：热点参数（SSID/密码/频段/信道等）属系统 SoftApConfiguration，导入不涉及；
    # 导入为“合并”语义（未提供字段沿用当前配置），文案明确说明
    save_config || { rm -f "$TMP_CFG"; printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间"}'; exit 0; }
    rm -f "$TMP_CFG"
    if [ -n "$INVALID_FIELDS" ]; then
      printf '{"ok":true,"message":"配置已合并导入并保存；以下字段无效已按旧值保留：%s"}' "$(printf '%s' "$INVALID_FIELDS" | "$BB" sed 's/^ //')"
    else
      printf '{"ok":true,"message":"配置已合并导入并保存"}'
    fi
    ;;
  set_settings)
    NEW_KEEPALIVE=$(get_param keepalive)
    NEW_IDLE=$(get_param idleShutdown)
    NEW_SCHED_EN=$(get_param schedEnable)
    NEW_SCHED_ON=$(get_param schedOn)
    NEW_SCHED_OFF=$(get_param schedOff)
    NEW_SCHED_MODE=$(get_param schedMode)
    NEW_SCHED_ON_WD=$(get_param schedOnWd)
    NEW_SCHED_OFF_WD=$(get_param schedOffWd)
    NEW_SCHED_ON_WE=$(get_param schedOnWe)
    NEW_SCHED_OFF_WE=$(get_param schedOffWe)
    NEW_CHANNEL=$(get_param channel)
    NEW_MAX=$(get_param maxClients)
    NEW_AUTOSTART=$(get_param autostart)
    NEW_DATA_LIMIT=$(get_param dataLimitMb)
    [ -z "$NEW_DATA_LIMIT" ] && NEW_DATA_LIMIT=$(get_param dataPlanMb)
    NEW_PP_B64=$(get_param pushplusTokenB64)
    NEW_DT_B64=$(get_param dingtalkWebhookB64)
    NEW_DT_SEC=$(get_param dingtalkSecretB64)
    NEW_BK=$(get_param barkKey)
    NEW_NL=$(get_param notifyLimit)
    NEW_MM=$(get_param macMode)
    NEW_AM=$(get_param allowedMacs)
    NEW_NTT=$(get_param notifyThresholds)
    NEW_SMS_FWD=$(get_param smsFwd)
    NEW_SMS_KW=$(get_param smsKeywordB64)
    NEW_SMS_SD=$(get_param smsSendersB64)
    NEW_LB_EN=$(get_param lowbattEnable)
    NEW_LB_TH=$(get_param lowbattThreshold)
    NEW_PLAN_MB=$(get_param dataPlanMb)
    NEW_PLAN_DAY=$(get_param dataPlanDay)
    NEW_LIMIT_ACT=$(get_param dataLimitAction)

    case "$NEW_KEEPALIVE" in 0|1) KEEPALIVE=$NEW_KEEPALIVE ;; esac
    # 数值类：请求提供字段即严格校验，非法直接报错（不静默忽略，避免用户误以为已保存）
    if [ -n "$NEW_IDLE" ]; then
      case "$NEW_IDLE" in ''|*[!0-9]*) printf '{"ok":false,"message":"空闲关闭时间需为数字（0或1–600分钟）"}'; exit 0 ;; esac
      valid_idle "$NEW_IDLE" || { printf '{"ok":false,"message":"空闲关闭时间需为0或1–600分钟"}'; exit 0; }
      IDLE_SHUTDOWN=$NEW_IDLE
    fi
    case "$NEW_SCHED_EN" in 0|1) SCHED_ENABLE=$NEW_SCHED_EN ;; esac
    if [ -n "$NEW_SCHED_ON" ]; then
      valid_hhmm "$NEW_SCHED_ON" || { printf '{"ok":false,"message":"开启时间格式错误（HHMM，00:00–23:59）"}'; exit 0; }
      SCHED_ON=$NEW_SCHED_ON
    fi
    if [ -n "$NEW_SCHED_OFF" ]; then
      valid_hhmm "$NEW_SCHED_OFF" || { printf '{"ok":false,"message":"关闭时间格式错误（HHMM，00:00–23:59）"}'; exit 0; }
      SCHED_OFF=$NEW_SCHED_OFF
    fi
    case "$NEW_SCHED_MODE" in daily|weekday|weekend) SCHED_MODE=$NEW_SCHED_MODE ;; esac
    if [ -n "$NEW_SCHED_ON_WD" ]; then
      valid_hhmm "$NEW_SCHED_ON_WD" || { printf '{"ok":false,"message":"工作日开启时间格式错误（HHMM）"}'; exit 0; }
      SCHED_ON_WD=$NEW_SCHED_ON_WD
    fi
    if [ -n "$NEW_SCHED_OFF_WD" ]; then
      valid_hhmm "$NEW_SCHED_OFF_WD" || { printf '{"ok":false,"message":"工作日关闭时间格式错误（HHMM）"}'; exit 0; }
      SCHED_OFF_WD=$NEW_SCHED_OFF_WD
    fi
    if [ -n "$NEW_SCHED_ON_WE" ]; then
      valid_hhmm "$NEW_SCHED_ON_WE" || { printf '{"ok":false,"message":"周末开启时间格式错误（HHMM）"}'; exit 0; }
      SCHED_ON_WE=$NEW_SCHED_ON_WE
    fi
    if [ -n "$NEW_SCHED_OFF_WE" ]; then
      valid_hhmm "$NEW_SCHED_OFF_WE" || { printf '{"ok":false,"message":"周末关闭时间格式错误（HHMM）"}'; exit 0; }
      SCHED_OFF_WE=$NEW_SCHED_OFF_WE
    fi
    # P1-9：定时开启时间不能等于关闭时间（否则会被解释为全天开启）
    if [ -n "$NEW_SCHED_ON" ] || [ -n "$NEW_SCHED_OFF" ]; then
      [ "$SCHED_ON" = "$SCHED_OFF" ] && { printf '{"ok":false,"message":"定时开启与关闭时间不能相同"}'; exit 0; }
    fi
    if [ -n "$NEW_SCHED_ON_WD" ] || [ -n "$NEW_SCHED_OFF_WD" ]; then
      [ "$SCHED_ON_WD" = "$SCHED_OFF_WD" ] && { printf '{"ok":false,"message":"工作日开启与关闭时间不能相同"}'; exit 0; }
    fi
    if [ -n "$NEW_SCHED_ON_WE" ] || [ -n "$NEW_SCHED_OFF_WE" ]; then
      [ "$SCHED_ON_WE" = "$SCHED_OFF_WE" ] && { printf '{"ok":false,"message":"周末开启与关闭时间不能相同"}'; exit 0; }
    fi
    if [ -n "$NEW_CHANNEL" ]; then
      case "$NEW_CHANNEL" in ''|*[!0-9]*) printf '{"ok":false,"message":"信道需为数字（0=自动）"}'; exit 0 ;; esac
      valid_channel "$BAND" "$NEW_CHANNEL" || { printf '{"ok":false,"message":"当前频段下信道不合法（2.4G:1/3/6/9/11/13；5G:36/40/44/48/149/153/157/161/165；自动频段仅支持自动信道0）"}'; exit 0; }
      CHANNEL=$NEW_CHANNEL
    fi
    if [ -n "$NEW_MAX" ]; then
      case "$NEW_MAX" in ''|*[!0-9]*) printf '{"ok":false,"message":"最大连接数需为数字（0–32）"}'; exit 0 ;; esac
      MC_LIMIT=$(get_max_clients_limit)
      valid_max_clients "$NEW_MAX" "$MC_LIMIT" || { printf '{"ok":false,"message":"最大连接数需为0–%s"}' "$MC_LIMIT"; exit 0; }
      MAX_CLIENTS=$NEW_MAX
    fi
    if [ -n "$NEW_DATA_LIMIT" ]; then
      case "$NEW_DATA_LIMIT" in ''|*[!0-9]*) printf '{"ok":false,"message":"流量限额需为数字（MB）"}'; exit 0 ;; esac
      valid_data_limit "$NEW_DATA_LIMIT" || { printf '{"ok":false,"message":"流量限额需为0–10000000 MB（0=关闭）"}'; exit 0; }
      # P0-3(1.5.11)：用户明确提交的限额直接保存（可调小/关闭），
      # 不再取较大值；旧 DATA_LIMIT_MB 的合并只在 1.5.10 迁移时执行一次（见 common.sh check_version_upgrade）
      DATA_PLAN_MB=$NEW_DATA_LIMIT
    fi
    # 通知配置：传空=保持原值（防止误清空已保存凭据）；清除用 clear_notify action
    if [ -n "$NEW_PP_B64" ]; then
      valid_b64url "$NEW_PP_B64" && PUSHPLUS_TOKEN_B64=$NEW_PP_B64
    fi
    if [ -n "$NEW_DT_B64" ]; then
      valid_b64url "$NEW_DT_B64" || { printf '{"ok":false,"message":"钉钉 Webhook 编码格式错误"}'; exit 0; }
      NEW_DT=$(b64url_decode "$NEW_DT_B64")
      NEW_DT=$(printf '%s' "$NEW_DT" | "$BB" tr -d ' \r\n')
      case "$NEW_DT" in
        https://oapi.dingtalk.com/robot/send?access_token=*)
          DINGTALK_WEBHOOK_B64=$(printf '%s' "$NEW_DT" | "$BB" base64 | "$BB" tr -d '=\r\n' | "$BB" tr '+/' '-_') ;;
        *) printf '{"ok":false,"message":"钉钉 Webhook 需为 https://oapi.dingtalk.com/robot/send?access_token=xxx"}'; exit 0 ;;
      esac
    fi
    if [ -n "$NEW_DT_SEC" ]; then
      valid_b64url "$NEW_DT_SEC" || { printf '{"ok":false,"message":"钉钉加签密钥编码格式错误"}'; exit 0; }
      NEW_SEC=$(b64url_decode "$NEW_DT_SEC")
      NEW_SEC=$(printf '%s' "$NEW_SEC" | "$BB" tr -d ' \r\n')
      case "$NEW_SEC" in
        SEC*) DINGTALK_SECRET_B64=$(printf '%s' "$NEW_SEC" | "$BB" base64 | "$BB" tr -d '=\r\n' | "$BB" tr '+/' '-_') ;;
        *) printf '{"ok":false,"message":"钉钉加签密钥需以 SEC 开头（与机器人安全设置一致）"}'; exit 0 ;;
      esac
    fi
    if [ -n "$NEW_BK" ]; then
      valid_b64url "$NEW_BK" || { printf '{"ok":false,"message":"Bark Key 格式错误"}'; exit 0; }
      BARK_KEY_B64=$NEW_BK
    fi
    case "$NEW_NL" in 0|1) NOTIFY_LIMIT=$NEW_NL ;; esac
    case "$NEW_AUTOSTART" in 0|1) AUTOSTART=$NEW_AUTOSTART ;; esac
    case "$NEW_MM" in blacklist|whitelist) MAC_MODE=$NEW_MM ;; esac
    if [ -n "$NEW_AM" ]; then
      for _m in $NEW_AM; do
        valid_mac "$_m" || { printf '{"ok":false,"message":"白名单 MAC 格式错误：%s"}' "$_m"; exit 0; }
      done
      ALLOWED_MACS=$NEW_AM
    fi
    case "$QUERY_STRING" in
      *allowedMacs=*) ALLOWED_MACS=$NEW_AM ;;
    esac
    if [ -n "$NEW_NTT" ]; then
      # v1.7.2：拒绝空段（如 80,,90、80,），与导入校验口径一致
      case "$NEW_NTT" in ,*|*,,*|*,) printf '{"ok":false,"message":"提醒节点格式错误（如 50,80,95）"}'; exit 0 ;; esac
      NTT_CNT=0
      NTT_OUT=
      for NTT_V in $(printf '%s' "$NEW_NTT" | "$BB" tr ',' ' '); do
        case "$NTT_V" in ''|*[!0-9]*) printf '{"ok":false,"message":"提醒节点需为 1-100 的数字，逗号分隔"}'; exit 0 ;; esac
        if [ "$NTT_V" -lt 1 ] || [ "$NTT_V" -gt 100 ]; then
          printf '{"ok":false,"message":"提醒节点需在 1-100 之间"}'; exit 0
        fi
        case " $NTT_OUT " in *" $NTT_V "*) : ;; *) NTT_OUT="${NTT_OUT:+$NTT_OUT,}$NTT_V"; NTT_CNT=$((NTT_CNT+1)) ;; esac
        if [ "$NTT_CNT" -gt 5 ]; then
          printf '{"ok":false,"message":"最多 5 个提醒节点"}'; exit 0
        fi
      done
      [ -z "$NTT_OUT" ] && { printf '{"ok":false,"message":"提醒节点格式错误（如 50,80,95）"}'; exit 0; }
      NOTIFY_TRAFFIC_THRESHOLDS=$NTT_OUT
    fi
    # 短信转发配置：传空=保持原值；清除用 clear_notify action
    case "$NEW_SMS_FWD" in 0|1) SMS_FWD=$NEW_SMS_FWD ;; esac
    if [ -n "$NEW_SMS_KW" ]; then
      valid_b64url "$NEW_SMS_KW" && SMS_FWD_KEYWORD_B64=$NEW_SMS_KW
    fi
    if [ -n "$NEW_SMS_SD" ]; then
      valid_b64url "$NEW_SMS_SD" && SMS_FWD_SENDERS_B64=$NEW_SMS_SD
    fi
    # 低电量提醒：开关 0/1；阈值 1–100 严格校验（请求提供字段即校验，非法直接报错）
    case "$NEW_LB_EN" in 0|1) LOWBATT_ENABLE=$NEW_LB_EN ;; esac
    if [ -n "$NEW_LB_TH" ]; then
      case "$NEW_LB_TH" in ''|*[!0-9]*) printf '{"ok":false,"message":"低电量提醒阈值需为1–100的整数"}'; exit 0 ;; esac
      if [ "$NEW_LB_TH" -ge 1 ] && [ "$NEW_LB_TH" -le 100 ]; then
        LOWBATT_THRESHOLD=$NEW_LB_TH
      else
        printf '{"ok":false,"message":"低电量提醒阈值需为1–100的整数"}'; exit 0
      fi
    fi
    # 手机套餐流量（MB/月，0=不限制；1–10000000）
    if [ -n "$NEW_PLAN_MB" ]; then
      case "$NEW_PLAN_MB" in ''|*[!0-9]*) printf '{"ok":false,"message":"套餐流量需为0–10000000的整数（MB，0=不限制）"}'; exit 0 ;; esac
      if [ "$NEW_PLAN_MB" -ge 0 ] && [ "$NEW_PLAN_MB" -le 10000000 ]; then
        DATA_PLAN_MB=$NEW_PLAN_MB
      else
        printf '{"ok":false,"message":"套餐流量需为0–10000000的整数（MB，0=不限制）"}'; exit 0
      fi
    fi
    # 账期起始日（每月 N 日，1–31）
    if [ -n "$NEW_PLAN_DAY" ]; then
      case "$NEW_PLAN_DAY" in ''|*[!0-9]*) printf '{"ok":false,"message":"账期起始日需为数字（1–31）"}'; exit 0 ;; esac
      if [ "$NEW_PLAN_DAY" -ge 1 ] && [ "$NEW_PLAN_DAY" -le 31 ]; then
        DATA_PLAN_DAY=$NEW_PLAN_DAY
      else
        printf '{"ok":false,"message":"账期起始日需为1–31"}'; exit 0
      fi
    fi
    case "$NEW_LIMIT_ACT" in notify|stop) DATA_LIMIT_ACTION=$NEW_LIMIT_ACT ;; esac
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"设置已保存（信道与最大连接数下次重启热点时生效）"}'
    ;;
  clear_notify)
    # 清除已保存的通知/短信配置字段：field=pp|dt|dtsec|smskw|smssd
    FIELD=$(get_param field)
    case "$FIELD" in
      pp) PUSHPLUS_TOKEN_B64= ;;
      dt) DINGTALK_WEBHOOK_B64= ;;
      dtsec) DINGTALK_SECRET_B64= ;;
      smskw) SMS_FWD_KEYWORD_B64= ;;
      smssd) SMS_FWD_SENDERS_B64= ;;
      bk) BARK_KEY_B64= ;;
      *) printf '{"ok":false,"message":"未知字段"}'; exit 0 ;;
    esac
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"已清除"}'
    ;;
  test_notify)
    # 向已配置渠道发测试消息，反馈各渠道结果；全部失败返回 ok:false + 具体错误原因
    load_config
    MSG="这是一条来自热点管理模块的测试通知
时间: $(/system/bin/date '+%m-%d %H:%M')"
    PP_RC=2
    DT_RC=2
    PUSHPLUS_LAST_ERR=
    DINGTALK_LAST_ERR=
    send_pushplus "测试通知" "$MSG"
    PP_RC=$?
    send_dingtalk "【测试通知】 $MSG"
    DT_RC=$?
    BARK_LAST_ERR=
    send_bark "测试通知" "$MSG"
    BK_RC=$?
    case "$PP_RC" in
      0) PP_TXT=成功 ;;
      1) PP_TXT="失败（${PUSHPLUS_LAST_ERR:-未知错误}）" ;;
      *) PP_TXT=未配置 ;;
    esac
    case "$DT_RC" in
      0) DT_TXT=成功 ;;
      1) DT_TXT="失败（${DINGTALK_LAST_ERR:-未知错误}）" ;;
      *) DT_TXT=未配置 ;;
    esac
    case "$BK_RC" in
      0) BK_TXT=成功 ;;
      1) BK_TXT="失败（${BARK_LAST_ERR:-未知错误}）" ;;
      *) BK_TXT=未配置 ;;
    esac
    if [ "$PP_RC" -eq 0 ] || [ "$DT_RC" -eq 0 ] || [ "$BK_RC" -eq 0 ]; then
      printf '{"ok":true,"message":"测试通知: PushPlus %s；钉钉 %s；Bark %s"}' "$(json_escape "$PP_TXT")" "$(json_escape "$DT_TXT")" "$(json_escape "$BK_TXT")"
    else
      printf '{"ok":false,"message":"测试通知发送失败: PushPlus %s；钉钉 %s；Bark %s"}' "$(json_escape "$PP_TXT")" "$(json_escape "$DT_TXT")" "$(json_escape "$BK_TXT")"
    fi
    ;;

  test_lowbatt)
    # 发送低电量测试提醒（复用已配置渠道；不改变自动提醒的 armed/attempted 状态）
    load_config
    get_battery_cached
    case "$BATTERY" in ''|*[!0-9]*) BATTERY=-- ;; esac
    MSG="当前电量 $BATTERY%（提醒阈值 ${LOWBATT_THRESHOLD:-20}%）。这是一条低电量提醒测试消息。
时间: $(/system/bin/date '+%m-%d %H:%M')"
    PP_RC=2
    DT_RC=2
    PUSHPLUS_LAST_ERR=
    DINGTALK_LAST_ERR=
    send_pushplus "热点低电量提醒测试" "$MSG"
    PP_RC=$?
    send_dingtalk "【热点低电量提醒测试】 $MSG"
    DT_RC=$?
    case "$PP_RC" in
      0) PP_TXT=成功 ;;
      1) PP_TXT="失败（${PUSHPLUS_LAST_ERR:-未知错误}）" ;;
      *) PP_TXT=未配置 ;;
    esac
    case "$DT_RC" in
      0) DT_TXT=成功 ;;
      1) DT_TXT="失败（${DINGTALK_LAST_ERR:-未知错误}）" ;;
      *) DT_TXT=未配置 ;;
    esac
    if [ "$PP_RC" -eq 0 ] || [ "$DT_RC" -eq 0 ]; then
      printf '{"ok":true,"message":"低电量测试提醒: PushPlus %s；钉钉 %s"}' "$(json_escape "$PP_TXT")" "$(json_escape "$DT_TXT")"
    else
      printf '{"ok":false,"message":"低电量测试提醒发送失败: PushPlus %s；钉钉 %s"}' "$(json_escape "$PP_TXT")" "$(json_escape "$DT_TXT")"
    fi
    ;;

  get_password)
    # 仅在登录 + CSRF 校验通过后返回热点密码明文（状态接口不回传密码）
    # v1.7.6：密码属系统 SoftApConfiguration，从系统读取（唯一数据源）
    hotspot_get_config
    if [ "$sys_ok" != "1" ] || [ -z "$sys_password" ]; then
      printf '{"ok":true,"password":"","message":"开放网络无密码"}'
      exit 0
    fi
    printf '{"ok":true,"password":"%s","message":"当前密码已显示（8秒后自动隐藏）"}' "$(json_escape "$sys_password")"
    ;;
  kick)
    MAC=$(get_param mac)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    AP_IFACE=$(get_hotspot_iface)
    if [ -z "$AP_IFACE" ]; then
      printf '{"ok":false,"message":"热点未运行"}'
      exit 0
    fi
    KIP=$(list_clients "$AP_IFACE" | "$BB" awk -F'|' -v m="$MAC" '$2==m{print $1; exit}')
    if [ -z "$KIP" ]; then
      printf '{"ok":false,"message":"该设备当前不在线"}'
      exit 0
    fi
    IN_BLOCKED=false
    case " $BLOCKED_MACS " in *" $MAC "*) IN_BLOCKED=true ;; esac
    # 1) 删除邻居表项强制断开；2) 临时 DROP 15 秒防立即重连（不持久化，区别于拉黑）
    /system/bin/ip neigh del "$KIP" dev "$AP_IFACE" 2>/dev/null
    # P0-43：临时断网也只 DROP FORWARD，不阻断设备访问管理页
    $IPT -C FORWARD -i "$AP_IFACE" -m mac --mac-source "$MAC" -j DROP 2>/dev/null || \
      $IPT -I FORWARD 1 -i "$AP_IFACE" -m mac --mac-source "$MAC" -j DROP 2>/dev/null
    printf '%s kick: %s %s\n' "$(date)" "$KIP" "$MAC" >> "$LOG"
    printf '{"ok":true,"message":"已暂停 %s 上网15秒（不会断开Wi-Fi连接）"}' "$(json_escape "$MAC")"
    (
      sleep 15
      # 已在黑名单中的设备不删除规则，避免误解除拉黑
      if [ "$IN_BLOCKED" != "true" ]; then
        $IPT -D FORWARD -i "$AP_IFACE" -m mac --mac-source "$MAC" -j DROP 2>/dev/null
      fi
      printf '%s kick: temporary drop expired for %s\n' "$(date)" "$MAC" >> "$LOG"
    ) </dev/null >/dev/null 2>&1 &
    ;;
  set_port)
    NEW_PORT=$(get_param port)
    case "$NEW_PORT" in
      ''|*[!0-9]*) printf '{"ok":false,"message":"端口格式错误"}'; exit 0 ;;
      *) [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ] || { printf '{"ok":false,"message":"端口需在1024–65535之间"}'; exit 0; } ;;
    esac
    PORT=$NEW_PORT
    save_config || { printf '{"ok":false,"message":"配置写入失败，请检查磁盘空间或稍后重试"}'; exit 0; }
    printf '{"ok":true,"message":"端口已保存为 %s，Web 服务正在切换到新端口"}' "$PORT"
    # v1.7.2：切换端口 = 按新端口刷新防火墙（清理旧端口规则）→ 重启 httpd/supervisor，
    # 由 service.sh 以新端口拉起 httpd；前端轮询新端口就绪后跳转。
    (
      sleep 2
      load_config
      ensure_web_fw
      HTTP_PID=$(cat "$HTTP_PIDFILE" 2>/dev/null)
      case "$HTTP_PID" in ''|*[!0-9]*) HTTP_PID=0 ;; esac
      if [ "$HTTP_PID" -gt 1 ] && [ -r "/proc/$HTTP_PID/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$HTTP_PID/cmdline" | "$BB" grep -q 'httpd'; then
        kill "$HTTP_PID" 2>/dev/null
      fi
      SUP=$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null)
      case "$SUP" in ''|*[!0-9]*) SUP=0 ;; esac
      [ "$SUP" -gt 1 ] && kill "$SUP" 2>/dev/null
      sleep 1
      nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    ) </dev/null >/dev/null 2>&1 &
    ;;
  restart_module)
    printf '{"ok":true,"message":"模块服务即将重启，页面将短暂中断，请稍后刷新"}'
    (
      sleep 1
      HTTP_PID=$(cat "$HTTP_PIDFILE" 2>/dev/null)
      case "$HTTP_PID" in ''|*[!0-9]*) HTTP_PID=0 ;; esac
      if [ "$HTTP_PID" -gt 1 ] && [ -r "/proc/$HTTP_PID/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$HTTP_PID/cmdline" | "$BB" grep -q 'httpd'; then
        kill "$HTTP_PID" 2>/dev/null
      fi
      SUP=$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null)
      case "$SUP" in ''|*[!0-9]*) SUP=0 ;; esac
      [ "$SUP" -gt 1 ] && kill "$SUP" 2>/dev/null
      sleep 1
      nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    ) </dev/null >/dev/null 2>&1 &
    ;;
  reset_usage)
    reset_usage
    rm -f "$PLAN_TH_MARK"
    printf '{"ok":true,"message":"流量累计已清零，账期提醒将重新计算"}'
    ;;
  set_rate_limit)
    MAC=$(get_param mac)
    RATE=$(get_param rate)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    case "$RATE" in ''|*[!0-9]*) printf '{"ok":false,"message":"限速值格式错误"}'; exit 0 ;; esac
    if [ "$RATE" -ne 0 ] && { [ "$RATE" -lt 32 ] || [ "$RATE" -gt 1000000 ]; }; then
      printf '{"ok":false,"message":"限速需在32–1000000 Kbps（0=解除）"}'
      exit 0
    fi
    write_rate_limit "$MAC" "$RATE"
    AP_IFACE=$(get_hotspot_iface)
    if [ -n "$AP_IFACE" ]; then
      TC=$(find_tc)
      if [ -z "$TC" ]; then
        printf '{"ok":true,"message":"限速配置已保存，但设备上未找到 tc 工具，热点开启后仍不会生效"}'
        exit 0
      fi
      clear_rate_limits_all "$AP_IFACE"
      if apply_rate_limits "$AP_IFACE"; then
        APPLIED_MSG="（已应用到当前热点，仅限下行速度）"
      else
        APPLIED_MSG="（已保存，但应用失败：内核可能不支持 tc）"
      fi
    else
      APPLIED_MSG="（已保存，热点开启后生效）"
    fi
    if [ "$RATE" -eq 0 ]; then
      printf '{"ok":true,"message":"已解除限速 %s%s"}' "$(json_escape "$MAC")" "$APPLIED_MSG"
    else
      printf '{"ok":true,"message":"已限速 %s（下行 %s Kbps，实验性功能）%s"}' "$(json_escape "$MAC")" "$RATE" "$APPLIED_MSG"
    fi
    ;;
  del_history)
    MAC=$(get_param mac)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    # 删除单条历史：known_macs、备注、客户端统计（首见/最近/在线时长）、客户端流量累计
    TMP_H="$KNOWN_MACS.tmp.$$"
    "$BB" grep -v "^$MAC$" "$KNOWN_MACS" 2>/dev/null > "$TMP_H" || : > "$TMP_H"
    mv -f "$TMP_H" "$KNOWN_MACS" 2>/dev/null
    TMP_H="$DEVICE_NOTES.tmp.$$"
    "$BB" grep -v "^$MAC|" "$DEVICE_NOTES" 2>/dev/null > "$TMP_H" || : > "$TMP_H"
    mv -f "$TMP_H" "$DEVICE_NOTES" 2>/dev/null
    TMP_H="$CLIENT_STATS_FILE.tmp.$$"
    "$BB" grep -v "^$MAC|" "$CLIENT_STATS_FILE" 2>/dev/null > "$TMP_H" || : > "$TMP_H"
    mv -f "$TMP_H" "$CLIENT_STATS_FILE" 2>/dev/null
    TMP_H="$CLIENT_USAGE_FILE.tmp.$$"
    "$BB" grep -v "^$MAC|" "$CLIENT_USAGE_FILE" 2>/dev/null > "$TMP_H" || : > "$TMP_H"
    mv -f "$TMP_H" "$CLIENT_USAGE_FILE" 2>/dev/null
    printf '{"ok":true,"message":"已删除 %s 的历史记录"}' "$(json_escape "$MAC")"
    ;;
  clear_history)
    : > "$KNOWN_MACS" 2>/dev/null
    : > "$DEVICE_NOTES" 2>/dev/null
    : > "$CLIENT_STATS_FILE" 2>/dev/null
    : > "$CLIENT_USAGE_FILE" 2>/dev/null
    printf '{"ok":true,"message":"历史设备已清空"}'
    ;;
  set_note)
    MAC=$(get_param mac)
    NOTE_B64=$(get_param note)
    valid_mac "$MAC" || { printf '{"ok":false,"message":"MAC 地址格式错误"}'; exit 0; }
    # 留空=清除备注（不再经 valid_b64url 拒绝空值）
    NOTE=
    if [ -n "$NOTE_B64" ]; then
      valid_b64url "$NOTE_B64" || { printf '{"ok":false,"message":"备注格式错误"}'; exit 0; }
      NOTE=$(b64url_decode "$NOTE_B64")
    fi
    case "$NOTE" in
      *[[:cntrl:]]*) printf '{"ok":false,"message":"备注包含控制字符"}'; exit 0 ;;
    esac
    # 长度口径统一：24 个字符以内；同时按 UTF-8 字节数兜底（72 字节），避免 locale/emoji 代理对差异
    NOTE_BYTES=$(printf '%s' "$NOTE" | "$BB" wc -c 2>/dev/null | "$BB" tr -d ' ' 2>/dev/null || printf '%s' "$NOTE" | wc -c)
    case "$NOTE_BYTES" in ''|*[!0-9]*) NOTE_BYTES=0 ;; esac
    if [ "${#NOTE}" -gt 24 ] || [ "$NOTE_BYTES" -gt 72 ]; then
      printf '{"ok":false,"message":"备注最多24个字符（约72字节）"}'
      exit 0
    fi
    set_device_note "$MAC" "$NOTE"
    if [ -n "$NOTE" ]; then
      printf '{"ok":true,"message":"已保存备注 %s → %s"}' "$(json_escape "$MAC")" "$(json_escape "$NOTE")"
    else
      printf '{"ok":true,"message":"已清除 %s 的备注"}' "$(json_escape "$MAC")"
    fi
    ;;
  sms_list)
    # 最近 20 条收件短信（供页面查看；转发与否不影响此列表）
    # P1-90：默认脱敏（不返回正文），full=1 且通过后台密码二次验证后才返回完整正文
    SMS_FULL=$(get_param full)
    # P2-10(1.5.11)：full=1（返回完整正文）必须通过后台密码二次验证；
    # 防止后台密码泄露时短信正文（含验证码）被直接读取。
    if [ "$SMS_FULL" = "1" ]; then
      PW_B64=$(get_param pw)
      valid_b64url "$PW_B64" || { printf '{"ok":false,"message":"查看完整正文需输入后台密码"}'; exit 0; }
      PW=$(b64url_decode "$PW_B64")
      CUR_PASS=$(read_admin_password)
      if [ -z "$CUR_PASS" ] || [ "$PW" != "$CUR_PASS" ]; then
        printf '{"ok":false,"message":"后台密码错误"}'
        exit 0
      fi
    fi
    OUT=$($CONTENT_CMD query --uri content://sms --projection _id:address:body:date --where "type=1" 2>/dev/null | "$BB" tail -n 20)
    # 注意：不要在 $(...) 内写 while+case（case 的 ) 会干扰 $() 闭合计数，bash 语法错误）
    SMS_TMP="$DATA_DIR/.sms_list.$$"
    : > "$SMS_TMP"
    printf '%s\n' "$OUT" | while IFS= read -r LINE; do
      ID=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=\([0-9]*\).*/\1/p')
      ADDR=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=[0-9]*, address=\([^,]*\),.*/\1/p')
      BODY=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* _id=[0-9]*, address=[^,]*, body=\(.*\), date=[0-9]*.*/\1/p')
      DATE=$(printf '%s\n' "$LINE" | "$BB" sed -n 's/^Row: [0-9]* .*date=\([0-9]*\).*/\1/p')
      case "$ID" in ''|*[!0-9]*) continue ;; esac
      DATE_TXT=
      case "$DATE" in ''|*[!0-9]*) : ;; *)
        DATE_TXT=$($DATE_CMD -d "@$((DATE / 1000))" '+%m-%d %H:%M' 2>/dev/null || $DATE_CMD '+%m-%d %H:%M')
      ;; esac
      if [ "$SMS_FULL" = "1" ]; then
        BODY_SHOWN=$BODY
      else
        BODY_SHOWN="（已隐藏，点击查看需验证后台密码）"
      fi
      printf '{"id":%s,"from":"%s","body":"%s","date":"%s"}\n' "$ID" "$(json_escape "$ADDR")" "$(json_escape "$BODY_SHOWN")" "$(json_escape "$DATE_TXT")" >> "$SMS_TMP"
    done
    ITEMS=$("$BB" paste -sd ',' "$SMS_TMP" 2>/dev/null)
    rm -f "$SMS_TMP"
    printf '{"ok":true,"sms":[%s]}' "$ITEMS"
    ;;
  *)
    printf '{"ok":false,"message":"未知操作"}'
    ;;
esac
