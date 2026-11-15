#!/bin/zsh
# @kitty.title URL 编码 & 解码
# @kitty.title.en URL Encode & Decode
# @kitty.keyword url
# @kitty.icon link
# @kitty.mode list
# @kitty.description 百分号编码和解码，各一条
# @kitty.description.en Percent-encode and decode, one result each
# @kitty.argument1 文字
# @kitty.argument1.en Text
#
# 输出 Script Filter 那种 JSON（title 显示、arg 是 ↩ 粘贴的），解出来带换行的也是一条。
# 说的话按 Kitty Tools 的界面语言（KITTY_LANGUAGE）。

/usr/bin/osascript -l JavaScript - "$1" "$KITTY_LANGUAGE" <<'JS'
function run(argv) {
  const text = argv[0]
  const en = (argv[1] || "").startsWith("en")
  const items = [
    { title: encodeURIComponent(text), subtitle: en ? "Encoded" : "编码", arg: encodeURIComponent(text) },
  ]
  try {
    const decoded = decodeURIComponent(text.replace(/\+/g, " "))
    items.push({ title: decoded.replace(/\n/g, " ⏎ "), subtitle: en ? "Decoded" : "解码", arg: decoded })
  } catch (error) {
    items.push(en
      ? { title: "Can’t decode", subtitle: "Not percent-encoded", valid: false }
      : { title: "解不出来", subtitle: "不是百分号编码", valid: false })
  }
  return JSON.stringify({ items })
}
JS
