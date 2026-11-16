// 提醒详情页的「重复」（REVIEW R101，照 mac Reminder.Schedule.Repeat）：存的格式不变，每天 / 工作日按勾了哪几天认出来。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ReminderRepeatTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    [TestMethod]
    public void WeeklyIsReadAsDailyWorkdaysOrWeekly()
    {
        Assert.AreEqual(ReminderRepeat.Daily, ReminderRepeats.Of(new ReminderSchedule { Kind = ReminderSchedule.Weekly, Days = new() { 7, 1, 2, 3, 4, 5, 6 } }));
        Assert.AreEqual(ReminderRepeat.Workdays, ReminderRepeats.Of(new ReminderSchedule { Kind = ReminderSchedule.Weekly, Days = new() { 2, 3, 4, 5, 6 } }));
        Assert.AreEqual(ReminderRepeat.Weekly, ReminderRepeats.Of(new ReminderSchedule { Kind = ReminderSchedule.Weekly, Days = new() { 2, 4 } }));
        Assert.AreEqual(ReminderRepeat.Interval, ReminderRepeats.Of(new ReminderSchedule { Kind = ReminderSchedule.Interval }));
    }

    [TestMethod]
    public void RepeatingKeepsTheStoredFormat()
    {
        // 2026-11-16 是星期一（weekday 2）
        var now = new DateTime(2026, 11, 16, 10, 0, 0, DateTimeKind.Utc);
        var daily = ReminderRepeats.Repeating(new ReminderSchedule { Kind = ReminderSchedule.Interval }, ReminderRepeat.Daily, now, Utc);
        Assert.AreEqual(ReminderSchedule.Weekly, daily.Kind);
        CollectionAssert.AreEqual(ReminderSchedule.AllDays, daily.Days.ToArray());
        var workdays = ReminderRepeats.Repeating(daily, ReminderRepeat.Workdays, now, Utc);
        CollectionAssert.AreEqual(ReminderSchedule.Workdays, workdays.Days.ToArray());
        // 从工作日换成每周：只勾今天，不然又认回工作日
        CollectionAssert.AreEqual(new[] { 2 }, ReminderRepeats.Repeating(workdays, ReminderRepeat.Weekly, now, Utc).Days.ToArray());
        // 换成一次而原来的时间已经过了：给下一个整点以后
        var once = ReminderRepeats.Repeating(workdays, ReminderRepeat.Once, now, Utc);
        Assert.AreEqual(ReminderSchedule.Once, once.Kind);
        Assert.IsTrue(ReminderTime.ToUtc(once.Date) > now);
    }

    [TestMethod]
    public void EveryTitleWritesHalfHours()
    {
        Assert.AreEqual("45 分钟", ReminderRepeats.EveryTitle(45));
        Assert.AreEqual("2 小时", ReminderRepeats.EveryTitle(120));
        Assert.AreEqual("1.5 小时", ReminderRepeats.EveryTitle(90));
    }
}
