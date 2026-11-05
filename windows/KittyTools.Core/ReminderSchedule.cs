// 提醒什么时候响（PLAN-v12 N6，照 mac Reminders/ReminderSchedule.swift），全是纯函数，单测锁住（ReminderTests）：
// - 一次 / 每周 / 每月：严格晚于某一刻的下一次（按当地钟表时间算：换了时区还是当地的 9 点；夏令时跳过的那个钟点取它后面最近的有效时刻，
//   重复的钟点取第一次）。
// - 间隔：从「锚点」起数 every 分钟，那一刻落在勾了的那天的时段里才算；落在时段外就是下一个时段开始再数 every 分钟。
//   锚点由 ReminderCenter 管：启动、醒来、解锁、离开电脑回来、点了「知道了」时设成那一刻。
// - Check：此刻哪几条该响、哪几条算错过（晚了超过 5 分钟）、下一次最早什么时候要再看。间隔类晚了也不补；正挂着的不重复响；
//   锁着屏、在状态屏里、暂停着（held）时一条都不响，等回来再看。一次 / 每周 / 每月都只算「上次处理到的那一刻」之后的。
// 时刻都是 UTC 的 DateTime，当地的日历用传进来的 TimeZoneInfo（单测用固定时区）。
namespace KittyTools.Core;

public static class ReminderMath
{
    /// <summary>
    /// 当地的墙上时刻 → UTC（同 mac bySettingHour 的 .nextTime / .first）：夏令时跳过的钟点取跳过之后的第一刻（2:30 → 3:00），
    /// 重复的钟点取第一次（夏令时那次，偏移大的那个；ConvertTimeToUtc 取的是标准时间那次，晚一小时）。时刻都是整分钟，逐分钟往后挪一定落在跳变那一刻。
    /// </summary>
    public static DateTime LocalToUtc(DateTime local, TimeZoneInfo zone)
    {
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(local))
        {
            local = local.AddMinutes(1);
        }

        return zone.IsAmbiguousTime(local)
            ? DateTime.SpecifyKind(local - zone.GetAmbiguousTimeOffsets(local).Max(), DateTimeKind.Utc)
            : TimeZoneInfo.ConvertTimeToUtc(local, zone);
    }

    /// <summary>UTC → 当地（很久以前 / 很久以后的夹住，不抛）。</summary>
    public static DateTime Local(DateTime utc, TimeZoneInfo zone)
    {
        try
        {
            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone);
        }
        catch (ArgumentOutOfRangeException)
        {
            return DateTime.SpecifyKind(utc, DateTimeKind.Unspecified);
        }
    }

    /// <summary>mac Calendar 的 weekday：1 = 周日 … 7 = 周六。</summary>
    public static int Weekday(DateTime local) => (int)local.DayOfWeek + 1;

    /// <summary>某一天（当地日期）的第几分钟；1440 = 第二天零点。</summary>
    public static DateTime Moment(int minutes, DateTime day, TimeZoneInfo zone)
        => LocalToUtc(day.Date.AddMinutes(Math.Clamp(minutes, 0, 1440)), zone);

    /// <summary>严格晚于 after 的下一次（一次 / 每周 / 每月）；间隔类走 NextFromAnchor，这里给 null。</summary>
    public static DateTime? NextAfter(ReminderSchedule schedule, DateTime after, TimeZoneInfo zone)
    {
        switch (schedule.Kind)
        {
            case ReminderSchedule.Once:
            {
                var date = ReminderTime.ToUtc(schedule.Date);
                return date > after ? date : null;
            }

            case ReminderSchedule.Weekly:
            {
                var start = Local(after, zone).Date;
                // 今天 + 后面 7 天：今天的时刻已经过了时，下周的同一天也在里面。
                for (var offset = 0; offset <= 7; offset++)
                {
                    var day = start.AddDays(offset);
                    if (!schedule.Days.Contains(Weekday(day)))
                    {
                        continue;
                    }

                    var at = Moment(schedule.Time, day, zone);
                    if (at > after)
                    {
                        return at;
                    }
                }

                return null;
            }

            case ReminderSchedule.Monthly:
            {
                var local = Local(after, zone);
                var month = new DateTime(local.Year, local.Month, 1);
                for (var offset = 0; offset <= 12; offset++)
                {
                    var first = month.AddMonths(offset);
                    var count = DateTime.DaysInMonth(first.Year, first.Month);
                    var at = Moment(schedule.Time, first.AddDays(Math.Min(schedule.Day, count) - 1), zone);
                    if (at > after)
                    {
                        return at;
                    }
                }

                return null;
            }

            default:
                return null;
        }
    }

    /// <summary>
    /// 间隔：从锚点数 every 分钟，那一刻落在某个时段里就是它；落在时段外，就是那之后第一个时段的开始 + every
    /// （时段比 every 还短、一次都响不了的跳过）。
    /// </summary>
    public static DateTime? NextFromAnchor(ReminderSchedule schedule, DateTime anchor, TimeZoneInfo zone)
    {
        if (schedule.Kind != ReminderSchedule.Interval)
        {
            return null;
        }

        var candidate = anchor.AddMinutes(schedule.Every);
        if (WindowContaining(schedule, candidate, zone) is not null)
        {
            return candidate;
        }

        var start = Local(candidate, zone).Date;
        for (var offset = 0; offset <= 8; offset++)
        {
            if (Window(schedule, start.AddDays(offset), zone) is not { } window || window.Start <= candidate)
            {
                continue;
            }

            var at = window.Start.AddMinutes(schedule.Every);
            if (at < window.End)
            {
                return at;
            }
        }

        return null;
    }

    /// <summary>date 落在哪个时段里（间隔类）：当天勾了、而且在 time…until 之间。</summary>
    public static (DateTime Start, DateTime End)? WindowContaining(ReminderSchedule schedule, DateTime date, TimeZoneInfo zone)
        => Window(schedule, Local(date, zone).Date, zone) is { } window && window.Start <= date && date < window.End ? window : null;

    /// <summary>某一天（当地日期）的时段；那天没勾给 null。</summary>
    private static (DateTime Start, DateTime End)? Window(ReminderSchedule schedule, DateTime day, TimeZoneInfo zone)
    {
        if (!schedule.Days.Contains(Weekday(day)))
        {
            return null;
        }

        var start = Moment(schedule.Time, day, zone);
        var end = Moment(schedule.Until, day, zone);
        return start < end ? (start, end) : null;
    }
}

/// <summary>每条开着的提醒已经处理到哪一刻，连着记下当时的时间规则（改了规则就从改的那一刻重新算）。时刻是 mac Date 秒数。</summary>
public sealed class ReminderMark
{
    public double At { get; set; }

    public ReminderSchedule Schedule { get; set; } = new();
}

/// <summary>这台电脑自己的提醒状态（Settings.RemindersState，不导出、不同步）：每条处理到哪一刻、推到几点、暂停到几点。</summary>
public sealed class ReminderState
{
    public Dictionary<string, ReminderMark> Marks { get; set; } = new(StringComparer.Ordinal);

    /// <summary>点了「稍后」的：推到几点（到点照常响）。</summary>
    public Dictionary<string, double> Snoozed { get; set; } = new(StringComparer.Ordinal);

    /// <summary>「暂停全部提醒」到几点：这之前一条都不响，之后照「错过的」规矩补。</summary>
    public double? PausedUntil { get; set; }

    public ReminderState Copy() => new()
    {
        Marks = Marks.ToDictionary(pair => pair.Key, pair => new ReminderMark { At = pair.Value.At, Schedule = pair.Value.Schedule.Copy() }),
        Snoozed = new Dictionary<string, double>(Snoozed, StringComparer.Ordinal),
        PausedUntil = PausedUntil,
    };

    public bool SameAs(ReminderState other)
        => PausedUntil.Equals(other.PausedUntil) && Snoozed.Count == other.Snoozed.Count &&
           Snoozed.All(pair => other.Snoozed.TryGetValue(pair.Key, out var value) && value.Equals(pair.Value)) &&
           Marks.Count == other.Marks.Count &&
           Marks.All(pair => other.Marks.TryGetValue(pair.Key, out var mark) && mark.At.Equals(pair.Value.At) &&
                             mark.Schedule.SameAs(pair.Value.Schedule));

    /// <summary>系统时间往回调过：记在「将来」的处理时刻收回到现在、推到的时刻最多再推 maxSnooze 秒；暂停最长到明天。</summary>
    public ReminderState PulledBack(DateTime nowUtc, double maxSnooze)
    {
        var now = ReminderTime.FromUtc(nowUtc);
        var next = Copy();
        foreach (var mark in next.Marks.Values.Where(mark => mark.At > now))
        {
            mark.At = now;
        }

        foreach (var id in next.Snoozed.Keys.ToList().Where(id => next.Snoozed[id] > now + maxSnooze))
        {
            next.Snoozed[id] = now + maxSnooze;
        }

        if (next.PausedUntil is { } paused && paused > now + 86_400)
        {
            next.PausedUntil = now + 86_400;
        }

        return next;
    }
}

public static class ReminderCheck
{
    /// <summary>晚了多久以内照常响；再晚算错过、合成一条告诉你。</summary>
    public static readonly TimeSpan LateLimit = TimeSpan.FromMinutes(5);

    public sealed class Result
    {
        public List<string> Fire { get; } = new();

        public List<string> Missed { get; } = new();

        public DateTime? Next { get; set; }
    }

    /// <summary>每条该什么时候响：推过的按推到的时刻；间隔按锚点；一次 / 每周 / 每月按上一次处理到的那一刻往后算。</summary>
    public static DateTime? Due(Reminder reminder, ReminderState state, IReadOnlyDictionary<string, DateTime> anchors, TimeZoneInfo zone)
    {
        if (state.Snoozed.TryGetValue(reminder.Id, out var snoozed))
        {
            return ReminderTime.ToUtc(snoozed);
        }

        if (reminder.Schedule.Kind == ReminderSchedule.Interval)
        {
            return anchors.TryGetValue(reminder.Id, out var anchor) ? ReminderMath.NextFromAnchor(reminder.Schedule, anchor, zone) : null;
        }

        return state.Marks.TryGetValue(reminder.Id, out var mark)
            ? ReminderMath.NextAfter(reminder.Schedule, ReminderTime.ToUtc(mark.At), zone)
            : null;
    }

    /// <summary>
    /// 此刻的检查。关着的、正挂着的不算；held（锁着屏、在状态屏里、暂停着）时一条都不响也不算错过；away（5 分钟没碰键盘鼠标）时
    /// 间隔类（没推过的）不响也不等，回来重设锚点再数；间隔类晚了不算错过。
    /// </summary>
    public static Result Check(
        IReadOnlyList<Reminder> list, ReminderState state, IReadOnlyDictionary<string, DateTime> anchors, IReadOnlySet<string> showing,
        DateTime nowUtc, TimeZoneInfo zone, bool held = false, bool away = false)
    {
        var result = new Result();
        foreach (var reminder in list.Where(reminder => reminder.IsOn && !showing.Contains(reminder.Id)))
        {
            var isInterval = reminder.Schedule.Kind == ReminderSchedule.Interval;
            if (isInterval && away && !state.Snoozed.ContainsKey(reminder.Id))
            {
                continue;
            }

            if (Due(reminder, state, anchors, zone) is not { } due)
            {
                continue;
            }

            if (due > nowUtc)
            {
                result.Next = result.Next is { } next && next < due ? next : due;
            }
            else if (held)
            {
                continue;
            }
            else if (nowUtc - due <= LateLimit || isInterval)
            {
                result.Fire.Add(reminder.Id);
            }
            else
            {
                result.Missed.Add(reminder.Id);
            }
        }

        return result;
    }

    /// <summary>
    /// 列表变了之后把状态跟上：开着的提醒没有记录（新加的、刚打开的）或者时间规则改了的，从 now 重新算、推到的时刻作废；
    /// 关掉的、删掉的连记录带推到的时刻一起去掉。
    /// </summary>
    public static ReminderState Reconciled(ReminderState state, IReadOnlyList<Reminder> list, DateTime nowUtc)
    {
        var next = new ReminderState { PausedUntil = state.PausedUntil };
        foreach (var reminder in list.Where(reminder => reminder.IsOn))
        {
            if (state.Marks.TryGetValue(reminder.Id, out var mark) && mark.Schedule.SameAs(reminder.Schedule))
            {
                next.Marks[reminder.Id] = new ReminderMark { At = mark.At, Schedule = mark.Schedule.Copy() };
                if (state.Snoozed.TryGetValue(reminder.Id, out var snoozed))
                {
                    next.Snoozed[reminder.Id] = snoozed;
                }
            }
            else
            {
                next.Marks[reminder.Id] = new ReminderMark { At = ReminderTime.FromUtc(nowUtc), Schedule = reminder.Schedule.Copy() };
            }
        }

        return next;
    }

    /// <summary>时间规则变了的（新旧列表里同一个 id、规则不一样）：正挂着的要撤下来。</summary>
    public static HashSet<string> Rescheduled(IReadOnlyList<Reminder> old, IReadOnlyList<Reminder> current)
    {
        var before = new Dictionary<string, ReminderSchedule>(StringComparer.Ordinal);
        foreach (var reminder in old)
        {
            before.TryAdd(reminder.Id, reminder.Schedule);
        }

        return current.Where(reminder => before.TryGetValue(reminder.Id, out var schedule) && !schedule.SameAs(reminder.Schedule))
            .Select(reminder => reminder.Id)
            .ToHashSet(StringComparer.Ordinal);
    }
}

/// <summary>到点之后怎么摆（mac ReminderCenter 里的静态函数）。</summary>
public static class ReminderAlerts
{
    /// <summary>几条一起到点时用哪种方式：最显眼的那条；正在录屏录音时一律轻提醒。</summary>
    public static string Alert(IEnumerable<Reminder> reminders, bool recording)
        => recording ? Reminder.Light : reminders.Select(reminder => reminder.Alert).OrderByDescending(Rank).FirstOrDefault() ?? Reminder.Light;

    public static int Rank(string alert) => alert switch
    {
        Reminder.Glow => 1,
        Reminder.Full => 2,
        Reminder.Status => 3,
        _ => 0,
    };

    /// <summary>全屏多久自己收：有一条要「点了才收」就点了才收，否则取最长的；不是全屏的那几条（含进不去状态屏、退成全屏的）不算。</summary>
    public static int FullSeconds(IEnumerable<Reminder> reminders)
    {
        var seconds = reminders.Where(reminder => reminder.Alert == Reminder.Full).Select(reminder => reminder.FullSeconds).ToList();
        return seconds.Count == 0 || seconds.Contains(0) ? 0 : seconds.Max();
    }

    /// <summary>全屏上「稍后」的几个选项：设置里定的那个 + 15 分钟 + 1 小时，去重、从小到大。</summary>
    public static IReadOnlyList<int> SnoozeChoices(int minutes) => new[] { minutes, 15, 60 }.Distinct().Order().ToList();

    /// <summary>
    /// 提示上那一条写什么：到点的标题连在一起（只有一条时带它的说明），错过的写在详情里；只有错过的时
    /// 「错过了提醒：喝水」/「错过了 3 个提醒」+ 是哪几个。都没有给 null。
    /// </summary>
    public static (string Title, string? Detail)? Notice(IReadOnlyList<Reminder> fired, IReadOnlyList<Reminder> missed)
    {
        var lostTitles = string.Join("、", missed.Select(reminder => reminder.Title));
        if (fired.Count == 0)
        {
            if (missed.Count == 0)
            {
                return null;
            }

            return missed.Count == 1 ? ($"错过了提醒：{missed[0].Title}", missed[0].Detail) : ($"错过了 {missed.Count} 个提醒", lostTitles);
        }

        var detail = fired.Count == 1 ? fired[0].Detail : null;
        if (missed.Count > 0)
        {
            var line = "还错过了：" + lostTitles;
            detail = detail is null ? line : detail + "；" + line;
        }

        return (string.Join(" · ", fired.Select(reminder => reminder.Title)), detail);
    }
}

/// <summary>
/// 提醒边框的渐变和呼吸（PLAN-v12 第 7 批，照 mac ReminderGlow）：贴着屏幕边那头 0.85、往里 Depth 淡到 0（线性，同 CAGradientLayer）；
/// 出现先淡入 FadeIn 秒，之后透明度在 1 和 0.35 之间来回（单程 1.2 s、缓入缓出），减弱动态效果时只亮着。
/// </summary>
public static class ReminderGlowCurve
{
    public const double Depth = 28;
    public const double EdgeAlpha = 0.85;
    public const double Breath = 1.2;
    public const double Dimmest = 0.35;

    /// <summary>离屏幕边 distance 个像素（像素中心）的那一行的不透明度；depth 是这条的厚度（像素）。</summary>
    public static double Alpha(int distance, int depth)
        => depth <= 0 ? 0 : EdgeAlpha * Math.Clamp(1 - (distance + 0.5) / depth, 0, 1);

    /// <summary>出现后 seconds 秒时整条的透明度（0–1）。</summary>
    public static double Opacity(double seconds, bool reduced)
    {
        var fade = MotionCurves.FadeInSeconds;
        if (seconds < fade)
        {
            return Math.Max(0, seconds / fade);
        }

        if (reduced)
        {
            return 1;
        }

        var phase = (seconds - fade) / Breath % 2;
        var progress = phase <= 1 ? phase : 2 - phase;
        var eased = (1 - Math.Cos(Math.PI * progress)) / 2;
        return 1 - (1 - Dimmest) * eased;
    }
}
