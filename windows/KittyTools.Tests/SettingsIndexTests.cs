// PLAN-v28 X3 X5 X7：设置项登记表（每一项都挂在页面上、只挂一次；键都是认得的设置；搜索的排序和上限）、
// 恢复默认只取改过的键、三个合并的下拉（两个键的全部组合读一遍，每对旧 → 新只写变了的那个）、推进行的状态。
using System.Text.RegularExpressions;
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsIndexTests
{
    /// <summary>不在同步对照表里、只给恢复默认用的那几个（App SettingsSyncFields 里接上的）。</summary>
    private static readonly HashSet<string> LocalKeys = new(StringComparer.Ordinal)
    {
        "RecordKeys", "RecordMicrophone", "AudioSource", "LauncherUseEverything", "ScreenshotCornerRadius",
    };

    private static readonly string[] SidebarPages =
    {
        "general", "clipboard", "launcher", "translate", "screenshot", "record", "notes", "reminders", "statusScreen", "keepAwake", "hotkeys", "about",
    };

    [TestMethod]
    public void IdsAreUniqueAndPagesKnown()
    {
        var ids = SettingsIndex.Items.Select(item => item.Id).ToList();
        Assert.AreEqual(ids.Count, ids.Distinct().Count(), "id 不重复");
        foreach (var item in SettingsIndex.Items)
        {
            Assert.IsTrue(SettingsIndex.PageTitles.ContainsKey(item.Page), item.Id);
            Assert.IsTrue(item.Id.StartsWith(item.Page + ".", StringComparison.Ordinal), item.Id);
            Assert.IsTrue(item.Sub is null || item.Sub == SettingsIndex.Advanced || SettingsIndex.Subpage(item.Page, item.Sub) is not null,
                $"{item.Id} 的子页 {item.Sub} 没登记");
        }
    }

    [TestMethod]
    public void EveryPageAndSubpageHasRows()
    {
        foreach (var page in SidebarPages)
        {
            Assert.IsTrue(SettingsIndex.Items.Any(item => item.Page == page), page);
        }

        // 新的六个子页（PLAN-v28 X2）都有行
        foreach (var (page, sub) in new[] { ("general", "sync"), ("general", "backup"), ("screenshot", "history"), ("translate", "lookup"), ("translate", "history"), ("notes", "deck") })
        {
            Assert.IsTrue(SettingsIndex.In(page, sub).Any(), $"{page}.{sub}");
        }
    }

    [TestMethod]
    public void KeysAreKnownSettings()
    {
        var known = SettingsSyncMap.Shared.Concat(SettingsSyncMap.WindowsOnly).Select(key => key.Field).ToHashSet(StringComparer.Ordinal);
        foreach (var item in SettingsIndex.Items)
        {
            foreach (var key in item.Keys)
            {
                Assert.IsTrue(known.Contains(key) || LocalKeys.Contains(key), $"{item.Id}：{key} 不是认得的设置");
            }
        }
    }

    [TestMethod]
    public void ResetNeverTouchesLimitsOrFeatures()
    {
        var places = SettingsIndex.Items.Select(item => (item.Page, item.Sub)).Distinct();
        foreach (var (page, sub) in places)
        {
            foreach (var key in SettingsIndex.ResetKeys(page, sub))
            {
                Assert.IsFalse(SettingsIndex.Limits.Contains(key), $"{page}.{sub}：{key}");
                Assert.IsFalse(key.StartsWith("feature.", StringComparison.Ordinal), key);
                // 旧规矩（PLAN-v26 G1）照样成立：保留期、占用、历史开关不跟着恢复——截图历史、翻译历史的开关除外：它们只关「记不记」，不删东西（同 mac）
                Assert.IsFalse(key.Contains("Retention", StringComparison.OrdinalIgnoreCase) || key.Contains("Megabytes", StringComparison.OrdinalIgnoreCase), key);
            }
        }

        CollectionAssert.AreEqual(new[] { "ClipboardShowLens", "ClipboardImageRows", "LinkPreviews", "ClipboardPanelPosition", "ClipboardImageOcr" },
            SettingsIndex.ResetKeys("clipboard", SettingsIndex.Advanced));
        CollectionAssert.AreEqual(new[] { "ShotHistory" }, SettingsIndex.ResetKeys("screenshot", "history"), "两个上限不进恢复默认");
        CollectionAssert.AreEqual(new[] { "TranslateHistoryEnabled" }, SettingsIndex.ResetKeys("translate", "history"), "条数不进");
    }

    /// <summary>读 App 的源码：每一项都挂在页面上、只挂一次（OpenItem / ShowItem 这些直达调用不算）。</summary>
    [TestMethod]
    public void EveryItemIsAnchoredOnce()
    {
        var folder = SettingsFolder();
        // SettingsWindow.Find.cs 是落到哪一行的那几条规则，不是页面上的行
        var text = string.Join("\n", Directory.GetFiles(folder, "*.cs")
            .Where(path => Path.GetFileName(path) != "SettingsWindow.Find.cs")
            .Select(File.ReadAllText));
        var direct = new Regex(@"(?:OpenItem|ShowItem|ShowSettingsItem)\(\s*""[^""]+""");
        text = direct.Replace(text, string.Empty);
        foreach (var item in SettingsIndex.Items)
        {
            var count = Regex.Matches(text, "\"" + Regex.Escape(item.Id) + "\"").Count;
            Assert.AreEqual(1, count, $"{item.Id} 在 Settings 的源码里出现了 {count} 次");
        }
    }

    [TestMethod]
    public void SearchRanksTitleThenKeywords()
    {
        var pages = SidebarPages;
        // 标题打头的排在前面：「面板位置」三处都是打头，按侧栏页序：剪贴板、启动器
        var hits = SettingsIndex.Matching("面板位置", pages);
        Assert.AreEqual("clipboard.panelPosition", hits[0].Id);
        Assert.AreEqual("launcher.panelPosition", hits[1].Id);
        // 「透镜」：标题里有
        Assert.AreEqual("clipboard.lens", SettingsIndex.Matching("透镜", pages)[0].Id);
        // 只在搜索词里：「OCR」
        Assert.AreEqual("clipboard.ocr", SettingsIndex.Matching("OCR", pages)[0].Id);
        // 标题打头 > 标题里有 > 搜索词里有
        var history = SettingsIndex.Matching("历史", pages);
        Assert.AreEqual(0, SettingsIndex.Rank(history[0], "历史"));
        Assert.IsTrue(history.Zip(history.Skip(1)).All(pair => SettingsIndex.Rank(pair.First, "历史") <= SettingsIndex.Rank(pair.Second, "历史")));
        // 最多 12 条
        Assert.AreEqual(SettingsIndex.ResultLimit, SettingsIndex.Matching("的", pages).Count, "对上的多于 12 条时只列 12 条");
        Assert.AreEqual(3, SettingsIndex.Matching("的", pages, limit: 3).Count);
        // 空的、只有空白的不出
        Assert.AreEqual(0, SettingsIndex.Matching("  ", pages).Count);
        // 侧栏里没有的页（没添加的插件）的行不出
        Assert.IsFalse(SettingsIndex.Matching("屏幕也不熄", pages.Where(page => page != "keepAwake").ToList()).Any());
        // 这会儿没有的行不出
        Assert.IsFalse(SettingsIndex.Matching("显示器", pages, item => item.Id != "notes.deckDisplay").Any(item => item.Id == "notes.deckDisplay"));
    }

    [TestMethod]
    public void SubpageAndAdvancedNamesFindTheirFirstRow()
    {
        Assert.AreEqual("screenshot.history", SettingsIndex.Matching("截图历史", SidebarPages).First(item => item.Page == "screenshot").Id);
        Assert.IsTrue(SettingsIndex.Words(SettingsIndex.Find("clipboard.lens")!).Contains("高级"));
        Assert.IsFalse(SettingsIndex.Words(SettingsIndex.Find("clipboard.imageRows")!).Contains("高级"), "只算第一行");
        Assert.IsTrue(SettingsIndex.PageWords("clipboard").Contains("透镜"), "页的词带上它的行");
    }

    [TestMethod]
    public void Locations()
    {
        Assert.AreEqual("剪贴板 · 高级", SettingsIndex.Location(SettingsIndex.Find("clipboard.lens")!));
        Assert.AreEqual("截图 › 截图历史", SettingsIndex.Location(SettingsIndex.Find("screenshot.historyDays")!));
        Assert.AreEqual("剪贴板", SettingsIndex.Location(SettingsIndex.Find("clipboard.pastePlain")!));
        Assert.AreEqual("scripts", SettingsIndex.Parent("launcher", "script-guide"));
        Assert.IsNull(SettingsIndex.Parent("translate", "history"));
    }

    [TestMethod]
    public void ResetTakesOnlyChangedKeys()
    {
        var current = new Dictionary<string, SettingValue>
        {
            ["A"] = SettingValue.Of(true), ["B"] = SettingValue.Of("top"), ["C"] = SettingValue.Of(30L),
        };
        var defaults = new Dictionary<string, SettingValue>
        {
            ["A"] = SettingValue.Of(false), ["B"] = SettingValue.Of("top"), ["C"] = SettingValue.Of(7L),
        };
        var changed = SettingsReset.Changed(new[] { "A", "B", "C", "Unknown" }, key => current.GetValueOrDefault(key), key => defaults.GetValueOrDefault(key));
        CollectionAssert.AreEqual(new[] { "A", "C" }, changed.Select(entry => entry.Key).ToList(), "没改过的、没接上的不算");
        // 写回默认之后再算一遍：一个都没有（按钮灰着）
        foreach (var (key, _) in changed)
        {
            current[key] = defaults[key];
        }

        Assert.AreEqual(0, SettingsReset.Changed(new[] { "A", "B", "C" }, key => current.GetValueOrDefault(key), key => defaults.GetValueOrDefault(key)).Count);
        // 撤销：原样写回，逐键和原来一样
        foreach (var (key, value) in changed)
        {
            current[key] = value;
        }

        Assert.AreEqual(SettingValue.Of(true), current["A"]);
        Assert.AreEqual(SettingValue.Of(30L), current["C"]);
    }

    [TestMethod]
    public void AutoClearReadsAndWritesOnlyChangedKey()
    {
        foreach (var quit in new[] { false, true })
        {
            foreach (var locked in new[] { false, true })
            {
                var index = AutoClearChoice.Index(quit, locked);
                Assert.AreEqual(quit, index is 1 or 3);
                Assert.AreEqual(locked, index is 2 or 3);
                for (var next = 0; next < AutoClearChoice.Titles.Length; next++)
                {
                    var (q, l) = AutoClearChoice.Writes(quit, locked, next);
                    var newQuit = q ?? quit;
                    var newLock = l ?? locked;
                    Assert.AreEqual(next, AutoClearChoice.Index(newQuit, newLock), $"{quit}/{locked} → {next}");
                    Assert.IsTrue(q is null || q != quit, "没变的不写");
                    Assert.IsTrue(l is null || l != locked, "没变的不写");
                }
            }
        }
    }

    [TestMethod]
    public void ElementChoiceLeavesWebKeyWhenOff()
    {
        Assert.AreEqual(0, ElementChoice.Index(false, true), "窗口里的关着一律算关");
        foreach (var finds in new[] { false, true })
        {
            foreach (var web in new[] { false, true })
            {
                for (var next = 0; next < ElementChoice.Titles.Length; next++)
                {
                    var (f, w) = ElementChoice.Writes(finds, web, next);
                    Assert.AreEqual(next, ElementChoice.Index(f ?? finds, w ?? web), $"{finds}/{web} → {next}");
                    Assert.IsTrue(f is null || f != finds);
                    Assert.IsTrue(w is null || w != web);
                    if (next == 0)
                    {
                        Assert.IsNull(w, "选「关」不动网页那个键");
                    }
                }
            }
        }
    }

    [TestMethod]
    public void WordVoiceHasFourChoices()
    {
        foreach (var recording in new[] { false, true })
        {
            foreach (var accent in new[] { "us", "uk" })
            {
                var index = WordVoiceChoice.Index(recording, accent);
                Assert.AreEqual(recording, index < 2);
                Assert.AreEqual(accent == "uk", index % 2 == 1);
                for (var next = 0; next < WordVoiceChoice.Titles.Length; next++)
                {
                    var (r, a) = WordVoiceChoice.Writes(recording, accent, next);
                    Assert.AreEqual(next, WordVoiceChoice.Index(r ?? recording, a ?? accent), $"{recording}/{accent} → {next}");
                    Assert.IsTrue(r is null || r != recording);
                    Assert.IsTrue(a is null || a != accent);
                }
            }
        }
    }

    [TestMethod]
    public void PushRowValues()
    {
        var now = new DateTimeOffset(2026, 11, 27, 9, 30, 0, TimeSpan.FromHours(9));
        Assert.AreEqual(new SettingsSummary.RowValue("关"), SettingsSummary.Sync(false, "idle", 0, now));
        Assert.AreEqual(new SettingsSummary.RowValue("停了", true), SettingsSummary.Sync(true, "stopped", 0, now));
        Assert.AreEqual(new SettingsSummary.RowValue("等你确认", true), SettingsSummary.Sync(true, "confirm", 0, now));
        Assert.AreEqual(new SettingsSummary.RowValue("正在同步…"), SettingsSummary.Sync(true, "syncing", 0, now));
        Assert.AreEqual("12 分钟前", SettingsSummary.Sync(true, "idle", now.AddMinutes(-12).ToUnixTimeMilliseconds(), now).Text);
        Assert.AreEqual("昨天", SettingsSummary.Ago(now.AddDays(-1), now));
        Assert.AreEqual("11月3日", SettingsSummary.Ago(new DateTimeOffset(2026, 11, 3, 8, 0, 0, now.Offset), now));

        var today = new DateTime(2026, 11, 27, 9, 30, 0);
        Assert.AreEqual("今天 09:12", SettingsSummary.Backup(true, today.Date.AddHours(9).AddMinutes(12), false, today).Text);
        Assert.AreEqual("自动备份关着", SettingsSummary.Backup(false, null, true, today).Text);
        Assert.AreEqual(new SettingsSummary.RowValue("没备成", true), SettingsSummary.Backup(true, today, true, today));

        Assert.AreEqual("30 天 · 2 GB", SettingsSummary.ShotHistory(true, 30, 2048).Text);
        Assert.AreEqual("一直留着 · 不限", SettingsSummary.ShotHistory(true, 0, 0).Text);
        Assert.AreEqual("关", SettingsSummary.ShotHistory(false, 30, 2048).Text);
        Assert.AreEqual("最多 5000 条", SettingsSummary.TranslateHistory(true, 5000).Text);
        Assert.AreEqual("不限", SettingsSummary.TranslateHistory(true, 0).Text);
        Assert.AreEqual("词典 · 真人英音", SettingsSummary.Lookup(true, 1).Text);
        Assert.AreEqual(new SettingsSummary.RowValue("2 个有问题", true), SettingsSummary.Scripts(true, 5, 2));
        Assert.AreEqual("开着 · 左边", SettingsSummary.Deck(true, "left").Text);
        Assert.AreEqual("关", SettingsSummary.Deck(false, "left").Text);
        // 行尾的字不超过 10 个（中文）
        foreach (var value in new[] { SettingsSummary.Lookup(true, 3), SettingsSummary.ShotHistory(true, 0, 0), SettingsSummary.Sync(true, "confirm", 0, now) })
        {
            Assert.IsTrue(value.Text.Length <= 10, value.Text);
        }
    }

    private static string SettingsFolder()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "KittyTools", "Settings");
            if (File.Exists(Path.Combine(candidate, "SettingsWindow.cs")))
            {
                return candidate;
            }
        }

        throw new AssertFailedException("找不到 KittyTools/Settings");
    }
}
