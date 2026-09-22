#!/system/bin/sh
# ============================================================
# Hotspot Compatibility Layer —— 通用 Android 热点兼容层
#
# 架构原则（v1.7.6 起）：
#   1) 不针对品牌 / ROM / Android 版本写死实现；一律运行时能力检测。
#   2) 系统热点配置（WifiConfigStore.xml + cmd wifi）是唯一数据源。
#      模块 config.conf 不再保存 SSID/密码/安全类型/频段/信道/隐藏/最大连接数
#      —— 这些参数属于 Android 系统，属于模块的是保活/定时/流量/通知/Mihomo/MAC 等。
#   3) 上层（control.cgi / status.cgi / service.sh / 前端）只调用本文件
#      定义的统一接口，禁止直接执行 cmd wifi / 直接读系统 XML。
#
# 统一接口（7 个）：
#   hotspot_get_capabilities  能力清单 JSON（前端据此动态显示）
#   hotspot_get_config        读取系统热点配置 → sys_ssid/sys_security/... 变量
#   hotspot_set_config        修改系统热点配置（写入系统存储，失败返回 1）
#   hotspot_get_state         读取热点运行状态
#   hotspot_start             启动热点（按能力自动选择 backend）
#   hotspot_stop              停止热点
#   hotspot_restart           重启热点
#
# Backend 选择（hotspot_start 内）：
#   A) 现代 Android（cmd wifi start-softap 可用）—— 主路径，参数完整
#   B) 旧系统 / 命令缺失（cmd connectivity tether start）—— 仅启停，参数降级
#   配置读写统一走系统 WifiConfigStore.xml（Android 11+/KernelSU root 环境）。
# ============================================================

# 能力检测结果缓存（status/UI 复用；检测一次即可）
HOTSPOT_CAPS_JSON=

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

  # 系统热点配置存储读写能力（root 环境；写入失败会在 hotspot_set_config 实时反馈）
  READ_CFG=0; WRITE_CFG=0
  if [ -r "$SYS_WIFI_STORE" ]; then
    READ_CFG=1
    # 目录可写 + 文件可写（root 下通常成立；SELinux 上下文问题写入时实时校验）
    [ -w "$SYS_WIFI_STORE" ] && [ -w "${SYS_WIFI_STORE%/*}" ] && WRITE_CFG=1
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

# ---- 接口 2：读取系统热点配置（变量见 sys_softap_get）----
hotspot_get_config() {
  sys_softap_get
}

# ---- 接口 3：修改系统热点配置（ssid security password band channel hidden maxclients）----
# 走系统 API（cmd wifi start-softap 传参 = WifiManager.setSoftApConfiguration + startSoftAp 路径），
# 系统 Framework 自行持久化；禁止直接改写 WifiConfigStore.xml（内存中配置不会被更新，随后会被系统写回）。
# 密码传空 = 保留系统当前密码；security=open = 清空密码。
# 热点开启中 → 停止后带参重启（新配置立即生效并保持开启）；
# 热点关闭时 → 带参启动一次（持久化新配置）后立即停止（不改变用户希望的关闭状态）。
# 返回 0 成功；1 失败（调用方必须明确报错，禁止回退到第二套配置）。
hotspot_set_config() {
  NEW_SSID=$1; NEW_SEC=$2; NEW_PASS=$3; NEW_BAND=$4; NEW_CHANNEL=$5; NEW_HIDDEN=$6; NEW_MAX=$7
  [ -n "$NEW_SSID" ] || { echo "$(date) hotspot_set_config: empty ssid" >> "$LOG" 2>/dev/null; return 1; }
  case "$NEW_BAND" in 2|5|6|any) : ;; *) NEW_BAND=any ;; esac
  case "$NEW_SEC" in open|wpa2|wpa3|wpa3_transition) : ;; *) NEW_SEC=wpa2 ;; esac
  # 密码留空且非 open → 读取系统当前密码（XML 只读，不涉及写回问题）
  if [ -z "$NEW_PASS" ] && [ "$NEW_SEC" != "open" ]; then
    sys_softap_get
    NEW_PASS=$sys_password
  fi
  [ "$NEW_SEC" = "open" ] && NEW_PASS=
  case "$NEW_CHANNEL" in ''|*[!0-9]*) NEW_CHANNEL=0 ;; esac
  case "$NEW_MAX" in ''|*[!0-9]*) NEW_MAX=0 ;; esac
  case "$NEW_HIDDEN" in 1|true|on) NEW_HIDDEN=1 ;; *) NEW_HIDDEN=0 ;; esac

  # 当前热点是否开启
  softap_state_snapshot 2>/dev/null
  WAS_ON=0
  [ "$SNAP_AP_STATE" = "ENABLED" ] && WAS_ON=1
  if [ "$WAS_ON" = "1" ]; then
    "$CMD_WIFI" wifi stop-softap >/dev/null 2>&1
    sleep 1
  fi

  EXTRA=
  [ "$NEW_CHANNEL" -gt 0 ] 2>/dev/null && EXTRA="$EXTRA -c $NEW_CHANNEL"
  [ "$NEW_MAX" -gt 0 ] 2>/dev/null && EXTRA="$EXTRA -m $NEW_MAX"
  [ "$NEW_HIDDEN" = "1" ] && EXTRA="$EXTRA -h"

  if [ "$NEW_SEC" = "open" ]; then
    "$CMD_WIFI" wifi start-softap "$NEW_SSID" open -b "$NEW_BAND" $EXTRA
    RC=$?
  else
    "$CMD_WIFI" wifi start-softap "$NEW_SSID" "$NEW_SEC" "$NEW_PASS" -b "$NEW_BAND" $EXTRA
    RC=$?
  fi
  # 隐藏 SSID 启动失败 → 自动回滚为广播 SSID 重试（持久化 HIDDEN=0）
  if [ "$RC" -ne 0 ] && [ "$NEW_HIDDEN" = "1" ]; then
    echo "$(date) hotspot_set_config: start-softap with -h failed rc=$RC, retrying without -h" >> "$LOG" 2>/dev/null
    case "$EXTRA" in *' -h'*) EXTRA=${EXTRA% -h} ;; esac
    if [ "$NEW_SEC" = "open" ]; then
      "$CMD_WIFI" wifi start-softap "$NEW_SSID" open -b "$NEW_BAND" $EXTRA
      RC=$?
    else
      "$CMD_WIFI" wifi start-softap "$NEW_SSID" "$NEW_SEC" "$NEW_PASS" -b "$NEW_BAND" $EXTRA
      RC=$?
    fi
    if [ "$RC" -eq 0 ]; then
      NEW_HIDDEN=0
      [ "${NOTIFY_HOTSPOT_EVT:-1}" = "1" ] && notify_all_async "热点隐藏SSID回滚" "系统不支持隐藏 SSID，已自动回滚为广播名称。" 2>/dev/null &
    fi
  fi
  if [ "$RC" -ne 0 ]; then
    echo "$(date) hotspot_set_config: system API failed rc=$RC" >> "$LOG" 2>/dev/null
    return 1
  fi
  # 原状态为关闭 → 配置已保存，恢复关闭（不改变开启/关闭意图）
  if [ "$WAS_ON" = "0" ]; then
    "$CMD_WIFI" wifi stop-softap >/dev/null 2>&1
  fi
  return 0
}

# ---- 接口 4：热点运行状态（复用 softap_state_snapshot）----
hotspot_get_state() {
  softap_state_snapshot "$@"
}

# ---- 接口 5：启动热点（backend 自动选择；以系统配置为唯一数据源）----
# 主路径：cmd wifi start-softap 无参启动（系统 tethering 使用已保存的 SoftApConfiguration，
# 与系统"设置"应用开启热点行为一致）。系统从未配置热点时，run_softap 内部会用模块旧参数
# 带参启动一次完成迁移（见 lib/common.sh run_softap）。
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
