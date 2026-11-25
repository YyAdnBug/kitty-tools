// PLAN-v26 第 1 批（I1–I5）：和 mac 0.10.x 的同步互通。样本是照 mac 0.10.3 的编码规则手写的（SyncRecords.encoder：键排好序、
// 不转义斜杠和非 ASCII；可选的 nil 不写）——审查方之后从 mac 单测宿主真编一份替换（REVIEW「PLAN-v26」第 1 批）。
// 每类一条「读进来 → 编回去逐字节一样」，加上旧版本该停、新字段该留着的几条。
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV26SyncTests
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");

    /// <summary>当地 2026-11-day hour:minute（2026-11-02 是周一），同 mac ReminderTests.at。</summary>
    private static DateTime At(int day, int hour, int minute = 0)
        => new DateTime(2026, 11, day, hour, minute, 0, DateTimeKind.Utc).AddHours(-8);

    // ---- I1 提醒

    /// <summary>mac 0.10.3：开了「专注模式时也照常提醒」、跨半夜 22:00–6:00 的间隔提醒（duringFocus 一定写；overnight 只在跨时写，排在 kind 后面）。</summary>
    private const string MacNightShift =
        "{\"alert\":\"glow\",\"chime\":\"Glass\",\"duringFocus\":true,\"fullSeconds\":0,\"id\":\"N1\",\"isOn\":true,\"nagMinutes\":0," +
        "\"schedule\":{\"date\":-63114076800,\"day\":1,\"days\":[2,3,4,5,6],\"every\":60,\"kind\":\"interval\",\"overnight\":true,\"time\":1320,\"until\":360}," +
        "\"sound\":\"chime\",\"statusID\":\"\",\"symbol\":\"\",\"title\":\"夜班喝水\"}";

    [TestMethod]
    public void Reminder_MacSampleRoundTrips()
    {
        var reminder = ReminderSync.Decode(MacNightShift);
        Assert.IsNotNull(reminder);
        Assert.IsTrue(reminder.DuringFocus);
        Assert.IsTrue(reminder.Schedule.IsOvernight());
        Assert.AreEqual(480, reminder.Schedule.WindowMinutes());
        Assert.AreEqual(MacNightShift, Reminders.Canonical(reminder));
        Assert.AreEqual(MacNightShift, ReminderSync.Values(new[] { reminder })["N1"]);

        // 落地：Plan 收得下、Sanitized 不把 22:00–6:00 收拾成到半夜
        var planned = ReminderSync.Plan(new Dictionary<string, string?> { ["N1"] = MacNightShift }, new List<Reminder>(), out var failure);
        Assert.IsNull(failure);
        Assert.IsNotNull(planned);
        Assert.AreEqual(360, planned.Single().Schedule.Until);
        Assert.IsTrue(planned.Single().DuringFocus);
    }

    [TestMethod]
    public void Reminder_OldOrBentRecordsStop()
    {
        // 0.9 以前的记录没有 duringFocus：同 mac 0.10 的 decodeExact，编回去对不上、那一类停下（对面先更新）
        var old = MacNightShift.Replace("\"duringFocus\":true,", string.Empty)
            .Replace("\"overnight\":true,", string.Empty).Replace("\"until\":360", "\"until\":1080").Replace("\"time\":1320", "\"time\":540");
        Assert.IsNull(ReminderSync.Decode(old));
        // 写了 overnight 却没跨半夜、跨了却没写：都不是 mac 写得出来的
        Assert.IsNull(ReminderSync.Decode(MacNightShift.Replace("\"until\":360", "\"until\":1380")));
        Assert.IsNull(ReminderSync.Decode(MacNightShift.Replace("\"overnight\":true,", string.Empty)));
        // 不是间隔类的没有时段：结束早于开始照旧收拾成到半夜，编出来没有 overnight
        var weekly = new ReminderSchedule { Kind = ReminderSchedule.Weekly, Time = 20 * 60, Until = 60 }.Sanitized();
        Assert.AreEqual(1440, weekly.Until);
        Assert.IsFalse(Reminders.CanonicalSchedule(weekly).Contains("overnight"));
    }

    [TestMethod]
    public void Reminder_DuringFocusAlwaysWrittenAndArchived()
    {
        var plain = new Reminder { Id = "p", Title = "p", Schedule = new ReminderSchedule { Kind = ReminderSchedule.Weekly } };
        StringAssert.Contains(Reminders.Canonical(plain), ",\"duringFocus\":false,\"fullSeconds\":");

        // 导出文件：两样都写，读回来一样
        var night = ReminderSync.Decode(MacNightShift)!;
        using var stream = new MemoryStream();
        using (var writer = new System.Text.Json.Utf8JsonWriter(stream))
        {
            Reminders.WriteArchive(writer, night);
        }

        var json = System.Text.Encoding.UTF8.GetString(stream.ToArray());
        StringAssert.Contains(json, "\"duringFocus\":true");
        StringAssert.Contains(json, "\"overnight\":true");
        using var document = System.Text.Json.JsonDocument.Parse(json);
        var back = Reminders.Read(document.RootElement)!;
        Assert.IsTrue(back.SameAs(night));
    }

    /// <summary>照 mac ReminderTests.windowCrossesMidnight。</summary>
    [TestMethod]
    public void Reminder_WindowCrossesMidnight()
    {
        var night = new ReminderSchedule
        {
            Kind = ReminderSchedule.Interval, Time = 22 * 60, Until = 6 * 60, Days = ReminderSchedule.Workdays.ToList(), Every = 60,
        };
        Assert.IsTrue(night.Sanitized().SameAs(night));
        Assert.AreEqual(480, night.WindowMinutes());
        DateTime? Next(DateTime anchor) => ReminderMath.NextFromAnchor(night, anchor, Zone);

        // 周一 22:30 → 23:30；半夜接着数（周一开始的那段）；6:00 出了时段 → 当天 22:00 + 60
        Assert.AreEqual(At(2, 23, 30), Next(At(2, 22, 30)));
        Assert.AreEqual(At(3, 1, 30), Next(At(3, 0, 30)));
        Assert.AreEqual(At(3, 23), Next(At(3, 5, 30)));
        Assert.AreEqual(At(3, 23), Next(At(3, 12)));
        // 周五晚上开始的那段到周六早上照响；周六晚上不响（周六没勾）：下一段是周一 22:00
        Assert.AreEqual(At(7, 3), Next(At(7, 2)));
        Assert.AreEqual(At(9, 23), Next(At(7, 5, 30)));
        Assert.AreEqual((At(6, 22), At(7, 6)), ReminderMath.WindowContaining(night, At(7, 3), Zone));
        // 周一 0:00–6:00 是周日开始的那段（周日没勾）
        Assert.IsNull(ReminderMath.WindowContaining(night, At(9, 3), Zone));

        // 23:00、5:59 在时段里，6:00 不在（PLAN-v26 第 10 批的验收，纯函数先锁住）
        Assert.IsNotNull(ReminderMath.WindowContaining(night, At(3, 23), Zone));
        Assert.IsNotNull(ReminderMath.WindowContaining(night, At(4, 5, 59), Zone));
        Assert.IsNull(ReminderMath.WindowContaining(night, At(4, 6), Zone));

        // 页头：8 小时、每 60 分钟不算「比间隔还短」；真的短的照报
        var reminder = new Reminder { Id = "n", Title = "夜班", Schedule = night };
        Assert.IsNull(Reminders.Problem(reminder, At(2, 8)));
        reminder.Schedule = new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 23 * 60 + 30, Until = 30, Every = 90 };
        Assert.AreEqual("这段时间比间隔还短，可能一次都不提醒", Reminders.Problem(reminder, At(2, 8)));
        // 收拾：结束和开始一样、0:00 都当到半夜
        Assert.AreEqual(1440, new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 540, Until = 540 }.Sanitized().Until);
        Assert.AreEqual(1440, new ReminderSchedule { Kind = ReminderSchedule.Interval, Time = 540, Until = 0 }.Sanitized().Until);
    }

    // ---- I2 翻译服务

    /// <summary>mac 0.10.3：开了讲解、写了附加要求的 AI 服务（键排好序：baseURL 之后是 explainsSentences、extraPrompt）。</summary>
    private const string MacExplainingService =
        "{\"aiProtocol\":\"openai\",\"baseURL\":\"https://api.deepseek.com/v1\",\"explainsSentences\":true," +
        "\"extraPrompt\":\"译文用简体中文，术语保留英文 / Keep \\\"API\\\"\",\"id\":\"ai:1a2b3c4d\",\"isEnabled\":true,\"kind\":\"ai\"," +
        "\"model\":\"deepseek-chat\",\"name\":\"DeepSeek\"}";

    [TestMethod]
    public void Service_MacSampleRoundTrips()
    {
        var plan = ServiceSync.Plan(new Dictionary<string, string?> { ["ai:1a2b3c4d"] = MacExplainingService },
            Array.Empty<SyncService>(), out var failure);
        Assert.IsNull(failure);
        Assert.IsNotNull(plan);
        var service = plan.Services.Single();
        Assert.AreEqual(true, service.ExplainsSentences);
        Assert.AreEqual("译文用简体中文，术语保留英文 / Keep \"API\"", service.ExtraPrompt);
        Assert.AreEqual(MacExplainingService, ServiceSync.Service(service));

        // 关着 / 空着不写：没设过的服务编出来和以前一字不差
        var plain = service with { ExplainsSentences = null, ExtraPrompt = null };
        Assert.IsFalse(ServiceSync.Service(plain).Contains("explains"));
        Assert.IsFalse(ServiceSync.Service(plain).Contains("extraPrompt"));
        // 不认识的键照旧整类停
        Assert.IsNull(ServiceSync.Plan(new Dictionary<string, string?>
        {
            ["ai:1a2b3c4d"] = MacExplainingService.Replace("\"id\"", "\"zzz\":1,\"id\""),
        }, Array.Empty<SyncService>(), out failure));
        Assert.AreEqual(ClipSync.Unreadable, failure);
    }

    [TestMethod]
    public void ExtraPrompt_StoredAndCleaned()
    {
        Assert.IsNull(ExtraPrompt.Stored(null));
        Assert.IsNull(ExtraPrompt.Stored("\0"));
        Assert.AreEqual("ab ", ExtraPrompt.Stored("a\0b "), "存的不去首尾空白：正在打的空格不吃掉");
        Assert.AreEqual("ab", ExtraPrompt.Cleaned(" a\0b \n"));
        Assert.IsNull(ExtraPrompt.Cleaned("  \n"));
        var emoji = string.Concat(Enumerable.Repeat("👍🏽", 1200));
        Assert.AreEqual(ExtraPrompt.MaxLength, new System.Globalization.StringInfo(ExtraPrompt.Stored(emoji)!).LengthInTextElements,
            "按字素截（同 Swift prefix），不切半个表情");
    }

    // ---- I3 片段的关键词

    /// <summary>mac 0.10.3：设了关键词的片段（keyword 排在 group 和 note 之间）。</summary>
    private const string MacKeywordSnippet =
        "{\"favorite\":false,\"keyword\":\";addr\",\"note\":\"地址\",\"snippet\":true,\"text\":\"上海市 / 浦东新区\\n{cursor}\"}";

    [TestMethod]
    public void Clip_MacKeywordSampleRoundTrips()
    {
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var plan = ClipSync.Plan(new Dictionary<string, string?> { [id] = MacKeywordSnippet },
            Array.Empty<SyncClipRow>(), Array.Empty<SyncClipGroup>(), 1000, out var failure);
        Assert.IsNull(failure);
        Assert.IsNotNull(plan);
        var write = plan.Writes.Single();
        Assert.AreEqual(";addr", write.Keyword);

        // 编回去一字不差；不是片段的不发关键词（同 mac：不起作用，发出去只会让旧版本白停）
        var row = new SyncClipRow(1, id, write.Text, write.Favorite, write.Snippet, write.Note, write.Group, write.CopiedAt, write.Keyword);
        Assert.AreEqual(MacKeywordSnippet, ClipSync.Values(new[] { row }, Array.Empty<SyncClipGroup>())[id]);
        var favorite = row with { Snippet = false, Favorite = true };
        Assert.IsFalse(ClipSync.Values(new[] { favorite }, Array.Empty<SyncClipGroup>())[id].Contains("keyword"));
        // 没设关键词的编出来和以前一样
        Assert.AreEqual(ClipSync.Clip("a", false, true, null, null), ClipSync.Clip("a", false, true, null, null, null));
    }

    [TestMethod]
    public void Clip_InvalidKeywordStopsTheKind()
    {
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        foreach (var bad in new[] { "a", "带汉字", "有 空格", new string('x', 33) })
        {
            var value = ClipSync.Clip("t", false, true, null, null, bad);
            Assert.IsNull(ClipSync.Plan(new Dictionary<string, string?> { [id] = value },
                Array.Empty<SyncClipRow>(), Array.Empty<SyncClipGroup>(), 1000, out var failure), bad);
            Assert.AreEqual(ClipSync.Unreadable, failure);
        }
    }

    [TestMethod]
    public void Clip_KeywordKeptWhenMergingSameText()
    {
        // 本机同正文、编号更小的那条留下：关键词缺的从来的那条补上（同 mac keeper.keyword ?? loser.keyword）
        var mine = "00000000-0000-0000-0000-000000000001";
        var theirs = "FFFFFFFF-0000-0000-0000-000000000001";
        var local = new SyncClipRow(7, mine, "同一段", false, true, null, null, 5);
        var plan = ClipSync.Plan(new Dictionary<string, string?> { [theirs] = ClipSync.Clip("同一段", false, true, null, null, ";same") },
            new[] { local }, Array.Empty<SyncClipGroup>(), 1, out _);
        Assert.IsNotNull(plan);
        var kept = plan.Writes.Single(write => write.Uid == mine);
        Assert.AreEqual(";same", kept.Keyword);
    }

    // ---- 走真的执行层：一个临时同步文件夹里一台假 Mac（照 0.10.3 写这三类）和两台 Windows，三类都不停（第 1 批的验收）

    [TestMethod]
    public void Folder_MacTenThreeRecordsDoNotStopAnyKind()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        Directory.CreateDirectory(folder);
        var snippetId = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var mac = new SyncNode("MAC-TEST", temp.Sub("mac"),
            new MemoryValueSource(ClipSync.Kind, ClipSync.JoinKey),
            new MemoryValueSource(ServiceSync.Kind, ServiceSync.JoinKey),
            new MemoryValueSource(ReminderSync.Kind, ReminderSync.JoinKey));
        var macMaps = mac.Sources.OfType<MemoryValueSource>().ToDictionary(source => source.Kind);
        macMaps[ClipSync.Kind].Map[snippetId] = MacKeywordSnippet;
        macMaps[ClipSync.Kind].Map[SyncEngine.OrderID] = SyncEngine.OrderValue(Array.Empty<string>());
        macMaps[ServiceSync.Kind].Map["ai:1a2b3c4d"] = MacExplainingService;
        macMaps[ServiceSync.Kind].Map[SyncEngine.OrderID] = SyncEngine.OrderValue(new[] { "ai:1a2b3c4d" });
        macMaps[ReminderSync.Kind].Map["N1"] = MacNightShift;
        macMaps[ReminderSync.Kind].Map[SyncEngine.OrderID] = SyncEngine.OrderValue(new[] { "N1" });

        SyncNode Windows(string name) => new(name, temp.Sub(name), new MemoryClipSource(), new MemoryServiceSource(), new MemoryReminderSource());
        var a = Windows("WIN-A");
        var b = Windows("WIN-B");
        long now = 1_764_000_000_000;
        foreach (var node in new[] { mac, a, b, a, b, mac })
        {
            var result = node.Round(folder, ref now);
            Assert.AreNotEqual("stopped", result.State, $"{node.Name}：{result.Message}");
        }

        foreach (var node in new[] { a, b })
        {
            Assert.AreEqual(";addr", node.Source<MemoryClipSource>().Rows.Single().Keyword, node.Name);
            var service = node.Source<MemoryServiceSource>().Services.Single();
            Assert.AreEqual(true, service.ExplainsSentences, node.Name);
            Assert.AreEqual(MacExplainingService, ServiceSync.Service(service), node.Name);
            var reminder = node.Source<MemoryReminderSource>().Stored!.Single();
            Assert.IsTrue(reminder.DuringFocus && reminder.Schedule.IsOvernight(), node.Name);
        }

        // 再合一轮谁都不写：Windows 编出来的和 Mac 的一字不差（不会被当成改了来回推）
        foreach (var node in new[] { a, b })
        {
            Assert.AreEqual(0, node.Round(folder, ref now).Written.Count, node.Name);
        }

        Assert.AreEqual(MacKeywordSnippet, macMaps[ClipSync.Kind].Map[snippetId]);
        Assert.AreEqual(MacNightShift, macMaps[ReminderSync.Kind].Map["N1"]);
    }

    // ---- SnippetKeyword（照 mac SnippetKeywordTests 的口径）

    [TestMethod]
    public void SnippetKeyword_Rules()
    {
        Assert.IsTrue(SnippetKeyword.IsValid(";ad"));
        Assert.IsTrue(SnippetKeyword.IsValid(new string('~', 32)));
        Assert.IsFalse(SnippetKeyword.IsValid(";"));
        Assert.IsFalse(SnippetKeyword.IsValid(new string('a', 33)));
        Assert.IsFalse(SnippetKeyword.IsValid("a b"));
        Assert.IsFalse(SnippetKeyword.IsValid("；ad"), "全角分号打不出来");
        Assert.IsNull(SnippetKeyword.Normalized("  \n"));
        Assert.AreEqual(";ad", SnippetKeyword.Normalized(" ;ad\t"));

        var others = new[] { new SnippetKeyword.Other(";addr", "地址"), new SnippetKeyword.Other(";s", "签名") };
        Assert.IsNull(SnippetKeyword.Evaluate("", others).Problem);
        Assert.AreEqual(0, SnippetKeyword.Evaluate("  ", others).Warnings.Count);
        Assert.AreEqual(SnippetKeyword.ProblemKind.Untypeable, SnippetKeyword.Evaluate("地址", others).Problem?.Kind);
        Assert.AreEqual(SnippetKeyword.ProblemKind.TooShort, SnippetKeyword.Evaluate("x", others).Problem?.Kind);
        Assert.AreEqual(SnippetKeyword.ProblemKind.TooLong, SnippetKeyword.Evaluate(new string('x', 33), others).Problem?.Kind);
        var duplicate = SnippetKeyword.Evaluate(";addr", others).Problem;
        Assert.AreEqual(SnippetKeyword.ProblemKind.Duplicate, duplicate?.Kind);
        Assert.AreEqual("和「地址」的关键词一样", SnippetKeyword.Message(duplicate!));
        Assert.IsNull(SnippetKeyword.Evaluate(";ADDR", others).Problem, "大小写严格");

        var hides = SnippetKeyword.Evaluate(";ad", others);
        Assert.IsNull(hides.Problem);
        Assert.AreEqual(new SnippetKeyword.Warning(SnippetKeyword.WarningKind.Hides, "地址"), hides.Warnings.Single());
        var hidden = SnippetKeyword.Evaluate(";sig", others);
        Assert.AreEqual(new SnippetKeyword.Warning(SnippetKeyword.WarningKind.HiddenBy, "签名"), hidden.Warnings.Single());
        Assert.AreEqual(SnippetKeyword.WarningKind.PlainWord, SnippetKeyword.Evaluate("addr", others).Warnings.Single().Kind);
        Assert.AreEqual("打普通单词时可能误展开，建议用 ; 开头", SnippetKeyword.Message(new SnippetKeyword.Warning(SnippetKeyword.WarningKind.PlainWord)));

        CollectionAssert.AreEquivalent(new[] { ";a" }, SnippetKeyword.Duplicates(new[] { ";a", ";b", ";a", ";a" }).ToList());
        Assert.AreEqual("地址", SnippetKeyword.Title("  地址 ", "正文"));
        Assert.AreEqual("第一行", SnippetKeyword.Title(null, "\n第一行\n第二行"));
        Assert.AreEqual(new string('长', 20) + "…", SnippetKeyword.Title(null, new string('长', 25)));
    }
}
