#!/bin/zsh
# @kitty.title 正则表达式测试
# @kitty.keyword regt
# @kitty.icon text.magnifyingglass
# @kitty.mode list
# @kitty.description 列出匹配和分组；没写文字就拿剪贴板里的试
# @kitty.argument1 正则
# @kitty.argument2 {"placeholder": "文字", "optional": true}
#
# 「regt \d+ 订单 123 和 456」：正则是第一段，后面的是拿来试的文字；只写正则就用剪贴板里的文字。
# JavaScript 的正则写法，加了 g（全部匹配），最多列 100 处。

text=${2-$(/usr/bin/pbpaste)}
/usr/bin/osascript -l JavaScript - "$1" "$text" <<'JS'
function run(argv) {
  const [pattern, text] = argv
  let regex
  try {
    regex = new RegExp(pattern, "g")
  } catch (error) {
    return JSON.stringify({ items: [{ title: "正则写错了", subtitle: error.message, valid: false }] })
  }
  const items = []
  for (const match of text.matchAll(regex)) {
    if (items.length >= 100) break
    const groups = match.length > 1 ? " · 分组：" + match.slice(1).map((g) => g ?? "（空）").join("，") : ""
    items.push({
      title: match[0] === "" ? "（空匹配）" : match[0].replace(/\n/g, " ⏎ "),
      subtitle: `第 ${items.length + 1} 处 · 位置 ${match.index}` + groups,
      arg: match[0],
    })
  }
  if (items.length === 0) {
    items.push({ title: "没有匹配", subtitle: `试的是 ${text.length} 个字的文字`, valid: false })
  }
  return JSON.stringify({ items })
}
JS
