// 启动器里一句话建提醒（PLAN-v12 N6，照 mac Reminders/ReminderPhrase.swift，纯函数，单测锁住）：「提醒 10分钟 喝水」「tx 明天9点 交周报」
// 「提醒 下午3点半 开会」。关键词「提醒」「tx」「remind」后面要有空格（这三个词也不能再当网页搜索的关键词，WebSearch.ReservedKeywords）。
// 认的写法：
// - 多久之后：10分钟 / 10分 / 10m / 半小时 / 一刻钟 / 1小时 / 1.5小时 / 1个半小时 / 1小时20分 / 2h，后面可带「后 / 以后 / 之后」；
// - 哪天：今天 / 明天 / 后天 / 大后天、今晚 / 明晚 / 今早 / 明早、周五 / 星期五 / 礼拜五（今天就是周五而时间还没过就是今天，否则下一个）、
//   下周一、12月25日（过了就是明年）；
// - 几点：9点 / 9点半 / 9点15 / 9点5分 / 9:30，前面可带 早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上 / 凌晨；「点」和分钟之间不许有空格、
//   不带「分」时分钟要两位；只写「9点」没说上午下午时取最近的那个将来时刻（只有 1–11 点两可）；只写哪天没写几点 = 那天 9:00，
//   写了「中午 / 下午 / 晚上」没写几点 = 12 / 15 / 20 点。
// - 两样都有时按先出现的那个。不认：重复（「每天…」）、年份、农历、汉字数字。全角数字和冒号先换成半角。
// 时间去掉之后剩下的就是标题，没剩下就是「时间到了」。
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class ReminderPhrase
{
    /// <summary>启动器的关键词（不分大小写；后面要有空格）。</summary>
    public static readonly string[] Keywords = { "提醒", "tx", "remind" };

    public const string DefaultTitle = "时间到了";

    /// <summary>「提醒 …」后面的部分；只输关键词（没空格）、不是这几个关键词开头的给 null。</summary>
    public static string? Query(string text)
    {
        foreach (var keyword in Keywords)
        {
            if (text.StartsWith(keyword + " ", StringComparison.OrdinalIgnoreCase))
            {
                return text[keyword.Length..].Trim(' ', '\t');
            }
        }

        return null;
    }

    /// <summary>只输了关键词：出补全提示。</summary>
    public static bool IsKeyword(string text) => Keywords.Contains(text.Trim(' ', '\t').ToLowerInvariant());

    /// <summary>写的是重复的提醒：启动器只建一次性的，提示去设置里建。</summary>
    public static bool IsRepeating(string text)
        => new[] { "每天", "每周", "每月", "每隔", "每小时", "每个", "每晚", "每早", "工作日" }.Any(text.Contains);

    /// <summary>解析一句话（关键词后面的部分）：认不出时间、写的是重复的给 null。算出来的时刻可能已经过了，调用方自己看。</summary>
    public static (DateTime At, string Title)? Parse(string raw, DateTime nowUtc, TimeZoneInfo zone)
    {
        var text = HalfWidth(raw);
        if (IsRepeating(text))
        {
            return null;
        }

        var span = Duration(text);
        var point = Moment(text, nowUtc, zone);
        if (span is { } duration && (point is null || duration.Start < point.Value.Start))
        {
            return (nowUtc.AddMinutes(duration.Minutes), Title(text, duration.Start, duration.Length));
        }

        return point is { } moment ? (moment.At, Title(text, moment.Start, moment.Length)) : null;
    }

    /// <summary>全角数字和冒号换成半角（别的全角标点不动：标题里的「，」照旧）。</summary>
    public static string HalfWidth(string text)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            builder.Append(ch switch
            {
                >= '０' and <= '９' => (char)(ch - 0xFF10 + '0'),
                '：' => ':',
                _ => ch,
            });
        }

        return builder.ToString();
    }

    // ---- 多久之后

    /// <summary>汉字写的几个常用的；「一个半小时」排在「半小时」前面。</summary>
    private static readonly (string Word, double Minutes)[] FixedSpans =
    {
        ("一个半小时", 90), ("一个半钟头", 90), ("半个小时", 30), ("半小时", 30), ("一刻钟", 15), ("一个小时", 60), ("一小时", 60),
    };

    [GeneratedRegex(
        @"([0-9]+(?:\.[0-9]+)?)\s*(?:个\s*)?(半\s*)?(?:小时|钟头|(?:hours?|hrs?|h)(?![a-z]))(?:\s*([0-9]+)\s*(?:分钟|分|minutes?|mins?|m)(?![a-z]))?(?:\s*(?:以后|之后|后))?",
        RegexOptions.IgnoreCase)]
    private static partial Regex HoursPattern();

    /// <summary>前面紧挨着「点」的不算（「3点15分」是钟点，不是 15 分钟后）。</summary>
    [GeneratedRegex(@"(?<![0-9.点])(?<!点\s)([0-9]+)\s*(?:分钟|分|minutes?|mins?|m)(?![a-z])(?:\s*(?:以后|之后|后))?", RegexOptions.IgnoreCase)]
    private static partial Regex MinutesPattern();

    /// <summary>「多久之后」有几分钟、在原文的哪一段（夹在 1 分钟…7 天）。</summary>
    public static (double Minutes, int Start, int Length)? Duration(string text)
    {
        var found = new List<(double Minutes, int Start, int Length)>();
        var hours = HoursPattern().Match(text);
        if (hours.Success && double.TryParse(hours.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var count))
        {
            var half = hours.Groups[2].Success ? 30.0 : 0;
            var extra = hours.Groups[3].Success && double.TryParse(hours.Groups[3].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var more)
                ? more
                : 0;
            if (Clamp(count * 60 + half + extra) is { } minutes)
            {
                found.Add((minutes, hours.Index, hours.Length));
            }
        }

        foreach (var (word, minutes) in FixedSpans)
        {
            var index = text.IndexOf(word, StringComparison.Ordinal);
            if (index >= 0)
            {
                found.Add((minutes, index, Suffix(text, index + word.Length) - index));
                break;
            }
        }

        var plain = MinutesPattern().Match(text);
        if (plain.Success && double.TryParse(plain.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) &&
            Clamp(value) is { } clamped)
        {
            found.Add((clamped, plain.Index, plain.Length));
        }

        // 几样都认出来时：最先出现的、同一处的取最长的。
        return found.Count == 0 ? null : found.OrderBy(item => item.Start).ThenByDescending(item => item.Length).First();
    }

    /// <summary>「半小时后」的「后」也算进时间那一段。</summary>
    private static int Suffix(string text, int index)
    {
        foreach (var word in new[] { "以后", "之后", "后" })
        {
            if (string.CompareOrdinal(text, index, word, 0, word.Length) == 0)
            {
                return index + word.Length;
            }
        }

        return index;
    }

    private static double? Clamp(double minutes) => minutes is >= 1 and <= 7 * 24 * 60 ? minutes : null;

    // ---- 哪天几点

    // 组：1 今天…明早  2 下  3 星期几  4 月  5 日  6 早上…凌晨  7–8 时:分  9 点  10 半  11 N分  12 两位分钟
    [GeneratedRegex(
        @"(?:(大后天|后天|明天|今天|今晚|明晚|今早|明早)|(下\s*)?(?:周|星期|礼拜)([一二三四五六日天1-7])|([0-9]{1,2})\s*月\s*([0-9]{1,2})\s*[日号])?\s*(早上|上午|中午|下午|傍晚|晚上|凌晨)?\s*(?:([0-9]{1,2})\s*:\s*([0-9]{2})|([0-9]{1,2})\s*点(?:(半)|([0-9]{1,2})分|([0-9]{2})(?![0-9]))?)?")]
    private static partial Regex MomentPattern();

    private static readonly Dictionary<char, int> Weekdays = new()
    {
        ['日'] = 1, ['天'] = 1, ['一'] = 2, ['二'] = 3, ['三'] = 4, ['四'] = 5, ['五'] = 6, ['六'] = 7,
        ['1'] = 2, ['2'] = 3, ['3'] = 4, ['4'] = 5, ['5'] = 6, ['6'] = 7, ['7'] = 1,
    };

    private static readonly Dictionary<string, (int Days, string? Period)> RelativeDays = new(StringComparer.Ordinal)
    {
        ["今天"] = (0, null), ["明天"] = (1, null), ["后天"] = (2, null), ["大后天"] = (3, null),
        ["今晚"] = (0, "晚上"), ["明晚"] = (1, "晚上"), ["今早"] = (0, "早上"), ["明早"] = (1, "早上"),
    };

    private static readonly Dictionary<string, int> PeriodHours = new(StringComparer.Ordinal)
    {
        ["早上"] = 8, ["上午"] = 9, ["中午"] = 12, ["下午"] = 15, ["傍晚"] = 18, ["晚上"] = 20, ["凌晨"] = 1,
    };

    /// <summary>「哪天几点」是哪一刻、在原文的哪一段；没写哪天也没写几点、写错了（25 点、2 月 30 号）给 null。</summary>
    public static (DateTime At, int Start, int Length)? Moment(string text, DateTime nowUtc, TimeZoneInfo zone)
    {
        var location = 0;
        while (location < text.Length)
        {
            var match = MomentPattern().Match(text, location);
            if (!match.Success)
            {
                return null;
            }

            // 空匹配（这个位置什么都没有）：往后挪一个字再找。
            if (match.Length == 0)
            {
                location = match.Index + 1;
                continue;
            }

            string? Group(int index) => match.Groups[index].Success ? match.Groups[index].Value : null;
            (int Days, string? Period)? relative = Group(1) is { } word && RelativeDays.TryGetValue(word, out var value) ? value : null;
            var hasDay = relative is not null || Group(3) is not null || Group(4) is not null;
            var hasTime = Group(7) is not null || Group(9) is not null;
            // 只有「下午」这类词、没有日期也没有钟点：不算。
            if (!hasDay && !hasTime)
            {
                location = match.Index + match.Length;
                continue;
            }

            var period = Group(6) ?? relative?.Period;
            var hour = period is not null && PeriodHours.TryGetValue(period, out var periodHour) ? periodHour : 9;
            var minute = 0;
            if (Group(7) is { } h && Group(8) is { } m)
            {
                hour = int.TryParse(h, out var parsedHour) ? parsedHour : -1;
                minute = int.TryParse(m, out var parsedMinute) ? parsedMinute : -1;
            }
            else if (Group(9) is { } clock)
            {
                hour = int.TryParse(clock, out var parsedHour) ? parsedHour : -1;
                minute = Group(10) is not null ? 30 : (Group(11) ?? Group(12)) is { } minuteText && int.TryParse(minuteText, out var parsed) ? parsed : 0;
            }

            if (hasTime)
            {
                hour = Adjusted(hour, period);
            }

            if (hour is < 0 or > 23 || minute is < 0 or > 59)
            {
                return null;
            }

            // 没说上午下午的 1–11 点两可（0 点、12 点不）。
            var ambiguous = hasTime && period is null && hour is >= 1 and <= 11;
            var day = ResolveDay(
                relative?.Days, Group(2) is not null, Group(3)?[0], Group(4) is { } month ? int.Parse(month, CultureInfo.InvariantCulture) : null,
                Group(5) is { } date ? int.Parse(date, CultureInfo.InvariantCulture) : null, hour, minute, ambiguous, nowUtc, zone);
            return day is { } at ? (at, match.Index, match.Length) : null;
        }

        return null;
    }

    /// <summary>按「下午 / 晚上」改成 24 小时制：下午 3 点 = 15 点；中午 1 点 = 13 点；晚上 / 凌晨 / 早上 12 点 = 0 点。</summary>
    private static int Adjusted(int hour, string? period) => period switch
    {
        "下午" or "傍晚" => hour < 12 ? hour + 12 : hour,
        "晚上" => hour == 12 ? 0 : hour < 12 ? hour + 12 : hour,
        "中午" => hour < 11 ? hour + 12 : hour,
        "凌晨" or "早上" or "上午" => hour == 12 ? 0 : hour,
        _ => hour,
    };

    private static DateTime? ResolveDay(
        int? offset, bool nextWeek, char? weekday, int? month, int? dayOfMonth, int hour, int minute, bool ambiguous,
        DateTime nowUtc, TimeZoneInfo zone)
    {
        var today = ReminderMath.Local(nowUtc, zone).Date;
        DateTime At(DateTime day, int h) => ReminderMath.LocalToUtc(day.AddHours(h).AddMinutes(minute), zone);
        DateTime Plus(int days) => today.AddDays(days);
        if (offset is { } days)
        {
            return At(Plus(days), hour);
        }

        if (weekday is { } name && Weekdays.TryGetValue(name, out var target))
        {
            var current = ReminderMath.Weekday(today);
            if (nextWeek)
            {
                // 下周 = 从下周一起的那一周（周一算一周的开始）。
                var toMonday = (9 - current) % 7 == 0 ? 7 : (9 - current) % 7;
                var fromMonday = (target + 5) % 7;
                return At(Plus(toMonday + fromMonday), hour);
            }

            var ahead = (target - current + 7) % 7;
            if (ahead == 0 && At(today, hour) <= nowUtc)
            {
                ahead = 7;
            }

            return At(Plus(ahead), hour);
        }

        if (month is { } m && dayOfMonth is { } d)
        {
            var year = today.Year;
            foreach (var candidate in new[] { year, year + 1 })
            {
                if (m is < 1 or > 12 || d < 1 || d > DateTime.DaysInMonth(candidate, m))
                {
                    return null;
                }

                var date = At(new DateTime(candidate, m, d), hour);
                if (date > nowUtc)
                {
                    return date;
                }
            }

            return null;
        }

        // 没写哪天：今天里最近的那个将来时刻（只写「9点」时 9 点、21 点都算），都过了就是明天。
        var hours = ambiguous ? new[] { hour, hour + 12 } : new[] { hour };
        var soonest = hours.Select(h => At(today, h)).Where(at => at > nowUtc).OrderBy(at => at).Cast<DateTime?>().FirstOrDefault();
        return soonest ?? At(Plus(1), hour);
    }

    // ---- 标题

    /// <summary>去掉时间那一段，剩下的收拾一下当标题；没剩下就是「时间到了」。</summary>
    private static string Title(string text, int start, int length)
    {
        var rest = text.Remove(start, length);
        var trimmed = rest.Trim().Trim('，', ',', '、', '。', ':', '：', ' ', '\t', '\n', '\r', '\u3000').Trim();
        var title = StatusPresets.OneLine(trimmed);
        if (title.Length == 0)
        {
            return DefaultTitle;
        }

        var info = new StringInfo(title);
        return info.LengthInTextElements <= Reminders.MaxTitle ? title : info.SubstringByTextElements(0, Reminders.MaxTitle);
    }
}

/// <summary>
/// 启动器里「提醒 …」那几行（PLAN-v12 N6，mac LauncherModel.reminderItems / reminderPrompts，纯函数）：认出了时间的先是「建一条」，再是已有的提醒——
/// 没写别的时全列，写了的只列标题里带着这些字的；认不出、已经过了、写的是重复的给一行提示，排在已有的后面。单输关键词出补全提示。
/// 行都借现成的种类：「建一条」和已有的是内置动作（目标 reminder:new / reminder:&lt;id&gt;，右侧小字「提醒」），提示是补全提示。
/// </summary>
public static class ReminderLauncher
{
    public const string Prefix = "reminder:";
    public const string NewTarget = "reminder:new";
    public const string HintTarget = "reminder-hint";
    public const string KeywordTarget = "reminder-new";

    public const string EmptyText = "还没有提醒：在「提醒 」后面接着写时间和内容，如「10分钟 喝水」";

    public static bool IsReminder(string target) => target.StartsWith(Prefix, StringComparison.Ordinal);

    /// <summary>已有的那一条的 id（不是「建一条」）；别的目标给 null。</summary>
    public static string? IdOf(string target)
        => IsReminder(target) && target != NewTarget ? target[Prefix.Length..] : null;

    /// <summary>单输「提醒」「tx」「remind」：Enter / Tab 补全关键词的提示。</summary>
    public static IReadOnlyList<LauncherItem> Prompts(string query)
        => ReminderPhrase.IsKeyword(query)
            ? new[]
            {
                new LauncherItem
                {
                    Kind = LauncherKind.Prompt,
                    Target = KeywordTarget,
                    Title = "新建提醒…",
                    Subtitle = "输入「提醒 空格 时间 内容」，如「提醒 10分钟 喝水」；Enter 或 Tab 补全关键词",
                    Completion = query.Trim() + " ",
                    Note = "提醒",
                },
            }
            : Array.Empty<LauncherItem>();

    public static List<LauncherItem> Items(string rest, IReadOnlyList<Reminder> list, DateTime nowUtc, TimeZoneInfo zone)
    {
        var create = new List<LauncherItem>();
        var hint = new List<LauncherItem>();
        if (rest.Length > 0)
        {
            var parsed = ReminderPhrase.Parse(rest, nowUtc, zone);
            if (parsed is { } value && value.At > nowUtc)
            {
                var when = Reminders.ScheduleSummary(
                    new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(value.At) }, nowUtc, zone);
                create.Add(new LauncherItem
                {
                    Kind = LauncherKind.Action, Target = NewTarget, Title = "提醒我：" + value.Title, Subtitle = when, Payload = rest, Note = "提醒",
                });
            }
            else
            {
                var repeating = ReminderPhrase.IsRepeating(ReminderPhrase.HalfWidth(rest));
                hint.Add(new LauncherItem
                {
                    Kind = LauncherKind.Prompt,
                    Target = HintTarget,
                    Title = repeating ? "重复的提醒到设置里建" : parsed is null ? "认不出时间" : "这个时间已经过了",
                    Subtitle = repeating
                        ? "这里只建一次的；每天、每周、每隔一阵的到 设置 › 提醒 里加"
                        : "试试「10分钟 喝水」「明天9点 交周报」「下午3点半 开会」",
                    Note = "提醒",
                });
            }
        }

        var folded = LauncherMatch.Fold(rest);
        var existing = list
            .Where(reminder => rest.Length == 0 || LauncherMatch.Fold(reminder.Title).Contains(folded, StringComparison.Ordinal))
            .Select(reminder => new LauncherItem
            {
                Kind = LauncherKind.Action,
                Target = Prefix + reminder.Id,
                Title = reminder.Title,
                Subtitle = Reminders.Summary(reminder, nowUtc, zone) + (reminder.IsOn ? string.Empty : " · 已暂停"),
                Payload = reminder.IsOn ? "on" : "off",
                Note = "提醒",
                Emoji = reminder.Symbol.Length > 0 ? reminder.Symbol : null,
            });
        return create.Concat(existing).Concat(hint).ToList();
    }
}
