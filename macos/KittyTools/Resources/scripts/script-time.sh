#!/bin/zsh
# @kitty.title Unix 时间戳
# @kitty.keyword time
# @kitty.icon ⏱
# @kitty.mode list
# @kitty.description 时间戳和日期互转
# @kitty.argument1 {"placeholder": "时间戳或日期", "optional": true}
#
# 不带参数：现在的秒、毫秒和日期；带参数：10 位秒 / 13 位毫秒的时间戳转成日期，2026-11-07 14:30 这类日期转成时间戳
# （按本地时间算）。每打印一行「结果⇥说明」就是启动器里的一条，↩ 粘贴选中的那条。

zmodload zsh/datetime
input=${${1##[[:space:]]#}%%[[:space:]]#}

row() { print -r -- "$1"$'\t'"$2" }
dates() {
  row "$(strftime '%Y-%m-%d %H:%M:%S' $1)" "本地时间"
  row "$(TZ=UTC strftime '%Y-%m-%dT%H:%M:%SZ' $1)" "UTC（ISO 8601）"
}

if [[ -z $input ]]; then
  seconds=${EPOCHREALTIME%.*}
  fraction=${EPOCHREALTIME#*.}
  row $seconds "秒"
  row $seconds${fraction[1,3]} "毫秒"
  dates $seconds
elif [[ $input == <-> ]]; then
  if (( ${#input} >= 13 )); then
    seconds=$(( input / 1000 ))
    dates $seconds
    row $seconds "秒"
  else
    dates $input
    row ${input}000 "毫秒"
  fi
else
  text=${${input//\//-}/T/ }
  [[ $text == <->-<->-<-> ]] && text+=" 00:00:00"
  [[ $text == <->-<->-<->\ <->:<-> ]] && text+=":00"
  if ! seconds=$(strftime -r '%Y-%m-%d %H:%M:%S' $text 2>/dev/null); then
    print -u2 -r -- "认不出「$input」：写成 1700000000、1700000000000 或 2026-11-07 14:30"
    exit 1
  fi
  row $seconds "秒"
  row ${seconds}000 "毫秒"
  dates $seconds
fi
