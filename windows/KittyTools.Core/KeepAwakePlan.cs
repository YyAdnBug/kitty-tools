// 保持唤醒（PLAN-v20 K1，第一个插件；照 mac KeepAwake/KeepAwakePlan.swift，f48c5d2e）的纯函数，单测锁住（KeepAwakeTests）：
// - 定时（KeepAwakeSchedule）：一条，勾星期几 + 一天里的时段；时段在里面就保持唤醒、出了就停。结束早于开始 = 跨午夜，算在开始那天
//   （周五 22:00–02:00 管到周六凌晨两点）；「全天」单独一个开关：开始等于结束不当全天（拨时间时两边会短暂相等），只是那天没有时段。
//   几点按那天的钟点算（时区、夏令时由 TimeZoneInfo 换算）。下一次要变的时刻只算真的进 / 出的那一刻（连着的两天全天之间的半夜不算）。
// - 启动器「awake 2小时」「保持唤醒 到18点」「awake 30m」「awake 无限期」：多久之后、几点都借提醒的解析（ReminderPhrase），
//   时间以外只许剩下「到 / 直到 / 至 / until」这类连接词，别的字认不出就给 Invalid（不猜）。
// - 剩多久的说法（托盘、启动器、设置页、轻提示同一句）。
// 星期的编号同 mac 的日历（1 = 周日 … 7 = 周六），存进 settings.json 的也是这个，和 mac 导出的写法一样。
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KittyTools.Core;

/// <summary>设置 › 保持唤醒「定时」（跟着这台电脑，不同步；导出导入带着）。</summary>
public sealed record KeepAwakeSchedule
{
    public bool IsOn { get; init; }

    /// <summary>星期（1 = 周日 … 7 = 周六）；默认工作日。</summary>
    public IReadOnlyList<int> Weekdays { get; init; } = new[] { 2, 3, 4, 5, 6 };

    /// <summary>一天里的第几分钟（0…1439）；默认 9:00–18:00。</summary>
    public int Start { get; init; } = 9 * 60;

    public int End { get; init; } = 18 * 60;

    /// <summary>那天整整 24 小时（勾了全天时 Start / End 留着，关掉全天回到原来的时段）。</summary>
    public bool AllDay { get; init; }

    public bool Equals(KeepAwakeSchedule? other)
        => other is not null && IsOn == other.IsOn && Start == other.Start && End == other.End && AllDay == other.AllDay &&
           Weekdays.OrderBy(day => day).SequenceEqual(other.Weekdays.OrderBy(day => day));

    public override int GetHashCode() => HashCode.Combine(IsOn, Start, End, AllDay, Weekdays.Count);

    /// <summary>读出来：读不出、字段越界的回到默认 / 夹回来（设置导入、手改过的 settings.json）。</summary>
    public static KeepAwakeSchedule Decode(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return new KeepAwakeSchedule();
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return new KeepAwakeSchedule();
            }

            var fallback = new KeepAwakeSchedule();
            bool Flag(string name, bool value) => root.TryGetProperty(name, out var field) && field.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? field.GetBoolean()
                : value;
            int Minutes(string name, int value) => root.TryGetProperty(name, out var field) && field.TryGetInt32(out var number)
                ? Math.Clamp(number, 0, 24 * 60 - 1)
                : value;
            var days = fallback.Weekdays;
            if (root.TryGetProperty("weekdays", out var list) && list.ValueKind == JsonValueKind.Array)
            {
                days = list.EnumerateArray()
                    .Where(item => item.TryGetInt32(out _)).Select(item => item.GetInt32())
                    .Where(day => day is >= 1 and <= 7).Distinct().OrderBy(day => day).ToArray();
            }

            return new KeepAwakeSchedule
            {
                IsOn = Flag("isOn", fallback.IsOn),
                Weekdays = days,
                Start = Minutes("start", fallback.Start),
                End = Minutes("end", fallback.End),
                AllDay = Flag("allDay", fallback.AllDay),
            };
        }
        catch (JsonException)
        {
            return new KeepAwakeSchedule();
        }
    }

    /// <summary>存成 JSON（键同 mac：allDay、end、isOn、start、weekdays，按字母排）。</summary>
    public string Encode()
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteBoolean("allDay", AllDay);
            writer.WriteNumber("end", End);
            writer.WriteBoolean("isOn", IsOn);
            writer.WriteNumber("start", Start);
            writer.WriteStartArray("weekdays");
            foreach (var day in Weekdays.OrderBy(day => day))
            {
                writer.WriteNumberValue(day);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>从 day 那天（当地日期）开始的那一段（UTC）；那天没勾、没有时段的给 null。</summary>
    public (DateTime From, DateTime To)? Window(DateTime localDay, TimeZoneInfo zone)
    {
        var midnight = localDay.Date;
        if (!Weekdays.Contains((int)midnight.DayOfWeek + 1))
        {
            return null;
        }

        if (AllDay)
        {
            return (KeepAwakePlan.ToUtc(midnight, zone), KeepAwakePlan.ToUtc(midnight.AddDays(1), zone));
        }

        if (Start == End)
        {
            return null;
        }

        var from = KeepAwakePlan.ToUtc(midnight.AddMinutes(Start), zone);
        var to = KeepAwakePlan.ToUtc(midnight.AddDays(End > Start ? 0 : 1).AddMinutes(End), zone);
        return to > from ? (from, to) : null;
    }

    /// <summary>这一刻（UTC）在不在时段里（定时开着才算）。</summary>
    public bool Contains(DateTime nowUtc, TimeZoneInfo zone)
        => IsOn && Windows(nowUtc, zone).Any(window => window.From <= nowUtc && nowUtc < window.To);

    /// <summary>这一刻之后下一次真的进 / 出时段的时刻（UTC）；连着的两段之间的接缝不算。定时关着、一天都没勾、一直在时段里的给 null。</summary>
    public DateTime? NextChange(DateTime nowUtc, TimeZoneInfo zone)
    {
        if (!IsOn)
        {
            return null;
        }

        var now = Contains(nowUtc, zone);
        foreach (var moment in Windows(nowUtc, zone).SelectMany(window => new[] { window.From, window.To })
                     .Where(moment => moment > nowUtc).Distinct().OrderBy(moment => moment))
        {
            if (Contains(moment, zone) != now)
            {
                return moment;
            }
        }

        return null;
    }

    /// <summary>前一天起往后一周多的每一段（跨午夜的前一天那段管到今天凌晨）。</summary>
    private IEnumerable<(DateTime From, DateTime To)> Windows(DateTime nowUtc, TimeZoneInfo zone)
    {
        var today = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, zone).Date;
        for (var offset = -1; offset <= 8; offset++)
        {
            if (Window(today.AddDays(offset), zone) is { } window)
            {
                yield return window;
            }
        }
    }

    /// <summary>「工作日 9:00–18:00」「周六、周日 22:00–次日 2:00」「每天 全天」：设置页、轻提示的说法（同 mac）。</summary>
    [JsonIgnore]
    public string Summary
    {
        get
        {
            var set = Weekdays.ToHashSet();
            string days;
            if (set.SetEquals(new[] { 2, 3, 4, 5, 6 }))
            {
                days = "工作日";
            }
            else if (set.SetEquals(Enumerable.Range(1, 7)))
            {
                days = "每天";
            }
            else if (set.SetEquals(new[] { 1, 7 }))
            {
                days = "周末";
            }
            else if (set.Count == 0)
            {
                days = "没选哪天";
            }
            else
            {
                days = string.Join("、", Order.Where(set.Contains).Select(day => "周" + Names[day - 1]));
            }

            if (AllDay)
            {
                return days + " 全天";
            }

            return $"{days} {KeepAwakePlan.Clock(Start)}–{(End < Start ? "次日 " : string.Empty)}{KeepAwakePlan.Clock(End)}";
        }
    }

    /// <summary>周一排在最前（设置页那一排也是这个顺序）。</summary>
    public static readonly int[] Order = { 2, 3, 4, 5, 6, 7, 1 };

    public static readonly string[] Names = { "日", "一", "二", "三", "四", "五", "六" };
}

/// <summary>启动器里「awake」后面那截解析出来的样子。</summary>
public abstract record KeepAwakeParsed
{
    /// <summary>什么都没写（列几档让你挑）。</summary>
    public sealed record Empty : KeepAwakeParsed;

    public sealed record Indefinitely : KeepAwakeParsed;

    /// <summary>到这一刻（UTC）；Label 是行上写的「2 小时」「到 18:00」。</summary>
    public sealed record Until(DateTime AtUtc, string Label) : KeepAwakeParsed;

    /// <summary>写了认不出的。</summary>
    public sealed record Invalid : KeepAwakeParsed;
}

public static class KeepAwakePlan
{
    /// <summary>托盘子菜单、设置页「开始」的几档（null = 无限期）。</summary>
    public static readonly (string Title, int? Minutes)[] Presets =
    {
        ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("5 小时", 300), ("无限期", null),
    };

    /// <summary>启动器的关键词（同 mac；也是网页搜索的保留词）。</summary>
    public static readonly string[] Keywords = { "awake", "保持唤醒", "防息屏" };

    private static readonly string[] Forever = { "无限期", "无限", "一直", "永久", "不限", "forever", "∞" };

    /// <summary>「到 18 点」里的连接词：去掉之后什么都不剩才算认出来了。</summary>
    private static readonly string[] Joiners = { "直到", "一直到", "到", "至", "until", "till", "to", "后", "以后", "之后" };

    public static DateTime ToUtc(DateTime local, TimeZoneInfo zone)
        => TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), zone);

    public static KeepAwakeParsed Parse(string raw, DateTime nowUtc, TimeZoneInfo zone)
    {
        var text = ReminderPhrase.HalfWidth(raw).Trim();
        if (text.Length == 0)
        {
            return new KeepAwakeParsed.Empty();
        }

        if (Forever.Contains(text.ToLowerInvariant()))
        {
            return new KeepAwakeParsed.Indefinitely();
        }

        // 两样都有时按先出现的（同提醒）
        var span = ReminderPhrase.Duration(text);
        var point = ReminderPhrase.Moment(text, nowUtc, zone);
        if (span is { } duration && (point is null || duration.Start <= point.Value.Start))
        {
            return Leftover(text, duration.Start, duration.Length)
                ? new KeepAwakeParsed.Until(nowUtc.AddMinutes(duration.Minutes), Length((int)duration.Minutes))
                : new KeepAwakeParsed.Invalid();
        }

        if (point is { } moment && moment.At > nowUtc)
        {
            return Leftover(text, moment.Start, moment.Length)
                ? new KeepAwakeParsed.Until(moment.At, "到 " + Moment(moment.At, nowUtc, zone))
                : new KeepAwakeParsed.Invalid();
        }

        return new KeepAwakeParsed.Invalid();
    }

    /// <summary>时间那一段去掉之后，剩下的只有连接词。</summary>
    private static bool Leftover(string text, int start, int length)
    {
        var rest = (text[..start] + text[(start + length)..]).ToLowerInvariant().Replace(" ", string.Empty);
        foreach (var word in Joiners.OrderByDescending(word => word.Length))
        {
            rest = rest.Replace(word, string.Empty);
        }

        return rest.Length == 0;
    }

    /// <summary>「2 小时」「1 小时 30 分钟」「45 分钟」。</summary>
    public static string Length(int minutes)
    {
        var hours = minutes / 60;
        var rest = minutes % 60;
        if (hours == 0)
        {
            return $"{rest} 分钟";
        }

        return rest == 0 ? $"{hours} 小时" : $"{hours} 小时 {rest} 分钟";
    }

    /// <summary>「18:00」「明天 8:00」「11月20日 9:00」：到哪一刻。</summary>
    public static string Moment(DateTime atUtc, DateTime nowUtc, TimeZoneInfo zone)
    {
        var at = TimeZoneInfo.ConvertTimeFromUtc(atUtc, zone);
        var now = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, zone);
        var time = $"{at.Hour}:{at.Minute:00}";
        if (at.Date == now.Date)
        {
            return time;
        }

        return at.Date == now.Date.AddDays(1) ? "明天 " + time : $"{at.Month}月{at.Day}日 " + time;
    }

    /// <summary>「还剩 1 小时 12 分」「还剩 42 分」「还剩不到 1 分钟」；null（无限期）是「无限期」。</summary>
    public static string Remaining(DateTime? endUtc, DateTime nowUtc)
    {
        if (endUtc is not { } end)
        {
            return "无限期";
        }

        var minutes = (int)Math.Ceiling((end - nowUtc).TotalMinutes);
        if (minutes <= 1)
        {
            return "还剩不到 1 分钟";
        }

        var hours = minutes / 60;
        var rest = minutes % 60;
        if (hours == 0)
        {
            return $"还剩 {rest} 分";
        }

        return rest == 0 ? $"还剩 {hours} 小时" : $"还剩 {hours} 小时 {rest} 分";
    }

    public static string Clock(int minutes) => $"{minutes / 60}:{minutes % 60:00}";

    /// <summary>
    /// 关键词后面的那截；不是这几个关键词加空格开头的给 null。中文的关键词后面不打空格也认（「保持唤醒2小时」），只打关键词本身的照旧给 null
    /// （那是内置动作那一行）。
    /// </summary>
    public static string? Query(string text)
    {
        foreach (var keyword in Keywords)
        {
            var joined = !keyword.All(char.IsAscii) && text.Length > keyword.Length;
            if (text.StartsWith(keyword + " ", StringComparison.OrdinalIgnoreCase) ||
                joined && text.StartsWith(keyword, StringComparison.OrdinalIgnoreCase))
            {
                return text[keyword.Length..].Trim();
            }
        }

        return null;
    }
}

/// <summary>
/// 启动器里「awake …」那几行（PLAN-v20 K1，mac LauncherModel.keepAwakeItems，纯函数）：手动开着时先是「停止保持唤醒」；后面什么都没写列几档时长，
/// 写了认得出的就那一行，认不出给提示。目标：awake-stop、awake-for:&lt;分钟&gt;（空的是无限期）、awake-until（Payload 是打的那截，Enter 时再算一遍）、
/// awake-hint（认不出，Enter 只响一声）。都是提示行（Kind = Prompt），右侧小字「保持唤醒」。
/// </summary>
public static class KeepAwakeLauncher
{
    public const string Prefix = "awake-";

    public static bool IsKeepAwake(string target) => target.StartsWith(Prefix, StringComparison.Ordinal);

    public static List<LauncherItem> Items(string rest, string? status, DateTime nowUtc, TimeZoneInfo zone)
    {
        var items = new List<LauncherItem>();
        if (status is not null)
        {
            items.Add(Row("stop", "停止保持唤醒", "保持唤醒中 · " + status));
        }

        LauncherItem Start(string title, int? minutes)
            => Row("for:" + (minutes?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty), "保持唤醒 " + title,
                minutes is { } value ? "到 " + KeepAwakePlan.Moment(nowUtc.AddMinutes(value), nowUtc, zone) : "直到你停止");

        switch (KeepAwakePlan.Parse(rest, nowUtc, zone))
        {
            case KeepAwakeParsed.Empty:
                items.AddRange(KeepAwakePlan.Presets.Select(preset => Start(preset.Title, preset.Minutes)));
                break;
            case KeepAwakeParsed.Indefinitely:
                items.Add(Start("无限期", null));
                break;
            case KeepAwakeParsed.Until until:
                items.Add(Row("until", "保持唤醒 " + until.Label, "到 " + KeepAwakePlan.Moment(until.AtUtc, nowUtc, zone)) with { Payload = rest });
                break;
            default:
                items.Add(Row("hint", "认不出要多久", "试试「2小时」「30分钟」「到18点」「无限期」"));
                break;
        }

        return items;
    }

    private static LauncherItem Row(string command, string title, string subtitle) => new()
    {
        Kind = LauncherKind.Prompt, Target = Prefix + command, Title = title, Subtitle = subtitle, Note = "保持唤醒",
    };
}

/// <summary>一个插件在启动器「添加…插件」里认的东西（PLAN-v20 K2）。</summary>
public sealed record PluginInfo(string Key, string Title, string Blurb, IReadOnlyList<string> Words);

/// <summary>
/// 启动器里「添加…插件」那一行（PLAN-v20 K2，mac LauncherModel.pluginOffers，纯函数）：没添加的插件里，打的字对得上名字或关键词的——
/// 整个词打全了（后面还可以接别的，「awake 2小时」；中文常不打空格，以这个词开头也算；英文的词后面不能紧跟字母、数字：打 awakening 不算），
/// 或者打了一个词的开头：英文至少 4 个字母、中文至少 2 个字（「ca」「aw」不该冒出来）。目标 plugin-&lt;键&gt;，Enter 去设置里那张卡。
/// </summary>
public static class PluginOffers
{
    public const string Prefix = "plugin-";

    public static List<LauncherItem> For(string typed, IEnumerable<PluginInfo> plugins, IReadOnlySet<string> added)
    {
        var text = LauncherMatch.Fold(typed.Trim());
        var head = new string(text.TakeWhile(character => !char.IsWhiteSpace(character)).ToArray());
        if (head.Length < 2)
        {
            return new List<LauncherItem>();
        }

        var least = head.All(char.IsAscii) ? 4 : 2;
        return plugins.Where(plugin => !added.Contains(plugin.Key))
            .Where(plugin => new[] { plugin.Title }.Concat(plugin.Words).Select(LauncherMatch.Fold).Any(word =>
                (head.StartsWith(word, StringComparison.Ordinal) &&
                 (!word.All(char.IsAscii) || head.Length == word.Length || !char.IsAsciiLetterOrDigit(head[word.Length]))) ||
                (word.StartsWith(head, StringComparison.Ordinal) && head.Length >= least)))
            .Select(plugin => new LauncherItem
            {
                Kind = LauncherKind.Prompt,
                Target = Prefix + plugin.Key,
                Title = $"添加「{plugin.Title}」插件",
                Subtitle = plugin.Blurb,
                Note = "插件",
            })
            .ToList();
    }
}
