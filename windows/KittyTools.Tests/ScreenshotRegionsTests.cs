// 截图翻译盖回的排版跟上 mac PR #25（对齐复查 R103，5ef55b2f、d829b1b1）：容器边界（嵌套同色标签、开放页面）、按钮居中不出边框、
// 放不下不截字、右上角标签不并进正文、英文正文译成中文按大写字高还原字号；另加一张合成的气泡图走 Prepare → Compose（Windows 自己加的，
// 代替 mac 那几个要真识字的样例：分段、标题、按钮、去字不碰边框）。
// 期望值照 mac ScreenshotRegionsTests / ScreenshotPopoverTests / ScreenshotReadingTests 原样；量字用按字数估的假字体
// （汉字一个字号宽、别的 0.55，大写字高 0.7、字形高 1 个字号）：mac 用真字体，挑的断言和字体无关。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScreenshotRegionsTests
{
    private sealed class FakeMeasure : ITextMeasure
    {
        public int LineCount(string text, double width, double fontSize, OverlayCode? code)
            => Math.Max(1, (int)Math.Ceiling(Width(text, fontSize) / Math.Max(1, width)));

        public double Width(string text, double fontSize)
            => text.Sum(ch => OcrText.IsCjk(ch) ? fontSize : fontSize * 0.55);
    }

    private static readonly FakeMeasure Measure = new();

    private static readonly OverlayRgb Black = new(0, 0, 0);

    // ---- mac ScreenshotRegionsTests

    [TestMethod]
    public void NestedBadgeUsesItsOwnBoundary()
    {
        var detector = new ScreenshotRegions(400, 240);
        var panel = new OverlayRect(10, 10, 380, 220);
        var badge = new OverlayRect(290, 170, 80, 40);
        var result = detector.Container(new OverlayRect(306, 182, 48, 16), 16, Black, (x, y) =>
        {
            if (badge.Contains(x, y))
            {
                return Inset(badge, 2).Contains(x, y) ? Black : new OverlayRgb(0, 0.4, 1);
            }

            if (panel.Contains(x, y))
            {
                return Inset(panel, 2).Contains(x, y) ? Black : new OverlayRgb(0.4, 0.4, 0.4);
            }

            return new OverlayRgb(1, 1, 1);
        });
        Assert.IsNotNull(result);
        Assert.AreEqual(Inset(badge, 2), result.Value);
    }

    [TestMethod]
    public void OpenPageHasNoContainer()
    {
        var detector = new ScreenshotRegions(500, 300);
        var white = new OverlayRgb(1, 1, 1);
        Assert.IsNull(detector.Container(new OverlayRect(50, 180, 300, 30), 30, white, (_, _) => white));
    }

    [TestMethod]
    public void ControlFitsWithoutCrossingItsBorder()
    {
        var button = new OverlayRect(64, 54, 98, 54);
        var segment = new OverlaySegment { Box = new OverlayRect(82, 73, 62, 23), Text = "Got it", LineHeight = 23, Container = button };
        var result = ScreenshotOverlay.Layout(new[] { segment }, new[] { "知道了" }, 636, 400, Measure);
        Assert.AreEqual(0, result.Leftovers.Count);
        var span = result.Spans.Single();
        Assert.IsTrue(Inset(button, 8, 4).Contains(span.Area), $"{span.Area}");
        Assert.AreEqual(button.MidX, span.Area.MidX, 0.5);
        Assert.AreEqual(button.MidY, span.Area.MidY, 0.5);
        Assert.AreEqual("知道了", span.Text);
        var tooLong = ScreenshotOverlay.Layout(
            new[] { segment }, new[] { string.Concat(Enumerable.Repeat("长按钮译文", 10)) }, 636, 400, Measure);
        Assert.AreEqual(0, tooLong.Spans.Count);
        CollectionAssert.AreEqual(new[] { 0 }, tooLong.Leftovers);
    }

    // ---- mac ScreenshotPopoverTests.badgeIsNotJoinedToTheParagraphBelow

    /// <summary>右上角「New」标签的行距虽然接近正文，横向只有一点重叠，要单独成段（mac 的 Vision 归一化框换成 1000 × 1000 像素、左上原点）。</summary>
    [TestMethod]
    public void BadgeIsNotJoinedToTheParagraphBelow()
    {
        static OcrLine Line(string text, double x, double y, double width, double height)
            => new(text, new RectD(x * 1000, (1 - y - height) * 1000, width * 1000, height * 1000));
        var lines = new[]
        {
            Line("New", 0.84, 0.72, 0.08, 0.06),
            Line("Choose whether github.com opens to", 0.1, 0.62, 0.76, 0.07),
            Line("Home or Feed.", 0.1, 0.52, 0.72, 0.07),
        };
        var paragraphs = OcrText.Paragraphs(lines);
        Assert.AreEqual(2, paragraphs.Count);
        CollectionAssert.AreEqual(new[] { "New" }, paragraphs[0]);
        CollectionAssert.AreEqual(new[] { "Choose whether github.com opens to", "Home or Feed." }, paragraphs[1]);
    }

    // ---- mac ScreenshotReadingTests.chineseParagraphKeepsReadableSizeAndParagraphAnchors

    /// <summary>空间够时译文可以多排一行，不为迁就原文的行数先缩字；14 像素的英文字面不当成 12.6 像素的中文字号。</summary>
    [TestMethod]
    public void ChineseParagraphKeepsReadableSizeAndParagraphAnchors()
    {
        var first = new OverlaySegment
        {
            Box = new OverlayRect(44, 240, 580, 40), Text = "The original paragraph spans two lines.", LineHeight = 14, LineCount = 2, Pitch = 26,
        };
        var second = new OverlaySegment { Box = new OverlayRect(44, 70, 580, 14), Text = "The next paragraph.", LineHeight = 14 };
        var translation = string.Concat(Enumerable.Repeat("请更新工作流程并使用支持的模型。", 6));
        var result = ScreenshotOverlay.Layout(new[] { first, second }, new[] { translation, "下一段译文" }, 677, 320, Measure);
        Assert.AreEqual(0, result.Leftovers.Count);
        var upper = result.Spans.First();
        var lower = result.Spans.Last();
        Assert.IsTrue(upper.FontSize is >= 18 and <= 22, $"字号 {upper.FontSize}");
        Assert.AreEqual(upper.FontSize, lower.FontSize, 0.01);
        Assert.AreEqual(first.Box.MinX, upper.Frame.MinX);
        Assert.AreEqual(first.Box.MaxY, upper.Area.MaxY, 1e-9);
        Assert.IsTrue(upper.Area.MinY < first.Box.MinY, "多排几行用下面的空白，不先缩字");
        Assert.IsTrue(upper.Area.MinY > second.Box.MaxY);
        Assert.IsFalse(Intersects(upper.Area, lower.Area));
    }

    /// <summary>代码块、中文原文、译成英文的都不还原字号：照原来的 0.9 倍行高。</summary>
    [TestMethod]
    public void ReadingSizeOnlyForEnglishIntoChinese()
    {
        var english = new OverlaySegment { Box = new OverlayRect(40, 400, 600, 30), Text = "One line", LineHeight = 30 };
        var nominal = 30 * ScreenshotOverlay.FontPerLineHeight;
        Assert.AreEqual(nominal, ScreenshotOverlay.Layout(new[] { english }, new[] { "One line" }, 800, 600, Measure).Spans.Single().FontSize, 0.01);
        var chinese = english with { Text = "一行原文" };
        Assert.AreEqual(nominal, ScreenshotOverlay.Layout(new[] { chinese }, new[] { "另一行" }, 800, 600, Measure).Spans.Single().FontSize, 0.01);
        Assert.AreEqual(30 / 0.7, ScreenshotOverlay.Layout(new[] { english }, new[] { "一行" }, 800, 600, Measure).Spans.Single().FontSize, 0.01);
    }

    // ---- 合成的气泡图：Prepare → Compose（Windows 自己加的，不要真识字）

    private const int CanvasWidth = 400;
    private const int CanvasHeight = 240;

    private static readonly (int R, int G, int B) Page = (13, 17, 23);
    private static readonly (int R, int G, int B) Bubble = (1, 4, 9);
    private static readonly (int R, int G, int B) Rim = (61, 68, 77);
    private static readonly (int R, int G, int B) ButtonFill = (33, 40, 48);
    private static readonly (int R, int G, int B) White = (230, 237, 243);
    private static readonly (int R, int G, int B) Gray = (139, 148, 158);

    /// <summary>
    /// 深色页面上一个 2 像素描边的气泡（20..380 × 20..220，原点左下）：白字标题、两行灰字正文、底色按钮（40..140 × 40..80，也有描边）里的白字。
    /// 「字」是一道道竖笔；识字的行是左上原点的像素框。
    /// </summary>
    private static (byte[] Bgra, OcrLine[] Lines) Popover()
    {
        var bytes = new byte[CanvasWidth * CanvasHeight * 4];
        void Fill(int x0, int y0, int x1, int y1, (int R, int G, int B) rgb)
        {
            for (var y = y0; y < y1; y++)
            {
                for (var x = x0; x < x1; x++)
                {
                    var offset = ((CanvasHeight - 1 - y) * CanvasWidth + x) * 4;
                    bytes[offset] = (byte)rgb.B;
                    bytes[offset + 1] = (byte)rgb.G;
                    bytes[offset + 2] = (byte)rgb.R;
                    bytes[offset + 3] = 255;
                }
            }
        }

        void Framed(int x0, int y0, int x1, int y1, (int R, int G, int B) fill)
        {
            Fill(x0, y0, x1, y1, Rim);
            Fill(x0 + 2, y0 + 2, x1 - 2, y1 - 2, fill);
        }

        void Strokes(int x0, int x1, int y, (int R, int G, int B) ink)
        {
            for (var x = x0; x < x1; x += 6)
            {
                Fill(x, y + 2, x + 2, y + 18, ink);
            }
        }

        Fill(0, 0, CanvasWidth, CanvasHeight, Page);
        Framed(20, 20, 380, 220, Bubble);
        Framed(40, 40, 140, 80, ButtonFill);
        Strokes(40, 238, 180, White);
        Strokes(40, 338, 140, Gray);
        Strokes(40, 318, 112, Gray);
        Strokes(62, 118, 50, White);
        static OcrLine Line(string text, double x, double y, double width, double height)
            => new(text, new RectD(x, CanvasHeight - y - height, width, height));
        return (bytes, new[]
        {
            Line("Pin your homepage", 40, 180, 200, 20),
            Line("Choose whether github.com opens to", 40, 140, 300, 20),
            Line("Home or Feed.", 40, 112, 280, 20),
            Line("Got it", 60, 50, 60, 20),
        });
    }

    [TestMethod]
    public void PrepareSplitsByContainerAndInk()
    {
        var (bgra, lines) = Popover();
        var before = (byte[])bgra.Clone();
        var segments = ScreenshotOverlay.Prepare(lines, new OverlayPixels(bgra, CanvasWidth, CanvasHeight, CanvasWidth * 4));
        CollectionAssert.AreEqual(before, bgra, "Prepare 不改图");
        Assert.AreEqual(3, segments.Count, string.Join(" | ", segments.Select(segment => segment.Text)));
        var bubble = new OverlayRect(22, 22, 356, 196);
        // 白字标题和灰字正文在同一个气泡里：按字色分开，标题认成标题
        Assert.AreEqual("Pin your homepage", segments[0].Text);
        Assert.AreEqual<OverlayRect?>(bubble, segments[0].Container);
        Assert.IsTrue(segments[0].IsHeading && !segments[0].IsControl);
        Assert.AreEqual("Choose whether github.com opens to Home or Feed.", segments[1].Text);
        Assert.AreEqual(2, segments[1].LineCount);
        Assert.AreEqual<OverlayRect?>(bubble, segments[1].Container);
        Assert.AreEqual<double?>(28, segments[1].Pitch);
        // 按钮自己一个容器
        Assert.AreEqual("Got it", segments[2].Text);
        Assert.AreEqual<OverlayRect?>(new OverlayRect(42, 42, 96, 36), segments[2].Container);
        Assert.IsTrue(segments[2].IsControl);
        Assert.IsTrue(segments.All(segment => segment.IsAnalyzed));
    }

    [TestMethod]
    public void ComposeKeepsContainerBordersAndCentersTheButton()
    {
        var (bgra, lines) = Popover();
        var image = new OverlayPixels(bgra, CanvasWidth, CanvasHeight, CanvasWidth * 4);
        var segments = ScreenshotOverlay.Prepare(lines, image);
        var rims = new[] { (21, 100), (100, 219), (379, 150), (41, 60), (139, 60), (90, 79) }
            .Select(point => (point, image.Raw(point.Item1, point.Item2))).ToList();
        var (spans, leftovers) = ScreenshotOverlay.Compose(
            image, segments, new[] { "固定你的主页", "选择 github.com 打开时显示主页还是动态内容。", "知道了" }, Measure);
        Assert.AreEqual(0, leftovers.Count);
        Assert.AreEqual(3, spans.Count);
        Assert.IsTrue(spans[0].Span.Bold, "标题粗体");
        Assert.IsTrue(spans.All(item => item.Span.Clip is not null), "容器里的段只画在容器里");
        var button = spans[2].Span;
        Assert.AreEqual(90, button.Area.MidX, 0.5);
        Assert.AreEqual(60, button.Area.MidY, 0.5);
        // 正文不出气泡、不压标题的译文
        Assert.IsTrue(new OverlayRect(22, 22, 356, 196).Contains(spans[1].Span.Area));
        Assert.IsFalse(Intersects(spans[0].Span.Area, spans[1].Span.Area));
        // 去字不碰描边
        foreach (var ((x, y), rgb) in rims)
        {
            Assert.AreEqual(rgb, image.Raw(x, y), $"描边 ({x}, {y}) 被动了");
        }

        // 字去掉了：按钮里的白竖笔换成了按钮的底色
        Assert.AreEqual(ButtonFill, image.Raw(62, 60));
    }

    private static OverlayRect Inset(OverlayRect rect, double dx, double? dy = null)
        => OverlayRect.FromEdges(rect.MinX + dx, rect.MinY + (dy ?? dx), rect.MaxX - dx, rect.MaxY - (dy ?? dx));

    private static bool Intersects(OverlayRect a, OverlayRect b)
        => a.MinX < b.MaxX && a.MaxX > b.MinX && a.MinY < b.MaxY && a.MaxY > b.MinY;
}
