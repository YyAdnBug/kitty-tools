#!/bin/zsh
# @kitty.title URL 编码 & 解码
# @kitty.keyword url
# @kitty.icon link
# @kitty.mode list
# @kitty.description 百分号编码和解码，各一条
# @kitty.argument1 文字
#
# 输出 Script Filter 那种 JSON（title 显示、arg 是 ↩ 粘贴的），解出来带换行的也是一条。

/usr/bin/osascript -l JavaScript - "$1" <<'JS'
function run(argv) {
  const text = argv[0]
  const items = [{ title: encodeURIComponent(text), subtitle: "编码", arg: encodeURIComponent(text) }]
  try {
    const decoded = decodeURIComponent(text.replace(/\+/g, " "))
    items.push({ title: decoded.replace(/\n/g, " ⏎ "), subtitle: "解码", arg: decoded })
  } catch (error) {
    items.push({ title: "解不出来", subtitle: "不是百分号编码", valid: false })
  }
  return JSON.stringify({ items })
}
JS
