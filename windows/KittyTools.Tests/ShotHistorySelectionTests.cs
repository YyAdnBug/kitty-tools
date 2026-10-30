// 截图历史的多选、方向键挑图、多选小结（照 mac 1ec2ca9a 的 multiSelect / spanAndSummary、933c1dd9 的 gridStepping）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ShotHistorySelectionTests
{
    private static readonly string[] Ids = { "a", "b", "c", "d", "e", "f" };

    private static string[] Sorted(IEnumerable<string> ids) => ids.OrderBy(id => id, StringComparer.Ordinal).ToArray();

    [TestMethod]
    public void PlainClickPicksOnlyThatOne()
    {
        var (picked, anchor) = ShotHistoryRules.Click(Ids, new[] { "a", "b" }, "a", "d", control: false, shift: false);
        CollectionAssert.AreEqual(new[] { "d" }, Sorted(picked));
        Assert.AreEqual("d", anchor);
    }

    [TestMethod]
    public void ControlClickTogglesAndMovesTheAnchor()
    {
        var (picked, anchor) = ShotHistoryRules.Click(Ids, new[] { "a" }, "a", "c", control: true, shift: false);
        CollectionAssert.AreEqual(new[] { "a", "c" }, Sorted(picked));
        Assert.AreEqual("c", anchor);
        (picked, _) = ShotHistoryRules.Click(Ids, picked, anchor, "a", control: true, shift: false);
        CollectionAssert.AreEqual(new[] { "c" }, Sorted(picked));
    }

    [TestMethod]
    public void ShiftClickSpansFromTheAnchorAndKeepsScatteredPicks()
    {
        // Ctrl 点了 a 和 f（锚点在 f），再 Shift 点 c：c–f 连起来，a 还在。
        var (picked, anchor) = ShotHistoryRules.Click(Ids, new[] { "a", "f" }, "f", "c", control: false, shift: true);
        CollectionAssert.AreEqual(new[] { "a", "c", "d", "e", "f" }, Sorted(picked));
        Assert.AreEqual("f", anchor);
        // 没有锚点（或锚点不在列表里）时 Shift 点就是单点。
        (picked, anchor) = ShotHistoryRules.Click(Ids, Array.Empty<string>(), "gone", "b", control: false, shift: true);
        CollectionAssert.AreEqual(new[] { "b" }, Sorted(picked));
        Assert.AreEqual("b", anchor);
    }

    [TestMethod]
    public void SpanWorksInBothDirections()
    {
        CollectionAssert.AreEqual(new[] { "b", "c", "d" }, Sorted(ShotHistoryRules.Span(Ids, 3, 1)));
        CollectionAssert.AreEqual(new[] { "e" }, Sorted(ShotHistoryRules.Span(Ids, 4, 4)));
    }

    [TestMethod]
    public void ColumnsFitTheWidth()
    {
        Assert.AreEqual(3, ShotHistoryRules.Columns(600, 172));
        Assert.AreEqual(1, ShotHistoryRules.Columns(100, 172));
    }

    [TestMethod]
    public void ArrowsStepWithinGroupedRowsAndClamp()
    {
        // 两组：今天 7 张（一行 3 张：0–2、3–5、6），昨天 2 张（7–8）。
        var groups = new[] { 7, 2 };
        Assert.AreEqual(0, ShotHistoryRules.Moved(null, 1, 0, groups, 3));
        Assert.AreEqual(1, ShotHistoryRules.Moved(0, 1, 0, groups, 3));
        Assert.AreEqual(0, ShotHistoryRules.Moved(0, -1, 0, groups, 3));
        Assert.AreEqual(8, ShotHistoryRules.Moved(8, 1, 0, groups, 3));
        Assert.AreEqual(4, ShotHistoryRules.Moved(1, 0, 1, groups, 3));
        // 第 5 张往下：下一行只有一张（第 6 张）。
        Assert.AreEqual(6, ShotHistoryRules.Moved(5, 0, 1, groups, 3));
        // 第 6 张往下到昨天那组的第一行，列 0。
        Assert.AreEqual(7, ShotHistoryRules.Moved(6, 0, 1, groups, 3));
        Assert.AreEqual(8, ShotHistoryRules.Moved(8, 0, 1, groups, 3));
        Assert.AreEqual(2, ShotHistoryRules.Moved(2, 0, -1, groups, 3));
        Assert.IsNull(ShotHistoryRules.Moved(null, 0, 1, Array.Empty<int>(), 3));
    }

    [TestMethod]
    public void SummaryCountsKindsAndSize()
    {
        var summary = ShotHistoryRules.Summary(new[]
        {
            (ShotKind.Shot, 3L * 1024 * 1024),
            (ShotKind.Shot, 2L * 1024 * 1024),
            (ShotKind.Video, 7L * 1024 * 1024),
            (ShotKind.Gif, 0L),
        });
        Assert.AreEqual("2 张截图 · 1 段录屏 · 1 张 GIF · 共 12 MB", summary);
    }
}
