#!/system/bin/sh

MODDIR=/data/adb/modules/xiaomi14_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/proxy.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"message":"模块公共组件不存在"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json
load_config

[ "${REQUEST_METHOD:-GET}" = "GET" ] || { printf '{"ok":false,"message":"仅支持GET"}'; exit 0; }
ACTION=$(get_param action)
[ -n "$ACTION" ] || ACTION=proxies

if ! proxy_is_running; then
  printf '{"ok":false,"message":"Mihomo未运行"}'
  exit 0
fi

case "$ACTION" in
  proxies)
    DATA=$(proxy_api GET /proxies "") || DATA=
    ;;
  provider)
    DATA=$(proxy_api GET /providers/proxies/airport "") || DATA=
    ;;
  version)
    DATA=$(proxy_api GET /version "") || DATA=
    ;;
  delay)
    DATA=$(proxy_group_delay) || DATA=
    ;;
  *)
    printf '{"ok":false,"message":"未知action"}'
    exit 0
    ;;
esac

if [ -z "$DATA" ]; then
  printf '{"ok":false,"message":"Mihomo控制接口不可用"}'
else
  printf '{"ok":true,"data":%s}' "$DATA"
fi
