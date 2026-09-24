#!/usr/bin/env bash
# 原生版打包（路径 B：Apple Development 签名、不公证，D7）：archive → 自检 → arm64 DMG → notes
# 发布约束：GitHub 只发 pre-release，不要勾 Set as latest（Tauri updater 读 releases/latest/.../latest.json，
#   被顶掉会让 Tauri 全平台更新 404）；GitCode 在确认 latest 排除预发布之前不发；
#   发完在 master 工作区跑 pnpm release:verify。发布说明固定附「系统设置 › 隐私与安全性 › 仍要打开」步骤。
set -euo pipefail
M="$(cd "$(dirname "$0")" && pwd)"; OUT="$M/build"; CHANGELOG="$M/KittyTools/Resources/changelog.json"
rm -rf "$OUT/KittyTools.xcarchive" "$OUT/dmg" && mkdir -p "$OUT/dmg"
xcodebuild archive -project "$M/KittyTools.xcodeproj" -scheme KittyTools -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/KittyTools.xcarchive" -quiet
APP=$(ls -d "$OUT"/KittyTools.xcarchive/Products/Applications/*.app)
NAME=$(basename "$APP" .app)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
jq -e --arg v "$VERSION" 'any(.[]; .version == $v)' "$CHANGELOG" >/dev/null \
  || { echo "changelog.json 缺少 $VERSION 条目"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
# 先存变量再判断：pipefail 下 grep -q 提前退出会让管道报错，导致漏报
ENT=$(codesign -d --entitlements - "$APP" 2>&1 || true)
[[ "$ENT" != *get-task-allow* ]] || { echo "get-task-allow 混入发布包"; exit 1; }
lipo -archs "$APP/Contents/MacOS/$NAME"
ditto "$APP" "$OUT/dmg/$NAME.app" && ln -s /Applications "$OUT/dmg/Applications"
DMG="$OUT/${NAME}_${VERSION}_arm64.dmg"
hdiutil create -volname "$NAME" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
jq -r --arg v "$VERSION" '.[] | select(.version == $v) | .summary, (.changes[] | "- \(.scope)：\(.text)")' \
  "$CHANGELOG" > "$OUT/notes.txt"
echo "$DMG"
