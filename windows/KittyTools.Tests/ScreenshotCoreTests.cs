// 框选几何和识字整理的纯函数单测；坐标按 Windows 的物理像素、原点左上。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RegionMathTests
{
    private static readonly RectD Bounds = new(0, 0, 1200, 800);

    [TestMethod]
    public void DrawnFollowsPointerAnyDirection()
    {
        Assert.AreEqual(new RectD(300, 200, 400, 300),
            RegionMath.Drawn(new PointD(300, 200), new PointD(700, 500), Bounds));
        Assert.AreEqual(new RectD(100, 50, 200, 150),
            RegionMath.Drawn(new PointD(300, 200), new PointD(100, 50), Bounds));
    }

    [TestMethod]
    public void DrawnSquareUsesLongerSide()
    {
        Assert.AreEqual(new RectD(300, 200, 200, 200),
            RegionMath.Drawn(new PointD(300, 200), new PointD(500, 260), Bounds, ratio: 1));
        Assert.AreEqual(new RectD(0, 100, 300, 300),
            RegionMath.Drawn(new PointD(300, 400), new PointD(250, 100), Bounds, ratio: 1));
        var wide = RegionMath.Drawn(new PointD(100, 100), new PointD(260, 130), Bounds, 16.0 / 9);
        Assert.AreEqual(100, wide.X);
        Assert.AreEqual(100, wide.Y);
        Assert.AreEqual(160, wide.Width, 1e-9);
        Assert.AreEqual(16.0 / 9, wide.Width / wide.Height, 1e-9);
    }

    [TestMethod]
    public void DrawnFromCenter()
    {
        Assert.AreEqual(new RectD(400, 350, 200, 100),
            RegionMath.Drawn(new PointD(500, 400), new PointD(600, 450), Bounds, fromCenter: true));
        Assert.AreEqual(new RectD(0, 350, 100, 100),
            RegionMath.Drawn(new PointD(50, 400), new PointD(200, 450), Bounds, fromCenter: true));
        Assert.AreEqual(new RectD(1000, 700, 100, 100),
            RegionMath.Drawn(new PointD(1000, 700), new PointD(1200, 800), Bounds, ratio: 1));
    }

    [TestMethod]
    public void HandleAtWholeEdge()
    {
        var rect = new RectD(300, 200, 400, 300);
        Assert.AreEqual(SelectionHandle.TopLeft, RegionMath.HandleAt(new PointD(300, 200), rect));
        Assert.AreEqual(SelectionHandle.BottomRight, RegionMath.HandleAt(new PointD(700, 500), rect));
        Assert.AreEqual(SelectionHandle.Top, RegionMath.HandleAt(new PointD(500, 200), rect));
        Assert.AreEqual(SelectionHandle.Left, RegionMath.HandleAt(new PointD(300, 350), rect));
        Assert.IsNull(RegionMath.HandleAt(new PointD(500, 350), rect));
        Assert.IsNull(RegionMath.HandleAt(new PointD(800, 500), rect));
    }

    [TestMethod]
    public void ResizedMovesEdges()
    {
        var original = new RectD(300, 200, 400, 200);
        Assert.AreEqual(new RectD(300, 200, 600, 200),
            RegionMath.Resized(original, SelectionHandle.Right, new PointD(900, 0), Bounds));
        Assert.AreEqual(new RectD(300, 200, 500, 500),
            RegionMath.Resized(original, SelectionHandle.BottomRight, new PointD(800, 700), Bounds));
        Assert.AreEqual(new RectD(300, 100, 400, 300),
            RegionMath.Resized(original, SelectionHandle.Top, new PointD(0, 100), Bounds));
    }

    [TestMethod]
    public void SnappingWithinSixPoints()
    {
        var edges = new double[] { 0, 400, 412, 1200 };
        Assert.AreEqual((400.0, (double?)400), RegionMath.Snap(405, edges));
        Assert.AreEqual((412.0, (double?)412), RegionMath.Snap(407, edges));
        Assert.AreEqual((400.0, (double?)400), RegionMath.Snap(394, edges));
        Assert.AreEqual((393.0, (double?)null), RegionMath.Snap(393, edges));
    }

    [TestMethod]
    public void PixelRectRoundsOutward()
    {
        var rect = RegionMath.PixelRect(new RectD(10.5, 20.5, 99.7, 50.2), 2, 400, 300);
        Assert.AreEqual(21, rect.X);
        Assert.AreEqual(41, rect.Y);
        Assert.AreEqual(221, rect.Right);
        Assert.AreEqual(142, rect.Bottom);
        var clamped = RegionMath.PixelRect(new RectD(-10, -10, 1000, 1000), 2, 400, 300);
        Assert.AreEqual(new RectD(0, 0, 400, 300), clamped);
    }
}

[TestClass]
public sealed class OcrTextTests
{
    [TestMethod]
    public void JoiningLinesKeepsCjkTight()
    {
        Assert.AreEqual("第一行文字接着第二行", OcrText.JoiningLines("第一行文字\n接着第二行"));
        Assert.AreEqual("hello world", OcrText.JoiningLines("hello\nworld"));
        Assert.AreEqual("an example", OcrText.JoiningLines("an exam-\nple"));
        Assert.AreEqual("中文English", OcrText.JoiningLines("中文\nEnglish"));
        Assert.AreEqual("한국어 텍스트", OcrText.JoiningLines("한국어\n텍스트"));
        Assert.AreEqual("第一行second line\n第三行", OcrText.JoiningLines("第一行\r\n  second line \n\n第三行"));
        Assert.AreEqual("Hello world\n\nfoo bar",
            OcrText.JoiningLines("Hello\nworld\n\nfoo\nbar", "\n\n"));
        Assert.AreEqual("提供了声明 App界面", OcrText.JoiningLines("提供了\n声明 App\n界面"));
        Assert.AreEqual("State-Of-the-art", OcrText.JoiningLines("State-\nOf-the-art"));
        Assert.AreEqual("price - five", OcrText.JoiningLines("price -\nfive"));
        Assert.AreEqual("中文测试 hello world", OcrText.RemoveCjkSpaces("中文 测试 hello world"));
        Assert.AreEqual("日本語のテキスト", OcrText.RemoveCjkSpaces("日本語 の テキスト"));
    }

    [TestMethod]
    public void ParagraphsFromLineBoxes()
    {
        static OcrLine Line(string text, double top, double width = 0.8, double x = 0.1)
            => new(text, new RectD(x, top, width, 0.05));

        var two = new[]
        {
            Line("The quick brown fox", 0.08), Line("jumps over the dog", 0.15),
            Line("A second paragraph", 0.27), Line("starts here", 0.34),
        };
        var paragraphs = OcrText.Paragraphs(two);
        Assert.AreEqual(2, paragraphs.Count);
        Assert.AreEqual("The quick brown fox jumps over the dog\n\nA second paragraph starts here",
            OcrText.Text(two, joined: true, separator: "\n\n"));
        Assert.AreEqual(4, OcrText.Text(two, joined: false).Split('\n').Length);

        var chinese = new[] { Line("敏捷的棕色狐狸", 0.08), Line("跳过了懒狗", 0.15) };
        Assert.AreEqual("敏捷的棕色狐狸跳过了懒狗", OcrText.Text(chinese, joined: true));

        var shortLast = new[]
        {
            Line("This is a long line of text", 0.08), Line("that ends here.", 0.15, 0.3),
            Line("Next paragraph line", 0.22), Line("continues on", 0.29),
        };
        Assert.AreEqual(2, OcrText.Paragraphs(shortLast).Count);

        var fullLine = new[] { Line("A sentence that fills the line.", 0.08), Line("And more", 0.15) };
        Assert.AreEqual(1, OcrText.Paragraphs(fullLine).Count);

        var columns = new[]
        {
            Line("an exam-", 0.35, x: 0.05), Line("ple of text", 0.42, x: 0.05),
            Line("right column", 0.08, x: 0.55),
        };
        Assert.AreEqual("an example of text\nright column", OcrText.Text(columns, joined: true));
        Assert.AreEqual(0, OcrText.Paragraphs(Array.Empty<OcrLine>()).Count);
    }
}
