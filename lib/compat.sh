#!/system/bin/sh
# ============================================================
# Hotspot Compatibility Layer —— 通用 Android 热点兼容层
#
# 架构原则（v1.7.6 起）：
#   1) 不针对品牌 / ROM / Android 版本写死实现；一律运行时能力检测。
#   2) 系统 SoftApConfiguration 是唯一数据源，Web 与系统设置共用同一份。
#      - 读：优先 Framework（IWifiManager.getSoftApConfiguration，Binder Bridge），
#           失败时降级只读解析 WifiConfigStore.xml（仅作兼容 fallback）。
#      - 写：必须走 Framework（IWifiManager.setSoftApConfiguration →
#           WifiApConfigStore.setApConfiguration 系统持久化），经 root Binder Bridge 调用。
#           禁止直接改写 WifiConfigStore.xml（内存配置不更新、会被系统写回覆盖），
#           禁止把 cmd wifi start-softap <参数> 当持久化接口（那只是临时启动配置）。
#      - 启动/停止：cmd wifi start-softap（无参）/ stop-softap，与系统设置行为一致。
#   3) 模块 config.conf 不再保存 SSID/密码/安全类型/频段/信道/隐藏/最大连接数；
#      这些参数属于 Android 系统，属于模块的是保活/定时/流量/通知/Mihomo/MAC 等。
#   4) 上层（control.cgi / status.cgi / service.sh / 前端）只调用本文件
#      定义的统一接口，禁止直接执行 cmd wifi / 直接读系统 XML。
#
# 统一接口（7 个）：
#   hotspot_get_capabilities  能力清单 JSON（前端据此动态显示）
#   hotspot_get_config        读取系统热点配置 → sys_ssid/sys_security/... 变量
#   hotspot_set_config        修改系统热点配置（Framework 持久化，失败返回 1）
#   hotspot_get_state         读取热点运行状态
#   hotspot_start             启动热点（无参，用系统已保存配置）
#   hotspot_stop              停止热点
#   hotspot_restart           重启热点
#
# Binder Bridge（lib/softap_bridge.dex，API 30+）：
#   app_process -Djava.class.path=$BRIDGE_DEX /system/bin com.mifi.softap.SoftApBridge \
#       get | set <ssid> <sec> <pass> <band> <channel> <hidden> <maxclients>
# ============================================================

# 能力检测结果缓存（status/UI 复用；检测一次即可）
HOTSPOT_CAPS_JSON=

# Binder Bridge 路径（可被测试覆盖为 mock）
APP_PROCESS=${APP_PROCESS:-/system/bin/app_process}
BRIDGE_DEX="$MODDIR/lib/softap_bridge.dex"

bridge_available() {
  [ -x "$APP_PROCESS" ] && [ -s "$BRIDGE_DEX" ]
}

# ---- 能力检测：一次解析，输出 HOTSPOT_CAPS_JSON ----
hotspot_detect_capabilities() {
  # Android API Level（ro.build.version.sdk）
  API=$("$BB" getprop ro.build.version.sdk 2>/dev/null | "$BB" tr -d ' \r\n')
  case "$API" in ''|*[!0-9]*) API=0 ;; esac

  # cmd wifi 可用性与 start-softap / stop-softap 子命令
  START_SOFTAP=0; STOP_SOFTAP=0; START_USAGE=
  if command -v "$CMD_WIFI" >/dev/null 2>&1; then
    CMD_HELP=$("$CMD_WIFI" wifi help 2>/dev/null)
    case "$CMD_HELP" in *start-softap*) START_SOFTAP=1 ;; esac
    case "$CMD_HELP" in *stop-softap*) STOP_SOFTAP=1 ;; esac
    START_USAGE=$(printf '%s' "$CMD_HELP" | "$BB" grep -m1 'start-softap' 2>/dev/null)
  fi

  # 参数能力（仅从 start-softap 用法行解析，避免其他 help 文本干扰）
  HIDDEN_OK=0; CH_CTL=0; MAX_CTL=0; BAND_2G=0; BAND_5G=0; BAND_6G=0
  if [ "$START_SOFTAP" = "1" ]; then
    case "$START_USAGE" in *'-h'*) HIDDEN_OK=1 ;; esac
    case "$START_USAGE" in *'-c'*) CH_CTL=1 ;; esac
    case "$START_USAGE" in *'-m'*) MAX_CTL=1 ;; esac
    case "$START_USAGE" in *'-b'*) BAND_2G=1; BAND_5G=1 ;; esac
    case "$START_USAGE" in *'6'*) BAND_6G=1 ;; esac
  fi

  # 系统配置读写能力：
  #   读：Binder Bridge 优先（Framework 真实值），XML 只读为兼容 fallback
  #   写：必须 Binder Bridge（Framework 持久化），XML 可写不再视为写能力
  READ_CFG=0; WRITE_CFG=0
  if bridge_available && [ "$API" -ge 30 ] 2>/dev/null; then
    READ_CFG=1; WRITE_CFG=1
  elif [ -r "$SYS_WIFI_STORE" ]; then
    READ_CFG=1
  fi

  # 同步级别：A=完整读写（系统↔Web 双向同步）；B=只读；C=无系统配置能力（仅开关/状态）
  SYNC_LEVEL=C
  [ "$READ_CFG" = "1" ] && SYNC_LEVEL=B
  [ "$WRITE_CFG" = "1" ] && SYNC_LEVEL=A

  HOTSPOT_CAPS_JSON=$(printf '{"android":%s,"startStop":%s,"readConfig":%s,"writeConfig":%s,"band2g":%s,"band5g":%s,"band6g":%s,"hiddenSsid":%s,"channelControl":%s,"maxClients":%s,"syncLevel":"%s"}' \
    "$API" \
    "$([ "$START_SOFTAP" = "1" ] && echo true || echo false)" \
    "$([ "$READ_CFG" = "1" ] && echo true || echo false)" \
    "$([ "$WRITE_CFG" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_2G" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_5G" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_6G" = "1" ] && echo true || echo false)" \
    "$([ "$HIDDEN_OK" = "1" ] && echo true || echo false)" \
    "$([ "$CH_CTL" = "1" ] && echo true || echo false)" \
    "$([ "$MAX_CTL" = "1" ] && echo true || echo false)" \
    "$SYNC_LEVEL")
}

# ---- 接口 1：能力清单 ----
hotspot_get_capabilities() {
  [ -n "$HOTSPOT_CAPS_JSON" ] || hotspot_detect_capabilities
  printf '%s' "$HOTSPOT_CAPS_JSON"
}

# ---- Binder Bridge：从 Framework 读取系统 SoftApConfiguration ----
# 成功时设置 sys_ssid/sys_security/sys_password/sys_band/sys_channel/sys_hidden/sys_maxclients/sys_ok
# 返回 0：bridge 运行成功（present=0 表示系统尚未配置热点，sys_ok=0）；1：bridge 不可用/失败
sys_bridge_get() {
  sys_ok=0
  sys_ssid=; sys_security=wpa2; sys_password=; sys_band=any; sys_channel=0; sys_hidden=0; sys_maxclients=0
  bridge_available || return 1
  OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge get 2>/dev/null)
  [ -n "$OUT" ] || return 1
  PRESENT=0
  while IFS= read -r LINE; do
    case "$LINE" in
      present=*) PRESENT=${LINE#present=} ;;
      ssid_b64=*) sys_ssid=$(b64url_decode "${LINE#ssid_b64=}") ;;
      security=*) sys_security=${LINE#security=} ;;
      password_b64=*) sys_password=$(b64url_decode "${LINE#password_b64=}") ;;
      band=*) sys_band=${LINE#band=} ;;
      channel=*) sys_channel=${LINE#channel=} ;;
      hidden=*) sys_hidden=${LINE#hidden=} ;;
      maxclients=*) sys_maxclients=${LINE#maxclients=} ;;
    esac
  done <<EOF
$OUT
EOF
  [ "$PRESENT" = "1" ] && [ -n "$sys_ssid" ] && sys_ok=1
  return 0
}

# ---- Binder Bridge：调用 Framework setSoftApConfiguration（系统持久化）----
# 返回 0 成功；非 0 失败（调用方必须明确报错，禁止回退到第二套配置）
sys_bridge_set() {
  bridge_available || return 1
  "$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge set \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >/dev/null 2>&1
}

# ---- 接口 2：读取系统热点配置（变量见 sys_softap_get / sys_bridge_get）----
# 优先 Framework（真实内存配置）；bridge 不可用时降级只读解析 WifiConfigStore.xml。
hotspot_get_config() {
  if sys_bridge_get; then
    return 0
  fi
  sys_softap_get
  return 0
}

# 系统是否已存在 SoftAp 配置（读路径与 hotspot_get_config 一致）
hotspot_config_present() {
  hotspot_get_config
  [ "$sys_ok" = "1" ] && [ -n "$sys_ssid" ]
}

# ---- 接口 3：修改系统热点配置（ssid security password band channel hidden maxclients）----
# 必须走 Framework：IWifiManager.setSoftApConfiguration() → WifiApConfigStore.setApConfiguration()
# 系统持久化（经 Binder Bridge）。cmd wifi start-softap <参数> 只是临时启动配置，禁止当持久化接口。
# 密码传空 = 保留系统当前密码；security=open = 清空密码。
# 热点开启中 → 先持久化新配置，再无参重启热点（新配置立即生效并保持开启）；
# 热点关闭时 → 仅持久化配置（不改变用户希望的关闭状态）。
# 返回 0 成功；1 失败（调用方必须明确报错，禁止回退到第二套配置）。
hotspot_set_config() {
  NEW_SSID=$1; NEW_SEC=$2; NEW_PASS=$3; NEW_BAND=$4; NEW_CHANNEL=$5; NEW_HIDDEN=$6; NEW_MAX=$7
  [ -n "$NEW_SSID" ] || { echo "$(date) hotspot_set_config: empty ssid" >> "$LOG" 2>/dev/null; return 1; }
  case "$NEW_BAND" in 2|5|6|any) : ;; *) NEW_BAND=any ;; esac
  case "$NEW_SEC" in open|wpa2|wpa3|wpa3_transition) : ;; *) NEW_SEC=wpa2 ;; esac
  case "$NEW_CHANNEL" in ''|*[!0-9]*) NEW_CHANNEL=0 ;; esac
  case "$NEW_MAX" in ''|*[!0-9]*) NEW_MAX=0 ;; esac
  case "$NEW_HIDDEN" in 1|true|on) NEW_HIDDEN=1 ;; *) NEW_HIDDEN=0 ;; esac

  # 密码留空且非 open → 沿用系统当前密码（Framework 优先，XML 只读兜底）
  if [ -z "$NEW_PASS" ] && [ "$NEW_SEC" != "open" ]; then
    hotspot_get_config
    NEW_PASS=$sys_password
  fi
  [ "$NEW_SEC" = "open" ] && NEW_PASS=

  # 当前热点是否开启
  softap_state_snapshot 2>/dev/null
  WAS_ON=0
  [ "$SNAP_AP_STATE" = "ENABLED" ] && WAS_ON=1
  if [ "$WAS_ON" = "1" ]; then
    "$CMD_WIFI" wifi stop-softap >/dev/null 2>&1
    sleep 1
  fi

  # Framework 持久化（Binder Bridge；API<30 或无 app_process 时明确失败）
  if ! sys_bridge_set "$NEW_SSID" "$NEW_SEC" "$NEW_PASS" "$NEW_BAND" "$NEW_CHANNEL" "$NEW_HIDDEN" "$NEW_MAX"; then
    echo "$(date) hotspot_set_config: setSoftApConfiguration failed (bridge unavailable or API rejected)" >> "$LOG" 2>/dev/null
    return 1
  fi

  # 原状态为开启 → 无参重启热点，使新配置生效并保持开启
  if [ "$WAS_ON" = "1" ]; then
    "$CMD_WIFI" wifi start-softap >/dev/null 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
      echo "$(date) hotspot_set_config: config saved but restart failed rc=$RC" >> "$LOG" 2>/dev/null
      return 1
    fi
  fi
  return 0
}

# ---- 接口 4：热点运行状态（复用 softap_state_snapshot）----
hotspot_get_state() {
  softap_state_snapshot "$@"
}

# ---- 接口 5：启动热点（无参，用系统已保存 SoftApConfiguration）----
# 与系统"设置"应用开启热点行为一致。系统从未配置热点时，run_softap 内部会用模块旧参数
# 经 Framework 持久化一次完成迁移（见 lib/common.sh run_softap）。
hotspot_start() {
  if command -v "$CMD_WIFI" >/dev/null 2>&1 && "$CMD_WIFI" wifi help 2>/dev/null | grep -q 'start-softap'; then
    run_softap "$@"
    return $?
  fi
  # Backend B：旧系统 / 命令缺失 —— 仅启停，参数无法传递（Level C 降级）
  echo "$(date) hotspot_start: cmd wifi start-softap unavailable, using connectivity tether" >> "$LOG" 2>/dev/null
  "$CMD_WIFI" connectivity tether start 2>/dev/null
  return $?
}

# ---- 接口 6：停止热点 ----
hotspot_stop() {
  stop_hotspot_real
  return $?
}

# ---- 接口 7：重启热点（完整 停止→启动）----
hotspot_restart() {
  stop_hotspot_real >/dev/null 2>&1
  sleep 2
  hotspot_start "$@"
  return $?
}
