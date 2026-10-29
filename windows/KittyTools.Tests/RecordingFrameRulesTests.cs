// 录屏 / 长截图选区边框（2026-10-29 用户反馈：开录后看不出在录哪）：线在选区外、按缩放换算、贴屏幕边那侧不画、整屏不画；
// 录屏开着 insideAtEdges 时贴边那侧收进选区里面画（整屏也有框）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RecordingFrameRulesTests
{
    [TestMethod]
    public void DrawsOutsideTheRegion()
    {
        var strips = RecordingFrameRules.Strips(100, 100, 500, 300, 0, 0, 1920, 1080, 1.5);
        Assert.AreEqual(new RecordingFrameRules.Strip(97, 97, 406, 3), strips[0]);
        Assert.AreEqual(new RecordingFrameRules.Strip(97, 300, 406, 3), strips[1]);
        Assert.AreEqual(new RecordingFrameRules.Strip(97, 100, 3, 200), strips[2]);
        Assert.AreEqual(new RecordingFrameRules.Strip(500, 100, 3, 200), strips[3]);
    }

    [TestMethod]
    public void SkipsSidesTouchingTheScreenEdge()
    {
        var strips = RecordingFrameRules.Strips(0, 0, 500, 300, 0, 0, 1920, 1080, 1.0);
        Assert.IsTrue(strips[0].IsEmpty);
        Assert.IsTrue(strips[2].IsEmpty);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 300, 502, 2), strips[1]);
        Assert.AreEqual(new RecordingFrameRules.Strip(500, 0, 2, 300), strips[3]);
    }

    [TestMethod]
    public void FullScreenHasNoFrame()
    {
        var strips = RecordingFrameRules.Strips(-1920, 0, 0, 1080, -1920, 0, 0, 1080, 1.25);
        Assert.IsTrue(strips.All(strip => strip.IsEmpty));
    }

    [TestMethod]
    public void StaysOnTheRegionsScreen()
    {
        // 选区贴着主屏左边，左边那块屏上不该露出线。
        var strips = RecordingFrameRules.Strips(0, 200, 800, 600, 0, 0, 2560, 1440, 2.0);
        Assert.IsTrue(strips[2].IsEmpty);
        Assert.AreEqual(0, strips[0].X);
        Assert.AreEqual(4, strips[3].Width);
    }

    [TestMethod]
    public void InsideAtEdgesFramesTheWholeScreen()
    {
        var strips = RecordingFrameRules.Strips(0, 0, 1920, 1080, 0, 0, 1920, 1080, 1.0, insideAtEdges: true);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 0, 1920, 2), strips[0]);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 1078, 1920, 2), strips[1]);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 2, 2, 1076), strips[2]);
        Assert.AreEqual(new RecordingFrameRules.Strip(1918, 2, 2, 1076), strips[3]);
    }

    [TestMethod]
    public void InsideAtEdgesOnlyMovesSidesWithoutRoom()
    {
        // 最大化的窗口：上、左、右贴着屏幕边收进里面；下边离屏幕底还有任务栏那一截，照旧画在外面。
        var strips = RecordingFrameRules.Strips(0, 0, 1920, 1032, 0, 0, 1920, 1080, 1.0, insideAtEdges: true);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 0, 1920, 2), strips[0]);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 1032, 1920, 2), strips[1]);
        Assert.AreEqual(new RecordingFrameRules.Strip(0, 2, 2, 1030), strips[2]);
        Assert.AreEqual(new RecordingFrameRules.Strip(1918, 2, 2, 1030), strips[3]);

        // 离屏幕边够远的选区：开不开都一样，全在外面。
        CollectionAssert.AreEqual(
            RecordingFrameRules.Strips(100, 100, 500, 300, 0, 0, 1920, 1080, 1.5),
            RecordingFrameRules.Strips(100, 100, 500, 300, 0, 0, 1920, 1080, 1.5, insideAtEdges: true));
    }
}
