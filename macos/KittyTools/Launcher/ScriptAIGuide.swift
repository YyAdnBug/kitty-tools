// 给 AI 的脚本写法说明（2026-11-07 第二轮拍板 A1 A2：用户要的是「一份写法说明丢给 AI」，Kitty 里不调 AI 写）：一份中文 Markdown，
// 说清楚文件格式、每个字段、六种结果方式、参数、列表的两种写法、运行环境和硬规矩，最后留一段给用户写「想做什么」。
// 设置 › 启动器「脚本命令」、「怎么写脚本」说明页、启动器里的「复制脚本写法说明」都复制这一份。AI 给回来的脚本从剪贴板新建，
// 走和导入一样的「先看一眼」（ScriptLibrary.scriptText(fromClipboard:)）。改了脚本的写法（字段、模式）要同步改这里（中英两份）。
// 英文界面复制的是英文那份（让 AI 写出英文的名字和说明）：给大模型的提示词不进 String Catalog，两份直接写在这里。

import Foundation

nonisolated enum ScriptAIGuide {
  /// 按这次运行界面的语言
  static var text: String { InterfaceLanguage.isEnglish ? english : chinese }

  static let chinese = """
    # 写一个 Kitty Tools 的脚本命令

    Kitty Tools 是一个 macOS 菜单栏工具，它的启动器能跑用户写的脚本：一个脚本文件就是启动器里的一条命令。请按下面的规矩，为最后一段「我要的脚本」写一个脚本。**只输出这一个完整的脚本文件，放在一个代码块里，不要别的解释。**

    ## 文件格式

    - 第一行是 `#!`，写用什么跑。优先 `#!/bin/zsh`；要写 JavaScript 用 `#!/usr/bin/osascript -l JavaScript`；AppleScript 用 `#!/usr/bin/osascript`。
    - 接着是元数据，每行一个，写成注释 `# @kitty.字段 值`（JavaScript 用 `// @kitty.字段 值`，AppleScript 用 `-- @kitty.字段 值`）：
      - `@kitty.title` 名字，中文，必写。
      - `@kitty.keyword` 关键词：一个小写英文短词，用户在启动器里打它。
      - `@kitty.mode` 结果给谁，六选一：
        - `island`：在屏幕顶上的提示里显示输出的最后一行（不写就是它，适合「做一件事、说一句结果」）
        - `paste`：把输出粘贴到用户正在用的 App 里（适合生成文字）
        - `copy`：把输出复制到剪贴板
        - `full`：在启动器里显示全部输出（适合查看较长的结果）
        - `list`：每行一条结果让用户挑，选中按回车粘贴（见下面「列表」）
        - `none`：什么都不显示
      - `@kitty.argument1` 参数的名字，如 `城市`。用户在启动器里输「关键词 空格 文字」，文字在 `$1` 里；最多 3 个（`argument1`–`argument3`，按空格切开，最后一个拿剩下的全部）。带空格的参数用户会用引号括起来。可以不填的写成 `{"placeholder": "城市", "optional": true}`；要直接拼进网址的再加 `"percentEncoded": true`（Kitty 先做网址编码再交给脚本）；只能从几个值里挑的写 `{"placeholder": "设备", "type": "dropdown", "data": [{"title": "耳机", "value": "headphones"}, {"title": "音箱", "value": "speakers"}]}`（用户挑 title，脚本收到 value）；密码、令牌写 `"type": "password"`。
      - `@kitty.description` 一句话说明它做什么。
      - `@kitty.icon` 一个 emoji，或者 SF Symbols 的符号名（优先用这两种；也可以写脚本同一个文件夹里的图片文件名，或 https 开头的图片网址）。
      - `@kitty.confirm` 一句确认的话。**会删文件、改系统设置、关机、发消息这类，必须写**：用户要按两次回车才运行。列表（`list`）打字时就会运行，确认不了，写了 confirm 的列表脚本不会出现。
      - `@kitty.timeout` 超时秒数，不写是 60；只有确实要跑很久时才写。
      - `@kitty.filter` 只给列表（`list`）用，见下面「列表」。

    ## 列表（mode 是 list 时）

    - 每打印一行就是一条结果，写成「结果<Tab>说明」（中间是一个制表符），用户选中按回车粘贴「结果」。
    - 要显示的和粘贴的不一样时，改成打印一段 JSON：`{"items": [{"title": "显示的", "subtitle": "说明", "arg": "粘贴的"}]}`，不能选的那条加 `"valid": false`。每条还可以写：
      - `"url"`：回车用浏览器打开这个网址（不粘贴）；`"path"`：回车打开这个文件或文件夹（⌘↩ 在访达中显示、⌘Y 快速查看）。
      - `"icon"`：这一条自己的图标，写法同 `@kitty.icon`（不认网址）；`{"type": "fileicon", "path": "~/Desktop"}` 用那个文件在访达里的图标。
      - `"autocomplete"`：按 ⇥ 时填进搜索框（接在关键词后面）的文字，适合一层一层往下选。
      - `"text": {"copy": "…"}`：按 ⌘C 复制的（不写就复制 arg、网址或路径）。
    - 用户每打一个字会重新运行一次，最多等 10 秒，所以要快。
    - 结果不随输入变（比如列出固定的几个项目）时，加一行 `@kitty.filter`：只在用户打完「关键词 空格」时运行一次，之后打的字由启动器按标题和说明过滤（认拼音和首字母），脚本收不到参数。

    ## 运行环境

    - 用用户自己终端里的 PATH；工作目录是脚本所在的文件夹；没有标准输入（读不到键盘）。
    - 能用的环境变量：`KITTY_SCRIPT_DIR`（脚本所在文件夹）、`KITTY_DATA_DIR`（Kitty Tools 的数据目录，要存东西就存这下面自己建的子文件夹）、`KITTY_VERSION`、`KITTY_LANGUAGE`（Kitty Tools 的界面语言，`zh-Hans` 或 `en`）。
    - 读剪贴板用 `pbpaste`。mode 是 paste / copy 时直接把结果打印出来就行，不用自己写剪贴板。
    - 退出码是 0 算成功；不是 0 算出错，提示里显示输出的最后一行。

    ## 硬规矩

    1. 只用每台 Mac 都自带的命令：zsh、osascript、curl、pbpaste / pbcopy、open、defaults、date、base64、sed、awk、grep 这类。python3、node、jq 和 Homebrew 装的工具不一定有；非用不可时，在开头检查它在不在，不在就往标准错误写「要先装 xxx」并 `exit 1`。
    2. 所有参数和变量都加双引号（`"$1"`）；不要用 `eval`；不要把参数拼进要执行的命令字符串里。
    3. 出错时把原因写到标准错误（zsh 用 `print -u2 "原因"`）并 `exit 1`；成功时只打印结果，不打印多余的话。
    4. 删文件、改系统设置、关机、发消息、花钱这类操作必须写 `@kitty.confirm`；删文件优先移到废纸篓。
    5. 联网用 `curl -sS --max-time 10`；不要写死循环、不要在后台留着进程（真要留，像 `caffeinate` 那样给它定个时间）。
    6. 文件名用小写英文和短横线，扩展名 `.sh`（JavaScript / AppleScript 的也可以用 `.sh`），比如 `short-url.sh`。

    ## 例子

    ```zsh
    \(ScriptLibrary.chineseExample)
    ```

    ## 我要的脚本

    （在这里写你想让它做什么，越具体越好：输入是什么、要什么结果、结果给谁。比如：把剪贴板里的网址转成短链接，直接粘贴出来。）
    """

  static let english = """
    # Write a Kitty Tools script command

    Kitty Tools is a macOS menu bar app whose Launcher runs scripts the user writes: one script file is one command in the Launcher. Following the rules below, write a script for the last section, “The script I want”. **Output only that one complete script file, in a single code block, with no other explanation.**

    ## File format

    - The first line is `#!`, saying what runs it. Prefer `#!/bin/zsh`; for JavaScript use `#!/usr/bin/osascript -l JavaScript`; for AppleScript use `#!/usr/bin/osascript`.
    - Then the metadata, one per line, written as comments `# @kitty.field value` (JavaScript uses `// @kitty.field value`, AppleScript uses `-- @kitty.field value`):
      - `@kitty.title` The name, in English. Required.
      - `@kitty.keyword` A keyword: one short lowercase English word the user types in the Launcher.
      - `@kitty.mode` Where the result goes, one of six:
        - `island`: show the last line of output in the notice at the top of the screen (the default; good for “do one thing, say one line”)
        - `paste`: paste the output into the app the user is in (good for generating text)
        - `copy`: copy the output to the clipboard
        - `full`: show all of the output in the Launcher (good for longer results)
        - `list`: one result per line for the user to pick; ↩ pastes the selected one (see “Lists” below)
        - `none`: show nothing
      - `@kitty.argument1` The argument’s name, like `City`. The user types “keyword, a space, then text” in the Launcher and the text is in `$1`; up to 3 (`argument1`–`argument3`, split on spaces, the last one gets the rest). The user puts arguments with spaces in quotes. An optional one is written `{"placeholder": "City", "optional": true}`; one that goes straight into a URL also gets `"percentEncoded": true` (Kitty percent-encodes it before passing it on); one picked from a few values is `{"placeholder": "Device", "type": "dropdown", "data": [{"title": "Headphones", "value": "headphones"}, {"title": "Speakers", "value": "speakers"}]}` (the user picks a title, the script gets the value); passwords and tokens use `"type": "password"`.
      - `@kitty.description` One sentence on what it does.
      - `@kitty.icon` An emoji, or an SF Symbols name (prefer these two; it can also be an image file name in the script’s folder, or an image URL starting with https).
      - `@kitty.confirm` A confirmation sentence. **Required for anything that deletes files, changes system settings, shuts down, or sends messages**: the user has to press Return twice to run it. A list (`list`) runs as you type and can’t confirm; list scripts with confirm don’t show up.
      - `@kitty.timeout` Timeout in seconds, 60 if not written; only write it when it really runs long.
      - `@kitty.filter` For lists (`list`) only; see “Lists” below.

    ## Lists (when mode is list)

    - Each printed line is one result, written “result<Tab>note” (a tab character in between); the user selects one and Return pastes “result”.
    - When what’s shown differs from what’s pasted, print JSON instead: `{"items": [{"title": "shown", "subtitle": "note", "arg": "pasted"}]}`; add `"valid": false` to one that can’t be picked. Each item can also have:
      - `"url"`: Return opens this URL in the browser (no paste); `"path"`: Return opens this file or folder (⌘↩ shows it in Finder, ⌘Y Quick Look).
      - `"icon"`: this item’s own icon, written like `@kitty.icon` (no URLs); `{"type": "fileicon", "path": "~/Desktop"}` uses that file’s icon in Finder.
      - `"autocomplete"`: text filled into the search field (after the keyword) by ⇥, good for drilling down level by level.
      - `"text": {"copy": "…"}`: what ⌘C copies (otherwise arg, the URL, or the path).
    - The script runs again on every keystroke and gets at most 10 seconds, so it has to be fast.
    - When the results don’t depend on the input (like a fixed list of items), add a line `@kitty.filter`: it runs once, when the user has typed “keyword and a space”; after that the Launcher filters by title and note, and the script gets no arguments.

    ## Environment

    - The PATH is the one from the user’s own Terminal; the working directory is the script’s folder; there’s no standard input (no keyboard).
    - Environment variables: `KITTY_SCRIPT_DIR` (the script’s folder), `KITTY_DATA_DIR` (Kitty Tools’ data folder; to store things, make your own subfolder in it), `KITTY_VERSION`, `KITTY_LANGUAGE` (Kitty Tools’ interface language, `zh-Hans` or `en`).
    - Read the clipboard with `pbpaste`. With mode paste / copy, just print the result; don’t write the clipboard yourself.
    - Exit code 0 is success; anything else is an error, and the notice shows the last line of output.

    ## Hard rules

    1. Use only commands every Mac has: zsh, osascript, curl, pbpaste / pbcopy, open, defaults, date, base64, sed, awk, grep and the like. python3, node, jq and Homebrew tools may be missing; if you must use one, check for it first and if it’s missing write “Install xxx first” to standard error and `exit 1`.
    2. Double-quote every argument and variable (`"$1"`); don’t use `eval`; don’t splice arguments into a command string you run.
    3. On error, write the reason to standard error (in zsh `print -u2 "reason"`) and `exit 1`; on success print only the result, nothing extra.
    4. Anything that deletes files, changes system settings, shuts down, sends messages, or spends money must have `@kitty.confirm`; prefer moving files to the Trash over deleting them.
    5. Use `curl -sS --max-time 10` for the network; no infinite loops, and don’t leave processes running in the background (if you really must, give it a time limit like `caffeinate` does).
    6. Name the file in lowercase English with hyphens, extension `.sh` (JavaScript / AppleScript ones can use `.sh` too), like `short-url.sh`.

    ## Example

    ```zsh
    \(ScriptLibrary.englishExample)
    ```

    ## The script I want

    (Write here what you want it to do, as specifically as you can: what goes in, what result you want, and where it goes. For example: turn the URL on the clipboard into a short link and paste it.)
    """
}
