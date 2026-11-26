// PLAN-v26 O1：Windows 识字拆开的短词合回去（OcrText.JoinWords）、几个认错的汉字不把英文段当成中文（ScreenshotOverlay.IsCjkSource）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV26OcrTests
{
    [TestMethod]
    public void TightPiecesJoin()
    {
        // 量到的：「G|ot」0.14、「N|ew」0.16，真的词间 0.3 以上
        Assert.AreEqual("Got it", OcrText.JoinWords(new[] { ("G", 0.0, 10.0, 20.0), ("ot", 12.8, 30.0, 20.0), ("it", 38.4, 50.0, 20.0) }));
        Assert.AreEqual("New", OcrText.JoinWords(new[] { ("N", 0.0, 10.0, 20.0), ("ew", 13.2, 30.0, 20.0) }));
        Assert.AreEqual("Pin your", OcrText.JoinWords(new[] { ("Pin", 0.0, 30.0, 20.0), ("your", 38.0, 70.0, 20.0) }));
        Assert.AreEqual("a ,", OcrText.JoinWords(new[] { ("a", 0.0, 10.0, 20.0), (",", 11.0, 13.0, 20.0) }), "标点不并");
        Assert.AreEqual("a b", OcrText.JoinWords(new[] { ("a", 0.0, 0.0, 0.0), ("b", 0.0, 0.0, 0.0) }), "没有框照常加空格");
    }

    [TestMethod]
    public void StrayCjkDoesNotMakeEnglishChinese()
    {
        Assert.IsFalse(ScreenshotOverlay.IsCjkSource("Everything stays on this computer 生 nothing is uploaded unless you turn on sync."));
        Assert.IsTrue(ScreenshotOverlay.IsCjkSource("Kitty Tools 的剪贴板"));
        Assert.IsTrue(ScreenshotOverlay.IsCjkSource("剪贴板"));
        Assert.IsTrue(ScreenshotOverlay.IsCjkSource("日"), "只有一个汉字、没有字母");
        Assert.IsFalse(ScreenshotOverlay.IsCjkSource("Hello"));
    }
}
