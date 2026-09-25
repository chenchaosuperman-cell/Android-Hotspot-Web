#!/system/bin/sh

MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/log.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"message":"模块公共组件不存在"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json

LINES=$(get_param lines)
case "$LINES" in ''|*[!0-9]*) LINES=50 ;; esac
[ "$LINES" -gt 200 ] && LINES=200

if [ -r "$LOG" ]; then
  TAIL=$("$BB" tail -n "$LINES" "$LOG" 2>/dev/null)
  # v1.9.1：日志含真实换行/回车，json_escape 不处理控制字符会产出非法 JSON
  # （前端报 Bad control character in string literal）。改用 json_escape_nl（\n 转义、\r 去化）。
  printf '{"ok":true,"log":"%s"}' "$(json_escape_nl "$TAIL")"
else
  printf '{"ok":false,"message":"日志文件不存在"}'
fi
