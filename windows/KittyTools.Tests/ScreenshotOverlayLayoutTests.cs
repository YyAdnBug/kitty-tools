// 截图翻译盖回第二轮的排版（PLAN-v18 S7 S8，照 mac ScreenshotOverlayTests 96e78116 30c71710 43931601）：字号下限按点算、用上周围的空白、
// 放不下的段交给卡片、一行的段先保原字号、不叠字、不跨栏、不拆词；随机版面守住不变式。
// 量字用按词折行的假字体（汉字一个字号宽、别的 0.55）：mac 用真字体，断言挑的是和字体无关的那些。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ScreenshotOverlayLayoutTests
{
    /// <summary>按空格分词贪心折行；一个词比整行还宽时按字母断开（SplitsWord 报出来）。</summary>
    private sealed class WordMeasure : ITextMeasure
    {
        public double Width(string text, double fontSize) => text.Sum(ch => OcrText.IsCjk(ch) ? fontSize : fontSize * 0.55);

        private List<double> Lines(string text, double width, double fontSize)
        {
            var lines = new List<double>();
            var current = 0.0;
            foreach (var token in Tokens(text))
            {
                var size = Width(token, fontSize);
                var space = current > 0 && !OcrText.IsCjk(token[0]) ? Width(" ", fontSize) : 0;
                if (current > 0 && current + space + size > width)
                {
                    lines.Add(current);
                    current = 0;
                    space = 0;
                }

                while (size > width && width > 0)
                {
                    lines.Add(width);
                    size -= width;
                }

                current += space + size;
            }

            lines.Add(current);
            return lines;
        }

        /// <summary>拉丁词一个一个，汉字一个字一个。</summary>
        private static IEnumerable<string> Tokens(string text)
        {
            var word = new System.Text.StringBuilder();
            foreach (var ch in text)
            {
                if (OcrText.IsCjk(ch) || ch == ' ')
                {
                    if (word.Length > 0)
                    {
                        yield return word.ToString();
                        word.Clear();
                    }

                    if (ch != ' ')
                    {
                        yield return ch.ToString();
                    }
                }
                else
                {
                    word.Append(ch);
                }
            }

            if (word.Length > 0)
            {
                yield return word.ToString();
            }
        }

        public int LineCount(string text, double width, double fontSize, OverlayCode? code) => Lines(text, width, fontSize).Count;

        public double Extent(string text, double width, double fontSize, OverlayCode? code) => Math.Min(width, Lines(text, width, fontSize).Max());

        public bool SplitsWord(string text, double width, double fontSize, OverlayCode? code)
            => Tokens(text).Any(token => !OcrText.IsCjk(token[0]) && Width(token, fontSize) > width);
    }

    private static readonly WordMeasure Measure = new();

    private const string Chinese = "识别元素的默认值改为关闭，保留原色以便验证";

    private const string English =
        "Change the default value of the recognition element to off, and keep the original color for verification.";

    private static OverlaySegment Segment(string text, OverlayRect box, double lineHeight, int lineCount = 1)
        => new() { Text = text, Box = box, LineHeight = lineHeight, LineCount = lineCount };

    private static (List<OverlaySpan> Spans, List<int> Leftovers) Layout(
        OverlaySegment[] segments, string[] translations, double width, double height, double pixelsPerPoint = 1)
        => ScreenshotOverlay.Layout(segments, translations, width, height, Measure, pixelsPerPoint);

    private static bool Intersects(OverlayRect a, OverlayRect b)
        => a.MinX < b.MaxX && a.MaxX > b.MinX && a.MinY < b.MaxY && a.MaxY > b.MinY;

    private static OverlayRect Inset(OverlayRect rect, double by) => OverlayRect.FromEdges(rect.MinX + by, rect.MinY + by, rect.MaxX - by, rect.MaxY - by);

    /// <summary>mac checkInvariants：译文占的地方在图里、不压别的段的原文、段与段不叠；排好的 + 放不下的 = 全部。</summary>
    private static void CheckInvariants((List<OverlaySpan> Spans, List<int> Leftovers) result, OverlaySegment[] segments, double width, double height, string label = "")
    {
        for (var i = 0; i < result.Spans.Count; i++)
        {
            var span = result.Spans[i];
            var area = span.Area;
            Assert.IsTrue(area.MinX >= -0.5 && area.MinY >= -0.5 && area.MaxX <= width + 0.5 && area.MaxY <= height + 0.5, $"{label} {area} 出了图");
            var probe = Inset(area, 0.5);
            foreach (var other in segments.Where(other => other.Box != span.Source))
            {
                Assert.IsFalse(Intersects(other.Box, probe), $"{label} {area} 压到了 {other.Box}");
            }

            foreach (var later in result.Spans.Skip(i + 1))
            {
                Assert.IsFalse(Intersects(later.Area, probe), $"{label} {area} 和 {later.Area} 叠在一起");
            }
        }

        Assert.AreEqual(segments.Length, result.Spans.Count + result.Leftovers.Count, label);
    }

    [TestMethod]
    public void ShortSelectionUsesTheBlankAroundTheLine()
    {
        // 150 %：图 1200 × 124 像素，一行字行高 40 像素，在选区竖直中间。用上空白居中排，不交给卡片
        var line = Segment(Chinese, new OverlayRect(40, 42, 760, 40), 40);
        var result = Layout(new[] { line }, new[] { English }, 1200, 124, 2);
        Assert.AreEqual(0, result.Leftovers.Count);
        var span = result.Spans.Single();
        Assert.IsTrue(span.FontSize >= 40 * ScreenshotOverlay.FontPerLineHeight * 0.75 - 0.01);
        Assert.IsTrue(span.FontSize >= 20, "不小于 10 pt");
        Assert.IsTrue(span.Baseline + span.FontSize * 0.8 <= 124 + 0.01, "第一行的上沿不出图片顶边");
        Assert.IsTrue(span.Erase.MinX <= line.Box.MinX && span.Erase.MinY <= line.Box.MinY && span.Erase.MaxX >= line.Box.MaxX && span.Erase.MaxY >= line.Box.MaxY);
        // 同样的几何在 1 倍屏上（每个数都是一半）：按点算一样大
        var small = Layout(new[] { Segment(Chinese, new OverlayRect(20, 21, 380, 20), 20) }, new[] { English }, 600, 62).Spans.Single();
        Assert.AreEqual(small.FontSize * 2, span.FontSize, 0.5);
    }

    [TestMethod]
    public void TightSelectionLeavesTheParagraphToTheCard()
    {
        // 选区紧贴着一行字：到 10 pt 也放不下，不再缩成看不清的小字——不画、不去字，交给截图页的卡片
        var retina = Layout(new[] { Segment(Chinese, new OverlayRect(40, 4, 760, 40), 40) }, new[] { English }, 1200, 48, 2);
        Assert.AreEqual(0, retina.Spans.Count);
        CollectionAssert.AreEqual(new[] { 0 }, retina.Leftovers);
        var oneX = Layout(new[] { Segment(Chinese, new OverlayRect(20, 2, 380, 20), 20) }, new[] { English }, 600, 24);
        CollectionAssert.AreEqual(new[] { 0 }, oneX.Leftovers);
    }

    [TestMethod]
    public void SmallOriginalIsNotShrunk()
    {
        // 行高 18 像素、2 倍：基准 16.2 像素 ≈ 8 pt，不往下缩
        var result = Layout(new[] { Segment("小字", new OverlayRect(40, 400, 200, 18), 18) }, new[] { English }, 800, 600, 2);
        Assert.AreEqual(18 * ScreenshotOverlay.FontPerLineHeight, result.Spans.Single().FontSize, 0.01);
    }

    [TestMethod]
    public void BlankLayoutNeverOverlapsAnotherParagraph()
    {
        var upper = Segment("上面一段", new OverlayRect(40, 200, 700, 30), 30);
        var lower = Segment("贴着图片底边的一段", new OverlayRect(40, 10, 700, 30), 30);
        var segments = new[] { upper, lower };
        var result = Layout(segments, new[]
        {
            string.Concat(Enumerable.Repeat("上面那段的译文比原文长，", 8)),
            string.Concat(Enumerable.Repeat("下面那段的译文长得多，下方又没有地方可借，", 7)),
        }, 800, 300);
        CheckInvariants(result, segments, 800, 300);
    }

    [TestMethod]
    public void BlankLayoutDoesNotCrossIntoAnotherColumn()
    {
        var left = Segment("左栏一行原文", new OverlayRect(40, 200, 400, 30), 30);
        var leftBelow = Segment("左栏下面一行", new OverlayRect(40, 150, 400, 30), 30);
        var right = Segment("右栏一行原文", new OverlayRect(520, 250, 400, 30), 30);
        const string leftText = "The quick brown fox jumps over the lazy dog and keeps running far beyond the column edge";
        var rightText = string.Concat(Enumerable.Repeat("右栏的译文很长，得往下借好几行，", 4));
        foreach (var order in new[] { new[] { left, leftBelow, right }, new[] { right, left, leftBelow } })
        {
            var translations = order.Select(segment => segment == left ? leftText : segment == right ? rightText : "短译文").ToArray();
            CheckInvariants(Layout(order, translations, 1000, 400), order, 1000, 400, order[0].Text);
        }
    }

    [TestMethod]
    public void CloseParagraphsStillUseTheRoomOnTheRight()
    {
        var items = new[] { 200.0, 152, 104 }.Select(y => Segment("列表项", new OverlayRect(40, y, 600, 40), 40)).ToArray();
        var result = Layout(items, new[] { "First item", "The middle item is translated into a sentence of about seventy letters", "Last" }, 1400, 300, 2);
        Assert.AreEqual(0, result.Leftovers.Count);
        var middle = result.Spans.Single(span => span.Source == items[1].Box);
        Assert.AreEqual(192 - 40 * 0.72, middle.Baseline, 0.01, "基线还压在原文上");
        Assert.IsTrue(middle.Frame.Width > 600 * 1.25);
    }

    [TestMethod]
    public void SingleLineKeepsItsSizeWhenTheRightIsBlank()
    {
        var heading = Segment("使用步骤", new OverlayRect(30, 400, 132, 40), 40);
        var nominal = 40 * ScreenshotOverlay.FontPerLineHeight;
        var span = Layout(new[] { heading }, new[] { "Usage steps and more" }, 1000, 600).Spans.Single();
        Assert.AreEqual(nominal, span.FontSize, 0.01);
        Assert.IsTrue(span.Area.Width > 132 * 1.25);
        // 多行的段不往右撑
        var paragraph = Segment("两行的一段", new OverlayRect(30, 360, 300, 90), 40, 2);
        var wrapped = Layout(new[] { paragraph }, new[] { "A paragraph of two lines whose translation is a little longer than the original" }, 1000, 600).Spans.Single();
        Assert.IsTrue(wrapped.Area.MaxX <= 30 + 300 * 1.25 + 0.5);
    }

    [TestMethod]
    public void FloorOfTenPointsWinsOverThreeQuarters()
    {
        // 基准 22 像素（2 倍屏 11 pt），四分之三是 16.5 像素，不能小于 20 像素
        var height = 22 / ScreenshotOverlay.FontPerLineHeight;
        var result = Layout(new[] { Segment("原文", new OverlayRect(40, 400, 300, height), height) },
            new[] { string.Concat(Enumerable.Repeat("这是一段很长的译文，得折成好几行才放得下。", 4)) }, 800, 600, 2);
        Assert.AreEqual(20, result.Spans.Single().FontSize, 0.01);
    }

    [TestMethod]
    public void WordsAreNotSplitAcrossLines()
    {
        // 窄栏里一个英文词都放不下：不按字母拆开，放不下就交给卡片
        var result = Layout(new[] { Segment("验证", new OverlayRect(740, 400, 50, 30), 30) }, new[] { "Verification" }, 800, 600);
        Assert.AreEqual(0, result.Spans.Count);
        CollectionAssert.AreEqual(new[] { 0 }, result.Leftovers);
    }

    [TestMethod]
    public void ReviewerOverlapCasesStayApart()
    {
        const string longText = English;
        var narrow = new[]
        {
            Segment("右栏", new OverlayRect(600, 250, 200, 30), 30),
            Segment("左栏", new OverlayRect(100, 150, 492, 30), 30),
        };
        CheckInvariants(Layout(narrow, new[] { longText, longText }, 1000, 400, 2), narrow, 1000, 400, "narrow");
        var stairs = new[]
        {
            Segment("上面一段", new OverlayRect(40, 200, 300, 30), 30),
            Segment("右下", new OverlayRect(360, 174, 120, 24), 24),
            Segment("再右边", new OverlayRect(490, 150, 300, 48), 24, 2),
            Segment("下面", new OverlayRect(360, 120, 120, 24), 24),
        };
        CheckInvariants(Layout(stairs, Enumerable.Repeat(longText, 4).ToArray(), 800, 260, 2), stairs, 800, 260, "stairs");
    }

    [TestMethod]
    public void RandomLayoutsKeepTheInvariants()
    {
        // 随机版面（种子固定）：几段不重叠的原文框、长短不一的英文译文、1 倍和 2 倍，排出来都守住不变式
        var random = new Random(20261108);
        var words = "the quick brown fox jumps over lazy dog recognition element default value color".Split(' ');
        for (var round = 0; round < 400; round++)
        {
            double width = random.Next(300, 1401);
            double height = random.Next(60, 501);
            var segments = new List<OverlaySegment>();
            for (var count = random.Next(1, 7); count > 0; count--)
            {
                double lineHeight = random.Next(14, 45);
                var lines = random.Next(1, 4);
                var boxHeight = lineHeight * lines;
                double boxWidth = random.Next(30, 501);
                if (width <= boxWidth + 2 || height <= boxHeight + 2)
                {
                    continue;
                }

                var box = new OverlayRect(random.Next(1, (int)(width - boxWidth)), random.Next(1, (int)(height - boxHeight)), boxWidth, boxHeight);
                if (segments.Any(other => Intersects(OverlayRect.FromEdges(other.Box.MinX - 2, other.Box.MinY - 2, other.Box.MaxX + 2, other.Box.MaxY + 2), box)))
                {
                    continue;
                }

                segments.Add(Segment("一段原文", box, lineHeight, lines));
            }

            var translations = segments.Select(_ => string.Join(" ", Enumerable.Range(0, random.Next(1, 25)).Select(_ => words[random.Next(words.Length)]))).ToArray();
            var pixelsPerPoint = random.Next(2) == 0 ? 2.0 : 1.0;
            var array = segments.ToArray();
            var result = Layout(array, translations, width, height, pixelsPerPoint);
            CheckInvariants(result, array, width, height, $"第 {round} 轮");
            foreach (var span in result.Spans)
            {
                Assert.IsTrue(span.FontSize >= 10 * pixelsPerPoint - 0.01 || span.Scale >= 0.999, $"第 {round} 轮字号 {span.FontSize}");
            }
        }
    }

    [TestMethod]
    public void ComposeLeavesKeptParagraphsAndIconsAlone()
    {
        // 白底图：一段字（黑），右边贴着一个红色「图标」；译文长得要往右边借——图标那块不是空的，不能排过去、不能去字。
        const int width = 400;
        const int height = 60;
        var bgra = new byte[width * height * 4];
        Array.Fill(bgra, (byte)255);
        void Paint(int x0, int y0, int x1, int y1, byte r, byte g, byte b)
        {
            // 左下原点的行号
            for (var y = y0; y < y1; y++)
            {
                for (var x = x0; x < x1; x++)
                {
                    var row = height - 1 - y;
                    var index = (row * width + x) * 4;
                    bgra[index] = b;
                    bgra[index + 1] = g;
                    bgra[index + 2] = r;
                }
            }
        }

        // 「字」：几道竖笔（左下原点 y 20–40）
        for (var x = 20; x < 120; x += 6)
        {
            Paint(x, 20, x + 2, 40, 20, 20, 20);
        }

        Paint(130, 18, 150, 42, 230, 30, 60); // 红色图标，紧挨着字
        var before = (byte[])bgra.Clone();
        var image = new OverlayPixels(bgra, width, height, width * 4);
        var segment = Segment("原文", new OverlayRect(18, 18, 104, 24), 24);
        var (spans, leftovers) = ScreenshotOverlay.Compose(image, new[] { segment },
            new[] { "A translation that is much longer than the original text" }, Measure, 1);
        // 图标的每个像素都还在
        for (var y = 18; y < 42; y++)
        {
            for (var x = 130; x < 150; x++)
            {
                var index = ((height - 1 - y) * width + x) * 4;
                Assert.AreEqual(before[index + 2], image.Bytes[index + 2], $"图标在 {x},{y} 被动了");
            }
        }

        Assert.AreEqual(1, spans.Count + leftovers.Count);
        foreach (var (span, _) in spans)
        {
            Assert.IsFalse(Intersects(span.Area, new OverlayRect(130, 18, 20, 24)), "译文排到图标上了");
        }
    }
}
