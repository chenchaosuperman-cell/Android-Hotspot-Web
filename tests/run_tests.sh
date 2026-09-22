#!/bin/sh
# ============================================================
# 自动化回归测试骨架（v1.7.4）
#
# 用法：
#   sh tests/run_tests.sh          # 本机开发环境（macOS/Linux）
#
# 说明：
#   - source lib/common.sh 后对核心纯函数做断言，不触碰任何真实设备状态；
#   - 系统路径（BB/IPT 等）自动回退到测试机 PATH 中的命令；
#   - 新增用例：在下方按 assert_eq / ok 格式追加即可。
#   - 发布前建议在真机 KernelSU 环境跑一次（sh tests/run_tests.sh）。
# ============================================================
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD

PASS=0; FAIL=0; FAILED=""
assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); FAILED="$FAILED\n  x $1 (期望[$2] 实际[$3])"; echo "  FAIL  $1 (期望[$2] 实际[$3])"; fi
}
ok() { # desc rc
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); FAILED="$FAILED\n  x $1 (rc=$2)"; echo "  FAIL  $1 (rc=$2)"; fi
}

echo "== 加载 lib/common.sh =="
# 让 common.sh 能找到 compat.sh（测试环境用仓库目录模拟 MODDIR，须在 source 前设置）
MODDIR=$ROOT
export MODDIR
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh" 2>/dev/null || { echo "source 失败：请确认在仓库根目录下运行"; exit 1; }
# 测试机 mock：macOS/Linux 无 /system/bin/*，
# 用 /usr/bin/env 作为命令前缀（"$BB" cmd → env cmd，走 PATH）
BB=/usr/bin/env

echo "== MAC 校验 =="
valid_mac 'AA:BB:CC:DD:EE:FF'; ok 'valid_mac 标准大写格式' $?
valid_mac 'aa:bb:cc:dd:ee:ff'; ok 'valid_mac 小写格式' $?
! valid_mac 'AA-BB-CC-DD-EE-FF'; ok 'valid_mac 连字符格式拒绝' $?
! valid_mac 'AA:BB:CC:DD:EE'; ok 'valid_mac 短格式拒绝' $?
! valid_mac 'GG:BB:CC:DD:EE:FF'; ok 'valid_mac 非法字符拒绝' $?
! valid_mac ''; ok 'valid_mac 空串拒绝' $?

echo "== 时间格式 =="
valid_hhmm '0000'; ok 'valid_hhmm 0000 接受' $?
valid_hhmm '2359'; ok 'valid_hhmm 2359 接受' $?
! valid_hhmm '2500'; ok 'valid_hhmm 2500 拒绝' $?
! valid_hhmm '2360'; ok 'valid_hhmm 2360 拒绝' $?
! valid_hhmm '12:00'; ok 'valid_hhmm 含冒号拒绝' $?
! valid_hhmm '700'; ok 'valid_hhmm 三位数拒绝' $?

echo "== base64url 往返 =="
E=$(b64url_encode '热点测试 Hello 123')
D=$(b64url_decode "$E")
assert_eq 'b64url 中文+英文往返' '热点测试 Hello 123' "$D"
assert_eq 'b64url 不含 =/+ 字符' 0 "$(printf '%s' "$E" | tr -d '=' | grep -c '+')"

echo "== 厂商识别 =="
assert_eq 'mac_vendor Apple' 'Apple' "$(mac_vendor 'F0:18:98:12:34:56')"
assert_eq 'mac_vendor Xiaomi' 'Xiaomi' "$(mac_vendor 'F4:8E:38:12:34:56')"
assert_eq 'mac_vendor 未知厂商为空' '' "$(mac_vendor '00:00:00:00:00:01')"

echo "== 配置默认值（PROXY_SCOPE 全新安装默认仅代理热点设备） =="
TMPDIR_CFG=$(mktemp -d 2>/dev/null || printf '/tmp/mifi_test_%s' "$$")
CONFIG="$TMPDIR_CFG/config.conf"
: > "$CONFIG"
load_config
assert_eq '无 PROXY_SCOPE 配置 → 默认 hotspot' 'hotspot' "$PROXY_SCOPE"
assert_eq '无 PROXY_SELF 配置 → 默认 0' '0' "$PROXY_SELF"
printf 'SSID_B64=%s\n' "$(b64url_encode 'test')" > "$CONFIG"
printf 'PROXY_SCOPE=both\n' >> "$CONFIG"
printf 'PROXY_SELF=1\n' >> "$CONFIG"
load_config
assert_eq '已有 PROXY_SCOPE=both → 保留（旧配置兼容）' 'both' "$PROXY_SCOPE"
assert_eq '已有 PROXY_SELF=1 → 保留' '1' "$PROXY_SELF"
unset PROXY_SCOPE PROXY_SELF
printf 'SSID_B64=%s\n' "$(b64url_encode 'test')" > "$CONFIG"
load_config
assert_eq '新进程（unset）缺失 PROXY_SCOPE → 回落 hotspot' 'hotspot' "$PROXY_SCOPE"
assert_eq '新进程（unset）缺失 PROXY_SELF → 回落 0' '0' "$PROXY_SELF"
rm -rf "$TMPDIR_CFG"

echo "== MAC 策略函数（模式切换需先清旧链） =="
command -v apply_mac_policy >/dev/null 2>&1; ok 'apply_mac_policy 存在' $?
command -v clear_mac_acl >/dev/null 2>&1; ok 'clear_mac_acl 存在' $?
command -v clear_blacklist_rules >/dev/null 2>&1; ok 'clear_blacklist_rules 存在' $?
# mock iptables（echo 前缀）：仅验证空 iface 安全返回 + 分支可走通
IPT=echo
MAC_MODE=whitelist; ALLOWED_MACS='AA:BB:CC:DD:EE:FF'; BLOCKED_MACS=
apply_mac_policy ''; ok 'apply_mac_policy 空 iface 安全返回（whitelist）' $?
MAC_MODE=blacklist; BLOCKED_MACS='AA:BB:CC:DD:EE:FF'
apply_mac_policy ''; ok 'apply_mac_policy 空 iface 安全返回（blacklist）' $?
MAC_MODE=blacklist; BLOCKED_MACS=
apply_mac_policy ''; ok 'apply_mac_policy 空 iface 安全返回（blacklist 空名单）' $?
# 记录型 mock：验证模式切换先清旧策略残留，再按新模式重建
IPT_LOG=$(mktemp 2>/dev/null || printf '/tmp/mifi_ipt_%s' "$$")
ipt_log() { printf '%s\n' "$*" >> "$IPT_LOG"; }
IPT=ipt_log
MAC_MODE=whitelist; ALLOWED_MACS='AA:BB:CC:DD:EE:FF'; BLOCKED_MACS='11:22:33:44:55:66'
apply_mac_policy 'wlan0'
XLN=$(grep -n '\-X mifi_acl' "$IPT_LOG" | head -1 | cut -d: -f1)
NLN=$(grep -n '\-N mifi_acl' "$IPT_LOG" | head -1 | cut -d: -f1)
if [ -n "$XLN" ] && [ -n "$NLN" ] && [ "$XLN" -lt "$NLN" ]; then
  ok 'whitelist 重建前先清理旧链（-X 先于 -N）' 0
else
  ok 'whitelist 重建前先清理旧链（-X 先于 -N）' 1
fi
grep -q '\-D FORWARD' "$IPT_LOG"; ok 'whitelist 应用前清理旧黑名单 DROP（-D FORWARD）' $?
: > "$IPT_LOG"
MAC_MODE=blacklist; BLOCKED_MACS='11:22:33:44:55:66'
apply_mac_policy 'wlan0'
grep -q '\-X mifi_acl' "$IPT_LOG"; ok 'blacklist 模式清除残留白名单链（-X mifi_acl）' $?
rm -f "$IPT_LOG"
IPT=echo

echo "== 配置往返（全字段写入 → load → 逐字段断言） =="
TMPDIR_CFG2=$(mktemp -d 2>/dev/null || printf '/tmp/mifi_test2_%s' "$$")
CONFIG="$TMPDIR_CFG2/config.conf"
cat > "$CONFIG" <<EOF
SSID_B64=$(b64url_encode 'MyTest')
PASS_B64=$(b64url_encode 'P@ssw0rd!')
SECURITY=wpa2
BAND=5
HIDDEN=1
AUTOSTART=0
PORT=8080
CHANNEL=149
MAX_CLIENTS=10
KEEPALIVE=0
IDLE_SHUTDOWN=15
SCHED_ENABLE=1
SCHED_ON=2200
SCHED_OFF=0700
SCHED_MODE=weekday
BLOCKED_MACS=AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02
MAC_MODE=whitelist
ALLOWED_MACS=AA:BB:CC:DD:EE:03
PROXY_ENABLE=1
PROXY_SELF=0
PROXY_SCOPE=hotspot
LOWBATT_ENABLE=1
LOWBATT_THRESHOLD=15
DATA_PLAN_MB=10240
DATA_PLAN_DAY=1
DATA_LIMIT_ACTION=stop
NOTIFY_LIMIT=1
NOTIFY_HOTSPOT_EVT=0
SMS_FWD=1
PUSHPLUS_TOKEN_B64=$(b64url_encode 'tok')
BARK_KEY_B64=$(b64url_encode 'key')
EOF
load_config
assert_eq '往返 SSID' 'MyTest' "$(b64url_decode "$SSID_B64")"
assert_eq '往返 密码' 'P@ssw0rd!' "$(b64url_decode "$PASS_B64")"
assert_eq '往返 BAND' '5' "$BAND"
assert_eq '往返 HIDDEN' '1' "$HIDDEN"
assert_eq '往返 端口' '8080' "$PORT"
assert_eq '往返 保活' '0' "$KEEPALIVE"
assert_eq '往返 空闲关闭' '15' "$IDLE_SHUTDOWN"
assert_eq '往返 MAC_MODE' 'whitelist' "$MAC_MODE"
assert_eq '往返 PROXY_SCOPE' 'hotspot' "$PROXY_SCOPE"
assert_eq '往返 PROXY_SELF' '0' "$PROXY_SELF"
assert_eq '往返 定时模式' 'weekday' "$SCHED_MODE"
assert_eq '往返 定时开' '2200' "$SCHED_ON"
assert_eq '往返 套餐' '10240' "$DATA_PLAN_MB"
assert_eq '往返 低电量' '15' "$LOWBATT_THRESHOLD"
assert_eq '往返 PushPlus' 'tok' "$(b64url_decode "$PUSHPLUS_TOKEN_B64")"
assert_eq '往返 Bark' 'key' "$(b64url_decode "$BARK_KEY_B64")"
assert_eq '往返 黑名单2条' 'AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:02' "$BLOCKED_MACS"
assert_eq '往返 白名单1条' 'AA:BB:CC:DD:EE:03' "$ALLOWED_MACS"
rm -rf "$TMPDIR_CFG2"

echo "== 配置升级兼容（旧版无新增字段 → 新字段安全默认） =="
# 清理前序测试遗留的变量（同一 shell 进程内 load_config 不会覆盖已 set 变量）
unset MAC_MODE ALLOWED_MACS PROXY_SCOPE PROXY_SELF HIDDEN KEEPALIVE IDLE_SHUTDOWN SCHED_ENABLE CHANNEL MAX_CLIENTS LOWBATT_ENABLE LOWBATT_THRESHOLD DATA_PLAN_MB DATA_PLAN_DAY DATA_LIMIT_ACTION NOTIFY_LIMIT NOTIFY_HOTSPOT_EVT SMS_FWD PROXY_ENABLE BAND PORT AUTOSTART SECURITY
TMPDIR_CFG3=$(mktemp -d 2>/dev/null || printf '/tmp/mifi_test3_%s' "$$")
CONFIG="$TMPDIR_CFG3/config.conf"
cat > "$CONFIG" <<EOF
SSID_B64=$(b64url_encode 'OldSSID')
PASS_B64=$(b64url_encode 'OldPass')
SECURITY=wpa2
BAND=2
AUTOSTART=1
PORT=8080
KEEPALIVE=1
SCHED_ENABLE=0
BLOCKED_MACS=AA:BB:CC:DD:EE:99
PROXY_ENABLE=0
LOWBATT_ENABLE=0
DATA_PLAN_MB=0
EOF
load_config
assert_eq '升级后 SSID 不丢' 'OldSSID' "$(b64url_decode "$SSID_B64")"
assert_eq '升级后 密码不丢' 'OldPass' "$(b64url_decode "$PASS_B64")"
assert_eq '升级后 黑名单不丢' 'AA:BB:CC:DD:EE:99' "$BLOCKED_MACS"
assert_eq '升级后 新字段 PROXY_SCOPE=hotspot' 'hotspot' "$PROXY_SCOPE"
assert_eq '升级后 新字段 PROXY_SELF=0' '0' "$PROXY_SELF"
assert_eq '升级后 新字段 MAC_MODE=blacklist' 'blacklist' "$MAC_MODE"
assert_eq '升级后 新字段 ALLOWED_MACS 空' '' "$ALLOWED_MACS"
rm -rf "$TMPDIR_CFG3"

echo
echo "== Hotspot Compatibility Layer（v1.7.6）=="
# 测试环境：DATA_DIR 覆盖为临时目录（sys_softap_set 的备份目录），SYS_WIFI_STORE 覆盖为 mock XML
TMP_SYS_DIR=$(mktemp -d /tmp/sysap_cfg.XXXXXX) || exit 1
DATA_DIR="$TMP_SYS_DIR"
export DATA_DIR
cat > "$TMP_SYS_DIR/store.xml" <<'XMLEOF'
<WifiConfigStoreData>
<int name="Version" value="3" />
<SoftAp>
<string name="WifiSsid">&quot;Xiaomi14-MiFi&quot;</string>
<boolean name="HiddenSSID" value="false" />
<int name="SecurityType" value="1" />
<string name="Passphrase">87654321</string>
<int name="MaxNumberOfClients" value="0" />
</SoftAp>
<string name="KeepMe">xyz</string>
</WifiConfigStoreData>
XMLEOF
SYS_WIFI_STORE="$TMP_SYS_DIR/store.xml"
export SYS_WIFI_STORE

sys_softap_get
assert_eq 'sys 解析 Android13 WifiSsid(实体包裹)' 'Xiaomi14-MiFi' "$sys_ssid"
assert_eq 'sys 解析 安全类型 1=wpa2' 'wpa2' "$sys_security"
assert_eq 'sys 解析 密码' '87654321' "$sys_password"
assert_eq 'sys 解析 无Band字段→any' 'any' "$sys_band"
assert_eq 'sys 解析 hidden=false' '0' "$sys_hidden"
assert_eq 'sys 解析 ok=1' '1' "$sys_ok"

# ---- Binder Bridge mock（模拟 Framework setSoftApConfiguration/getSoftApConfiguration 系统持久化）----
MOCKBIN="$TMP_SYS_DIR/mockbin"
mkdir -p "$MOCKBIN"
# mock getprop：模拟 API 34 设备
cat > "$MOCKBIN/getprop" <<'EOF'
#!/bin/sh
echo "34"
EOF
chmod +x "$MOCKBIN/getprop"
BRIDGE_STATE="$TMP_SYS_DIR/bridge_state"
BRIDGE_LOG="$TMP_SYS_DIR/bridge_calls.log"
LOG="$TMP_SYS_DIR/service.log"
export LOG
: > "$BRIDGE_LOG"
# 初始系统配置（模拟设备已有持久热点配置）
printf '%s' "Xiaomi14-MiFi|wpa2|87654321|any|0|0|0" > "$BRIDGE_STATE"
cat > "$MOCKBIN/app_process" <<EOF
#!/bin/sh
# 参数形式：-Djava.class.path=... /system/bin com.mifi.softap.SoftApBridge set|get ...
CMD=
FOUND=0
ARGS=
for a in "\$@"; do
  if [ "\$FOUND" = "1" ]; then
    if [ -z "\$ARGS" ]; then ARGS="\$a"; else ARGS="\$ARGS|\$a"; fi
  else
    case "\$a" in set|get|get-api) CMD=\$a; FOUND=1 ;; esac
  fi
done
case "\$CMD" in
  set)
    echo "\$ARGS" >> "$BRIDGE_LOG"
    IFS='|' read -r S1 S2 S3 S4 S5 S6 S7 <<EOF2
\$ARGS
EOF2
    printf '%s|%s|%s|%s|%s|%s|%s' "\$S1" "\$S2" "\$S3" "\$S4" "\$S5" "\$S6" "\$S7" > "$BRIDGE_STATE"
    echo "ok=1"
    ;;
  get)
    if [ ! -s "$BRIDGE_STATE" ]; then echo "present=0"; exit 0; fi
    IFS='|' read -r G1 G2 G3 G4 G5 G6 G7 < "$BRIDGE_STATE"
    E1=\$(printf '%s' "\$G1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    E3=\$(printf '%s' "\$G3" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    printf 'present=1\nssid_b64=%s\nsecurity=%s\npassword_b64=%s\nband=%s\nchannel=%s\nhidden=%s\nmaxclients=%s\n' "\$E1" "\$G2" "\$E3" "\$G4" "\$G5" "\$G6" "\$G7"
    ;;
esac
exit 0
EOF
chmod +x "$MOCKBIN/app_process"
PATH="$MOCKBIN:$PATH"
export PATH
APP_PROCESS="$MOCKBIN/app_process"
export APP_PROCESS

# mock cmd wifi：记录调用（启动/停止走 cmd；配置读写走 bridge）
MOCK_LOG="$TMP_SYS_DIR/mock_cmd.log"
: > "$MOCK_LOG"
cat > "$TMP_SYS_DIR/cmdwifi" <<CMDEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$MOCK_LOG"
exit 0
CMDEOF
chmod +x "$TMP_SYS_DIR/cmdwifi"
CMD_WIFI="$TMP_SYS_DIR/cmdwifi"
export CMD_WIFI

# --- hotspot_set_config：Web 改 → Framework setSoftApConfiguration 持久化 ---
hotspot_set_config "New Hotspot" "wpa3" "Pass@123" "5" "149" "1" "8"
assert_eq 'set_config rc=0' '0' "$?"
"$BB" grep -q 'New Hotspot|wpa3|Pass@123|5|149|1|8' "$BRIDGE_LOG"; ok 'set_config 走 Framework setSoftApConfiguration（参数完整）' $?
# 持久化闭环：改完立刻从系统读到新配置（模拟 Web 改 → 系统变）
hotspot_get_config
assert_eq 'set_config 后系统配置 ssid' 'New Hotspot' "$sys_ssid"
assert_eq 'set_config 后系统配置 security' 'wpa3' "$sys_security"
assert_eq 'set_config 后系统配置 band' '5' "$sys_band"
assert_eq 'set_config 后系统配置 hidden' '1' "$sys_hidden"
assert_eq 'set_config 后系统配置 maxclients' '8' "$sys_maxclients"

# 密码留空 → 沿用系统当前密码（Framework 读 → set）
hotspot_set_config "New Hotspot" "wpa2" "" "2" "0" "0" "0"
assert_eq 'set_config 留空密码 rc=0' '0' "$?"
"$BB" grep -q 'New Hotspot|wpa2|Pass@123|2|0|0|0' "$BRIDGE_LOG"; ok 'set_config 留空密码沿用系统密码' $?

# open 网络 → 无密码
hotspot_set_config "Open-Net" "open" "" "2" "0" "0" "0"
assert_eq 'set_config open rc=0' '0' "$?"
"$BB" grep -q 'Open-Net|open||2|0|0|0' "$BRIDGE_LOG"; ok 'set_config open 网络无密码' $?

# 热点关闭时保存 → 不改变开启/关闭意图（不调用 start-softap）
if "$BB" grep -q 'start-softap' "$MOCK_LOG"; then ok 'set_config 热点关闭时仅持久化（不启动）' 1; else ok 'set_config 热点关闭时仅持久化（不启动）' 0; fi

# --- run_softap：系统已有配置 → 无参启动（用系统配置） ---
: > "$MOCK_LOG"
run_softap "" "" "" "" "" ""
"$BB" grep -q 'start-softap$' "$MOCK_LOG"; ok 'run_softap 系统已有配置 → 无参启动' $?

# --- run_softap：系统从未配置 + 模块旧参数 → 迁移（bridge 持久化）后无参启动 ---
: > "$MOCK_LOG"
: > "$BRIDGE_STATE"   # 模拟系统从未配置热点
run_softap "Migrated-AP" "wpa2" "12345678" "any" "0" "0"
"$BB" grep -q 'Migrated-AP|wpa2|12345678|any|0|0|0' "$BRIDGE_LOG"; ok 'run_softap 迁移：旧配置经 Framework 持久化' $?
"$BB" grep -q 'start-softap$' "$MOCK_LOG"; ok 'run_softap 迁移后无参启动（用系统配置）' $?
# 迁移后系统配置已生效（持久化闭环）
hotspot_get_config
assert_eq '迁移后系统配置 ssid' 'Migrated-AP' "$sys_ssid"
BRIDGE_LOG="$TMP_SYS_DIR/bridge_calls.log"
: > "$BRIDGE_STATE"
printf '%s' "Xiaomi14-MiFi|wpa2|87654321|any|0|0|0" > "$BRIDGE_STATE"

# 新版 SSID 标签（SoftApConfToXmlMigration 风格）
cat > "$TMP_SYS_DIR/store3.xml" <<'XMLEOF'
<WifiConfigStoreData>
<int name="Version" value="3" />
<SoftAp>
<string name="SSID">Modern-AP</string>
<int name="SecurityType" value="4" />
<string name="Passphrase">12345678</string>
<int name="Band" value="3" />
</SoftAp>
</WifiConfigStoreData>
XMLEOF
SYS_WIFI_STORE="$TMP_SYS_DIR/store3.xml"
sys_softap_get
assert_eq 'sys 新版SSID标签解析' 'Modern-AP' "$sys_ssid"
assert_eq 'sys 新版 安全类型4=wpa3_transition' 'wpa3_transition' "$sys_security"
assert_eq 'sys 新版 Band3=any' 'any' "$sys_band"

# 能力检测 JSON（mock cmd wifi：用假命令模拟 Android 13 风格 help）
cat > "$TMP_SYS_DIR/cmdwifi" <<'CMDEOF'
#!/bin/sh
if [ "$1" = "wifi" ] && [ "$2" = "help" ]; then
  cat <<'HELP'
cmd wifi help
  start-softap <ssid> (open|wpa2|wpa3) <passphrase> [-b 2|5|6|any] [-c channel] [-m max_clients] [-h]
  stop-softap
HELP
fi
exit 0
CMDEOF
chmod +x "$TMP_SYS_DIR/cmdwifi"
# mock 提供了 start-softap help → startStop=true；bridge 可用 → 读写 true / 同步 A
hotspot_detect_capabilities
CAPS=$HOTSPOT_CAPS_JSON
case "$CAPS" in *'"startStop":true'*) ok 'caps cmd wifi 支持 start-softap → startStop=true' 0 ;; *) ok 'caps cmd wifi 支持 start-softap → startStop=true' 1 ;; esac
case "$CAPS" in *'"readConfig":true'*) ok 'caps bridge 可读 → readConfig=true' 0 ;; *) ok 'caps bridge 可读 → readConfig=true' 1 ;; esac
case "$CAPS" in *'"writeConfig":true'*) ok 'caps bridge 可写 → writeConfig=true' 0 ;; *) ok 'caps bridge 可写 → writeConfig=true' 1 ;; esac
case "$CAPS" in *'"syncLevel":"A"'*) ok 'caps 同步级别 A（Framework 双向）' 0 ;; *) ok 'caps 同步级别 A（Framework 双向）' 1 ;; esac
case "$CAPS" in *'"android":34'*) ok 'caps android=34（getprop mock）' 0 ;; *) ok 'caps android=34（getprop mock）' 1 ;; esac
# 真正无 cmd wifi（路径不存在）→ startStop=false（bridge 读写不受影响）
CMD_WIFI=/nonexistent/cmd
hotspot_detect_capabilities
CAPS=$HOTSPOT_CAPS_JSON
case "$CAPS" in *'"startStop":false'*) ok 'caps 无 cmd wifi → startStop=false' 0 ;; *) ok 'caps 无 cmd wifi → startStop=false' 1 ;; esac
case "$CAPS" in *'"writeConfig":true'*) ok 'caps 无 cmd wifi 仍可写（bridge 独立）' 0 ;; *) ok 'caps 无 cmd wifi 仍可写（bridge 独立）' 1 ;; esac
case "$CAPS" in *'"android":'*'"band2g":'*'"hiddenSsid":'*'"channelControl":'*'"maxClients":'*) ok 'caps JSON 字段齐全' 0 ;; *) ok 'caps JSON 字段齐全' 1 ;; esac
# 统一接口可用性
hotspot_get_capabilities >/dev/null 2>&1; ok '接口 hotspot_get_capabilities' $?
hotspot_get_config >/dev/null 2>&1; ok '接口 hotspot_get_config' $?
rm -rf "$TMP_SYS_DIR"

echo
echo "== 结果：$PASS 通过 / $FAIL 失败 =="
if [ "$FAIL" -gt 0 ]; then
  printf '%b\n' "$FAILED"
  exit 1
fi
echo "全部通过 ✓"
exit 0
