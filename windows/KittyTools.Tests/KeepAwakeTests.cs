// 保持唤醒（PLAN-v20 K1 K2，照 mac KeepAwakeTests，f48c5d2e）的纯函数：定时的时段（工作日、跨午夜、全天、关着）、下一次要变的时刻、
// 读写，启动器「awake …」的解析和那几行，剩多久的说法；插件没添加时启动器里「添加…插件」那一行。执行层（电源请求、到点、醒来）不测。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class KeepAwakeTests
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    /// <summary>2026-11-16 是周一；给的是北京时间，返回 UTC。</summary>
    private static DateTime At(int day, int hour, int minute = 0)
        => TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 11, day, hour, minute, 0, DateTimeKind.Unspecified), Zone);

    [TestMethod]
    public void WorkdaysWindow()
    {
        var plan = new KeepAwakeSchedule { IsOn = true };
        Assert.IsTrue(plan.Contains(At(16, 10), Zone));
        Assert.IsFalse(plan.Contains(At(16, 8, 59), Zone));
        Assert.IsFalse(plan.Contains(At(16, 18), Zone), "结束那一刻已经出了时段");
        Assert.IsFalse(plan.Contains(At(21, 10), Zone), "周六");
        Assert.AreEqual(At(16, 9), plan.NextChange(At(16, 8), Zone));
        Assert.AreEqual(At(16, 18), plan.NextChange(At(16, 10), Zone));
        Assert.AreEqual(At(23, 9), plan.NextChange(At(20, 19), Zone), "周五下班之后：下一次是下周一 9 点");
        Assert.AreEqual("工作日 9:00–18:00", plan.Summary);
    }

    [TestMethod]
    public void OvernightWindow()
    {
        // 结束早于开始 = 跨午夜，算在开始那天：周五 22:00 管到周六 2:00，周四晚上不算
        var plan = new KeepAwakeSchedule { IsOn = true, Weekdays = new[] { 6 }, Start = 22 * 60, End = 2 * 60 };
        Assert.IsTrue(plan.Contains(At(20, 23), Zone));
        Assert.IsTrue(plan.Contains(At(21, 1), Zone));
        Assert.IsFalse(plan.Contains(At(21, 3), Zone));
        Assert.IsFalse(plan.Contains(At(19, 23), Zone));
        Assert.AreEqual(At(21, 2), plan.NextChange(At(21, 1), Zone));
        Assert.AreEqual("周五 22:00–次日 2:00", plan.Summary);
    }

    [TestMethod]
    public void AllDayAndOff()
    {
        var allDay = new KeepAwakeSchedule { IsOn = true, Weekdays = Enumerable.Range(1, 7).ToArray(), AllDay = true };
        Assert.IsTrue(allDay.Contains(At(22, 12), Zone));
        Assert.AreEqual("每天 全天", allDay.Summary);
        Assert.IsNull(allDay.NextChange(At(22, 12), Zone), "每天全天：一直在时段里，半夜的接缝不算");
        var sunday = new KeepAwakeSchedule { IsOn = true, Weekdays = new[] { 1 }, AllDay = true };
        Assert.IsTrue(sunday.Contains(At(22, 23, 59), Zone));
        Assert.IsFalse(sunday.Contains(At(23, 0, 30), Zone));
        // 工作日全天：周一到周五连成一段，下一次变是周六 0 点（不是每个半夜）
        var workdays = new KeepAwakeSchedule { IsOn = true, AllDay = true };
        Assert.AreEqual(At(21, 0), workdays.NextChange(At(17, 12), Zone));
        // 开始等于结束（拨时间时两边短暂相等）不当全天：那天没有时段
        var blank = new KeepAwakeSchedule { IsOn = true, Start = 9 * 60, End = 9 * 60 };
        Assert.IsFalse(blank.Contains(At(16, 9), Zone));
        var off = new KeepAwakeSchedule();
        Assert.IsFalse(off.Contains(At(16, 10), Zone));
        Assert.IsNull(off.NextChange(At(16, 8), Zone));
        var noDays = new KeepAwakeSchedule { IsOn = true, Weekdays = Array.Empty<int>() };
        Assert.IsNull(noDays.NextChange(At(16, 8), Zone));
    }

    [TestMethod]
    public void ScheduleStorage()
    {
        // 读写：往返不变；读不出的回到默认；越界的夹回来；写法和 mac 的偏好里那份 JSON 逐字节一样（键按字母排）
        var plan = new KeepAwakeSchedule { IsOn = true, Weekdays = new[] { 7, 1 }, Start = 60, End = 120 };
        Assert.AreEqual(plan, KeepAwakeSchedule.Decode(plan.Encode()));
        Assert.AreEqual("""{"allDay":false,"end":120,"isOn":true,"start":60,"weekdays":[1,7]}""", plan.Encode());
        Assert.AreEqual(new KeepAwakeSchedule(), KeepAwakeSchedule.Decode(""));
        Assert.AreEqual(new KeepAwakeSchedule(), KeepAwakeSchedule.Decode("不是 JSON"));
        var wild = KeepAwakeSchedule.Decode("""{"isOn":true,"weekdays":[0,2,9],"start":-5,"end":99999}""");
        CollectionAssert.AreEqual(new[] { 2 }, wild.Weekdays.ToArray());
        Assert.AreEqual(0, wild.Start);
        Assert.AreEqual(24 * 60 - 1, wild.End);
        Assert.AreEqual("周末 1:00–2:00", plan.Summary);
        Assert.AreEqual("周一、周三 9:00–18:00", (new KeepAwakeSchedule { Weekdays = new[] { 4, 2 } }).Summary);
    }

    [TestMethod]
    public void ParsePhrases()
    {
        var now = At(16, 10);
        Assert.IsInstanceOfType<KeepAwakeParsed.Empty>(KeepAwakePlan.Parse("", now, Zone));
        Assert.IsInstanceOfType<KeepAwakeParsed.Indefinitely>(KeepAwakePlan.Parse("无限期", now, Zone));
        Assert.AreEqual(new KeepAwakeParsed.Until(now.AddHours(2), "2 小时"), KeepAwakePlan.Parse("2小时", now, Zone));
        Assert.AreEqual(new KeepAwakeParsed.Until(now.AddMinutes(90), "1 小时 30 分钟"), KeepAwakePlan.Parse("90m", now, Zone));
        Assert.AreEqual(new KeepAwakeParsed.Until(At(16, 18), "到 18:00"), KeepAwakePlan.Parse("到18点", now, Zone));
        Assert.AreEqual(new KeepAwakeParsed.Until(At(16, 18, 30), "到 18:30"), KeepAwakePlan.Parse("until 18:30", now, Zone));
        Assert.IsInstanceOfType<KeepAwakeParsed.Invalid>(KeepAwakePlan.Parse("喝水", now, Zone));
        Assert.IsInstanceOfType<KeepAwakeParsed.Invalid>(KeepAwakePlan.Parse("2小时 下载", now, Zone));
    }

    [TestMethod]
    public void Wording()
    {
        var now = At(16, 10);
        Assert.AreEqual("无限期", KeepAwakePlan.Remaining(null, now));
        Assert.AreEqual("还剩 1 小时 12 分", KeepAwakePlan.Remaining(now.AddMinutes(72), now));
        Assert.AreEqual("还剩 2 小时", KeepAwakePlan.Remaining(now.AddHours(2), now));
        Assert.AreEqual("还剩 42 分", KeepAwakePlan.Remaining(now.AddMinutes(42), now));
        Assert.AreEqual("还剩不到 1 分钟", KeepAwakePlan.Remaining(now.AddSeconds(30), now));
        Assert.AreEqual("18:05", KeepAwakePlan.Moment(At(16, 18, 5), now, Zone));
        Assert.AreEqual("明天 8:00", KeepAwakePlan.Moment(At(17, 8), now, Zone));
        Assert.AreEqual("2h", KeepAwakePlan.Query("awake 2h"));
        Assert.AreEqual("到18点", KeepAwakePlan.Query("Awake 到18点"));
        Assert.IsNull(KeepAwakePlan.Query("awake"));
        Assert.IsNull(KeepAwakePlan.Query("awakening"));
        // 中文关键词后面不打空格也认；只打关键词本身不算
        Assert.AreEqual("2小时", KeepAwakePlan.Query("保持唤醒2小时"));
        Assert.IsNull(KeepAwakePlan.Query("保持唤醒"));
    }

    [TestMethod]
    public void LauncherRows()
    {
        // 「awake …」那几行：什么都没写列五档（目标各不相同）；开着时第一行是停止；认不出给提示
        var now = At(16, 10);
        var presets = KeepAwakeLauncher.Items("", null, now, Zone);
        CollectionAssert.AreEqual(
            new[] { "保持唤醒 30 分钟", "保持唤醒 1 小时", "保持唤醒 2 小时", "保持唤醒 5 小时", "保持唤醒 无限期" },
            presets.Select(item => item.Title).ToArray());
        Assert.AreEqual(presets.Count, presets.Select(item => item.Target).Distinct().Count());
        Assert.AreEqual("到 11:00", presets[1].Subtitle);
        Assert.AreEqual("直到你停止", presets[4].Subtitle);
        var running = KeepAwakeLauncher.Items("2小时", "还剩 42 分", now, Zone);
        CollectionAssert.AreEqual(new[] { "停止保持唤醒", "保持唤醒 2 小时" }, running.Select(item => item.Title).ToArray());
        Assert.AreEqual("保持唤醒中 · 还剩 42 分", running[0].Subtitle);
        Assert.AreEqual("2小时", running[1].Payload);
        var bad = KeepAwakeLauncher.Items("喝水", null, now, Zone);
        CollectionAssert.AreEqual(new[] { KeepAwakeLauncher.Prefix + "hint" }, bad.Select(item => item.Target).ToArray());
    }

    [TestMethod]
    public void PluginOffersNeedAWholeWordOrALongEnoughStart()
    {
        // 照 mac pluginOffers（Windows 只有保持唤醒一个插件，§0）
        var plugins = new[] { new PluginInfo("keepAwake", "保持唤醒", "不让电脑睡", new[] { "awake", "保持唤醒", "防息屏", "防止睡眠", "caffeinate" }) };
        List<string> Offered(string typed, params string[] added)
            => PluginOffers.For(typed, plugins, added.ToHashSet()).Select(item => item.Title).ToList();

        CollectionAssert.AreEqual(new[] { "添加「保持唤醒」插件" }, Offered("awake"));
        CollectionAssert.AreEqual(new[] { "添加「保持唤醒」插件" }, Offered("awake 2小时"));
        CollectionAssert.AreEqual(new[] { "添加「保持唤醒」插件" }, Offered("awak"));
        CollectionAssert.AreEqual(new[] { "添加「保持唤醒」插件" }, Offered("保持"));
        CollectionAssert.AreEqual(new[] { "添加「保持唤醒」插件" }, Offered("保持唤醒2小时"));
        Assert.AreEqual(0, Offered("ca").Count + Offered("aw").Count + Offered("safari").Count);
        Assert.AreEqual(0, Offered("awakening").Count, "英文的词后面紧跟字母不算");
        Assert.AreEqual(0, Offered("awake", "keepAwake").Count, "添加了就不出");
        Assert.AreEqual(PluginOffers.Prefix + "keepAwake", PluginOffers.For("防息屏", plugins, new HashSet<string>())[0].Target);
    }
}
