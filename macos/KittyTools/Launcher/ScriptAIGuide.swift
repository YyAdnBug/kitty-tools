// 给 AI 的脚本写法说明（2026-11-07 第二轮拍板 A1 A2：用户要的是「一份写法说明丢给 AI」，Kitty 里不调 AI 写）：一份中文 Markdown，
// 说清楚文件格式、每个字段、六种结果方式、参数、列表的两种写法、运行环境和硬规矩，最后留一段给用户写「想做什么」。
// 设置 › 启动器「脚本命令」、「怎么写脚本」说明页、启动器里的「复制脚本写法说明」都复制这一份。AI 给回来的脚本从剪贴板新建，
// 走和导入一样的「先看一眼」（ScriptLibrary.scriptText(fromClipboard:)）。改了脚本的写法（字段、模式）要同步改这里。

import Foundation

nonisolated enum ScriptAIGuide {
  static let text = """
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
      - `@kitty.argument1` 参数的名字，如 `城市`。用户在启动器里输「关键词 空格 文字」，文字在 `$1` 里；最多 3 个（`argument1`–`argument3`，按空格切开，最后一个拿剩下的全部）。可以不填的写成 `{"placeholder": "城市", "optional": true}`。
      - `@kitty.description` 一句话说明它做什么。
      - `@kitty.icon` 一个 emoji，或者 SF Symbols 的符号名。
      - `@kitty.confirm` 一句确认的话。**会删文件、改系统设置、关机、发消息这类，必须写**：用户要按两次回车才运行。
      - `@kitty.timeout` 超时秒数，不写是 60；只有确实要跑很久时才写。

    ## 列表（mode 是 list 时）

    - 每打印一行就是一条结果，写成「结果<Tab>说明」（中间是一个制表符），用户选中按回车粘贴「结果」。
    - 要显示的和粘贴的不一样时，改成打印一段 JSON：`{"items": [{"title": "显示的", "subtitle": "说明", "arg": "粘贴的"}]}`，不能选的那条加 `"valid": false`。
    - 用户每打一个字会重新运行一次，最多等 10 秒，所以要快。

    ## 运行环境

    - 用用户自己终端里的 PATH；工作目录是脚本所在的文件夹；没有标准输入（读不到键盘）。
    - 能用的环境变量：`KITTY_SCRIPT_DIR`（脚本所在文件夹）、`KITTY_DATA_DIR`（Kitty Tools 的数据目录，要存东西就存这下面自己建的子文件夹）、`KITTY_VERSION`。
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
    #!/bin/zsh
    # @kitty.title 查天气
    # @kitty.keyword tq
    # @kitty.icon ⛅
    # @kitty.argument1 城市
    # @kitty.description 输入「tq 空格 城市」，提示里显示天气

    city="$1"
    curl -sS --max-time 8 "https://wttr.in/${city// /+}?format=3&lang=zh" || {
      print -u2 "没查到：检查一下网络"
      exit 1
    }
    ```

    ## 我要的脚本

    （在这里写你想让它做什么，越具体越好：输入是什么、要什么结果、结果给谁。比如：把剪贴板里的网址转成短链接，直接粘贴出来。）
    """
}
