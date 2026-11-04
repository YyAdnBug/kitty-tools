// 长截图自动滚动的步子（Core ScrollPacer，2026-11-04 用户反馈太快）：按实际滚了多少调滚轮量、滚过头退回来、
// 老程序攒满一格才滚、滚到头停下；很高的选区每步滚得少也拼得上（重叠在整帧里找）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollPacerTests
{
    /// <summary>
    /// 一个「窗口」：一个滚轮单位滚 pixelsPerUnit 像素（老程序 accumulate = true 时攒满 120 才滚，按整格滚）。
    /// 返回这一步滚了多少像素。
    /// </summary>
    private sealed class FakeWindow(double pixelsPerUnit, bool accumulate = false)
    {
        private int _pending;

        public int Wheel(int delta)
        {
            if (!accumulate)
            {
                return (int)Math.Round(delta * pixelsPerUnit);
            }

            _pending += delta;
            var notches = _pending / ScrollPacer.Notch;
            _pending -= notches * ScrollPacer.Notch;
            return (int)Math.Round(notches * ScrollPacer.Notch * pixelsPerUnit);
        }
    }

    /// <summary>上一步滚了 moved 像素，选区高 height：拼接看到的是哪种（重叠不到 MinOverlap 就对不上）。</summary>
    private static (ScrollStep Step, int Shift) Observe(int moved, int height)
        => moved == 0 ? (ScrollStep.Unchanged, 0)
            : moved > height - ScrollStitcher.MinOverlap ? (ScrollStep.Lost, 0)
            : (ScrollStep.Moved, moved);

    [TestMethod]
    public void OneNotchScrollsPastSelection_StepShrinksToTarget()
    {
        // 选区 300 高，这个窗口一格就滚 300（「一次滚一屏」那种）：以前固定一格，帧帧对不上。
        const int height = 300;
        var window = new FakeWindow(300.0 / ScrollPacer.Notch);
        var pacer = new ScrollPacer(height, ScrollSpeed.Normal);
        var delta = pacer.Next(ScrollStep.Moved, height); // 第一帧
        var lost = 0;
        for (var i = 0; i < 20; i++)
        {
            var (step, shift) = Observe(window.Wheel(delta), height);
            if (step == ScrollStep.Lost)
            {
                lost++;
            }

            delta = pacer.Next(step, shift);
            Assert.AreNotEqual(0, delta, "一直在往下滚，不该停");
        }

        Assert.AreEqual(0, lost, "半格起步就够小，一次都不该滚过头");
        Assert.AreEqual(pacer.Target, window.Wheel(pacer.Delta), 3, "步子收敛到每步滚出选区高度的 25%");
    }

    [TestMethod]
    public void SmallNotch_StepGrowsAndStaysUnderMax()
    {
        // 一格只滚 20 像素的窗口、选区 1000 高：要发好几格。
        var window = new FakeWindow(20.0 / ScrollPacer.Notch);
        var pacer = new ScrollPacer(1000, ScrollSpeed.Fast);
        var delta = pacer.Next(ScrollStep.Moved, 1000);
        for (var i = 0; i < 10; i++)
        {
            var (step, shift) = Observe(window.Wheel(delta), 1000);
            delta = pacer.Next(step, shift);
        }

        Assert.AreEqual(ScrollPacer.MaxDelta, delta, "要 2400 单位才够 400 像素，夹在上限 10 格");
    }

    [TestMethod]
    public void Lost_BacksOffHalfThenStopsAfterFour()
    {
        var pacer = new ScrollPacer(400, ScrollSpeed.Normal);
        Assert.AreEqual(60, pacer.Next(ScrollStep.Moved, 400));
        Assert.AreEqual(-30, pacer.Next(ScrollStep.Lost, 0), "往回退半步");
        Assert.AreEqual(-15, pacer.Next(ScrollStep.Lost, 0));
        Assert.AreEqual(-ScrollPacer.MinDelta, pacer.Next(ScrollStep.Lost, 0), "退的量不小于下限");
        Assert.AreEqual(0, pacer.Next(ScrollStep.Lost, 0), "连着 4 次对不上就停");
        Assert.AreEqual(ScrollStopReason.Lost, pacer.Stopped);
    }

    [TestMethod]
    public void BackOffThenMoved_KeepsHalvedStepAndResetsLost()
    {
        var pacer = new ScrollPacer(400, ScrollSpeed.Normal);
        pacer.Next(ScrollStep.Moved, 400);
        Assert.AreEqual(-30, pacer.Next(ScrollStep.Lost, 0));
        // 退回来以后对上了：往回退的那一步不拿来量，照减半后的步子往前。
        Assert.AreEqual(30, pacer.Next(ScrollStep.Moved, 50));
        // 计数清零：再丢三次也不停。
        pacer.Next(ScrollStep.Lost, 0);
        pacer.Next(ScrollStep.Lost, 0);
        Assert.AreNotEqual(0, pacer.Next(ScrollStep.Lost, 0));
    }

    [TestMethod]
    public void AccumulatingWindow_RampsToFullNotchAndKeepsMoving()
    {
        // 老程序：不到一格不滚。起步半格画面不动，要加到一格；之后一直有进展、不会误判成到底。
        const int height = 600;
        var window = new FakeWindow(100.0 / ScrollPacer.Notch, accumulate: true);
        var pacer = new ScrollPacer(height, ScrollSpeed.Normal);
        var delta = pacer.Next(ScrollStep.Moved, height);
        var total = 0;
        for (var i = 0; i < 30; i++)
        {
            var moved = window.Wheel(delta);
            total += moved;
            var (step, shift) = Observe(moved, height);
            delta = pacer.Next(step, shift);
            Assert.AreNotEqual(0, delta, $"第 {i} 步不该停（{pacer.Stopped}）");
        }

        Assert.IsTrue(total >= 30 * 50, $"30 步至少滚出 1500 像素，实际 {total}");
    }

    [TestMethod]
    public void FullNotchesWithoutMovement_StopsAtEnd()
    {
        var pacer = new ScrollPacer(500, ScrollSpeed.Normal);
        Assert.AreEqual(60, pacer.Next(ScrollStep.Moved, 500));
        Assert.AreEqual(120, pacer.Next(ScrollStep.Unchanged, 0), "半格没动先加到一格");
        Assert.AreEqual(120, pacer.Next(ScrollStep.Unchanged, 0));
        Assert.AreEqual(120, pacer.Next(ScrollStep.Unchanged, 0));
        Assert.AreEqual(0, pacer.Next(ScrollStep.Unchanged, 0), "整格三次都没动 = 到底了");
        Assert.AreEqual(ScrollStopReason.End, pacer.Stopped);
    }

    [TestMethod]
    public void UnchangedRightAfterBackOff_DoesNotCountAsEnd()
    {
        var pacer = new ScrollPacer(500, ScrollSpeed.Normal);
        pacer.Next(ScrollStep.Moved, 500);
        pacer.Next(ScrollStep.Moved, 100); // 量出来：60 单位 100 像素 → 下一步 75 单位
        Assert.AreEqual(75, pacer.Delta);
        Assert.AreEqual(-37, pacer.Next(ScrollStep.Lost, 0));
        Assert.AreEqual(37, pacer.Next(ScrollStep.Unchanged, 0), "退回原处画面没变不算到底，也不加量");
    }

    [TestMethod]
    public void Reset_SkipsMeasuringTheStepBeforePause()
    {
        var pacer = new ScrollPacer(500, ScrollSpeed.Normal);
        pacer.Next(ScrollStep.Moved, 500);
        pacer.Next(ScrollStep.Moved, 100);
        var before = pacer.Delta;
        pacer.Reset();
        // 暂停时用户自己滚了一大段：这一拍长了 400 行，不该拿它算出更小的步子。
        Assert.AreEqual(before, pacer.Next(ScrollStep.Moved, 400));
    }

    [TestMethod]
    public void TargetShift_BySpeed()
    {
        Assert.AreEqual(60, ScrollPacer.TargetShift(500, ScrollSpeed.Slow), 0.001);
        Assert.AreEqual(125, ScrollPacer.TargetShift(500, ScrollSpeed.Normal), 0.001);
        Assert.AreEqual(200, ScrollPacer.TargetShift(500, ScrollSpeed.Fast), 0.001);
        Assert.AreEqual(240, ScrollPacer.TargetShift(2000, ScrollSpeed.Slow), 0.001, "高选区慢速也只滚 12%，不再被重叠上限逼快");
    }

    [TestMethod]
    public void TallSelection_SmallStepStillStitches()
    {
        // 1500 高的选区每步只滚 180（慢速）：重叠 1320 行，以前最多找 800 行、这一步对不上。
        var frames = new[] { Frame(0, 1500), Frame(180, 1500), Frame(360, 1500) };
        Assert.AreEqual(1320, ScrollStitcher.FindOverlap(frames[0], frames[1], ScrollDirection.Down));
        var canvas = new ScrollCanvas(frames[0]);
        Assert.IsTrue(canvas.Append(frames[1], ScrollDirection.Down));
        Assert.IsTrue(canvas.Append(frames[2], ScrollDirection.Down));
        Assert.AreEqual(1860, canvas.Height);
        CollectionAssert.AreEqual(Frame(0, 1860).Pixels, canvas.Compose().Pixels);

        // 往上滚同样。
        var up = new ScrollCanvas(Frame(360, 1500));
        Assert.IsTrue(up.Append(Frame(180, 1500), ScrollDirection.Up));
        Assert.AreEqual(1680, up.Height);
        CollectionAssert.AreEqual(Frame(180, 1680).Pixels, up.Compose().Pixels);
    }

    /// <summary>页面从 offset 起的 rows 行：每行都不一样（没有吸顶栏）。</summary>
    private static ScrollFrame Frame(int offset, int rows)
    {
        const int width = 16;
        var pixels = new int[width * rows];
        for (var row = 0; row < rows; row++)
        {
            for (var x = 0; x < width; x++)
            {
                pixels[row * width + x] = unchecked((int)(0xFF000000u | ((uint)(offset + row) * 2654435761u ^ (uint)(x * 40503)) & 0xFFFFFFu));
            }
        }

        return new ScrollFrame(width, rows, pixels);
    }

    [TestMethod]
    public void Parse_UnknownIsNormal()
    {
        Assert.AreEqual(ScrollSpeed.Slow, ScrollPacer.Parse("slow"));
        Assert.AreEqual(ScrollSpeed.Fast, ScrollPacer.Parse("fast"));
        Assert.AreEqual(ScrollSpeed.Normal, ScrollPacer.Parse("normal"));
        Assert.AreEqual(ScrollSpeed.Normal, ScrollPacer.Parse(null));
        Assert.AreEqual(ScrollSpeed.Normal, ScrollPacer.Parse("turbo"));
    }

    [TestMethod]
    public void Classify_SmallChangesAreUnchanged()
    {
        var previous = Enumerable.Range(0, 100).Select(row => (uint)row).ToArray();
        var caret = (uint[])previous.Clone();
        for (var row = 40; row < 49; row++)
        {
            caret[row] = 9999; // 光标闪：9 行变了
        }

        var scrolled = previous.Select(hash => hash + 1000).ToArray();
        Assert.IsTrue(ScrollPacer.Same(previous, (uint[])previous.Clone()));
        Assert.IsFalse(ScrollPacer.Same(null, previous));
        Assert.IsFalse(ScrollPacer.Same(previous, caret));
        Assert.AreEqual(ScrollStep.Unchanged, ScrollPacer.Classify(previous, caret, appended: false, grown: 0));
        Assert.AreEqual(ScrollStep.Lost, ScrollPacer.Classify(previous, scrolled, appended: false, grown: 0));
        Assert.AreEqual(ScrollStep.Unchanged, ScrollPacer.Classify(previous, scrolled, appended: true, grown: 0));
        Assert.AreEqual(ScrollStep.Moved, ScrollPacer.Classify(previous, scrolled, appended: true, grown: 30));
    }
}
