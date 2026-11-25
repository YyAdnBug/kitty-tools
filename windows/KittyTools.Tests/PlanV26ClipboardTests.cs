// PLAN-v26 第 4 批（C2）：列表里直接显示图片的几何——图片行 64 高、图按比例夹在 0.75–5 倍、前缀和按每行的高算（同 mac ClipboardPanelTests）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV26ClipboardTests
{
    [TestMethod]
    public void StripWidthKeepsTheRatioWithinLimits()
    {
        Assert.AreEqual(96, ClipLens.StripWidth(1600, 800), 1e-9);
        Assert.AreEqual(36, ClipLens.StripWidth(1170, 2532), 1e-9, "手机截图：窄到 0.75 倍为止，从顶上裁");
        Assert.AreEqual(240, ClipLens.StripWidth(4000, 300), 1e-9, "长横条：宽到 5 倍为止");
        Assert.AreEqual(48, ClipLens.StripWidth(0, 0), 1e-9);
    }

    [TestMethod]
    public void LayoutUsesEachRowsHeight()
    {
        var days = new long[] { 1, 1, 1, 2 };
        var heights = new[] { 40.0, ClipLens.ImageRow, 40, ClipLens.ImageRow };
        var layout = new ClipListLayout(days, -1, 0, rowHeights: heights);
        // 两个分组标题 24 + 40 + 64 + 40 + 64
        Assert.AreEqual(2 * ClipListLayout.HeaderHeight + 40 + 64 + 40 + 64, layout.TotalHeight, 1e-9);
        Assert.AreEqual(ClipListLayout.HeaderHeight + 40, layout.RowTop(1), 1e-9);
        Assert.AreEqual(64, layout.RowHeightOf(1), 1e-9);

        // 选中的图片行换成透镜的高（行头 40 + 透镜），别的照旧
        var selected = new ClipListLayout(days, 1, 186, rowHeights: heights);
        Assert.AreEqual(186, selected.RowHeightOf(1), 1e-9);
        Assert.AreEqual(layout.TotalHeight - 64 + 186, selected.TotalHeight, 1e-9);
        Assert.AreEqual(64, selected.RowHeightOf(3), 1e-9);

        // 条数对不上（不该发生）就当全是普通行
        Assert.AreEqual(new ClipListLayout(days, -1, 0).TotalHeight, new ClipListLayout(days, -1, 0, rowHeights: new[] { 64.0 }).TotalHeight, 1e-9);
    }
}
