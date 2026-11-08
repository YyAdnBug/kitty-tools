#!/bin/zsh
# @kitty.title Base64 编码 & 解码
# @kitty.keyword b64
# @kitty.icon arrow.left.arrow.right.square
# @kitty.mode list
# @kitty.description 编码和解码各一条
# @kitty.argument1 文字
#
# 按 UTF-8 编解码；解出来不是文字的不列。输出 Script Filter 那种 JSON。

/usr/bin/osascript -l JavaScript - "$1" <<'JS'
ObjC.import("Foundation")
function run(argv) {
  const text = argv[0]
  const data = $(text).dataUsingEncoding($.NSUTF8StringEncoding)
  const encoded = data.base64EncodedStringWithOptions(0).js
  const items = [{ title: encoded, subtitle: "编码", arg: encoded }]
  const raw = $.NSData.alloc.initWithBase64EncodedStringOptions($(text.trim()), 0)
  const decoded = raw.isNil() ? null : $.NSString.alloc.initWithDataEncoding(raw, $.NSUTF8StringEncoding)
  if (decoded && !decoded.isNil() && decoded.length > 0) {
    const value = decoded.js
    items.push({ title: value.replace(/\n/g, " ⏎ "), subtitle: "解码", arg: value })
  } else {
    items.push({ title: "解不出来", subtitle: "不是 Base64，或者解出来不是文字", valid: false })
  }
  return JSON.stringify({ items })
}
JS
