#!/bin/zsh
# 把代码里能本地化的字面量并进 String Catalog（PLAN §10「多语言」，做法见 macos/TRANSLATION.md）。Xcode 打开工程构建时会自己并；
# 命令行 / agent 用这个：先构建（编译时每个 Swift 文件出一份 .stringsdata），再用 Xcode 自带的 xcstringstool sync 并进目录。
# 新抽出来的 key 没有英文（state new），代码里不用了的标成 stale；已有的英文原样留着。只认还在的源文件的 .stringsdata
# （删掉、改名的文件留在构建目录里的旧输出不算，不然它们的字会一直留在目录里）。
# 用法（仓库根目录）：macos/sync-strings.sh [derivedDataPath]（默认 macos/build/dd-strings）
set -euo pipefail
dd=${1:-macos/build/dd-strings}
xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools -derivedDataPath "$dd" build -quiet
for target in KittyTools KittyToolsFinder; do
  catalog=macos/$target/Localizable.xcstrings
  [[ $target == KittyTools ]] && catalog=macos/KittyTools/Resources/Localizable.xcstrings
  [[ -f $catalog ]] || continue
  typeset -A sources=()
  for file in macos/$target/**/*.swift; do sources[${file:t:r}]=1; done
  args=()
  for data in "$dd"/Build/Intermediates.noindex/KittyTools.build/Debug/$target.build/Objects-normal/arm64/*.stringsdata; do
    (( ${+sources[${data:t:r}]} )) && args+=(--stringsdata "$data")
  done
  xcrun xcstringstool sync "$catalog" "${args[@]}"
  echo "$catalog：$(xcrun xcstringstool print "$catalog" | grep -c '^') 条"
done
