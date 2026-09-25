#!/system/bin/sh
# ============================================================
# export_diag.cgi — 导出诊断包
# 一键收集 service.log / 缓存 / 运行时状态 / 脱敏配置，
# 打包成 tar(.gz) 供下载，便于在其它机器上排查问题。
# 敏感信息脱敏：config 密码/订阅/短信/token 打码；日志中 token/password 打码。
# 用法：浏览器直接访问 /cgi-bin/export_diag.cgi（需登录）
# ============================================================

MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/export_diag.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
  printf '模块公共组件不存在'
  exit 0
fi

BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null)

. "$MODDIR/lib/common.sh" 2>/dev/null
load_config 2>/dev/null

TS=$(/system/bin/date +%Y%m%d_%H%M%S 2>/dev/null || date +%Y%m%d_%H%M%S)
TMP="$DATA_DIR/.diag_export.$$"
mkdir -p "$TMP" 2>/dev/null
[ -d "$TMP" ] || { printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n无法创建临时目录'; exit 1; }

# ---------- 1. 版本与核心日志 ----------
cp -f "$MODDIR/module.prop" "$TMP/module.prop" 2>/dev/null
"$BB" tail -n 3000 "$LOG" 2>/dev/null | "$BB" sed -E 's/(token=)[^ &"]*/\1***/g; s/(password=)[^ &"]*/\1***/g; s/(sub_b64=)[^ &"]*/\1***/g; s/(B64=)[^ ]*/\1***/g' > "$TMP/service.log" 2>/dev/null

# ---------- 2. 状态/能力/传感器缓存 ----------
cp -f "$DATA_DIR/status.json.cache" "$TMP/status.json" 2>/dev/null
for C in hotspot_iface.cache softap.cache hotspot_caps.cache system_hotspot.cache \
         battery.cache thermal.cache sim.cache signal.cache cell.cache usage_iface \
         proxy.cache proxy_error.cache; do
  [ -r "$DATA_DIR/$C" ] && cp -f "$DATA_DIR/$C" "$TMP/$C" 2>/dev/null
done
[ -r "$DATA_DIR/operation.status" ] && cp -f "$DATA_DIR/operation.status" "$TMP/operation.status" 2>/dev/null
[ -r "$DATA_DIR/udhcpd.conf" ] && cp -f "$DATA_DIR/udhcpd.conf" "$TMP/udhcpd.conf" 2>/dev/null
[ -r "$DATA_DIR/udhcpd.leases" ] && cp -f "$DATA_DIR/udhcpd.leases" "$TMP/udhcpd.leases" 2>/dev/null
[ -r "$DATA_DIR/udhcpd.log" ] && "$BB" tail -n 300 "$DATA_DIR/udhcpd.log" > "$TMP/udhcpd.log" 2>/dev/null

# ---------- 3. 脱敏配置（密码/订阅/短信/令牌一律打码） ----------
"$BB" awk -F= '{k=tolower($1); if(k ~ /password|passwd|sub_url|sub_b64|sms_fwd_|csrf|token|secret|apikey|webhook|key/) {print $1"=***"} else {print}}' \
  "$DATA_DIR/config.conf" > "$TMP/config_masked.txt" 2>/dev/null

# ---------- 4. 运行时状态汇总 ----------
{
  echo "module: xiaomi_mifi_web"
  echo "time: $(date 2>/dev/null)"
  echo "iface: $(cat "$DATA_DIR/hotspot_iface.cache" 2>/dev/null)"
  echo "upstream: $(get_upstream_iface 2>/dev/null)"
  echo "softap: $(grep SNAP_AP_STATE "$DATA_DIR/softap.cache" 2>/dev/null)"
  echo "selinux: $(/system/bin/getenforce 2>/dev/null)"
  echo "--- ip -4 addr ---"
  /system/bin/ip -o -4 addr show 2>/dev/null
  echo "--- route table local_network ---"
  /system/bin/ip route show table local_network 2>/dev/null
  echo "--- route main ---"
  /system/bin/ip route show 2>/dev/null
  echo "--- ip rule ---"
  /system/bin/ip rule show 2>/dev/null
  echo "--- route table all defaults ---"
  /system/bin/ip -4 route show table all 2>/dev/null | grep '^default'
  echo "--- iptables FORWARD ---"
  $IPT -S FORWARD 2>/dev/null
  echo "--- iptables mifi 链 ---"
  $IPT -S 2>/dev/null | grep -i mifi
  echo "--- iptables -t nat (前 30 行) ---"
  $IPT -t nat -S 2>/dev/null | head -30
  echo "--- ip6tables mifi 链 ---"
  $IPT6 -S 2>/dev/null | grep -i mifi
  echo "--- udhcpd 进程 ---"
  ps -ef 2>/dev/null | grep -i udhcpd | grep -v grep
  echo "--- mihomo 进程 ---"
  ps -ef 2>/dev/null | grep -i mihomo | grep -v grep
  echo "--- httpd 进程 ---"
  ps -ef 2>/dev/null | grep -i httpd | grep -v grep
  echo "--- supervisor 进程 ---"
  ps -ef 2>/dev/null | grep -E "service\.sh|xiaomi_mifi_web" | grep -v grep
  echo "--- clients (list_clients) ---"
  list_clients "$(cat "$DATA_DIR/hotspot_iface.cache" 2>/dev/null)" 2>/dev/null | head -30
} > "$TMP/runtime.txt" 2>/dev/null

# ---------- 5. 关键系统属性 ----------
{
  echo "model: $(getprop ro.product.model 2>/dev/null)"
  echo "brand: $(getprop ro.product.brand 2>/dev/null)"
  echo "android: $(getprop ro.build.version.release 2>/dev/null)"
  echo "sdk: $(getprop ro.build.version.sdk 2>/dev/null)"
  echo "miui: $(getprop ro.miui.ui.version.name 2>/dev/null)"
  echo "kernel: $(uname -r 2>/dev/null)"
  echo "ksu: $(ls /data/adb/ksu 2>/dev/null | head -3)"
  echo "--- getprop 网络相关 ---"
  getprop 2>/dev/null | grep -iE "tether|softap|wifi\.interface|net\.dns" | head -20
} > "$TMP/getprop.txt" 2>/dev/null

# ---------- 6. 代理状态 ----------
{
  echo "proxy_enable: ${PROXY_ENABLE:-0}"
  echo "proxy_self: ${PROXY_SELF:-0}"
  proxy_is_running 2>/dev/null && echo "proxy_running: true" || echo "proxy_running: false"
  [ -r "$DATA_DIR/proxy.cache" ] && { echo "--- proxy.cache ---"; cat "$DATA_DIR/proxy.cache" 2>/dev/null; }
} > "$TMP/proxy.txt" 2>/dev/null

# ---------- 7. 打包 ----------
OUT_DIR="$DATA_DIR"
OUT="$OUT_DIR/diagnostic_${TS}.tar"
CT="application/x-tar"
EXT=".tar"

TAR_CMD=""
if [ -x /system/bin/tar ]; then
  TAR_CMD=/system/bin/tar
elif "$BB" tar --help >/dev/null 2>&1; then
  TAR_CMD="$BB tar"
fi

if [ -n "$TAR_CMD" ]; then
  if command -v gzip >/dev/null 2>&1; then
    ( cd "$TMP" && $TAR_CMD -cf - . 2>/dev/null ) | gzip > "$OUT.gz" 2>/dev/null
    if [ -s "$OUT.gz" ]; then
      OUT="$OUT.gz"; CT="application/gzip"; EXT=".tar.gz"
    else
      rm -f "$OUT.gz"
      $TAR_CMD -cf "$OUT" -C "$TMP" . 2>/dev/null
    fi
  else
    $TAR_CMD -cf "$OUT" -C "$TMP" . 2>/dev/null
  fi
fi

if [ ! -s "$OUT" ]; then
  printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
  printf '打包失败：设备上无可用 tar（%s）' "$TAR_CMD"
  rm -rf "$TMP"
  exit 0
fi

# ---------- 8. 输出 ----------
SZ=$("$BB" wc -c < "$OUT" 2>/dev/null | "$BB" tr -d ' ')
printf 'Content-Type: %s\r\n' "$CT"
printf 'Content-Disposition: attachment; filename="diagnostic_%s%s"\r\n' "$TS" "$EXT"
printf 'Content-Length: %s\r\n' "$SZ"
printf 'Cache-Control: no-store\r\n\r\n'
cat "$OUT" 2>/dev/null
rm -rf "$TMP" "$OUT"
exit 0
