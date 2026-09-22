#!/bin/bash
# ============================================================
# Android-Hotspot-Web 一键发布脚本
# 用法：在仓库根目录执行  ./release.sh
# 前置：module.prop 版本号已更新、CHANGELOG.md 已写好
# 流程：校验代理数据 → 打精简版+完整版 zip → 更新 update.json
#       → 提交推送代码 → 创建 GitHub Release → 上传两个 zip
# 数据说明：bin/ 内的 mihomo / geoip.metadb / geosite.dat 随完整版发布，
#           精简版安装时由 customize.sh 联网下载（校验 SHA-256）。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO="chenchaosuperman-cell/Android-Hotspot-Web"
VERSION=$(sed -n 's/^version=//p' module.prop)
VERSION_CODE=$(sed -n 's/^versionCode=//p' module.prop)
[ -n "$VERSION" ] || { echo "✗ 无法读取 module.prop 版本号"; exit 1; }
TAG="v$VERSION"
ZIP_LITE="Android-Hotspot-Web_KSU_${TAG}.zip"
ZIP_FULL="Android-Hotspot-Web_KSU_${TAG}_full.zip"
DIST="dist"

echo "=== 发布 ${TAG} (versionCode=${VERSION_CODE}) ==="

# ---------- 1. 校验代理数据（完整版依赖） ----------
for f in bin/mihomo bin/geoip.metadb bin/geosite.dat; do
  [ -s "$f" ] || { echo "✗ 缺少 $f，无法打完整版（可先执行 scripts/fetch-proxy-data.sh）"; exit 1; }
done
echo "✓ 代理数据完整"

# ---------- 2. 打包 ----------
mkdir -p "$DIST"
rm -f "$DIST/$ZIP_LITE" "$DIST/$ZIP_FULL"
zip -qr "$DIST/$ZIP_LITE" . -x 'bin/*' -x '.git/*' -x "$DIST/*" -x 'release.sh'
zip -qr "$DIST/$ZIP_FULL" . -x '.git/*' -x "$DIST/*" -x 'release.sh'
echo "✓ 精简版: $DIST/$ZIP_LITE ($(du -h "$DIST/$ZIP_LITE" | cut -f1))"
echo "✓ 完整版: $DIST/$ZIP_FULL ($(du -h "$DIST/$ZIP_FULL" | cut -f1))"

# ---------- 3. 更新 update.json（KernelSU 自动更新指向精简版） ----------
cat > update.json <<EOF
{
  "version": "$TAG",
  "versionCode": $VERSION_CODE,
  "zipUrl": "https://github.com/$REPO/releases/download/$TAG/$ZIP_LITE",
  "changelog": "https://raw.githubusercontent.com/$REPO/main/CHANGELOG.md"
}
EOF
echo "✓ update.json 已更新（指向精简版资产）"

# ---------- 4. 提交推送代码 ----------
git add -A update.json module.prop CHANGELOG.md README.md lib web service.sh action.sh customize.sh uninstall.sh release.sh .gitignore
if git diff --cached --quiet; then
  echo "· 代码无改动，跳过提交"
else
  git commit -m "$TAG: 发布准备（update.json / 文档）"
  git push origin main
  echo "✓ 代码已推送"
fi

# ---------- 5. 创建 Release 并上传 ----------
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')
[ -n "$TOKEN" ] || { echo "✗ 无法从 git 凭据获取 GitHub token"; exit 1; }

EXIST=$(curl -s -H "Authorization: token $TOKEN" "https://api.github.com/repos/$REPO/releases/tags/$TAG")
RID=$(printf '%s' "$EXIST" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("id",""))' 2>/dev/null || true)
if [ -n "$RID" ]; then
  echo "✗ Release $TAG 已存在（id=$RID），如需重新发布请先删除旧 Release"
  exit 1
fi

# 从 CHANGELOG 提取最新版本块作为 release body
BODY=$(python3 - "$TAG" <<'PYEOF'
import sys,re
tag=sys.argv[1]
txt=open('CHANGELOG.md',encoding='utf-8').read()
m=re.search(r'^# '+re.escape(tag)+r'（[^）]*）\s*\n(.*?)(?=^# |\Z)',txt,re.S|re.M)
print((m.group(1).strip() if m else '') or tag)
PYEOF
)
BODY_JSON=$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$BODY")

echo "· 创建 Release $TAG ..."
RELEASE=$(curl -s -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":$BODY_JSON,\"draft\":false,\"prerelease\":true}" \
  "https://api.github.com/repos/$REPO/releases")
RID=$(printf '%s' "$RELEASE" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("id",""))' 2>/dev/null || true)
[ -n "$RID" ] || { echo "✗ Release 创建失败：$(printf '%s' "$RELEASE" | head -c 300)"; exit 1; }
echo "✓ Release 已创建 id=$RID"

for Z in "$ZIP_LITE" "$ZIP_FULL"; do
  echo "· 上传 $Z ..."
  curl -s -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary "@$DIST/$Z" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$Z" >/dev/null
  echo "✓ 已上传 $Z"
done

echo ""
echo "=== 发布完成：$TAG ==="
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
