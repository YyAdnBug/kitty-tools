// PLAN-v9 S11：长截图预览取哪一段、滚轮往回看、位置指示条、面板摆哪边、条带取样；R106：平滑取样、纸带 / 接缝 / 渐隐、高度数字滚动。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollPreviewTests
{
    [TestMethod]
    public void RangeFollowsTheNewestEnd()
    {
        Assert.AreEqual((700, 300), ScrollPreview.Range(1000, 300, null, growingUp: false));
        Assert.AreEqual((0, 300), ScrollPreview.Range(1000, 300, null, growingUp: true));
        // 整张放得下：就是整张。
        Assert.AreEqual((0, 200), ScrollPreview.Range(200, 300, null, growingUp: false));
        Assert.AreEqual((0, 0), ScrollPreview.Range(0, 300, null, growingUp: false));
    }

    [TestMethod]
    public void RangeClampsTheBrowsedStart()
    {
        Assert.AreEqual((100, 300), ScrollPreview.Range(1000, 300, 100, growingUp: false));
        Assert.AreEqual((700, 300), ScrollPreview.Range(1000, 300, 900, growingUp: false));
        Assert.AreEqual((0, 300), ScrollPreview.Range(1000, 300, -50, growingUp: false));
    }

    [TestMethod]
    public void BrowseMovesUpAndReturnsToFollowAtTheNewestEnd()
    {
        // 往下长：滚轮往上看前面的内容，滚回最下面回到跟随。
        Assert.AreEqual(500, ScrollPreview.Browse(null, 200, 1000, 300, growingUp: false));
        Assert.AreEqual(0, ScrollPreview.Browse(100, 400, 1000, 300, growingUp: false));
        Assert.IsNull(ScrollPreview.Browse(500, -250, 1000, 300, growingUp: false));
        // 往上长：最新的在最上面，滚轮往下看后面的内容，滚回顶上回到跟随。
        Assert.AreEqual(200, ScrollPreview.Browse(null, -200, 1000, 300, growingUp: true));
        Assert.IsNull(ScrollPreview.Browse(200, 300, 1000, 300, growingUp: true));
        // 整张都在预览里：没得看。
        Assert.IsNull(ScrollPreview.Browse(null, 100, 200, 300, growingUp: false));
    }

    [TestMethod]
    public void ScrubberTracksTheShownPart()
    {
        Assert.IsNull(ScrollPreview.Scrubber(300, 0, 300, 300));
        var (top, height) = ScrollPreview.Scrubber(300, 0, 300, 3000)!.Value;
        Assert.AreEqual(0, top, 1e-9);
        Assert.AreEqual(30, height, 1e-9);
        (top, height) = ScrollPreview.Scrubber(300, 2700, 300, 3000)!.Value;
        Assert.AreEqual(270, top, 1e-9);
        // 再长也不比 20 矮。
        (top, height) = ScrollPreview.Scrubber(300, 0, 300, 30000)!.Value;
        Assert.AreEqual(20, height, 1e-9);
    }

    [TestMethod]
    public void PanelGoesRightThenLeftThenInside()
    {
        // 工作区 0..1920 × 0..1040，面板 300 × 500，间隔 16。
        Assert.AreEqual((1016, 100), ScrollPreview.PanelOrigin(400, 100, 1000, 0, 0, 1920, 1040, 300, 500, 16));
        Assert.AreEqual((584, 100), ScrollPreview.PanelOrigin(900, 100, 1700, 0, 0, 1920, 1040, 300, 500, 16));
        Assert.AreEqual((1604, 0), ScrollPreview.PanelOrigin(0, 0, 1920, 0, 0, 1920, 1040, 300, 500, 16));
        // 选区贴着下边：面板往上挪，不出工作区。
        Assert.AreEqual((1016, 540), ScrollPreview.PanelOrigin(400, 900, 1000, 0, 0, 1920, 1040, 300, 500, 16));
    }

    [TestMethod]
    public void SampleReadsAcrossStrips()
    {
        // 宽 4，每帧 100 行，往下滚 50 行：拼成 150 行，第 row 行第 x 列的像素值是 row × 16 + x。
        static ScrollFrame Frame(int offset)
        {
            var pixels = new int[4 * 100];
            for (var row = 0; row < 100; row++)
            {
                for (var x = 0; x < 4; x++)
                {
                    pixels[row * 4 + x] = (offset + row) * 16 + x;
                }
            }

            return new ScrollFrame(4, 100, pixels);
        }

        var canvas = new ScrollCanvas(Frame(0));
        Assert.IsTrue(canvas.Append(Frame(50), ScrollDirection.Down));
        Assert.AreEqual(150, canvas.Height);
        // 第 90 行起 40 行按原大小取（跨了两条条带）：每个像素就是原来那个，透明度补成 255。
        var sample = canvas.Sample(90, 40, 4, 40);
        var expected = new int[4 * 40];
        for (var y = 0; y < 40; y++)
        {
            for (var x = 0; x < 4; x++)
            {
                expected[y * 4 + x] = Opaque((90 + y) * 16 + x);
            }
        }

        CollectionAssert.AreEqual(expected, sample);
        // 要的比剩下的多：只按剩下的那一行取，不读出界。
        Assert.AreEqual(Opaque(149 * 16), canvas.Sample(149, 10, 4, 10)[0]);
    }

    [TestMethod]
    public void SampleAveragesTheCoveredBlock()
    {
        // R106 平滑取样：黑白棋盘 4 × 4 缩成 1 个像素是 50% 灰（最近邻会是纯黑或纯白）。
        var checker = new int[16];
        for (var index = 0; index < 16; index++)
        {
            checker[index] = (index / 4 + index % 4) % 2 == 0 ? Opaque(0xFFFFFF) : Opaque(0);
        }

        Assert.AreEqual(Opaque(0x808080), new ScrollCanvas(new ScrollFrame(4, 4, checker)).Sample(0, 4, 1, 1)[0]);

        // 四个象限各一种颜色（透明度是 0，屏幕 DC 拷出来常这样）缩成 2 × 2：每个输出像素正好是它那个象限的颜色，透明度补成 255。
        const int red = 0xFF0000, green = 0x00FF00, blue = 0x0000FF, white = 0xFFFFFF;
        var quadrants = new int[16];
        for (var y = 0; y < 4; y++)
        {
            for (var x = 0; x < 4; x++)
            {
                quadrants[y * 4 + x] = (y < 2, x < 2) switch
                {
                    (true, true) => red,
                    (true, false) => green,
                    (false, true) => blue,
                    _ => white,
                };
            }
        }

        CollectionAssert.AreEqual(
            new[] { Opaque(red), Opaque(green), Opaque(blue), Opaque(white) },
            new ScrollCanvas(new ScrollFrame(4, 4, quadrants)).Sample(0, 4, 2, 2));

        // 一行灰阶 0、40、80、120、160、200、240、255 缩成 2 个像素：各取自己那半边的平均。
        var ramp = new[] { 0, 40, 80, 120, 160, 200, 240, 255 }.Select(v => v << 16 | v << 8 | v).ToArray();
        CollectionAssert.AreEqual(
            new[] { Opaque(60 * 0x010101), Opaque(214 * 0x010101) },
            new ScrollCanvas(new ScrollFrame(8, 1, ramp)).Sample(0, 1, 2, 1));
    }

    [TestMethod]
    public void EaseOutMatchesCoreAnimation()
    {
        Assert.AreEqual(0, ScrollPreview.EaseOut(0), 1e-12);
        Assert.AreEqual(1, ScrollPreview.EaseOut(1), 1e-12);
        Assert.AreEqual(1, ScrollPreview.EaseOut(1.5), 1e-12);
        // easeOut (0, 0, 0.58, 1) 的中点约 0.6846；ease-in-out (0.42, 0, 0.58, 1) 对称，中点正好 0.5。
        Assert.AreEqual(0.6846, ScrollPreview.EaseOut(0.5), 1e-4);
        Assert.AreEqual(0.5, ScrollPreview.CubicBezier(0.42, 0, 0.58, 1, 0.5), 1e-6);
        var previous = 0.0;
        for (var step = 1; step < 20; step++)
        {
            var t = step / 20.0;
            var value = ScrollPreview.EaseOut(t);
            Assert.IsTrue(value > previous && value >= t, $"t={t}");
            previous = value;
        }
    }

    [TestMethod]
    public void TapeSlidesFromTheGrowingEnd()
    {
        // 长图 800 宽、预览 200 DIP 宽：新拼上 400 行 = 预览里 100 DIP。往下长从下面推上来（正），往上长从上面推下来（负）。
        Assert.AreEqual(100, ScrollPreview.TapeStart(400, 200, 800, 300, growingUp: false, current: 0), 1e-9);
        Assert.AreEqual(-100, ScrollPreview.TapeStart(400, 200, 800, 300, growingUp: true, current: 0), 1e-9);
        // 上一段还没滑完（还差 10）：接着算，旧内容不跳；推得再远也不超过预览高。
        Assert.AreEqual(110, ScrollPreview.TapeStart(400, 200, 800, 300, growingUp: false, current: 10), 1e-9);
        Assert.AreEqual(300, ScrollPreview.TapeStart(4000, 200, 800, 300, growingUp: false, current: 0), 1e-9);
        Assert.AreEqual(-300, ScrollPreview.TapeStart(4000, 200, 800, 300, growingUp: true, current: 0), 1e-9);

        // 0.2 s easeOut 滑回 0：开头在原处，50 ms 时已经走了大约 38%，到点正好是 0。
        Assert.AreEqual(100, ScrollPreview.TapeOffset(100, 0), 1e-9);
        Assert.AreEqual(62.19, ScrollPreview.TapeOffset(100, 0.05), 0.01);
        Assert.AreEqual(0, ScrollPreview.TapeOffset(100, ScrollPreview.TapeSeconds), 1e-12);
        Assert.AreEqual(0, ScrollPreview.TapeOffset(-100, 1), 1e-12);
    }

    [TestMethod]
    public void SeamFlashFadesAndEdgesFade()
    {
        Assert.AreEqual(0.25, ScrollPreview.SeamOpacity(0), 1e-9);
        Assert.AreEqual(0.125, ScrollPreview.SeamOpacity(0.2), 1e-9);
        Assert.AreEqual(0, ScrollPreview.SeamOpacity(0.4), 1e-9);
        Assert.AreEqual(0, ScrollPreview.SeamOpacity(3), 1e-9);
        // 上下渐隐 18 DIP，预览很矮时最多占 0.3。
        Assert.AreEqual(18, ScrollPreview.FadeHeight(300), 1e-9);
        Assert.AreEqual(12, ScrollPreview.FadeHeight(40), 1e-9);
        Assert.AreEqual(0, ScrollPreview.FadeHeight(0), 1e-9);
    }

    [TestMethod]
    public void PlacesAlignDigitsByPlaceValue()
    {
        // 只有变了的那几位滚。
        var places = ScrollPreview.Places(1234, 1250);
        CollectionAssert.AreEqual(
            new[] { new DigitPlace('1', '1'), new DigitPlace('2', '2'), new DigitPlace('3', '5'), new DigitPlace('4', '0') },
            places);
        CollectionAssert.AreEqual(new[] { false, false, true, true }, places.Select(place => place.Changed).ToArray());
        // 位数变多：新长出来的高位原来没有；个位对个位。
        CollectionAssert.AreEqual(
            new[] { new DigitPlace(null, '1'), new DigitPlace('9', '0'), new DigitPlace('9', '0'), new DigitPlace('9', '0') },
            ScrollPreview.Places(999, 1000));
        // 位数变少：没了的高位现在没有。
        CollectionAssert.AreEqual(
            new[] { new DigitPlace('1', null), new DigitPlace('2', '9'), new DigitPlace('0', '5') },
            ScrollPreview.Places(120, 95));
        // 不分组。
        Assert.AreEqual(5, ScrollPreview.Places(0, 12000).Length);

        Assert.AreEqual(1, ScrollPreview.RollDirection(600, 950));
        Assert.AreEqual(-1, ScrollPreview.RollDirection(950, 600));
        Assert.AreEqual(0, ScrollPreview.RollDirection(950, 950));
    }

    private static int Opaque(int rgb) => unchecked((int)0xFF000000) | rgb;
}
