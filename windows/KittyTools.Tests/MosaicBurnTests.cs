// 马赛克打进原图（第四轮体检 E6，PLAN-v11 M4）：框里每格一种颜色、框外不动，格子跨出选区时取色照整屏。
// 另有 PngInfo（PLAN-v11 M16：角落卡按图本身的像素算尺寸）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class MosaicBurnTests
{
    [TestMethod]
    public void CellsBecomeOneColorAndOutsideIsUntouched()
    {
        var image = Gradient(8, 8);
        var before = (byte[])image.Clone();

        MosaicBurn.Apply(image, 8, 8, new RectD(2, 2, 4, 4), 2, image, 8, 8, 0, 0);

        // 框里：每个 2 × 2 的格子四个像素同一个颜色，而且和原来那个格子不完全一样（原图是渐变）。
        for (var cellY = 2; cellY < 6; cellY += 2)
        {
            for (var cellX = 2; cellX < 6; cellX += 2)
            {
                var first = Pixel(image, 8, cellX, cellY);
                Assert.AreEqual(first, Pixel(image, 8, cellX + 1, cellY));
                Assert.AreEqual(first, Pixel(image, 8, cellX, cellY + 1));
                Assert.AreEqual(first, Pixel(image, 8, cellX + 1, cellY + 1));
            }
        }

        Assert.AreNotEqual(Pixel(before, 8, 3, 3), Pixel(image, 8, 3, 3));

        // 框外一个像素都没变，透明度也没动。
        for (var y = 0; y < 8; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                var inside = x is >= 2 and < 6 && y is >= 2 and < 6;
                if (!inside)
                {
                    Assert.AreEqual(Pixel(before, 8, x, y), Pixel(image, 8, x, y), $"({x}, {y})");
                }

                Assert.AreEqual(255, image[(y * 8 + x) * 4 + 3]);
            }
        }
    }

    [TestMethod]
    public void CropGetsTheSameColorsAsTheWholeScreen()
    {
        // 选区从 (3, 0) 起、宽 5：格子 (2..4) 跨在选区左边上，取色要照整屏（和屏幕上画的一样），只写进选区里那半格。
        var screen = Gradient(8, 4);
        var whole = (byte[])screen.Clone();
        MosaicBurn.Apply(screen, 8, 4, new RectD(2, 0, 4, 4), 2, whole, 8, 4, 0, 0);

        var crop = new byte[5 * 4 * 4];
        for (var y = 0; y < 4; y++)
        {
            Buffer.BlockCopy(screen, (y * 8 + 3) * 4, crop, y * 5 * 4, 5 * 4);
        }

        MosaicBurn.Apply(screen, 8, 4, new RectD(2, 0, 4, 4), 2, crop, 5, 4, 3, 0);

        for (var y = 0; y < 4; y++)
        {
            for (var x = 0; x < 5; x++)
            {
                Assert.AreEqual(Pixel(whole, 8, x + 3, y), Pixel(crop, 5, x, y), $"({x}, {y})");
            }
        }
    }

    [TestMethod]
    public void AverageSamplesEveryStepPixels()
    {
        // 12 宽的格子：step = 2，只抽 x = 0, 2, 4…；单行，抽到的 6 个蓝通道是 0, 20, 40, 60, 80, 100 → 平均 50。
        var row = new byte[12 * 4];
        for (var x = 0; x < 12; x++)
        {
            row[x * 4] = (byte)(x * 10);
        }

        Assert.AreEqual(((byte)0, (byte)0, (byte)50), MosaicBurn.Average(row, 12, 0, 0, 12, 1));
    }

    private static byte[] Gradient(int width, int height)
    {
        var bgra = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var index = (y * width + x) * 4;
                bgra[index] = (byte)(x * 30);
                bgra[index + 1] = (byte)(y * 30);
                bgra[index + 2] = (byte)((x + y) * 15);
                bgra[index + 3] = 255;
            }
        }

        return bgra;
    }

    private static (byte, byte, byte, byte) Pixel(byte[] bgra, int width, int x, int y)
    {
        var index = (y * width + x) * 4;
        return (bgra[index], bgra[index + 1], bgra[index + 2], bgra[index + 3]);
    }
}

[TestClass]
public sealed class PngInfoTests
{
    [TestMethod]
    public void ReadsWidthAndHeightFromTheHeader()
    {
        // 签名 + IHDR 块头（长度 13）+ 宽 1200、高 30000（大端）；后面的内容不看。
        var png = new byte[]
        {
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R',
            0, 0, 0x04, 0xB0, 0, 0, 0x75, 0x30,
            8, 6, 0, 0, 0,
        };
        Assert.AreEqual((1200, 30000), PngInfo.Size(png)!.Value);
        Assert.IsNull(PngInfo.Size(png[..20]), "头不完整");
        Assert.IsNull(PngInfo.Size(new byte[32]), "不是 PNG");
    }
}
