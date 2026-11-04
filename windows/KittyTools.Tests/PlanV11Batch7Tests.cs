// PLAN-v11 第 7 批：标注里的「裁剪」（F11）——算不算裁剪、裁剪框换成像素、按像素裁 BGRA。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV11Batch7Tests
{
    [TestMethod]
    public void CropMustSitInsideAndBeSmaller()
    {
        var original = new RectD(100, 50, 400, 300);
        Assert.IsTrue(ImageCrop.IsCropOf(new RectD(120, 60, 200, 100), original));
        // 只裁掉一条边
        Assert.IsTrue(ImageCrop.IsCropOf(new RectD(100, 50, 400, 250), original));
        // 一样大（差不到半个像素）不算
        Assert.IsFalse(ImageCrop.IsCropOf(new RectD(100.2, 50, 399.9, 300), original));
        // 伸到原图外面（框了别的范围）不算
        Assert.IsFalse(ImageCrop.IsCropOf(new RectD(90, 60, 200, 100), original));
        Assert.IsFalse(ImageCrop.IsCropOf(new RectD(300, 60, 250, 100), original));
    }

    [TestMethod]
    public void ClampRoundsAndStaysInside()
    {
        Assert.AreEqual(new CropRect(10, 20, 30, 40), ImageCrop.Clamp(new RectD(9.6, 20.4, 30.2, 39.8), 100, 100));
        Assert.AreEqual(new CropRect(0, 0, 100, 50), ImageCrop.Clamp(new RectD(-5, -5, 200, 200), 100, 50));
        // 退化成 0 宽也至少留 1 像素
        Assert.AreEqual(new CropRect(99, 49, 1, 1), ImageCrop.Clamp(new RectD(120, 80, 0, 0), 100, 50));
    }

    [TestMethod]
    public void CropCopiesTheRightPixels()
    {
        const int width = 4;
        const int height = 3;
        var bgra = new byte[width * height * 4];
        for (var i = 0; i < width * height; i++)
        {
            bgra[i * 4] = (byte)i;
            bgra[i * 4 + 3] = 255;
        }

        var cropped = ImageCrop.Crop(bgra, width, height, new CropRect(1, 1, 2, 2));
        Assert.AreEqual(16, cropped.Length);
        // 第 1 行第 1、2 个像素是 5、6，第 2 行是 9、10
        CollectionAssert.AreEqual(new byte[] { 5, 6, 9, 10 }, new[] { cropped[0], cropped[4], cropped[8], cropped[12] });
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => ImageCrop.Crop(bgra, width, height, new CropRect(3, 0, 2, 1)));
    }
}
