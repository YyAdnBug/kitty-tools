// 第三版第 6 批的纯函数单测：长截图拼接（整行哈希投票、上下两个方向、吸顶栏、上限）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScrollStitcherTests
{
    private const int Width = 40;

    /// <summary>每行一个颜色（行号决定），方便精确检查拼接结果。</summary>
    private static ScrollFrame Frame(int firstRow, int rows)
    {
        var pixels = new int[Width * rows];
        for (var row = 0; row < rows; row++)
        {
            var value = (firstRow + row) & 0xFFFFFF;
            for (var x = 0; x < Width; x++)
            {
                pixels[row * Width + x] = unchecked((int)0xFF000000u) | (value & 0xFFFFFF);
            }
        }

        return new ScrollFrame(Width, rows, pixels);
    }

    [TestMethod]
    public void StitchesDownWithOverlap()
    {
        // 第 1 帧行 0–99；第 2 帧从 60 开始（重叠 40 行）。
        var first = Frame(0, 100);
        var second = Frame(60, 100);
        var stitched = ScrollStitcher.Append(first, second, ScrollDirection.Down);
        Assert.IsNotNull(stitched);
        Assert.AreEqual(160, stitched!.Height);
        Assert.AreEqual(first.Pixels[0], stitched.Pixels[0]);
        Assert.AreEqual(second.Pixels[99 * Width], stitched.Pixels[159 * Width]);
    }

    [TestMethod]
    public void StitchesUpWithOverlap()
    {
        var first = Frame(60, 100);   // 当前画面
        var second = Frame(0, 100);   // 往上滚，露出上面的内容
        var stitched = ScrollStitcher.Append(first, second, ScrollDirection.Up);
        Assert.IsNotNull(stitched);
        Assert.AreEqual(160, stitched!.Height);
        Assert.AreEqual(second.Pixels[0], stitched.Pixels[0]);
        Assert.AreEqual(first.Pixels[99 * Width], stitched.Pixels[159 * Width]);
    }

    [TestMethod]
    public void FindsExactOverlap()
    {
        var first = Frame(0, 80);
        var second = Frame(50, 80);
        Assert.AreEqual(30, ScrollStitcher.FindOverlap(first, second, ScrollDirection.Down));
    }

    [TestMethod]
    public void StickyHeaderIsNotCountedAsOverlap()
    {
        // 两帧最上面 20 行一样（吸顶栏），下面才是滚动的内容。
        var first = Frame(0, 100);
        var secondPixels = Frame(0, 100).Pixels.ToArray();
        var fresh = Frame(70, 100).Pixels;
        Array.Copy(fresh, 20 * Width, secondPixels, 20 * Width, 80 * Width);
        var second = new ScrollFrame(Width, 100, secondPixels);
        var stitched = ScrollStitcher.Append(first, second, ScrollDirection.Down);
        Assert.IsNotNull(stitched);
        // 重叠 30 行，吸顶栏那 20 行只算一次。
        Assert.AreEqual(170, stitched!.Height);
    }

    [TestMethod]
    public void RefusesUnrelatedFrames()
    {
        var a = Frame(0, 40);
        var b = new ScrollFrame(Width + 1, 40, new int[(Width + 1) * 40]);
        Assert.IsNull(ScrollStitcher.Append(a, b, ScrollDirection.Down));

        var random = new Random(7);
        var pixels = new int[Width * 40];
        for (var index = 0; index < pixels.Length; index++)
        {
            pixels[index] = random.Next(int.MinValue, int.MaxValue);
        }

        Assert.IsNull(ScrollStitcher.Append(Frame(0, 40), new ScrollFrame(Width, 40, pixels),
            ScrollDirection.Down));
    }

    [TestMethod]
    public void StitchManyAndCapHeight()
    {
        var frames = new List<ScrollFrame>
        {
            Frame(0, 100), Frame(40, 100), Frame(80, 100),
        };
        var stitched = ScrollStitcher.Stitch(frames, ScrollDirection.Down);
        Assert.AreEqual(180, stitched.Height);

        var tall = new List<ScrollFrame>();
        for (var index = 0; index < 60; index++)
        {
            tall.Add(Frame(index * 600, 1200));
        }

        Assert.AreEqual(ScrollStitcher.MaxOutputHeight, ScrollStitcher.Stitch(tall, ScrollDirection.Down).Height);
    }
}
