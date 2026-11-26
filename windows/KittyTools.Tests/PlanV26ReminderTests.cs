// PLAN-v26 E1（照 mac 0.10.1 6bc786b6 的 E5 E6 E7）：时钟往回调的余量、推后的上限、暂停结束重新数、过了时段不补响、
// 「暂停到明天」到明天第一个时段、全屏没人碰时挂到提示上。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV26ReminderTests
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");

    /// <summary>当地 2026-11-05（周四）的几点几分。</summary>
    private static DateTime At(int hour, int minute, int day = 5)
        => new DateTime(2026, 11, day, hour, minute, 0, DateTimeKind.Utc).AddHours(-8);

    private static Reminder Interval(string id, int time, int until, int every = 30, params int[] days) => new()
    {
        Id = id, Title = id, IsOn = true,
        Schedule = new ReminderSchedule
        {
            Kind = ReminderSchedule.Interval, Time = time, Until = until, Every = every,
            Days = days.Length == 0 ? ReminderSchedule.AllDays.ToList() : days.ToList(),
        },
    };

    [TestMethod]
    public void ClockSlackAndFarthestSnooze()
    {
        var now = At(10, 0);
        var state = new ReminderState();
        state.Marks["a"] = new ReminderMark { At = ReminderTime.FromUtc(now) + 30, Schedule = new ReminderSchedule() };
        state.Marks["b"] = new ReminderMark { At = ReminderTime.FromUtc(now) + 600, Schedule = new ReminderSchedule() };
        state.Snoozed["s60"] = ReminderTime.FromUtc(now.AddMinutes(60));
        state.Snoozed["far"] = ReminderTime.FromUtc(now.AddHours(5));
        var pulled = state.PulledBack(now, ReminderAlerts.FarthestSnoozeMinutes * 60);
        Assert.AreEqual(ReminderTime.FromUtc(now) + 30, pulled.Marks["a"].At, "差几十秒的对时不动");
        Assert.AreEqual(ReminderTime.FromUtc(now), pulled.Marks["b"].At, "往回调了 10 分钟：收回到现在");
        Assert.AreEqual(ReminderTime.FromUtc(now.AddMinutes(60)), pulled.Snoozed["s60"], "全屏上推 1 小时的不被截短");
        Assert.AreEqual(ReminderTime.FromUtc(now.AddMinutes(65)), pulled.Snoozed["far"]);
    }

    [TestMethod]
    public void EndPauseOnlyWhenDue()
    {
        var state = new ReminderState { PausedUntil = ReminderTime.FromUtc(At(11, 0)) };
        Assert.IsFalse(state.EndPause(At(10, 59)));
        Assert.IsNotNull(state.PausedUntil);
        Assert.IsTrue(state.EndPause(At(11, 0)));
        Assert.IsNull(state.PausedUntil);
        Assert.IsFalse(state.EndPause(At(12, 0)), "没在暂停");
    }

    [TestMethod]
    public void IntervalOutsideWindowRestsInsteadOfFiring()
    {
        // 9:00–18:00 每 30 分钟，锚点 17:20 → 17:50 该响；18:30 才看到（从状态屏出来）：出了时段，不补响
        var water = Interval("water", 9 * 60, 18 * 60);
        var anchors = new Dictionary<string, DateTime> { ["water"] = At(17, 20) };
        var result = ReminderCheck.Check(new[] { water }, new ReminderState(), anchors, new HashSet<string>(), At(18, 30), Zone);
        Assert.AreEqual(0, result.Fire.Count);
        CollectionAssert.AreEqual(new[] { "water" }, result.Rested);
        Assert.AreEqual(At(9, 30, 6), result.Next, "交给明天的时段");

        // 还在时段里的晚了照响（间隔类不算错过）
        result = ReminderCheck.Check(new[] { water }, new ReminderState(), anchors, new HashSet<string>(), At(17, 58), Zone);
        CollectionAssert.AreEqual(new[] { "water" }, result.Fire);

        // 推过的照响：那是自己要的时刻
        var state = new ReminderState();
        state.Snoozed["water"] = ReminderTime.FromUtc(At(17, 55));
        result = ReminderCheck.Check(new[] { water }, state, anchors, new HashSet<string>(), At(18, 30), Zone);
        CollectionAssert.AreEqual(new[] { "water" }, result.Fire);
    }

    [TestMethod]
    public void PauseUntilTomorrowStartsAtFirstWindow()
    {
        var list = new List<Reminder>
        {
            Interval("eyes", 0, 1440, 20),          // 全天的不算时段
            Interval("water", 9 * 60, 18 * 60),
            Interval("late", 10 * 60, 18 * 60),
        };
        Assert.AreEqual(At(9, 0, 6), ReminderCheck.PauseUntilTomorrow(list, At(15, 0), Zone), "明天第一个时段 9:00");
        Assert.AreEqual(At(9, 0), ReminderCheck.PauseUntilTomorrow(list, At(1, 0), Zone), "凌晨点的：今天的 9:00 还没到");
        Assert.AreEqual(At(8, 0, 6), ReminderCheck.PauseUntilTomorrow(new[] { list[0] }, At(15, 0), Zone), "没设时段的到 8:00");
        Assert.AreEqual(At(8, 0, 6), ReminderCheck.PauseUntilTomorrow(Array.Empty<Reminder>(), At(15, 0), Zone));

        // 周五（11-06）只有周一的时段勾着：那天没有，按 8:00
        var monday = Interval("mon", 7 * 60, 9 * 60, 30, 2);
        Assert.AreEqual(At(8, 0, 6), ReminderCheck.PauseUntilTomorrow(new[] { monday }, At(15, 0), Zone));
        // 跨过半夜的按开始的钟点
        Assert.AreEqual(At(22, 0, 6), ReminderCheck.PauseUntilTomorrow(new[] { Interval("night", 22 * 60, 6 * 60) }, At(23, 0), Zone));
    }

    [TestMethod]
    public void UnattendedFullScreenKeepsNonInterval()
    {
        var list = new List<Reminder>
        {
            new() { Id = "once", Title = "交周报", IsOn = true, Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once } },
            Interval("eyes", 0, 1440, 20),
        };
        CollectionAssert.AreEqual(new[] { "once" }, ReminderAlerts.Unattended(new[] { "once", "eyes" }, list, idleSeconds: 40, shownSeconds: 20, away: false));
        Assert.AreEqual(0, ReminderAlerts.Unattended(new[] { "once", "eyes" }, list, idleSeconds: 3, shownSeconds: 20, away: false).Count, "有人碰过");
        CollectionAssert.AreEqual(new[] { "once" }, ReminderAlerts.Unattended(new[] { "once" }, list, idleSeconds: 0, shownSeconds: 20, away: true), "锁着屏");
        Assert.AreEqual(0, ReminderAlerts.Unattended(new[] { "eyes" }, list, idleSeconds: 40, shownSeconds: 20, away: false).Count, "全是间隔类");
    }
}
