// 第二版第 5 批的纯函数单测：截图翻译浮窗贴着选区出现（放右 → 放左 → 放下 → 夹进工作区）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScreenshotLayoutTests
{
    private static readonly WorkArea Work = new(0, 0, 1920, 1040);

    [TestMethod]
    public void PrefersRightOfSelection()
    {
        var anchor = new PixelRect(100, 100, 300, 200);
        var rect = MonitorLayout.NearRect(anchor, Work, 1, 460, 320);
        Assert.AreEqual(400 + 12, rect.X);
        Assert.AreEqual(100, rect.Y);
        Assert.AreEqual(460, rect.Width);
        Assert.AreEqual(320, rect.Height);
    }

    [TestMethod]
    public void FlipsLeftWhenNoRoomOnRight()
    {
        var anchor = new PixelRect(1500, 100, 300, 200);
        var rect = MonitorLayout.NearRect(anchor, Work, 1, 460, 320);
        Assert.AreEqual(1500 - 460 - 12, rect.X);
    }

    [TestMethod]
    public void GoesBelowWhenNeitherSideFits()
    {
        var anchor = new PixelRect(700, 100, 500, 200);
        var rect = MonitorLayout.NearRect(anchor, Work, 1, 900, 320);
        // 左右都放不下 900 宽：放到下面，横向仍夹进工作区。
        Assert.AreEqual(700, rect.X);
        Assert.AreEqual(300 + 12, rect.Y);
        Assert.IsTrue(rect.Right <= Work.Right);
    }

    [TestMethod]
    public void ScalesWithMonitorAndStaysInsideWorkArea()
    {
        var anchor = new PixelRect(1800, 900, 100, 100);
        var rect = MonitorLayout.NearRect(anchor, Work, 2, 460, 320);
        Assert.AreEqual(920, rect.Width);
        Assert.AreEqual(640, rect.Height);
        Assert.IsTrue(rect.X >= Work.Left && rect.Right <= Work.Right);
        Assert.IsTrue(rect.Y >= Work.Top && rect.Bottom <= Work.Bottom);
    }
}
