#!/bin/zsh
# @kitty.title Unix 时间戳
# @kitty.title.en Unix Timestamp
# @kitty.keyword time
# @kitty.icon ⏱
# @kitty.mode list
# @kitty.description 时间戳和日期互转
# @kitty.description.en Convert between timestamps and dates
# @kitty.argument1 {"placeholder": "时间戳或日期", "optional": true}
# @kitty.argument1.en {"placeholder": "Timestamp or date", "optional": true}
#
# 不带参数：现在的秒、毫秒和日期；带参数：最多 10 位的秒 / 11–13 位的毫秒转成日期，2026-11-07 14:30 这类日期转成时间戳
# （没写时区按本地时间算；结尾是 Z 按 UTC，+08:00 这类按写的时区）。每打印一行「结果⇥说明」就是启动器里的一条，↩ 粘贴选中的那条。

zmodload zsh/datetime
# 下面的 ##0#、%%[[:space:]]# 要它（非交互的 zsh 默认不开）
setopt extended_glob
input=${${1##[[:space:]]#}%%[[:space:]]#}
# 说的话按 Kitty Tools 的界面语言（KITTY_LANGUAGE：zh-Hans / en）
en=0
[[ $KITTY_LANGUAGE == en* ]] && en=1
say() { (( en )) && print -r -- "$2" || print -r -- "$1" }

row() { print -r -- "$1"$'\t'"$2" }
dates() {
  row "$(strftime '%Y-%m-%d %H:%M:%S' $1)" "$(say 本地时间 'Local time')"
  row "$(TZ=UTC strftime '%Y-%m-%dT%H:%M:%SZ' $1)" "$(say 'UTC（ISO 8601）' 'UTC (ISO 8601)')"
}
seconds_label=$(say 秒 Seconds)
millis_label=$(say 毫秒 Milliseconds)

if [[ -z $input ]]; then
  seconds=${EPOCHREALTIME%.*}
  fraction=${EPOCHREALTIME#*.}
  row $seconds $seconds_label
  row $seconds${fraction[1,3]} $millis_label
  dates $seconds
elif [[ $input == <-> ]]; then
  if (( ${#input} > 13 )); then
    say "「$input」太长了：秒最多 10 位、毫秒最多 13 位" \
      "“$input” is too long: seconds have at most 10 digits, milliseconds 13" >&2
    exit 1
  elif (( ${#input} > 10 )); then
    seconds=$(( input / 1000 ))
    dates $seconds
    row $seconds $seconds_label
  else
    dates $input
    row ${input}000 $millis_label
  fi
else
  text=${${input//\//-}/T/ }
  # 时区：结尾的 Z 是 UTC，+08:00 / -0500 这类是写的那个时区；都没有按本地时间
  zone=""
  offset=0
  if [[ $text == *[Zz] ]]; then
    zone=UTC
    text=${${text%?}%%[[:space:]]#}
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
    say "认不出「$input」：写成 1700000000、1700000000000 或 2026-11-07 14:30" \
      "Can’t read “$input”: write it as 1700000000, 1700000000000 or 2026-11-07 14:30" >&2
    exit 1
  fi
  row $seconds $seconds_label
  row ${seconds}000 $millis_label
  dates $seconds
fi
