// PLAN-v6 第 1 批的纯函数单测：码率、帧率上限、补帧、偶数尺寸、选区裁剪。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RecordingPipelineTests
{
    [TestMethod]
    public void FrameTimeFollowsTheCaptureClock()
    {
        const long interval = 10_000_000 / 60;
        // 帧准时来：落在自己的格子上
        Assert.AreEqual(interval * 3, RecordingPipeline.FrameTime(interval * 3 + 1000, interval * 3, interval));
        // 帧来晚了（中间丢了两帧）：跳到它真实时间的格子，不接着排在上一帧后面（以前的锯齿）
        Assert.AreEqual(interval * 6, RecordingPipeline.FrameTime(interval * 6 + 50_000, interval * 4, interval));
        // 抓取时间比该在的格子早（两帧挤在同一格里）：放到下一格，保证递增
        Assert.AreEqual(interval * 5, RecordingPipeline.FrameTime(interval * 4 + 10, interval * 5, interval));
        // 开录之前抓的那一帧：放在 0
        Assert.AreEqual(0, RecordingPipeline.FrameTime(-200_000, 0, interval));

        // 57 帧 / 秒连着来 60 秒：最后一帧的时间和真实时间差不到一格（以前会落后约 3 秒）
        var next = 0L;
        var last = 0L;
        for (var frame = 0; frame < 57 * 60; frame++)
        {
            var captured = frame * 10_000_000L / 57;
            last = RecordingPipeline.FrameTime(captured, next, interval);
            next = last + interval;
        }

        Assert.IsTrue(Math.Abs(last - (57 * 60 - 1) * 10_000_000L / 57) < interval);
    }

    [TestMethod]
    public void StandardSharpnessCapsTheLongSideAt1920()
    {
        Assert.AreEqual((2560, 1440), RecordingPipeline.OutputSize(2560, 1440, standard: false));
        Assert.AreEqual((1920, 1080), RecordingPipeline.OutputSize(2560, 1440, standard: true));
        // 竖的：长边是高。
        Assert.AreEqual((1080, 1920), RecordingPipeline.OutputSize(1440, 2560, standard: true));
        // 不到 1920 的两种一样（取偶数）。
        Assert.AreEqual((1280, 720), RecordingPipeline.OutputSize(1281, 721, standard: true));
        // 3840 × 1601 → 1920 × 800.5 → 取偶 800。
        Assert.AreEqual((1920, 800), RecordingPipeline.OutputSize(3840, 1601, standard: true));
    }

    [TestMethod]
    public void BitrateMatchesPlanExamples()
    {
        Assert.AreEqual(4_354_560u, RecordingPipeline.BitrateFor(1920, 1080, 30));
        Assert.AreEqual(7_741_440u, RecordingPipeline.BitrateFor(2560, 1440, 30));
        Assert.AreEqual(20_000_000u, RecordingPipeline.BitrateFor(3840, 2160, 60));
        Assert.AreEqual(1_000_000u, RecordingPipeline.BitrateFor(16, 16, 1));
    }

    [TestMethod]
    public void FrameRateIsAnUpperBound()
    {
        const long step = 10_000_000 / 30;
        Assert.IsTrue(RecordingPipeline.ShouldAccept(1_000, long.MinValue, 30));
        Assert.IsFalse(RecordingPipeline.ShouldAccept(1_000 + step - 1, 1_000, 30));
        Assert.IsTrue(RecordingPipeline.ShouldAccept(1_000 + step, 1_000, 30));
        Assert.IsFalse(RecordingPipeline.ShouldAccept(1_000, 1_000, 60));
        Assert.IsTrue(RecordingPipeline.ShouldAccept(1_000 + 10_000_000 / 60, 1_000, 60));
    }

    [TestMethod]
    public void RepeatIsOneFrameLater()
    {
        Assert.AreEqual(1_000 + 10_000_000 / 30, RecordingPipeline.NextRepeat(1_000, 30));
        Assert.AreEqual(1_000 + 1_000_000, RecordingPipeline.NextRepeat(1_000, 10));
    }

    [TestMethod]
    public void EvenSizeAtLeastTwo()
    {
        CollectionAssert.AreEqual(
            new[] { 2558, 1438 }, new[] { RecordingPipeline.EvenSize(2559, 1439).Width, RecordingPipeline.EvenSize(2559, 1439).Height });
        CollectionAssert.AreEqual(
            new[] { 2, 2 }, new[] { RecordingPipeline.EvenSize(0, 1).Width, RecordingPipeline.EvenSize(0, 1).Height });
    }

    [TestMethod]
    public void CropClampsToMonitor()
    {
        var inside = RecordingPipeline.Crop(100, 200, 900, 800, 0, 0, 2560, 1440);
        Assert.AreEqual((100, 200, 900, 800), inside);

        var outside = RecordingPipeline.Crop(-100, -50, 200, 100, 0, 0, 2560, 1440);
        Assert.AreEqual((0, 0, 200, 100), outside);

        Assert.IsNull(RecordingPipeline.Crop(10, 10, 11, 100, 0, 0, 2560, 1440));
        Assert.IsNull(RecordingPipeline.Crop(3000, 10, 3100, 100, 0, 0, 2560, 1440));
    }

    [TestMethod]
    public void CropHandlesNegativeMonitorOrigin()
    {
        var crop = RecordingPipeline.Crop(-1920, 100, -1200, 900, -1920, 0, 0, 1080);
        Assert.AreEqual((0, 100, 720, 900), crop);
    }
}
