#!/system/bin/sh
. "$(dirname "$0")/../../../lib/common.sh"
load_config
. "$MODDIR/lib/common.sh"

echo "Content-Type: application/json"
echo ""

[ "$REQUEST_METHOD" = "GET" ] || { echo '{"ok":false,"message":"仅支持GET"}'; exit 0; }

QUERY_STRING=$(getenv QUERY_STRING)
ACTION=$(echo "$QUERY_STRING" | sed 's/.*action=\([^&]*\).*/\1/' | b64d 2>/dev/null || echo "")
[ -z "$ACTION" ] && ACTION="proxies"

if ! proxy_is_running; then
  echo '{"ok":false,"message":"Mihomo未运行"}'
  exit 0
fi

case "$ACTION" in
  proxies)
    DATA=$(proxy_api GET /proxies)
    if [ -z "$DATA" ]; then
      echo '{"ok":false,"message":"Mihomo控制接口不可用"}'
    else
      printf '{"ok":true,"data":%s}' "$DATA"
    fi
    ;;
  provider)
    DATA=$(proxy_api GET /providers/proxies/airport)
    if [ -z "$DATA" ]; then
      echo '{"ok":false,"message":"Mihomo控制接口不可用"}'
    else
      printf '{"ok":true,"data":%s}' "$DATA"
    fi
    ;;
  version)
    DATA=$(proxy_api GET /version)
    if [ -z "$DATA" ]; then
      echo '{"ok":false,"message":"Mihomo控制接口不可用"}'
    else
      printf '{"ok":true,"data":%s}' "$DATA"
    fi
    ;;
  *)
    echo '{"ok":false,"message":"未知action"}'
    ;;
esac
