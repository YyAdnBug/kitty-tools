// 截图翻译的「原位覆盖」（PLAN-v16 S1 / S1b，照 mac Translate/ScreenshotOverlay.swift，纯函数配单测）：把识字认出的一段段文字
// 从图上去掉，再把译文按原来的位置、原来的字色排回去，出一张能直接复制的图。
// 坐标：这里全程照 mac 用「像素、原点左下」（Segments 进来时从识字的左上原点翻过来），算法逐行照搬，不改方向；
// 像素是 BGRA 各 8 位（Windows 的截图），读写时按左下原点换行号。量字宽、折行要真字体，交给调用方的 ITextMeasure
// （App 里是 Win2D 的 CanvasTextLayout，单测里是按字数估的假的）。
// 排版规则（mac 2026-11-06）：正文段（行高和全图正文差不到两成）统一用一个基准字号，标题、小字按自己的行高；
// 译文行数多过原文先缩，最多缩到基准的四分之三，再多借下方的空白，借完还放不下才继续缩（宁可小也不丢字，最小 6.5）。
// 观感：只去掉字的像素，底色、渐变、边框留着；字色取原文的；每行译文的基线落在原文一行的基线上（基线、行距从像素里量）；
// 行内代码块跟着词走（原来的底框连字一起去掉，译文里还留着的代码词在新位置按原来的样子重画底框）；列表记号单独画。
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>量字：一段字按某个宽度、字号折成几行；一段字一行的宽（列表记号让出多宽）。代码词用等宽字体量。</summary>
public interface ITextMeasure
{
    int LineCount(string text, double width, double fontSize, OverlayCode? code);

    double Width(string text, double fontSize);
}

public readonly record struct OverlayRgb(double Red, double Green, double Blue)
{
    /// <summary>相对亮度（Rec. 601）：深底配白字、浅底配黑字。</summary>
    public double Luminance => 0.299 * Red + 0.587 * Green + 0.114 * Blue;

    /// <summary>两个颜色差多少：三个通道里差得最大的那个（0–1）。</summary>
    public double Distance(OverlayRgb other)
        => Math.Max(Math.Abs(Red - other.Red), Math.Max(Math.Abs(Green - other.Green), Math.Abs(Blue - other.Blue)));

    public static readonly OverlayRgb Light = new(1, 1, 1);
}

/// <summary>矩形（像素、原点左下）：MinX / MinY 是左下角。</summary>
public readonly record struct OverlayRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;

    public static OverlayRect FromEdges(double minX, double minY, double maxX, double maxY) => new(minX, minY, maxX - minX, maxY - minY);

    public OverlayRect Union(OverlayRect other)
        => FromEdges(Math.Min(MinX, other.MinX), Math.Min(MinY, other.MinY), Math.Max(MaxX, other.MaxX), Math.Max(MaxY, other.MaxY));

    public OverlayRect Intersection(OverlayRect other)
    {
        var minX = Math.Max(MinX, other.MinX);
        var minY = Math.Max(MinY, other.MinY);
        var maxX = Math.Min(MaxX, other.MaxX);
        var maxY = Math.Min(MaxY, other.MaxY);
        return maxX > minX && maxY > minY ? FromEdges(minX, minY, maxX, maxY) : default;
    }

    public bool Contains(double x, double y) => x >= MinX && x < MaxX && y >= MinY && y < MaxY;
}

/// <summary>段里一个拉丁词和它的框（像素、原点左下）：认哪些词在行内代码块里。</summary>
public readonly record struct OverlayWord(string Text, OverlayRect Box);

/// <summary>行内代码块的样子，从原图量出来；译文里原样留着的代码词按它重画底框。</summary>
public sealed record OverlayCode
{
    /// <summary>每个代码块里的词（按原文顺序）：一个代码块常常不止一个词，译文里整串出现才画。</summary>
    public IReadOnlyList<IReadOnlyList<string>> Phrases { get; init; } = System.Array.Empty<IReadOnlyList<string>>();

    public OverlayRgb Fill { get; init; }

    /// <summary>描边和它多宽；没有描边时 null。</summary>
    public OverlayRgb? Border { get; init; }

    public double BorderWidth { get; init; }

    /// <summary>代码块里字的颜色；取不到 null，用正文的。</summary>
    public OverlayRgb? Text { get; init; }

    /// <summary>底框比字左右各宽出多少、顶边在基线上方多少、底边在基线下方多少（像素）。</summary>
    public double Padding { get; init; }

    public double Above { get; init; }

    public double Below { get; init; }
}

/// <summary>一段：行框并集（像素、原点左下）、接好的原文、段内的中位行高、有几行；出图时再从像素里量出基线、行距、代码块。</summary>
public sealed record OverlaySegment
{
    public OverlayRect Box { get; init; }

    public string Text { get; init; } = string.Empty;

    public double LineHeight { get; init; }

    public int LineCount { get; init; } = 1;

    /// <summary>列表项的正文列离段框左边多远（第二行起的左边界）；不是列表项或量不出来时 0。</summary>
    public double Inset { get; init; }

    public IReadOnlyList<OverlayWord> Words { get; init; } = System.Array.Empty<OverlayWord>();

    /// <summary>从像素里量出来的第一行基线、行距；没量（纯几何的单测）时按行框估。</summary>
    public double? Baseline { get; init; }

    public double? Pitch { get; init; }

    public OverlayCode? Code { get; init; }
}

/// <summary>一段排好之后要画的东西。</summary>
public sealed record OverlaySpan
{
    public string Text { get; init; } = string.Empty;

    /// <summary>列表记号：画在原文段框的左边、第一行的基线上。</summary>
    public string? Marker { get; init; }

    public OverlayRect Source { get; init; }

    /// <summary>要去字的范围：里面只换掉字的像素（有代码块的段连代码块的底框一起换），底色留着。</summary>
    public OverlayRect Erase { get; init; }

    /// <summary>正文排在哪：左边界和宽度；顶边和原文顶边齐平，底边是最多往下长到哪。</summary>
    public OverlayRect Frame { get; init; }

    public double Baseline { get; init; }

    public double Pitch { get; init; }

    public double FontSize { get; init; }

    /// <summary>字号缩了多少（拟合后 / 基准）：重画的代码块底框跟着缩。</summary>
    public double Scale { get; init; }

    public double LineHeight { get; init; }

    public OverlayCode? Code { get; init; }
}

public static partial class ScreenshotOverlay
{
    /// <summary>可接受的最小字号（像素）。</summary>
    public const double MinimumFontSize = 6.5;

    /// <summary>字号和行高之比：0.9 时汉字的字面和原文的大写字母、上伸部差不多高（mac 对照微信）。</summary>
    public const double FontPerLineHeight = 0.9;

    /// <summary>量不到基线时按行框估：基线在行框顶边往下多少（行高的倍数）。</summary>
    private const double BaselineDrop = 0.72;

    /// <summary>代码词用等宽字体，比正文小一点。</summary>
    public const double CodeScale = 0.88;

    private const double BodyTolerance = 0.2;
    private const double ShrinkFloor = 0.75;
    private const double ErasePad = 0.3;

    /// <summary>和所在那一小块的底色差过这么多才算字（0–1）。</summary>
    private const double InkThreshold = 0.16;

    /// <summary>和底色差过这么多算「不是底色」（代码块的底、描边）。</summary>
    private const double FillThreshold = 0.03;

    [GeneratedRegex(@"^[A-Za-z0-9_](?:[A-Za-z0-9_.\-]*[A-Za-z0-9_])?")]
    private static partial Regex LatinWord();

    // ---- 分段

    /// <summary>
    /// 识字的行（左上原点的像素框）→ 按段分好的块（切段规则同 OcrText.Groups）；框翻成左下原点。
    /// 词：每个识字词里拉丁字母、数字、下划线组成的那一截（`total_comments_evaluated`、`v1.2`）。
    /// </summary>
    public static List<OverlaySegment> Segments(IReadOnlyList<OcrLine> lines, double imageWidth, double imageHeight)
    {
        var result = new List<OverlaySegment>();
        if (imageWidth <= 0 || imageHeight <= 0)
        {
            return result;
        }

        OverlayRect Flip(RectD box) => new(box.X, imageHeight - box.Y - box.Height, box.Width, box.Height);
        foreach (var group in OcrText.Groups(MergeRowFragments(lines)))
        {
            var text = OcrText.JoinLine(group.Select(line => line.Text));
            if (text.Length == 0)
            {
                continue;
            }

            var box = Flip(group[0].Box);
            foreach (var line in group.Skip(1))
            {
                box = box.Union(Flip(line.Box));
            }

            var heights = group.Select(line => line.Box.Height).OrderBy(value => value).ToList();
            var lineHeight = heights[heights.Count / 2];
            double inset = 0;
            if (group.Count > 1 && OcrText.ListMarker(group[0].Text) is not null)
            {
                var column = group.Skip(1).Min(line => line.Box.X);
                var measured = column - box.MinX;
                if (measured > 0 && measured < 4 * lineHeight)
                {
                    inset = measured;
                }
            }

            var words = new List<OverlayWord>();
            foreach (var word in group.SelectMany(line => line.Words ?? (IReadOnlyList<OcrWord>)System.Array.Empty<OcrWord>()))
            {
                var match = LatinWord().Match(word.Text.TrimStart('(', '（', '[', '"', '\'', '`'));
                if (match.Success)
                {
                    words.Add(new OverlayWord(match.Value, Flip(word.Box)));
                }
            }

            result.Add(new OverlaySegment
            {
                Box = box,
                Text = text,
                LineHeight = lineHeight,
                LineCount = group.Count,
                Inset = inset,
                Words = words,
            });
        }

        return result;
    }

    /// <summary>
    /// Windows 的识字在行内代码块这种底色变了的地方会把一行切成几段「行」（`Use` | `max_size` | `to limit …`），mac 的 Vision 给的是整行。
    /// 同一排（纵向重叠过矮的那个的一半）、横向挨着（空隙不到 1.5 个行高）的几段先接回一行，再分段；两栏之间的空隙一般远大于这个。
    /// 中日文之间直接接，别的加一个空格（同 OcrText.JoinLine）。
    /// </summary>
    public static List<OcrLine> MergeRowFragments(IReadOnlyList<OcrLine> lines)
    {
        // 识字给的顺序不一定从左到右（实测 `to limit …` 排在 `Use max` 前面）：先按排归拢，排里按 x 排好再接
        var rows = new List<List<(OcrLine Line, int Order)>>();
        for (var order = 0; order < lines.Count; order++)
        {
            var line = lines[order];
            var row = rows.FirstOrDefault(row => row.Any(other =>
                Math.Min(other.Line.Box.Bottom, line.Box.Bottom) - Math.Max(other.Line.Box.Y, line.Box.Y) >=
                Math.Min(other.Line.Box.Height, line.Box.Height) * 0.5));
            if (row is null)
            {
                rows.Add(new List<(OcrLine, int)> { (line, order) });
            }
            else
            {
                row.Add((line, order));
            }
        }

        // 接好的行按组成它的那几段里最早出现的那段排（两栏的版面照旧一栏一栏地出，不交错）
        var result = new List<(OcrLine Line, int Order)>();
        foreach (var row in rows)
        {
            (OcrLine Line, int Order)? current = null;
            foreach (var (line, order) in row.OrderBy(item => item.Line.Box.X))
            {
                if (current is { } left)
                {
                    var gap = line.Box.X - left.Line.Box.Right;
                    if (gap <= Math.Max(left.Line.Box.Height, line.Box.Height) * 1.5)
                    {
                        var box = RectD.FromLtrb(
                            Math.Min(left.Line.Box.X, line.Box.X), Math.Min(left.Line.Box.Y, line.Box.Y),
                            Math.Max(left.Line.Box.Right, line.Box.Right), Math.Max(left.Line.Box.Bottom, line.Box.Bottom));
                        var words = (left.Line.Words ?? System.Array.Empty<OcrWord>()).Concat(line.Words ?? System.Array.Empty<OcrWord>()).ToList();
                        current = (new OcrLine(OcrText.JoinLine(new[] { left.Line.Text, line.Text }), box, words), Math.Min(left.Order, order));
                        continue;
                    }

                    result.Add(left);
                }

                current = (line, order);
            }

            if (current is { } last)
            {
                result.Add(last);
            }
        }

        return result.OrderBy(item => item.Order).Select(item => item.Line).ToList();
    }

    /// <summary>这段有没有值得翻译的内容：字母、数字、汉字都算；纯标点、分隔线、装饰符不算（mac hasTranslatableContent）。</summary>
    public static bool HasTranslatableContent(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            if (char.IsLetterOrDigit(text, index))
            {
                return true;
            }
        }

        return false;
    }

    // ---- 排版

    /// <summary>每段用多大字号、画在哪：只算几何，不碰像素（基线、代码块先量好放进 Segment）。</summary>
    public static List<OverlaySpan> Spans(
        IReadOnlyList<OverlaySegment> segments, IReadOnlyList<string> translations, double imageWidth, double imageHeight,
        ITextMeasure measure)
    {
        var body = BodyLineHeight(segments);
        var bodyPitch = BodyPitch(segments, body);
        var bounds = new OverlayRect(0, 0, imageWidth, imageHeight);
        var spans = new List<OverlaySpan>();
        for (var index = 0; index < segments.Count; index++)
        {
            if (index >= translations.Count)
            {
                continue;
            }

            var segment = segments[index];
            var (marker, translated) = ListItem(translations[index].Trim(), segment.Text);
            // 代码词换回原文的写法（服务常把句首的 `total_…` 改成 `Total_…`）
            var text = segment.Code is { } segmentCode ? CodeSpans(translated, segmentCode.Phrases).Text : translated;
            if (text.Length == 0 || !HasTranslatableContent(segment.Text))
            {
                continue;
            }

            var box = segment.Box;
            var others = segments.Where((_, other) => other != index).Select(other => other.Box).ToList();
            var gap = Math.Max(2, segment.LineHeight * 0.3);
            var margin = Math.Max(2, segment.LineHeight * 0.2);

            var isBody = Math.Abs(segment.LineHeight - body) <= body * BodyTolerance;
            var lineHeight = isBody ? body : segment.LineHeight;
            var nominal = lineHeight * FontPerLineHeight;
            var pitch = Math.Min(
                Math.Max(segment.Pitch ?? EstimatedPitch(segment) ?? (isBody ? bodyPitch : null) ?? lineHeight * 1.3, lineHeight * 0.9),
                lineHeight * 2.5);

            // 右边整个在本段右边、高度上有重叠的那一栏：放宽译文时要让出它的位置
            double? column = others.Where(other => other.MinX >= box.MaxX - 0.5 && Overlaps(other, box, vertically: true))
                .Select(other => (double?)other.MinX).Min();
            var rightRoom = (column ?? imageWidth) - margin - box.MinX;
            var width = Math.Max(8, Math.Min(box.Width * 1.25, rightRoom));
            var inset = segment.Inset > 0 ? segment.Inset : marker is not null ? measure.Width(marker + " ", nominal) : 0;
            var columnWidth = Math.Max(8, width - inset);

            double Pad(double? room) => Math.Max(1, Math.Min(segment.LineHeight * ErasePad, (room ?? double.PositiveInfinity) / 2));
            double? left = others.Where(other => other.MaxX <= box.MinX + 0.5 && Overlaps(other, box, vertically: true))
                .Select(other => (double?)(box.MinX - other.MaxX)).Min();
            double? above = others.Where(other => other.MinY >= box.MaxY - 0.5 && Overlaps(other, box, vertically: false))
                .Select(other => (double?)(other.MinY - box.MaxY)).Min();
            double? under = others.Where(other => other.MaxY <= box.MinY + 0.5 && Overlaps(other, box, vertically: false))
                .Select(other => (double?)(box.MinY - other.MaxY)).Min();
            var eraseMinX = box.MinX - Pad(left);
            var eraseMaxX = Math.Max(box.MaxX + Pad(column is { } c ? c - box.MaxX : null), box.MinX + width);

            // 往下能长到哪：这一整条（比原文宽）下面、横向有重叠的段里最高的那个顶边，再留一点空；下面没东西就到图片底边
            double? below = others.Where(other => other.MaxY < box.MaxY - 0.5 && other.MaxX > eraseMinX && other.MinX < eraseMaxX)
                .Select(other => (double?)other.MaxY).Max();
            var bottom = below is { } belowTop ? Math.Max(0, Math.Min(box.MinY, belowTop + gap)) : 0;

            var baseline = segment.Baseline ?? box.MaxY - segment.LineHeight * BaselineDrop;
            var fitted = Fit(text, columnWidth, nominal, pitch, segment.LineCount, baseline, bottom, segment.Code, measure);

            var top = box.MaxY + Pad(above);
            var floor = box.MinY - Pad(under);
            var minX = eraseMinX;
            var maxX = eraseMaxX;
            if (segment.Code is { } code)
            {
                var last = baseline - Math.Max(0, segment.LineCount - 1) * pitch;
                top = Math.Max(top, baseline + code.Above + 1);
                floor = Math.Min(floor, last - code.Below - 1);
                minX = Math.Min(minX, box.MinX - code.Padding - 2);
                maxX = Math.Max(maxX, box.MaxX + code.Padding + 2);
            }

            // 去字的范围也要盖住译文多出来的行
            var eraseMinY = Math.Min(floor, Math.Max(bottom, fitted.TextBottom));
            var erase = OverlayRect.FromEdges(minX, eraseMinY, maxX, top).Intersection(bounds);
            if (erase.Width <= 1 || erase.Height <= 1)
            {
                continue;
            }

            spans.Add(new OverlaySpan
            {
                Text = text,
                Marker = marker,
                Source = box,
                Erase = erase,
                Frame = new OverlayRect(box.MinX + inset, bottom, columnWidth, Math.Max(box.Height, box.MaxY - bottom)),
                Baseline = baseline,
                Pitch = fitted.Pitch,
                FontSize = fitted.FontSize,
                Scale = fitted.FontSize / Math.Max(1, nominal),
                LineHeight = segment.LineHeight,
                Code = segment.Code,
            });
        }

        return spans;
    }

    private static double? EstimatedPitch(OverlaySegment segment)
        => segment.LineCount > 1 ? (segment.Box.Height - segment.LineHeight) / (segment.LineCount - 1) : null;

    /// <summary>全图正文的行高：各段行高按行数加权的中位数。纯符号的段不算。</summary>
    private static double BodyLineHeight(IReadOnlyList<OverlaySegment> segments)
    {
        var heights = segments.Where(segment => HasTranslatableContent(segment.Text))
            .SelectMany(segment => Enumerable.Repeat(segment.LineHeight, Math.Max(1, segment.LineCount)))
            .OrderBy(value => value)
            .ToList();
        return heights.Count == 0 ? 0 : heights[heights.Count / 2];
    }

    private static double? BodyPitch(IReadOnlyList<OverlaySegment> segments, double body)
    {
        var pitches = segments.Where(segment => segment.LineCount > 1 && HasTranslatableContent(segment.Text) &&
                                                Math.Abs(segment.LineHeight - body) <= body * BodyTolerance)
            .Select(segment => segment.Pitch ?? EstimatedPitch(segment))
            .Where(value => value is not null)
            .Select(value => value!.Value)
            .OrderBy(value => value)
            .ToList();
        return pitches.Count == 0 ? null : pitches[pitches.Count / 2];
    }

    private static bool Overlaps(OverlayRect a, OverlayRect b, bool vertically)
        => vertically ? a.MinY < b.MaxY && a.MaxY > b.MinY : a.MinX < b.MaxX && a.MaxX > b.MinX;

    /// <summary>列表项拆成记号和正文：译文里有就用译文的，服务弄丢了就用原文的。</summary>
    private static (string? Marker, string Text) ListItem(string text, string source)
    {
        if (OcrText.ListMarker(text) is { } marker)
        {
            return (marker.Trim(), text[marker.Length..].Trim());
        }

        return (OcrText.ListMarker(source)?.Trim(), text);
    }

    /// <summary>
    /// 字号拟合（mac fit）：① 从基准起，行数不多于原文、也没超出可用的高度就用它，不然一档档缩，最多到基准的四分之三；
    /// ② 四分之三还多出行，就用它借下方的空白；③ 借完还放不下才继续缩、行距跟着缩。
    /// </summary>
    private static (double FontSize, double Pitch, int Lines, double TextBottom) Fit(
        string text, double width, double nominal, double pitch, int lineCount, double baseline, double bottom,
        OverlayCode? code, ITextMeasure measure)
    {
        var start = Math.Max(MinimumFontSize, nominal);
        var floor = Math.Max(MinimumFontSize, start * ShrinkFloor);
        (int Lines, double Bottom) TextBottom(double size, double linePitch)
        {
            var lines = measure.LineCount(text, width, size, code);
            var under = Math.Max(size * 0.25, (code?.Below ?? 0) * size / start);
            return (lines, baseline - Math.Max(0, lines - 1) * linePitch - under);
        }

        var size = start;
        while (true)
        {
            var measured = TextBottom(size, pitch);
            if (measured.Lines <= Math.Max(1, lineCount) && measured.Bottom >= bottom)
            {
                return (size, pitch, measured.Lines, measured.Bottom);
            }

            if (size <= floor)
            {
                break;
            }

            size = Math.Max(floor, size * 0.92);
        }

        var borrowed = TextBottom(size, pitch);
        if (borrowed.Bottom >= bottom)
        {
            return (size, pitch, borrowed.Lines, borrowed.Bottom);
        }

        while (size * 0.92 >= MinimumFontSize)
        {
            size *= 0.92;
            var scaledPitch = pitch * size / floor;
            var measured = TextBottom(size, scaledPitch);
            if (measured.Bottom >= bottom)
            {
                return (size, scaledPitch, measured.Lines, measured.Bottom);
            }
        }

        var lastPitch = pitch * size / floor;
        var lastMeasured = TextBottom(size, lastPitch);
        return (size, lastPitch, lastMeasured.Lines, lastMeasured.Bottom);
    }

    /// <summary>
    /// 译文里的代码串（mac codeSpans）：一个代码块里的词按原文顺序、中间隔着不超过三个空格或标点，前后不连着字母、数字、下划线。
    /// 不分大小写，找到后换回原文的写法（词之间的空格换成不断行空格，长度不变）。重叠的只留先出现、更长的那个。位置是 UTF-16。
    /// </summary>
    public static (string Text, List<(int Start, int Length)> Ranges) CodeSpans(string text, IReadOnlyList<IReadOnlyList<string>> phrases)
    {
        var found = new List<(int Start, int Length, string Replacement)>();
        foreach (var words in phrases)
        {
            if (words.Count == 0)
            {
                continue;
            }

            var pattern = "(?<![A-Za-z0-9_])" +
                          string.Join(@"([\s.,:/\-]{0,3})", words.Select(word => "(" + Regex.Escape(word) + ")")) +
                          "(?![A-Za-z0-9_])";
            foreach (Match match in Regex.Matches(text, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                var replacement = new StringBuilder();
                for (var index = 0; index < words.Count; index++)
                {
                    replacement.Append(words[index]);
                    if (index < words.Count - 1)
                    {
                        replacement.Append(match.Groups[2 * index + 2].Value.Replace(' ', '\u00A0'));
                    }
                }

                found.Add((match.Index, match.Length, replacement.ToString()));
            }
        }

        var kept = new List<(int Start, int Length, string Replacement)>();
        foreach (var item in found.OrderBy(item => item.Start).ThenByDescending(item => item.Length))
        {
            if (kept.Count == 0 || kept[^1].Start + kept[^1].Length <= item.Start)
            {
                kept.Add(item);
            }
        }

        var result = new StringBuilder(text);
        foreach (var item in kept)
        {
            if (item.Replacement.Length == item.Length)
            {
                result.Remove(item.Start, item.Length).Insert(item.Start, item.Replacement);
            }
        }

        return (result.ToString(), kept.Select(item => (item.Start, item.Length)).ToList());
    }

    /// <summary>字色：原文的字色；取不到、或者和底色太接近时按底色深浅用近黑 / 近白。</summary>
    public static OverlayRgb TextColor(OverlayRgb? ink, OverlayRgb background)
    {
        if (ink is { } color && Math.Abs(color.Luminance - background.Luminance) >= 0.3)
        {
            return color;
        }

        return background.Luminance > 0.55 ? new OverlayRgb(0.08, 0.08, 0.09) : new OverlayRgb(0.97, 0.97, 0.97);
    }

    /// <summary>
    /// 从原图量一段（mac measure）：每行的基线（第一行的、行距），哪些词在行内代码块里、代码块长什么样。
    /// </summary>
    public static OverlaySegment Measure(OverlaySegment segment, OverlayPixels original)
    {
        if (!HasTranslatableContent(segment.Text))
        {
            return segment;
        }

        var baselines = original.Baselines(segment.Box, segment.LineHeight);
        double? pitch = null;
        if (baselines.Count > 1)
        {
            var steps = baselines.Zip(baselines.Skip(1), (a, b) => a - b).OrderBy(value => value).ToList();
            pitch = steps[steps.Count / 2];
        }

        var background = original.Ring(segment.Box) ?? OverlayRgb.Light;
        return segment with
        {
            Baseline = baselines.Count > 0 ? baselines[0] : null,
            Pitch = pitch,
            Code = original.Code(segment.Words, segment.Box, baselines, segment.LineHeight, background),
        };
    }

    /// <summary>
    /// 合成的前一半（mac render 里画字之前的那些）：先从原图量出每段的基线、行距和行内代码块，再排版；然后把原文的字从 image 上
    /// 去掉（只换字的像素，有代码块的段连底框一起换）。返回要画的段和各段的字色；画字（和代码块的底框）交给调用方。
    /// </summary>
    public static List<(OverlaySpan Span, OverlayRgb Color)> Compose(
        OverlayPixels image, IReadOnlyList<OverlaySegment> segments, IReadOnlyList<string> translations, ITextMeasure measure)
    {
        var original = image.Snapshot();
        var measured = segments.Select(segment => Measure(segment, original)).ToList();
        var spans = Spans(measured, translations, image.Width, image.Height, measure);
        var result = new List<(OverlaySpan, OverlayRgb)>(spans.Count);
        foreach (var span in spans)
        {
            var background = original.Ring(span.Erase) ?? OverlayRgb.Light;
            var ink = image.Inpaint(span.Erase, original, span.LineHeight, background, clearFills: span.Code is not null);
            result.Add((span, TextColor(ink, background)));
        }

        return result;
    }

    /// <summary>字色：够浓的字像素里出现最多的颜色（门槛取最浓那个的一半）。</summary>
    internal static OverlayRgb? Dominant(List<(double Distance, OverlayRgb Color)> samples)
    {
        if (samples.Count == 0)
        {
            return null;
        }

        var strongest = samples.Max(sample => sample.Distance);
        var counts = new Dictionary<int, (int Count, double Red, double Green, double Blue)>();
        foreach (var (distance, color) in samples)
        {
            if (distance < Math.Max(InkThreshold, strongest * 0.5))
            {
                continue;
            }

            var key = ((int)(color.Red * 15) << 8) | ((int)(color.Green * 15) << 4) | (int)(color.Blue * 15);
            counts.TryGetValue(key, out var old);
            counts[key] = (old.Count + 1, old.Red + color.Red, old.Green + color.Green, old.Blue + color.Blue);
        }

        if (counts.Count == 0)
        {
            return null;
        }

        var best = counts.Values.MaxBy(value => value.Count);
        return new OverlayRgb(best.Red / best.Count, best.Green / best.Count, best.Blue / best.Count);
    }

    internal static double InkLimit => InkThreshold;

    internal static double FillLimit => FillThreshold;

    internal static double Drop => BaselineDrop;
}
