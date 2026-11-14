// 新功能标记（PLAN-v16 G3，照 mac WhatsNewTests）：清单的规矩、新装不标、跳着升级中间几版一起标、30 天 / 碰过 / 功能关着就不标、
// 升到下一版旧的没了、换页时看着的那页不闪掉、碰过没变化时原样。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class WhatsNewTests
{
    private const long Day = 24L * 60 * 60 * 1000;
    private const long T0 = 1_800_000_000_000;
    private static readonly HashSet<string> All = new() { "clipboard", "translate", "launcher", "screenshot", "recording", "notes", "statusScreen", "reminders" };

    private static readonly WhatsNewEntry[] Sample =
    {
        new("a", "0.7.0", "clipboard", new[] { "pinClipboard" }, null),
        new("b", "0.8.0", null, System.Array.Empty<string>(), "general", "功能"),
        new("c", "0.9.0", "reminders", new[] { "reminderNew" }, "reminders"),
    };

    private static Dictionary<string, long> Started(WhatsNewLedger ledger) => ledger.Started.ToDictionary(pair => pair.Key, pair => pair.Value);

    [TestMethod]
    public void EntriesAreWellFormed()
    {
        var entries = WhatsNew.Entries;
        Assert.AreEqual(entries.Count, entries.Select(entry => entry.Id).Distinct().Count());
        foreach (var version in entries.Select(entry => entry.Version).Distinct())
        {
            Assert.IsTrue(entries.Count(entry => entry.Version == version) <= WhatsNew.PerVersion, version);
        }

        foreach (var entry in entries)
        {
            Assert.IsTrue(entry.Actions.Count > 0 || entry.Page is not null, entry.Id);
            Assert.IsTrue(entry.Section is null || entry.Page is not null, entry.Id);
            // 还没发布：比 0.1.2（Windows 最后发的一版）新
            Assert.IsTrue(WhatsNew.IsNewer(entry.Version, "0.1.2"), entry.Id);
        }
    }

    [TestMethod]
    public void UpgradeStartsTheVersionsInBetween()
    {
        var empty = WhatsNewLedger.Empty;
        Assert.AreSame(empty, WhatsNew.Adopting(empty, null, "0.8.0", T0, Sample));
        var upgraded = WhatsNew.Adopting(empty, "0.6.0", "0.8.0", T0, Sample);
        CollectionAssert.AreEquivalent(new Dictionary<string, long> { ["0.7.0"] = T0, ["0.8.0"] = T0 }, Started(upgraded));
        var later = T0 + 5 * Day;
        var again = WhatsNew.Adopting(upgraded, "0.8.0", "0.9.0", later, Sample);
        CollectionAssert.AreEquivalent(new Dictionary<string, long> { ["0.7.0"] = 0, ["0.8.0"] = 0, ["0.9.0"] = later }, Started(again));
        // 退回 0.7.0 再升回来：时刻不重新算
        Assert.IsTrue(WhatsNew.Adopting(again, "0.7.0", "0.9.0", later + Day, Sample).Same(again));
    }

    [TestMethod]
    public void FreshFollowsTheRules()
    {
        var ledger = new WhatsNewLedger(new Dictionary<string, long> { ["0.7.0"] = T0, ["0.8.0"] = T0 }, new HashSet<string>());
        string[] Ids(WhatsNewLedger value, IReadOnlySet<string> enabled, long now)
            => WhatsNew.Fresh(value, enabled, now, Sample).Select(entry => entry.Id).ToArray();
        CollectionAssert.AreEqual(new[] { "a", "b" }, Ids(ledger, All, T0));
        CollectionAssert.AreEqual(new[] { "a", "b" }, Ids(ledger, All, T0 - Day));
        CollectionAssert.AreEqual(new[] { "a", "b" }, Ids(ledger, All, T0 + WhatsNew.LifetimeMs - 1));
        Assert.AreEqual(0, Ids(ledger, All, T0 + WhatsNew.LifetimeMs).Length);
        CollectionAssert.AreEqual(new[] { "b" }, Ids(ledger, All.Where(key => key != "clipboard").ToHashSet(), T0));
        CollectionAssert.AreEqual(new[] { "b" }, Ids(ledger, new HashSet<string>(), T0));
        CollectionAssert.AreEqual(new[] { "b" }, Ids(ledger with { Touched = new HashSet<string> { "a" } }, All, T0));
    }

    [TestMethod]
    public void TouchingOnlyRecordsStartedEntries()
    {
        var ledger = new WhatsNewLedger(new Dictionary<string, long> { ["0.7.0"] = T0 }, new HashSet<string>());
        var touched = WhatsNew.Touching(ledger, entry => entry.Actions.Contains("pinClipboard"), Sample);
        CollectionAssert.AreEquivalent(new[] { "a" }, touched.Touched.ToArray());
        Assert.AreSame(touched, WhatsNew.Touching(touched, entry => entry.Id == "a", Sample));
        // 0.9.0 还没开始标：碰它的动作不记
        Assert.AreSame(ledger, WhatsNew.Touching(ledger, entry => entry.Actions.Contains("reminderNew"), Sample));
    }

    [TestMethod]
    public void SettingsOnlyEntries()
    {
        Assert.IsFalse(WhatsNew.InSettingsOnly(new[] { Sample[0] }));
        Assert.IsTrue(WhatsNew.InSettingsOnly(new[] { Sample[1] }));
        Assert.IsFalse(WhatsNew.InSettingsOnly(new[] { Sample[2] }));
        Assert.IsFalse(WhatsNew.InSettingsOnly(System.Array.Empty<WhatsNewEntry>()));
    }

    [TestMethod]
    public void NextVersionClearsOlderMarks()
    {
        var sample = new[]
        {
            new WhatsNewEntry("old", "0.7.2", null, System.Array.Empty<string>(), "launcher", "x"),
            new WhatsNewEntry("new", "0.8.0", null, new[] { "noteCapture" }, null),
        };
        var on072 = WhatsNew.Adopting(WhatsNewLedger.Empty, "0.7.1", "0.7.2", T0, sample);
        CollectionAssert.AreEquivalent(new Dictionary<string, long> { ["0.7.2"] = T0 }, Started(on072));
        Assert.IsTrue(WhatsNew.Adopting(on072, "0.7.2", "0.7.2", T0, sample).Same(on072));
        var on080 = WhatsNew.Adopting(on072, "0.7.2", "0.8.0", T0, sample);
        CollectionAssert.AreEquivalent(new Dictionary<string, long> { ["0.7.2"] = 0, ["0.8.0"] = T0 }, Started(on080));
        CollectionAssert.AreEqual(new[] { "new" }, WhatsNew.Fresh(on080, new HashSet<string>(), T0, sample).Select(entry => entry.Id).ToArray());
        var skipped = WhatsNew.Adopting(WhatsNewLedger.Empty, "0.7.1", "0.8.0", T0, sample);
        CollectionAssert.AreEquivalent(new Dictionary<string, long> { ["0.7.2"] = T0, ["0.8.0"] = T0 }, Started(skipped));
    }

    [TestMethod]
    public void VisitedPageKeepsItsMarksUntilLeft()
    {
        var reminders = Sample[2];
        var features = Sample[1];
        var first = WhatsNew.Shown("reminders", new[] { reminders, features }, new HashSet<string>(), Sample);
        CollectionAssert.AreEquivalent(new[] { "c", "b" }, first.ToArray());
        Assert.IsTrue(WhatsNew.Marks("reminders", first, Sample));
        var second = WhatsNew.Shown("general", new[] { features }, first, Sample);
        CollectionAssert.AreEquivalent(new[] { "b" }, second.ToArray());
        Assert.IsFalse(WhatsNew.Marks("reminders", second, Sample));
        Assert.IsTrue(WhatsNew.Marks("general", second, Sample));
        Assert.IsTrue(WhatsNew.Marks("功能", "general", second, Sample));
        Assert.IsFalse(WhatsNew.Marks("外观", "general", second, Sample));
        Assert.AreEqual(0, WhatsNew.Shown("about", System.Array.Empty<WhatsNewEntry>(), second, Sample).Count);
    }

    [TestMethod]
    public void WindowsEntriesStartWhenUpgradingFromTheReleasedVersion()
    {
        // 从 0.1.2（或没记过上次版本的老设置，按 0.0.0 算）升到下一版：便签、提醒、状态屏都开始标；新装不标
        var upgraded = WhatsNew.Adopting(WhatsNewLedger.Empty, "0.1.2", "0.2.0", T0);
        CollectionAssert.AreEqual(new[] { "notes", "reminders", "status-screen" }, WhatsNew.Fresh(upgraded, All, T0).Select(entry => entry.Id).ToArray());
        Assert.IsTrue(WhatsNew.MarksAction("noteCapture", WhatsNew.Fresh(upgraded, All, T0)));
        Assert.AreEqual(0, WhatsNew.Fresh(WhatsNew.Adopting(WhatsNewLedger.Empty, null, "0.2.0", T0), All, T0).Count);
        // 0.2.0 升到 0.3.0：只标脚本命令、WebDAV（都只在设置里有入口），0.2.0 那三个不再标
        var third = WhatsNew.Fresh(WhatsNew.Adopting(WhatsNewLedger.Empty, "0.2.0", "0.3.0", T0), All, T0);
        CollectionAssert.AreEqual(new[] { "scripts", "webdav" }, third.Select(entry => entry.Id).ToArray());
        Assert.IsTrue(WhatsNew.InSettingsOnly(third));
        // 还没改版本号（这次还是 0.1.2）：不标
        Assert.AreEqual(0, WhatsNew.Fresh(WhatsNew.Adopting(WhatsNewLedger.Empty, "0.1.2", "0.1.2", T0), All, T0).Count);
    }
}
