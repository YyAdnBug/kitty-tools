// 录屏压缩的纯规则：60% 目标、45% 码率、输出文件名。
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
    public void OutputName()
    {
        var path = CompressionRules.OutputPath(@"C:\Videos\录屏 2026-10-25.mp4");
        Assert.AreEqual(@"C:\Videos\录屏 2026-10-25 压缩版.mp4", path);
    }
}
