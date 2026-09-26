#!/usr/bin/env bash
# 原生版打包（路径 B：Apple Development 签名、不公证，D7）：archive → 自检 → arm64 DMG → notes
# 发布约束：GitHub 只发 pre-release，不要勾 Set as latest（Tauri updater 读 releases/latest/.../latest.json，
#   被顶掉会让 Tauri 全平台更新 404）；GitCode 在确认 latest 排除预发布之前不发；
#   发完在 master 工作区跑 pnpm release:verify。发布说明固定附「系统设置 › 隐私与安全性 › 仍要打开」步骤。
# 产物名跟 PRODUCT_NAME 走（N16：Kitty Tools.app、卷名 Kitty Tools、Kitty Tools_<版本>_arm64.dmg，之前叫 Kitty Tools Native）。
#   和 Tauri 旧版同名，发布说明还要附：安装前先删掉（或让访达替换）/Applications 里旧版的 Kitty Tools.app；
#   从 Kitty Tools Native 升上来的，把旧的 Kitty Tools Native.app 也删掉（同一个 bundle id，留着会让开机自启指错），
#   开机自启可能要在 设置 › 通用 重新打开一次。
# DMG 窗口（Whisker 品牌时刻）：背景 Config/dmg-background.tiff（设计区 600×400 在左上角：左 App、右「应用程序」、中间品牌粉箭头，
#   底下写着「仍要打开」的路径；整张 2560×1600 pt、@1x + @2x——访达从窗口左上角 1:1 贴背景、不缩放，窗口拉大时靠多出来的
#   奶油底盖住，不露白；由 swift macos/brand-icons.swift 生成，字标写死 Kitty Tools，改名要改那个脚本重跑），
#   用 hdiutil 做可写映像 + AppleScript 让访达摆位置（隐藏的 .background 挪到默认窗口外、删掉 .fseventsd，
#   免得开了「显示隐藏文件」时压在字标上），再压成只读。第一次跑会问能不能控制访达；
#   不允许或 DMG_LAYOUT=0 时照样出包，只是没有背景和摆位。
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
if [[ "${DMG_LAYOUT:-1}" == 0 ]]; then
  hdiutil create -volname "$NAME" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG"
else
  mkdir -p "$OUT/dmg/.background" && cp "$M/Config/dmg-background.tiff" "$OUT/dmg/.background/background.tiff"
  RW="$OUT/rw.dmg"
  hdiutil create -volname "$NAME" -srcfolder "$OUT/dmg" -format UDRW -ov "$RW"
  # 同名卷已经挂着（上次没卸掉）时访达会摆错窗口：先卸
  [[ -d "/Volumes/$NAME" ]] && hdiutil detach "/Volumes/$NAME" -force >/dev/null || true
  MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
  # 窗口 600×400（加标题栏，正好是背景的设计区）、图标 112、App 在 (150, 205)、「应用程序」在 (450, 205)，和背景图对齐
  osascript <<APPLESCRIPT || echo "访达摆位没成功（没有控制访达的权限？），DMG 照样出，只是没有背景"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {150, 205}
    set position of item "Applications" of container window to {450, 205}
    -- 开了「显示隐藏文件」的访达会把 .background 画出来：挪到默认窗口右边（扩展背景上），不压字标和图标；
    -- 没开时访达拿不到这个隐藏项，忽略
    try
      set position of item ".background" of container window to {860, 205}
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  # 挂载时系统写进来的事件日志目录：开了「显示隐藏文件」会露在窗口里，只读映像里也用不上
  rm -rf "$MOUNT/.fseventsd"
  sync
  hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null
  hdiutil convert "$RW" -format UDZO -ov -o "$DMG"
  rm -f "$RW"
fi
hdiutil verify "$DMG"
jq -r --arg v "$VERSION" '.[] | select(.version == $v) | .summary, (.changes[] | "- \(.scope)：\(.text)")' \
  "$CHANGELOG" > "$OUT/notes.txt"
echo "$DMG"
