// PLAN-v9 第 5e 批：选区旁的工具栏、尺寸胶囊放哪，Ctrl / Alt + 方向键推收边，尺寸胶囊输宽高（照 mac RegionSelectorTests 的
// pushed / sized，mac 原点左下、这里原点左上）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SelectionChromeTests
{
    private static readonly RectD Screen = new(0, 0, 1920, 1080);

    [TestMethod]
    public void ToolbarSitsBelowCenteredThenAboveThenInside()
    {
        // 下方 10、水平居中
        var below = SelectionChrome.Toolbar(new RectD(500, 200, 400, 300), 600, 40, 40, 1920, 1080);
        Assert.AreEqual((400.0, 510.0, ToolbarSide.Below), below);
        // 下方连托盘放不下 → 上方
        var above = SelectionChrome.Toolbar(new RectD(500, 600, 400, 420), 600, 40, 40, 1920, 1080);
        Assert.AreEqual((400.0, 550.0, ToolbarSide.Above), above);
        // 上下都放不下 → 选区底部里面
        var inside = SelectionChrome.Toolbar(new RectD(0, 30, 1920, 1040), 600, 40, 40, 1920, 1080);
        Assert.AreEqual((660.0, 1020.0, ToolbarSide.Inside), inside);
        // 靠屏幕左边：夹在屏内 10
        Assert.AreEqual(10, SelectionChrome.Toolbar(new RectD(0, 100, 100, 100), 600, 40, 0, 1920, 1080).X);
        // 没有托盘时下方刚好放得下
        Assert.AreEqual(ToolbarSide.Below, SelectionChrome.Toolbar(new RectD(0, 0, 100, 1020), 300, 40, 0, 1920, 1080).Side);
        Assert.AreEqual(ToolbarSide.Above, SelectionChrome.Toolbar(new RectD(0, 100, 100, 920), 300, 40, 40, 1920, 1080).Side);
    }

    [TestMethod]
    public void SizeCapsuleFallsBackInsideThenBesideThenReadOnly()
    {
        var none = Array.Empty<RectD>();
        // 左上角外 8
        Assert.AreEqual((300.0, 166.0, true), SelectionChrome.SizeCapsule(new RectD(300, 200, 400, 300), 140, 26, 1920, 1080, none));
        // 贴着屏幕顶：放进选区（离左、上各 8）
        Assert.AreEqual((308.0, 8.0, true), SelectionChrome.SizeCapsule(new RectD(300, 0, 400, 300), 140, 26, 1920, 1080, none));
        // 上面压着顶部提示：也放进选区
        var hint = new[] { new RectD(0, 14, 1920, 30) };
        Assert.AreEqual((308.0, 58.0, true), SelectionChrome.SizeCapsule(new RectD(300, 50, 400, 300), 140, 26, 1920, 1080, hint));
        // 选区又贴顶又小：放右侧外 8，比胶囊矮的竖直居中；居中后出了屏顶就只读放进选区
        Assert.IsFalse(SelectionChrome.SizeCapsule(new RectD(300, 0, 50, 20), 140, 26, 1920, 1080, none).Interactive);
        Assert.AreEqual(358,SelectionChrome.SizeCapsule(new RectD(300, 10, 50, 20), 140, 26, 1920, 1080, none).X);
        Assert.AreEqual(7, SelectionChrome.SizeCapsule(new RectD(300, 10, 50, 20), 140, 26, 1920, 1080, none).Y);
        // 右边贴屏：放左侧外 8
        Assert.AreEqual(1722, SelectionChrome.SizeCapsule(new RectD(1870, 0, 50, 40), 140, 26, 1920, 1080, none).X);
        // 整屏选区：放进选区，能点
        Assert.IsTrue(SelectionChrome.SizeCapsule(Screen, 140, 26, 1920, 1080, none).Interactive);
        // 整屏又被工具栏压住左上：只读放进去
        var full = SelectionChrome.SizeCapsule(Screen, 140, 26, 1920, 1080, new[] { new RectD(0, 0, 400, 60) });
        Assert.IsFalse(full.Interactive);
    }

    [TestMethod]
    public void PushAndPullEdgesKeepAMinimumAndStayOnScreen()
    {
        var rect = new RectD(100, 100, 200, 100);
        Assert.AreEqual(new RectD(90, 100, 210, 100), SelectionChrome.Pushed(rect, SelectionHandle.Left, 10, Screen, 8));
        Assert.AreEqual(new RectD(100, 100, 201, 100), SelectionChrome.Pushed(rect, SelectionHandle.Right, 1, Screen, 8));
        Assert.AreEqual(new RectD(100, 99, 200, 101), SelectionChrome.Pushed(rect, SelectionHandle.Top, 1, Screen, 8));
        Assert.AreEqual(new RectD(100, 100, 200, 90), SelectionChrome.Pushed(rect, SelectionHandle.Bottom, -10, Screen, 8));
        // 收到不小于 8
        Assert.AreEqual(8, SelectionChrome.Pushed(rect, SelectionHandle.Left, -500, Screen, 8).Width);
        // 本来就比 8 小的不再收
        var thin = new RectD(100, 100, 5, 100);
        Assert.AreEqual(5, SelectionChrome.Pushed(thin, SelectionHandle.Right, -1, Screen, 8).Width);
        // 推不出屏
        Assert.AreEqual(0, SelectionChrome.Pushed(new RectD(5, 5, 10, 10), SelectionHandle.Left, 10, Screen, 8).X);
        Assert.AreEqual(1080, SelectionChrome.Pushed(new RectD(5, 1070, 10, 5), SelectionHandle.Bottom, 10, Screen, 8).Bottom);
        // 角不认
        Assert.AreEqual(rect, SelectionChrome.Pushed(rect, SelectionHandle.TopLeft, 10, Screen, 8));
    }

    [TestMethod]
    public void SizedKeepsTheTopLeftPixelAndClamps()
    {
        Assert.AreEqual(new RectD(100, 50, 640, 480), SelectionChrome.Sized(new RectD(100.6, 50.2, 10, 10), 640, 480, Screen));
        Assert.AreEqual(new RectD(1800, 1000, 120, 80), SelectionChrome.Sized(new RectD(1800, 1000, 10, 10), 4000, 4000, Screen));
        Assert.AreEqual(new RectD(0, 0, 1, 1), SelectionChrome.Sized(new RectD(0, 0, 10, 10), 0, -5, Screen));
    }

    [TestMethod]
    public void ApplyingARatioKeepsTheTopEdgeAndCenter()
    {
        // 宽不变、高按比例，顶边和水平中心不动
        Assert.AreEqual(new RectD(100, 100, 400, 225), RegionMath.ApplyingRatio(16.0 / 9, new RectD(100, 100, 400, 300), Screen));
        // 下面放不下：按剩下的高反推宽，变窄、居中
        var squeezed = RegionMath.ApplyingRatio(1, new RectD(100, 980, 400, 50), Screen);
        Assert.AreEqual(new RectD(250, 980, 100, 100), squeezed);
    }

    [TestMethod]
    public void RatioTitles()
    {
        Assert.AreEqual("自由", SelectionChrome.RatioTitle(null));
        Assert.AreEqual("16:9", SelectionChrome.RatioTitle(16.0 / 9));
        Assert.AreEqual("自由", SelectionChrome.RatioTitle(2.5));
        Assert.AreEqual(6, SelectionChrome.Ratios.Length);
    }
}
