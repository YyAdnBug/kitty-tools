// 长截图自动滚动（Core ScrollPacer，照 mac 389289d4）：每帧发一小段滚轮、按实际滚了多少校准倍率、对不上退回放慢、
// 老程序攒满一格才滚也不算到头、滚到头停下；很高的选区每帧滚得少也拼得上（重叠在整帧里找）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollPacerTests
{
    /// <summary>
    /// 一个「窗口」：一个滚轮单位滚 pixelsPerUnit 像素（老程序 accumulate = true 时攒满 120 才滚，按整格滚）；
    /// limit：最多滚到这么多像素（到底了）。返回这一下滚了多少像素。
    /// </summary>
    private sealed class FakeWindow(double pixelsPerUnit, bool accumulate = false, double limit = double.MaxValue)
    {
        private int _pending;

        public double Page { get; private set; }

        public void Wheel(int delta)
        {
            double moved;
            if (!accumulate)
            {
                moved = delta * pixelsPerUnit;
            }
            else
            {
                _pending += delta;
                var notches = _pending / ScrollPacer.Notch;
                _pending -= notches * ScrollPacer.Notch;
                moved = notches * ScrollPacer.Notch * pixelsPerUnit;
            }

            Page = Math.Clamp(Page + moved, 0, limit);
        }
    }

    /// <summary>
    /// 跑 seconds 秒：60 Hz 每帧发一段，每 10 帧（约 160 ms）抓一帧、当场拼完喂给 After（同 ScrollingCapture）。
    /// 拼接看到的：没动 = Unchanged；离参照帧滚过了选区高减 MinOverlap = 对不上；否则拼上了 shift 行。返回停在哪一帧（没停 = -1）。
    /// </summary>
    private static int Run(ScrollPacer pacer, FakeWindow window, int height, double seconds, List<double>? pages = null)
    {
        var reference = window.Page;
        var frames = (int)(seconds * 60);
        for (var frame = 0; frame < frames; frame++)
        {
            window.Wheel(pacer.Frame(1 / 60.0));
            if (frame % 10 != 9)
            {
                continue;
            }

            pacer.Captured();
            var shift = window.Page - reference;
            ScrollStep step;
            if (Math.Abs(shift) < 0.5)
            {
                step = ScrollStep.Unchanged;
            }
            else if (shift > height - ScrollStitcher.MinOverlap || shift < 0)
            {
                step = ScrollStep.Lost;
            }
            else
            {
                step = ScrollStep.Moved;
                reference = window.Page;
            }

            var back = pacer.After(step, (int)Math.Round(shift));
            if (back > 0)
            {
                window.Wheel(-back);
            }

            pages?.Add(window.Page);
            if (pacer.Stopped != ScrollStopReason.None)
            {
                return frame;
            }
        }

        return -1;
    }

    [TestMethod]
    public void Speeds_AreHeightsPerSecond()
    {
        Assert.AreEqual(0.3, ScrollPacer.HeightsPerSecond(ScrollSpeed.Slow));
        Assert.AreEqual(0.6, ScrollPacer.HeightsPerSecond(ScrollSpeed.Normal));
        Assert.AreEqual(1.2, ScrollPacer.HeightsPerSecond(ScrollSpeed.Fast));
        // 600 高、一个单位 1 像素：标准每秒 360 个单位。
        Assert.AreEqual(360, ScrollPacer.VelocityFor(ScrollSpeed.Normal, 600, 1), 1e-9);
        // 上下限：每秒至少 10 个单位、最多 30 格。
        Assert.AreEqual(10, ScrollPacer.VelocityFor(ScrollSpeed.Slow, 10, 100), 1e-9);
        Assert.AreEqual(ScrollPacer.Notch * 30, ScrollPacer.VelocityFor(ScrollSpeed.Fast, 4000, 0.01), 1e-9);
        Assert.AreEqual("slow", ScrollPacer.Name(ScrollSpeed.Slow));
        Assert.AreEqual(ScrollSpeed.Fast, ScrollPacer.Parse(ScrollPacer.Name(ScrollSpeed.Fast)));
    }

    [TestMethod]
    public void Calibrated_AveragesAndIgnoresShortSegments()
    {
        var guess = ScrollPacer.InitialGain(1);
        // 发了 100 个单位滚了 50 像素：新旧各半。
        Assert.AreEqual((guess + 0.5) / 2, ScrollPacer.Calibrated(guess, 50, 100, 1), 1e-9);
        // 发得太少、没往前滚：不算。
        Assert.AreEqual(guess, ScrollPacer.Calibrated(guess, 50, 5, 1), 1e-9);
        Assert.AreEqual(guess, ScrollPacer.Calibrated(guess, 0, 100, 1), 1e-9);
        // 夹在猜的 1/20 到 20 倍。
        Assert.AreEqual(guess * 20, ScrollPacer.Calibrated(guess * 20, 100000, 100, 1), 1e-9);
        Assert.AreEqual(guess / 20, ScrollPacer.Calibrated(guess / 20, 0.001, 1000, 1), 1e-9);
    }

    [TestMethod]
    public void FrameUnits_CarryAndCap()
    {
        // 每秒 100 个单位、60 Hz：每帧 1.67，零头留着，三帧发 5 个。
        var carry = 0.0;
        var total = 0;
        for (var i = 0; i < 3; i++)
        {
            (var units, carry) = ScrollPacer.FrameUnits(100, 1 / 60.0, carry);
            total += units;
        }

        Assert.AreEqual(5, total);
        // 卡了一秒：只按 50 ms 算。
        Assert.AreEqual(5, ScrollPacer.FrameUnits(100, 1, 0).Units);
        Assert.AreEqual(0, ScrollPacer.FrameUnits(100, -1, 0).Units);
    }

    [TestMethod]
    public void SmoothWindow_CalibratesToTargetSpeed()
    {
        // 一个单位只滚 0.5 像素（猜的是 0.83）、选区 600 高：校准后标准档每秒约 360 像素。
        const int height = 600;
        var window = new FakeWindow(0.5);
        var pacer = new ScrollPacer(height, 1, ScrollSpeed.Normal);
        pacer.Begin();
        var pages = new List<double>();
        Assert.AreEqual(-1, Run(pacer, window, height, 6, pages), "一直在往下滚，不该停");
        Assert.AreEqual(0.5, pacer.Gain, 0.05);
        // 最后 3 秒（约 18 次抓帧）滚了多少。
        var last = pages[^1] - pages[^19];
        Assert.AreEqual(360 * 18 * 10 / 60.0, last, 360 * 3 * 0.15);
    }

    [TestMethod]
    public void PageScrollWindow_SlowsDownWithoutLosingTrack()
    {
        // 「一次滚一屏」那种：一格滚 600 像素 = 选区高。猜的倍率小了 6 倍，开头一帧滚得多，也不该对不上。
        const int height = 600;
        var window = new FakeWindow(600.0 / ScrollPacer.Notch);
        var pacer = new ScrollPacer(height, 1, ScrollSpeed.Fast);
        pacer.Begin();
        Assert.AreEqual(-1, Run(pacer, window, height, 4));
        Assert.AreEqual(5, pacer.Gain, 0.5);
    }

    [TestMethod]
    public void AccumulatingWindow_KeepsGoing()
    {
        // 老程序攒满一格才滚（一格 60 像素）：攒着的那几帧画面不动，不能当成到头。
        const int height = 400;
        var window = new FakeWindow(60.0 / ScrollPacer.Notch, accumulate: true);
        var pacer = new ScrollPacer(height, 1, ScrollSpeed.Slow);
        pacer.Begin();
        Assert.AreEqual(-1, Run(pacer, window, height, 6));
        Assert.IsTrue(window.Page > 400, $"6 秒滚了 {window.Page} 像素");
    }

    [TestMethod]
    public void ReachingTheEnd_Stops()
    {
        const int height = 600;
        var window = new FakeWindow(1, limit: 900);
        var pacer = new ScrollPacer(height, 1, ScrollSpeed.Normal);
        pacer.Begin();
        Assert.AreNotEqual(-1, Run(pacer, window, height, 10));
        Assert.AreEqual(ScrollStopReason.End, pacer.Stopped);
        Assert.AreEqual(900, window.Page);
    }

    [TestMethod]
    public void Lost_BacksOffHalfThenStopsAfterFour()
    {
        var pacer = new ScrollPacer(600, 1, ScrollSpeed.Normal);
        pacer.Begin();
        for (var i = 0; i < 30; i++)
        {
            pacer.Frame(1 / 60.0);
        }

        pacer.Captured();
        var posted = pacer.Posted;
        var velocity = pacer.Velocity;
        var back = pacer.After(ScrollStep.Lost, 0);
        Assert.AreEqual((int)Math.Round(posted / 2), back, "退回自上次接上以来发的一半");
        Assert.AreEqual(posted - back, pacer.Posted);
        Assert.AreEqual(velocity / 2, pacer.Velocity, 1e-9, "先放慢一半");
        pacer.After(ScrollStep.Lost, 0);
        pacer.After(ScrollStep.Lost, 0);
        Assert.AreEqual(ScrollStopReason.None, pacer.Stopped);
        pacer.After(ScrollStep.Lost, 0);
        Assert.AreEqual(ScrollStopReason.Lost, pacer.Stopped);

        // 接着滚：计数清零、速度按档算回来。
        pacer.Begin();
        Assert.AreEqual(ScrollStopReason.None, pacer.Stopped);
        Assert.AreEqual(velocity, pacer.Velocity, 1e-9);
    }

    [TestMethod]
    public void NoWheelSent_IsNotAStall()
    {
        // 光标停在面板上（这几帧不发）：画面不动不算到头。
        var pacer = new ScrollPacer(600, 1, ScrollSpeed.Normal);
        pacer.Begin();
        for (var i = 0; i < 10; i++)
        {
            pacer.Captured();
            pacer.After(ScrollStep.Unchanged, 0);
        }

        Assert.AreEqual(ScrollStopReason.None, pacer.Stopped);
    }

    [TestMethod]
    public void SetSpeed_TakesEffectNextFrame()
    {
        var pacer = new ScrollPacer(600, 1, ScrollSpeed.Normal);
        var normal = pacer.Velocity;
        pacer.SetSpeed(ScrollSpeed.Fast);
        Assert.AreEqual(normal * 2, pacer.Velocity, 1e-9);
        Assert.AreEqual(ScrollSpeed.Fast, pacer.Speed);
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
