// PLAN-v26 S8：钉图上拖选字的纯函数（PinTextSelection）。两行：一行中文（一个字一个词框，Windows 识字就是这么给的）、一行英文。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PinTextSelectionTests
{
    private static readonly OcrLine[] Lines =
    {
        new("你好世界", new RectD(10, 10, 80, 20), new[]
        {
            new OcrWord("你", new RectD(10, 10, 20, 20)),
            new OcrWord("好", new RectD(30, 10, 20, 20)),
            new OcrWord("世", new RectD(50, 10, 20, 20)),
            new OcrWord("界", new RectD(70, 10, 20, 20)),
        }),
        new("hello big world", new RectD(10, 50, 150, 20), new[]
        {
            new OcrWord("hello", new RectD(10, 50, 50, 20)),
            new OcrWord("big", new RectD(70, 50, 30, 20)),
            new OcrWord("world", new RectD(110, 50, 50, 20)),
        }),
    };

    [TestMethod]
    public void HitOnlyOnWords()
    {
        var words = PinTextSelection.Flatten(Lines);
        Assert.AreEqual(7, words.Count);
        Assert.AreEqual(1, PinTextSelection.Hit(words, 35, 15, 2));
        Assert.AreEqual(4, PinTextSelection.Hit(words, 20, 60, 2));
        Assert.IsNull(PinTextSelection.Hit(words, 200, 200, 2), "空白处：挪钉图");
        Assert.AreEqual(5, PinTextSelection.Hit(words, 101, 60, 2), "词框外扩 2 像素也算");
    }

    [TestMethod]
    public void TextJoinsLikeRecognition()
    {
        var words = PinTextSelection.Flatten(Lines);
        Assert.AreEqual("好世", PinTextSelection.Text(words, 1, 2), "中文之间不加空格");
        Assert.AreEqual("世界\nhello big", PinTextSelection.Text(words, 5, 2), "倒着拖一样；跨行接换行");
        Assert.AreEqual("你好世界\nhello big world", PinTextSelection.Text(words, 0, words.Count - 1));
    }

    [TestMethod]
    public void NearestKeepsSelectingOffText()
    {
        var words = PinTextSelection.Flatten(Lines);
        Assert.AreEqual(6, PinTextSelection.Nearest(words, 400, 58), "拖到第二行右边外面：最后一个词");
        Assert.AreEqual(0, PinTextSelection.Nearest(words, 0, 0), "左上角外面：第一个词");
        Assert.AreEqual(3, PinTextSelection.Nearest(words, 95, 31), "两行之间离第一行近");
        Assert.IsNull(PinTextSelection.Nearest(PinTextSelection.Flatten(Array.Empty<OcrLine>()), 1, 1));
    }

    [TestMethod]
    public void OneBoxPerLine()
    {
        var words = PinTextSelection.Flatten(Lines);
        var boxes = PinTextSelection.Boxes(words, 2, 5);
        Assert.AreEqual(2, boxes.Count);
        Assert.AreEqual(RectD.FromLtrb(50, 10, 90, 30), boxes[0]);
        Assert.AreEqual(RectD.FromLtrb(10, 50, 100, 70), boxes[1]);
    }

    [TestMethod]
    public void LineWithoutWordsIsOneWord()
    {
        var words = PinTextSelection.Flatten(new[] { new OcrLine("整行", new RectD(0, 0, 40, 20)) });
        Assert.AreEqual(1, words.Count);
        Assert.AreEqual("整行", PinTextSelection.Text(words, 0, 0));
    }
}
