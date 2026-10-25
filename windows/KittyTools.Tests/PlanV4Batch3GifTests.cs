// 转 GIF 的单测：GIF 结构（头 / 循环扩展 / 两帧 / 尾）、缩放规则、抽帧步长。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class GifWriterTests
{
    private static byte[] Frame(int width, int height, byte b, byte g, byte r)
    {
        var bgra = new byte[width * height * 4];
        for (var index = 0; index < bgra.Length; index += 4)
        {
            bgra[index] = b;
            bgra[index + 1] = g;
            bgra[index + 2] = r;
            bgra[index + 3] = 255;
        }

        return bgra;
    }

    [TestMethod]
    public void WritesGif89aWithLoopAndFrames()
    {
        using var stream = new MemoryStream();
        using (var writer = new GifWriter(stream, 8, 8, 10))
        {
            writer.AddFrame(Frame(8, 8, 0, 0, 255));
            writer.AddFrame(Frame(8, 8, 0, 255, 0));
            writer.Finish();
        }

        var bytes = stream.ToArray();
        CollectionAssert.AreEqual("GIF89a"u8.ToArray(), bytes[..6]);
        Assert.AreEqual(0x3B, bytes[^1]);
        Assert.AreEqual(2, Count(bytes, new byte[] { 0x2C }));
        Assert.IsTrue(Contains(bytes, "NETSCAPE2.0"u8));
    }

    [TestMethod]
    public void EmptyGifStillValid()
    {
        using var stream = new MemoryStream();
        using (var writer = new GifWriter(stream, 4, 4))
        {
            writer.Finish();
        }

        var bytes = stream.ToArray();
        CollectionAssert.AreEqual("GIF89a"u8.ToArray(), bytes[..6]);
        Assert.AreEqual(0x3B, bytes[^1]);
    }

    private static int Count(byte[] haystack, byte[] needle)
    {
        var count = 0;
        for (var index = 0; index <= haystack.Length - needle.Length; index++)
        {
            var match = true;
            for (var inner = 0; inner < needle.Length; inner++)
            {
                if (haystack[index + inner] != needle[inner])
                {
                    match = false;
                    break;
                }
            }

            if (match)
            {
                count++;
            }
        }

        return count;
    }

    private static bool Contains(byte[] haystack, ReadOnlySpan<byte> needle)
        => haystack.AsSpan().IndexOf(needle) >= 0;
}

[TestClass]
public sealed class GifRulesTests
{
    [TestMethod]
    public void ScalesLongEdgeTo800()
    {
        Assert.AreEqual((800, 450), GifRules.TargetSize(2560, 1440));
        Assert.AreEqual((800, 800), GifRules.TargetSize(1200, 1200));
        Assert.AreEqual((640, 480), GifRules.TargetSize(640, 480));
        Assert.AreEqual((1, 1), GifRules.TargetSize(0, 0));
    }

    [TestMethod]
    public void SamplesAtTenFps()
    {
        Assert.AreEqual(1, GifRules.SampleStep(10));
        Assert.AreEqual(2, GifRules.SampleStep(15));
        Assert.AreEqual(3, GifRules.SampleStep(30));
        Assert.AreEqual(6, GifRules.SampleStep(60));
        Assert.AreEqual(1, GifRules.SampleStep(0));
        Assert.AreEqual(601, GifRules.MaxFrames(10));
    }

    [TestMethod]
    public void NearestScaleCopiesCorners()
    {
        var source = new byte[]
        {
            1, 2, 3, 255, 4, 5, 6, 255,
            7, 8, 9, 255, 10, 11, 12, 255,
        };
        var scaled = GifRules.NearestScale(source, 2, 2, 4, 4);
        Assert.AreEqual(4 * 4 * 4, scaled.Length);
        Assert.AreEqual(1, scaled[0]);
        Assert.AreEqual(4, scaled[3 * 4]);
        Assert.AreEqual(7, scaled[12 * 4]);
        Assert.AreEqual(10, scaled[15 * 4]);
    }
}
