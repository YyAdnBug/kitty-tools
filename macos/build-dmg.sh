#!/usr/bin/env bash
# 原生版打包（路径 B：Apple Development 签名、不公证，D7）：archive → 自检 → arm64 DMG + 更新用 zip + 更新清单 → notes
# 发布（2026-09-27 起，和 Tauri 版的仓库无关）：发到本仓库 github.com/YyAdnBug/kitty-tools，tag macos-v<版本>、
#   正式 release、**标 latest**，附三个文件：DMG（首次安装）、<名字>_<版本>_arm64.zip（App 内更新下载它，文件名后缀 _arm64.zip 别改）、
#   更新清单 macos-update.json（2026-11-09，issue #12）。App 内更新先读 releases/latest/download/macos-update.json（静态文件，
#   不走 API、不受没登录时每个 IP 每小时 60 次的限制），读不到才读 API 的 release 列表、取版本号最大的 macos-v*（第四轮体检 E13）——
#   所以 latest 必须一直是 mac 版（Windows 版、表情包这些 release 一律 --latest=false），清单必须传上去。清单里是版本号、zip 的下载地址
#   （按 GitHub 上传后的名字：空格换成「.」）、sha256、大小、发布页；**格式发布后别改**（已装的版本会读它，见
#   Updater.release(fromManifest:)：只加新键，要改已有键的意思就换文件名、旧名字的照发）。传完核一遍（两条都要 200）：
#     curl -fsSL https://github.com/YyAdnBug/kitty-tools/releases/latest/download/macos-update.json
#     curl -fsIL "$(curl -fsSL https://github.com/YyAdnBug/kitty-tools/releases/latest/download/macos-update.json | jq -r .url)"
#   发布说明固定附「系统设置 › 隐私与安全 › 仍要打开」步骤（只有第一次安装要；之后 App 内更新下载的包不带隔离标记，不用再放行）。
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
# 访达扩展（第十一族「访达右键」，mac-native §6）：在包里、本团队签名、开着沙盒、没有 get-task-allow
FX="$APP/Contents/PlugIns/KittyToolsFinder.appex"
codesign --verify --strict \
  -R '=identifier "com.yy.kitty-tools.native.finder" and anchor apple generic and certificate leaf[subject.OU] = "HTX9F4KG39"' \
  "$FX"
FXENT=$(codesign -d --entitlements - "$FX" 2>&1 || true)
[[ "$FXENT" == *com.apple.security.app-sandbox* ]] || { echo "访达扩展没开沙盒"; exit 1; }
[[ "$FXENT" != *get-task-allow* ]] || { echo "get-task-allow 混入访达扩展"; exit 1; }
# 正在播放服务（刘海岛扩展第 2 期，mac-native §2 §6）：在包里、bundle id 是 com.apple.kittytools.nowplaying（mediaremoted 认 Info.plist
# 的 bundle id，以 com.apple. 开头才给别的 App 的播放信息）、本团队签名、开着强化运行时、没有 get-task-allow
NP="$APP/Contents/XPCServices/KittyToolsNowPlaying.xpc"
codesign --verify --strict \
  -R '=identifier "com.apple.kittytools.nowplaying" and anchor apple generic and certificate leaf[subject.OU] = "HTX9F4KG39"' \
  "$NP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NP/Contents/Info.plist")" == com.apple.kittytools.nowplaying ]] \
  || { echo "正在播放服务的 bundle id 不对"; exit 1; }
NPSIGN=$(codesign -dv "$NP" 2>&1 || true)
[[ "$NPSIGN" == *"(runtime)"* ]] || { echo "正在播放服务没开强化运行时"; exit 1; }
NPENT=$(codesign -d --entitlements - "$NP" 2>&1 || true)
[[ "$NPENT" != *get-task-allow* ]] || { echo "get-task-allow 混入正在播放服务"; exit 1; }
# 内置智谱 key（来自不入库的 Secrets.xcconfig）要真打进包里，否则「装好就能用」不成立；只判断非空，不打印
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :KittyBuiltinZhipuKey' "$APP/Contents/Info.plist" 2>/dev/null)" ]] \
  || { echo "内置智谱 key 没打进包（缺 macos/Config/Secrets.xcconfig？）"; exit 1; }
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
# App 内更新用的 zip（Updater 下载后 ditto 解开、按同样的签名要求验签）：打完就解开验一次，别发出去才发现装不上
ZIP="$OUT/${NAME}_${VERSION}_arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
CHECK="$OUT/zip-check" && rm -rf "$CHECK" && ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict \
  -R '=identifier "com.yy.kitty-tools.native" and anchor apple generic and certificate leaf[subject.OU] = "HTX9F4KG39"' \
  "$CHECK/$NAME.app"
rm -rf "$CHECK"
# 更新清单（#12，说明见文件头）：文件名和 Updater.manifestName 一样（单测比对）
ZIPNAME=$(basename "$ZIP") && TAG="macos-v$VERSION" && REL="https://github.com/YyAdnBug/kitty-tools/releases"
MANIFEST="$OUT/macos-update.json"
jq -n --arg version "$VERSION" --arg url "$REL/download/$TAG/${ZIPNAME// /.}" \
  --arg sha256 "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" --argjson size "$(stat -f%z "$ZIP")" \
  --arg page "$REL/tag/$TAG" '{version: $version, url: $url, sha256: $sha256, size: $size, page: $page}' \
  > "$MANIFEST"
jq -r --arg v "$VERSION" '.[] | select(.version == $v) | .summary, (.changes[] | "- \(.scope)：\(.text)")' \
  "$CHANGELOG" > "$OUT/notes.txt"
echo "$DMG"
echo "$ZIP"
echo "$MANIFEST"
