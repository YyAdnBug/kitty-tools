// PLAN-v6 第 3 批：八叉树调色板的单测（≤ 256 色、纯色保真、下标都在范围内）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class OctreeQuantizerTests
{
    [TestMethod]
    public void FewColorsArePreserved()
    {
        var pixels = new byte[4 * 4 * 4];
        for (var index = 0; index < 16; index++)
        {
            var offset = index * 4;
            pixels[offset] = (byte)(index % 2 == 0 ? 255 : 0); // B
            pixels[offset + 1] = 0;                            // G
            pixels[offset + 2] = (byte)(index % 2 == 0 ? 0 : 255); // R
            pixels[offset + 3] = 255;
        }

        var (indices, palette) = OctreeQuantizer.Quantize(pixels, 4, 4);
        Assert.AreEqual(16, indices.Length);
        Assert.AreEqual(768, palette.Length);
        Assert.AreEqual(2, indices.Distinct().Count());
    }

    [TestMethod]
    public void ManyColorsStayWithin256()
    {
        const int width = 64;
        const int height = 64;
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                pixels[offset] = (byte)(x * 4);
                pixels[offset + 1] = (byte)(y * 4);
                pixels[offset + 2] = (byte)((x + y) * 2);
                pixels[offset + 3] = 255;
            }
        }

        var (indices, palette) = OctreeQuantizer.Quantize(pixels, width, height);
        Assert.AreEqual(width * height, indices.Length);
        Assert.AreEqual(256 * 3, palette.Length);
        Assert.IsTrue(indices.Distinct().Count() <= 256);
    }
}
