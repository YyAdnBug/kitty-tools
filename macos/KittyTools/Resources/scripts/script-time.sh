#!/bin/zsh
# @kitty.title Unix 时间戳
# @kitty.keyword time
# @kitty.icon ⏱
# @kitty.mode list
# @kitty.description 时间戳和日期互转
# @kitty.argument1 {"placeholder": "时间戳或日期", "optional": true}
#
# 不带参数：现在的秒、毫秒和日期；带参数：最多 10 位的秒 / 11–13 位的毫秒转成日期，2026-11-07 14:30 这类日期转成时间戳
# （没写时区按本地时间算；结尾是 Z 按 UTC，+08:00 这类按写的时区）。每打印一行「结果⇥说明」就是启动器里的一条，↩ 粘贴选中的那条。

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
  if (( ${#input} > 13 )); then
    print -u2 -r -- "「$input」太长了：秒最多 10 位、毫秒最多 13 位"
    exit 1
  elif (( ${#input} > 10 )); then
    seconds=$(( input / 1000 ))
    dates $seconds
    row $seconds "秒"
  else
    dates $input
    row ${input}000 "毫秒"
  fi
else
  text=${${input//\//-}/T/ }
  # 时区：结尾的 Z 是 UTC，+08:00 / -0500 这类是写的那个时区；都没有按本地时间
  zone=""
  offset=0
  if [[ $text == *[Zz] ]]; then
    zone=UTC
    text=${text%?}
  elif [[ $text =~ '([+-])([0-9]{2}):?([0-9]{2})$' ]]; then
    zone=UTC
    sign=1
    [[ $match[1] == - ]] && sign=-1
    offset=$(( (10#$match[2] * 3600 + 10#$match[3] * 60) * sign ))
    text=${${text%$MATCH}%%[[:space:]]#}
  fi
  text=${text%.<->}
  [[ $text == <->-<->-<-> ]] && text+=" 00:00:00"
  [[ $text == <->-<->-<->\ <->:<-> ]] && text+=":00"
  if [[ -n $zone ]]; then
    seconds=$(TZ=UTC strftime -r '%Y-%m-%d %H:%M:%S' $text 2>/dev/null) || seconds=""
    [[ -n $seconds ]] && seconds=$(( seconds - offset ))
  else
    seconds=$(strftime -r '%Y-%m-%d %H:%M:%S' $text 2>/dev/null) || seconds=""
  fi
  if [[ -z $seconds ]]; then
    print -u2 -r -- "认不出「$input」：写成 1700000000、1700000000000 或 2026-11-07 14:30"
    exit 1
  fi
  row $seconds "秒"
  row ${seconds}000 "毫秒"
  dates $seconds
fi
