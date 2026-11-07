#!/bin/zsh
# @kitty.title JSON 格式化
# @kitty.keyword json
# @kitty.icon curlybraces
# @kitty.mode full
# @kitty.description 把 JSON 排成好读的样子；不带参数时排剪贴板里的
# @kitty.argument1 {"placeholder": "JSON", "optional": true}
#
# 全文显示在启动器里：↩ 粘贴、⌘C 复制。用系统自带的 JavaScript（osascript）解析，每台 Mac 都能跑。

text=${1:-$(/usr/bin/pbpaste)}
if [[ -z ${text//[[:space:]]/} ]]; then
  print -u2 "剪贴板里没有文字"
  exit 1
fi
result=$(/usr/bin/osascript -l JavaScript - "$text" <<'JS'
function run(argv) {
  try {
    return JSON.stringify(JSON.parse(argv[0]), null, 2)
  } catch (error) {
    return "\u0000" + error.message
  }
}
JS
)
if [[ $result == $'\0'* ]]; then
  print -u2 -r -- "不是有效的 JSON：${result#?}"
  exit 1
fi
print -r -- "$result"
