// 录屏压缩的纯规则：60% 目标、质量阶梯、输出文件名。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CompressionRulesTests
{
    [TestMethod]
    public void TargetIsSixtyPercent()
    {
        Assert.IsTrue(CompressionRules.IsSmallEnough(1000, 600));
        Assert.IsFalse(CompressionRules.IsSmallEnough(1000, 601));
        Assert.IsFalse(CompressionRules.IsSmallEnough(0, 0));
    }

    [TestMethod]
    public void QualityLadder()
    {
        Assert.AreEqual(0.5f, CompressionRules.QualityFor(0));
        Assert.AreEqual(0.35f, CompressionRules.QualityFor(1));
        Assert.AreEqual(0.25f, CompressionRules.QualityFor(2));
        Assert.AreEqual(0.25f, CompressionRules.QualityFor(9));
    }

    [TestMethod]
    public void OutputName()
    {
        var path = CompressionRules.OutputPath(@"C:\Videos\录屏 2026-10-25.avi");
        Assert.AreEqual(@"C:\Videos\录屏 2026-10-25 压缩版.avi", path);
    }
}
