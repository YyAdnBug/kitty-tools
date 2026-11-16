// 提醒详情页「重复」那一栏（REVIEW R101，照 mac ReminderDetail.swift 的 Reminder.Schedule.Repeat）：一次 / 每天 / 工作日 / 每周 / 每月 / 每隔一阵。
// 存的格式不变：每天、工作日、每周都是 weekly，按勾了哪几天认出来（同 mac）。纯函数配单测。
namespace KittyTools.Core;

public enum ReminderRepeat
{
    Once,
    Daily,
    Workdays,
    Weekly,
    Monthly,
    Interval,
}

public static class ReminderRepeats
{
    public static readonly ReminderRepeat[] All =
    {
        ReminderRepeat.Once, ReminderRepeat.Daily, ReminderRepeat.Workdays, ReminderRepeat.Weekly, ReminderRepeat.Monthly, ReminderRepeat.Interval,
    };

    public static string Title(ReminderRepeat repeat) => repeat switch
    {
        ReminderRepeat.Once => "一次",
        ReminderRepeat.Daily => "每天",
        ReminderRepeat.Workdays => "工作日",
        ReminderRepeat.Weekly => "每周",
        ReminderRepeat.Monthly => "每月",
        _ => "每隔一阵",
    };

    /// <summary>这条规则在「重复」里算哪一种：weekly 勾满七天是每天、勾一到五是工作日，别的是每周。</summary>
    public static ReminderRepeat Of(ReminderSchedule schedule) => schedule.Kind switch
    {
        ReminderSchedule.Once => ReminderRepeat.Once,
        ReminderSchedule.Monthly => ReminderRepeat.Monthly,
        ReminderSchedule.Interval => ReminderRepeat.Interval,
        _ => schedule.Days.Order().SequenceEqual(ReminderSchedule.AllDays) ? ReminderRepeat.Daily
            : schedule.Days.Order().SequenceEqual(ReminderSchedule.Workdays) ? ReminderRepeat.Workdays
            : ReminderRepeat.Weekly,
    };

    /// <summary>
    /// 换一种重复方式（同 mac repeating）：别的字段留着；换成一次而时间已经过了的给下一个整点；换成每周而原来是每天 / 工作日的只勾今天
    /// （不然选了「每周」又显示回「每天」）。
    /// </summary>
    public static ReminderSchedule Repeating(ReminderSchedule schedule, ReminderRepeat repeat, DateTime nowUtc, TimeZoneInfo zone)
    {
        var next = schedule.Copy();
        switch (repeat)
        {
            case ReminderRepeat.Once:
                next.Kind = ReminderSchedule.Once;
                if (ReminderTime.ToUtc(next.Date) <= nowUtc)
                {
                    next.Date = Reminders.New(nowUtc, zone).Schedule.Date;
                }

                break;
            case ReminderRepeat.Daily:
                next.Kind = ReminderSchedule.Weekly;
                next.Days = ReminderSchedule.AllDays.ToList();
                break;
            case ReminderRepeat.Workdays:
                next.Kind = ReminderSchedule.Weekly;
                next.Days = ReminderSchedule.Workdays.ToList();
                break;
            case ReminderRepeat.Weekly:
                next.Kind = ReminderSchedule.Weekly;
                if (Of(schedule) is ReminderRepeat.Daily or ReminderRepeat.Workdays)
                {
                    next.Days = new List<int> { (int)TimeZoneInfo.ConvertTimeFromUtc(nowUtc, zone).DayOfWeek + 1 };
                }

                break;
            case ReminderRepeat.Monthly:
                next.Kind = ReminderSchedule.Monthly;
                break;
            default:
                next.Kind = ReminderSchedule.Interval;
                break;
        }

        return next;
    }

    /// <summary>「每隔」的叫法（同 mac everyTitle）：不到一小时写分钟，整小时写几小时，别的写 1.5 小时这种。</summary>
    public static string EveryTitle(int minutes)
        => minutes < 60 ? $"{minutes} 分钟"
            : minutes % 60 == 0 ? $"{minutes / 60} 小时"
            : $"{(minutes / 60.0).ToString(System.Globalization.CultureInfo.InvariantCulture)} 小时";

    /// <summary>「时间」那一组的脚注（同 mac ScheduleSection.footnote）。</summary>
    public static string Footnote(string kind) => kind switch
    {
        ReminderSchedule.Once => "响过、点了「知道了」之后从列表里拿掉。",
        ReminderSchedule.Weekly => "工作日按周一到周五算，不管调休；要别的日子选「每周」自己勾。",
        ReminderSchedule.Monthly => "没有这一天的月份（比如 2 月 30 号），在当月最后一天提醒。",
        _ => "只在勾了的日子、这一段时间里提醒。锁屏、睡眠，或者 5 分钟没碰键盘鼠标，算休息过了，回来重新数。",
    };

    /// <summary>每隔一阵的「全天」：从 0:00 到 24:00。</summary>
    public static bool IsAllDay(ReminderSchedule schedule) => schedule.Time == 0 && schedule.Until == 1440;
}
