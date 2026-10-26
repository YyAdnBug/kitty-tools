// REVIEW R26 §2：`275ea952` 修的那几处「会删到每一台」的问题，每一处一个用例。编出去 / 落回来走 Core 的四类规则，
// 一轮走 Core 的 SyncRunner（临时同步文件夹），不再只测引擎加手写的值。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncSourceTests
{
    private const string Small = "11111111-1111-4111-8111-111111111111";
    private const string Large = "99999999-9999-4999-8999-999999999999";

    // ---- 仓库没起来 → 这一类不合 ----

    [TestMethod]
    public void UnavailableStoreSkipsTheKindInsteadOfErasingEverything()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var clips = new MemoryClipSource();
        for (var index = 0; index < 8; index++)
        {
            clips.Add("条目 " + index);
        }

        var node = new SyncNode("WIN-A", temp.Sub("a"), clips);
        long now = 0;
        Assert.AreEqual("idle", node.Round(folder, ref now).State);
        var ownPath = Path.Combine(folder, SyncDisk.KindPath("WIN-A", ClipSync.Kind));
        var before = File.ReadAllText(ownPath);
        var ledger = clips.LedgerText;

        clips.Unavailable = true;
        var result = node.Round(folder, ref now, confirmBrakes: false);

        Assert.AreEqual("idle", result.State, "跳过的那一类不算出错");
        Assert.AreEqual(before, File.ReadAllText(ownPath), "没起来的那一类不该写出墓碑");
        Assert.AreEqual(ledger, clips.LedgerText, "账本也不动");
        Assert.IsFalse(File.ReadAllText(ownPath).Contains("\"erased\":[{"), "文件里不该有墓碑");
    }

    // ---- 收藏夹同名 → 编号小的留下、条目归过去 ----

    [TestMethod]
    public void SameNamedGroupKeepsTheSmallerIdAndMovesItsClips()
    {
        var clips = new MemoryClipSource();
        clips.Groups.Add(new SyncClipGroup(Large, "工作", 1));
        var mine = clips.Add("本机收藏夹里的", group: Large);

        // 别处来了一个同名、编号更小的：本机那个让位，条目归进来的那个。
        var changes = new Dictionary<string, string?>
        {
            [ClipSync.GroupPrefix + Small] = ClipSync.Group("工作", 2),
        };
        var plan = ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out var failure);
        Assert.IsNull(failure);
        Assert.AreEqual(1, plan!.Groups.Count);
        Assert.AreEqual(Small, plan.Groups[0].Id);
        Assert.AreEqual(Small, plan.Writes.Single(write => write.Row == mine.Row).Group);

        // 反过来：来的编号大，留本机的；来的条目归进本机那个。
        clips = new MemoryClipSource();
        clips.Groups.Add(new SyncClipGroup(Small, "工作", 1));
        var incomingClip = MemoryClipSource.NewUid();
        changes = new Dictionary<string, string?>
        {
            [ClipSync.GroupPrefix + Large] = ClipSync.Group("工作", 2),
            [incomingClip] = ClipSync.Clip("别处收藏夹里的", true, false, null, Large),
        };
        plan = ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out failure);
        Assert.IsNull(failure);
        Assert.AreEqual(Small, plan!.Groups.Single().Id);
        Assert.AreEqual(Small, plan.Writes.Single(write => write.Uid == incomingClip).Group);
    }

    [TestMethod]
    public void DeletedGroupWithASameNamedSurvivorMovesItsClipsThere()
    {
        var clips = new MemoryClipSource();
        clips.Groups.Add(new SyncClipGroup(Small, "工作", 1));
        clips.Groups.Add(new SyncClipGroup(Large, "工作 2", 2));
        var item = clips.Add("在大的那个里", group: Large);
        // 别处把 Large 删了、又把 Small 改名成「工作 2」：条目跟着名字归进 Small。
        var changes = new Dictionary<string, string?>
        {
            [ClipSync.GroupPrefix + Large] = null,
            [ClipSync.GroupPrefix + Small] = ClipSync.Group("工作 2", 1),
        };
        var plan = ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out _);
        Assert.AreEqual(Small, plan!.Writes.Single(write => write.Row == item.Row).Group);
    }

    // ---- 只是片段的条目要交出去 ----

    [TestMethod]
    public void SnippetOnlyAndGroupedClipsAreSyncedButPlainHistoryIsNot()
    {
        var clips = new MemoryClipSource();
        var snippet = clips.Add("只是片段", favorite: false, snippet: true);
        var grouped = clips.Add("在收藏夹里", favorite: true, group: Small);
        clips.Groups.Add(new SyncClipGroup(Small, "工作", 1));
        var plain = clips.Add("普通历史", favorite: false);
        var withNul = clips.Add("带\0NUL");

        var values = ClipSync.Values(clips.Rows, clips.Groups);
        Assert.IsTrue(values.ContainsKey(snippet.Uid!), "只是片段的也要交");
        Assert.AreEqual("{\"favorite\":false,\"snippet\":true,\"text\":\"只是片段\"}", values[snippet.Uid!]);
        Assert.IsTrue(values.ContainsKey(grouped.Uid!));
        Assert.IsFalse(values.ContainsKey(plain.Uid!), "普通历史不同步");
        Assert.IsFalse(values.ContainsKey(withNul.Uid!), "带 NUL 的不同步");
        Assert.AreEqual("[\"group:" + Small + "\"]", values[SyncEngine.OrderID]);
        Assert.IsTrue(ClipSync.Values(new List<SyncClipRow>(), new List<SyncClipGroup>())
            .ContainsKey(SyncEngine.OrderID), "收藏夹是空表时也交 ~order");
    }

    // ---- 有一条解不开 → 整类不落、不存账本 ----

    [TestMethod]
    public void OneUnreadableRecordRefusesTheWholeKindAndKeepsTheLedger()
    {
        var clips = new MemoryClipSource();
        var good = MemoryClipSource.NewUid();
        var bad = MemoryClipSource.NewUid();
        var changes = new Dictionary<string, string?>
        {
            [good] = ClipSync.Clip("能读的", true, false, null, null),
            // 更新版本多写了一个字段：解得开，但编回去少了它。
            [bad] = "{\"extra\":1,\"favorite\":true,\"snippet\":false,\"text\":\"新版本写的\"}",
        };
        Assert.IsNull(ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out var failure));
        Assert.AreEqual(ClipSync.Unreadable, failure);

        // 走一整轮：别的电脑的文件里有一条更新版本写的（规范写法，引擎收；仓库落不下）。
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var node = new SyncNode("WIN-A", temp.Sub("a"), clips);
        clips.Add("本机的");
        long now = 0;
        node.Round(folder, ref now);
        var ledger = clips.LedgerText;
        var ownPath = Path.Combine(folder, SyncDisk.KindPath("WIN-A", ClipSync.Kind));
        var own = File.ReadAllText(ownPath);
        WritePeer(folder, "MAC-1", ClipSync.Kind, new Dictionary<string, string>
        {
            [good] = changes[good]!,
            [bad] = changes[bad]!,
        });

        var result = node.Round(folder, ref now, confirmBrakes: false);
        Assert.AreEqual("stopped", result.State);
        Assert.AreEqual(ClipSync.Unreadable, result.Message);
        Assert.AreEqual(ledger, clips.LedgerText, "落不下就不存账本");
        Assert.AreEqual(own, File.ReadAllText(ownPath), "也不写自己那份");
        Assert.IsFalse(clips.Rows.Any(row => row.Text == "能读的"), "能读的那条也不落（整类不落）");
    }

    // ---- 编 → 落 → 再编，字节一样 ----

    [TestMethod]
    public void BlankNoteSurvivesEncodeApplyEncode()
    {
        foreach (var note in new[] { "  ", "", "tab\t\tend ", "\n" })
        {
            var clips = new MemoryClipSource();
            var uid = MemoryClipSource.NewUid();
            var value = ClipSync.Clip("正文", true, false, note, null);
            var plan = ClipSync.Plan(
                new Dictionary<string, string?> { [uid] = value }, clips.Rows, clips.Groups, 0, out _);
            clips.Execute(plan!);
            Assert.AreEqual(value, ClipSync.Values(clips.Rows, clips.Groups)[uid], $"备注「{note}」");
        }
    }

    [TestMethod]
    public void WordWithSurroundingSpacesSurvivesEncodeApplyEncode()
    {
        var words = new MemoryWordSource();
        var id = MemoryClipSource.NewUid();
        var value = VocabularySync.Word("  hello  ", "zh-Hans", " 你好 ", "zhipu", 1_761_300_000_000);
        var ops = VocabularySync.Plan(
            new Dictionary<string, string?> { [id] = value }, words.Rows, out var failure);
        Assert.IsNull(failure);
        Assert.AreEqual("  hello  ", ops!.Single().Word!.Source, "原文不 Trim");
        words.Rows.Add(ops!.Single().Word!);
        Assert.AreEqual(value, VocabularySync.Values(words.Rows)[id]);
    }

    [TestMethod]
    public void ServiceWithoutProtocolSurvivesEncodeApplyEncode()
    {
        foreach (var value in new[]
                 {
                     "{\"id\":\"google\",\"isEnabled\":true,\"kind\":\"google\",\"name\":\"Google 翻译\"}",
                     "{\"id\":\"google\",\"isEnabled\":false,\"kind\":\"google\",\"name\":\"Google 翻译\"}",
                     // 空串照写（写成空串的那台不会被当成「这一版读不懂」）。
                     "{\"baseURL\":\"\",\"id\":\"ai:1a2b3c4d\",\"isEnabled\":false,\"kind\":\"ai\",\"model\":\"\",\"name\":\"AI\"}",
                 })
        {
            var id = value.Contains("google") ? "google" : "ai:1a2b3c4d";
            var plan = ServiceSync.Plan(
                new Dictionary<string, string?> { [id] = value }, new List<SyncService>(), out var failure);
            Assert.IsNull(failure, value);
            Assert.IsNull(plan!.Services.Single().Protocol, "没写协议就是没有，不补 openai");
            Assert.AreEqual(value, ServiceSync.Values(plan.Services)[id]);
        }
    }

    [TestMethod]
    public void GoldenSamplesRoundTripThroughTheWindowsEncoders()
    {
        using var document = System.Text.Json.JsonDocument.Parse(
            File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "sync-golden.json")));
        var checkedCount = 0;
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (!item.TryGetProperty("json", out var jsonElement) || jsonElement.GetString() is not { } json)
            {
                continue;
            }

            var kind = item.GetProperty("kind").GetString();
            var id = MemoryClipSource.NewUid();
            switch (kind)
            {
                case "clip":
                {
                    // 有收藏夹的样本：先把那个收藏夹建好（mac 的条目里只写收藏夹的编号本身，R26 §4）。
                    var groups = new List<SyncClipGroup>();
                    if (json.Contains("\"group\":\"0F8FAD5B-D9CB-469F-A165-70867728950E\""))
                    {
                        groups.Add(new SyncClipGroup("0F8FAD5B-D9CB-469F-A165-70867728950E", "收藏", 1));
                    }

                    var plan = ClipSync.Plan(
                        new Dictionary<string, string?> { [id] = json }, new List<SyncClipRow>(), groups, 0,
                        out var failure);
                    Assert.IsNull(failure, json);
                    var write = plan!.Writes.Single();
                    // mac 的规矩：在收藏夹里的就是收藏（样本里 favorite:false 的落下来会变成 true）。
                    var expected = write.Group is not null
                        ? json.Replace("\"favorite\":false", "\"favorite\":true")
                        : json;
                    Assert.AreEqual(expected, ClipSync.Clip(write.Text, write.Favorite, write.Snippet, write.Note, write.Group));
                    checkedCount++;
                    break;
                }

                case "word":
                {
                    var ops = VocabularySync.Plan(
                        new Dictionary<string, string?> { [id] = json }, new List<SyncWordRow>(), out var failure);
                    Assert.IsNull(failure, json);
                    Assert.AreEqual(json, VocabularySync.Values(new[] { ops!.Single().Word! })[id]);
                    checkedCount++;
                    break;
                }

                case "group":
                {
                    var plan = ClipSync.Plan(
                        new Dictionary<string, string?> { [ClipSync.GroupPrefix + id] = json },
                        new List<SyncClipRow>(), new List<SyncClipGroup>(), 0, out var failure);
                    Assert.IsNull(failure, json);
                    var group = plan!.Groups.Single();
                    Assert.AreEqual(json, ClipSync.Group(group.Name, group.Created));
                    checkedCount++;
                    break;
                }

                case "engine":
                {
                    var engines = EngineSync.Plan(
                        new Dictionary<string, string?> { ["custom"] = json },
                        new List<KittyTools.Core.SearchEngine>(), out var failure);
                    Assert.IsNull(failure, json);
                    Assert.AreEqual(json, EngineSync.Values(engines!)["custom"]);
                    checkedCount++;
                    break;
                }

                case "service":
                {
                    // R32：mac 会写 usesDeepLX:false / model:"" / baseURL:""，落下来再编要一模一样。
                    using var serviceDocument = System.Text.Json.JsonDocument.Parse(json);
                    var serviceId = serviceDocument.RootElement.GetProperty("id").GetString()!;
                    var plan = ServiceSync.Plan(
                        new Dictionary<string, string?> { [serviceId] = json },
                        new List<SyncService>(), out var failure);
                    Assert.IsNull(failure, json);
                    var encoded = ServiceSync.Values(plan!.Services)[serviceId];
                    Assert.AreEqual(json, encoded, encoded);
                    checkedCount++;
                    break;
                }
            }
        }

        Assert.IsTrue(checkedCount >= 30, $"checked {checkedCount}");
    }

    // ---- 正文撞上已经留着的条目时不抢它的 uid ----

    [TestMethod]
    public void TextCollisionKeepsTheSmallerIdAndNeverStealsARetainedUid()
    {
        // 本机留着的编号小：留本机的，来的这条不落，本机那条的 uid 不变。
        var clips = new MemoryClipSource();
        var mine = clips.Add("同一段文字", uid: Small, note: null);
        var changes = new Dictionary<string, string?>
        {
            [Large] = ClipSync.Clip("同一段文字", false, true, "来的备注", null),
        };
        clips.Execute(ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out _)!);
        var kept = clips.Rows.Single(row => row.Text == "同一段文字");
        Assert.AreEqual(Small, kept.Uid, "不抢本机那条的 uid");
        Assert.AreEqual(mine.Row, kept.Row);
        Assert.IsTrue(kept.Favorite && kept.Snippet, "收藏、片段取并集");
        Assert.AreEqual("来的备注", kept.Note, "缺的备注补上");

        // 来的编号小：留来的，本机那条让位（只剩一条，下一轮本机那条的删除传出去）。
        clips = new MemoryClipSource();
        clips.Add("同一段文字", uid: Large);
        changes = new Dictionary<string, string?>
        {
            [Small] = ClipSync.Clip("同一段文字", true, false, null, null),
        };
        clips.Execute(ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out _)!);
        Assert.AreEqual(Small, clips.Rows.Single(row => row.Text == "同一段文字").Uid);

        // 撞上的是没留着的普通条目：来的接过那一行，不多出一条。
        clips = new MemoryClipSource();
        var plain = clips.Add("复制过的", favorite: false, uid: null);
        clips.Replace(plain with { Uid = null });
        changes = new Dictionary<string, string?>
        {
            [Large] = ClipSync.Clip("复制过的", true, false, null, null),
        };
        clips.Execute(ClipSync.Plan(changes, clips.Rows, clips.Groups, 0, out _)!);
        var taken = clips.Rows.Single();
        Assert.AreEqual(plain.Row, taken.Row, "接过那一行");
        Assert.AreEqual(Large, taken.Uid);
        Assert.IsTrue(taken.Favorite);
    }

    [TestMethod]
    public void UnretainedElsewhereOnlyUnfavoritesLocally()
    {
        var clips = new MemoryClipSource();
        clips.Groups.Add(new SyncClipGroup(Small, "工作", 1));
        var item = clips.Add("别处不要了", snippet: true, group: Small);
        clips.Execute(ClipSync.Plan(
            new Dictionary<string, string?> { [item.Uid!] = null }, clips.Rows, clips.Groups, 0, out _)!);
        var row = clips.Rows.Single();
        Assert.AreEqual(item.Row, row.Row, "不删行，还在历史里");
        Assert.IsFalse(row.Favorite || row.Snippet || row.Group is not null);
    }

    [TestMethod]
    public void VocabularyCollisionKeepsTheSmallerId()
    {
        var words = new MemoryWordSource();
        words.Add("hello", "zh-Hans", "你好", id: Small);
        var ops = VocabularySync.Plan(new Dictionary<string, string?>
        {
            [Large] = VocabularySync.Word("hello", "zh-Hans", "哈喽", "zhipu", 1),
        }, words.Rows, out _);
        Assert.AreEqual(SyncWordStep.Delete, ops!.Single().Step, "本机那条编号小：来的这条不落");

        words = new MemoryWordSource();
        words.Add("hello", "zh-Hans", "你好", id: Large);
        ops = VocabularySync.Plan(new Dictionary<string, string?>
        {
            [Small] = VocabularySync.Word("hello", "zh-Hans", "哈喽", "zhipu", 1),
        }, words.Rows, out _);
        Assert.AreEqual(SyncWordStep.Replace, ops!.Single().Step, "来的编号小：换掉本机那条");
    }

    // ---- 本机删一大批（erasing）也要刹车，等确认的状态不被盖掉 ----

    [TestMethod]
    public void LocalMassDeletionBrakesUntilConfirmedAndOnlyForThatMany()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var clips = new MemoryClipSource();
        var words = new MemoryWordSource();
        for (var index = 0; index < 30; index++)
        {
            clips.Add("条目 " + index);
        }

        words.Add("hello", "zh-Hans", "你好");
        var node = new SyncNode("WIN-A", temp.Sub("a"), clips, words);
        long now = 0;
        Assert.AreEqual("idle", node.Round(folder, ref now).State);
        var ownPath = Path.Combine(folder, SyncDisk.KindPath("WIN-A", ClipSync.Kind));
        var published = File.ReadAllText(ownPath);
        var ledger = clips.LedgerText;

        // 本机一下删掉 25 条（比如库被清空了一半）：先问。
        clips.Rows.RemoveRange(0, 25);
        words.Add("world", "zh-Hans", "世界");
        var result = node.Round(folder, ref now, confirmBrakes: false);
        Assert.AreEqual("confirm", result.State);
        Assert.AreEqual(25, result.Waiting[ClipSync.Kind]);
        Assert.AreEqual(published, File.ReadAllText(ownPath), "没确认之前不把删除写出去");
        Assert.AreEqual(ledger, clips.LedgerText, "账本也不动");
        Assert.IsTrue(File.ReadAllText(Path.Combine(folder, SyncDisk.KindPath("WIN-A", VocabularySync.Kind)))
            .Contains("world"), "别的类照常合、照常写");

        // 再来一轮还是「等确认」（不被别的类的「好了」盖掉）。
        now += 1000;
        result = new SyncRunner(node.Device, node.Sources, "WIN-A")
            .RunAsync(folder, new Dictionary<string, int>(), now).GetAwaiter().GetResult();
        Assert.AreEqual("confirm", result.State);

        // 额度比要删的少：照样停。
        now += 1000;
        result = new SyncRunner(node.Device, node.Sources, "WIN-A")
            .RunAsync(folder, new Dictionary<string, int> { [ClipSync.Kind] = 24 }, now).GetAwaiter().GetResult();
        Assert.AreEqual("confirm", result.State);

        // 点了「继续」（额度 = 当时要删的 25 条）：放行，墓碑写出去。
        now += 1000;
        result = new SyncRunner(node.Device, node.Sources, "WIN-A")
            .RunAsync(folder, new Dictionary<string, int> { [ClipSync.Kind] = 25 }, now).GetAwaiter().GetResult();
        Assert.AreEqual("idle", result.State);
        var file = SyncFile.Decode(File.ReadAllText(ownPath), ClipSync.Kind)!;
        Assert.AreEqual(25, file.Erased.Count);
    }

    [TestMethod]
    public void TrashingFromElsewhereBrakesToo()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var a = new SyncNode("WIN-A", temp.Sub("a"), new MemoryClipSource());
        var b = new SyncNode("WIN-B", temp.Sub("b"), new MemoryClipSource());
        for (var index = 0; index < 10; index++)
        {
            a.Source<MemoryClipSource>().Add("条目 " + index);
        }

        long now = 0;
        a.Round(folder, ref now);
        b.Round(folder, ref now);
        Assert.AreEqual(10, b.Source<MemoryClipSource>().Rows.Count);

        // A 删了 8 条（A 自己点了继续），B 那边就要被删掉 8 / 10：B 也先问。
        a.Source<MemoryClipSource>().Rows.RemoveRange(0, 8);
        a.Round(folder, ref now);
        var result = b.Round(folder, ref now, confirmBrakes: false);
        Assert.AreEqual("confirm", result.State);
        Assert.AreEqual(10, b.Source<MemoryClipSource>().Rows.Count(row => row.Favorite), "没确认之前 B 一条都不动");
    }

    // ---- 账本 ----

    [TestMethod]
    public void LedgerTextRoundTripsMigratesTheOldFormatAndRejectsGarbage()
    {
        var ledger = new SyncLedgerData();
        ledger.Entries["B"] = new SyncEntry(SyncClock.Parse("WIN-A:2"), "hash-b", 7);
        ledger.Entries["A"] = new SyncEntry(SyncClock.Parse("MAC-1:1,WIN-A:1"), "hash-a", 3);
        ledger.Erased["C"] = SyncClock.Parse("WIN-A:4");
        var text = SyncLedgerText.Encode(ledger);
        Assert.AreEqual(
            "{\"entries\":{\"A\":{\"clock\":\"MAC-1:1,WIN-A:1\",\"hash\":\"hash-a\",\"modified\":3}," +
            "\"B\":{\"clock\":\"WIN-A:2\",\"hash\":\"hash-b\",\"modified\":7}},\"erased\":{\"C\":\"WIN-A:4\"}}",
            text);
        Assert.AreEqual(text, SyncLedgerText.Encode(SyncLedgerText.Decode(text)!));

        var old = SyncLedgerText.Decode("{\"A\":\"WIN-A:3|abc\",\"~clock\":\"9\"}")!;
        Assert.AreEqual(3, old.Entries["A"].Clock["WIN-A"]);
        Assert.AreEqual(0, old.Entries["A"].Modified);
        Assert.IsNull(SyncLedgerText.Decode(null));

        Assert.ThrowsExactly<FormatException>(() => SyncLedgerText.Decode("{ 写坏了"));
        Assert.ThrowsExactly<FormatException>(() => SyncLedgerText.Decode("{\"entries\":{\"A\":{\"clock\":1}}}"));
    }

    [TestMethod]
    public void UnreadableLedgerStopsTheKindInsteadOfJoiningAgain()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var clips = new MemoryClipSource();
        clips.Add("一条");
        var node = new SyncNode("WIN-A", temp.Sub("a"), clips);
        long now = 0;
        node.Round(folder, ref now);
        clips.LedgerText = "{ 写坏了";
        var result = node.Round(folder, ref now);
        Assert.AreEqual("stopped", result.State);
        Assert.AreEqual("片段与收藏的同步记录读不出来", result.Message);
    }

    // ---- 执行层的几件小事 ----

    [TestMethod]
    public void QuietRoundsWriteNothing()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var clips = new MemoryClipSource();
        clips.Add("一条");
        var node = new SyncNode("WIN-A", temp.Sub("a"), clips, new MemoryEngineSource());
        long now = 0;
        var first = node.Round(folder, ref now);
        CollectionAssert.AreEquivalent(new[] { ClipSync.Kind, EngineSync.Kind }, first.Written);
        var epoch = node.Device.Epoch;
        var devicePath = Path.Combine(folder, SyncDisk.DevicePath("WIN-A"));
        var stamp = File.GetLastWriteTimeUtc(devicePath);

        var second = node.Round(folder, ref now);
        Assert.AreEqual(0, second.Written.Count, "没变就不重写（云盘不用每 20 秒传一遍）");
        Assert.AreEqual(epoch, node.Device.Epoch, "没写东西 epoch 不涨");
        Assert.AreEqual(stamp, File.GetLastWriteTimeUtc(devicePath));
        Assert.AreEqual(1, clips.Applied, "改动是空的、账本也没变：不落");
    }

    [TestMethod]
    public void ForeignOrMissingFoldersStop()
    {
        using var temp = new TempFolder();
        var node = new SyncNode("WIN-A", temp.Sub("a"), new MemoryClipSource());
        long now = 0;
        Assert.AreEqual("文件夹不在了", node.Round(Path.Combine(temp.Path, "nope"), ref now).Message);
        var foreign = temp.Sub("foreign");
        File.WriteAllText(Path.Combine(foreign, "别人的.txt"), "x");
        Assert.AreEqual("这个文件夹里已经有别的东西了", node.Round(foreign, ref now).Message);
        Assert.AreEqual(1, Directory.EnumerateFileSystemEntries(foreign).Count(), "不碰别人的文件夹");
    }

    [TestMethod]
    public void DuplicateAiServicesJoinAndMoveTheKey()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var a = new SyncNode("WIN-A", temp.Sub("a"), new MemoryServiceSource());
        var b = new SyncNode("WIN-B", temp.Sub("b"), new MemoryServiceSource());
        a.Source<MemoryServiceSource>().Services.Add(
            new SyncService("ai:aaaaaaaa", "ai", "DeepSeek", true, "deepseek-chat", "https://api.deepseek.com/v1",
                "openai", null, false));
        b.Source<MemoryServiceSource>().Services.Add(
            new SyncService("ai:bbbbbbbb", "ai", "我的 DeepSeek", true, "deepseek-chat", "https://api.deepseek.com/v1",
                "openai", null, false));
        long now = 0;
        a.Round(folder, ref now);
        b.Round(folder, ref now);
        a.Round(folder, ref now);
        Assert.AreEqual("ai:aaaaaaaa", b.Source<MemoryServiceSource>().Services.Single().Id, "同协议 + 地址 + 模型只留一个");
        Assert.AreEqual(new SyncSecretMove("ai:bbbbbbbb", "ai:aaaaaaaa"), b.Source<MemoryServiceSource>().Moves.Single());
    }

    private static void WritePeer(string folder, string device, string kind, Dictionary<string, string> values)
    {
        var file = new SyncFile { Kind = kind };
        foreach (var (id, value) in values)
        {
            file.Records.Add(new SyncRecord
            {
                Id = id, Clock = SyncClock.Parse(device + ":1"), Modified = 1_761_300_000_000, Value = value,
            });
        }

        var path = Path.Combine(folder, SyncDisk.KindPath(device, kind));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, file.Encode());
        File.WriteAllText(Path.Combine(folder, SyncDisk.DevicePath(device)), SyncFolderRules.DeviceJson(1, device));
    }
}
