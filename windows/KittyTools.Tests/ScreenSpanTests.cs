// PLAN-v24：截图一个选区跨几块屏（ScreenSpan）。全局物理像素、原点左上；屏幕列表按左、再按上排（同 ScreenCapture.CaptureAll）。
// 七种摆法：只在一块屏里、左右并排、副屏在左边（负坐标）、上下错位（选区里有空角）、一块竖屏、和哪块屏都不沾、相交一样大。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScreenSpanTests
{
    private static readonly (int, int, int, int) Primary = (0, 0, 1920, 1080);

    [TestMethod]
    public void InsideOneScreenIsOnePiece()
    {
        var screens = new[] { Primary, (1920, 0, 3840, 1080) };
        var rect = (100, 100, 500, 400);
        Assert.AreEqual<int?>(0, ScreenSpan.Owner(rect, screens));
        Assert.IsFalse(ScreenSpan.Spans(rect, screens));
        CollectionAssert.AreEqual(new[] { (0, (100, 100, 500, 400), 0, 0) }, ScreenSpan.Pieces(rect, screens));
    }

    [TestMethod]
    public void SideBySideSplitsAtTheSeam()
    {
        var screens = new[] { Primary, (1920, 0, 3840, 1080) };
        var rect = (1800, 100, 2100, 300);
        Assert.IsTrue(ScreenSpan.Spans(rect, screens));
        Assert.AreEqual<int?>(1, ScreenSpan.Owner(rect, screens)); // 右边那块占 180 列、左边 120 列
        CollectionAssert.AreEqual(
            new[] { (0, (1800, 100, 1920, 300), 0, 0), (1, (0, 100, 180, 300), 120, 0) },
            ScreenSpan.Pieces(rect, screens));
    }

    [TestMethod]
    public void ScreenOnTheLeftHasNegativeCoordinates()
    {
        // 副屏 2560 × 1440 摆在主屏左边：它的左上是 (-2560, 0)
        var screens = new[] { (-2560, 0, 0, 1440), Primary };
        var rect = (-100, 50, 100, 150);
        CollectionAssert.AreEqual(
            new[] { (0, (2460, 50, 2560, 150), 0, 0), (1, (0, 50, 100, 150), 100, 0) },
            ScreenSpan.Pieces(rect, screens));
        Assert.AreEqual((-2560, 0, 1920, 1440), ScreenSpan.Bounds(screens));
    }

    [TestMethod]
    public void StaggeredScreensLeaveAGap()
    {
        // 副屏在主屏上边、往右错开 200：选区左上那一角（100..200, -100..0）哪块屏都没有，调用方填黑
        var screens = new[] { Primary, (200, -1440, 2760, 0) };
        var rect = (100, -100, 300, 100);
        var pieces = ScreenSpan.Pieces(rect, screens);
        CollectionAssert.AreEqual(
            new[] { (0, (100, 0, 300, 100), 0, 100), (1, (0, 1340, 100, 1440), 100, 0) },
            pieces);
        var covered = pieces.Sum(piece => (piece.Source.Right - piece.Source.Left) * (piece.Source.Bottom - piece.Source.Top));
        Assert.AreEqual(200 * 200 - 100 * 100, covered);
        Assert.AreEqual((0, -1440, 2760, 1080), ScreenSpan.Bounds(screens));
    }

    [TestMethod]
    public void PortraitScreen()
    {
        // 右边一块竖屏（1080 × 1920）
        var screens = new[] { Primary, (1920, 0, 3000, 1920) };
        var rect = (1900, 1000, 2000, 1500);
        Assert.AreEqual<int?>(1, ScreenSpan.Owner(rect, screens));
        CollectionAssert.AreEqual(
            new[] { (0, (1900, 1000, 1920, 1080), 0, 0), (1, (0, 1000, 80, 1500), 20, 0) },
            ScreenSpan.Pieces(rect, screens));
    }

    [TestMethod]
    public void OffEveryScreen()
    {
        var screens = new[] { Primary, (1920, 0, 3840, 1080) };
        var rect = (4000, 0, 4200, 200);
        Assert.IsNull(ScreenSpan.Owner(rect, screens));
        Assert.IsFalse(ScreenSpan.Spans(rect, screens));
        Assert.AreEqual(0, ScreenSpan.Pieces(rect, screens).Count);
        Assert.IsNull(ScreenSpan.LastRegion(rect, screens));
        Assert.AreEqual(default((int, int, int, int)), ScreenSpan.Bounds(Array.Empty<(int, int, int, int)>()));
    }

    [TestMethod]
    public void TieGoesToTheScreenListedFirst()
    {
        var screens = new[] { Primary, (1920, 0, 3840, 1080) };
        Assert.AreEqual<int?>(0, ScreenSpan.Owner((1820, 0, 2020, 100), screens));
    }

    [TestMethod]
    public void LastRegionKeepsWhatIsStillThere()
    {
        var rect = (1800, 100, 2100, 300);
        var both = new[] { Primary, (1920, 0, 3840, 1080) };
        Assert.AreEqual<(int, int, int, int)?>(rect, ScreenSpan.LastRegion(rect, both));
        // 拔掉右边那块：只剩主屏上那一段
        Assert.AreEqual<(int, int, int, int)?>((1800, 100, 1920, 300), ScreenSpan.LastRegion(rect, new[] { Primary }));
    }
}
