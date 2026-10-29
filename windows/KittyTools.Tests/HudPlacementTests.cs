// REVIEW R22：录屏控制条的位置 / 尺寸（100%、150%、贴底、负坐标）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HudPlacementTests
{
    [TestMethod]
    public void UsesPhysicalPixelsForScale()
    {
        var rect = HudPlacement.Compute(100, 100, 600, 300, 0, 0, 1920, 1080, 1.5);
        Assert.AreEqual(402, rect.Width);
        Assert.AreEqual(69, rect.Height);
        Assert.AreEqual(300 + 12, rect.Y);
        Assert.AreEqual(149, rect.X);
    }

    [TestMethod]
    public void WiderHudStaysCenteredUnderTheRegion()
    {
        // 录屏那条宽 300（PLAN-v9 R7）：150% 下 450 像素，仍在选区下方居中。
        var rect = HudPlacement.Compute(100, 100, 600, 300, 0, 0, 1920, 1080, 1.5, widthDip: 300);
        Assert.AreEqual(450, rect.Width);
        Assert.AreEqual(125, rect.X);
    }

    [TestMethod]
    public void FallsAboveWhenBottomDoesNotFit()
    {
        var rect = HudPlacement.Compute(100, 900, 500, 1070, 0, 0, 1920, 1080, 1.0);
        Assert.AreEqual(900 - 46 - 8, rect.Y);
        Assert.IsTrue(rect.Y >= 0);
    }

    [TestMethod]
    public void FallsInsideWhenNeitherSideFits()
    {
        var rect = HudPlacement.Compute(100, 0, 500, 1080, 0, 0, 1920, 1080, 1.0);
        Assert.AreEqual(1080 - 46 - 8, rect.Y);
        Assert.IsTrue(rect.Y >= 0);
    }

    [TestMethod]
    public void KeepsHudInsideNegativeCoordinateMonitor()
    {
        var rect = HudPlacement.Compute(-1800, 100, -1400, 500, -1920, 0, 0, 1080, 1.5);
        Assert.IsTrue(rect.X >= -1920);
        Assert.IsTrue(rect.X + rect.Width <= 0);
        Assert.AreEqual(500 + 12, rect.Y);
    }
}
