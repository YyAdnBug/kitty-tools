// 同步合并规则的 mac 用例移植（reference/mac-sync/SyncRecordsTests.swift 的 17 个），期望值原样。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncEngineTests
{
    private sealed class Mac
    {
        public Mac(string id, bool joining = false)
        {
            Id = id;
            Ledger = joining ? null : new SyncLedgerData();
        }

        public string Id { get; }

        public Dictionary<string, string> Local { get; set; } = new(StringComparer.Ordinal);

        public SyncLedgerData? Ledger { get; set; }

        public SyncFileData? Own { get; set; }

        public SyncOutcome Round(
            IEnumerable<Mac> others,
            long now,
            JoinMode join = JoinMode.Union,
            Func<string, string?>? dedupe = null,
            Dictionary<string, long>? changed = null,
            bool ownUnreadable = false)
        {
            var outcome = SyncEngine.Round(
                Local,
                changed ?? new Dictionary<string, long>(),
                Ledger,
                ownUnreadable ? null : Own,
                others.Select(mac => mac.Own).Where(file => file is not null).Cast<SyncFileData>().ToList(),
                Id,
                now,
                join,
                dedupe ?? (value => value));
            foreach (var (id, value) in outcome.Changes)
            {
                if (value is null)
                {
                    Local.Remove(id);
                }
                else
                {
                    Local[id] = value;
                }
            }

            Ledger = outcome.Ledger;
            Own = outcome.Own;
            return outcome;
        }
    }

    private static string Clock(SyncLedgerData? ledger, string id)
        => ledger is not null && ledger.Entries.TryGetValue(id, out var entry) ? entry.Clock.Text() : string.Empty;

    private static SyncLedgerData? Clone(SyncLedgerData? ledger)
    {
        if (ledger is null)
        {
            return null;
        }

        var copy = new SyncLedgerData();
        foreach (var (id, entry) in ledger.Entries)
        {
            copy.Entries[id] = new SyncEntry(SyncEngine.Clone(entry.Clock), entry.Hash, entry.Modified);
        }

        foreach (var (id, clock) in ledger.Erased)
        {
            copy.Erased[id] = SyncEngine.Clone(clock);
        }

        return copy;
    }

    private static SyncFileData? Clone(SyncFileData? file)
    {
        if (file is null)
        {
            return null;
        }

        var copy = new SyncFileData();
        foreach (var (id, value) in file.Records)
        {
            copy.Records[id] = new SyncValue
            {
                Value = value.Value,
                Clock = SyncEngine.Clone(value.Clock),
                Modified = value.Modified,
            };
        }

        foreach (var (id, clock) in file.Erased)
        {
            copy.Erased[id] = SyncEngine.Clone(clock);
        }

        return copy;
    }

    [TestMethod]
    public void NewItemsTravelAndEditsInOrderReplace()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["1"] = "一";
        a.Round(new[] { b }, 1);
        Assert.AreEqual("A:1", a.Own!.Records["1"].Clock.Text());
        b.Round(new[] { a }, 2);
        CollectionAssert.AreEqual(new[] { "一" }, b.Local.Values);
        b.Local["1"] = "一二";
        b.Round(new[] { a }, 3);
        var outcome = a.Round(new[] { b }, 4);
        Assert.AreEqual("一二", a.Local["1"]);
        Assert.AreEqual("一二", outcome.Changes["1"]);
        Assert.AreEqual("A:1,B:1", Clock(a.Ledger, "1"));
        Assert.AreEqual(0, a.Round(new[] { b }, 5).Changes.Count);
        Assert.AreEqual(0, b.Round(new[] { a }, 6).Changes.Count);
    }

    [TestMethod]
    public void ConcurrentEditsLaterWinsOnBothSides()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["1"] = "原来的";
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local["1"] = "A 改的";
        b.Local["1"] = "B 后改的";
        a.Round(new[] { b }, 10);
        b.Round(new[] { a }, 20);
        a.Round(new[] { b }, 30);
        Assert.AreEqual("B 后改的", a.Local["1"]);
        Assert.AreEqual("B 后改的", b.Local["1"]);
        Assert.AreEqual(Clock(a.Ledger, "1"), Clock(b.Ledger, "1"));
    }

    [TestMethod]
    public void DeletionTravelsButAConcurrentEditSurvives()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local = new Dictionary<string, string> { ["1"] = "删", ["2"] = "删了又被改" };
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local.Clear();
        b.Local["2"] = "B 改了";
        a.Round(new[] { b }, 3);
        CollectionAssert.AreEquivalent(new[] { "1", "2" }, a.Own!.Erased.Keys.ToList());
        var outcome = b.Round(new[] { a }, 4);
        Assert.AreEqual("B 改了", b.Local["2"]);
        Assert.AreEqual(1, outcome.Trashing);
        a.Round(new[] { b }, 5);
        Assert.AreEqual("B 改了", a.Local["2"]);
    }

    [TestMethod]
    public void RolledBackLedgerCatchesUp()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local = new Dictionary<string, string> { ["1"] = "一", ["2"] = "甲" };
        a.Round(new[] { b }, 1);
        var snapshot = new Mac("A") { Local = new Dictionary<string, string>(a.Local), Ledger = Clone(a.Ledger), Own = Clone(a.Own) };
        a.Local["1"] = "一二";
        a.Local["2"] = "甲乙";
        a.Round(new[] { b }, 2);
        b.Round(new[] { a }, 3);
        var restored = snapshot;
        restored.Own = a.Own;
        restored.Local["1"] = "一（恢复后）";
        restored.Round(new[] { b }, 4);
        Assert.AreEqual("A:3", Clock(restored.Ledger, "1"));
        Assert.AreEqual("一（恢复后）", restored.Local["1"]);
        Assert.AreEqual("甲乙", restored.Local["2"]);
        b.Round(new[] { restored }, 5);
        CollectionAssert.AreEquivalent(restored.Local, b.Local);
    }

    [TestMethod]
    public void JoiningDoesNotDuplicateOrOverrideTheFolder()
    {
        var a = new Mac("A");
        a.Local = new Dictionary<string, string> { ["a1"] = "同样的片段", ["a2"] = "新内容" };
        a.Round(Array.Empty<Mac>(), 1);
        var b = new Mac("B", joining: true) { Local = new Dictionary<string, string> { ["b1"] = "同样的片段", ["a2"] = "旧内容", ["b2"] = "只有 B 有" } };
        var outcome = b.Round(new[] { a }, 2);
        Assert.AreEqual("同样的片段", b.Local["a1"]);
        Assert.AreEqual("新内容", b.Local["a2"]);
        Assert.AreEqual("只有 B 有", b.Local["b2"]);
        Assert.AreEqual(0, outcome.Trashing);
        a.Round(new[] { b }, 3);
        CollectionAssert.AreEquivalent(b.Local, a.Local);
    }

    [TestMethod]
    public void SettingsAdoptTheExistingMacs()
    {
        var a = new Mac("A", joining: true) { Local = new Dictionary<string, string> { ["fontSize"] = "17", ["edge"] = "\"left\"" } };
        a.Round(Array.Empty<Mac>(), 1, JoinMode.Adopt);
        Assert.AreEqual(2, a.Own!.Records.Count);
        var b = new Mac("B", joining: true) { Local = new Dictionary<string, string> { ["fontSize"] = "13", ["sound"] = "false" } };
        var outcome = b.Round(new[] { a }, 2, JoinMode.Adopt);
        Assert.AreEqual("17", b.Local["fontSize"]);
        Assert.AreEqual("\"left\"", b.Local["edge"]);
        Assert.AreEqual(0, outcome.Trashing);
    }

    [TestMethod]
    public void AResetKeyCanBeSetAgain()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["k"] = "1";
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local.Clear();
        a.Round(new[] { b }, 3);
        b.Round(new[] { a }, 4);
        Assert.AreEqual(0, b.Local.Count);
        b.Local["k"] = "2";
        b.Round(new[] { a }, 5);
        a.Round(new[] { b }, 6);
        Assert.AreEqual("2", a.Local["k"]);
    }

    [TestMethod]
    public void BrakeCountsOnlyRealDeletions()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local = Enumerable.Range(0, 10).ToDictionary(index => index.ToString(), index => $"第 {index} 条");
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        foreach (var key in new[] { "0", "1", "2" })
        {
            a.Local.Remove(key);
        }

        a.Round(new[] { b }, 3);
        var outcome = b.Round(new[] { a }, 4);
        Assert.AreEqual(3, outcome.Trashing);
        Assert.AreEqual(10, outcome.Alive);
    }

    [TestMethod]
    public void ReAddedIDSurvivesAStaleThirdFile()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        var c = new Mac("C");
        a.Local["k"] = "1";
        a.Round(new[] { b, c }, 1);
        b.Round(new[] { a, c }, 2);
        c.Round(new[] { a, b }, 3);
        a.Local.Clear();
        a.Round(new[] { b, c }, 4);
        b.Round(new[] { a, c }, 5);
        a.Local["k"] = "2";
        a.Round(new[] { b, c }, 6);
        Assert.AreEqual("2", a.Local["k"]);
        b.Round(new[] { a, c }, 7);
        Assert.AreEqual("2", b.Local["k"]);
    }

    [TestMethod]
    public void TwoMacsSettingTheSameNewKeyLaterWins()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["k"] = "A 先设的";
        a.Round(new[] { b }, 10);
        b.Local["k"] = "B 后设的";
        b.Round(new[] { a }, 20);
        a.Round(new[] { b }, 30);
        Assert.AreEqual("B 后设的", a.Local["k"]);
        Assert.AreEqual("B 后设的", b.Local["k"]);
    }

    [TestMethod]
    public void RealChangeTimesDecide()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["k"] = "原来";
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local["k"] = "A 昨天改的";
        b.Local["k"] = "B 今天改的";
        b.Round(new[] { a }, 100, changed: new Dictionary<string, long> { ["k"] = 90 });
        a.Round(new[] { b }, 200, changed: new Dictionary<string, long> { ["k"] = 10 });
        b.Round(new[] { a }, 210);
        Assert.AreEqual("B 今天改的", a.Local["k"]);
        Assert.AreEqual("B 今天改的", b.Local["k"]);
    }

    [TestMethod]
    public void RollbackDoesNotLetAFastClockOldValueWin()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        var c = new Mac("C");
        c.Local["k"] = "v1";
        c.Round(new[] { a, b }, 10_000);
        a.Round(new[] { b, c }, 1);
        var snapshot = new Mac("A") { Local = new Dictionary<string, string>(a.Local), Ledger = Clone(a.Ledger), Own = Clone(a.Own) };
        b.Round(new[] { a, c }, 2);
        b.Local["k"] = "v2";
        b.Round(new[] { a, c }, 5_000);
        a.Round(new[] { b, c }, 6_000);
        var restored = snapshot;
        restored.Own = a.Own;
        restored.Round(new[] { b, c }, 7_000);
        Assert.AreEqual("v2", restored.Local["k"]);
    }

    [TestMethod]
    public void JoiningDedupesOnlyAgainstLiveVersions()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local = new Dictionary<string, string> { ["r"] = "foo", ["s"] = "bar" };
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local["r"] = "改掉了";
        a.Local.Remove("s");
        a.Round(new[] { b }, 3);
        var j = new Mac("J", joining: true) { Local = new Dictionary<string, string> { ["j1"] = "foo", ["j2"] = "bar" } };
        j.Round(new List<Mac> { a, b }, 4);
        Assert.AreEqual("foo", j.Local["j1"]);
        Assert.AreEqual("bar", j.Local["j2"]);
        Assert.AreEqual("改掉了", j.Local["r"]);
    }

    [TestMethod]
    public void UnicodeSpellingsSettle()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local["k"] = "caf\u00e9";
        b.Local["k"] = "cafe\u0301";
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Round(new[] { b }, 3);
        b.Round(new[] { a }, 4);
        var clock = Clock(a.Ledger, "k");
        Assert.AreEqual(0, a.Round(new[] { b }, 5).Changes.Count);
        Assert.AreEqual(0, b.Round(new[] { a }, 6).Changes.Count);
        Assert.AreEqual(clock, Clock(a.Ledger, "k"));
    }

    [TestMethod]
    public void AdoptDoesNotTripTheBrake()
    {
        var a = new Mac("A");
        var old = new Mac("O");
        a.Local = Enumerable.Range(0, 10).ToDictionary(index => $"k{index}", index => index.ToString());
        a.Round(new[] { old }, 1);
        old.Round(new[] { a }, 2);
        a.Local = new Dictionary<string, string> { ["k0"] = "0" };
        a.Round(new[] { old }, 3);
        var j = new Mac("J", joining: true)
        {
            Local = Enumerable.Range(0, 15).ToDictionary(index => $"k{index}", index => $"本机 {index}"),
        };
        var outcome = j.Round(new[] { a, old }, 4, JoinMode.Adopt);
        Assert.AreEqual("0", j.Local["k0"]);
        Assert.AreEqual(0, outcome.Trashing);
    }

    [TestMethod]
    public void UnreadableOwnFileAndErasingCount()
    {
        var a = new Mac("A");
        var b = new Mac("B");
        a.Local = new Dictionary<string, string> { ["1"] = "一", ["2"] = "二", ["3"] = "三" };
        a.Round(new[] { b }, 1);
        b.Round(new[] { a }, 2);
        a.Local["1"] = "一改";
        a.Round(new[] { b }, 3, ownUnreadable: true);
        Assert.AreEqual("A:2", Clock(a.Ledger, "1"));
        a.Local.Clear();
        var outcome = a.Round(new[] { b }, 4);
        Assert.AreEqual(3, outcome.Erasing);
    }

    /// <summary>文件的往返和读得严（照 mac 的 fileRoundTripAndStrictRead）：同样的内容同样的字节，
    /// 怪字符原样存；类别不对、编号重复、钟写坏了、结构对不上都算读不出来；format 更大又结构对的是「更新版本写的」。</summary>
    [TestMethod]
    public void FileRoundTripAndStrictRead()
    {
        var odd = "引号\"、换行\n、NUL\0、\u2028、👩‍👩‍👧、" + new string('长', 100_000);
        var file = new SyncFile { Kind = "clips" };
        file.Records.Add(new SyncRecord
        {
            Id = "x", Value = """{"text":"你好"}""", Clock = SyncClock.Parse("A:2,B:1"), Modified = 1234,
        });
        file.Records.Add(new SyncRecord
        {
            Id = "z", Value = odd, Clock = SyncClock.Parse("B:1"), Modified = 1,
        });
        file.Erased.Add(new SyncErased { Id = "y", Clock = SyncClock.Parse("A:1") });
        var data = file.Encode();
        var back = SyncFile.Decode(data, "clips");
        Assert.IsNotNull(back);
        Assert.IsFalse(back!.IsNewer);
        Assert.AreEqual(data, back.Encode(), "同样的内容同样的字节");
        Assert.AreEqual(odd, back.Records.Single(record => record.Id == "z").Value);
        Assert.AreEqual(2, back.Records.Count);
        Assert.AreEqual(1, back.Erased.Count);

        // 换个顺序建的同一份：同样的字节。
        var reordered = new SyncFile { Kind = "clips" };
        reordered.Erased.Add(new SyncErased { Id = "y", Clock = SyncClock.Parse("A:1") });
        reordered.Records.Add(back.Records.Single(record => record.Id == "z"));
        reordered.Records.Add(back.Records.Single(record => record.Id == "x"));
        Assert.AreEqual(data, reordered.Encode());

        Assert.IsNull(SyncFile.Decode(data, "vocabulary"));
        var newer = """{"format":99,"kind":"clips","records":[],"erased":[],"extra":1}""";
        var newerFile = SyncFile.Decode(newer, "clips");
        Assert.IsNotNull(newerFile);
        Assert.IsTrue(newerFile!.IsNewer);
        // 结构对不上的、别的类别的：不算更新版本。
        Assert.IsNull(SyncFile.Decode("""{"format":2,"kind":"clips","records":{}}""", "clips"));
        Assert.IsNull(SyncFile.Decode(newer, "settings"));
        Assert.IsNull(SyncFile.Decode(
            """{"format":1,"kind":"clips","erased":[],"records":[{"id":"x","clock":"A:1,B:x","modified":1,"value":"1"}]}""",
            "clips"));
        Assert.IsNull(SyncFile.Decode(
            """{"format":1,"kind":"clips","erased":[],"records":[{"id":"x","clock":"A:1","modified":1,"value":"1"},{"id":"x","clock":"A:2","modified":2,"value":"2"}]}""",
            "clips"));
        Assert.IsNull(SyncFile.Decode("{", "clips"));

        // 同一编号在 records 和 erased 里都有（别处删过、本机又改回来了）是合法的：两个列表各自查重；
        // 共用一套会把这一份整份当成读不出来，几台就合不到一起（集成测试抓到的）。
        var both = new SyncFile { Kind = "clips" };
        both.Records.Add(new SyncRecord { Id = "x", Value = "{}", Clock = SyncClock.Parse("A:2"), Modified = 2 });
        both.Erased.Add(new SyncErased { Id = "x", Clock = SyncClock.Parse("A:1") });
        var bothText = both.Encode();
        var bothBack = SyncFile.Decode(bothText, "clips");
        Assert.IsNotNull(bothBack);
        Assert.AreEqual(bothText, bothBack!.Encode());
        Assert.IsNull(SyncFile.Decode(
            """{"format":1,"kind":"clips","erased":[{"clock":"A:1","id":"x"},{"clock":"A:2","id":"x"}],"records":[]}""",
            "clips"));
    }
}
