#!/bin/zsh
# @kitty.title 防止睡眠
# @kitty.title.en Keep Awake
# @kitty.keyword awake
# @kitty.icon cup.and.saucer.fill
# @kitty.description 接下来 1 小时不睡眠；再运行一次取消
# @kitty.description.en Stay awake for the next hour; run it again to cancel
#
# 用系统自带的 caffeinate（-d 屏幕也不睡、-i 系统不睡）；到 1 小时自己结束。
# 说的话按 Kitty Tools 的界面语言（KITTY_LANGUAGE：zh-Hans / en）。

en=0
[[ $KITTY_LANGUAGE == en* ]] && en=1

if /usr/bin/pkill -f '^/usr/bin/caffeinate -di -t 3600$'; then
  (( en )) && print "Stopped keeping awake" || print "已取消防止睡眠"
  exit 0
fi
/usr/bin/nohup /usr/bin/caffeinate -di -t 3600 >/dev/null 2>&1 &!
(( en )) && print "Staying awake for the next hour; run again to cancel" \
  || print "接下来 1 小时不会睡眠，再运行一次取消"
