#!/bin/zsh
# @kitty.title 进制转换
# @kitty.keyword bcvt
# @kitty.icon number
# @kitty.mode list
# @kitty.description 十进制、十六进制、二进制、八进制一起列
# @kitty.argument1 数字
#
# 写成 255、0xff、0b1010 或 0o17，四种进制各一行，↩ 粘贴选中的那条。最大到 2^63 - 1（再大 zsh 的整数装不下）。

# 下面的 ##0#、%%[[:space:]]# 要它（非交互的 zsh 默认不开）
setopt extended_glob
n=${${1:l}//[[:space:]_]/}
row() { print -r -- "$1"$'\t'"$2" }
too_big() {
  print -u2 -r -- "「$1」太大了：最大到 9223372036854775807（0x7fffffffffffffff）"
  exit 1
}
if [[ $n =~ '^0x[0-9a-f]+$' ]]; then
  digits=${${n#0x}##0#}
  (( ${#digits} > 16 )) || [[ ${#digits} == 16 && $digits[1] == [89a-f] ]] && too_big $1
  value=$(( 16#${n#0x} ))
elif [[ $n =~ '^0b[01]+$' ]]; then
  digits=${${n#0b}##0#}
  (( ${#digits} > 63 )) && too_big $1
  value=$(( 2#${n#0b} ))
elif [[ $n =~ '^0o[0-7]+$' ]]; then
  digits=${${n#0o}##0#}
  (( ${#digits} > 21 )) && too_big $1
  value=$(( 8#${n#0o} ))
elif [[ $n == <-> ]]; then
  digits=${n##0#}
  (( ${#digits} > 19 )) || [[ ${#digits} == 19 && $digits > 9223372036854775807 ]] && too_big $1
  value=$(( 10#${digits:-0} ))
else
  print -u2 -r -- "认不出「$1」：写成 255、0xff、0b1010 或 0o17"
  exit 1
fi
row $value "十进制"
row "0x$(( [##16] value ))" "十六进制"
row "0b$(( [##2] value ))" "二进制"
row "0o$(( [##8] value ))" "八进制"
