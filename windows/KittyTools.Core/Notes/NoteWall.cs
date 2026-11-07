// 全部便签窗口的「便签墙」（PLAN-v13，照 mac Notes/NoteWall.swift 的纯函数部分；卡片的高照 NoteWallCard 的算法）：
// - 卡片一样宽、高随内容（有上下限），按窗口宽度排几列（列宽固定、整块居中）；瀑布流：每张放进当时最矮的那一列；
//   分段（固定的 / 其他，各有一行小标题；最近删除里不分）。
// - 每张微微斜一点：大小按便签编号定（1–2°，每次一样），方向按位置交错。
// - 方向键在卡片之间怎么走、指针下面是哪张、拖动排序落到哪（只看拖动开始时那份排法）、落成仓库的哪个下标；
//   编辑卡多大、它那块纸从哪长出来 / 缩回哪。
// - 卡片上那段字（Excerpt：标题之后的开头几行 + 这一段里的代码块）和卡片多高（Card：字的高由窗口代码量好传进来——
//   mac 用 NSFont 量，这里不碰字体）。卡片上的字一行一种（CardLines，PLAN-v16 V2）：标题去掉 # 记号、按几级标题的字号画，
//   无序列表的符号画成淡色圆点，代码块的围栏行不要、块里的行原样，别的行去掉行内标记；字号和颜色在窗口代码里。
// 坐标：墙的坐标，滚动内容的左上角是原点、y 向下（mac 也是这么算的，不用换算）。
using System.Text;

namespace KittyTools.Core.Notes;

public static class NoteWall
{
    // ---- 数值（mac-whisker/notes.md「便签墙」）----

    public const double CardWidth = 224;
    public const double Gap = 16;
    public const double Margin = 20;
    public const double SectionGap = 12;
    public const double HeaderHeight = 24;
    public const double MinHeight = 112;
    public const double MaxHeight = 320;
    public const double StripHeight = 3;
    public const double Padding = 12;
    public const double TopInset = 10;
    public const double TitleGap = 4;
    public const double FooterGap = 8;
    public const double FooterHeight = 14;
    public const double BottomInset = 10;
    public const double TitleSize = 14;
    public const double TitleLine = 19;
    public const int TitleLines = 2;
    public const double PinRoom = 16;
    public const double BodySize = 12;
    public const double FadeHeight = 28;
    public const int ExcerptLines = 16;
    public const int ExcerptLength = 1200;
    public const int ExcerptScan = 8192;
    public const double MinTilt = 1.0;
    public const double MaxTilt = 2.0;
    public static readonly (double Width, double Height) EditorShare = (0.78, 0.84);
    public static readonly (double Width, double Height) EditorMax = (680, 560);
    public const double Dim = 0.25;
    public const double SolidDim = 0.5;
    public const double DragInset = 0.2;
    public const double DragSlop = 4;
    public const double EstimatedHeight = 200;
    public const double PaperInset = 24;

    /// <summary>卡片顶上那张缩略图最高多高、和下面的字隔多少（mac NoteImageLayout.thumbnailMaxHeight / thumbnailGap）。</summary>
    public const double ThumbnailMaxHeight = 120;
    public const double ThumbnailGap = 8;

    public static double TextWidth => CardWidth - Padding * 2;

    // ---- 排 ----

    /// <summary>一段：小标题（null = 不画）、卡片的编号和高（从前到后）。</summary>
    public readonly record struct Section(string? Title, IReadOnlyList<string> Ids, IReadOnlyList<double> Heights);

    public readonly record struct Header(string Title, RectD Frame);

    /// <summary>排好的墙。Ids、Frames、Columns、Tilts 按墙上的顺序（各段接着排）；Sections 是每段在 Ids 里的下标范围（空的段不在里面）。</summary>
    public sealed record Layout(
        IReadOnlyList<string> Ids,
        IReadOnlyList<RectD> Frames,
        IReadOnlyList<int> Columns,
        IReadOnlyList<double> Tilts,
        IReadOnlyList<Header> Headers,
        IReadOnlyList<NoteRange> Sections,
        int ColumnCount,
        double Height)
    {
        public int? IndexOf(string id)
        {
            for (var index = 0; index < Ids.Count; index++)
            {
                if (Ids[index] == id)
                {
                    return index;
                }
            }

            return null;
        }

        /// <summary>第 index 张在哪一段（Sections 里的下标）。</summary>
        public int? SectionOf(int index)
        {
            for (var section = 0; section < Sections.Count; section++)
            {
                if (Sections[section].Contains(index))
                {
                    return section;
                }
            }

            return null;
        }

        public bool Equals(Layout? other)
            => other is not null && ColumnCount == other.ColumnCount && Height.Equals(other.Height) &&
               Ids.SequenceEqual(other.Ids) && Frames.SequenceEqual(other.Frames) && Columns.SequenceEqual(other.Columns) &&
               Tilts.SequenceEqual(other.Tilts) && Headers.SequenceEqual(other.Headers) && Sections.SequenceEqual(other.Sections);

        public override int GetHashCode() => HashCode.Combine(Ids.Count, ColumnCount, Height);
    }

    /// <summary>这么宽的墙排几列：列宽固定，放得下几列就几列（至少一列）。</summary>
    public static int ColumnCount(double width)
        => Math.Max(1, (int)Math.Floor((width - Margin * 2 + Gap) / (CardWidth + Gap)));

    /// <summary>排一面墙（mac layout(_:width:)）。</summary>
    public static Layout Arrange(IReadOnlyList<Section> sections, double width)
    {
        var heights = sections.SelectMany(section => section.Heights).ToList();
        return Arrange(sections.Select(section => (section.Title, section.Ids)).ToList(), width, (index, _) => heights[index]);
    }

    /// <summary>同上，卡片的高边排边要：height(第几张（墙上的顺序，各段接着数）, 它的顶落在哪)。各段依次往下排：有标题的先放一行小标题，
    /// 卡片按顺序一张张放进当时最矮的那一列（一样矮的取左边的）；空的段整段跳过（连标题）。卡片的顶按排的顺序只增不减，
    /// 调用方可以只为顶在可见区附近的现量、往下的先给 EstimatedHeight。</summary>
    public static Layout Arrange(
        IReadOnlyList<(string? Title, IReadOnlyList<string> Ids)> sections, double width, Func<int, double, double> height)
    {
        var columns = ColumnCount(width);
        var span = columns * CardWidth + (columns - 1) * Gap;
        var left = Math.Max(Margin, Math.Floor((width - span) / 2));
        var ids = new List<string>();
        var frames = new List<RectD>();
        var columnOf = new List<int>();
        var tilts = new List<double>();
        var headers = new List<Header>();
        var ranges = new List<NoteRange>();
        var y = Margin;
        foreach (var (title, sectionIds) in sections)
        {
            if (sectionIds.Count == 0)
            {
                continue;
            }

            if (ranges.Count > 0)
            {
                y += SectionGap;
            }

            if (title is not null)
            {
                headers.Add(new Header(title, new RectD(left, y, span, HeaderHeight)));
                y += HeaderHeight;
            }

            var bottoms = Enumerable.Repeat(y, columns).ToArray();
            // 这一段里每一列放了几张（倾斜的方向按它交错；每段从头数）
            var rows = new int[columns];
            var start = ids.Count;
            foreach (var id in sectionIds)
            {
                var column = 0;
                for (var candidate = 1; candidate < columns; candidate++)
                {
                    if (bottoms[candidate] < bottoms[column])
                    {
                        column = candidate;
                    }
                }

                var cardHeight = height(ids.Count, bottoms[column]);
                ids.Add(id);
                frames.Add(new RectD(left + column * (CardWidth + Gap), bottoms[column], CardWidth, cardHeight));
                columnOf.Add(column);
                tilts.Add(Tilt(id, column, rows[column]));
                bottoms[column] += cardHeight + Gap;
                rows[column]++;
            }

            ranges.Add(NoteRange.Of(start, ids.Count));
            y = bottoms.Max() - Gap;
        }

        return new Layout(ids, frames, columnOf, tilts, headers, ranges, columns, y + Margin);
    }

    /// <summary>一张卡片斜多少度（顺时针为正）：大小按编号定（1–2°，FNV-1a 过 UTF-8，每次启动一样），方向按位置交错——
    /// 列号 + 它是这一段里这一列的第几张，偶数逆时针、奇数顺时针。</summary>
    public static double Tilt(string id, int column, int row)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var value in Encoding.UTF8.GetBytes(id))
        {
            hash = unchecked((hash ^ value) * 0x100000001b3UL);
        }

        var size = MinTilt + (MaxTilt - MinTilt) * (hash % 1001) / 1000;
        return (column + row) % 2 == 0 ? -size : size;
    }

    // ---- 方向键 ----

    public enum Direction
    {
        Up,
        Down,
        Left,
        Right,
    }

    /// <summary>从第 index 张往 direction 走到哪张；走不动是 null。↑↓：同一列里上一张 / 下一张（跨段接着走），这一列那边没有了就去
    /// 最近的有卡片的那一列里离得最近的一张；←→：那边最近的一列里，竖直方向上中心离这张最近的那张。</summary>
    public static int? Neighbor(int index, Direction direction, Layout layout)
    {
        if (index < 0 || index >= layout.Frames.Count)
        {
            return null;
        }

        var here = layout.Frames[index];
        var column = layout.Columns[index];
        int? best = null;
        var (bestColumns, bestOffset) = (0, 0.0);
        for (var other = 0; other < layout.Frames.Count; other++)
        {
            if (other == index)
            {
                continue;
            }

            var frame = layout.Frames[other];
            var distance = Math.Abs(layout.Columns[other] - column);
            double offset;
            switch (direction)
            {
                case Direction.Down when frame.Y > here.Y:
                    offset = frame.Y;
                    break;
                case Direction.Up when frame.Y < here.Y:
                    offset = -frame.Y;
                    break;
                case Direction.Left when layout.Columns[other] < column:
                case Direction.Right when layout.Columns[other] > column:
                    offset = Math.Abs(frame.MidY - here.MidY);
                    break;
                default:
                    continue;
            }

            if (best is null || distance < bestColumns || (distance == bestColumns && offset < bestOffset))
            {
                (best, bestColumns, bestOffset) = (other, distance, offset);
            }
        }

        return best;
    }

    // ---- 拖动排序 ----

    /// <summary>指针下面是哪张：point 落在它里面（四边各往里收 inset × 边长；拖动时用 DragInset）。左、上边算里面，右、下边不算。</summary>
    public static int? ItemAt(PointD point, Layout layout, double inset = 0)
    {
        for (var index = 0; index < layout.Frames.Count; index++)
        {
            var frame = layout.Frames[index];
            var (dx, dy) = (frame.Width * inset, frame.Height * inset);
            if (point.X >= frame.X + dx && point.X < frame.Right - dx && point.Y >= frame.Y + dy && point.Y < frame.Bottom - dy)
            {
                return index;
            }
        }

        return null;
    }

    /// <summary>items 里把第 from 个挪成第 to 个（挪完之后的下标）；越界或同一个原样。</summary>
    public static List<T> Moved<T>(IReadOnlyList<T> items, int from, int to)
    {
        var list = items.ToList();
        if (from < 0 || from >= list.Count || to < 0 || to >= list.Count || from == to)
        {
            return list;
        }

        var item = list[from];
        list.RemoveAt(from);
        list.Insert(to, item);
        return list;
    }

    /// <summary>拖着原来第 from 张、停在第 over 张上：落成 over 那个位置；两张不在同一段时不换（null）。</summary>
    public static int? Landing(int from, int over, Layout layout)
        => layout.SectionOf(from) is { } section && layout.SectionOf(over) == section ? over : null;

    /// <summary>拖着原来第 from 张、现在让到第 current 张，指针在 point：该让到第几张。**只看拖动开始时那份排法（based）**——指针进到
    /// 同一段里另一张的里面（四边各收 DragInset）就落到那张的位置，不然不动（current）。</summary>
    public static int DropTarget(int from, int current, PointD point, Layout based)
        => ItemAt(point, based, DragInset) is { } over && Landing(from, over, based) is { } to ? to : current;

    /// <summary>墙上拖完之后的顺序 → 仓库挪顺序要的下标（「全部」里没归档没删的那一列，挪完之后的下标）：照它在墙上同一段里紧挨着的
    /// 那张放——后面有一张就放到那张前面，它是这一段的最后一张就放到前面那张后面。active：仓库现在的顺序（编号）。</summary>
    public static int? StoreIndex(string id, IReadOnlyList<string> order, NoteRange section, IReadOnlyList<string> active)
    {
        var rest = active.Where(other => other != id).ToList();
        var at = -1;
        for (var index = 0; index < order.Count; index++)
        {
            if (order[index] == id)
            {
                at = index;
                break;
            }
        }

        if (at < 0 || !section.Contains(at))
        {
            return null;
        }

        if (at + 1 < section.End && rest.IndexOf(order[at + 1]) is var next and >= 0)
        {
            return next;
        }

        if (at > section.Location && rest.IndexOf(order[at - 1]) is var previous and >= 0)
        {
            return previous + 1;
        }

        return null;
    }

    // ---- 编辑卡 ----

    /// <summary>编辑卡多大：墙（连顶上那一条）的七八成，有上限。</summary>
    public static (double Width, double Height) EditorSize((double Width, double Height) container)
        => (Math.Min(EditorMax.Width, Math.Round(container.Width * EditorShare.Width, MidpointRounding.AwayFromZero)),
            Math.Min(EditorMax.Height, Math.Round(container.Height * EditorShare.Height, MidpointRounding.AwayFromZero)));

    /// <summary>编辑卡那块纸长出来的起点、缩回去的终点：那张卡片**现在**在这一块（墙连顶上那一条）里的位置——墙上的位置 − 滚过的 +
    /// 顶上那一条多高。card 不在墙上（null）或整张都在可见区外给 null：纸在中央略小一圈（PaperInset）长出来 / 淡掉。收回时按收回那一刻算。</summary>
    public static RectD? PaperRect(RectD? card, double top, double scrollY, double viewport)
    {
        if (card is not { } frame)
        {
            return null;
        }

        var rect = frame.Offset(0, top - scrollY);
        return rect.Bottom > top && rect.Y < top + viewport ? rect : null;
    }

    // ---- 卡片上的字 ----

    /// <summary>只看正文开头 ExcerptScan 个字时在哪截：一段图片令牌跨在截断处就截到令牌后面（截成两半的令牌认不出来，后半截原文会露出来）。</summary>
    public static int ScanEnd(string body)
    {
        if (body.Length <= ExcerptScan)
        {
            return body.Length;
        }

        var reach = NoteImages.Token(
            new NoteImages.Image(Guid.Empty, new string('x', NoteImages.MaxExtension), NoteImages.MaxWidth)).Length;
        for (var index = Math.Max(ExcerptScan - reach, 0); index < ExcerptScan; index++)
        {
            if (body[index] == '!' && NoteImages.Match(body, index) is { } match && match.Range.End > ExcerptScan)
            {
                return match.Range.End;
            }
        }

        return ExcerptScan;
    }

    public enum CardLineKind
    {
        Plain,
        Heading,
        Bullet,
        Code,
    }

    /// <summary>卡片上的一行：哪种、几级标题（Heading）、列表符号前面缩进几个空白（Bullet）、去掉记号之后的字。</summary>
    public readonly record struct CardLine(CardLineKind Kind, string Text, int Level = 0, int Indent = 0);

    /// <summary>
    /// 卡片上那段字一行一行（照 mac NoteWallCard.make：样式同正文编辑器，藏着的标记和代码块的围栏行删掉）：标题行去掉 # 和后面的空白、
    /// 行内的标记照样去；无序列表的 - * + 换成圆点（窗口代码画淡色，mac 是淡色的原符号，PLAN-v16 V2 要圆点）；代码块里的行原样；
    /// 别的行同列表里的摘要（NoteMarkdown.Plain，引用的 &gt; 也去）。
    /// </summary>
    public static List<CardLine> CardLines(Note note)
    {
        var (text, blocks) = Excerpt(note);
        var lines = new List<CardLine>();
        foreach (var (start, contentsEnd, _) in NoteText.Lines(text))
        {
            var line = text[start..contentsEnd];
            switch (NoteMarkdown.RoleAt(start, blocks))
            {
                case NoteMarkdown.Role.Open or NoteMarkdown.Role.Close:
                    continue;
                case NoteMarkdown.Role.Content:
                    lines.Add(new CardLine(CardLineKind.Code, line));
                    continue;
            }

            if (NoteMarkdown.Heading(line) is { } heading)
            {
                lines.Add(new CardLine(CardLineKind.Heading, NoteMarkdown.Plain(line[heading.Marker.End..], blocks: false), heading.Level));
            }
            else if (NoteTasks.PrefixOf(line) is { Lead.Kind: NoteTasks.LeadKind.Bullet } prefix)
            {
                lines.Add(new CardLine(CardLineKind.Bullet, NoteMarkdown.Plain(line[prefix.ContentStart..], blocks: false), Indent: prefix.Indent));
            }
            else
            {
                lines.Add(new CardLine(CardLineKind.Plain, NoteMarkdown.Plain(line, blocks: true)));
            }
        }

        // 末尾的空行不要（收尾的围栏删了之后，不然多出一行空的高）
        while (lines.Count > 0 && lines[^1].Kind != CardLineKind.Code && lines[^1].Text.Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }

        return lines;
    }

    /// <summary>卡片上带的正文：标题之后的开头几行（原文，连着的一段）和这一段里的代码块（位置相对这一段）。没自己起标题的，标题就是
    /// 正文第一个有内容的行（Note.DisplayTitle），这一行不再重复（跳过前面的空行和围栏行）。最多 ExcerptLines 行、ExcerptLength 个
    /// UTF-16；只认正文开头 ExcerptScan 个字里的代码块，被截在中间的照样算块。图片先处理（只有图片的行整行去掉、行内的令牌换成「[图片]」）
    /// 再认代码块、再截取。</summary>
    public static (string Text, IReadOnlyList<NoteMarkdown.CodeBlock> Blocks) Excerpt(Note note)
    {
        var body = note.Body;
        var raw = body.Length > ExcerptScan ? NoteText.SafePrefix(body, ScanEnd(body)) : body;
        var head = NoteImages.DisplayLines(raw);
        IReadOnlyList<NoteMarkdown.CodeBlock> blocks = NoteMarkdown.CodeBlocks(head);
        var location = 0;
        // 标题取自正文第一行时跳过它（和它前面的空行、围栏行）
        if (NoteText.TrimSpacesAndNewlines(note.Title).Length == 0)
        {
            while (location < head.Length)
            {
                var line = NoteText.Line(head, location);
                location = Math.Max(line.End, location + 1);
                var role = NoteMarkdown.RoleAt(line.Start, blocks);
                if (IsBlank(head, line.Start, line.ContentsEnd) || role == NoteMarkdown.Role.Open || role == NoteMarkdown.Role.Close)
                {
                    continue;
                }

                break;
            }
        }

        // 开头的空行不要；标题取自代码块里的一行时，紧跟着的收尾围栏也不要
        while (location < head.Length)
        {
            var line = NoteText.Line(head, location);
            if (!IsBlank(head, line.Start, line.ContentsEnd) && NoteMarkdown.RoleAt(line.Start, blocks) != NoteMarkdown.Role.Close)
            {
                break;
            }

            location = Math.Max(line.End, location + 1);
        }

        var start = location;
        var end = start;
        var lines = 0;
        while (location < head.Length && lines < ExcerptLines && end - start < ExcerptLength)
        {
            var line = NoteText.Line(head, location);
            end = line.ContentsEnd;
            location = Math.Max(line.End, location + 1);
            lines++;
        }

        end = Math.Min(end, start + ExcerptLength);
        if (end <= start)
        {
            return (string.Empty, Array.Empty<NoteMarkdown.CodeBlock>());
        }

        // 不把一对代理项从中间切开（mac rangeOfComposedCharacterSequences）。ponytail: 只管代理项，不管组合字符；
        // 截在一个带组合符的字中间时最后一个字少了组合符，卡片上一眼看个大概，够用
        if (end < head.Length && char.IsLowSurrogate(head[end]) && char.IsHighSurrogate(head[end - 1]))
        {
            end++;
        }

        var range = NoteRange.Of(start, end);
        var text = head[start..end];
        // 碰到这一段的块，挪到这一段的坐标里；被截在头上的开头记成空的（长度 0），截在尾上的收尾放在这一段的末尾之外
        var shifted = new List<NoteMarkdown.CodeBlock>();
        foreach (var block in blocks)
        {
            if (block.Close.End <= range.Location || block.Open.Location >= range.End)
            {
                continue;
            }

            var open = block.Open.Location >= range.Location
                ? new NoteRange(block.Open.Location - range.Location, block.Open.Length)
                : new NoteRange(0, 0);
            var close = block.Close.End <= range.End
                ? new NoteRange(block.Close.Location - range.Location, block.Close.Length)
                : new NoteRange(range.Length + 1, 0);
            shifted.Add(new NoteMarkdown.CodeBlock(open, close));
        }

        return (text, shifted);
    }

    private static bool IsBlank(string text, int start, int end)
    {
        for (var index = start; index < end; index++)
        {
            if (!NoteText.IsWhite(text[index]))
            {
                return false;
            }
        }

        return true;
    }

    // ---- 卡片多高 ----

    /// <summary>一张卡片的尺寸：标题排多宽、画多高（一两行）、正文排完多高、正文在卡片里露出来多高（超出的截断渐隐）、整张多高、
    /// 顶上缩略图多高（0 = 没有）。</summary>
    public readonly record struct CardMetrics(
        double TitleWidth, double TitleHeight, double BodyHeight, double BodyRoom, double Height, double ThumbnailHeight)
    {
        public bool Overflows => BodyHeight > BodyRoom + 0.5;

        /// <summary>卡片上字的那一块多高：标题 + 露出来的正文。</summary>
        public double TextHeight => TitleHeight + (BodyHeight > 0 ? TitleGap + BodyRoom : 0);
    }

    /// <summary>标题排多宽：固定的给右上角的图钉让出 PinRoom。</summary>
    public static double TitleWidthFor(bool isPinned) => TextWidth - (isPinned ? PinRoom : 0);

    /// <summary>卡片多高（mac NoteWallCard.init 的算法）。titleMeasured：标题（TitleSize 半粗、行高定死 TitleLine）按 TitleWidthFor(isPinned)
    /// 宽排出来多高；bodyMeasured：卡片上那段字（Excerpt 的字删掉藏着的标记和围栏行之后，BodySize、正文编辑器「标准」行距）按 TextWidth
    /// 宽排完多高，没有正文给 0；thumbnailHeight：ThumbnailHeight 算的（没有图给 0）。窗口代码量字，这里只排。</summary>
    public static CardMetrics Card(bool isPinned, double titleMeasured, double bodyMeasured, double thumbnailHeight = 0)
    {
        var titleHeight = Math.Min(Math.Ceiling(titleMeasured), TitleLine * TitleLines);
        var bodyHeight = bodyMeasured > 0 ? Math.Ceiling(bodyMeasured) : 0;
        var thumbnail = thumbnailHeight > 0 ? thumbnailHeight : 0;
        var chrome = StripHeight + TopInset + titleHeight + FooterGap + FooterHeight + BottomInset +
                     (thumbnail > 0 ? thumbnail + ThumbnailGap : 0);
        var natural = chrome + (bodyHeight > 0 ? TitleGap + bodyHeight : 0);
        var height = Math.Min(Math.Max(natural, MinHeight), MaxHeight);
        return new CardMetrics(TitleWidthFor(isPinned), titleHeight, bodyHeight, Math.Max(0, height - chrome - TitleGap), height, thumbnail);
    }

    /// <summary>卡片顶上那张缩略图（正文里的第一张图，NoteImages.First）多高：按图的宽高比铺满字的宽，最高 ThumbnailMaxHeight。
    /// 宽高按图片文件的元数据给（不等解码）；读不出来（文件不在）给 0 = 不放缩略图。</summary>
    public static double ThumbnailHeight(double imageWidth, double imageHeight)
        => imageWidth > 0 && imageHeight > 0
            ? Math.Min(ThumbnailMaxHeight, Math.Round(TextWidth * imageHeight / imageWidth, MidpointRounding.AwayFromZero))
            : 0;
}
