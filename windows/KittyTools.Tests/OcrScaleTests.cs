// 识字前放大（2026-10-29）：按字高定倍数、封顶、双线性缩放。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class OcrScaleTests
{
    [TestMethod]
    public void ScalesSmallTextTowardsIdealHeight()
    {
        Assert.AreEqual(2.5, OcrScale.Factor(16, 600, 200, 10000), 1e-9);
    }

    [TestMethod]
    public void LeavesLargeTextAlone()
    {
        Assert.AreEqual(1, OcrScale.Factor(40, 600, 200, 10000));
        Assert.AreEqual(1, OcrScale.Factor(36, 600, 200, 10000));
        Assert.AreEqual(1, OcrScale.Factor(90, 600, 200, 10000));
    }

    [TestMethod]
    public void TriesDoubleWhenNothingWasRecognized()
    {
        Assert.AreEqual(2, OcrScale.Factor(0, 300, 40, 10000), 1e-9);
    }

    [TestMethod]
    public void CapsByFactorDimensionAndPixels()
    {
        Assert.AreEqual(OcrScale.MaxFactor, OcrScale.Factor(5, 100, 50, 10000), 1e-9);
        Assert.AreEqual(2, OcrScale.Factor(10, 5000, 100, 10000), 1e-9);
        // 3000 × 2000 放 2 倍是 2400 万像素：按 1600 万封顶。
        Assert.AreEqual(Math.Sqrt(16_000_000.0 / 6_000_000), OcrScale.Factor(20, 3000, 2000, 10000), 1e-9);
    }

    [TestMethod]
    public void ResizesBilinearly()
    {
        // 1 × 2 的黑白两格放大到 4 × 2：中间两列是过渡色，两头是原色。
        var source = new byte[] { 0, 0, 0, 255, 200, 200, 200, 255 };
        var result = OcrScale.Resize(source, 2, 1, 4, 2);
        Assert.AreEqual(4 * 2 * 4, result.Length);
        Assert.AreEqual(0, result[0]);
        Assert.AreEqual(50, result[4]);
        Assert.AreEqual(150, result[8]);
        Assert.AreEqual(200, result[12]);
        Assert.AreEqual(255, result[15]);
        CollectionAssert.AreEqual(result[..16], result[16..]);
    }
}
