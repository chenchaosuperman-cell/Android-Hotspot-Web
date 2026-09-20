#!/system/bin/sh

PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

MOD_VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)
ui_print "*******************************"
ui_print " Android-Hotspot-Web v${MOD_VER}"
ui_print " Root Android Hotspot Manager"
ui_print "*******************************"
ui_print "Default Wi-Fi password: 87654321"
ui_print "Web port: 8080"
ui_print "Web login: admin / admin"
ui_print "IMPORTANT: change the Web password after first login."

# Download Mihomo core if not bundled
MIHOMO_BIN="$MODPATH/bin/mihomo"
MIHOMO_VER="v1.19.31"
if [ ! -f "$MIHOMO_BIN" ]; then
  ui_print "- Downloading Mihomo core $MIHOMO_VER ..."
  mkdir -p "$MODPATH/bin"
  RAW_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-android-arm64-v8-${MIHOMO_VER}.gz"
  # 多镜像 fallback：国内镜像优先，最后直连 GitHub
  URLS="$RAW_URL
https://ghfast.top/$RAW_URL
https://mirror.ghproxy.com/$RAW_URL
https://gh-proxy.com/$RAW_URL
https://ghproxy.net/$RAW_URL
https://ghps.cc/$RAW_URL"
  echo "$URLS" | while read -r URL; do
    [ -z "$URL" ] && continue
    ui_print "  Trying: $(echo "$URL" | cut -c1-60)..."
    for TRY in 1 2; do
      if curl -fsSL --connect-timeout 15 --max-time 180 "$URL" -o /tmp/mihomo.gz 2>/dev/null; then
        if gunzip -f /tmp/mihomo.gz 2>/dev/null && [ -s /tmp/mihomo ]; then
          mv /tmp/mihomo "$MIHOMO_BIN"
          echo "OK" > /tmp/mihomo_dl_ok
          break
        fi
      fi
      ui_print "  retry $TRY..."
      sleep 2
    done
    [ -f /tmp/mihomo_dl_ok ] && break
  done
  if [ -f "$MIHOMO_BIN" ]; then
    ui_print "- Mihomo core downloaded OK"
  else
    ui_print "- WARN: Mihomo core download failed after all mirrors."
    ui_print "- You can manually place it at: $MIHOMO_BIN"
    ui_print "- File: mihomo-android-arm64-v8 $MIHOMO_VER"
  fi
  rm -f /tmp/mihomo_dl_ok /tmp/mihomo.gz /tmp/mihomo
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/web/cgi-bin" 0 0 0755 0755
set_perm "$MODPATH/lib/common.sh" 0 0 0755 0644

[ -f "$MODPATH/bin/mihomo" ] && set_perm "$MODPATH/bin/mihomo" 0 0 0755
[ -f "$MODPATH/bin/geoip.metadb" ] && set_perm "$MODPATH/bin/geoip.metadb" 0 0 0644
