#!/bin/zsh
# @kitty.title 切换深色模式
# @kitty.title.en Toggle Dark Mode
# @kitty.keyword dark
# @kitty.icon circle.lefthalf.filled
# @kitty.description 深色和浅色来回切
# @kitty.description.en Switch between dark and light
#
# 第一次运行时系统会问能不能让 Kitty Tools 控制「系统事件」，同意了才切得了。
# 说的话按 Kitty Tools 的界面语言（KITTY_LANGUAGE：zh-Hans / en）。

en=0
[[ $KITTY_LANGUAGE == en* ]] && en=1
result=$(/usr/bin/osascript -e 'tell application "System Events" to tell appearance preferences
  set dark mode to not dark mode
  if dark mode then return "已切换到深色模式"
  return "已切换到浅色模式"
end tell' 2>&1)
if (( $? != 0 )); then
  if [[ $result == *-1743* ]]; then
    if (( en )); then
      print -u2 "No permission to control System Events: turn it on for Kitty Tools in System Settings › Privacy & Security › Automation"
    else
      print -u2 "没有控制「系统事件」的权限：到 系统设置 › 隐私与安全性 › 自动化 里给 Kitty Tools 打开"
    fi
  else
    print -u2 -r -- "$result"
  fi
  exit 1
fi
if (( en )); then
  case $result in
    已切换到深色模式) result="Switched to Dark Mode" ;;
    已切换到浅色模式) result="Switched to Light Mode" ;;
  esac
fi
print -r -- "$result"
