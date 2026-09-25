#!/system/bin/sh
# ============================================================
# Hotspot Compatibility Layer —— 通用 Android 热点兼容层（v1.7.6-rc2）
#
# 架构原则：
#   1) 不针对品牌 / ROM / Android 版本写死实现；一律运行时能力检测（probe 实测）。
#   2) 系统 SoftApConfiguration 是唯一数据源，Web 与系统设置共用同一份。
#      - 读：Binder Bridge 调 IWifiManager.getSoftApConfiguration（真实内存配置），
#            失败降级只读解析 WifiConfigStore.xml（兼容 fallback）。
#      - 写：Binder Bridge 调 IWifiManager.setSoftApConfiguration(config, packageName)
#            → WifiApConfigStore.setApConfiguration() 系统持久化（与设置应用同一路径）。
#            禁止直接改写 WifiConfigStore.xml；禁止把 cmd wifi start-softap <参数>
#            当持久化接口（AOSP 中它只构造临时配置调 startTetheredHotspot 启动）。
#      - 开关：Generic Backend = 系统 Tethering（cmd connectivity tether start/stop，
#            内部即 ConnectivityManager/TetheringManager.startTethering，与 Settings 一致）；
#            cmd wifi start-softap 仅作为 capability 验证后的 OEM/老系统 fallback。
#   3) 模块 config.conf 不再保存 SSID/密码/安全/频段/信道/隐藏/最大连接数。
#   4) 上层只调用本文件统一接口，禁止直接执行 cmd wifi / 直接读系统 XML。
#
# 统一接口（7 个）：
#   hotspot_get_capabilities / hotspot_get_config / hotspot_set_config /
#   hotspot_get_state / hotspot_start / hotspot_stop / hotspot_restart
#
# Binder Bridge（lib/softap_bridge.dex，API 30+）：
#   app_process -Djava.class.path=$BRIDGE_DEX /system/bin com.mifi.softap.SoftApBridge \
#       get-config | set-config <ssid> <sec> <pass> <band> <channel> <hidden> <max> \
#       | tether-state | probe
# ============================================================

# 能力检测结果缓存（status/UI 复用；检测一次即可）
HOTSPOT_CAPS_JSON=
# v1.7.9：能力/状态缓存（supervisor 预热；status.cgi 只读，避免每次请求起 app_process/dumpsys）
CAPS_CACHE_FILE="${DATA_DIR:-}/hotspot_caps.cache"
STATE_CACHE_FILE="${DATA_DIR:-}/system_hotspot.cache"
CONFIG_CACHE_FILE="${DATA_DIR:-}/hotspot_config.cache"
HOTSPOT_IFACE_FILE="${DATA_DIR:-}/hotspot_iface.cache"
CAPS_CACHE_TTL=600

# Binder Bridge 路径（可被测试覆盖为 mock）
APP_PROCESS=${APP_PROCESS:-/system/bin/app_process}
BRIDGE_DEX="$MODDIR/lib/softap_bridge.dex"

bridge_available() {
  [ -x "$APP_PROCESS" ] && [ -s "$BRIDGE_DEX" ]
}

# ---- Binder Bridge：真实能力探测（probe 实测，替代“文件存在即有能力”）----
# 成功时设置 BRIDGE_P_* 变量，返回 0；bridge 不可用/输出异常返回 1。
sys_bridge_probe() {
  bridge_available || return 1
  P_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge probe 2>/dev/null)
  [ -n "$P_OUT" ] || return 1
  BRIDGE_P_API=0; BRIDGE_P_WIFI=0; BRIDGE_P_GET=0
  BRIDGE_P_SET2=0; BRIDGE_P_SET1=0
  BRIDGE_P_BS_SSID=0; BRIDGE_P_BS_PASS_INT=0; BRIDGE_P_BS_PASS_STR=0
  BRIDGE_P_BS_SEC=0; BRIDGE_P_BS_BAND=0; BRIDGE_P_BS_CH_INTINT=0; BRIDGE_P_BS_CH_INT=0
  BRIDGE_P_BS_HIDDEN=0; BRIDGE_P_BS_MAX=0
  BRIDGE_P_SEC_OPEN=-1; BRIDGE_P_SEC_WPA2=-1; BRIDGE_P_SEC_WPA3_T=-1; BRIDGE_P_SEC_WPA3=-1
  BRIDGE_P_BAND_2G=-1; BRIDGE_P_BAND_5G=-1; BRIDGE_P_BAND_6G=-1; BRIDGE_P_BAND_ANY=-1
  BRIDGE_P_CAP=0; BRIDGE_P_PASS_R=0; BRIDGE_P_TSTART=0; BRIDGE_P_TSTOP=0
  BRIDGE_P_TCONN=0; BRIDGE_P_TCONN_START=0; BRIDGE_P_TCONN_STOP=0
  BRIDGE_P_CH2G=; BRIDGE_P_CH5G=; BRIDGE_P_CH6G=
  while IFS= read -r PL; do
    case "$PL" in
      api=*) BRIDGE_P_API=${PL#api=} ;;
      wifi_service=*) BRIDGE_P_WIFI=${PL#wifi_service=} ;;
      get_config=*) BRIDGE_P_GET=${PL#get_config=} ;;
      set_config_2arg=*) BRIDGE_P_SET2=${PL#set_config_2arg=} ;;
      set_config_1arg=*) BRIDGE_P_SET1=${PL#set_config_1arg=} ;;
      builder_setSsid=*) BRIDGE_P_BS_SSID=${PL#builder_setSsid=} ;;
      builder_setPassphrase_int=*) BRIDGE_P_BS_PASS_INT=${PL#builder_setPassphrase_int=} ;;
      builder_setPassphrase_str=*) BRIDGE_P_BS_PASS_STR=${PL#builder_setPassphrase_str=} ;;
      builder_setSecurityType=*) BRIDGE_P_BS_SEC=${PL#builder_setSecurityType=} ;;
      builder_setBand=*) BRIDGE_P_BS_BAND=${PL#builder_setBand=} ;;
      builder_setChannel_intint=*) BRIDGE_P_BS_CH_INTINT=${PL#builder_setChannel_intint=} ;;
      builder_setChannel_int=*) BRIDGE_P_BS_CH_INT=${PL#builder_setChannel_int=} ;;
      builder_setHiddenSsid=*) BRIDGE_P_BS_HIDDEN=${PL#builder_setHiddenSsid=} ;;
      builder_setMaxNumberOfClients=*) BRIDGE_P_BS_MAX=${PL#builder_setMaxNumberOfClients=} ;;
      sec_open=*) BRIDGE_P_SEC_OPEN=${PL#sec_open=} ;;
      sec_wpa2=*) BRIDGE_P_SEC_WPA2=${PL#sec_wpa2=} ;;
      sec_wpa3_transition=*) BRIDGE_P_SEC_WPA3_T=${PL#sec_wpa3_transition=} ;;
      sec_wpa3=*) BRIDGE_P_SEC_WPA3=${PL#sec_wpa3=} ;;
      band_2g=*) BRIDGE_P_BAND_2G=${PL#band_2g=} ;;
      band_5g=*) BRIDGE_P_BAND_5G=${PL#band_5g=} ;;
      band_6g=*) BRIDGE_P_BAND_6G=${PL#band_6g=} ;;
      band_any=*) BRIDGE_P_BAND_ANY=${PL#band_any=} ;;
      softap_capability=*) BRIDGE_P_CAP=${PL#softap_capability=} ;;
      password_readable=*) BRIDGE_P_PASS_R=${PL#password_readable=} ;;
      tether_start_cm=*) BRIDGE_P_TSTART=${PL#tether_start_cm=} ;;
      tether_stop_cm=*) BRIDGE_P_TSTOP=${PL#tether_stop_cm=} ;;
      tether_connector=*) BRIDGE_P_TCONN=${PL#tether_connector=} ;;
      tether_connector_start=*) BRIDGE_P_TCONN_START=${PL#tether_connector_start=} ;;
      tether_connector_stop=*) BRIDGE_P_TCONN_STOP=${PL#tether_connector_stop=} ;;
      channels2g=*) BRIDGE_P_CH2G=${PL#channels2g=} ;;
      channels5g=*) BRIDGE_P_CH5G=${PL#channels5g=} ;;
      channels6g=*) BRIDGE_P_CH6G=${PL#channels6g=} ;;
    esac
  done <<EOF
$P_OUT
EOF
  # v1.7.9：Modern（ITetheringConnector AIDL）与 Legacy（IConnectivityManager）任一可用即支持系统 Tethering 启停
  [ "$BRIDGE_P_TCONN_START" = "1" ] && BRIDGE_P_TSTART=1
  [ "$BRIDGE_P_TCONN_STOP" = "1" ] && BRIDGE_P_TSTOP=1
  return 0
}

# # Binder Bridge：SoftApCapability 实测（SoftApCallback.onCapabilityChanged，非反射猜方法）
# 成功时设置 BRIDGE_SC_CAPS=1 + BRIDGE_SC_CH2G/CH5G/CH6G/BRIDGE_SC_MAX；失败置 0。
sys_bridge_softap_caps() {
  BRIDGE_SC_CAPS=0; BRIDGE_SC_CH2G=; BRIDGE_SC_CH5G=; BRIDGE_SC_CH6G=; BRIDGE_SC_MAX=0
  bridge_available || return 1
  SC_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge softap-capability 2>/dev/null)
  [ -n "$SC_OUT" ] || return 1
  while IFS= read -r PL; do
    case "$PL" in
      caps=1) BRIDGE_SC_CAPS=1 ;;
      channels2g=*) BRIDGE_SC_CH2G=${PL#channels2g=} ;;
      channels5g=*) BRIDGE_SC_CH5G=${PL#channels5g=} ;;
      channels6g=*) BRIDGE_SC_CH6G=${PL#channels6g=} ;;
      max_clients=*) BRIDGE_SC_MAX=${PL#max_clients=} ;;
    esac
  done <<EOF
$SC_OUT
EOF
  case "$BRIDGE_SC_MAX" in ''|*[!0-9]*) BRIDGE_SC_MAX=0 ;; esac
  return 0
}

# cmd wifi 的 start-softap/stop-softap 可用性（仅决定 fallback 启停能力）
sys_cmd_wifi_caps() {
  CMDW_START=0; CMDW_STOP=0
  if command -v "$CMD_WIFI" >/dev/null 2>&1; then
    CMDW_HELP=$("$CMD_WIFI" wifi help 2>/dev/null)
    case "$CMDW_HELP" in *start-softap*) CMDW_START=1 ;; esac
    case "$CMDW_HELP" in *stop-softap*) CMDW_STOP=1 ;; esac
  fi
}

# cmd connectivity tether 可用性（系统 Tethering 路径）
sys_tether_supported() {
  [ "$TETHER_SUPPORTED" = "1" ]
}

# ---- 能力检测：一次解析，输出 HOTSPOT_CAPS_JSON ----
hotspot_detect_capabilities() {
  # Android API Level（优先 probe，其次 getprop）
  API=$("$BB" getprop ro.build.version.sdk 2>/dev/null | "$BB" tr -d ' \r\n')
  case "$API" in ''|*[!0-9]*) API=0 ;; esac

  # cmd wifi / connectivity tether 可用性
  sys_cmd_wifi_caps
  TETHER_SUPPORTED=0
  if command -v "$CMD_WIFI" >/dev/null 2>&1; then
    case "$("$CMD_WIFI" connectivity help 2>/dev/null)" in
      *'tether'*'start'*) TETHER_SUPPORTED=1 ;;
    esac
  fi

  # 系统配置读写能力：由 Binder Bridge probe 实测决定（不靠文件存在）
  READ_CFG=0; WRITE_CFG=0
  if sys_bridge_probe; then
    [ -n "$BRIDGE_P_API" ] && [ "$BRIDGE_P_API" -gt 0 ] 2>/dev/null && API=$BRIDGE_P_API
    [ "$BRIDGE_P_WIFI" = "1" ] && [ "$BRIDGE_P_GET" = "1" ] && READ_CFG=1
    # 写能力：setSoftApConfiguration 签名存在（2 参标准 / 1 参 OEM 变体）
    #        + Builder 具备 setSsid 与密码设置路径（setPassphrase(String,int) 标准，
    #          或 setPassphrase(String)+setSecurityType(int) OEM 变体）
    if { [ "$BRIDGE_P_SET2" = "1" ] || [ "$BRIDGE_P_SET1" = "1" ]; } \
       && [ "$BRIDGE_P_BS_SSID" = "1" ] \
       && { [ "$BRIDGE_P_BS_PASS_INT" = "1" ] \
            || { [ "$BRIDGE_P_BS_PASS_STR" = "1" ] && [ "$BRIDGE_P_BS_SEC" = "1" ]; }; }; then
      WRITE_CFG=1
    fi
  elif [ -r "$SYS_WIFI_STORE" ]; then
    READ_CFG=1
  fi

  # 配置参数能力：优先由 probe 的 Builder 方法/常量决定（SoftApConfiguration 层）
  HIDDEN_OK=0; CH_CTL=0; MAX_CTL=0; BAND_2G=0; BAND_5G=0; BAND_6G=0
  if [ "$BRIDGE_P_BS_HIDDEN" = "1" ]; then HIDDEN_OK=1; fi
  if [ "$BRIDGE_P_BS_CH_INTINT" = "1" ] || [ "$BRIDGE_P_BS_CH_INT" = "1" ]; then CH_CTL=1; fi
  if [ "$BRIDGE_P_BS_MAX" = "1" ]; then MAX_CTL=1; fi
  if [ "$BRIDGE_P_BAND_2G" -gt 0 ] 2>/dev/null; then BAND_2G=1; fi
  if [ "$BRIDGE_P_BAND_5G" -gt 0 ] 2>/dev/null; then BAND_5G=1; fi
  if [ "$BRIDGE_P_BAND_6G" -gt 0 ] 2>/dev/null; then BAND_6G=1; fi
  # 无 bridge 时：配置能力随 fallback 命令粗判（不承诺）
  if [ "$READ_CFG" = "0" ] && [ "$WRITE_CFG" = "0" ]; then
    BAND_2G=1; BAND_5G=1
  fi

  # 启停能力：Bridge 系统 Tethering（IConnectivityManager.startTethering，probe 实测）优先，
  # cmd connectivity / cmd wifi 仅作 fallback 可用性判断
  START_STOP=0
  if [ "$BRIDGE_P_TSTART" = "1" ] || [ "$BRIDGE_P_TSTOP" = "1" ]; then
    START_STOP=1
  elif [ "$TETHER_SUPPORTED" = "1" ] || [ "$CMDW_START" = "1" ]; then
    START_STOP=1
  fi

  # 信道能力：由设备 SoftApCapability 实测（SoftApCallback.onCapabilityChanged →
  # SoftApCapability.getSupportedChannelList），无列表时 Web 只显示"自动"
  # 动态最大客户端数：SoftApCapability 实测，>0 时前端据此动态设置上限
  MAX_CLIENTS_LIMIT=0
  if [ "$BRIDGE_P_WIFI" = "1" ]; then
    if sys_bridge_softap_caps; then
      if [ "$BRIDGE_SC_CAPS" = "1" ]; then
        BRIDGE_P_CH2G=$BRIDGE_SC_CH2G
        BRIDGE_P_CH5G=$BRIDGE_SC_CH5G
        BRIDGE_P_CH6G=$BRIDGE_SC_CH6G
        MAX_CLIENTS_LIMIT=$BRIDGE_SC_MAX
      fi
    fi
  fi
  CH_JSON_2G=[$(list_to_json "$BRIDGE_P_CH2G")]
  CH_JSON_5G=[$(list_to_json "$BRIDGE_P_CH5G")]
  CH_JSON_6G=[$(list_to_json "$BRIDGE_P_CH6G")]

  # 同步级别：A=完整读写（系统↔Web 双向同步）；B=只读；C=无系统配置能力（仅开关/状态）
  SYNC_LEVEL=C
  [ "$READ_CFG" = "1" ] && SYNC_LEVEL=B
  [ "$WRITE_CFG" = "1" ] && SYNC_LEVEL=A

  HOTSPOT_CAPS_JSON=$(printf '{"android":%s,"startStop":%s,"readConfig":%s,"writeConfig":%s,"band2g":%s,"band5g":%s,"band6g":%s,"hiddenSsid":%s,"channelControl":%s,"maxClients":%s,"maxClientsLimit":%s,"channels2g":%s,"channels5g":%s,"channels6g":%s,"syncLevel":"%s"}' \
    "$API" \
    "$([ "$START_STOP" = "1" ] && echo true || echo false)" \
    "$([ "$READ_CFG" = "1" ] && echo true || echo false)" \
    "$([ "$WRITE_CFG" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_2G" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_5G" = "1" ] && echo true || echo false)" \
    "$([ "$BAND_6G" = "1" ] && echo true || echo false)" \
    "$([ "$HIDDEN_OK" = "1" ] && echo true || echo false)" \
    "$([ "$CH_CTL" = "1" ] && echo true || echo false)" \
    "$([ "$MAX_CTL" = "1" ] && echo true || echo false)" \
    "$MAX_CLIENTS_LIMIT" \
    "$CH_JSON_2G" \
    "$CH_JSON_5G" \
    "$CH_JSON_6G" \
    "$SYNC_LEVEL")
  # v1.7.9：探测结果回写缓存（CGI 只读）；目录不存在（如测试环境）时静默跳过
  if [ -n "$CAPS_CACHE_FILE" ] && [ -d "${CAPS_CACHE_FILE%/*}" ]; then
    printf '%s\n' "$HOTSPOT_CAPS_JSON" > "$CAPS_CACHE_FILE" 2>/dev/null
  fi
}

# v1.7.9：动态最大客户端上限（读能力缓存 maxClientsLimit；无缓存/异常回退 32）
get_max_clients_limit() {
  LIMIT=32
  if [ -s "$CAPS_CACHE_FILE" ]; then
    V=$(printf '%s' "$("$BB" cat "$CAPS_CACHE_FILE" 2>/dev/null)" | "$BB" sed -n 's/.*"maxClientsLimit":\([0-9]*\).*/\1/p')
    case "$V" in ''|*[!0-9]*) V=0 ;; esac
    [ "$V" -gt 0 ] 2>/dev/null && LIMIT=$V
  fi
  printf '%s' "$LIMIT"
}

# 缓存新鲜度（mtime < TTL）；无法取 mtime 视为不新鲜（触发重探测）
cache_fresh() {
  f=$1; ttl=$2
  [ -s "$f" ] || return 1
  m=$(stat -c %Y "$f" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(/system/bin/date +%s 2>/dev/null || date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((now - m))" -lt "$ttl" ]
}

# "1,3,6,9" → "1,3,6,9"（空/empty 时输出空串）
list_to_json() {
  case "$1" in ''|empty) printf '' ;; *) printf '%s' "$1" ;; esac
}

# ---- 接口 1：能力清单 ----
# v1.7.9：只读缓存（10 分钟新鲜度），过期/缺失才现场探测（探测会回写缓存）。
# supervisor 每 120 tick（约 10 分钟）强制刷新一次。
hotspot_get_capabilities() {
  if [ -s "$CAPS_CACHE_FILE" ] && cache_fresh "$CAPS_CACHE_FILE" "$CAPS_CACHE_TTL"; then
    HOTSPOT_CAPS_JSON=$("$BB" tr -d '\r\n' < "$CAPS_CACHE_FILE" 2>/dev/null)
  fi
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
  OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge get-config 2>/dev/null)
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
  # v1.7.9：非 CGI 调用时写系统配置缓存（supervisor 主 tick 预热；status.cgi
  # 只读此缓存，不再每次轮询起 app_process get-config）。
  if [ -n "$CONFIG_CACHE_FILE" ] && [ -d "${CONFIG_CACHE_FILE%/*}" ] && [ "${CGI_READONLY:-0}" != "1" ]; then
    TMP_CC="$CONFIG_CACHE_FILE.tmp.$$"
    {
      printf 'present=%s\n' "$PRESENT"
      printf 'ssid_b64=%s\n' "$(printf '%s' "$sys_ssid" | "$BB" base64 -w0 2>/dev/null | "$BB" tr '+/' '-_')"
      printf 'security=%s\n' "$sys_security"
      printf 'password_b64=%s\n' "$(printf '%s' "$sys_password" | "$BB" base64 -w0 2>/dev/null | "$BB" tr '+/' '-_')"
      printf 'band=%s\n' "$sys_band"
      printf 'channel=%s\n' "$sys_channel"
      printf 'hidden=%s\n' "$sys_hidden"
      printf 'maxclients=%s\n' "$sys_maxclients"
    } > "$TMP_CC" 2>/dev/null
    chmod 0600 "$TMP_CC" 2>/dev/null
    mv -f "$TMP_CC" "$CONFIG_CACHE_FILE" 2>/dev/null
    rm -f "$TMP_CC" 2>/dev/null
  fi
  return 0
}

# ---- Binder Bridge：调用 Framework setSoftApConfiguration（系统持久化）----
# 返回 0 成功；非 0 失败（调用方必须明确报错，禁止回退到第二套配置）
sys_bridge_set() {
  bridge_available || return 1
  "$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge set-config \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >/dev/null 2>&1
}

# ---- 接口 2：读取系统热点配置（变量见 sys_softap_get / sys_bridge_get）----
# 优先 Framework（真实内存配置）；bridge 不可用时降级只读解析 WifiConfigStore.xml。
CONFIG_CACHE_TTL=25
# 从配置文件读入 sys_*（共用段，CGI 与非 CGI 复用）
_read_config_cache() {
  sys_ok=0
  sys_ssid=; sys_security=wpa2; sys_password=; sys_band=any; sys_channel=0; sys_hidden=0; sys_maxclients=0
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
  done < "$CONFIG_CACHE_FILE"
  [ "$PRESENT" = "1" ] && [ -n "$sys_ssid" ] && sys_ok=1
}

hotspot_get_config() {
  # v1.7.9：CGI 只读轮询——直接读 supervisor 预热的系统配置缓存，
  # 不在此进程起 app_process（get-config），避免每次状态轮询都 fork app_process。
  if [ "${CGI_READONLY:-0}" = "1" ] && [ -s "$CONFIG_CACHE_FILE" ]; then
    _read_config_cache
    return 0
  fi
  # v1.7.9：非 CGI（supervisor 预热）同样按 TTL 复用缓存，避免每 5s tick
  # 都起一次 app_process get-config；配置保存后 control.cgi 会删缓存强制重建。
  if [ -s "$CONFIG_CACHE_FILE" ]; then
    CC_MT=$("$BB" stat -c %Y "$CONFIG_CACHE_FILE" 2>/dev/null)
    CC_NOW=$(/system/bin/date +%s 2>/dev/null || date +%s)
    case "$CC_MT" in ''|*[!0-9]*) CC_MT=0 ;; esac
    CC_AGE=$((CC_NOW - CC_MT))
    if [ "$CC_MT" -gt 0 ] && [ "$CC_AGE" -ge 0 ] && [ "$CC_AGE" -lt "$CONFIG_CACHE_TTL" ]; then
      _read_config_cache
      return 0
    fi
  fi
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
# 必须走 Framework：IWifiManager.setSoftApConfiguration(config, packageName)
#   → WifiApConfigStore.setApConfiguration() 系统持久化（经 Binder Bridge）。
# 密码传空 = 保留系统当前密码；security=open = 清空密码。
# 【不关闭热点】写入失败时热点保持原运行状态；写入成功后由调用方决定是否重启。
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

  # Framework 持久化（Binder Bridge；不关闭热点！）
  if ! sys_bridge_set "$NEW_SSID" "$NEW_SEC" "$NEW_PASS" "$NEW_BAND" "$NEW_CHANNEL" "$NEW_HIDDEN" "$NEW_MAX"; then
    echo "$(date) hotspot_set_config: setSoftApConfiguration failed (bridge unavailable or API rejected)" >> "$LOG" 2>/dev/null
    return 1
  fi

  # v1.7.9：写成功后立即删系统配置缓存，读回验证必须走实时 bridge——
  # 否则 25s TTL 缓存窗口内读到旧配置，把成功写入误判为失败。
  rm -f "$CONFIG_CACHE_FILE" 2>/dev/null

  # 确保 probe 已跑（密码可读性 / 最大连接数能力判定）
  [ -n "${BRIDGE_P_GET:-}" ] || sys_bridge_probe 2>/dev/null

  # 读回验证：系统配置已持久化（热点保持原状态未动）
  hotspot_get_config
  VERIFY_OK=0
  if [ "$sys_ok" = "1" ] && [ "$sys_ssid" = "$NEW_SSID" ] \
     && [ "$sys_security" = "$NEW_SEC" ] \
     && [ "$sys_band" = "$NEW_BAND" ] \
     && [ "$sys_channel" = "$NEW_CHANNEL" ] \
     && [ "$sys_hidden" = "$NEW_HIDDEN" ]; then
    VERIFY_OK=1
    # 密码验证：非 open 且设置了新密码时，系统可读回则必须一致（读不回=ROM 遮蔽，跳过并记日志）
    if [ "$VERIFY_OK" = "1" ] && [ "$NEW_SEC" != "open" ] && [ -n "$NEW_PASS" ]; then
      if [ "${BRIDGE_P_PASS_R:-0}" = "1" ]; then
        if [ -z "$sys_password" ] || [ "$sys_password" != "$NEW_PASS" ]; then
          echo "$(date) hotspot_set_config: password verify mismatch" >> "$LOG" 2>/dev/null
          VERIFY_OK=0
        fi
      else
        echo "$(date) hotspot_set_config: password not readable on this ROM, skip verify" >> "$LOG" 2>/dev/null
      fi
    fi
    # 最大连接数验证：设备支持时 0（恢复默认）与正数都必须一致
    if [ "$VERIFY_OK" = "1" ] && [ "${BRIDGE_P_BS_MAX:-0}" = "1" ] && [ "$sys_maxclients" != "$NEW_MAX" ]; then
      echo "$(date) hotspot_set_config: maxclients verify mismatch (saved=$sys_maxclients want=$NEW_MAX)" >> "$LOG" 2>/dev/null
      VERIFY_OK=0
    fi
  fi
  if [ "$VERIFY_OK" != "1" ]; then
    echo "$(date) hotspot_set_config: verify failed (saved ssid=$sys_ssid want=$NEW_SSID sec=$sys_security want=$NEW_SEC band=$sys_band want=$NEW_BAND hidden=$sys_hidden want=$NEW_HIDDEN)" >> "$LOG" 2>/dev/null
    return 1
  fi
  return 0
}

# ---- 接口 4：热点运行状态（统一入口，业务层禁止自行猜接口名）----
# 判定优先级（v1.7.8）：
#   1) SoftAP Framework state（Bridge SoftApCallback.onStateChanged，state 10-14，最终状态优先）
#   2) dumpsys 快照（softap_state_snapshot 缓存，支持 onStateChanged state 解析）
#   3) Tethering state（bridge tether-state：tether_state=2/tethered=1 → ENABLED）
#   4) 接口探测（仅剩此路时才用 get_hotspot_iface）
# 任何"failure reason: 0"都不判失败；只有 state=14（FAILED）才算启动失败。
hotspot_get_state() {
  SNAP_AP_STATE=
  # v1.7.9：CGI 只读轮询——先读 supervisor 每 tick 写的 system_hotspot.cache
  # （永远新鲜，5s 刷新），非空即返回；避免起 app_process 或触发 dumpsys。
  if [ "${CGI_READONLY:-0}" = "1" ]; then
    if [ -s "$STATE_CACHE_FILE" ]; then
      SNAP_AP_STATE=$("$BB" sed -n 's/^SNAP_AP_STATE=//p' "$STATE_CACHE_FILE" 2>/dev/null | "$BB" head -1)
      [ -n "$SNAP_AP_STATE" ] && return 0
    fi
    softap_state_snapshot "$@"
    [ -n "$SNAP_AP_STATE" ] && return 0
  fi
  # 1) Bridge SoftAP Framework state（真实回调状态，10=DISABLING 11=DISABLED 12=ENABLING 13=ENABLED 14=FAILED）
  if bridge_available; then
    S_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge softap-state 2>/dev/null)
    case "$S_OUT" in
      *'softap_state='*)
        S_NUM=${S_OUT#*softap_state=}
        S_NUM=${S_NUM%%$'\n'*}
        case "$S_NUM" in
          10) SNAP_AP_STATE=DISABLING ;;
          11) SNAP_AP_STATE=DISABLED ;;
          12) SNAP_AP_STATE=ENABLING ;;
          13) SNAP_AP_STATE=ENABLED ;;
          14) SNAP_AP_STATE=FAILED ;;
        esac
        ;;
    esac
  fi
  # 2) dumpsys 快照兜底（含 onStateChanged state 解析）
  if [ -z "$SNAP_AP_STATE" ]; then
    softap_state_snapshot "$@"
  fi
  # 3) Tethering state 兜底
  if [ -z "$SNAP_AP_STATE" ] && bridge_available; then
    T_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null)
    case "$T_OUT" in
      *'tether_state=2'*|*'tethered=1'*) SNAP_AP_STATE=ENABLED ;;
      *'tethered=0'*) SNAP_AP_STATE=DISABLED ;;
    esac
  fi
}

# ---- 热点接口名（统一入口：不写死单一 wlan*，跨厂商探测）----
# v1.7.9 优先级（避免把 Wi-Fi STA 接口误认成热点接口）：
#   1) Bridge tether-state 真实 Tethering downstream 接口（系统回调数据，最可靠）
#   2) 固定管理别名 192.168.43.1/32 所在接口（该别名只挂载在热点接口上）
#   3) supervisor 写入的状态缓存 HOTSPOT_IFACE_FILE（见第 7 项能力/状态缓存）
#   4) ip 枚举兜底：仅限 ap*/softap*/swlan*/apbr*/wlan_ap*/wlan[1-9]* 且接口上有 IPv4 地址
get_hotspot_iface() {
  IFACE=
  # 1) 系统 Tethering downstream（Bridge tether-state 实测）
  if bridge_available; then
    T_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null)
    case "$T_OUT" in
      *'ifaces='*)
        SEG=${T_OUT#*ifaces=}
        SEG=${SEG%%$'\n'*}
        SEG=${SEG%%,*}
        case "$SEG" in
          wlan*|ap0|softap0|swlan0|apbr0|wlan_ap*) IFACE=$SEG ;;
        esac
        ;;
    esac
  fi
  # 2) 固定管理别名所在接口（模块只把 192.168.43.1/32 挂到热点接口；
  #    stop 后别名挂在 lo，lo 绝不是热点接口——必须排除，否则验证循环拿到
  #    lo 的 127.0.0.1 恒非空 IP，热点刚启动就被误判成功/失败）
  if [ -z "$IFACE" ]; then
    IFACE=$(/system/bin/ip -o -4 addr show 2>/dev/null | "$BB" awk -v s="$STABLE_IP/32" '$2 != "lo" && $4 == s {print $2; exit}')
  fi
  # 3) supervisor 状态缓存（第 7 项：HOTSPOT_IFACE_FILE）
  if [ -z "$IFACE" ] && [ -n "$HOTSPOT_IFACE_FILE" ] && [ -s "$HOTSPOT_IFACE_FILE" ]; then
    IFACE=$("$BB" tr -d '\r\n' < "$HOTSPOT_IFACE_FILE" 2>/dev/null)
  fi
  # 4) ip 枚举兜底：接口名模式 + 必须已有地址（IPv4 或 IPv6 链路本地均可）。
  #    v1.7.9：HyperOS 热点接口 wlan2 启动后只有 IPv6 链路本地（fe80::），
  #    IPv4 管理别名由模块后挂；若用 ip -o -4 addr show 会永远匹配不到，
  #    导致启动验证失败并误报"热点启动失败"。改用全量地址枚举。
  if [ -z "$IFACE" ]; then
    IFACE=$(/system/bin/ip -o addr show 2>/dev/null \
      | "$BB" awk '$2 ~ /^(wlan[1-9][0-9]*|ap[0-9]*|softap[0-9]*|swlan[0-9]*|apbr[0-9]*|wlan_ap[0-9]*)$/ && $4 != "" {print $2; exit}')
  fi
  printf '%s' "$IFACE"
}

# 等待系统 Tethering 生效（轮询 dumpsys 快照 / bridge tether-state）
# 启动序列 11→12→13 属正常；state=14（FAILED）立即判失败，不等到超时才报错。
wait_tether_enabled() {
  I=0
  while [ "$I" -lt "$1" ]; do
    I=$((I + 1))
    sleep 1
    softap_state_snapshot 2>/dev/null
    case "$SNAP_AP_STATE" in
      ENABLED) return 0 ;;
      FAILED) return 1 ;;
    esac
    if bridge_available; then
      T_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null)
      case "$T_OUT" in *'tether_state=2'*|*'tethered=1'*) return 0 ;; esac
    fi
  done
  return 1
}

# ---- 接口 5：启动热点（Generic Backend = Bridge 系统 Tethering，与 Settings 一致）----
hotspot_start() {
  NEW_SSID_ARG=$1; NEW_SEC_ARG=$2; NEW_PASS_ARG=$3; NEW_BAND_ARG=$4; NEW_CHANNEL_ARG=$5; NEW_MAX_ARG=$6
  NEW_HIDDEN_ARG=${HIDDEN:-0}

  # 迁移：系统从未配置 + 模块旧参数 → 经 Framework 持久化一次（此后 config.conf 不再保存）
  if [ -n "$NEW_SSID_ARG" ] && ! hotspot_config_present; then
    echo "$(date) hotspot_start: migrating module hotspot config to system SoftApConfiguration" >> "$LOG" 2>/dev/null
    if ! hotspot_set_config "$NEW_SSID_ARG" "$NEW_SEC_ARG" "$NEW_PASS_ARG" "$NEW_BAND_ARG" "$NEW_CHANNEL_ARG" "$NEW_HIDDEN_ARG" "$NEW_MAX_ARG"; then
      echo "$(date) hotspot_start: migration failed, abort start (system config missing)" >> "$LOG" 2>/dev/null
      return 1
    fi
    # 迁移成功：清除 config.conf 中的旧热点字段（仅此一次，密码不再留在模块配置）
    if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
      "$BB" sed -i -E '/^(SSID_B64|PASS_B64|SECURITY|BAND|CHANNEL|HIDDEN|MAX_CLIENTS)=/d' "$CONFIG" 2>/dev/null
      echo "$(date) hotspot_start: old hotspot fields removed from config.conf" >> "$LOG" 2>/dev/null
    fi
  fi

  # Generic Backend：Bridge 系统 Tethering（IConnectivityManager.startTethering，
  # 跨 ROM 无需 cmd connectivity 子命令存在；回调经 Proxy+Binder 静默接受）
  if bridge_available; then
    B_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-start 2>/dev/null)
    case "$B_OUT" in
      *'ok=1'*)
        echo "$(date) hotspot_start: bridge tether-start (system Tethering)" >> "$LOG" 2>/dev/null
        if wait_tether_enabled 10; then
          return 0
        fi
        echo "$(date) hotspot_start: bridge tether-start did not reach ENABLED within 10s" >> "$LOG" 2>/dev/null
        ;;
      *)
        echo "$(date) hotspot_start: bridge tether-start unavailable/failed, fallback; result=$(printf '%s' "$B_OUT" | "$BB" tr '\n' ' ' | "$BB" head -c 180)" >> "$LOG" 2>/dev/null
        ;;
    esac
  fi

  # Fallback 2：cmd connectivity tether start（老系统 Shell 路径）
  if command -v "$CMD_WIFI" >/dev/null 2>&1; then
    case "$("$CMD_WIFI" connectivity help 2>/dev/null)" in
      *'tether'*'start'*)
        echo "$(date) hotspot_start: connectivity tether start (shell fallback)" >> "$LOG" 2>/dev/null
        "$BB" timeout 10 "$CMD_WIFI" connectivity tether start 2>&1 | "$BB" head -3 >> "$LOG" 2>/dev/null
        if wait_tether_enabled 10; then
          return 0
        fi
        echo "$(date) hotspot_start: connectivity tether start did not reach ENABLED" >> "$LOG" 2>/dev/null
        ;;
      *) echo "$(date) hotspot_start: connectivity tether unsupported" >> "$LOG" 2>/dev/null ;;
    esac
  fi

  # Fallback 3（capability 验证后）：cmd wifi start-softap 带参（用系统配置，OEM/老系统路径）
  if command -v "$CMD_WIFI" >/dev/null 2>&1 \
     && "$CMD_WIFI" wifi help 2>/dev/null | grep -q 'start-softap'; then
    hotspot_get_config
    if [ "$sys_ok" = "1" ] && [ -n "$sys_ssid" ]; then
      EXTRA=
      case "$sys_channel" in ''|0) ;; *) EXTRA="$EXTRA -c $sys_channel" ;; esac
      case "$sys_maxclients" in ''|0) ;; *) EXTRA="$EXTRA -m $sys_maxclients" ;; esac
      [ "$sys_hidden" = "1" ] && EXTRA="$EXTRA -h"
      case "$sys_security" in
        wpa3_transition|owe_transition|owe) FALL_SEC=wpa2 ;;
        *) FALL_SEC=$sys_security ;;
      esac
      if [ "$FALL_SEC" = "open" ]; then
        # v1.7.9：cmd wifi start-softap 在 HyperOS 上可能因 Binder 挂起永不返回，
        # 必须 timeout 兜底（15s 内未返回则终止，避免 start_hotspot 永久卡死
        # 导致 ensure_hotspot_dhcp 永远执行不到——热点半开无网）。
        "$BB" timeout 15 "$CMD_WIFI" wifi start-softap "$sys_ssid" open -b "$sys_band" $EXTRA 2>/dev/null
      else
        "$BB" timeout 15 "$CMD_WIFI" wifi start-softap "$sys_ssid" "$FALL_SEC" "$sys_password" -b "$sys_band" $EXTRA 2>/dev/null
      fi
      return $?
    fi
  fi
  echo "$(date) hotspot_start: no usable backend" >> "$LOG" 2>/dev/null
  return 1
}

# ---- 接口 6：停止热点（Generic = Bridge 系统 Tethering 优先；cmd connectivity / wifi fallback）----
hotspot_stop() {
  if bridge_available; then
    B_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-stop 2>/dev/null)
    case "$B_OUT" in
      *'ok=1'*)
        echo "$(date) hotspot_stop: bridge tether-stop (system Tethering)" >> "$LOG" 2>/dev/null
        I=0
        STOP_CONFIRM_MAX=${STOP_CONFIRM_MAX:-8}
        while [ "$I" -lt "$STOP_CONFIRM_MAX" ]; do
          I=$((I + 1))
          sleep 1
          softap_state_snapshot 2>/dev/null
          case "$SNAP_AP_STATE" in DISABLED) return 0 ;; esac
        done
        # 8 秒后仍未在快照中确认关闭：再查 bridge tether-state 真实状态，
        # 仍 tethered 则返回失败（绝不"超时就假装关闭成功"）。
        if bridge_available; then
          T_OUT=$("$APP_PROCESS" -Djava.class.path="$BRIDGE_DEX" /system/bin com.mifi.softap.SoftApBridge tether-state 2>/dev/null)
          case "$T_OUT" in
            *'tethered=0'*|*'tether_state=0'*|*'tether_state=1'*)
              # v1.7.9：停止自建 DHCP/NAT（若启用）
              _CLEAN_IFACE=$(get_hotspot_iface 2>/dev/null)
              [ -n "$_CLEAN_IFACE" ] && cleanup_hotspot_dhcp "$_CLEAN_IFACE"
              return 0 ;;
          esac
        fi
        echo "$(date) hotspot_stop: system still reports hotspot active after $STOP_CONFIRM_MAX s" >> "$LOG" 2>/dev/null
        return 1
        ;;
      *)
        echo "$(date) hotspot_stop: bridge tether-stop unavailable, fallback; result=$(printf '%s' "$B_OUT" | "$BB" tr '\n' ' ' | "$BB" head -c 180)" >> "$LOG" 2>/dev/null
        ;;
    esac
  fi
  stop_hotspot_real
  return $?
}

# ---- 接口 7：重启热点（完整 停止→启动，单次）----
hotspot_restart() {
  # v1.7.9：统一走兼容层（stop 确认 → start），不再绕过 hotspot_stop 直用旧 Shell 实现
  hotspot_stop >/dev/null 2>&1
  sleep 2
  hotspot_start "$@"
  return $?
}

# ---- 一次性迁移：v1.7.5 及更早保存在 config.conf 的热点字段 → 系统 SoftApConfiguration ----
# 服务启动时调用（load_config 之后）。幂等：成功写 marker；失败下次启动重试。
# 系统不可写时跳过（hotspot_start 内还有带参兜底迁移）。
migrate_legacy_hotspot_config() {
  MARKER="$DATA_DIR/.hotspot_migrated_v176"
  [ -f "$MARKER" ] && return 0
  [ -s "$CONFIG" ] || { : > "$MARKER"; return 0; }
  # 无旧热点字段
  if [ -z "${SSID_B64:-}" ] && [ -z "${PASS_B64:-}" ] && [ -z "${SECURITY:-}" ]; then
    : > "$MARKER"
    return 0
  fi
  # 系统可写（probe 实测）
  [ -n "${BRIDGE_P_GET:-}" ] || sys_bridge_probe 2>/dev/null
  if [ "${BRIDGE_P_SET2:-0}" != "1" ] && [ "${BRIDGE_P_SET1:-0}" != "1" ]; then
    echo "$(date) migrate: system not writable, skip (legacy fields kept)" >> "$LOG" 2>/dev/null
    return 0
  fi
  OLD_SSID=$(b64url_decode "$SSID_B64" 2>/dev/null)
  OLD_PASS=$(b64url_decode "$PASS_B64" 2>/dev/null)
  OLD_SEC=${SECURITY:-wpa2}
  case "$OLD_SEC" in open|wpa2|wpa3|wpa3_transition) ;; *) OLD_SEC=wpa2 ;; esac
  OLD_BAND=${BAND:-any}
  case "$OLD_BAND" in 2|5|6|any) ;; *) OLD_BAND=any ;; esac
  OLD_CHANNEL=${CHANNEL:-0}
  case "$OLD_CHANNEL" in ''|*[!0-9]*) OLD_CHANNEL=0 ;; esac
  OLD_HIDDEN=${HIDDEN:-0}
  case "$OLD_HIDDEN" in 1|true|on) OLD_HIDDEN=1 ;; *) OLD_HIDDEN=0 ;; esac
  OLD_MAX=${MAX_CLIENTS:-0}
  case "$OLD_MAX" in ''|*[!0-9]*) OLD_MAX=0 ;; esac
  if [ -z "$OLD_SSID" ]; then
    echo "$(date) migrate: legacy ssid empty, mark done" >> "$LOG" 2>/dev/null
    : > "$MARKER"
    return 0
  fi
  echo "$(date) migrate: migrating legacy hotspot config (ssid=$OLD_SSID) to system SoftApConfiguration" >> "$LOG" 2>/dev/null
  if hotspot_set_config "$OLD_SSID" "$OLD_SEC" "$OLD_PASS" "$OLD_BAND" "$OLD_CHANNEL" "$OLD_HIDDEN" "$OLD_MAX"; then
    # 迁移成功：save_config 重写 config.conf（热点字段不再输出），写 marker
    save_config 2>/dev/null
    : > "$MARKER"
    echo "$(date) migrate: done, legacy fields cleared from config.conf" >> "$LOG" 2>/dev/null
  else
    echo "$(date) migrate: failed, keep legacy fields for retry" >> "$LOG" 2>/dev/null
  fi
  return 0
}
