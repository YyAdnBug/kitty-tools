#!/bin/zsh
# @kitty.title UUID 生成器
# @kitty.keyword uuid
# @kitty.icon number.square
# @kitty.mode paste
# @kitty.description 生成一个小写的 UUID，粘贴到前台 App
/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]'
