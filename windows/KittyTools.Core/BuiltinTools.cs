// 自带的几条命令（PLAN-v18 D8，mac Resources/scripts 的 9 个里的 7 个）：Unix 时间戳、JSON 格式化、UUID、进制转换、URL 编码解码、
// Base64、正则测试。mac 是随包的 shell 脚本；Windows 上 PowerShell 冷启动要 0.2–1 秒、列表脚本每停一下就跑一遍，所以做成 C#：
// 头部字段和 mac 那几个一模一样（标题、关键词、模式、参数），走同一条脚本命令的路（别名、开关、快捷键、列表 / 粘贴 / 全文），
// 只是不起进程——ScriptRunner 认出解释器是 kitty-builtin 时调这里的 Run。输出照脚本的写法：列表一行「标题⇥副标题」。
// 「切换深色模式」做成系统命令（SystemCommands），「防止睡眠」等 issue #3 定了再做。
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static class BuiltinTools
{
    public const string Interpreter = "kitty-builtin";

    private static ScriptCommand Tool(string id, string title, string keyword, ScriptMode mode, string description, params ScriptArgument[] arguments)
        => new()
        {
            Path = "kitty-builtin:" + id,
            Title = title,
            Keyword = keyword,
            Mode = mode,
            Summary = description,
            Arguments = arguments,
            Interpreter = new[] { Interpreter },
            IsBundled = true,
        };

    /// <summary>自带的命令（排在自己的脚本后面：同一个关键词时用自己的）。</summary>
    public static readonly IReadOnlyList<ScriptCommand> Commands = new[]
    {
        Tool("time", "Unix 时间戳", "time", ScriptMode.List, "时间戳和日期互转", new ScriptArgument("时间戳或日期", IsOptional: true)),
        Tool("json", "JSON 格式化", "json", ScriptMode.Full, "把 JSON 排成好读的样子；不带参数时排剪贴板里的", new ScriptArgument("JSON", IsOptional: true)),
        Tool("uuid", "UUID 生成器", "uuid", ScriptMode.Paste, "生成一个小写的 UUID，粘贴到前台应用"),
        Tool("bcvt", "进制转换", "bcvt", ScriptMode.List, "十进制、十六进制、二进制、八进制一起列", new ScriptArgument("数字")),
        Tool("url", "URL 编码 & 解码", "url", ScriptMode.List, "百分号编码和解码，各一条", new ScriptArgument("文字")),
        Tool("b64", "Base64 编码 & 解码", "b64", ScriptMode.List, "编码和解码各一条", new ScriptArgument("文字")),
        Tool("regt", "正则表达式测试", "regt", ScriptMode.List, "列出匹配和分组；没写文字就拿剪贴板里的试",
            new ScriptArgument("正则"), new ScriptArgument("文字", IsOptional: true)),
    };

    /// <summary>
    /// 切换深色模式（系统命令 dark，D8）：此刻的 AppsUseLightTheme（没有这个值 = 浅色）→ 应用和系统两项都写成的值、提示那一句。
    /// </summary>
    public static (int LightTheme, string Message) DarkModeToggle(int? appsUseLightTheme)
        => (appsUseLightTheme ?? 1) == 0 ? (1, "已切换到浅色模式") : (0, "已切换到深色模式");

    public static bool IsBuiltin(ScriptCommand script) => script.Interpreter.Count > 0 && script.Interpreter[0] == Interpreter;

    /// <summary>跑一条：退出码和输出（列表的一行「标题⇥副标题」）。clipboard：剪贴板里的文字（json / regt 不带文字时用）。</summary>
    public static (int ExitCode, string Output) Run(string path, IReadOnlyList<string> arguments, string? clipboard, DateTimeOffset now, TimeZoneInfo zone)
    {
        var first = arguments.Count > 0 ? arguments[0].Trim() : string.Empty;
        try
        {
            return path["kitty-builtin:".Length..] switch
            {
                "time" => (0, Time(first, now, zone)),
                "json" => Json(first.Length > 0 ? string.Join(" ", arguments) : clipboard ?? string.Empty),
                "uuid" => (0, Guid.NewGuid().ToString()),
                "bcvt" => Numbers(first),
                "url" => (0, Lines((Uri.EscapeDataString(first), "编码"), (Decode(first), "解码"))),
                "b64" => (0, Base64(first)),
                "regt" => Regex(first, arguments.Count > 1 ? arguments[1] : clipboard ?? string.Empty),
                _ => (1, "不认识的命令"),
            };
        }
        catch (Exception ex) when (ex is ArgumentException or FormatException or OverflowException)
        {
            return (1, ex.Message);
        }
    }

    private static string Lines(params (string Title, string Subtitle)[] lines)
        => string.Join("\n", lines.Select(line => line.Title.Replace('\n', ' ').Replace('\t', ' ') + "\t" + line.Subtitle));

    private static string Decode(string text)
    {
        try
        {
            return Uri.UnescapeDataString(text.Replace('+', ' '));
        }
        catch (UriFormatException)
        {
            return text;
        }
    }

    /// <summary>时间戳（10 位秒、13 位毫秒）→ 本地时间、UTC、ISO；日期 → 秒、毫秒；空 = 现在。</summary>
    public static string Time(string text, DateTimeOffset now, TimeZoneInfo zone)
    {
        DateTimeOffset moment;
        if (text.Length == 0)
        {
            moment = now;
        }
        else if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number))
        {
            moment = Math.Abs(number) >= 100_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(number) : DateTimeOffset.FromUnixTimeSeconds(number);
        }
        else if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var parsed) ||
                 DateTimeOffset.TryParse(text, CultureInfo.CurrentCulture, DateTimeStyles.AssumeLocal, out parsed))
        {
            moment = parsed;
        }
        else
        {
            return Lines(("认不出", "写时间戳（秒或毫秒）或日期，如 2026-11-14 10:30"));
        }

        var local = TimeZoneInfo.ConvertTime(moment, zone);
        return Lines(
            (moment.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture), "秒"),
            (moment.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture), "毫秒"),
            (local.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture), "本地时间"),
            (moment.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture), "UTC（ISO 8601）"));
    }

    public static (int, string) Json(string text)
    {
        if (text.Trim().Length == 0)
        {
            return (1, "剪贴板里没有文字：在 json 后面贴上 JSON");
        }

        try
        {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            using var stream = new MemoryStream();
            using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
            {
                document.WriteTo(writer);
            }

            return (0, Encoding.UTF8.GetString(stream.ToArray()));
        }
        catch (JsonException ex)
        {
            return (1, $"不是 JSON：{ex.Message}");
        }
    }

    /// <summary>数字（十进制，或 0x / 0b / 0o 开头）→ 四种进制各一行。</summary>
    public static (int, string) Numbers(string text)
    {
        var clean = text.Replace("_", string.Empty).Replace(",", string.Empty).Trim().ToLowerInvariant();
        var negative = clean.StartsWith('-');
        if (negative)
        {
            clean = clean[1..];
        }

        BigInteger value;
        bool ok;
        if (clean.StartsWith("0x"))
        {
            ok = BigInteger.TryParse("0" + clean[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out value);
        }
        else if (clean.StartsWith("0b") || clean.StartsWith("0o"))
        {
            var radix = clean[1] == 'b' ? 2 : 8;
            value = BigInteger.Zero;
            ok = clean.Length > 2;
            foreach (var ch in clean[2..])
            {
                var digit = ch - '0';
                if (digit < 0 || digit >= radix)
                {
                    ok = false;
                    break;
                }

                value = value * radix + digit;
            }
        }
        else
        {
            ok = BigInteger.TryParse(clean, NumberStyles.None, CultureInfo.InvariantCulture, out value);
        }

        if (!ok)
        {
            return (1, "写一个整数：十进制，或者 0x / 0b / 0o 开头");
        }

        string Radix(int radix)
        {
            if (value.IsZero)
            {
                return "0";
            }

            var digits = new StringBuilder();
            for (var rest = value; rest > 0; rest /= radix)
            {
                digits.Insert(0, "0123456789abcdef"[(int)(rest % radix)]);
            }

            return digits.ToString();
        }

        var sign = negative ? "-" : string.Empty;
        return (0, Lines(
            (sign + value.ToString(CultureInfo.InvariantCulture), "十进制"),
            (sign + "0x" + Radix(16), "十六进制"),
            (sign + "0b" + Radix(2), "二进制"),
            (sign + "0o" + Radix(8), "八进制")));
    }

    public static string Base64(string text)
    {
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        string decoded;
        try
        {
            var bytes = Convert.FromBase64String(text.Trim().Replace('-', '+').Replace('_', '/').PadRight((text.Trim().Length + 3) / 4 * 4, '='));
            decoded = new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (Exception ex) when (ex is FormatException or DecoderFallbackException)
        {
            return Lines((encoded, "编码"));
        }

        return Lines((encoded, "编码"), (decoded, "解码"));
    }

    /// <summary>正则：每个匹配一行（副标题写第几个、在哪），带分组的再把分组各列一行。最多 1 秒、200 行。</summary>
    public static (int, string) Regex(string pattern, string text)
    {
        if (pattern.Length == 0)
        {
            return (1, "写一个正则");
        }

        System.Text.RegularExpressions.Regex regex;
        try
        {
            regex = new System.Text.RegularExpressions.Regex(pattern, RegexOptions.Multiline, TimeSpan.FromSeconds(1));
        }
        catch (ArgumentException ex)
        {
            return (1, "正则写错了：" + ex.Message);
        }

        var lines = new List<(string, string)>();
        try
        {
            var count = 0;
            foreach (Match match in regex.Matches(text))
            {
                count++;
                lines.Add((match.Value, $"匹配 {count}（第 {match.Index + 1} 个字起）"));
                for (var group = 1; group < match.Groups.Count; group++)
                {
                    var name = regex.GroupNameFromNumber(group);
                    lines.Add((match.Groups[group].Value, $"  分组 {(name == group.ToString(CultureInfo.InvariantCulture) ? name : $"{group}「{name}」")}"));
                }

                if (lines.Count >= ScriptCommand.LineLimit)
                {
                    break;
                }
            }
        }
        catch (RegexMatchTimeoutException)
        {
            return (1, "匹配超过 1 秒，停了：正则可能回溯太多");
        }

        return (0, lines.Count == 0 ? Lines(("没有匹配", text.Length == 0 ? "剪贴板里没有文字" : $"在 {text.Length} 个字里")) : Lines(lines.ToArray()));
    }
}
