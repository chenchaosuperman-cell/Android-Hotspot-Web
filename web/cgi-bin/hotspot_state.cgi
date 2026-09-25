#!/system/bin/sh
MODDIR=/data/adb/modules/xiaomi_mifi_web
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
  MODDIR=${SCRIPT_PATH%/web/cgi-bin/hotspot_state.cgi}
fi
if [ ! -r "$MODDIR/lib/common.sh" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"error":"module common library not found"}'
  exit 0
fi
. "$MODDIR/lib/common.sh"
header_json

# Default path is cache-only and very cheap. During a user start/stop transition,
# ?live=1 asks compat.sh for the live Bridge/Framework SoftAP state so the page
# does not wait for the heavy full status JSON cache to refresh.
case "${QUERY_STRING:-}" in
  *live=1*) CGI_READONLY=0 ;;
  *) CGI_READONLY=1 ;;
esac
HOTSPOT_STATE=UNKNOWN
hotspot_get_state
case "$SNAP_AP_STATE" in
  ENABLED|ENABLED_AND_SUSPENDED) HOTSPOT_STATE=ON ;;
  ENABLING) HOTSPOT_STATE=STARTING ;;
  DISABLING) HOTSPOT_STATE=STOPPING ;;
  DISABLED) HOTSPOT_STATE=OFF ;;
  FAILED) HOTSPOT_STATE=ERROR ;;
esac
DESIRED=$("$BB" head -n 1 "$DESIRED_FILE" 2>/dev/null)
[ "$DESIRED" = "1" ] || DESIRED=0
printf '{"ok":true,"hotspotState":"%s","desired":%s,"ts":%s}' \
  "$HOTSPOT_STATE" "$([ "$DESIRED" = "1" ] && echo true || echo false)" "$(date +%s)"
