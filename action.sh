#!/system/bin/sh
# Xiaomi 14 MiFi Web Control - unified command interface
# Usage:
#   action.sh status --json     print status JSON
#   action.sh hotspot start     enable hotspot (clears manual-off)
#   action.sh hotspot stop      disable hotspot (manual-off this boot)
#   action.sh service restart   restart web/supervisor service
#   action.sh web-url           print local web URL
#   action.sh                   (no args) show info + restart service (legacy)

MODDIR=${0%/*}
DATA_DIR=/data/adb/xiaomi14_mifi_web
STABLE_IP=192.168.43.1
PORT=8080
DESIRED_FILE="$DATA_DIR/desired_state"
MANUAL_OFF_FILE="$DATA_DIR/manual_off"
[ -r "$DATA_DIR/config.conf" ] && {
  SAVED_PORT=$(/system/bin/sed -n 's/^PORT=//p' "$DATA_DIR/config.conf" 2>/dev/null | /system/bin/head -n 1)
  case "$SAVED_PORT" in ''|*[!0-9]*) ;; *) PORT=$SAVED_PORT ;; esac
}

cmd="$1"; sub="$2"

case "$cmd" in
  status)
    # 只有绑定了 192.168.43.1 的 wlan[1-9]+ 热点接口才算热点运行
    # （v1.7.2：必须限定接口名为 wlan 热点接口，避免 lo/其它接口误判）
    IFACE=$(/system/bin/ip -o -4 addr show 2>/dev/null | /system/bin/awk -v s="$STABLE_IP" '$2 ~ /^wlan[1-9][0-9]*$/ && $4 ~ "^"s"/" {print $2; exit}')
    RUNNING=false; [ -n "$IFACE" ] && RUNNING=true
    DESIRED=$(/system/bin/cat "$DESIRED_FILE" 2>/dev/null); [ "$DESIRED" = "1" ] || DESIRED=0
    MOFF=false; [ -f "$MANUAL_OFF_FILE" ] && MOFF=true
    if [ "$sub" = "--json" ]; then
      echo "{\"running\":$RUNNING,\"desired\":$DESIRED,\"manualOff\":$MOFF,\"interface\":\"$IFACE\"}"
    else
      echo "running=$RUNNING desired=$DESIRED manualOff=$MOFF iface=$IFACE"
    fi
    ;;
  hotspot)
    case "$sub" in
      start)
        rm -f "$MANUAL_OFF_FILE" 2>/dev/null
        echo 1 > "$DESIRED_FILE" && chmod 0600 "$DESIRED_FILE"
        # v1.7.1：与 Web 后台一致，按模块保存的 SSID/密码/频段/信道/最大客户端参数启动
        . "$MODDIR/lib/common.sh" 2>/dev/null
        load_config
        SSID=$(b64url_decode "$SSID_B64")
        PASS=$(b64url_decode "$PASS_B64")
        run_softap "$SSID" "$SECURITY" "$PASS" "$BAND" "$CHANNEL" "$MAX_CLIENTS" >/dev/null 2>&1
        echo "hotspot start requested with saved config"
        ;;
      stop)
        echo 1 > "$MANUAL_OFF_FILE" && chmod 0600 "$MANUAL_OFF_FILE"
        echo 0 > "$DESIRED_FILE" && chmod 0600 "$DESIRED_FILE"
        /system/bin/cmd wifi stop-softap >/dev/null 2>&1
        echo "hotspot stop requested (manual-off this boot)"
        ;;
      *) echo "usage: action.sh hotspot start|stop"; exit 1 ;;
    esac
    ;;
  service)
    if [ "$sub" = "restart" ]; then
      for f in httpd supervisor; do
        pf="$DATA_DIR/$f.pid"
        [ -f "$pf" ] || continue
        PID=$(/system/bin/cat "$pf" 2>/dev/null)
        case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
        [ "$PID" -gt 1 ] || continue
        [ -r "/proc/$PID/cmdline" ] || continue
        cmd=$(/system/bin/cat "/proc/$PID/cmdline" 2>/dev/null | /system/bin/tr '\000' ' ')
        [ -n "$cmd" ] || continue
        case "$f" in
          httpd) echo "$cmd" | /system/bin/grep -q httpd && /system/bin/kill "$PID" 2>/dev/null ;;
          supervisor) echo "$cmd" | /system/bin/grep -q "xiaomi_mifi_web" && /system/bin/kill "$PID" 2>/dev/null ;;
        esac
      done
      /system/bin/sleep 1
      /system/bin/nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
      echo "service restarted"
    else
      echo "usage: action.sh service restart"; exit 1
    fi
    ;;
  web-url)
    echo "http://127.0.0.1:$PORT"
    ;;
  *)
    # legacy: no args -> show info + restart
    IFACE=$(/system/bin/ip -o -4 addr show 2>/dev/null | /system/bin/awk -v s="$STABLE_IP" '$2 ~ /^wlan[1-9][0-9]*$/ && $4 !~ "^"s"/" {print $2; exit}')
    IP=""
    [ -n "$IFACE" ] && IP=$(/system/bin/ip -o -4 addr show dev "$IFACE" 2>/dev/null | /system/bin/awk '{split($4,a,"/"); print a[1]; exit}')
    echo "Xiaomi 14 MiFi Web Control"
    echo "Web: http://127.0.0.1:$PORT  (hotspot: http://$STABLE_IP:$PORT)"
    echo "Restarting service..."
    if [ -f "$DATA_DIR/httpd.pid" ]; then
      PID=$(/system/bin/cat "$DATA_DIR/httpd.pid" 2>/dev/null)
      case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
      if [ "$PID" -gt 1 ] && [ -r "/proc/$PID/cmdline" ]; then
        /system/bin/cat "/proc/$PID/cmdline" 2>/dev/null | /system/bin/tr '\000' ' ' | /system/bin/grep -q httpd && /system/bin/kill "$PID" 2>/dev/null
      fi
    fi
    if [ -f "$DATA_DIR/supervisor.pid" ]; then
      PID=$(/system/bin/cat "$DATA_DIR/supervisor.pid" 2>/dev/null)
      case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
      if [ "$PID" -gt 1 ] && [ -r "/proc/$PID/cmdline" ]; then
        /system/bin/cat "/proc/$PID/cmdline" 2>/dev/null | /system/bin/tr '\000' ' ' | /system/bin/grep -q xiaomi_mifi_web && /system/bin/kill "$PID" 2>/dev/null
      fi
    fi
    /system/bin/sleep 1
    /system/bin/nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "Done."
    ;;
esac
