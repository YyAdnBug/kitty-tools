// 便签正文样式里的纯函数部分（PLAN-v13 第 4 批，照 mac Notes/NoteStyles.swift）：存的是纯文本，样式是显示时加的。
// 这里只有「哪一段是什么、叠起来长什么样、要重排哪几行、行距和比例」，换成 RichEditBox 的格式那一层（mac 的 apply、
// Theme、BoxMetrics、字体、布局管理器的代理、outdated）在 WinUI 的编辑器包装里重写，不在这里。
// - Spans：一行文字 → 若干「区间 + 样式种类」。任务的两种（方框那个字、做完的任务的内容）不看 Markdown 开关；
//   开着时再加 Markdown 的（标题、粗体、斜体、删除线、行内代码、链接、引用、无序列表的符号、和它们的标记）——
//   行内的由 NoteMarkdown 的扫描器认。任务行的内容里只认行内样式。颜色不看开关（关着时只留颜色那几段）。
// - BlockSpans：代码块里的一行整行一种样式（块里的字 / 围栏行）；ShapeOf：这一行在段落上是哪种（行高、段前段后、缩进按它定）。
// - Runs：把可以互相套着的区间叠成一段段「最后长什么样」（Look）：字号跟这一行的标题级别走，粗细 / 倾斜 / 等宽 / 划线叠上去。
// - Pending / LinesCovering / NeighborLines / Merged：编辑过的区间 → 要重排的那几行（前后各扩一个字、扩到整行；组字期间攒着）。
// - RoleChanges：代码块的角色跟着正文里围栏的配对变，改一个围栏可能让后面整块都变——找出「上次排时记下的角色」和
//   现在认出来的不一样的那些行（mac 读的是文本存储上的 roleKey，这里由调用方把记着的区间传进来）。
// - 行距三档、各个比例（标题、代码、方框、引用缩进、段前段后），数和 mac 一样（长相在 mac-whisker/notes.md）。
// 位置都是 UTF-16 的（同 C# 的 string 下标）。
namespace KittyTools.Core.Notes;

/// <summary>正文的行距（设置 › 便签「行距」）：每一行的行高 = 这一行的字号 × 倍数（整点），字在行里竖直居中。</summary>
public enum NoteSpacing
{
    Compact,
    Standard,
    Relaxed,
}

public static class NoteStyles
{
    // ---- 种类和区间 ----

    public enum KindTag
    {
        /// <summary>任务的方框（五种状态的那一个字），带 State。</summary>
        Box,

        /// <summary>做完 / 取消的任务的内容：划线、墨色变淡。</summary>
        Done,

        /// <summary>上了色的字（`[字]{red}` 中间那一段），带 Ink。</summary>
        Color,

        /// <summary>标题（1–6 级）：整行，连标记；带 Level。</summary>
        Heading,
        Bold,
        Italic,
        Strike,

        /// <summary>行内代码（不含两头的反引号）。</summary>
        Code,

        /// <summary>链接的字；带着它的地址 Address（原样，能不能打开看 NoteMarkdown.Url）。</summary>
        Link,

        /// <summary>引用：整行，连标记。</summary>
        Quote,

        /// <summary>无序列表的符号（- * +），和后面没有字的引用的 &gt;：变淡，不藏。</summary>
        Bullet,

        /// <summary>Markdown 的标记字符：光标不在这一行时藏起来，在的时候淡淡显示。</summary>
        Marker,

        /// <summary>代码块里的一行（整行，按原文）。</summary>
        CodeBlock,

        /// <summary>代码块的围栏行（整行，一直显示、不藏）。</summary>
        Fence,
    }

    /// <summary>样式的种类（mac 是带关联值的枚举）：用到的那个关联值记在对应的字段里，别的字段一律是默认值——
    /// 所以用下面的工厂建，自动生成的相等比较才对。</summary>
    public readonly record struct Kind(
        KindTag Tag, NoteTaskState State = default, NoteColor Ink = default, int Level = 0, string? Address = null)
    {
        public static readonly Kind Done = new(KindTag.Done);
        public static readonly Kind Bold = new(KindTag.Bold);
        public static readonly Kind Italic = new(KindTag.Italic);
        public static readonly Kind Strike = new(KindTag.Strike);
        public static readonly Kind Code = new(KindTag.Code);
        public static readonly Kind Quote = new(KindTag.Quote);
        public static readonly Kind Bullet = new(KindTag.Bullet);
        public static readonly Kind Marker = new(KindTag.Marker);
        public static readonly Kind CodeBlock = new(KindTag.CodeBlock);
        public static readonly Kind Fence = new(KindTag.Fence);

        public static Kind Box(NoteTaskState state) => new(KindTag.Box, State: state);

        public static Kind Color(NoteColor ink) => new(KindTag.Color, Ink: ink);

        public static Kind Heading(int level) => new(KindTag.Heading, Level: level);

        public static Kind Link(string address) => new(KindTag.Link, Address: address);
    }

    /// <summary>一段样式：区间是 UTF-16 的、相对这一行的开头。区间可以互相套着（粗体里的斜体、标题里的链接）。</summary>
    public readonly record struct Span(NoteRange Range, Kind Kind);

    /// <summary>这一行（不含行尾的换行）要加哪些样式。markdown：设置 › 便签「Markdown 样式」开没开（任务、颜色不看它）。</summary>
    public static List<Span> Spans(string line, bool markdown)
    {
        var prefix = NoteTasks.PrefixOf(line);
        if (prefix is { Lead.Kind: NoteTasks.LeadKind.Task } task)
        {
            var spans = new List<Span> { new(new NoteRange(task.Indent, 1), Kind.Box(task.Lead.State)) };
            if (NoteTasks.IsClosed(task.Lead.State) && line.Length > task.ContentStart)
            {
                spans.Add(new Span(new NoteRange(task.ContentStart, line.Length - task.ContentStart), Kind.Done));
            }

            // 任务行的内容里只认行内样式；Markdown 关着时颜色照样认
            spans.AddRange(markdown
                ? NoteMarkdown.Inline(line, task.ContentStart, line.Length)
                : NoteMarkdown.ColorOnlySpans(line));
            return spans;
        }

        if (!markdown)
        {
            return NoteMarkdown.ColorOnlySpans(line);
        }

        var result = new List<Span>();
        var content = 0;
        if (NoteMarkdown.Heading(line) is { } heading)
        {
            result.Add(new Span(new NoteRange(0, line.Length), Kind.Heading(heading.Level)));
            result.Add(new Span(heading.Marker, Kind.Marker));
            content = heading.Marker.End;
        }
        else if (NoteMarkdown.Quote(line) is { } marker)
        {
            // 后面没有字的引用（夹在几行引用中间的空行）：> 不藏、只是变淡——全藏起来的话这一行什么都没有
            var isEmpty = marker.End == line.Length;
            result.Add(new Span(new NoteRange(0, line.Length), Kind.Quote));
            result.Add(new Span(marker, isEmpty ? Kind.Bullet : Kind.Marker));
            content = marker.End;
        }
        else if (prefix is { Lead.Kind: NoteTasks.LeadKind.Bullet } bullet)
        {
            result.Add(new Span(new NoteRange(bullet.Indent, 1), Kind.Bullet));
            content = bullet.ContentStart;
        }

        result.AddRange(NoteMarkdown.Inline(line, content, line.Length));
        return result;
    }

    /// <summary>代码块里的一行：整行一种样式，里面什么 Markdown 都不认（任务的方框、列表符号也是原文）。</summary>
    public static List<Span> BlockSpans(string line, NoteMarkdown.Role role)
        => new() { new Span(new NoteRange(0, line.Length), role == NoteMarkdown.Role.Content ? Kind.CodeBlock : Kind.Fence) };

    public enum ShapeKind
    {
        Plain,
        Heading,
        Quote,
        Code,
    }

    /// <summary>一行在段落上是哪种（mac 的 Shape：plain / heading(级别) / quote / code(角色)）。用工厂建，相等比较才对。</summary>
    public readonly record struct Shape(ShapeKind Kind, int Level = 0, NoteMarkdown.Role Role = default)
    {
        public static readonly Shape Plain = new(ShapeKind.Plain);
        public static readonly Shape Quote = new(ShapeKind.Quote);

        public static Shape Heading(int level) => new(ShapeKind.Heading, Level: level);

        public static Shape Code(NoteMarkdown.Role role) => new(ShapeKind.Code, Role: role);
    }

    /// <summary>这一行（不含行尾的换行）在段落上是哪种；和 Spans 认的一样（任务行不是标题、不是引用）。role：它在不在代码块里。</summary>
    public static Shape ShapeOf(string line, bool markdown, NoteMarkdown.Role? role)
    {
        if (role is { } inBlock)
        {
            return Shape.Code(inBlock);
        }

        if (!markdown || NoteTasks.PrefixOf(line) is { Lead.Kind: NoteTasks.LeadKind.Task })
        {
            return Shape.Plain;
        }

        if (NoteMarkdown.Heading(line) is { } heading)
        {
            return Shape.Heading(heading.Level);
        }

        return NoteMarkdown.Quote(line) is not null ? Shape.Quote : Shape.Plain;
    }

    // ---- 叠起来 ----

    /// <summary>一小段字叠完之后长什么样。Heading：标题的级别（0 = 不在标题里）；BoxState：任务方框的状态（null = 不是方框）；
    /// Color：文字颜色（null = 默认的墨）；Link：在链接的字里时它的地址。</summary>
    public readonly record struct Look(
        int Heading = 0,
        bool IsBold = false,
        bool IsItalic = false,
        bool IsStruck = false,
        bool IsCode = false,
        bool IsQuote = false,
        bool IsDone = false,
        bool IsBullet = false,
        NoteTaskState? BoxState = null,
        bool IsMarker = false,
        bool IsCodeBlock = false,
        bool IsFence = false,
        NoteColor? Color = null,
        string? Link = null);

    /// <summary>一段样子一样的字：区间是 UTF-16 的、相对这一行的开头。</summary>
    public readonly record struct Run(NoteRange Range, Look Look);

    /// <summary>扫到某个位置时在几层什么里面（同一种可以套几层：粗体里的粗体）。</summary>
    private struct Depth
    {
        private NoteTaskState? boxState;
        private NoteColor? color;
        private int done;
        private int bold;
        private int italic;
        private int strike;
        private int code;
        private int quote;
        private int bullet;
        private int marker;
        private int codeBlock;
        private int fence;
        private int heading;
        private string? link;

        /// <summary>进了（step 是 1）/ 出了（-1）一段 kind。</summary>
        public void Move(Kind kind, int step)
        {
            switch (kind.Tag)
            {
                case KindTag.Box:
                    boxState = step > 0 ? kind.State : (NoteTaskState?)null;
                    break;
                case KindTag.Color:
                    color = step > 0 ? kind.Ink : (NoteColor?)null;
                    break;
                case KindTag.Done:
                    done += step;
                    break;
                case KindTag.Bold:
                    bold += step;
                    break;
                case KindTag.Italic:
                    italic += step;
                    break;
                case KindTag.Strike:
                    strike += step;
                    break;
                case KindTag.Code:
                    code += step;
                    break;
                case KindTag.Quote:
                    quote += step;
                    break;
                case KindTag.Bullet:
                    bullet += step;
                    break;
                case KindTag.Marker:
                    marker += step;
                    break;
                case KindTag.CodeBlock:
                    codeBlock += step;
                    break;
                case KindTag.Fence:
                    fence += step;
                    break;
                // 一行最多一个标题；链接里不套链接
                case KindTag.Heading:
                    heading = step > 0 ? kind.Level : 0;
                    break;
                case KindTag.Link:
                    link = step > 0 ? kind.Address : null;
                    break;
            }
        }

        public readonly Look Look => new(
            heading, bold > 0, italic > 0, strike > 0, code > 0, quote > 0, done > 0, bullet > 0,
            boxState, marker > 0, codeBlock > 0, fence > 0, color, link);
    }

    /// <summary>把一行的样式区间叠成一段段（从左到右、互不相交；什么样式都没有的那些段不给）。</summary>
    public static List<Run> Runs(IReadOnlyList<Span> spans)
    {
        // 每段的两头各记一笔，按位置排好（稳定排序），从左到右数「现在在几层什么里面」
        var edges = new List<(int At, int Step, Kind Kind)>(spans.Count * 2);
        foreach (var span in spans)
        {
            if (span.Range.Length > 0)
            {
                edges.Add((span.Range.Location, 1, span.Kind));
                edges.Add((span.Range.End, -1, span.Kind));
            }
        }

        var runs = new List<Run>();
        var depth = default(Depth);
        var last = 0;
        foreach (var edge in edges.OrderBy(e => e.At))
        {
            var look = depth.Look;
            if (edge.At > last && look != default(Look))
            {
                runs.Add(new Run(new NoteRange(last, edge.At - last), look));
            }

            last = edge.At;
            depth.Move(edge.Kind, edge.Step);
        }

        return runs;
    }

    // ---- 要重排哪几行 ----

    /// <summary>攒着的「编辑过的区间」（正文每改一次报一次）：合成一段，后来的编辑让前面记下的位置跟着挪。
    /// 输入法组字期间只攒不用，确认后一次拿走。（mac 是值类型；这里是类，编辑器持有一个，不会被无意拷贝。）</summary>
    public sealed class Pending
    {
        public NoteRange? Range { get; private set; }

        /// <summary>记一次编辑：edited 是改完之后那一段的位置，delta 是长度变了多少。</summary>
        public void Record(NoteRange edited, int delta)
        {
            if (Range is not { } old)
            {
                Range = edited;
                return;
            }

            // 改之前那一段到哪为止：在它后面的位置都挪了 delta
            var oldEnd = edited.End - delta;
            var (start, end) = (old.Location, old.End);
            if (start >= oldEnd)
            {
                start += delta;
            }

            if (end >= oldEnd)
            {
                end += delta;
            }

            start = Math.Max(Math.Min(start, edited.Location), 0);
            end = Math.Max(end, edited.End);
            Range = new NoteRange(start, end - start);
        }

        /// <summary>拿走攒着的那一段。</summary>
        public NoteRange? Take()
        {
            var taken = Range;
            Range = null;
            return taken;
        }
    }

    /// <summary>编辑过的区间 → 要重排的那几行（整行，连行尾的换行）：前后各扩一个字再扩到整行——插入、删除换行时两头的行都要重排。
    /// 区间夹进正文的长度里（攒着的时候正文又变短了也不越界）。</summary>
    public static NoteRange LinesCovering(NoteRange edited, string text)
    {
        var start = Math.Min(Math.Max(edited.Location - 1, 0), text.Length);
        var end = Math.Min(Math.Max(edited.End + 1, start), text.Length);
        return NoteText.LineRange(text, NoteRange.Of(start, end));
    }

    /// <summary>这几行（整行）再往上、往下各带一行：引用块的段前段后看的是上下两行是不是引用，一行变了，挨着的两行也要重排。</summary>
    public static NoteRange NeighborLines(NoteRange lines, string text)
    {
        var start = lines.Location > 0
            ? NoteText.LineRange(text, new NoteRange(lines.Location - 1, 0)).Location
            : lines.Location;
        var end = lines.End < text.Length
            ? NoteText.LineRange(text, new NoteRange(lines.End, 0)).End
            : lines.End;
        return NoteRange.Of(start, end);
    }

    /// <summary>几段区间从前到后排好，重叠的、首尾相接的并成一段。</summary>
    public static List<NoteRange> Merged(IEnumerable<NoteRange> ranges)
    {
        var merged = new List<NoteRange>();
        foreach (var range in ranges.OrderBy(r => r.Location))
        {
            if (merged.Count > 0 && range.Location <= merged[^1].End)
            {
                merged[^1] = merged[^1].Union(range);
            }
            else
            {
                merged.Add(range);
            }
        }

        return merged;
    }

    /// <summary>代码块里的角色和上次排时记下的不一样的那些行（整行，从前到后、挨着的并成一段）：开头、收尾的围栏配上了 /
    /// 拆开了，块里的行一下子都变了。
    /// stored：上次排的时候记着角色的那些区间和角色（mac 是字上的 roleKey：编辑器每排一行就把那一行整行连换行记一次，
    /// 之后正文改了要跟着挪——同 Pending 的挪法；从前到后排好、互不相交，挨着的同一种可以并成一段，也可以一行一段）。
    /// blocks：照现在的正文认出来的（NoteMarkdown.CodeBlocks）。isStyled：这一行排过没有（mac 看 lineFontKey；
    /// 整段换字时只当场排了开头一屏，后面的还没排过，轮到它时照那时的正文排，不算变了）；null = 全都排过。
    /// 只看两边沾着代码块的行：记着角色的、现在在块里的；两边都没有代码块时什么都不做。</summary>
    public static List<NoteRange> RoleChanges(
        string text,
        IReadOnlyList<(NoteRange Range, NoteMarkdown.Role Role)> stored,
        IReadOnlyList<NoteMarkdown.CodeBlock> blocks,
        Func<int, bool>? isStyled = null)
    {
        var full = new NoteRange(0, text.Length);
        var found = new List<NoteRange>();

        // 第 position 个字上记着的角色（stored 里盖着它的那一段；没有就是 null）
        NoteMarkdown.Role? StoredAt(int position)
        {
            var (low, high) = (0, stored.Count);
            while (low < high)
            {
                var middle = (low + high) / 2;
                if (stored[middle].Range.End <= position)
                {
                    low = middle + 1;
                }
                else
                {
                    high = middle;
                }
            }

            return low < stored.Count && stored[low].Range.Contains(position) ? stored[low].Role : (NoteMarkdown.Role?)null;
        }

        void Check(NoteRange range)
        {
            var location = range.Location;
            while (location < range.End)
            {
                var line = NoteText.LineRange(text, new NoteRange(location, 0));
                if (StoredAt(line.Location) != NoteMarkdown.RoleAt(line.Location, blocks) &&
                    (isStyled?.Invoke(line.Location) ?? true))
                {
                    found.Add(line);
                }

                location = Math.Max(line.End, location + 1);
            }
        }

        foreach (var item in stored)
        {
            Check(item.Range.Intersection(full));
        }

        foreach (var block in blocks)
        {
            Check(block.Range.Intersection(full));
        }

        return Merged(found);
    }

    // ---- 数值（长相在 mac-whisker/notes.md「正文里的 Markdown」）----

    /// <summary>方框那个字（只用来占宽度，方框是自己画的）比正文的字大多少。</summary>
    public const double BoxScale = 1.1;

    /// <summary>标题比正文的字大多少（一到六级；五、六级和正文一样大，只加粗）。</summary>
    public static readonly double[] HeadingScales = { 1.6, 1.4, 1.25, 1.12, 1, 1 };

    /// <summary>行内代码的等宽字比旁边的字小多少（正文 13 → 代码 12）。</summary>
    public const double CodeScale = 0.92;

    /// <summary>斜体斜多少：倾斜，不换字体——中文字体没有斜体字形。</summary>
    public const double Obliqueness = 0.2;

    /// <summary>引用缩进多少、左边那条竖线多宽。</summary>
    public const double QuoteIndent = 14;

    public const double QuoteBarWidth = 3;

    /// <summary>标题上方、下方各留多少（正文一行的行高的几分之几；正文第一行的段前不给）。</summary>
    public const double HeadingBefore = 0.5;

    public const double HeadingAfter = 0.25;

    /// <summary>引用块、代码块整块的上下各留多少（同上）。</summary>
    public const double BlockMargin = 0.25;

    /// <summary>代码块里的字离那块底的左右边多远；那块底比开头、收尾两行再往上下各多出多少；Tab 是几个空格那么宽。</summary>
    public const double CodeInset = 8;

    public const double CodePadding = 3;

    public const int CodeTabWidth = 4;

    /// <summary>Swift 的 .rounded()（四舍五入，.5 远离零）。</summary>
    private static double Rounded(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    /// <summary>level 级标题的字号（整点）。</summary>
    public static double HeadingSize(int level, double baseSize)
        => Rounded(baseSize * HeadingScales[Math.Clamp(level, 1, HeadingScales.Length) - 1]);

    /// <summary>旁边的字是 size 号时行内代码的字号（整点）。</summary>
    public static double CodeSize(double size) => Rounded(size * CodeScale);

    /// <summary>size 号字那一行的行高（整点；mac Theme.lineHeight）。</summary>
    public static double LineHeight(double size, NoteSpacing spacing) => Rounded(size * SpacingValue(spacing));

    // ---- 行距三档（mac 的 Spacing：rawValue compact / standard / relaxed，存在偏好里）----

    public static readonly NoteSpacing[] AllSpacings = { NoteSpacing.Compact, NoteSpacing.Standard, NoteSpacing.Relaxed };

    /// <summary>倍数。标准 1.45：常见的笔记软件大多 1.5，便签的字小一点、略紧。</summary>
    public static double SpacingValue(NoteSpacing spacing) => spacing switch
    {
        NoteSpacing.Compact => 1.2,
        NoteSpacing.Standard => 1.45,
        _ => 1.7,
    };

    /// <summary>存进偏好的名字（同 mac 的 rawValue）。</summary>
    public static string SpacingName(NoteSpacing spacing) => spacing switch
    {
        NoteSpacing.Compact => "compact",
        NoteSpacing.Standard => "standard",
        _ => "relaxed",
    };

    public static NoteSpacing? SpacingFromName(string name) => name switch
    {
        "compact" => NoteSpacing.Compact,
        "standard" => NoteSpacing.Standard,
        "relaxed" => NoteSpacing.Relaxed,
        _ => null,
    };

    public static string SpacingTitle(NoteSpacing spacing) => spacing switch
    {
        NoteSpacing.Compact => "紧凑",
        NoteSpacing.Standard => "标准",
        _ => "宽松",
    };
}
