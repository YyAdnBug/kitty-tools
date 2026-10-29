// REVIEW R43：长截图拍的过程改成条带（ScrollCanvas），拼出来的必须和以前逐帧整张拼（ScrollStitcher.Stitch）逐像素一样。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollCanvasTests
{
    private const int Width = 48;
    private const int Header = 20;

    /// <summary>页面第 row 行的像素：每行都不一样，行里每个像素也不一样。</summary>
    private static int Pixel(int row, int x) => unchecked((int)(0xFF000000u | (uint)((row * 2654435761u) ^ (uint)(x * 40503)) & 0xFFFFFFu));

    /// <summary>一帧：最上面 Header 行是吸顶栏（每帧都一样），下面是页面从 offset 起的那一段。</summary>
    private static ScrollFrame Frame(int offset, int height)
    {
        var pixels = new int[Width * height];
        for (var row = 0; row < height; row++)
        {
            for (var x = 0; x < Width; x++)
            {
                pixels[row * Width + x] = row < Header ? Pixel(-1 - row, x) : Pixel(offset + row - Header, x);
            }
        }

        return new ScrollFrame(Width, height, pixels);
    }

    private static void AssertSame(IReadOnlyList<ScrollFrame> frames, ScrollDirection direction)
    {
        var expected = ScrollStitcher.Stitch(frames, direction);
        var canvas = new ScrollCanvas(frames[0]);
        foreach (var frame in frames.Skip(1))
        {
            canvas.Append(frame, direction);
            if (canvas.Height >= ScrollStitcher.MaxOutputHeight)
            {
                break;
            }
        }

        var actual = canvas.Compose();
        Assert.AreEqual(expected.Height, actual.Height);
        CollectionAssert.AreEqual(expected.Pixels, actual.Pixels);
    }

    [TestMethod]
    public void DownMatchesWholeImageStitching()
    {
        // 每拍滚 0–270 行（0 = 没动），中间夹一帧不相干的（接不上，两边都跳过），长到比找重叠看的那几行高得多（约 15000 行）。
        var random = new Random(5);
        var frames = new List<ScrollFrame>();
        var offset = 0;
        for (var index = 0; index < 120; index++)
        {
            frames.Add(index == 30 ? Frame(1_000_000, 300) : Frame(offset, 300));
            offset += random.Next(0, 271);
        }

        AssertSame(frames, ScrollDirection.Down);
    }

    [TestMethod]
    public void UpMatchesWholeImageStitching()
    {
        var random = new Random(7);
        var frames = new List<ScrollFrame>();
        var offset = 20_000;
        for (var index = 0; index < 60; index++)
        {
            frames.Add(Frame(offset, 300));
            offset -= random.Next(0, 251);
        }

        AssertSame(frames, ScrollDirection.Up);
    }

    [TestMethod]
    public void TallFramesStopAtTheCapLikeBefore()
    {
        var frames = new List<ScrollFrame>();
        for (var index = 0; index < 60; index++)
        {
            frames.Add(Frame(index * 600, 1200));
        }

        AssertSame(frames, ScrollDirection.Down);
    }
}
