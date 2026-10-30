// PLAN-v9 S11：长截图预览取哪一段、滚轮往回看、位置指示条、面板摆哪边、条带取样。
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
        // 宽 4，每帧 100 行，往下滚 50 行：拼成 150 行，第 row 行的像素值就是 row。
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
        // 第 90 行起 40 行缩成 2 × 4：取第 90、100、110、120 行（跨了两条条带）的第 0、2 列。
        var sample = canvas.Sample(90, 40, 2, 4);
        CollectionAssert.AreEqual(
            new[] { 90 * 16, 90 * 16 + 2, 100 * 16, 100 * 16 + 2, 110 * 16, 110 * 16 + 2, 120 * 16, 120 * 16 + 2 },
            sample);
    }
}
