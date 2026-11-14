// 新建脚本用的东西（PLAN-v18 L1 第 8 批，mac ScriptLibrary.template / example / scriptText(fromClipboard:) / ScriptAIGuide）：
// 新建脚本表单按名字、关键词、结果方式、语言生成的文件，两个带着的样板（查天气、数字数），把 AI 给的脚本从剪贴板认出来、起文件名，
// 和给 AI 的写法说明。Windows 不看 #!（D7），所以「是不是脚本」看开头几行有没有 @kitty.title / @raycast.title，语言看 Markdown 围栏
// 写的语言或注释写法（:: / REM 是批处理）。.ps1 要存成带 BOM 的 UTF-8（PowerShell 5.1 读不带 BOM 的中文是乱码），批处理不带 BOM
// （cmd 把 BOM 当成命令的一部分）。改了脚本的写法（字段、模式）要同步改 AIGuide 和设置里「怎么写脚本」那一页。
using System.Text;

namespace KittyTools.Core;

public enum ScriptLanguage
{
    PowerShell,
    Batch,
    Python,
}

public static class ScriptTemplates
{
    public static string Extension(ScriptLanguage language) => language switch
    {
        ScriptLanguage.Batch => ".cmd",
        ScriptLanguage.Python => ".py",
        _ => ".ps1",
    };

    public static string Comment(ScriptLanguage language) => language == ScriptLanguage.Batch ? "::" : "#";

    /// <summary>按扩展名的语言（.bat 也算批处理）；认不出的 null。</summary>
    public static ScriptLanguage? LanguageOf(string path) => System.IO.Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".ps1" => ScriptLanguage.PowerShell,
        ".cmd" or ".bat" => ScriptLanguage.Batch,
        ".py" => ScriptLanguage.Python,
        _ => null,
    };

    /// <summary>写进文件的字节：.ps1 带 BOM，别的不带。</summary>
    public static byte[] Bytes(string text, ScriptLanguage language)
        => new UTF8Encoding(language == ScriptLanguage.PowerShell).GetPreamble().Concat(Encoding.UTF8.GetBytes(text.Replace("\r\n", "\n").Replace("\n", "\r\n"))).ToArray();

    /// <summary>新建脚本表单生成的文件：开头几行元数据、几行写法提示，和一段按语言、结果方式能直接跑的示例。</summary>
    public static string Template(string title, string? keyword, ScriptMode mode, ScriptLanguage language)
    {
        var c = Comment(language);
        var lines = new List<string>();
        if (language == ScriptLanguage.Batch)
        {
            lines.Add("@echo off");
        }

        lines.Add($"{c} @kitty.title {title}");
        if (!string.IsNullOrWhiteSpace(keyword))
        {
            lines.Add($"{c} @kitty.keyword {keyword}");
        }

        lines.Add($"{c} @kitty.mode {mode.ToString().ToLowerInvariant()}");
        lines.Add($"{c} @kitty.description 这一行写它是做什么的");
        lines.Add(c);
        lines.Add($"{c} 要参数就加一行「{c} @kitty.argument1 城市」，在启动器里输「关键词 空格 北京」，「北京」是第一个参数");
        lines.Add(mode == ScriptMode.List
            ? $"{c} 结果不随输入变的，加一行「{c} @kitty.filter」：只跑一次，打的字由启动器过滤"
            : $"{c} 要先确认再跑就加一行「{c} @kitty.confirm 再按 Enter 运行」");
        lines.Add($"{c} 别的字段看 设置 › 启动器 › 脚本命令「怎么写脚本」");
        if (language == ScriptLanguage.Python)
        {
            lines.Add($"{c} 要先装好 Python（带 py 启动器；命令提示符里输 py --version 看看）");
        }

        if (mode == ScriptMode.List)
        {
            lines.Add($"{c} 每行一条结果：标题、一个 Tab、说明；Enter 粘贴选中那条的标题");
        }

        lines.Add(string.Empty);
        lines.Add(Sample(mode, language));
        lines.Add(string.Empty);
        return string.Join("\n", lines);
    }

    /// <summary>能直接跑的示例：岛上 / 粘贴 / 复制 / 全文打一句话，列表列两条，不显示的响一声。</summary>
    public static string Sample(ScriptMode mode, ScriptLanguage language) => (language, mode) switch
    {
        (ScriptLanguage.PowerShell, ScriptMode.List) => "\"第一条`t说明一\"\n\"第二条`t说明二\"",
        (ScriptLanguage.PowerShell, ScriptMode.Full) => "\"你好，$env:USERNAME\"\n[Environment]::OSVersion.VersionString",
        (ScriptLanguage.PowerShell, ScriptMode.None) => "[System.Media.SystemSounds]::Asterisk.Play()",
        (ScriptLanguage.PowerShell, _) => "\"你好，$env:USERNAME\"",
        (ScriptLanguage.Batch, ScriptMode.List) => "echo 第一条\t说明一\necho 第二条\t说明二",
        (ScriptLanguage.Batch, ScriptMode.Full) => "echo 你好，%USERNAME%\nver",
        (ScriptLanguage.Batch, ScriptMode.None) => "rundll32 user32.dll,MessageBeep",
        (ScriptLanguage.Batch, _) => "echo 你好，%USERNAME%",
        (ScriptLanguage.Python, ScriptMode.List) => "print(\"第一条\\t说明一\")\nprint(\"第二条\\t说明二\")",
        (ScriptLanguage.Python, ScriptMode.None) => "import winsound\n\nwinsound.MessageBeep()",
        _ => "import getpass\n\nprint(f\"你好，{getpass.getuser()}\")",
    };

    /// <summary>新建脚本的文件名：关键词（只留字母、数字、短横线、下划线），没写关键词用名字（去掉文件名里不许的字和开头的点）。</summary>
    public static string NewFileName(string title, string? keyword, ScriptLanguage language)
    {
        var safe = new string((keyword ?? string.Empty).Where(ch => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_').ToArray());
        var name = safe.Length > 0
            ? safe
            : new string(title.Select(ch => System.IO.Path.GetInvalidFileNameChars().Contains(ch) ? '-' : ch).ToArray()).Trim().TrimStart('.');
        return (name.Length == 0 ? "新脚本" : name) + Extension(language);
    }

    /// <summary>例子：查天气（带一个参数，岛上显示一行；设置里「用例子新建」、说明页、默认文件夹第一次建时带上）。</summary>
    public const string Example = """
        # @kitty.title 查天气
        # @kitty.keyword tq
        # @kitty.icon ⛅
        # @kitty.argument1 城市
        # @kitty.description 输入「tq 空格 城市」，提示里显示天气

        $city = [Uri]::EscapeDataString($args[0])
        try {
            (Invoke-RestMethod -TimeoutSec 10 "https://wttr.in/${city}?format=3&lang=zh").Trim()
        } catch {
            [Console]::Error.WriteLine("没查到：检查一下网络")
            exit 1
        }
        """;

    public const string ExampleName = "查天气.ps1";

    /// <summary>第二个样板：数剪贴板里的字（不联网、不带参数）。</summary>
    public const string CountExample = """
        # @kitty.title 数一数剪贴板里的字
        # @kitty.keyword zs
        # @kitty.icon 🔢
        # @kitty.description 字数、行数，提示里显示

        $text = Get-Clipboard -Raw
        if (-not $text) {
            [Console]::Error.WriteLine("剪贴板里没有文字")
            exit 1
        }
        $chars = ($text -replace '\s', '').Length
        $lines = ($text -split "`n").Count
        "$chars 个字（不算空白），$lines 行"
        """;

    public const string CountExampleName = "数字数.ps1";

    /// <summary>
    /// 剪贴板里的一段文字是不是一个脚本（AI 给回来的）：去掉两头空白和 Markdown 代码块的 ``` 围栏，开头 40 行里有 @kitty.title /
    /// @raycast.title 才算。语言：围栏写的（powershell / ps1 / pwsh、bat / batch / cmd、python / py），没写看注释（:: / REM 是批处理），
    /// 再不然是 PowerShell。
    /// </summary>
    public static (string Text, ScriptLanguage Language)? FromClipboard(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        // 有代码块就只取第一个代码块（AI 常在前后加几句话）
        var lines = raw.Replace("\r\n", "\n").Trim().Split('\n').ToList();
        ScriptLanguage? fenced = null;
        var open = lines.FindIndex(line => line.TrimStart().StartsWith("```", StringComparison.Ordinal));
        if (open >= 0)
        {
            fenced = lines[open].Trim().TrimStart('`').Trim().ToLowerInvariant() switch
            {
                "powershell" or "ps1" or "pwsh" or "ps" => ScriptLanguage.PowerShell,
                "bat" or "batch" or "cmd" or "batchfile" or "dos" => ScriptLanguage.Batch,
                "python" or "py" or "python3" => ScriptLanguage.Python,
                _ => null,
            };
            var close = lines.FindIndex(open + 1, line => line.TrimStart().StartsWith("```", StringComparison.Ordinal));
            lines = lines.GetRange(open + 1, (close < 0 ? lines.Count : close) - open - 1);
        }

        var text = string.Join("\n", lines).Trim('\n', ' ', '\t');
        var head = text.Split('\n').Take(40).Select(ScriptCommand.Field).OfType<(string Prefix, string Key, string Value)>().ToList();
        if (!head.Any(field => field.Key == "title" && field.Value.Length > 0))
        {
            return null;
        }

        var batch = text.Split('\n').Take(40).Any(line =>
        {
            var trimmed = line.TrimStart();
            return trimmed.StartsWith("::", StringComparison.Ordinal) || trimmed.StartsWith("@echo", StringComparison.OrdinalIgnoreCase) ||
                   trimmed.StartsWith("rem ", StringComparison.OrdinalIgnoreCase) || trimmed.StartsWith("@rem ", StringComparison.OrdinalIgnoreCase);
        });
        var python = text.StartsWith("#!", StringComparison.Ordinal) && text.Split('\n')[0].Contains("python", StringComparison.OrdinalIgnoreCase);
        return (text + "\n", fenced ?? (batch ? ScriptLanguage.Batch : python ? ScriptLanguage.Python : ScriptLanguage.PowerShell));
    }

    /// <summary>从剪贴板新建时起的文件名：关键词 + 扩展名，没写关键词用「新脚本」。</summary>
    public static string SuggestedName(string text, ScriptLanguage language)
    {
        var keyword = text.Split('\n').Take(40).Select(ScriptCommand.Field)
            .OfType<(string Prefix, string Key, string Value)>()
            .FirstOrDefault(field => field.Key == "keyword").Value;
        return NewFileName("新脚本", keyword, language);
    }

    /// <summary>默认文件夹里没用过的名字：重名加「 2」「 3」。</summary>
    public static string FreeName(string name, Func<string, bool> taken)
    {
        if (!taken(name))
        {
            return name;
        }

        var stem = System.IO.Path.GetFileNameWithoutExtension(name);
        var extension = System.IO.Path.GetExtension(name);
        for (var index = 2; ; index++)
        {
            var candidate = $"{stem} {index}{extension}";
            if (!taken(candidate))
            {
                return candidate;
            }
        }
    }

    /// <summary>
    /// 给 AI 的写法说明（mac ScriptAIGuide，用户要的是「一份写法说明丢给 AI」，Kitty 里不调 AI 写）：中文 Markdown，说清楚文件格式、
    /// 每个字段、六种结果方式、参数、列表、运行环境和硬规矩，最后留一段给用户写「想做什么」。字段和 mac 一样（D9），语言换成 Windows 的。
    /// </summary>
    public static readonly string AIGuide = $$"""
        # 写一个 Kitty Tools 的脚本命令

        Kitty Tools 是一个 Windows 托盘工具，它的启动器能跑用户写的脚本：一个脚本文件就是启动器里的一条命令。请按下面的规矩，为最后一段「我要的脚本」写一个脚本。**只输出这一个完整的脚本文件，放在一个代码块里（代码块写上语言，如 ```powershell），不要别的解释。**

        ## 文件格式

        - 用什么跑看扩展名，不看第一行：优先写 PowerShell（`.ps1`，Windows PowerShell 5.1，每台 Windows 都有）；很简单的也可以写批处理（`.cmd`）；Python（`.py`）要用户装了 Python。
        - 开头是元数据，每行一个，写成注释 `# @kitty.字段 值`（批处理写 `:: @kitty.字段 值`）：
          - `@kitty.title` 名字，中文，必写。
          - `@kitty.keyword` 关键词：一个小写英文短词，用户在启动器里打它。
          - `@kitty.mode` 结果给谁，六选一：
            - `island`：在屏幕上的提示里显示输出的最后一行（不写就是它，适合「做一件事、说一句结果」）
            - `paste`：把输出粘贴到用户正在用的软件里（适合生成文字）
            - `copy`：把输出复制到剪贴板
            - `full`：在一个窗口里显示全部输出（适合查看较长的结果）
            - `list`：每行一条结果让用户挑，选中按 Enter 粘贴（见下面「列表」）
            - `none`：什么都不显示
          - `@kitty.argument1` 参数的名字，如 `城市`。用户在启动器里输「关键词 空格 文字」，PowerShell 里是 `$args[0]`（批处理 `%~1`，Python `sys.argv[1]`）；最多 3 个（`argument1`–`argument3`，按空格切开，最后一个拿剩下的全部）。带空格的参数用户会用引号括起来。可以不填的写成 `{"placeholder": "城市", "optional": true}`；要直接拼进网址的再加 `"percentEncoded": true`（Kitty 先做网址编码再交给脚本）；只能从几个值里挑的写 `{"placeholder": "设备", "type": "dropdown", "data": [{"title": "耳机", "value": "headphones"}, {"title": "音箱", "value": "speakers"}]}`（用户挑 title，脚本收到 value）；密码、令牌写 `"type": "password"`。
          - `@kitty.description` 一句话说明它做什么。
          - `@kitty.icon` 一个 emoji。
          - `@kitty.confirm` 一句确认的话。**会删文件、改系统设置、关机、发消息这类，必须写**：用户要按两次 Enter 才运行。列表（`list`）打字时就会运行，确认不了，写了 confirm 的列表脚本不会出现。
          - `@kitty.timeout` 超时秒数，不写是 60；只有确实要跑很久时才写。
          - `@kitty.filter` 只给列表（`list`）用，见下面「列表」。

        ## 列表（mode 是 list 时）

        - 每打印一行就是一条结果，写成「结果<Tab>说明」（中间是一个制表符，PowerShell 里写 `` `t ``），用户选中按 Enter 粘贴「结果」。
        - 要显示的和粘贴的不一样时，改成打印一段 JSON：`{"items": [{"title": "显示的", "subtitle": "说明", "arg": "粘贴的"}]}`，不能选的那条加 `"valid": false`。每条还可以写：
          - `"url"`：Enter 用浏览器打开这个网址（不粘贴）；`"path"`：Enter 打开这个文件或文件夹。
          - `"autocomplete"`：按 Tab 时填进搜索框（接在关键词后面）的文字，适合一层一层往下选。
        - 用户每打一个字会重新运行一次，最多等 10 秒，所以要快（PowerShell 起一次要零点几秒，别再做慢的事）。
        - 结果不随输入变（比如列出固定的几个项目）时，加一行 `@kitty.filter`：只在用户打完「关键词 空格」时运行一次，之后打的字由启动器按标题和说明过滤（认拼音和首字母），脚本收不到参数。

        ## 运行环境

        - PowerShell 用 `powershell -NoProfile -ExecutionPolicy Bypass -File` 跑（不读用户的配置文件）；批处理用 `cmd /d /c`；Python 用 `py`。
        - 工作目录是脚本所在的文件夹；没有窗口，没有标准输入（读不到键盘，不要 `Read-Host`、`pause`）。
        - 能用的环境变量：`KITTY_SCRIPT_DIR`（脚本所在文件夹）、`KITTY_DATA_DIR`（Kitty Tools 的数据目录，要存东西就存这下面自己建的子文件夹）、`KITTY_VERSION`。
        - 读剪贴板用 `Get-Clipboard -Raw`。mode 是 paste / copy 时直接把结果打印出来就行，不用自己写剪贴板。
        - 退出码是 0 算成功；不是 0 算出错，提示里显示输出的最后一行。
        - 输出按系统的代码页读（中文 Windows 是 GBK）：中文没问题，emoji 和生僻字可能变成问号；Python 和存成 UTF-8 的批处理按 UTF-8 读。

        ## 硬规矩

        1. 只用 Windows 自带的：PowerShell 5.1 的命令（`Invoke-RestMethod`、`Get-Clipboard`、`Get-Date`、`ConvertTo-Json`…）、.NET 类、`cmd` 的内置命令。不要用 PowerShell 7 才有的写法（`??`、`?.`、三元 `? :`、`&&`），不要装模块；Python 只用标准库。
        2. 参数和变量都当数据用：不要 `Invoke-Expression`、不要把参数拼进要执行的命令字符串里；批处理里参数用 `"%~1"` 加引号。
        3. 出错时把原因写到标准错误（PowerShell 用 `[Console]::Error.WriteLine("原因")`，批处理 `echo 原因 1>&2`）并 `exit 1`；成功时只打印结果，不打印多余的话，不用 `Write-Host`。
        4. 删文件、改系统设置、关机、发消息、花钱这类操作必须写 `@kitty.confirm`；删文件优先移到回收站。
        5. 联网用 `Invoke-RestMethod -TimeoutSec 10`；不要写死循环、不要在后台留着进程。
        6. 文件名用小写英文和短横线，扩展名 `.ps1`（批处理 `.cmd`、Python `.py`），比如 `short-url.ps1`。

        ## 例子

        ```powershell
        {{Example}}
        ```

        ## 我要的脚本

        （在这里写你想让它做什么，越具体越好：输入是什么、要什么结果、结果给谁。比如：把剪贴板里的网址转成短链接，直接粘贴出来。）
        """;
}
