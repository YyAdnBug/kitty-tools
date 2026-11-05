// 定时提醒的一条（PLAN-v12 N6，照 mac Reminders/Reminder.swift）：标题、说明、图标（状态屏那套动画表情）、开没开、什么时候响（Schedule）、
// 怎么提醒（alert：light 轻提醒 / glow 边框 / full 全屏 / status 进入状态屏）、全屏多久自己收、声音、催促，加一个不变的 id。
// 整张列表存在设置里（Settings.Reminders，null = 三条示例，默认都关着）。读出来、导入的、同步来的都过 Sanitized。
// 种类、方式、声音存字符串，和 mac 的 JSON 一字不差（同步文件夹两边互读）：时刻是 mac 的 Date——2001-01-01 UTC 起的秒数（double），
// 同步里写成数字（Swift JSONEncoder 默认、最短往返），设置导出文件里写成 ISO 8601 字符串（mac 导出用 .iso8601，到秒）。
// 设置 › 提醒改列表的纯函数、列表行的摘要也在这里；什么时候响在 ReminderSchedule.cs，一句话建提醒在 ReminderPhrase.cs。
using System.Globalization;
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;

namespace KittyTools.Core;

/// <summary>mac 的 Date：2001-01-01 UTC 起的秒数。</summary>
public static class ReminderTime
{
    public static readonly DateTime Epoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    /// <summary>mac 的 Date.distantPast（0001-01-01）。</summary>
    public const double DistantPast = -63114076800;

    public static DateTime ToUtc(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= DistantPast)
        {
            return DateTime.MinValue;
        }

        var max = (DateTime.MaxValue - Epoch).TotalSeconds;
        return seconds >= max ? DateTime.MaxValue : Epoch.AddSeconds(seconds);
    }

    /// <summary>UTC 时刻 → 秒数（Kind 是 Local 的先换成 UTC；Unspecified 当成 UTC，DateTime.MinValue 就是很久以前）。</summary>
    public static double FromUtc(DateTime utc) => ((utc.Kind == DateTimeKind.Local ? utc.ToUniversalTime() : utc) - Epoch).TotalSeconds;

    /// <summary>同步里的写法（Swift JSONEncoder 的 Double：最短往返，整数不带 .0）。</summary>
    public static string Number(double seconds) => seconds.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>导出文件里的写法（mac .iso8601：UTC、到秒）。</summary>
    public static string Iso(double seconds) => ToUtc(seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}

public sealed class ReminderSchedule
{
    public const string Once = "once";
    public const string Weekly = "weekly";
    public const string Monthly = "monthly";
    public const string Interval = "interval";

    public static readonly string[] Kinds = { Once, Weekly, Monthly, Interval };

    /// <summary>星期几（mac Calendar 的 weekday：1 = 周日 … 7 = 周六）。</summary>
    public static readonly int[] AllDays = { 1, 2, 3, 4, 5, 6, 7 };

    /// <summary>工作日 = 周一到周五，不认调休。</summary>
    public static readonly int[] Workdays = { 2, 3, 4, 5, 6 };

    public static readonly int[] EveryChoices = { 15, 20, 30, 45, 60, 90, 120 };

    public string Kind { get; set; } = Weekly;

    /// <summary>一次：哪一刻（mac Date，ReminderTime）。</summary>
    public double Date { get; set; } = ReminderTime.DistantPast;

    /// <summary>一天里的第几分钟：每周 / 每月的时刻、间隔的时段开始。</summary>
    public int Time { get; set; } = 9 * 60;

    /// <summary>间隔的时段结束（不含；1440 = 到半夜）。</summary>
    public int Until { get; set; } = 18 * 60;

    public List<int> Days { get; set; } = AllDays.ToList();

    /// <summary>每月几号（1…31；没有这一天的月份在最后一天）。</summary>
    public int Day { get; set; } = 1;

    /// <summary>间隔几分钟。</summary>
    public int Every { get; set; } = 60;

    public ReminderSchedule Copy()
    {
        var copy = (ReminderSchedule)MemberwiseClone();
        copy.Days = Days.ToList();
        return copy;
    }

    public bool SameAs(ReminderSchedule other)
        => Kind == other.Kind && Date.Equals(other.Date) && Time == other.Time && Until == other.Until &&
           Days.SequenceEqual(other.Days) && Day == other.Day && Every == other.Every;

    /// <summary>
    /// 收拾成能用的（mac sanitized）：时刻夹进一天里，时段的结束不晚于开始就到半夜，星期去重排序、一天都没勾当七天都勾，
    /// 几号夹进 1…31，间隔夹进 5 分钟…12 小时，时刻不是有限数的换成很久以前；不认识的种类当很久以前的一次（不会响）。
    /// </summary>
    public ReminderSchedule Sanitized()
    {
        var next = Copy();
        if (!Kinds.Contains(next.Kind))
        {
            next.Kind = Once;
            next.Date = ReminderTime.DistantPast;
        }

        next.Time = Math.Clamp(Time, 0, 1439);
        next.Until = Until > next.Time && Until <= 1440 ? Until : 1440;
        var days = Days.Where(day => day is >= 1 and <= 7).Distinct().Order().ToList();
        next.Days = days.Count == 0 ? AllDays.ToList() : days;
        next.Day = Math.Clamp(Day, 1, 31);
        next.Every = Math.Clamp(Every, 5, 720);
        if (!double.IsFinite(next.Date))
        {
            next.Date = ReminderTime.DistantPast;
        }

        return next;
    }
}

public sealed class Reminder
{
    public const string Light = "light";
    public const string Glow = "glow";
    public const string Full = "full";
    public const string Status = "status";
    public const string SoundNone = "none";
    public const string SoundChime = "chime";
    public const string SoundSpeak = "speak";

    public string Id { get; set; } = string.Empty;

    public string Title { get; set; } = string.Empty;

    public string? Detail { get; set; }

    /// <summary>表情 id（StatusEmojiCatalog.Ids 里的一个）；空 = 不要图标。</summary>
    public string Symbol { get; set; } = string.Empty;

    public bool IsOn { get; set; } = true;

    public ReminderSchedule Schedule { get; set; } = new();

    public string Alert { get; set; } = Light;

    /// <summary>进入哪个状态（Alert 是 status 时；状态屏的状态 id，找不到时用排在最前面的那个）。</summary>
    public string StatusID { get; set; } = string.Empty;

    /// <summary>全屏多久自己收（秒，FullChoices 里的一个；0 = 点了才收）。</summary>
    public int FullSeconds { get; set; }

    public string Sound { get; set; } = SoundChime;

    /// <summary>mac 的提示音名（Reminders.Chimes 里的一个）：Windows 上一律放系统的通知声，名字照存（同步不丢）。</summary>
    public string Chime { get; set; } = Reminders.DefaultChime;

    /// <summary>没理会时每隔几分钟再催一次（NagChoices 里的一个；0 = 不催）。</summary>
    public int NagMinutes { get; set; }

    public Reminder Copy()
    {
        var copy = (Reminder)MemberwiseClone();
        copy.Schedule = Schedule.Copy();
        return copy;
    }

    public bool SameAs(Reminder other)
        => Id == other.Id && Title == other.Title && Detail == other.Detail && Symbol == other.Symbol && IsOn == other.IsOn &&
           Schedule.SameAs(other.Schedule) && Alert == other.Alert && StatusID == other.StatusID &&
           FullSeconds == other.FullSeconds && Sound == other.Sound && Chime == other.Chime && NagMinutes == other.NagMinutes;
}

public static class Reminders
{
    public const int MaxCount = 50;
    public const int MaxTitle = 30;
    public const int MaxDetail = 60;
    public const int MaxId = 64;
    public static readonly int[] FullChoices = { 0, 20, 60, 300 };
    public static readonly int[] NagChoices = { 0, 5, 10, 15 };

    /// <summary>「稍后」推多久（设置 › 提醒）。</summary>
    public static readonly int[] SnoozeChoices = { 5, 10, 15, 30 };

    public static readonly string[] Alerts = { Reminder.Light, Reminder.Glow, Reminder.Full, Reminder.Status };
    public static readonly string[] Sounds = { Reminder.SoundNone, Reminder.SoundChime, Reminder.SoundSpeak };

    /// <summary>mac 的提示音（/System/Library/Sounds 里的文件名）：同步、导入时认这几个名字。</summary>
    public static readonly string[] Chimes =
    {
        "Glass", "Ping", "Tink", "Pop", "Purr", "Hero", "Submarine", "Bottle", "Funk", "Frog", "Morse", "Blow", "Basso", "Sosumi",
    };

    public const string DefaultChime = "Glass";

    public static string AlertTitle(string alert) => alert switch
    {
        Reminder.Glow => "边框",
        Reminder.Full => "全屏",
        Reminder.Status => "进入状态屏",
        _ => "轻提醒",
    };

    /// <summary>详情里选中这一种时下面的一句话（Windows 的说法：轻提醒挂在屏幕底部的提示上）。</summary>
    public static string AlertExplanation(string alert) => alert switch
    {
        Reminder.Glow => "屏幕四边一圈光，鼠标点得穿，底部的提示同时挂着",
        Reminder.Full => "盖住所有屏幕，键盘鼠标照常能用",
        Reminder.Status => "到点进入一个状态，拦住键盘鼠标",
        _ => "屏幕底部的提示挂着，点了「知道了」或「稍后」才收",
    };

    public static string SoundTitle(string sound) => sound switch
    {
        Reminder.SoundNone => "无",
        Reminder.SoundSpeak => "朗读标题",
        _ => "提示音",
    };

    /// <summary>示例：默认都关着，打开才响。id 固定，「恢复示例提醒」按它认。</summary>
    public static IReadOnlyList<Reminder> Examples() => new[]
    {
        new Reminder
        {
            Id = "water", Title = "喝水", Symbol = "hot-beverage", IsOn = false,
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Days = ReminderSchedule.Workdays.ToList(), Every = 60 },
        },
        new Reminder
        {
            Id = "eyes", Title = "休息眼睛", Detail = "看看 6 米外的地方，20 秒", Symbol = "sleeping-face", IsOn = false,
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 0, Until = 1440, Every = 20 },
            Alert = Reminder.Full, FullSeconds = 20,
        },
        new Reminder
        {
            Id = "walk", Title = "起来走走", Symbol = "waving-hand", IsOn = false,
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Days = ReminderSchedule.Workdays.ToList(), Every = 45 },
            Alert = Reminder.Glow,
        },
    };

    /// <summary>
    /// 收拾一张列表（mac sanitized）：标题去首尾空白、换行当空格，空的整条丢掉、超过 30 个字截断；说明同样、最多 60 个字、空了就是没有；
    /// 图标不在表情清单里的置空；时间规则收拾一遍；方式、声音认不出的换成默认，几个选项不是可选值的换成默认；
    /// id 为空、太长、重复的丢掉（留先出现的）；最多 50 条。结果可以是空的（用户删光了）。不改传进来的。
    /// </summary>
    public static List<Reminder> Sanitized(IEnumerable<Reminder?> reminders)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<Reminder>();
        foreach (var source in reminders)
        {
            if (source is null)
            {
                continue;
            }

            var reminder = source.Copy();
            reminder.Title = Prefix(StatusPresets.OneLine(reminder.Title), MaxTitle);
            if (reminder.Title.Length == 0 || string.IsNullOrEmpty(reminder.Id) || reminder.Id.Length > MaxId || !seen.Add(reminder.Id))
            {
                continue;
            }

            var detail = Prefix(StatusPresets.OneLine(reminder.Detail), MaxDetail);
            reminder.Detail = detail.Length == 0 ? null : detail;
            if (!StatusEmojiCatalog.Ids.Contains(reminder.Symbol))
            {
                reminder.Symbol = string.Empty;
            }

            reminder.Schedule = (reminder.Schedule ?? new ReminderSchedule()).Sanitized();
            reminder.StatusID ??= string.Empty;
            if (reminder.StatusID.Length > MaxId)
            {
                reminder.StatusID = string.Empty;
            }

            if (!Alerts.Contains(reminder.Alert))
            {
                reminder.Alert = Reminder.Light;
            }

            if (!Sounds.Contains(reminder.Sound))
            {
                reminder.Sound = Reminder.SoundChime;
            }

            if (!FullChoices.Contains(reminder.FullSeconds))
            {
                reminder.FullSeconds = 0;
            }

            if (!Chimes.Contains(reminder.Chime))
            {
                reminder.Chime = DefaultChime;
            }

            if (!NagChoices.Contains(reminder.NagMinutes))
            {
                reminder.NagMinutes = 0;
            }

            result.Add(reminder);
            if (result.Count == MaxCount)
            {
                break;
            }
        }

        return result;
    }

    /// <summary>设置里存的 → 列表：没存过（null）是示例；存过的照收拾过的用（可以是空的）。</summary>
    public static List<Reminder> Load(IEnumerable<Reminder?>? stored)
        => stored is null ? Examples().Select(reminder => reminder.Copy()).ToList() : Sanitized(stored);

    /// <summary>
    /// 导入时并进本机的列表（mac merged）：按 id 更新和添加、顺序先照文件里的，本机独有的接在后面（不删）；超过上限时少加文件里新的，
    /// 不挤掉本机的；文件里本机没有、时间已经过了的一次性提醒不加（旧备份里早就点过「知道了」的）。
    /// </summary>
    public static List<Reminder> Merged(IReadOnlyList<Reminder> incoming, IReadOnlyList<Reminder> local, DateTime nowUtc)
    {
        var now = ReminderTime.FromUtc(nowUtc);
        var localIds = local.Select(reminder => reminder.Id).ToHashSet(StringComparer.Ordinal);
        var fresh = incoming.Where(reminder =>
            !localIds.Contains(reminder.Id) && !(reminder.Schedule.Kind == ReminderSchedule.Once && reminder.Schedule.Date <= now));
        var room = Math.Max(0, MaxCount - Sanitized(local).Count);
        var added = Sanitized(fresh).Take(room).Select(reminder => reminder.Id).ToHashSet(StringComparer.Ordinal);
        var kept = incoming.Where(reminder => localIds.Contains(reminder.Id) || added.Contains(reminder.Id));
        return Sanitized(kept.Concat(local.Where(mine => incoming.All(item => item.Id != mine.Id))));
    }

    /// <summary>新加的一条：标题「新提醒」、一次、下一个整点（离现在不到 10 分钟就再下一个）、轻提醒、提示音。</summary>
    public static Reminder New(DateTime nowUtc, TimeZoneInfo zone, string? id = null)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(nowUtc.AddMinutes(10), zone);
        var hour = new DateTime(local.Year, local.Month, local.Day, local.Hour, 0, 0, DateTimeKind.Unspecified).AddHours(1);
        return new Reminder
        {
            Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
            Title = "新提醒",
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(ReminderMath.LocalToUtc(hour, zone)) },
        };
    }

    public static List<Reminder> Adding(Reminder reminder, IReadOnlyList<Reminder> list)
        => list.Count < MaxCount ? list.Append(reminder).ToList() : list.ToList();

    public static List<Reminder> Removing(string id, IReadOnlyList<Reminder> list)
        => list.Where(reminder => reminder.Id != id).ToList();

    public static List<Reminder> Moving(string id, int offset, IReadOnlyList<Reminder> list)
    {
        var result = list.ToList();
        var index = result.FindIndex(reminder => reminder.Id == id);
        if (index < 0 || index + offset < 0 || index + offset >= result.Count)
        {
            return result;
        }

        (result[index], result[index + offset]) = (result[index + offset], result[index]);
        return result;
    }

    public static List<Reminder> MissingExamples(IReadOnlyList<Reminder> list)
        => Examples().Where(example => list.All(item => item.Id != example.Id)).ToList();

    public static List<Reminder> RestoringExamples(IReadOnlyList<Reminder> list)
        => list.Concat(MissingExamples(list)).Take(MaxCount).ToList();

    /// <summary>删之前要不要确认：和示例一模一样的不用（开没开不算），自己加的、改过的要。</summary>
    public static bool IsPristine(Reminder reminder)
    {
        var off = reminder.Copy();
        off.IsOn = false;
        return Examples().Any(example => example.SameAs(off));
    }

    /// <summary>详情改了一条：按 id 换掉。标题只有空白时留着原来的标题。</summary>
    public static List<Reminder> Updating(IReadOnlyList<Reminder> list, Reminder draft)
        => list.Select(stored =>
        {
            if (stored.Id != draft.Id)
            {
                return stored;
            }

            var next = draft.Copy();
            if (StatusPresets.OneLine(draft.Title).Length == 0)
            {
                next.Title = stored.Title;
            }

            return next;
        }).ToList();

    /// <summary>详情里正在改的这一条有什么问题（橙字；null = 没问题）。不拦着改：存进去的是收拾过的。</summary>
    public static string? Problem(Reminder draft, DateTime nowUtc)
    {
        var title = StatusPresets.OneLine(draft.Title);
        if (title.Length == 0)
        {
            return "还没填标题";
        }

        if (StatusPresets.Length(title) > MaxTitle)
        {
            return $"标题最多 {MaxTitle} 个字，后面的不会保存";
        }

        if (StatusPresets.Length(StatusPresets.OneLine(draft.Detail)) > MaxDetail)
        {
            return $"说明最多 {MaxDetail} 个字，后面的不会保存";
        }

        if (draft.Schedule.Kind == ReminderSchedule.Once && draft.Schedule.Date <= ReminderTime.FromUtc(nowUtc))
        {
            return "这个时间已经过了，不会再提醒";
        }

        return draft.Schedule.Kind == ReminderSchedule.Interval && draft.Schedule.Until - draft.Schedule.Time < draft.Schedule.Every
            ? "这段时间比间隔还短，可能一次都不提醒"
            : null;
    }

    // ---- 摘要

    /// <summary>列表行的一行小字：什么时候 · 怎么提醒（「工作日 9:00–18:00 每 60 分钟 · 轻提醒」「明天 9:00 · 全屏 20 秒」）。</summary>
    public static string Summary(Reminder reminder, DateTime nowUtc, TimeZoneInfo zone, string? statusTitle = null)
    {
        var how = reminder.Alert switch
        {
            Reminder.Full => reminder.FullSeconds == 0 ? AlertTitle(reminder.Alert) : "全屏 " + DurationTitle(reminder.FullSeconds),
            Reminder.Status => statusTitle is null ? AlertTitle(reminder.Alert) : $"进入「{statusTitle}」",
            _ => AlertTitle(reminder.Alert),
        };
        return ScheduleSummary(reminder.Schedule, nowUtc, zone) + " · " + how;
    }

    /// <summary>「20 秒」「1 分钟」「5 分钟」。</summary>
    public static string DurationTitle(int seconds) => seconds < 60 ? $"{seconds} 秒" : $"{seconds / 60} 分钟";

    /// <summary>一天里的第几分钟 → 「9:00」「18:30」「24:00」。</summary>
    public static string Clock(int minutes) => $"{minutes / 60}:{minutes % 60:00}";

    /// <summary>「每天」「工作日」「周末」「每周一、三、五」（周一排在前面、周日排最后）。</summary>
    public static string DaysTitle(IReadOnlyList<int> days)
    {
        if (days.SequenceEqual(ReminderSchedule.AllDays))
        {
            return "每天";
        }

        if (days.SequenceEqual(ReminderSchedule.Workdays))
        {
            return "工作日";
        }

        if (days.SequenceEqual(new[] { 1, 7 }))
        {
            return "周末";
        }

        string[] names = { "日", "一", "二", "三", "四", "五", "六" };
        var ordered = days.Where(day => day != 1).Concat(days.Contains(1) ? new[] { 1 } : Array.Empty<int>());
        return "每周" + string.Join("、", ordered.Select(day => names[day - 1]));
    }

    /// <summary>摘要里「什么时候」那一段。一次的写「今天 9:00」「明天 9:00」「11月5日 9:00」（不是今年的带年份）。</summary>
    public static string ScheduleSummary(ReminderSchedule schedule, DateTime nowUtc, TimeZoneInfo zone)
    {
        switch (schedule.Kind)
        {
            case ReminderSchedule.Once:
            {
                var date = ReminderMath.Local(ReminderTime.ToUtc(schedule.Date), zone);
                var now = ReminderMath.Local(nowUtc, zone);
                var time = date.ToString("H:mm", CultureInfo.InvariantCulture);
                if (date.Date == now.Date)
                {
                    return "今天 " + time;
                }

                if (date.Date == now.Date.AddDays(1))
                {
                    return "明天 " + time;
                }

                var day = $"{date.Month}月{date.Day}日";
                return (date.Year == now.Year ? day : $"{date.Year}年{day}") + " " + time;
            }

            case ReminderSchedule.Weekly:
                return DaysTitle(schedule.Days) + " " + Clock(schedule.Time);
            case ReminderSchedule.Monthly:
                return $"每月 {schedule.Day} 号 " + Clock(schedule.Time);
            default:
            {
                var span = schedule.Time == 0 && schedule.Until == 1440 ? string.Empty : Clock(schedule.Time) + "–" + Clock(schedule.Until) + " ";
                var when = schedule.Days.SequenceEqual(ReminderSchedule.AllDays) ? string.Empty : DaysTitle(schedule.Days) + " ";
                return when + span + $"每 {schedule.Every} 分钟";
            }
        }
    }

    // ---- JSON

    /// <summary>
    /// 同步里的一条（mac SyncRecords.encoder：键排好序、不转义斜杠和非 ASCII，时刻是数字），也是 decodeExact 的比较基准。
    /// 没有说明时不写 detail（Swift 的 Codable 不写 nil）。
    /// </summary>
    public static string Canonical(Reminder reminder)
    {
        var builder = new StringBuilder(256);
        builder.Append("{\"alert\":");
        CanonicalJson.WriteString(reminder.Alert, builder);
        builder.Append(",\"chime\":");
        CanonicalJson.WriteString(reminder.Chime, builder);
        if (reminder.Detail is { } detail)
        {
            builder.Append(",\"detail\":");
            CanonicalJson.WriteString(detail, builder);
        }

        builder.Append(",\"fullSeconds\":").Append(reminder.FullSeconds.ToString(CultureInfo.InvariantCulture));
        builder.Append(",\"id\":");
        CanonicalJson.WriteString(reminder.Id, builder);
        builder.Append(",\"isOn\":").Append(reminder.IsOn ? "true" : "false");
        builder.Append(",\"nagMinutes\":").Append(reminder.NagMinutes.ToString(CultureInfo.InvariantCulture));
        builder.Append(",\"schedule\":").Append(CanonicalSchedule(reminder.Schedule));
        builder.Append(",\"sound\":");
        CanonicalJson.WriteString(reminder.Sound, builder);
        builder.Append(",\"statusID\":");
        CanonicalJson.WriteString(reminder.StatusID, builder);
        builder.Append(",\"symbol\":");
        CanonicalJson.WriteString(reminder.Symbol, builder);
        builder.Append(",\"title\":");
        CanonicalJson.WriteString(reminder.Title, builder);
        builder.Append('}');
        return builder.ToString();
    }

    public static string CanonicalSchedule(ReminderSchedule schedule)
        => $"{{\"date\":{ReminderTime.Number(schedule.Date)},\"day\":{schedule.Day.ToString(CultureInfo.InvariantCulture)}," +
           $"\"days\":[{string.Join(',', schedule.Days.Select(day => day.ToString(CultureInfo.InvariantCulture)))}]," +
           $"\"every\":{schedule.Every.ToString(CultureInfo.InvariantCulture)},\"kind\":\"{schedule.Kind}\"," +
           $"\"time\":{schedule.Time.ToString(CultureInfo.InvariantCulture)},\"until\":{schedule.Until.ToString(CultureInfo.InvariantCulture)}}}";

    /// <summary>设置导出文件里的一条（键名同 mac，时刻写 ISO 8601 字符串；键的顺序无所谓）。</summary>
    public static void WriteArchive(Utf8JsonWriter writer, Reminder reminder)
    {
        writer.WriteStartObject();
        writer.WriteString("id", reminder.Id);
        writer.WriteString("title", reminder.Title);
        if (reminder.Detail is { } detail)
        {
            writer.WriteString("detail", detail);
        }

        writer.WriteString("symbol", reminder.Symbol);
        writer.WriteBoolean("isOn", reminder.IsOn);
        writer.WriteStartObject("schedule");
        writer.WriteString("kind", reminder.Schedule.Kind);
        writer.WriteString("date", ReminderTime.Iso(reminder.Schedule.Date));
        writer.WriteNumber("time", reminder.Schedule.Time);
        writer.WriteNumber("until", reminder.Schedule.Until);
        writer.WriteStartArray("days");
        foreach (var day in reminder.Schedule.Days)
        {
            writer.WriteNumberValue(day);
        }

        writer.WriteEndArray();
        writer.WriteNumber("day", reminder.Schedule.Day);
        writer.WriteNumber("every", reminder.Schedule.Every);
        writer.WriteEndObject();
        writer.WriteString("alert", reminder.Alert);
        writer.WriteString("statusID", reminder.StatusID);
        writer.WriteNumber("fullSeconds", reminder.FullSeconds);
        writer.WriteString("sound", reminder.Sound);
        writer.WriteString("chime", reminder.Chime);
        writer.WriteNumber("nagMinutes", reminder.NagMinutes);
        writer.WriteEndObject();
    }

    /// <summary>
    /// 读一条（mac 的逐个字段兜底：只有 id 和标题是必须的，别的缺了、类型不对就用默认值；种类不认识的当很久以前的一次）。
    /// 时刻认数字（同步）和 ISO 8601 字符串（导出文件）。之后再过 Sanitized。
    /// </summary>
    public static Reminder? Read(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object || Text(element, "id") is not { } id || Text(element, "title") is not { } title)
        {
            return null;
        }

        var reminder = new Reminder
        {
            Id = id,
            Title = title,
            Detail = Text(element, "detail"),
            Symbol = Text(element, "symbol") ?? string.Empty,
            IsOn = element.TryGetProperty("isOn", out var on) && on.ValueKind is JsonValueKind.True,
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.DistantPast },
            Alert = Text(element, "alert") is { } alert && Alerts.Contains(alert) ? alert : Reminder.Light,
            StatusID = Text(element, "statusID") ?? string.Empty,
            FullSeconds = Integer(element, "fullSeconds") ?? 0,
            Sound = Text(element, "sound") is { } sound && Sounds.Contains(sound) ? sound : Reminder.SoundChime,
            Chime = Text(element, "chime") ?? DefaultChime,
            NagMinutes = Integer(element, "nagMinutes") ?? 0,
        };
        if (element.TryGetProperty("schedule", out var schedule) && schedule.ValueKind == JsonValueKind.Object)
        {
            var fallback = new ReminderSchedule();
            var next = new ReminderSchedule
            {
                Time = Integer(schedule, "time") ?? fallback.Time,
                Until = Integer(schedule, "until") ?? fallback.Until,
                Days = schedule.TryGetProperty("days", out var days) && days.ValueKind == JsonValueKind.Array &&
                       days.EnumerateArray().All(day => day.ValueKind == JsonValueKind.Number && day.TryGetInt32(out _))
                    ? days.EnumerateArray().Select(day => day.GetInt32()).ToList()
                    : fallback.Days,
                Day = Integer(schedule, "day") ?? fallback.Day,
                Every = Integer(schedule, "every") ?? fallback.Every,
            };
            if (Text(schedule, "kind") is { } kind && ReminderSchedule.Kinds.Contains(kind))
            {
                next.Kind = kind;
                next.Date = Moment(schedule) ?? fallback.Date;
            }
            else
            {
                next.Kind = ReminderSchedule.Once;
                next.Date = ReminderTime.DistantPast;
            }

            reminder.Schedule = next;
        }

        return reminder;
    }

    /// <summary>一组：一条解不出（缺 id、标题）只丢这一条，不连累整张；不是数组给 null。</summary>
    public static List<Reminder>? ReadList(JsonElement element)
        => element.ValueKind == JsonValueKind.Array
            ? element.EnumerateArray().Select(Read).Where(reminder => reminder is not null).Select(reminder => reminder!).ToList()
            : null;

    private static double? Moment(JsonElement schedule)
    {
        if (!schedule.TryGetProperty("date", out var date))
        {
            return null;
        }

        if (date.ValueKind == JsonValueKind.Number && date.TryGetDouble(out var seconds))
        {
            return seconds;
        }

        return date.ValueKind == JsonValueKind.String &&
               DateTime.TryParse(date.GetString(), CultureInfo.InvariantCulture,
                   DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var parsed)
            ? ReminderTime.FromUtc(DateTime.SpecifyKind(parsed, DateTimeKind.Utc))
            : null;
    }

    private static string? Text(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? Integer(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)
            ? number
            : null;

    private static string Prefix(string text, int count)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }
}
