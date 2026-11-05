// PLAN-v12 第 5 批：提醒的纯逻辑（照 mac ReminderTests.swift 的口径）。时区固定 UTC+8，「现在」是 2026-11-05（周四）10:00。
// 同步的那一行和 mac 一字不差：Golden 里的几行是在 Mac 上用 mac 的 Reminder 结构 + SyncRecords.encoder（sortedKeys、withoutEscapingSlashes）
// 真编出来的（2026-11-05）。
using System.Text;
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ReminderTests
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");

    /// <summary>当地 2026-11-05 10:00（周四）。</summary>
    private static readonly DateTime Now = Local(2026, 11, 5, 10, 0);

    private static DateTime Local(int year, int month, int day, int hour, int minute)
        => new DateTime(year, month, day, hour, minute, 0, DateTimeKind.Utc).AddHours(-8);

    private static readonly string[] Golden =
    {
        "{\"alert\":\"light\",\"chime\":\"Glass\",\"fullSeconds\":0,\"id\":\"water\",\"isOn\":false,\"nagMinutes\":0,\"schedule\":{\"date\":-63114076800,\"day\":1,\"days\":[2,3,4,5,6],\"every\":60,\"kind\":\"interval\",\"time\":540,\"until\":1080},\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"hot-beverage\",\"title\":\"喝水\"}",
        "{\"alert\":\"full\",\"chime\":\"Glass\",\"detail\":\"看看 6 米外的地方，20 秒\",\"fullSeconds\":20,\"id\":\"eyes\",\"isOn\":false,\"nagMinutes\":0,\"schedule\":{\"date\":-63114076800,\"day\":1,\"days\":[1,2,3,4,5,6,7],\"every\":20,\"kind\":\"interval\",\"time\":0,\"until\":1440},\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"sleeping-face\",\"title\":\"休息眼睛\"}",
        "{\"alert\":\"glow\",\"chime\":\"Glass\",\"fullSeconds\":0,\"id\":\"walk\",\"isOn\":false,\"nagMinutes\":0,\"schedule\":{\"date\":-63114076800,\"day\":1,\"days\":[2,3,4,5,6],\"every\":45,\"kind\":\"interval\",\"time\":540,\"until\":1080},\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"waving-hand\",\"title\":\"起来走走\"}",
        "{\"alert\":\"status\",\"chime\":\"Ping\",\"detail\":\"第二行\\n带换行\",\"fullSeconds\":60,\"id\":\"A1B2\",\"isOn\":true,\"nagMinutes\":10,\"schedule\":{\"date\":815545273.628506,\"day\":1,\"days\":[1,2,3,4,5,6,7],\"every\":60,\"kind\":\"once\",\"time\":540,\"until\":1080},\"sound\":\"speak\",\"statusID\":\"busy\",\"symbol\":\"rocket\",\"title\":\"交周报 \\\"Q4\\\" / 汇总\"}",
        "{\"alert\":\"light\",\"chime\":\"Glass\",\"fullSeconds\":0,\"id\":\"M1\",\"isOn\":true,\"nagMinutes\":0,\"schedule\":{\"date\":-63114076800,\"day\":31,\"days\":[1,2,3,4,5,6,7],\"every\":60,\"kind\":\"monthly\",\"time\":1050,\"until\":1080},\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"\",\"title\":\"月报\"}",
        "{\"alert\":\"light\",\"chime\":\"Glass\",\"fullSeconds\":0,\"id\":\"W1\",\"isOn\":true,\"nagMinutes\":0,\"schedule\":{\"date\":-63114076800,\"day\":1,\"days\":[2,4,6],\"every\":60,\"kind\":\"weekly\",\"time\":600,\"until\":1080},\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"\",\"title\":\"周会\"}",
    };

    private static List<Reminder> GoldenCases()
    {
        var cases = Reminders.Examples().ToList();
        cases.Add(new Reminder
        {
            Id = "A1B2", Title = "交周报 \"Q4\" / 汇总", Detail = "第二行\n带换行", Symbol = "rocket", IsOn = true,
            Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = 815545273.628506 },
            Alert = Reminder.Status, StatusID = "busy", FullSeconds = 60, Sound = Reminder.SoundSpeak, Chime = "Ping", NagMinutes = 10,
        });
        cases.Add(new Reminder { Id = "M1", Title = "月报", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Monthly, Time = 17 * 60 + 30, Day = 31 } });
        cases.Add(new Reminder { Id = "W1", Title = "周会", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Weekly, Time = 600, Days = new() { 2, 4, 6 } } });
        return cases;
    }

    [TestMethod]
    public void Canonical_MatchesMacByteForByte()
    {
        var cases = GoldenCases();
        for (var index = 0; index < cases.Count; index++)
        {
            Assert.AreEqual(Golden[index], Reminders.Canonical(cases[index]), cases[index].Id);
            var decoded = ReminderSync.Decode(Golden[index]);
            Assert.IsNotNull(decoded, cases[index].Id);
            Assert.IsTrue(decoded.SameAs(cases[index]));
        }

        Assert.AreEqual(
            "{\"date\":815545273.628506,\"day\":1,\"days\":[1,2,3,4,5,6,7],\"every\":60,\"kind\":\"once\",\"time\":540,\"until\":1080}",
            Reminders.CanonicalSchedule(cases[3].Schedule));
        Assert.AreEqual("交周报 \"Q4\" / 汇总\n" + Reminders.CanonicalSchedule(cases[3].Schedule), ReminderSync.JoinKey(Golden[3]));
    }

    [TestMethod]
    public void Sync_DecodeExactAndPlan()
    {
        // 不认识的方式、种类、多了个键、键序不对：编回去不一样 = 更新的版本写的，不落。
        Assert.IsNull(ReminderSync.Decode(Golden[0].Replace("\"light\"", "\"popup\"")));
        Assert.IsNull(ReminderSync.Decode(Golden[0].Replace("\"interval\"", "\"yearly\"")));
        Assert.IsNull(ReminderSync.Decode(Golden[0].Replace("{\"alert\"", "{\"zzz\":1,\"alert\"")));
        Assert.IsNull(ReminderSync.Decode("{\"id\":\"x\",\"title\":\"t\"}"));

        var values = ReminderSync.Values(GoldenCases());
        Assert.AreEqual(Golden[4], values["M1"]);
        Assert.AreEqual("[\"water\",\"eyes\",\"walk\",\"A1B2\",\"M1\",\"W1\"]", values[SyncEngine.OrderID]);
        Assert.AreEqual(1, ReminderSync.Values(null).Count, "没存过列表：交出去只有空的顺序");

        var changes = new Dictionary<string, string?>
        {
            ["water"] = null,
            ["W1"] = Golden[5].Replace("周会", "周例会"),
            [SyncEngine.OrderID] = "[\"W1\",\"eyes\",\"walk\"]",
        };
        var planned = ReminderSync.Plan(changes, Reminders.Examples().Append(GoldenCases()[5]).ToList(), out var failure);
        Assert.IsNull(failure);
        CollectionAssert.AreEqual(new[] { "W1", "eyes", "walk" }, planned!.Select(reminder => reminder.Id).ToList());
        Assert.AreEqual("周例会", planned[0].Title);
        Assert.IsNull(ReminderSync.Plan(new Dictionary<string, string?> { ["x"] = "{" }, null, out failure));
        Assert.IsNotNull(failure);
    }

    [TestMethod]
    public void Sanitized_AndLoad()
    {
        var list = Reminders.Sanitized(new Reminder?[]
        {
            new() { Id = "a", Title = " 多行\n标题 ", Symbol = "nope", Alert = "popup", Sound = "beep", FullSeconds = 7, NagMinutes = 3, Chime = "Xylo",
                Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 2000, Until = 10, Days = new() { 9, 3, 3 }, Day = 40, Every = 1 } },
            new() { Id = "a", Title = "重复" },
            new() { Id = "", Title = "没 id" },
            null,
        });
        Assert.AreEqual(1, list.Count);
        var reminder = list[0];
        Assert.AreEqual("多行 标题", reminder.Title);
        Assert.AreEqual(string.Empty, reminder.Symbol);
        Assert.AreEqual(Reminder.Light, reminder.Alert);
        Assert.AreEqual(Reminder.SoundChime, reminder.Sound);
        Assert.AreEqual(0, reminder.FullSeconds);
        Assert.AreEqual(0, reminder.NagMinutes);
        Assert.AreEqual(Reminders.DefaultChime, reminder.Chime);
        Assert.AreEqual(1439, reminder.Schedule.Time);
        Assert.AreEqual(1440, reminder.Schedule.Until);
        CollectionAssert.AreEqual(new[] { 3 }, reminder.Schedule.Days);
        Assert.AreEqual(31, reminder.Schedule.Day);
        Assert.AreEqual(5, reminder.Schedule.Every);

        Assert.AreEqual(3, Reminders.Load(null).Count, "没存过是示例");
        Assert.AreEqual(0, Reminders.Load(new List<Reminder>()).Count, "存过空的就是空的");
        Assert.IsTrue(Reminders.IsPristine(Reminders.Examples()[0].Copy()));
        var on = Reminders.Examples()[0].Copy();
        on.IsOn = true;
        Assert.IsTrue(Reminders.IsPristine(on), "开没开不算");
        on.Title = "多喝水";
        Assert.IsFalse(Reminders.IsPristine(on));
    }

    [TestMethod]
    public void Archive_RoundTripsWithIsoDates()
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            Reminders.WriteArchive(writer, GoldenCases()[3]);
        }

        var text = Encoding.UTF8.GetString(stream.ToArray());
        StringAssert.Contains(text, "\"date\":\"2026-11-05T04:21:13Z\"");
        using var document = JsonDocument.Parse(text);
        var read = Reminders.Read(document.RootElement)!;
        Assert.AreEqual(815545273, read.Schedule.Date, 1e-9, "ISO 只到秒（同 mac .iso8601）");
        Assert.AreEqual("busy", read.StatusID);

        // mac 导出的（缺字段的用默认值，种类不认识的当很久以前的一次）。
        using var mac = JsonDocument.Parse("[{\"id\":\"x\",\"title\":\"t\",\"schedule\":{\"kind\":\"yearly\",\"date\":\"2026-01-01T00:00:00Z\"}},{\"title\":\"没 id\"}]");
        var list = Reminders.ReadList(mac.RootElement)!;
        Assert.AreEqual(1, list.Count);
        Assert.AreEqual(ReminderSchedule.Once, list[0].Schedule.Kind);
        Assert.AreEqual(ReminderTime.DistantPast, list[0].Schedule.Date);
        Assert.IsFalse(list[0].IsOn);
    }

    [TestMethod]
    public void Merged_KeepsLocalSkipsPastOnes()
    {
        var local = Reminders.Examples().ToList();
        var past = new Reminder { Id = "past", Title = "早就过了", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(Now.AddDays(-1)) } };
        var fresh = new Reminder { Id = "fresh", Title = "明天", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(Now.AddDays(1)) } };
        var renamed = local[1].Copy();
        renamed.Title = "看远处";
        var merged = Reminders.Merged(new[] { renamed, past, fresh }, local, Now);
        CollectionAssert.AreEqual(new[] { "eyes", "fresh", "water", "walk" }, merged.Select(reminder => reminder.Id).ToList());
        Assert.AreEqual("看远处", merged[0].Title);
    }

    [TestMethod]
    public void Schedule_WeeklyMonthlyOnce()
    {
        var weekly = new ReminderSchedule { Kind = ReminderSchedule.Weekly, Time = 600, Days = new() { 2, 4, 6 } };
        Assert.AreEqual(Local(2026, 11, 6, 10, 0), ReminderMath.NextAfter(weekly, Now, Zone), "周四 10:00 之后是周五 10:00");
        Assert.AreEqual(Local(2026, 11, 9, 10, 0), ReminderMath.NextAfter(weekly, Local(2026, 11, 6, 10, 0), Zone), "严格晚于");

        var monthly = new ReminderSchedule { Kind = ReminderSchedule.Monthly, Time = 1050, Day = 31 };
        Assert.AreEqual(Local(2026, 11, 30, 17, 30), ReminderMath.NextAfter(monthly, Now, Zone), "没有 31 号在最后一天");
        Assert.AreEqual(Local(2026, 12, 31, 17, 30), ReminderMath.NextAfter(monthly, Local(2026, 11, 30, 18, 0), Zone));

        var once = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(Local(2026, 11, 5, 12, 0)) };
        Assert.AreEqual(Local(2026, 11, 5, 12, 0), ReminderMath.NextAfter(once, Now, Zone));
        Assert.IsNull(ReminderMath.NextAfter(once, Local(2026, 11, 5, 12, 0), Zone));
    }

    [TestMethod]
    public void Schedule_Interval()
    {
        var work = new ReminderSchedule { Kind = ReminderSchedule.Interval, Days = ReminderSchedule.Workdays.ToList(), Every = 60 };
        Assert.AreEqual(Local(2026, 11, 5, 11, 0), ReminderMath.NextFromAnchor(work, Now, Zone));
        Assert.AreEqual(Local(2026, 11, 5, 9, 30), ReminderMath.NextFromAnchor(work, Local(2026, 11, 5, 8, 30), Zone), "8:30 开始用电脑 = 9:30");
        Assert.AreEqual(Local(2026, 11, 6, 10, 0), ReminderMath.NextFromAnchor(work, Local(2026, 11, 5, 17, 30), Zone), "时段外：明天开始 + 60");
        Assert.AreEqual(Local(2026, 11, 9, 10, 0), ReminderMath.NextFromAnchor(work, Local(2026, 11, 6, 17, 30), Zone), "周末不算");

        var allDay = new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 0, Until = 1440, Every = 20 };
        Assert.AreEqual(Local(2026, 11, 6, 0, 10), ReminderMath.NextFromAnchor(allDay, Local(2026, 11, 5, 23, 50), Zone), "全天的跨过半夜接着数");
    }

    [TestMethod]
    public void Check_FireMissedHeldAway()
    {
        var once = new Reminder { Id = "o", Title = "开会", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(Now) } };
        var interval = new Reminder { Id = "i", Title = "喝水", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Days = ReminderSchedule.Workdays.ToList(), Every = 60 } };
        var list = new List<Reminder> { once, interval };
        var state = ReminderCheck.Reconciled(new ReminderState(), list, Now.AddHours(-1));
        var anchors = new Dictionary<string, DateTime> { ["i"] = Local(2026, 11, 5, 8, 0) };
        var none = new HashSet<string>();

        var result = ReminderCheck.Check(list, state, anchors, none, Now.AddMinutes(3), Zone);
        CollectionAssert.AreEqual(new[] { "o", "i" }, result.Fire, "晚 3 分钟照常响；间隔的晚了也响");

        result = ReminderCheck.Check(list, state, anchors, none, Now.AddMinutes(6), Zone);
        CollectionAssert.AreEqual(new[] { "o" }, result.Missed, "晚 6 分钟算错过");
        CollectionAssert.AreEqual(new[] { "i" }, result.Fire);

        result = ReminderCheck.Check(list, state, anchors, none, Local(2026, 11, 5, 8, 59), Zone);
        Assert.AreEqual(0, result.Fire.Count + result.Missed.Count);
        Assert.AreEqual(Local(2026, 11, 5, 9, 0), result.Next, "间隔的 9:00 最早");

        result = ReminderCheck.Check(list, state, anchors, none, Now.AddMinutes(3), Zone, held: true);
        Assert.AreEqual(0, result.Fire.Count + result.Missed.Count, "锁着屏 / 状态屏里 / 暂停着：一条都不响");

        result = ReminderCheck.Check(list, state, anchors, new HashSet<string> { "o" }, Now.AddMinutes(3), Zone, away: true);
        Assert.AreEqual(0, result.Fire.Count, "正挂着的不重复响；离开了的间隔先不响");

        state.Snoozed["i"] = ReminderTime.FromUtc(Now.AddMinutes(5));
        result = ReminderCheck.Check(list, state, anchors, new HashSet<string> { "o" }, Now.AddMinutes(5), Zone, away: true);
        CollectionAssert.AreEqual(new[] { "i" }, result.Fire, "推过的到点照常响（离开了也响）");
    }

    [TestMethod]
    public void Reconciled_AndRescheduled()
    {
        var a = new Reminder { Id = "a", Title = "a", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Weekly } };
        var b = new Reminder { Id = "b", Title = "b", IsOn = false };
        var state = ReminderCheck.Reconciled(new ReminderState(), new[] { a, b }, Now);
        Assert.IsTrue(state.Marks.ContainsKey("a"));
        Assert.IsFalse(state.Marks.ContainsKey("b"), "关着的不记");
        state.Snoozed["a"] = 1;
        var changed = a.Copy();
        changed.Schedule.Time = 600;
        var next = ReminderCheck.Reconciled(state, new[] { changed }, Now.AddHours(1));
        Assert.AreEqual(ReminderTime.FromUtc(Now.AddHours(1)), next.Marks["a"].At, "改了时间从现在重新算");
        Assert.IsFalse(next.Snoozed.ContainsKey("a"), "推到的时刻作废");
        CollectionAssert.AreEqual(new[] { "a" }, ReminderCheck.Rescheduled(new[] { a }, new[] { changed }).ToList());

        state.PausedUntil = ReminderTime.FromUtc(Now.AddDays(5));
        state.Marks["a"].At = ReminderTime.FromUtc(Now.AddDays(2));
        var pulled = state.PulledBack(Now, 1800);
        Assert.AreEqual(ReminderTime.FromUtc(Now), pulled.Marks["a"].At);
        Assert.AreEqual(ReminderTime.FromUtc(Now) + 86_400, pulled.PausedUntil);
    }

    [TestMethod]
    public void Phrase_Durations()
    {
        Assert.AreEqual("10分钟 喝水", ReminderPhrase.Query("提醒 10分钟 喝水"));
        Assert.AreEqual("x", ReminderPhrase.Query("TX x"));
        Assert.IsNull(ReminderPhrase.Query("提醒事项"));
        Assert.IsTrue(ReminderPhrase.IsKeyword(" remind "));

        var parsed = ReminderPhrase.Parse("10分钟 喝水", Now, Zone)!.Value;
        Assert.AreEqual(Now.AddMinutes(10), parsed.At);
        Assert.AreEqual("喝水", parsed.Title);
        parsed = ReminderPhrase.Parse("1个半小时后 关火", Now, Zone)!.Value;
        Assert.AreEqual(Now.AddMinutes(90), parsed.At);
        Assert.AreEqual("关火", parsed.Title);
        parsed = ReminderPhrase.Parse("半小时", Now, Zone)!.Value;
        Assert.AreEqual(Now.AddMinutes(30), parsed.At);
        Assert.AreEqual(ReminderPhrase.DefaultTitle, parsed.Title);
        Assert.AreEqual(Now.AddMinutes(80), ReminderPhrase.Parse("1小时20分 出门", Now, Zone)!.Value.At);
        Assert.AreEqual(Now.AddMinutes(120), ReminderPhrase.Parse("2h 下载完了", Now, Zone)!.Value.At);
        Assert.AreEqual(Now.AddMinutes(10), ReminderPhrase.Parse("１０分钟 全角", Now, Zone)!.Value.At);
        Assert.IsNull(ReminderPhrase.Parse("每天9点 吃药", Now, Zone), "重复的去设置里建");
        Assert.IsNull(ReminderPhrase.Parse("喝水", Now, Zone));
    }

    [TestMethod]
    public void Phrase_Moments()
    {
        (DateTime At, string Title) Parse(string text) => ReminderPhrase.Parse(text, Now, Zone)!.Value;
        Assert.AreEqual((Local(2026, 11, 6, 9, 0), "交周报"), Parse("明天9点 交周报"));
        Assert.AreEqual((Local(2026, 11, 5, 15, 30), "开会"), Parse("下午3点半 开会"));
        Assert.AreEqual((Local(2026, 11, 5, 21, 0), "吃药"), Parse("9点 吃药"), "现在 10:00 说 9 点 = 今晚 21:00");
        Assert.AreEqual((Local(2026, 11, 5, 15, 15), "开会"), Parse("3点15分 开会"), "不当成 15 分钟后");
        Assert.AreEqual((Local(2026, 11, 6, 15, 0), "开会1小时"), Parse("周五下午3点 开会1小时"), "按先出现的那个");
        Assert.AreEqual((Local(2026, 11, 6, 9, 0), "3号会议室"), Parse("明天9点 3号会议室"));
        Assert.AreEqual((Local(2026, 12, 25, 9, 0), "圣诞"), Parse("12月25日 圣诞"));
        Assert.AreEqual((Local(2027, 11, 1, 9, 0), "交房租"), Parse("11月1日 交房租"), "过了就是明年");
        Assert.AreEqual((Local(2026, 11, 9, 9, 0), "开会"), Parse("下周一 开会"));
        Assert.AreEqual((Local(2026, 11, 12, 9, 0), "例会"), Parse("周四 例会"), "今天就是周四而 9 点已过：下周四");
        Assert.AreEqual((Local(2026, 11, 5, 20, 0), "看球"), Parse("今晚 看球"));
        Assert.AreEqual((Local(2026, 11, 5, 18, 30), "下班"), Parse("18:30 下班"));
        Assert.IsNull(ReminderPhrase.Parse("2月30日 不存在", Now, Zone));
        Assert.IsNull(ReminderPhrase.Parse("25点 不存在", Now, Zone));
    }

    [TestMethod]
    public void Alerts_AndNotice()
    {
        var light = new Reminder { Id = "l", Title = "喝水", Alert = Reminder.Light };
        var full = new Reminder { Id = "f", Title = "休息", Detail = "看远处", Alert = Reminder.Full, FullSeconds = 20 };
        var full60 = new Reminder { Id = "g", Title = "走走", Alert = Reminder.Full, FullSeconds = 60 };
        Assert.AreEqual(Reminder.Full, ReminderAlerts.Alert(new[] { light, full }, recording: false));
        Assert.AreEqual(Reminder.Light, ReminderAlerts.Alert(new[] { light, full }, recording: true), "录屏录音时一律轻提醒");
        Assert.AreEqual(60, ReminderAlerts.FullSeconds(new[] { full, full60, light }));
        Assert.AreEqual(0, ReminderAlerts.FullSeconds(new[] { light }));
        CollectionAssert.AreEqual(new[] { 5, 15, 60 }, ReminderAlerts.SnoozeChoices(5).ToList());
        CollectionAssert.AreEqual(new[] { 15, 60 }, ReminderAlerts.SnoozeChoices(15).ToList());

        Assert.AreEqual(("休息", "看远处"), ReminderAlerts.Notice(new[] { full }, Array.Empty<Reminder>())!.Value);
        Assert.AreEqual(("喝水 · 休息", "还错过了：走走"), ReminderAlerts.Notice(new[] { light, full }, new[] { full60 })!.Value);
        Assert.AreEqual(("错过了提醒：休息", "看远处"), ReminderAlerts.Notice(Array.Empty<Reminder>(), new[] { full })!.Value);
        Assert.AreEqual(("错过了 2 个提醒", "喝水、走走"), ReminderAlerts.Notice(Array.Empty<Reminder>(), new[] { light, full60 })!.Value);
        Assert.IsNull(ReminderAlerts.Notice(Array.Empty<Reminder>(), Array.Empty<Reminder>()));
    }

    [TestMethod]
    public void Summary_AndNew()
    {
        var examples = Reminders.Examples();
        Assert.AreEqual("工作日 9:00–18:00 每 60 分钟 · 轻提醒", Reminders.Summary(examples[0], Now, Zone));
        Assert.AreEqual("每 20 分钟 · 全屏 20 秒", Reminders.Summary(examples[1], Now, Zone));
        Assert.AreEqual("工作日 9:00–18:00 每 45 分钟 · 边框", Reminders.Summary(examples[2], Now, Zone));
        var weekly = new Reminder { Title = "x", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Weekly, Time = 600, Days = new() { 1, 2, 4 } }, Alert = Reminder.Status };
        Assert.AreEqual("每周一、三、日 10:00 · 进入「请勿触碰」", Reminders.Summary(weekly, Now, Zone, "请勿触碰"));
        var once = new Reminder { Title = "x", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Once, Date = ReminderTime.FromUtc(Local(2026, 11, 6, 9, 5)) } };
        Assert.AreEqual("明天 9:05 · 轻提醒", Reminders.Summary(once, Now, Zone));
        once.Schedule.Date = ReminderTime.FromUtc(Local(2027, 1, 2, 9, 5));
        Assert.AreEqual("2027年1月2日 9:05 · 轻提醒", Reminders.Summary(once, Now, Zone));
        Assert.AreEqual("周末", Reminders.DaysTitle(new[] { 1, 7 }));

        var created = Reminders.New(Local(2026, 11, 5, 10, 55), Zone, "N");
        Assert.AreEqual(ReminderTime.FromUtc(Local(2026, 11, 5, 12, 0)), created.Schedule.Date, "离整点不到 10 分钟就再下一个");
        Assert.AreEqual("这个时间已经过了，不会再提醒", Reminders.Problem(created, Local(2026, 11, 5, 12, 1)));
        Assert.IsNull(Reminders.Problem(created, Now));
    }

    [TestMethod]
    public void Launcher_ItemsAndPrompts()
    {
        // 「提醒 10分钟 喝水」：第一行是建一条，后面没有同名的。
        var list = Reminders.Examples();
        var items = ReminderLauncher.Items("10分钟 喝水", list, Now, Zone);
        Assert.AreEqual(ReminderLauncher.NewTarget, items[0].Target);
        Assert.AreEqual("提醒我：喝水", items[0].Title);
        Assert.AreEqual("10分钟 喝水", items[0].Payload);
        Assert.IsNull(ReminderLauncher.IdOf(items[0].Target));

        // 只写了「提醒 」：列出全部已有的，没有建一条也没有提示。
        items = ReminderLauncher.Items(string.Empty, list, Now, Zone);
        CollectionAssert.AreEqual(new[] { "reminder:water", "reminder:eyes", "reminder:walk" }, items.Select(item => item.Target).ToList());
        Assert.AreEqual("off", items[0].Payload);
        StringAssert.EndsWith(items[0].Subtitle, " · 已暂停");
        Assert.AreEqual("water", ReminderLauncher.IdOf(items[0].Target));

        // 认不出时间：按标题筛已有的，末尾一行提示；重复的叫去设置里建。
        items = ReminderLauncher.Items("喝水", list, Now, Zone);
        CollectionAssert.AreEqual(new[] { "reminder:water", ReminderLauncher.HintTarget }, items.Select(item => item.Target).ToList());
        Assert.AreEqual("认不出时间", items[^1].Title);
        Assert.AreEqual("重复的提醒到设置里建", ReminderLauncher.Items("每天9点 喝水", list, Now, Zone)[^1].Title);

        Assert.AreEqual(1, ReminderLauncher.Prompts("TX").Count);
        Assert.AreEqual("提醒 ", ReminderLauncher.Prompts(" 提醒 ")[0].Completion);
        Assert.AreEqual(0, ReminderLauncher.Prompts("提醒 10分钟").Count);

        // 三个关键词都留给提醒：网页搜索里不能再用。
        foreach (var keyword in ReminderPhrase.Keywords)
        {
            Assert.AreEqual("提醒", WebSearch.ReservedKeywords[keyword]);
        }
    }
}
