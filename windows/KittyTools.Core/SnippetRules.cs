// 片段占位符（第三版 §4，纯函数 + 单测）：{date} {time} {datetime} {weekday} {uuid}
// {clipboard} / {clipboard:N} {cursor}。当前时间、剪贴板文字、UUID 都由调用方给，方便单测。
// {cursor} 不产出文字，只告诉调用方粘贴后要往左挪几个字（光标之后还有多少字）。
// 边界上的意思照 mac Clipboard/Snippet.swift（REVIEW R86，2026-11-16；片段正文是同步的，两边展开结果要一样）：
// - 花括号里的一段（不跨行、不嵌套）才看；名字不分大小写；认不出的 {…}（JSON、模板语法、{ date }、{clipboard:12}）原样留着；
// - {clipboard} / {clipboard:0} = 粘贴时剪贴板里的文字；{clipboard:N}（1…9）= 历史第 N 条文字（历史跳过所有片段，取不到是空）；
// - 只认第一个 {cursor}，其余的去掉；它后面的字数按字形簇数（和 ← 一次挪一个字对应，后面有表情时不挪过头）。
// PLAN-v26 C1（mac 0.10.0 X20，对标 Raycast 的动态占位符）：
// - 日期时间能偏移、自定格式：{date+1d}、{date-2w:yyyy/MM/dd}、{time+30m}、{weekday+1d}、{datetime:M月d日 HH:mm}。偏移能连写（{date+1M-1d}），
//   单位区分大小写：m 分钟、h 小时、d 天、w 周、M 月、y 年；格式是 mac 的写法（Unicode 日期格式），这里一段段翻成 .NET 的（UnicodeFormat），
//   月份、星期的名字用中文（界面语言）。格式只认「像日期格式」的：冒号后面紧跟着字（不是空格）、没有 %、单引号外面的英文字母都是格式字母——
//   {time: 30}（JS 对象）、{date:%Y-%m-%d}（Python）照旧原样留着。
// - 填空：{input}、{input:称呼}。粘贴前问（同一个名字只问一次、几处都填它；没写名字的几处算同一个空）。askedInputs 给 false（没问过，
//   比如拖出去）：{input…} 原样留着，不悄悄填成空的。
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public readonly record struct SnippetExpansion(string Text, int CursorBackChars);

public static partial class SnippetRules
{
    public const int MaxCursorBackChars = 500;

    /// <summary>花括号里的一段（不跨行、不嵌套）。</summary>
    [GeneratedRegex(@"\{([^{}\n]+)\}", RegexOptions.CultureInvariant)]
    private static partial Regex Token();

    [GeneratedRegex(@"^(?i:input)(?::(.*))?$", RegexOptions.CultureInvariant | RegexOptions.Singleline)]
    private static partial Regex Input();

    [GeneratedRegex(@"^((?i:datetime|date|time|weekday))((?:[+-][0-9]{1,4}[mhdwMy])*)(?::(.*))?$", RegexOptions.CultureInvariant | RegexOptions.Singleline)]
    private static partial Regex Dated();

    [GeneratedRegex(@"([+-])([0-9]{1,4})([mhdwMy])", RegexOptions.CultureInvariant)]
    private static partial Regex Offset();

    [GeneratedRegex(@"^clipboard:[1-9]$", RegexOptions.CultureInvariant)]
    private static partial Regex HistoryRef();

    [GeneratedRegex(@"\{cursor\}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Cursor();

    private const char Quote = '\'';

    private static readonly CultureInfo Chinese = CultureInfo.GetCultureInfo("zh-CN");

    /// <param name="clipboard">粘贴时剪贴板里的文字。</param>
    /// <param name="history">历史里的文字（新→旧、不含片段）：{clipboard:N} 取第 N 条。</param>
    public static SnippetExpansion Expand(
        string template, DateTimeOffset now, Func<string> uuid, string clipboard, IReadOnlyList<string> history)
        => Expand(template, now, uuid, () => clipboard, n => n <= history.Count ? history[n - 1] : null);

    /// <summary>片段里要先问的空（{input:名字} 的名字，没写名字是空串），按出现顺序、同名只算一次。</summary>
    public static IReadOnlyList<string> Inputs(string text)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var names = new List<string>();
        foreach (Match match in Token().Matches(text))
        {
            if (Input().Match(match.Groups[1].Value) is { Success: true } input && seen.Add(Label(input.Groups[1])))
            {
                names.Add(Label(input.Groups[1]));
            }
        }

        return names;
    }

    /// <summary>不认识的写法原样留着；剪贴板、历史只在用到时才读（同 mac）。</summary>
    /// <param name="uuid">每出现一处 {uuid} 调一次：每处、每次粘贴都应该是新的（REVIEW R61）。</param>
    /// <param name="inputs">填空填的字（按 Inputs 的名字）；没填的是空串。</param>
    /// <param name="askedInputs">false = 没问过（拖出去）：{input…} 原样留着。</param>
    public static SnippetExpansion Expand(
        string template, DateTimeOffset now, Func<string> uuid, Func<string?> clipboard, Func<int, string?> history,
        IReadOnlyDictionary<string, string>? inputs = null, bool askedInputs = true)
    {
        if (!Token().IsMatch(template))
        {
            return new SnippetExpansion(template, 0);
        }

        string? cached = null;
        string Clipboard() => cached ??= clipboard() ?? string.Empty;

        string? Value(string inside)
        {
            switch (inside.ToLowerInvariant())
            {
                case "uuid":
                    return uuid();
                case "cursor":
                    return string.Empty;
                case "clipboard" or "clipboard:0":
                    return Clipboard();
            }

            if (HistoryRef().IsMatch(inside.ToLowerInvariant()))
            {
                return history(inside[^1] - '0') ?? string.Empty;
            }

            if (Input().Match(inside) is { Success: true } input)
            {
                if (!askedInputs)
                {
                    return null;
                }

                return inputs is not null && inputs.TryGetValue(Label(input.Groups[1]), out var filled) ? filled : string.Empty;
            }

            if (Dated().Match(inside) is { Success: true } dated &&
                (!dated.Groups[3].Success || IsDateFormat(dated.Groups[3].Value)))
            {
                return Date(dated.Groups[1].Value.ToLowerInvariant(), dated.Groups[2].Value,
                    dated.Groups[3].Success ? dated.Groups[3].Value : null, now);
            }

            return null;
        }

        string Fill(string part) => Token().Replace(part, match => Value(match.Groups[1].Value) ?? match.Value);

        var cursor = Cursor().Match(template);
        if (!cursor.Success)
        {
            return new SnippetExpansion(Fill(template), 0);
        }

        var after = Fill(template[(cursor.Index + cursor.Length)..]);
        var back = new StringInfo(after).LengthInTextElements;
        return new SnippetExpansion(Fill(template[..cursor.Index]) + after, Math.Clamp(back, 0, MaxCursorBackChars));
    }

    private static string Label(Group group) => group.Success ? group.Value.Trim(' ', '\t') : string.Empty;

    /// <summary>日期格式里能用的字母（Unicode 日期格式的那些，同 mac patternLetters）。</summary>
    private const string PatternLetters = "GyYuUrQqMLlwWdDFgEecabBhHKkjJCmsSAzZOvVXx";

    /// <summary>冒号后面这段像不像日期格式（同 mac isDateFormat）：开头不是空白、没有 %、单引号外面的英文字母都是格式字母。空的算（用默认格式）。</summary>
    public static bool IsDateFormat(string format)
    {
        if (format.Length == 0)
        {
            return true;
        }

        if (char.IsWhiteSpace(format[0]) || format.Contains('%'))
        {
            return false;
        }

        var quoted = false;
        foreach (var c in format)
        {
            if (c == Quote)
            {
                quoted = !quoted;
            }
            else if (!quoted && char.IsAsciiLetter(c) && !PatternLetters.Contains(c))
            {
                return false;
            }
        }

        return true;
    }

    private static string Date(string name, string offsets, string? format, DateTimeOffset now)
    {
        // 按钟表时间偏移（同 mac Calendar.date(byAdding:)），时区不变
        var local = now.DateTime;
        foreach (Match step in Offset().Matches(offsets))
        {
            var amount = int.Parse(step.Groups[2].Value, CultureInfo.InvariantCulture) * (step.Groups[1].Value == "-" ? -1 : 1);
            local = step.Groups[3].Value switch
            {
                "m" => local.AddMinutes(amount),
                "h" => local.AddHours(amount),
                "d" => local.AddDays(amount),
                "w" => local.AddDays(7 * amount),
                "M" => local.AddMonths(amount),
                _ => local.AddYears(amount),
            };
        }

        if (format is not null && format.Trim().Length > 0)
        {
            return UnicodeFormat(local, format, now.Offset);
        }

        return name switch
        {
            "date" => local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            "time" => local.ToString("HH:mm", CultureInfo.InvariantCulture),
            "datetime" => local.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
            _ => Weekday(local.DayOfWeek),
        };
    }

    /// <summary>
    /// 按 Unicode 日期格式（mac DateFormatter 的写法）排一个时刻：同一个字母连写算一段，一段段翻成 .NET 的；单引号里的原样（两个单引号是一个单引号），
    /// 别的字符原样。月份、星期、上下午的名字用中文。ponytail: 只把常用的那些（y M L d D E e c H h k K m s S a Q w W z Z）翻准；
    /// 少见的（G 纪元、F、g、A、O、v、V、X、x……）按最接近的写或原样留着，要再全就照 ICU 的表补。
    /// </summary>
    public static string UnicodeFormat(DateTime local, string format, TimeSpan offset)
    {
        var builder = new StringBuilder();
        var index = 0;
        while (index < format.Length)
        {
            var c = format[index];
            if (c == Quote)
            {
                if (index + 1 < format.Length && format[index + 1] == Quote)
                {
                    builder.Append(Quote);
                    index += 2;
                    continue;
                }

                var end = index + 1;
                while (end < format.Length)
                {
                    if (format[end] == Quote && end + 1 < format.Length && format[end + 1] == Quote)
                    {
                        builder.Append(Quote);
                        end += 2;
                        continue;
                    }

                    if (format[end] == Quote)
                    {
                        break;
                    }

                    builder.Append(format[end++]);
                }

                index = end + 1;
                continue;
            }

            if (!char.IsAsciiLetter(c))
            {
                builder.Append(c);
                index++;
                continue;
            }

            var count = 1;
            while (index + count < format.Length && format[index + count] == c)
            {
                count++;
            }

            builder.Append(Field(local, c, count, offset));
            index += count;
        }

        return builder.ToString();
    }

    private static string Two(int value) => value.ToString("00", CultureInfo.InvariantCulture);

    private static string Number(int value, int width) => value.ToString(new string('0', Math.Max(1, width)), CultureInfo.InvariantCulture);

    private static string Field(DateTime local, char letter, int count, TimeSpan offset)
    {
        var names = Chinese.DateTimeFormat;
        switch (letter)
        {
            case 'y' or 'Y' or 'u' or 'U' or 'r':
                return count == 2 ? Two(local.Year % 100) : Number(local.Year, count);
            case 'M' or 'L':
                return count switch
                {
                    1 => local.Month.ToString(CultureInfo.InvariantCulture),
                    2 => Two(local.Month),
                    3 => names.GetAbbreviatedMonthName(local.Month),
                    _ => names.GetMonthName(local.Month),
                };
            case 'd':
                return Number(local.Day, count);
            case 'D':
                return Number(local.DayOfYear, count);
            case 'E' or 'e' or 'c':
                if (letter != 'E' && count <= 2)
                {
                    // 本地的星期几数字：中文是周一起算（1 = 周一）
                    return (((int)local.DayOfWeek + 6) % 7 + 1).ToString(CultureInfo.InvariantCulture);
                }

                return count == 4 ? Weekday(local.DayOfWeek)
                    : count >= 5 ? names.GetShortestDayName(local.DayOfWeek)
                    : names.GetAbbreviatedDayName(local.DayOfWeek);
            case 'a' or 'b' or 'B':
                return local.Hour < 12 ? names.AMDesignator : names.PMDesignator;
            case 'H' or 'j' or 'J' or 'C':
                return Number(local.Hour, count);
            case 'k':
                return Number(local.Hour == 0 ? 24 : local.Hour, count);
            case 'h':
                return Number(local.Hour % 12 == 0 ? 12 : local.Hour % 12, count);
            case 'K':
                return Number(local.Hour % 12, count);
            case 'm':
                return Number(local.Minute, count);
            case 's':
                return Number(local.Second, count);
            case 'S':
                var fraction = (local.Ticks % TimeSpan.TicksPerSecond).ToString("0000000", CultureInfo.InvariantCulture);
                return count <= 7 ? fraction[..count] : fraction.PadRight(count, '0');
            case 'Q' or 'q':
                var quarter = (local.Month - 1) / 3 + 1;
                return count <= 2 ? Number(quarter, count) : $"第{quarter}季度";
            case 'w':
                return Number(ISOWeek.GetWeekOfYear(local), count);
            case 'W' or 'F':
                return ((local.Day - 1) / 7 + 1).ToString(CultureInfo.InvariantCulture);
            case 'G':
                return "公元";
            case 'z' or 'Z' or 'O' or 'v' or 'V' or 'X' or 'x':
                var sign = offset < TimeSpan.Zero ? "-" : "+";
                var abs = offset.Duration();
                return count >= 4 || letter is 'O'
                    ? $"GMT{sign}{Two(abs.Hours)}:{Two(abs.Minutes)}"
                    : $"{sign}{Two(abs.Hours)}{Two(abs.Minutes)}";
            default:
                return new string(letter, count);
        }
    }

    private static string Weekday(DayOfWeek day) => day switch
    {
        DayOfWeek.Monday => "星期一",
        DayOfWeek.Tuesday => "星期二",
        DayOfWeek.Wednesday => "星期三",
        DayOfWeek.Thursday => "星期四",
        DayOfWeek.Friday => "星期五",
        DayOfWeek.Saturday => "星期六",
        _ => "星期日",
    };
}

/// <summary>收藏夹的规则（纯函数 + 单测）：名字去空白、最多 24 字、不重名（不区分大小写）。</summary>
public static class ClipGroups
{
    public const int MaxNameLength = 24;

    public const int MaxCount = 200;

    public static string? Normalize(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        var trimmed = name.Trim();
        return trimmed.Length > MaxNameLength ? trimmed[..MaxNameLength] : trimmed;
    }

    public static bool IsUnique(string name, IEnumerable<string> existing, string? ignore = null)
        => !existing.Any(other =>
            !string.Equals(other, ignore, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(other, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>有收藏夹的条目一定是收藏（第三版 §4 的不变式）。</summary>
    public static bool GroupImpliesFavorite(string? groupId, bool favorite) => groupId is null || favorite;
}
