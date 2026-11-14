// 启动器的脚本命令（PLAN-v18 L1 / D7 D9，mac ScriptCommand.swift；纯函数，配单测）：一个文件就是一条命令。
// 开头几行注释写元数据，字段和 mac 一模一样：@kitty.title（不写用文件名）、keyword、icon、iconDark、mode、description、package、
// argument1–3、confirm、timeout、filter；也认 @raycast. 的同名字段（packageName、needsConfirmation、argument 的 JSON）。
// 注释可以是 #、//、--，Windows 另认 ::、REM（批处理）。**用什么跑按扩展名定（D7），不看 #!**：.ps1 → PowerShell、.cmd / .bat → cmd、
// .py → py.exe（装了 Python 启动器才认；WindowsApps 里的 python.exe 是商店占位，一跑就弹商店）。别的像脚本的扩展名（.sh、.js…）
// 记一条原因给设置页列。文件名带 .template. 的、点开头的不列。不承诺同一个文件 mac / Windows 两边都能跑（D9）。
// 输出的收拾（去终端颜色码、回车）、列表输出的读法、「关键词 空格 参数」怎么切、看全文时标出看不见的字，也在这里。
using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>输出交给谁（mac B1）。</summary>
public enum ScriptMode
{
    /// <summary>刘海岛上显示最后一行（默认）。</summary>
    Island,
    Paste,
    Copy,
    /// <summary>启动器里原地显示全部输出。</summary>
    Full,
    /// <summary>每行一条结果。</summary>
    List,
    None,
}

/// <summary>头部写的图标：emoji、Segoe 图标名、脚本旁边的图片、https 网址；列表结果另有某个文件的图标。</summary>
public abstract record ScriptIcon
{
    public sealed record Emoji(string Text) : ScriptIcon;

    public sealed record Symbol(string Name) : ScriptIcon;

    public sealed record Image(string Path) : ScriptIcon;

    public sealed record Remote(string Url) : ScriptIcon;

    public sealed record FileIcon(string Path) : ScriptIcon;
}

public sealed record ScriptOption(string Title, string Value);

public sealed record ScriptArgument(
    string Placeholder, bool IsOptional = false, bool IsPercentEncoded = false, IReadOnlyList<ScriptOption>? Options = null,
    bool IsSecret = false)
{
    public IReadOnlyList<ScriptOption> Choices => Options ?? Array.Empty<ScriptOption>();

    /// <summary>打的这个值对应的选项：标题一字不差的先认，再是不分大小写的标题，最后是 value。</summary>
    public ScriptOption? OptionFor(string value)
    {
        var folded = LauncherMatch.Fold(value);
        return Choices.FirstOrDefault(option => option.Title == value) ??
               Choices.FirstOrDefault(option => LauncherMatch.Fold(option.Title) == folded) ??
               Choices.FirstOrDefault(option => option.Value == value);
    }

    public bool Equals(ScriptArgument? other)
        => other is not null && Placeholder == other.Placeholder && IsOptional == other.IsOptional &&
           IsPercentEncoded == other.IsPercentEncoded && IsSecret == other.IsSecret && Choices.SequenceEqual(other.Choices);

    public override int GetHashCode() => HashCode.Combine(Placeholder, IsOptional, IsSecret);
}

/// <summary>读不成一条命令的原因（设置页列出来）。</summary>
public enum ScriptProblem
{
    /// <summary>扩展名像脚本，Windows 版不认（.sh、.js…）。</summary>
    Unsupported,

    /// <summary>.py 要装了 Python 启动器（py.exe）才跑得了。</summary>
    NeedsPython,
    Unreadable,

    /// <summary>列表脚本打字时就会跑，不能写 confirm。</summary>
    ConfirmInList,
}

public sealed record ScriptCommand
{
    public const int DefaultTimeout = 60;

    /// <summary>只读开头这么多字节找元数据。</summary>
    public const int HeaderBytes = 8192;

    public const int LineLimit = 200;

    /// <summary>脚本文件的路径：使用记录、收藏、别名都按它认。</summary>
    public required string Path { get; init; }

    public required string Title { get; init; }

    /// <summary>头部写的关键词（「命令」表里的默认别名）：折叠过、不带空白。</summary>
    public string? Keyword { get; init; }

    public ScriptIcon? Icon { get; init; }

    public ScriptIcon? IconDark { get; init; }

    public ScriptMode Mode { get; init; } = ScriptMode.Island;

    public string? Summary { get; init; }

    public string? Package { get; init; }

    public IReadOnlyList<ScriptArgument> Arguments { get; init; } = Array.Empty<ScriptArgument>();

    /// <summary>要先上膛：副标题换成的那句；null = 直接跑。</summary>
    public string? Confirmation { get; init; }

    /// <summary>秒；0 = 不限，null = 默认。</summary>
    public int? Timeout { get; init; }

    /// <summary>解释器和它的参数（脚本路径接在后面）。</summary>
    public required IReadOnlyList<string> Interpreter { get; init; }

    /// <summary>带着下载来的标记（:Zone.Identifier）：第一次跑之前先给用户看全文。</summary>
    public bool IsDownloaded { get; init; }

    public bool IsBundled { get; init; }

    /// <summary>列表脚本只跑一次、打的字由启动器过滤（@kitty.filter）：不收参数。</summary>
    public bool Filters { get; init; }

    public string Folder => System.IO.Path.GetDirectoryName(Path) ?? string.Empty;

    public string FileName => System.IO.Path.GetFileName(Path);

    public int Limit => Timeout ?? DefaultTimeout;

    /// <summary>声明了参数的、列表的（打字时重跑）：打了关键词之后先补「关键词 空格」，不直接跑。</summary>
    public bool TakesInput => Arguments.Count > 0 || Mode == ScriptMode.List;

    public int RequiredCount => Arguments.TakeWhile(argument => !argument.IsOptional).Count();

    public bool HasSecret => Arguments.Any(argument => argument.IsSecret);

    // ---- 解析

    private static readonly HashSet<string> LooksLikeScript = new(StringComparer.OrdinalIgnoreCase)
    {
        ".sh", ".zsh", ".bash", ".js", ".mjs", ".ts", ".rb", ".pl", ".php", ".lua", ".fish", ".vbs", ".applescript", ".scpt",
    };

    /// <summary>
    /// 这个扩展名用什么跑（D7）；null = 不认。pythonAvailable：装了 py.exe。
    /// </summary>
    public static IReadOnlyList<string>? InterpreterFor(string path, bool pythonAvailable)
        => System.IO.Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".ps1" => new[] { "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File" },
            ".cmd" or ".bat" => new[] { "cmd.exe", "/d", "/c" },
            ".py" when pythonAvailable => new[] { "py.exe" },
            _ => null,
        };

    /// <summary>读到的开头 → 一条命令；null = 不是脚本、或者是 .template. / 点开头的（不列也不报）。</summary>
    public static (ScriptCommand? Script, ScriptProblem? Problem)? Parse(string head, string path, bool pythonAvailable)
    {
        var name = System.IO.Path.GetFileName(path);
        if (name.StartsWith('.') || name.Contains(".template.", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var extension = System.IO.Path.GetExtension(name);
        if (InterpreterFor(path, pythonAvailable) is not { } interpreter)
        {
            return extension.Equals(".py", StringComparison.OrdinalIgnoreCase)
                ? (null, ScriptProblem.NeedsPython)
                : LooksLikeScript.Contains(extension) ? (null, ScriptProblem.Unsupported) : null;
        }

        var kitty = new Dictionary<string, string>();
        var raycast = new Dictionary<string, string>();
        foreach (var line in head.Split('\n'))
        {
            if (Field(line) is not { } field)
            {
                continue;
            }

            var target = field.Prefix == "kitty" ? kitty : raycast;
            target.TryAdd(field.Key, field.Value);
        }

        var fields = Merged(kitty, raycast);
        var fileTitle = System.IO.Path.GetFileNameWithoutExtension(name);
        var title = fields.TryGetValue("title", out var custom) && custom.Length > 0 ? custom : fileTitle;
        var folder = System.IO.Path.GetDirectoryName(path) ?? string.Empty;
        var mode = fields.TryGetValue("mode", out var modeText) ? ParseMode(modeText) ?? ScriptMode.Island : ScriptMode.Island;
        var script = new ScriptCommand
        {
            Path = path,
            Title = title,
            Interpreter = interpreter,
            Keyword = fields.TryGetValue("keyword", out var keyword) ? KeywordFor(keyword) : null,
            Icon = fields.TryGetValue("icon", out var icon) ? IconFor(icon, folder) : null,
            IconDark = fields.TryGetValue("iconDark", out var dark) ? IconFor(dark, folder) : null,
            Mode = mode,
            Summary = fields.TryGetValue("description", out var summary) && summary.Length > 0 ? summary : null,
            Package = fields.TryGetValue("package", out var package) && package.Length > 0 ? package : null,
            Arguments = ArgumentsFrom(fields),
            Confirmation = fields.TryGetValue("confirm", out var confirm) ? ConfirmationFor(confirm, title) : null,
            Timeout = fields.TryGetValue("timeout", out var timeout) && int.TryParse(timeout, out var seconds)
                ? Math.Clamp(seconds, 0, 3600)
                : null,
        };
        if (script.Mode == ScriptMode.List && script.Confirmation is not null)
        {
            return (null, ScriptProblem.ConfirmInList);
        }

        if (script.Mode == ScriptMode.List && fields.TryGetValue("filter", out var filter) && IsYes(filter))
        {
            script = script with { Filters = true, Arguments = Array.Empty<ScriptArgument>() };
        }

        return (script, null);
    }

    public static string ProblemText(ScriptProblem problem) => problem switch
    {
        ScriptProblem.Unsupported => "Windows 版只认 .ps1、.cmd、.bat、.py 脚本",
        ScriptProblem.NeedsPython => "要装 Python（带 py 启动器）才跑得了 .py",
        ScriptProblem.ConfirmInList => "列表脚本打字时就会运行，不能写 confirm",
        _ => "读不出来",
    };

    /// <summary>一行注释里的「@kitty.key 值」/「@raycast.key 值」；注释可以是 #、//、--、::、REM。</summary>
    public static (string Prefix, string Key, string Value)? Field(string line)
    {
        var text = line.Trim();
        string? rest = null;
        foreach (var marker in new[] { "#", "//", "--", "::" })
        {
            if (text.StartsWith(marker, StringComparison.Ordinal))
            {
                rest = text[marker.Length..];
                break;
            }
        }

        if (rest is null)
        {
            var lower = text.ToLowerInvariant();
            if (lower.StartsWith("@rem", StringComparison.Ordinal) && lower.Length > 4 && char.IsWhiteSpace(lower[4]))
            {
                rest = text[4..];
            }
            else if (lower.StartsWith("rem", StringComparison.Ordinal) && lower.Length > 3 && char.IsWhiteSpace(lower[3]))
            {
                rest = text[3..];
            }
        }

        if (rest is null)
        {
            return null;
        }

        rest = rest.TrimStart();
        foreach (var prefix in new[] { "kitty", "raycast" })
        {
            var head = "@" + prefix + ".";
            if (!rest.StartsWith(head, StringComparison.Ordinal))
            {
                continue;
            }

            var body = rest[head.Length..];
            var keyLength = body.TakeWhile(ch => !char.IsWhiteSpace(ch)).Count();
            if (keyLength == 0)
            {
                return null;
            }

            return (prefix, body[..keyLength], body[keyLength..].Trim());
        }

        return null;
    }

    /// <summary>两种写法并成一份：自家的优先；社区写法的字段名换成自家的。</summary>
    public static Dictionary<string, string> Merged(IReadOnlyDictionary<string, string> kitty, IReadOnlyDictionary<string, string> raycast)
    {
        var fields = new Dictionary<string, string>();
        foreach (var (key, value) in raycast)
        {
            switch (key)
            {
                case "packageName":
                    fields["package"] = value;
                    break;
                case "needsConfirmation":
                    fields["confirm"] = value;
                    break;
                case "mode":
                    fields["mode"] = value == "fullOutput" ? "full" : "island";
                    break;
                case "title" or "icon" or "iconDark" or "description" or "argument1" or "argument2" or "argument3":
                    fields[key] = value;
                    break;
            }
        }

        foreach (var (key, value) in kitty)
        {
            fields[key] = value;
        }

        return fields;
    }

    public static string? KeywordFor(string value)
    {
        var first = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return string.IsNullOrEmpty(first) ? null : LauncherMatch.Fold(first);
    }

    public static ScriptMode? ParseMode(string value) => value.ToLowerInvariant() switch
    {
        "island" => ScriptMode.Island,
        "paste" => ScriptMode.Paste,
        "copy" => ScriptMode.Copy,
        "full" => ScriptMode.Full,
        "list" => ScriptMode.List,
        "none" => ScriptMode.None,
        _ => null,
    };

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".gif", ".ico", ".bmp", ".tiff", ".tif", ".webp",
    };

    public static ScriptIcon? IconFor(string value, string folder)
    {
        var text = value.Trim();
        if (text.Length == 0)
        {
            return null;
        }

        if (text.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return Uri.TryCreate(text, UriKind.Absolute, out _) ? new ScriptIcon.Remote(text) : null;
        }

        if (text.StartsWith("http:", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (ImageExtensions.Contains(System.IO.Path.GetExtension(text)) || text.Contains('/') || text.Contains('\\'))
        {
            return new ScriptIcon.Image(Absolute(text, folder));
        }

        // 第一个字是 emoji（⏱ 这类默认不是彩色的补上 U+FE0F）
        if (Rune.DecodeFromUtf16(text, out var rune, out var length) == OperationStatus.Done &&
            Rune.GetUnicodeCategory(rune) == UnicodeCategory.OtherSymbol && rune.Value >= 0x2100)
        {
            var emoji = text[..length];
            var rest = text[length..];
            if (rest.StartsWith('\uFE0F'))
            {
                return new ScriptIcon.Emoji(emoji + "\uFE0F");
            }

            return new ScriptIcon.Emoji(rune.Value >= 0x1F000 ? emoji : emoji + "\uFE0F");
        }

        return new ScriptIcon.Symbol(text);
    }

    /// <summary>~ 展开；相对路径按脚本所在的文件夹算。</summary>
    public static string Absolute(string path, string folder)
    {
        var expanded = path.StartsWith('~')
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..]
            : path;
        expanded = expanded.Replace('/', '\\');
        return System.IO.Path.GetFullPath(System.IO.Path.IsPathRooted(expanded) ? expanded : System.IO.Path.Combine(folder, expanded));
    }

    /// <summary>argument1–3：按顺序，缺一个就停。值是 JSON（placeholder、optional、type、data、percentEncoded）或者直接是占位文字（必填）。</summary>
    public static IReadOnlyList<ScriptArgument> ArgumentsFrom(IReadOnlyDictionary<string, string> fields)
    {
        var result = new List<ScriptArgument>();
        for (var index = 1; index <= 3; index++)
        {
            if (!fields.TryGetValue("argument" + index, out var value) || value.Length == 0)
            {
                break;
            }

            if (value.StartsWith('{'))
            {
                try
                {
                    using var document = JsonDocument.Parse(value);
                    var root = document.RootElement;
                    string? Text(string name) => root.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String
                        ? element.GetString()
                        : null;
                    bool Flag(string name) => root.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.True;
                    var type = Text("type");
                    var options = new List<ScriptOption>();
                    if (type == "dropdown" && root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in data.EnumerateArray())
                        {
                            string? Get(string name) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var element) &&
                                                        element.ValueKind == JsonValueKind.String
                                ? element.GetString()
                                : null;
                            if ((Get("value") ?? Get("title")) is { } optionValue)
                            {
                                options.Add(new ScriptOption(Get("title") is { Length: > 0 } title ? title : optionValue, optionValue));
                            }
                        }
                    }

                    result.Add(new ScriptArgument(Text("placeholder") ?? $"参数{index}", Flag("optional"), Flag("percentEncoded"),
                        options, type == "password"));
                    continue;
                }
                catch (JsonException)
                {
                    // 不是 JSON：当占位文字
                }
            }

            result.Add(new ScriptArgument(value));
        }

        return result;
    }

    /// <summary>开关类的字段：空或 true / yes / 1 算开。</summary>
    public static bool IsYes(string value) => value.ToLowerInvariant() is "" or "true" or "yes" or "1";

    /// <summary>confirm / needsConfirmation：空或 true = 默认那句，false = 不确认，别的就是自己写的那句。</summary>
    public static string? ConfirmationFor(string value, string title) => value.ToLowerInvariant() switch
    {
        "false" or "no" or "0" => null,
        "" or "true" or "yes" or "1" => $"再按 Enter 运行「{title}」",
        _ => value,
    };

    // ---- 参数

    /// <summary>第一个填了、却不是可选值之一的下拉参数；null = 都对得上。</summary>
    public int? InvalidChoice(IReadOnlyList<string> values)
    {
        for (var index = 0; index < values.Count && index < Arguments.Count; index++)
        {
            if (Arguments[index].Choices.Count > 0 && Arguments[index].OptionFor(values[index]) is null)
            {
                return index;
            }
        }

        return null;
    }

    /// <summary>真交给脚本的参数：下拉的换成选项的 value；声明了 percentEncoded 的先做网址编码。</summary>
    public IReadOnlyList<string> Passed(IReadOnlyList<string> values)
        => values.Select((value, index) =>
        {
            if (index >= Arguments.Count)
            {
                return value;
            }

            var argument = Arguments[index];
            var chosen = argument.OptionFor(value)?.Value ?? value;
            return argument.IsPercentEncoded ? Uri.EscapeDataString(chosen) : chosen;
        }).ToList();

    public bool Equals(ScriptCommand? other)
        => other is not null && Path == other.Path && Title == other.Title && Keyword == other.Keyword && Mode == other.Mode &&
           Arguments.SequenceEqual(other.Arguments) && Interpreter.SequenceEqual(other.Interpreter) && Confirmation == other.Confirmation &&
           Timeout == other.Timeout && Equals(Icon, other.Icon) && Filters == other.Filters && IsDownloaded == other.IsDownloaded;

    public override int GetHashCode() => HashCode.Combine(Path, Title);
}

/// <summary>「别名 空格 文字」/「标题 空格 文字」：后面的字交给这条脚本。</summary>
public sealed record ScriptInvocation(ScriptCommand Script, string Keyword, IReadOnlyList<string> Arguments, int Typing = 0)
{
    public bool IsMissing => Arguments.Count < Script.RequiredCount;
}

/// <summary>列表脚本的一条结果。</summary>
public sealed record ScriptLine(string Title, string Subtitle = "", string? Arg = null, bool IsValid = true)
{
    /// <summary>Enter 打开的：网址（任何协议交给系统）或文件。</summary>
    public string? OpensUrl { get; init; }

    public string? OpensFile { get; init; }

    public ScriptIcon? Icon { get; init; }

    public string? Autocomplete { get; init; }

    public string? CopyText { get; init; }

    public string Value => Arg ?? Title;
}

public static partial class ScriptText
{
    /// <summary>
    /// 输入是不是在给某条脚本传参数：要参数的脚本里，别名或标题（不分大小写）后面跟着空白的；几条都对得上时取词长的。
    /// alias：这条脚本此刻的别名（「命令」表里改过的，没有就是 null）。
    /// </summary>
    public static ScriptInvocation? InvocationFor(string query, IReadOnlyList<ScriptCommand> scripts, Func<ScriptCommand, string?> alias)
    {
        // 不去两头空白（LauncherMatch.Fold 会去）：「tq 」后面那个空格算数
        var folded = Search.Fold(query.TrimStart());
        (ScriptCommand Script, int Length)? best = null;
        foreach (var script in scripts.Where(script => script.TakesInput))
        {
            foreach (var key in new[] { alias(script), LauncherMatch.Fold(script.Title) })
            {
                if (string.IsNullOrEmpty(key) || key.Length <= (best?.Length ?? 0) || !folded.StartsWith(key, StringComparison.Ordinal))
                {
                    continue;
                }

                if (folded.Length > key.Length && char.IsWhiteSpace(folded[key.Length]))
                {
                    best = (script, key.Length);
                }
            }
        }

        if (best is not { } found)
        {
            return null;
        }

        var typed = PrefixOf(query.TrimStart(), found.Length);
        var rest = query.TrimStart()[typed.Length..].TrimStart();
        var count = found.Script.Arguments.Count;
        var (arguments, open) = Tokens(rest, count);
        var next = rest.Length > 0 && (!char.IsWhiteSpace(rest[^1]) || open);
        return new ScriptInvocation(found.Script, typed, arguments,
            Math.Min(next ? arguments.Count - 1 : arguments.Count, Math.Max(count - 1, 0)));
    }

    /// <summary>原样的输入里对上「折叠后 length 个字」的那一截。</summary>
    public static string PrefixOf(string query, int foldedLength)
    {
        var end = 0;
        while (end < query.Length && Search.Fold(query[..end]).Length < foldedLength)
        {
            end++;
        }

        return query[..end];
    }

    private static readonly Dictionary<char, char> Quotes = new() { ['"'] = '"', ['“'] = '”' };

    public static IReadOnlyList<string> Split(string text, int count) => Tokens(text, count).Parts;

    /// <summary>
    /// 按空白切成最多 count 段，最后一段拿剩下的全部；不止一个参数时引号括起来的算一段，最后一段整个括着的去掉引号。
    /// Open：最后一段是没配上的引号开头的。
    /// </summary>
    public static (IReadOnlyList<string> Parts, bool Open) Tokens(string text, int count)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return (Array.Empty<string>(), false);
        }

        if (count <= 1)
        {
            return (new[] { trimmed }, false);
        }

        var parts = new List<string>();
        var rest = trimmed;
        while (parts.Count < count - 1 && rest.Length > 0)
        {
            if (Quotes.TryGetValue(rest[0], out var close))
            {
                var end = rest.IndexOf(close, 1);
                if (end < 0)
                {
                    parts.Add(rest[1..]);
                    return (parts, true);
                }

                parts.Add(rest[1..end]);
                rest = rest[(end + 1)..];
            }
            else
            {
                var end = rest.TakeWhile(ch => !char.IsWhiteSpace(ch)).Count();
                parts.Add(rest[..end]);
                rest = rest[end..];
            }

            rest = rest.TrimStart();
        }

        if (rest.Length > 0)
        {
            parts.Add(Unquoted(rest));
        }

        return (parts, false);
    }

    public static string Unquoted(string text)
    {
        if (text.Length >= 2 && Quotes.TryGetValue(text[0], out var close) && text[^1] == close && !text[1..^1].Contains(close))
        {
            return text[1..^1];
        }

        return text;
    }

    /// <summary>填进搜索框时：带空白的（或者开头是引号的）括上引号。</summary>
    public static string Quoted(string text)
    {
        if (text.Length == 0)
        {
            return "\"\"";
        }

        if (!text.Any(char.IsWhiteSpace) && !Quotes.ContainsKey(text[0]))
        {
            return text;
        }

        return text.Contains('"') ? $"“{text}”" : $"\"{text}\"";
    }

    // ---- 列表输出

    /// <summary>
    /// 列表脚本的输出 → 一条条结果：开头是 { 的按 Script Filter 的 JSON 读（items 的 title、subtitle、arg、valid、url、path、icon、
    /// autocomplete、text.copy；type: file 的 arg 当路径），否则一行一条「标题⇥副标题」。folder：脚本所在的文件夹。最多 200 条。
    /// </summary>
    public static IReadOnlyList<ScriptLine> Lines(string output, string folder = @"C:\")
    {
        var text = Clean(output).Trim();
        if (text.StartsWith('{'))
        {
            try
            {
                using var document = JsonDocument.Parse(text);
                if (document.RootElement.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                {
                    var lines = new List<ScriptLine>();
                    foreach (var item in items.EnumerateArray().Take(ScriptCommand.LineLimit))
                    {
                        if (ItemLine(item, folder) is { } line)
                        {
                            lines.Add(line);
                        }
                    }

                    return lines;
                }
            }
            catch (JsonException)
            {
                // 不是 JSON：一行一条
            }
        }

        return text.Split('\n')
            .Select(line =>
            {
                var tab = line.IndexOf('\t');
                var title = (tab < 0 ? line : line[..tab]).Trim();
                return title.Length == 0 ? null : new ScriptLine(title, tab < 0 ? string.Empty : line[(tab + 1)..].Trim());
            })
            .OfType<ScriptLine>()
            .Take(ScriptCommand.LineLimit)
            .ToList();
    }

    private static ScriptLine? ItemLine(JsonElement item, string folder)
    {
        if (item.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        string? Text(string name) => item.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;
        if (Text("title") is not { Length: > 0 } title)
        {
            return null;
        }

        string? arg = null;
        if (item.TryGetProperty("arg", out var argElement))
        {
            arg = argElement.ValueKind switch
            {
                JsonValueKind.String => argElement.GetString(),
                JsonValueKind.Number => argElement.GetRawText(),
                JsonValueKind.Array => string.Join("\n", argElement.EnumerateArray()
                    .Where(value => value.ValueKind == JsonValueKind.String).Select(value => value.GetString())),
                _ => null,
            };
        }

        var valid = !(item.TryGetProperty("valid", out var validElement) && validElement.ValueKind == JsonValueKind.False);
        string? url = null;
        string? file = null;
        if (Text("url")?.Trim() is { Length: > 0 } link)
        {
            if (link.StartsWith('/') || link.StartsWith('~') || (link.Length > 2 && link[1] == ':' && link[2] is '\\' or '/'))
            {
                file = ScriptCommand.Absolute(link, folder);
            }
            else if (Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme.Length > 0)
            {
                if (uri.IsFile)
                {
                    file = ScriptCommand.Absolute(uri.LocalPath, folder);
                }
                else
                {
                    url = link;
                }
            }
        }

        if (url is null && file is null &&
            (Text("path") is { Length: > 0 } path ? path : Text("type")?.StartsWith("file", StringComparison.Ordinal) == true ? arg : null) is
            { Length: > 0 } target)
        {
            file = ScriptCommand.Absolute(target, folder);
        }

        ScriptIcon? icon = null;
        if (item.TryGetProperty("icon", out var iconElement))
        {
            if (iconElement.ValueKind == JsonValueKind.String)
            {
                icon = ScriptCommand.IconFor(iconElement.GetString() ?? string.Empty, folder);
            }
            else if (iconElement.ValueKind == JsonValueKind.Object && iconElement.TryGetProperty("path", out var iconPath) &&
                     iconPath.ValueKind == JsonValueKind.String)
            {
                var type = iconElement.TryGetProperty("type", out var iconType) && iconType.ValueKind == JsonValueKind.String ? iconType.GetString() : null;
                icon = type == "fileicon"
                    ? new ScriptIcon.FileIcon(ScriptCommand.Absolute(iconPath.GetString()!, folder))
                    : ScriptCommand.IconFor(iconPath.GetString()!, folder);
            }

            if (icon is ScriptIcon.Remote)
            {
                icon = null;
            }
        }

        string? copy = null;
        if (item.TryGetProperty("text", out var textElement) && textElement.ValueKind == JsonValueKind.Object &&
            textElement.TryGetProperty("copy", out var copyElement) && copyElement.ValueKind == JsonValueKind.String)
        {
            copy = copyElement.GetString() is { Length: > 0 } value ? value : null;
        }

        return new ScriptLine(title, Text("subtitle") ?? string.Empty, arg, valid)
        {
            OpensUrl = url,
            OpensFile = file,
            Icon = icon,
            Autocomplete = Text("autocomplete") is { Length: > 0 } complete ? complete : null,
            CopyText = copy,
        };
    }

    // ---- 输出

    [GeneratedRegex(@"\u001B\][^\u0007\u001B]*(\u0007|\u001B\\)?")]
    private static partial Regex OscPattern();

    [GeneratedRegex(@"\u001B\[[0-9;:?]*[ -/]*[@-~]")]
    private static partial Regex CsiPattern();

    [GeneratedRegex(@"\u001B[@-_]")]
    private static partial Regex EscapePattern();

    [GeneratedRegex(@"[^\n\r]*\r+(?=(?:\u001B\[[0-9;:?]*[ -/]*[@-~])*[^\n\r\u001B])")]
    private static partial Regex OverwrittenPattern();

    /// <summary>去掉终端颜色码（CSI、OSC）和回车：岛上、粘贴、复制、列表行都是纯文字。</summary>
    public static string Clean(string output)
    {
        if (output.IndexOf('\u001B') < 0 && output.IndexOf('\r') < 0)
        {
            return output;
        }

        var text = CarriageReturns(output);
        text = OscPattern().Replace(text, string.Empty);
        text = CsiPattern().Replace(text, string.Empty);
        return EscapePattern().Replace(text, string.Empty);
    }

    /// <summary>
    /// 回车：\r\n 是换行。只有 \r 当换行、没有别的换行的是老式换行；否则同终端：单独的 \r 回到行首，后面写出的字盖掉这一行（进度条只留最后一帧）。
    /// </summary>
    public static string CarriageReturns(string text)
    {
        if (text.IndexOf('\r') < 0)
        {
            return text;
        }

        var unified = text.Replace("\r\n", "\n");
        if (!unified.TrimEnd('\n').Contains('\n'))
        {
            return unified.Replace('\r', '\n');
        }

        return OverwrittenPattern().Replace(unified, string.Empty).Replace("\r", string.Empty);
    }

    /// <summary>最后一行有字的（岛上一行、出错时的原因）。</summary>
    public static string? LastLine(string output)
        => Clean(output).Split('\n').Select(line => line.Trim()).LastOrDefault(line => line.Length > 0);

    /// <summary>粘贴、复制的内容：去掉颜色码和末尾的换行，中间的照旧。</summary>
    public static string Payload(string output) => Clean(output).TrimEnd('\n', '\r');

    /// <summary>看全文时要标出来的字：block = 不放行（双向控制符、零宽字、单独的回车…），mark = 标出来照放（不换行空格、全角空格）。</summary>
    public enum HiddenKind
    {
        Block,
        Mark,
    }

    private static bool IsEmojiLike(int value)
        => value >= 0x1F000 || value is >= 0x2100 and < 0x2C00 || value is 0x200D or >= 0xFE00 and <= 0xFE0F;

    public static HiddenKind? Hidden(int value, int? previous, int? next)
    {
        switch (value)
        {
            case 0x09 or 0x0A or 0x20:
                return null;
            case 0x0D:
                return next == 0x0A ? null : HiddenKind.Block;
            case 0x200D or >= 0xFE00 and <= 0xFE0F:
                return previous is { } before && IsEmojiLike(before) ? null : HiddenKind.Block;
            case 0x115F or 0x1160 or 0x3164 or 0xFFA0 or >= 0x180B and <= 0x180F or >= 0xE0000 and <= 0xE0FFF:
                return HiddenKind.Block;
        }

        return CharUnicodeInfo.GetUnicodeCategory(value) switch
        {
            UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator =>
                HiddenKind.Block,
            UnicodeCategory.SpaceSeparator => HiddenKind.Mark,
            _ => null,
        };
    }

    /// <summary>给人看一眼的脚本：那些字换成看得见的「⟦U+200B⟧」。HasHidden：有 block 的（不放行）。</summary>
    public static (string Text, bool HasHidden) Revealed(string text)
    {
        var runes = text.EnumerateRunes().Select(rune => rune.Value).ToArray();
        var shown = new StringBuilder(text.Length);
        var blocked = false;
        var changed = false;
        for (var index = 0; index < runes.Length; index++)
        {
            var kind = Hidden(runes[index], index > 0 ? runes[index - 1] : null, index + 1 < runes.Length ? runes[index + 1] : null);
            if (kind is null)
            {
                shown.Append(char.ConvertFromUtf32(runes[index]));
                continue;
            }

            changed = true;
            blocked |= kind == HiddenKind.Block;
            shown.Append($"⟦U+{runes[index]:X4}⟧");
        }

        return (changed ? shown.ToString() : text, blocked);
    }
}
