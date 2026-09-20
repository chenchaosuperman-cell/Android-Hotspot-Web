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

# 模块目录去重自检：安装/更新时清理与当前模块同 id 的“非标准目录”残留副本
# （标准目录 = /data/adb/modules/<id>，KernelSU 规范要求目录名必须等于 MODID）。
# 修复 KSU 管理器下滑模块列表闪退（重复 id → LazyColumn key 冲突）。
# 残留目录移入 /data/adb/ksu/modules_dup_bak/ 备份，不直接删除。
MOD_ID=$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)
if [ -n "$MOD_ID" ]; then
  STD_DIR=/data/adb/modules/$MOD_ID
  BK_DIR=/data/adb/ksu/modules_dup_bak
  for D in /data/adb/modules/*/; do
    [ -d "$D" ] || continue
    D=${D%/}
    [ "$D" = "$MODPATH" ] && continue
    [ "$D" = "$STD_DIR" ] && continue
    [ -f "$D/module.prop" ] || continue
    DID=$(sed -n 's/^id=//p' "$D/module.prop" 2>/dev/null | head -n 1)
    if [ -n "$DID" ] && [ "$DID" = "$MOD_ID" ]; then
      mkdir -p "$BK_DIR" 2>/dev/null
      TS=$(date +%Y%m%d-%H%M%S 2>/dev/null); [ -z "$TS" ] && TS=$$
      if mv "$D" "$BK_DIR/$(basename "$D").$TS" 2>/dev/null; then
        ui_print "- dedup: moved non-standard duplicate module $D"
      fi
    fi
  done
fi

# 首次安装生成随机后台管理密码（升级保留用户已有 httpd.conf 密码，不覆盖）。
# 密码写入模块目录 .admin_pwd，由 service.sh 首次创建 httpd.conf 时读取并删除。
if [ ! -f "$MODPATH/.admin_pwd" ]; then
  GEN_PWD=$(od -An -N9 -tx1 /dev/urandom 2>/dev/null | tr -d ' \r\n' | cut -c1-12)
  case "$GEN_PWD" in ''|*[!A-Za-z0-9._@!-]*) GEN_PWD= ;; esac
  if [ -n "$GEN_PWD" ]; then
    printf '%s\n' "$GEN_PWD" > "$MODPATH/.admin_pwd"
    chmod 0600 "$MODPATH/.admin_pwd"
    ui_print "  ** 本次安装生成的后台管理密码：$GEN_PWD"
    ui_print "  ** 请立即保存；登录后可在 设置 → 修改后台密码 中更换"
  fi
fi

# Download Mihomo core if not bundled（供应链加固 v1.7.1）：
# 1) 仅支持 arm64：其他架构停止安装代理组件
# 2) 下载后必须通过官方 SHA-256 校验（gz 与解压后二进制双重校验），失败立即删除绝不执行
# 3) 临时文件使用 KernelSU 提供的 $TMPDIR，不共用 /tmp/mihomo
MIHOMO_BIN="$MODPATH/bin/mihomo"
MIHOMO_VER="v1.19.31"
# 官方 v1.19.31 android-arm64-v8 的 SHA-256（2026-09-20 从官方 release 镜像核验）
MIHOMO_GZ_SHA="de00bc53ed151636ca078c812a82a5315687d8d52164db230f1935b2a37904f6"
MIHOMO_BIN_SHA="dbd8af275219a097d66362d543b32f65ba0d4de9d96a49bf5e9abdcdad3af6f1"
ARCH_CHECK=$(printf '%s' "${ARCH:-$(uname -m 2>/dev/null)}" | tr 'A-Z' 'a-z')
ARCH_OK=0
case "$ARCH_CHECK" in
  arm64|aarch64|armv8*) ARCH_OK=1 ;;
esac
if [ ! -f "$MIHOMO_BIN" ] && [ "$ARCH_OK" != "1" ]; then
  ui_print "- ============================================"
  ui_print "- 当前架构 $ARCH_CHECK 不是 arm64，跳过 Mihomo 代理核心下载"
  ui_print "- 科学上网功能不可用（模块主体仍可正常安装使用）"
  ui_print "- ============================================"
fi
if [ ! -f "$MIHOMO_BIN" ] && [ "$ARCH_OK" = "1" ]; then
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
  SHA_BIN=$(command -v sha256sum 2>/dev/null || echo /system/bin/sha256sum)
  TMPD="${TMPDIR:-/data/local/tmp}"
  mkdir -p "$TMPD"
  MIHOMO_GZ="$TMPD/mihomo.$$.gz"
  MIHOMO_TMP="$TMPD/mihomo.$$"
  DL_OK=
  printf '%s\n' "$URLS" | while read -r URL; do
    [ -z "$URL" ] && continue
    ui_print "  Trying: $(echo "$URL" | cut -c1-60)..."
    for TRY in 1 2; do
      if curl -fsSL --connect-timeout 15 --max-time 180 "$URL" -o "$MIHOMO_GZ" 2>/dev/null; then
        # 校验 1：gz 文件 SHA-256 必须等于官方值
        GOT_GZ_SHA=$($SHA_BIN "$MIHOMO_GZ" 2>/dev/null | awk '{print $1}')
        if [ "$GOT_GZ_SHA" != "$MIHOMO_GZ_SHA" ]; then
          ui_print "    SHA256 mismatch (got $GOT_GZ_SHA), discarding"
          rm -f "$MIHOMO_GZ"
        elif gunzip -f "$MIHOMO_GZ" 2>/dev/null && [ -s "$MIHOMO_TMP" ]; then
          # 校验 2：解压后二进制 SHA-256 必须等于官方值
          GOT_BIN_SHA=$($SHA_BIN "$MIHOMO_TMP" 2>/dev/null | awk '{print $1}')
          if [ "$GOT_BIN_SHA" = "$MIHOMO_BIN_SHA" ]; then
            mv "$MIHOMO_TMP" "$MIHOMO_BIN"
            echo "OK" > "$TMPD/mihomo_dl_ok.$$"
            break
          else
            ui_print "    binary SHA256 mismatch (got $GOT_BIN_SHA), discarding"
            rm -f "$MIHOMO_TMP"
          fi
        else
          ui_print "    gunzip failed, discarding"
          rm -f "$MIHOMO_GZ" "$MIHOMO_TMP"
        fi
      fi
      ui_print "  retry $TRY..."
      sleep 2
    done
    [ -f "$TMPD/mihomo_dl_ok.$$" ] && break
  done
  if [ -f "$MIHOMO_BIN" ]; then
    # 校验 3：ELF magic + 可执行性
    MAGIC=$(od -An -tx1 -N4 "$MIHOMO_BIN" 2>/dev/null | tr -d ' \n')
    if [ "$MAGIC" = "7f454c46" ]; then
      chmod 0755 "$MIHOMO_BIN"
      VER=$("$MIHOMO_BIN" -v 2>/dev/null | head -n 1)
      if [ -n "$VER" ]; then
        ui_print "- Mihomo core OK (SHA256 verified): $VER"
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
    ui_print "- 原因：Mihomo 核心下载/校验失败（需 arm64 + 网络）"
    ui_print "- 解决：手动放置官方 mihomo 到 $MIHOMO_BIN"
    ui_print "- 或安装后执行: $MODPATH/action.sh"
    ui_print "- ============================================"
  fi
  rm -f "$MIHOMO_GZ" "$MIHOMO_TMP" "$TMPD/mihomo_dl_ok.$$"
fi


set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/web/cgi-bin" 0 0 0755 0755
set_perm "$MODPATH/lib/common.sh" 0 0 0755 0644

[ -f "$MODPATH/bin/mihomo" ] && set_perm "$MODPATH/bin/mihomo" 0 0 0755
[ -f "$MODPATH/bin/geoip.metadb" ] && set_perm "$MODPATH/bin/geoip.metadb" 0 0 0644
