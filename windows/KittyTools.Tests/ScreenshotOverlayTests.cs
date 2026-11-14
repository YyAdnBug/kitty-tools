// 截图翻译「原位覆盖」的单测（PLAN-v16 S1 / S1b，照 mac ScreenshotOverlayTests）：分段、字号拟合（正文统一一个字号）、行距照原文、
// 去字范围、不压到下一段、邻栏只认整个在右边的、列表记号另画、代码词的匹配；去字（只换字的像素）、取原文字色、行内代码块量出来的样子。
// 量字用按字数估的假字体（汉字一个字号宽、别的 0.55）：mac 用真字体，断言挑的是和字体无关的那些。画字在 App 里（Win2D），这里不测。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScreenshotOverlayTests
{
    private sealed class FakeMeasure : ITextMeasure
    {
        public int LineCount(string text, double width, double fontSize, OverlayCode? code)
            => Math.Max(1, (int)Math.Ceiling(Width(text, fontSize) / Math.Max(1, width)));

        public double Width(string text, double fontSize)
            => text.Sum(ch => OcrText.IsCjk(ch) ? fontSize : fontSize * 0.55);
    }

    private static readonly FakeMeasure Measure = new();

    private static OverlaySegment Segment(string text, OverlayRect box, double lineHeight, int lineCount = 1)
        => new() { Text = text, Box = box, LineHeight = lineHeight, LineCount = lineCount };

    private static List<OverlaySpan> Spans(OverlaySegment[] segments, string[] translations, double width, double height)
        => ScreenshotOverlay.Spans(segments, translations, width, height, Measure);

    [TestMethod]
    public void SegmentsMergeLinesIntoParagraphs()
    {
        // 左上原点的像素行框（mac 用的归一化左下原点换算过来：图 1000 × 500）
        var lines = new[]
        {
            new OcrLine("The quick brown fox", new RectD(100, 50, 800, 25)),
            new OcrLine("jumps over the dog", new RectD(100, 85, 800, 25)),
            new OcrLine("A second paragraph", new RectD(100, 200, 800, 25)),
        };
        var segments = ScreenshotOverlay.Segments(lines, 1000, 500);
        Assert.AreEqual(2, segments.Count);
        Assert.AreEqual("The quick brown fox jumps over the dog", segments[0].Text);
        // 行框并集、翻成左下原点
        Assert.AreEqual(100, segments[0].Box.MinX, 0.01);
        Assert.AreEqual(390, segments[0].Box.MinY, 0.01);
        Assert.AreEqual(800, segments[0].Box.Width, 0.01);
        Assert.AreEqual(60, segments[0].Box.Height, 0.01);
        Assert.AreEqual(25, segments[0].LineHeight, 0.01);
        Assert.AreEqual("A second paragraph", segments[1].Text);
    }

    [TestMethod]
    public void SegmentsJoinChineseWithoutSpacesAndKeepLatinWords()
    {
        var segments = ScreenshotOverlay.Segments(new[]
        {
            new OcrLine("敏捷的棕色狐狸", new RectD(10, 5, 80, 5), new[] { new OcrWord("敏", new RectD(10, 5, 5, 5)) }),
            new OcrLine("跳过了懒狗 total_count：", new RectD(10, 12, 80, 5),
                new[] { new OcrWord("跳", new RectD(10, 12, 5, 5)), new OcrWord("total_count：", new RectD(40, 12, 30, 5)) }),
        }, 100, 100);
        Assert.AreEqual("敏捷的棕色狐狸跳过了懒狗 total_count：", segments.Single().Text);
        // 词只收拉丁字母 / 数字那一截，框翻成左下原点
        var word = segments[0].Words.Single();
        Assert.AreEqual("total_count", word.Text);
        Assert.AreEqual(83, word.Box.MinY, 0.01);
    }

    /// <summary>Windows 的识字在行内代码块那里把一行切成三段「行」：同一排、挨着的接回一行；隔得远的两栏不接。</summary>
    [TestMethod]
    public void RowFragmentsAreMergedBackIntoOneLine()
    {
        var lines = new[]
        {
            new OcrLine("Use", new RectD(40, 100, 40, 22), new[] { new OcrWord("Use", new RectD(40, 100, 40, 22)) }),
            new OcrLine("max_size", new RectD(90, 99, 90, 24), new[] { new OcrWord("max_size", new RectD(90, 99, 90, 24)) }),
            new OcrLine("to limit how many", new RectD(186, 100, 300, 22)),
            new OcrLine("Next line", new RectD(40, 140, 200, 22)),
            new OcrLine("Far column", new RectD(700, 140, 150, 22)),
        };
        var merged = ScreenshotOverlay.MergeRowFragments(lines);
        Assert.AreEqual(3, merged.Count);
        Assert.AreEqual("Use max_size to limit how many", merged[0].Text);
        Assert.AreEqual(40, merged[0].Box.X);
        Assert.AreEqual(486, merged[0].Box.Right);
        Assert.AreEqual(2, merged[0].Words!.Count);
        Assert.AreEqual("Far column", merged[2].Text);
        // 识字给的顺序不是从左到右（实测）：照样按 x 接；接好的行按最早出现的那段排
        var shuffled = ScreenshotOverlay.MergeRowFragments(new[] { lines[3], lines[2], lines[0], lines[1] });
        Assert.AreEqual(2, shuffled.Count);
        Assert.AreEqual("Next line", shuffled[0].Text);
        Assert.AreEqual("Use max_size to limit how many", shuffled[1].Text);
    }

    [TestMethod]
    public void ListItemsStartNewParagraphsAndMeasureTheTextColumn()
    {
        var lines = new[]
        {
            new OcrLine("• first item", new RectD(69, 100, 800, 50)),
            new OcrLine("continues here", new RectD(101, 160, 700, 50)),
            new OcrLine("• second item", new RectD(69, 220, 800, 50)),
        };
        Assert.AreEqual(2, OcrText.Paragraphs(lines).Count);
        var segments = ScreenshotOverlay.Segments(lines, 1000, 1000);
        Assert.AreEqual(2, segments.Count);
        Assert.AreEqual(32, segments[0].Inset, 0.01);
        Assert.AreEqual("• ", OcrText.ListMarker("• first"));
        Assert.AreEqual("1. ", OcrText.ListMarker("1. first"));
        Assert.AreEqual("①", OcrText.ListMarker("①第一"));
        Assert.IsNull(OcrText.ListMarker("first"));
    }

    [TestMethod]
    public void ListMarkerWithoutSpace()
    {
        // PLAN-v18 S12（mac 43931601）：「1.」后面没有空格也算；紧跟着数字、点的不算。
        Assert.AreEqual("1.", OcrText.ListMarker("1.Alt+Shift+A截图"));
        Assert.AreEqual("2.", OcrText.ListMarker("2.等待该区域变成翻译之后的内容"));
        Assert.AreEqual("3)", OcrText.ListMarker("3)ESC"));
        Assert.IsNull(OcrText.ListMarker("1.5倍行距"));
        Assert.IsNull(OcrText.ListMarker("192.168.1.1 是网关"));
        Assert.IsNull(OcrText.ListMarker("1..."));
        Assert.IsNull(OcrText.ListMarker("3.14"));
    }

    [TestMethod]
    public void OrderedListWithoutSpacesSplits()
    {
        // mac orderedListWithoutSpacesSplits 的行框（Vision 归一化、左下原点）换成 1000 × 1000 像素、左上原点：
        // 「使用步骤」、三条记号后面没空格的有序列表、列表后面往左缩回去的一段正文，各成一段；折行接着写（缩进到正文列）的不断。
        static OcrLine Line(string text, double x, double y, double width, double height)
            => new(text, new RectD(x * 1000, (1 - y - height) * 1000, width * 1000, height * 1000));
        var shot = new[]
        {
            Line("使用步骤", 0.0218, 0.8313, 0.0963, 0.1039),
            Line("1.Alt+Shift+A截图", 0.0538, 0.5860, 0.1986, 0.1145),
            Line("2.等待该区域变成翻译之后的内容", 0.0523, 0.4363, 0.3560, 0.1264),
            Line("3.ESC关闭翻译", 0.0521, 0.2919, 0.1698, 0.1222),
            Line("这些步骤是直接在原地显示翻译之后的内容，不是单独显示一个框显示翻译之后的内容。", 0.0233, 0.0479, 0.9009, 0.1198),
        };
        Assert.AreEqual(5, OcrText.Paragraphs(shot).Count);
        var wrapped = new[]
        {
            Line("1.第一条写得很长很长很长很长很长", 0.05, 0.8, 0.4, 0.05),
            Line("接着往下写的折行", 0.075, 0.74, 0.2, 0.05),
            Line("2.第二条", 0.05, 0.68, 0.1, 0.05),
        };
        var paragraphs = OcrText.Paragraphs(wrapped);
        Assert.AreEqual(2, paragraphs.Count);
        CollectionAssert.AreEqual(new[] { "1.第一条写得很长很长很长很长很长", "接着往下写的折行" }, paragraphs[0]);
        CollectionAssert.AreEqual(new[] { "2.第二条" }, paragraphs[1]);
    }

    [TestMethod]
    public void ShortLineAfterALongWordIsNotAParagraphEnd()
    {
        // 「…agent.」后面一整行长的代码词：上一行剩下的地方放不下它，是被挤断的，不算段落结尾
        var lines = new[]
        {
            new OcrLine("This is a long line of text here", new RectD(0, 0, 500, 20)),
            new OcrLine("by agent.", new RectD(0, 24, 300, 20)),
            new OcrLine("total_merged_no_human_change", new RectD(0, 48, 480, 20),
                new[] { new OcrWord("total_merged_no_human_change", new RectD(0, 48, 480, 20)) }),
        };
        Assert.AreEqual(1, OcrText.Paragraphs(lines).Count);
    }

    [TestMethod]
    public void ShortTranslationKeepsTheOriginalSize()
    {
        var segment = Segment("原文", new OverlayRect(100, 400, 300, 30), 30);
        var spans = Spans(new[] { segment }, new[] { "短译文" }, 800, 600);
        Assert.AreEqual(1, spans.Count);
        var span = spans[0];
        Assert.AreEqual(30 * ScreenshotOverlay.FontPerLineHeight, span.FontSize, 0.01);
        Assert.AreEqual(segment.Box.MaxY, span.Frame.MaxY, 0.01);
        Assert.IsTrue(span.Erase.MinY < segment.Box.MinY && span.Erase.MaxY > segment.Box.MaxY);
        Assert.AreEqual(0, span.Frame.MinY);
    }

    [TestMethod]
    public void LongTranslationShrinksInsteadOfOverflowing()
    {
        var segment = Segment("原文", new OverlayRect(100, 400, 300, 30), 30);
        var spans = Spans(new[] { segment }, new[] { string.Concat(Enumerable.Repeat("这是一段很长的译文，得折成好几行才放得下。", 4)) }, 800, 600);
        Assert.AreEqual(1, spans.Count);
        var nominal = 30 * ScreenshotOverlay.FontPerLineHeight;
        Assert.IsTrue(spans[0].FontSize < nominal);
        // 最多缩到基准的四分之三，再多就借下方的空白
        Assert.IsTrue(spans[0].FontSize >= nominal * 0.75 - 0.01);
        Assert.IsTrue(spans[0].Frame.MinY < segment.Box.MinY);
    }

    [TestMethod]
    public void BodyParagraphsShareOneFontSize()
    {
        var segments = new[]
        {
            Segment("A heading", new OverlayRect(40, 900, 400, 60), 60),
            Segment("First paragraph", new OverlayRect(40, 700, 900, 130), 36, 3),
            Segment("Second paragraph", new OverlayRect(40, 500, 900, 140), 41, 3),
            Segment("Third", new OverlayRect(40, 400, 900, 39), 39),
        };
        var spans = Spans(segments, new[] { "标题", "第一段", "第二段", "第三段" }, 1000, 1000);
        Assert.AreEqual(4, spans.Count);
        Assert.AreEqual(1, spans.Skip(1).Select(span => span.FontSize).Distinct().Count());
        Assert.IsTrue(spans[0].FontSize > spans[1].FontSize * 1.3);
    }

    [TestMethod]
    public void IndentedParagraphBelowIsNotANeighbourColumn()
    {
        var upper = Segment("• total_comments_addressed: The number of evaluated comments …", new OverlayRect(69, 364, 1160, 421), 39, 8);
        var lower = Segment("max ), comment type (e.g., bug, security …", new OverlayRect(101, 206, 1113, 193), 40, 4);
        var spans = Spans(new[] { upper, lower }, new[] { string.Concat(Enumerable.Repeat("开发者处理过的已评估评论数，", 12)), "评论类型" }, 1231, 1034);
        Assert.AreEqual(2, spans.Count);
        Assert.IsTrue(spans[0].Frame.Width > upper.Box.Width * 0.95 - 32);
        Assert.AreEqual(spans[1].FontSize, spans[0].FontSize, 0.001);
    }

    [TestMethod]
    public void TranslationFollowsTheOriginalLinePitch()
    {
        var paragraph = Segment("Three lines of text", new OverlayRect(40, 600, 900, 142), 40, 3);
        var single = Segment("One line", new OverlayRect(40, 400, 900, 40), 40);
        var spans = Spans(new[] { paragraph, single }, new[] { "三行", "一行" }, 1000, 1000);
        Assert.AreEqual(2, spans.Count);
        Assert.AreEqual(51, spans[0].Pitch, 0.01);
        Assert.AreEqual(51, spans[1].Pitch, 0.01);
        Assert.IsTrue(spans[0].Baseline < 742 && spans[0].Baseline > 742 - 40);
        var measured = paragraph with { Baseline = 710, Pitch = 49 };
        var fromPixels = Spans(new[] { measured }, new[] { "三行" }, 1000, 1000);
        Assert.AreEqual(710, fromPixels[0].Baseline);
        Assert.AreEqual(49, fromPixels[0].Pitch);
    }

    [TestMethod]
    public void ListItemKeepsItsMarker()
    {
        var item = Segment("• total_comments_evaluated: The number", new OverlayRect(69, 400, 900, 91), 40, 2) with { Inset = 32 };
        var dropped = Spans(new[] { item }, new[] { "评论数" }, 1000, 600);
        Assert.AreEqual("•", dropped[0].Marker);
        Assert.AreEqual("评论数", dropped[0].Text);
        Assert.AreEqual(101, dropped[0].Frame.MinX);
        var tight = Spans(new[] { item }, new[] { "•评论数" }, 1000, 600);
        Assert.AreEqual("•", tight[0].Marker);
        Assert.AreEqual("评论数", tight[0].Text);
    }

    [TestMethod]
    public void CodeSpansMatchWholePhrases()
    {
        const string text = "maximum 和 max、max_size 以及 Total_count：total，授予 View Copilot Metrics 权限的 Copilot";
        var phrases = new IReadOnlyList<string>[] { new[] { "max" }, new[] { "total_count" }, new[] { "total" }, new[] { "View", "Copilot", "Metrics" } };
        var (result, ranges) = ScreenshotOverlay.CodeSpans(text, phrases);
        CollectionAssert.AreEqual(
            new[] { "max", "total_count", "total", "View\u00A0Copilot\u00A0Metrics" },
            ranges.Select(range => result.Substring(range.Start, range.Length)).ToArray());
        Assert.IsTrue(result.Contains("total_count：total", StringComparison.Ordinal) && !result.Contains("Total_count", StringComparison.Ordinal));
        Assert.IsTrue(result.EndsWith("权限的 Copilot", StringComparison.Ordinal));
        var (joined, joinedRanges) = ScreenshotOverlay.CodeSpans("每行 repos-1-day 报告", new IReadOnlyList<string>[] { new[] { "repos", "1-day" } });
        Assert.AreEqual("repos-1-day", joined.Substring(joinedRanges[0].Start, joinedRanges[0].Length));
    }

    [TestMethod]
    public void FrameStopsBeforeTheNextParagraph()
    {
        var upper = Segment("上面的原文", new OverlayRect(100, 500, 300, 30), 30);
        var lower = Segment("下面的原文", new OverlayRect(100, 400, 300, 30), 30);
        var spans = Spans(new[] { upper, lower }, new[] { string.Concat(Enumerable.Repeat("这一段译文很长，会想往下长。", 4)), "下面那段" }, 800, 600);
        Assert.AreEqual(2, spans.Count);
        Assert.IsTrue(spans[0].Frame.MinY > lower.Box.MaxY);
    }

    [TestMethod]
    public void WidenedTranslationStopsBeforeTheNextColumn()
    {
        var left = Segment("Left column text", new OverlayRect(40, 300, 200, 30), 30);
        var right = Segment("Right column text", new OverlayRect(260, 300, 200, 30), 30);
        var spans = Spans(new[] { left, right }, new[] { string.Concat(Enumerable.Repeat("左列这句译文很长，会想往右边放宽。", 3)), "右边那列" }, 600, 600);
        Assert.AreEqual(2, spans.Count);
        Assert.IsTrue(spans[0].Erase.MaxX <= right.Box.MinX);
        Assert.IsTrue(spans[0].Frame.MaxX <= right.Box.MinX);
        Assert.AreEqual(right.Box.MinX, spans[1].Frame.MinX, 0.01);
    }

    [TestMethod]
    public void EraseCoversTheTranslationWhenItGrowsPastTheParagraph()
    {
        var only = Segment("One line", new OverlayRect(100, 400, 300, 28), 28);
        var spans = Spans(new[] { only }, new[] { string.Concat(Enumerable.Repeat("译文比原文长很多，得多占几行。", 3)) }, 800, 600);
        Assert.AreEqual(1, spans.Count);
        Assert.IsTrue(spans[0].Erase.Height > only.Box.Height + 2);
        Assert.IsTrue(spans[0].Erase.MaxY >= only.Box.MaxY);
        Assert.IsTrue(spans[0].Erase.MinY < only.Box.MinY);
    }

    [TestMethod]
    public void SymbolOnlyParagraphsAreNotTranslated()
    {
        Assert.IsFalse(ScreenshotOverlay.HasTranslatableContent("——— ... !!!"));
        Assert.IsFalse(ScreenshotOverlay.HasTranslatableContent("• • •"));
        Assert.IsFalse(ScreenshotOverlay.HasTranslatableContent("   "));
        Assert.IsTrue(ScreenshotOverlay.HasTranslatableContent("Order shipped"));
        Assert.IsTrue(ScreenshotOverlay.HasTranslatableContent("订单已发货"));
        Assert.IsTrue(ScreenshotOverlay.HasTranslatableContent("第 12 条"));
        Assert.AreEqual(0, Spans(new[] { Segment("———", new OverlayRect(100, 400, 300, 30), 30) }, new[] { "———" }, 800, 600).Count);
    }

    [TestMethod]
    public void FrameStaysInsideTheImage()
    {
        var segment = Segment("右边贴边的一段", new OverlayRect(700, 400, 90, 30), 30);
        var spans = Spans(new[] { segment }, new[] { "贴在右边" }, 800, 600);
        Assert.AreEqual(1, spans.Count);
        Assert.IsTrue(spans[0].Frame.MaxX <= 800);
        Assert.IsTrue(spans[0].Erase.MaxX <= 800);
        Assert.IsTrue(spans[0].Erase.MinY >= 0);
    }

    [TestMethod]
    public void EmptyTranslationIsSkipped()
        => Assert.AreEqual(0, Spans(new[] { Segment("原文", new OverlayRect(100, 400, 300, 30), 30) }, new[] { "   " }, 800, 600).Count);

    [TestMethod]
    public void TextColourFallsBackOnLowContrast()
    {
        var dark = new OverlayRgb(0.1, 0.1, 0.1);
        Assert.AreEqual(new OverlayRgb(0.97, 0.97, 0.97), ScreenshotOverlay.TextColor(null, dark));
        Assert.AreEqual(new OverlayRgb(0.08, 0.08, 0.09), ScreenshotOverlay.TextColor(new OverlayRgb(0.9, 0.9, 0.9), OverlayRgb.Light));
        Assert.AreEqual(new OverlayRgb(0.6, 0.6, 0.6), ScreenshotOverlay.TextColor(new OverlayRgb(0.6, 0.6, 0.6), dark));
    }

    // ---- 像素：合成的小图（BGRA，左下原点画）

    private sealed class Canvas
    {
        public Canvas(int width, int height)
        {
            Width = width;
            Height = height;
            Bytes = new byte[width * height * 4];
        }

        public int Width { get; }

        public int Height { get; }

        public byte[] Bytes { get; }

        public void Fill(double x, double y, double width, double height, (int R, int G, int B) rgb)
        {
            for (var py = (int)y; py < (int)(y + height); py++)
            {
                for (var px = (int)x; px < (int)(x + width); px++)
                {
                    var offset = ((Height - 1 - py) * Width + px) * 4;
                    Bytes[offset] = (byte)rgb.B;
                    Bytes[offset + 1] = (byte)rgb.G;
                    Bytes[offset + 2] = (byte)rgb.R;
                    Bytes[offset + 3] = 255;
                }
            }
        }

        public OverlayPixels Pixels() => new(Bytes, Width, Height, Width * 4);
    }

    private static bool Near(OverlayPixels pixels, int x, int y, (int R, int G, int B) rgb)
    {
        var (r, g, b) = pixels.Raw(x, y);
        return Math.Abs(r - rgb.R) <= 4 && Math.Abs(g - rgb.G) <= 4 && Math.Abs(b - rgb.B) <= 4;
    }

    /// <summary>没认出代码块的段只去字：代码块的底、描边都留着，块里的白字换成块的底色；隔着空白的线不动；字色取正文的灰。</summary>
    [TestMethod]
    public void InpaintingKeepsInlineCodeAndTakesTheTextColour()
    {
        var canvas = new Canvas(420, 200);
        canvas.Fill(0, 0, 420, 200, (1, 4, 9));
        canvas.Fill(40, 90, 260, 40, (22, 27, 34));
        canvas.Fill(40, 128, 260, 2, (33, 38, 45));
        for (var x = 200; x < 290; x += 12)
        {
            canvas.Fill(x, 100, 4, 18, (230, 237, 243));
        }

        for (var x = 320; x < 400; x += 10)
        {
            canvas.Fill(x, 100, 4, 18, (139, 148, 158));
        }

        canvas.Fill(40, 170, 260, 2, (120, 120, 120));
        var image = canvas.Pixels();
        var composed = ScreenshotOverlay.Compose(
            image, new[] { Segment("inline code and text", new OverlayRect(50, 95, 360, 25), 25) }, new[] { "译" }, Measure);
        Assert.AreEqual(1, composed.Spans.Count);
        foreach (var (x, y) in new[] { (202, 110), (250, 105), (150, 125), (150, 92) })
        {
            Assert.IsTrue(Near(image, x, y, (22, 27, 34)), $"({x}, {y}) 是 {image.Raw(x, y)}");
        }

        Assert.IsTrue(Near(image, 150, 129, (33, 38, 45)));
        Assert.IsTrue(Near(image, 322, 110, (1, 4, 9)), $"{image.Raw(322, 110)}");
        Assert.IsTrue(image.Raw(150, 171).R > 100);
        // 译文的字色是原文正文的灰，不是白
        var color = composed.Spans[0].Color;
        Assert.IsTrue(color.Red * 255 is > 100 and <= 150, $"字色 {color}");
    }

    /// <summary>行内代码块跟着词走：原来的底框连字一起去掉；量出底色、描边、上下高度（基线 100 下 8 到上 30）。</summary>
    [TestMethod]
    public void CodeChipIsMeasuredAndClearedFromItsOldPlace()
    {
        var canvas = new Canvas(420, 200);
        canvas.Fill(0, 0, 420, 200, (1, 4, 9));
        canvas.Fill(250, 92, 150, 38, (22, 27, 34));
        canvas.Fill(250, 128, 150, 2, (33, 38, 45));
        for (var x = 262; x < 388; x += 12)
        {
            canvas.Fill(x, 100, 4, 18, (230, 237, 243));
        }

        var image = canvas.Pixels();
        var segment = Segment("foo_bar here", new OverlayRect(20, 95, 380, 30), 25) with
        {
            Words = new[] { new OverlayWord("foo_bar", new OverlayRect(260, 98, 130, 26)) },
        };
        var composed = ScreenshotOverlay.Compose(image, new[] { segment }, new[] { "foo_bar 在左边" }, Measure);
        Assert.AreEqual(1, composed.Spans.Count);
        var code = composed.Spans[0].Span.Code;
        Assert.IsNotNull(code);
        Assert.AreEqual("foo_bar", code.Phrases.Single().Single());
        Assert.AreEqual(22 / 255.0, code.Fill.Red, 0.01);
        Assert.IsNotNull(code.Border);
        Assert.AreEqual(2, code.BorderWidth);
        Assert.AreEqual(30, code.Above, 0.01);
        Assert.AreEqual(8, code.Below, 0.01);
        Assert.AreEqual(100, composed.Spans[0].Span.Baseline, 0.01);
        foreach (var (x, y) in new[] { (395, 110), (395, 129), (255, 95) })
        {
            Assert.IsTrue(Near(image, x, y, (1, 4, 9)), $"({x}, {y}) 是 {image.Raw(x, y)}");
        }
    }

    [TestMethod]
    public void BaselinesAreMeasuredFromPixels()
    {
        var canvas = new Canvas(200, 120);
        canvas.Fill(0, 0, 200, 120, (255, 255, 255));
        // 两行字：基线 80 和 40（x 高度那一截 80–90、40–50，上伸部再高一点）
        foreach (var baseline in new[] { 80, 40 })
        {
            for (var x = 10; x < 190; x += 6)
            {
                canvas.Fill(x, baseline, 3, 10, (20, 20, 20));
            }

            canvas.Fill(10, baseline, 3, 16, (20, 20, 20));
        }

        var baselines = canvas.Pixels().Baselines(new OverlayRect(5, 30, 190, 70), 20);
        CollectionAssert.AreEqual(new[] { 80.0, 40.0 }, baselines.ToArray());
    }
}
