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

# 模块目录去重自检（v1.7.0）：安装/更新时清理与当前模块同 id 的残留目录，
# 修复 KernelSU 管理器下滑模块列表闪退（重复 id → LazyColumn key 冲突）。
# 残留目录移入 /data/adb/ksu/modules_dup_bak/ 备份，不直接删除。
MOD_ID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)
if [ -n "$MOD_ID" ]; then
  BK_DIR=/data/adb/ksu/modules_dup_bak
  for D in /data/adb/modules/*/; do
    [ -d "$D" ] || continue
    D=${D%/}
    [ "$D" = "$MODPATH" ] && continue
    [ -f "$D/module.prop" ] || continue
    DID=$(sed -n 's/^id=//p' "$D/module.prop" 2>/dev/null | head -n 1)
    if [ -n "$DID" ] && [ "$DID" = "$MOD_ID" ]; then
      mkdir -p "$BK_DIR" 2>/dev/null
      TS=$(date +%Y%m%d-%H%M%S 2>/dev/null); [ -z "$TS" ] && TS=$$
      if mv "$D" "$BK_DIR/$(basename "$D").$TS" 2>/dev/null; then
        ui_print "- dedup: moved duplicate module $D"
      fi
    fi
  done
fi

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
    # 校验：ELF magic
    MAGIC=$(od -An -tx1 -N4 "$MIHOMO_BIN" 2>/dev/null | tr -d ' \n')
    if [ "$MAGIC" = "7f454c46" ]; then
      chmod 0755 "$MIHOMO_BIN"
      VER=$("$MIHOMO_BIN" -v 2>/dev/null | head -n 1)
      if [ -n "$VER" ]; then
        ui_print "- Mihomo core OK: $VER"
      else
        ui_print "- WARN: mihomo -v failed, removing invalid binary"
        rm -f "$MIHOMO_BIN"
      fi
    else
      ui_print "- WARN: binary is not ELF (magic=$MAGIC), removing"
      rm -f "$MIHOMO_BIN"
    fi
  fi
  if [ ! -f "$MIHOMO_BIN" ]; then
    ui_print "- ============================================"
    ui_print "- 模块主体安装成功，但科学上网功能不可用"
    ui_print "- 原因：Mihomo 核心自动下载失败"
    ui_print "- 解决：手动放置 mihomo 到 $MIHOMO_BIN"
    ui_print "- 或安装后执行: $MODPATH/action.sh"
    ui_print "- ============================================"
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
