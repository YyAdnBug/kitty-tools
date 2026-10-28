// 翻译历史列表的分组和几何（PLAN-v9-translate 8d），期望值照 mac TranslateTests 里 HistoryView 的那几条。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HistoryListLayoutTests
{
    private static readonly DateTime Now = new(2026, 10, 28, 15, 0, 0);

    [TestMethod]
    public void GroupsByDayWithTitles()
    {
        var layout = new HistoryListLayout(new[]
        {
            Now.AddMinutes(-5), Now.AddHours(-2), Now.AddDays(-1), new DateTime(2026, 3, 5, 9, 0, 0),
            new DateTime(2025, 12, 31, 23, 0, 0),
        }, Now);
        CollectionAssert.AreEqual(
            new[] { "今天", "昨天", "3月5日", "2025年12月31日" },
            layout.Headers.Select(header => header.Title).ToArray());
        // 标题 24、行 44：第一组标题在 0，两行在 24、68；第二组标题 112，行 136
        Assert.AreEqual(24, layout.Top(0));
        Assert.AreEqual(68, layout.Top(1));
        Assert.AreEqual(112, layout.Headers[1].Top);
        Assert.AreEqual(136, layout.Top(2));
        Assert.AreEqual(4 * 24 + 5 * 44.0, layout.TotalHeight);
    }

    [TestMethod]
    public void SpanIncludesHeaderForFirstRowOfGroup()
    {
        var layout = new HistoryListLayout(new[] { Now, Now.AddMinutes(-1), Now.AddDays(-1) }, Now);
        Assert.AreEqual((0.0, 68.0), layout.Span(0));
        Assert.AreEqual((68.0, 112.0), layout.Span(1));
        Assert.AreEqual((112.0, 180.0), layout.Span(2));
        // 已经看得见不滚；在下面看不见时滚到底边 + 12；在上面时滚到顶 − 12
        Assert.IsNull(layout.Reveal(1, 0, 200));
        Assert.AreEqual(180 + 12 - 100.0, layout.Reveal(2, 0, 100));
        Assert.AreEqual(56.0, layout.Reveal(1, 100, 100));
    }

    [TestMethod]
    public void RowTimeIsTwoDigits()
    {
        Assert.AreEqual("18:07", HistoryListLayout.RowTime(new DateTime(2026, 1, 1, 18, 7, 0)));
        Assert.AreEqual("09:05", HistoryListLayout.RowTime(new DateTime(2026, 1, 1, 9, 5, 0)));
    }
}
