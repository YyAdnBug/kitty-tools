// 便签正文里的 Markdown（PLAN-v13 第 1 批，照 mac Notes/NoteMarkdown.swift 逐个函数移植，行为一个字不差）：认标记的扫描器。
// 全是纯函数、**不用正则**，一遍从左到右扫完；位置都是 UTF-16 的（同 C# 的 string 下标）。样式怎么叠在 NoteStyles，这里只管「哪一段是什么」。
// 除了代码块，所有语法都不跨行：一行一行扫和整篇扫结果一样（编辑器按行重排靠这一条）；代码块（CodeBlocks）是唯一跨行的，
// 整篇认一遍、每一行拿到自己的角色（开头的围栏 / 块里 / 收尾的围栏），块里的行不再按 Markdown 扫。
// - 块（行首，前面最多 3 个空格）：标题 `#`…`######` 后面跟空白、再后面得有字（只有「# 」的不算）；引用 `>`（单层，后面的
//   一个空格算标记，可以没有内容——那时 `>` 不藏，NoteStyles.Spans）。无序列表的符号、任务的方框由 NoteTasks 认。
// - 行内：行内代码（反引号，几个开就几个关）、粗体 `**` `__`、斜体 `*` `_`、删除线 `~~`、链接 `[字](地址)`、颜色 `[字]{名字}`
//   （red / orange / green / blue / purple / gray，全小写）。代码先认，代码里的 `*` `_` `~` `[` 都不是标记；前面有反斜杠的标点
//   不算标记（反斜杠照常显示）；没配对的原样显示。`*` 可以在词中间，开头的标记后面、结尾的标记前面不能是空白；`_` `__` 两边还得
//   不是字（字母、数字、汉字）——`snake_case_name` 里的下划线不是斜体。**紧挨着的前一个字和后一个字都是 ASCII 数字的一串 `*`
//   不是标记**：`2*3*4`、`箱子 60*40*30` 是乘号。`***又粗又斜***` 两层都认。空的强调凑不出来（`****`、`__` 自己配不了自己）。
// - 链接：方括号可以套、地址里的括号成对就行；地址里不能有空白、字和地址都不能是空的；链接的字里不再认链接。
//   `![…](…)` 是图片，原样显示，里面什么都不认。
// - 颜色：`]` 后面紧跟 `{名字}`，中间不许有空白；方括号里的字不能全是空白、不跨行；`![…]{red}` 不是颜色。颜色里可以有粗体、
//   斜体、删除线、行内代码、链接；**颜色里不套颜色**（里面已经认出颜色的，外面这一对原样显示）。
// - 代码块：行首（前面最多 3 个空格）三个以上的反引号或波浪号开一个块，同一种字符、不少于开头个数、后面只有空白的那一行关；
//   开头那行后面可以跟语言名（只显示）。**只认配上了对的**（CodeBlocks 那里写了为什么）。
// - Plain：把一行里的标记去掉，给标题和摘要用（Note.DisplayTitle / Preview）。
// - 加标记的快捷键（Ctrl+B / I / Shift+X / E，Toggle）、粘贴网址成链接（LinkPaste）、上色（ApplyColor）、块格式（Block）、
//   链接（Link）、清除格式（Clear）、代码块（CodeBlockChange）：纯函数，编辑器只管调；改字的都给 NoteTasks.Change。
// - 颜色 ⇄ `<span style="color: #RRGGBB">`（Html / BodyFromHtml）：导出 / 导入 Markdown 文件、复制成富文本时换，正文里不存这些。
// 和 mac 不一样的名字：color(_:in:selection:) 叫 ApplyColor（和扫描用的 ColorAfter 分开）、codeBlock(in:selection:) 叫 CodeBlockChange、
// codeSpot 叫 CodeSpotOf、fence(count:at:) 叫 FenceOf（C# 里方法不能和同一个类里的类型同名）；url(_:) 给 Uri。
// ponytail: 强调的定界没照 CommonMark，差在这几处——紧挨着的 `*a**b**c*` 按就近配对（它的「3 的倍数」规则没做）；标点旁边的
// `*` 不另算；数字中间的 `*` 一律不算。`__init__` 是粗体（要原样就写进反引号里）。上限：这几种写法和别的 Markdown 工具画出来的
// 不一样；真有人在意，再把 Emphasis 照它的「左 / 右定界」规则重写。
// ponytail: 链接地址最多 AddressLimit 个字（再长的不当链接）——一行里全是「](」的怪文字不至于越扫越慢。没关上的反引号要往后找到
// 行尾：一行里塞满长度各不相同的反引号串时是 n 的 1.5 次方（1 MB 的一行约一秒），真碰上了再记「这么长的串后面没有了」。
using System.Globalization;
using System.Text;
using Kind = KittyTools.Core.Notes.NoteStyles.Kind;
using KindTag = KittyTools.Core.Notes.NoteStyles.KindTag;
using Span = KittyTools.Core.Notes.NoteStyles.Span;

namespace KittyTools.Core.Notes;

public static class NoteMarkdown
{
    /// <summary>链接地址最多这么长（UTF-16）。</summary>
    public const int AddressLimit = 2000;

    /// <summary>空白：空格、Tab、不换行空格、全角空格（中文输入法打出来的）。</summary>
    private static bool IsBlank(char unit) => unit is ' ' or '\t' or '\u00A0' or '\u3000';

    /// <summary>ASCII 标点：反斜杠只转义这些。</summary>
    private static bool IsPunctuation(char unit)
        => unit is (>= '!' and <= '/') or (>= ':' and <= '@') or (>= '[' and <= '`') or (>= '{' and <= '~');

    /// <summary>ASCII 数字：两边都是它的星号是乘号，不算强调。</summary>
    private static bool IsDigit(char? unit) => unit is >= '0' and <= '9';

    /// <summary>是不是「字」（mac CharacterSet.alphanumerics：L*、M*、N* 三类）：下划线两边是字就不算强调。代理项（表情、生僻字）不算字。</summary>
    private static bool IsWord(char? unit)
    {
        if (unit is not { } ch || char.IsSurrogate(ch))
        {
            return false;
        }

        return CharUnicodeInfo.GetUnicodeCategory(ch) switch
        {
            UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or
                UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.NonSpacingMark or
                UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark or
                UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
            _ => false,
        };
    }

    private static int LeadingSpaces(string units)
    {
        var count = 0;
        while (count < units.Length && units[count] == ' ')
        {
            count++;
        }

        return count;
    }

    private static int LeadingSpacesOrTabs(string units)
    {
        var count = 0;
        while (count < units.Length && units[count] is ' ' or '\t')
        {
            count++;
        }

        return count;
    }

    private static bool HasNonBlank(string units, int start, int end)
    {
        for (var index = start; index < end; index++)
        {
            if (!IsBlank(units[index]))
            {
                return true;
            }
        }

        return false;
    }

    private static NoteRange? First(List<NoteRange> ranges, Func<NoteRange, bool> predicate)
    {
        foreach (var range in ranges)
        {
            if (predicate(range))
            {
                return range;
            }
        }

        return null;
    }

    private static List<NoteRange> MarkerRanges(List<Span> spans)
    {
        var found = new List<NoteRange>();
        foreach (var span in spans)
        {
            if (span.Kind.Tag == KindTag.Marker)
            {
                found.Add(span.Range);
            }
        }

        return found;
    }

    // ---- 块 ----

    /// <summary>标题：级别（1–6）和标记的区间（那几个 # 连后面的空白）。不是标题给 null。</summary>
    public static (int Level, NoteRange Marker)? Heading(string line)
    {
        var indent = LeadingSpaces(line);
        var hashes = 0;
        while (indent + hashes < line.Length && line[indent + hashes] == '#')
        {
            hashes++;
        }

        if (indent > 3 || hashes is < 1 or > 6)
        {
            return null;
        }

        var blanks = 0;
        while (indent + hashes + blanks < line.Length && IsBlank(line[indent + hashes + blanks]))
        {
            blanks++;
        }

        // 后面得跟空白（「#标签」不算），再后面得有字
        if (blanks == 0 || indent + hashes + blanks >= line.Length)
        {
            return null;
        }

        return (hashes, new NoteRange(indent, hashes + blanks));
    }

    /// <summary>引用：标记的区间（`>` 连后面的一个空格）。不是引用给 null。</summary>
    public static NoteRange? Quote(string line)
    {
        var indent = LeadingSpaces(line);
        if (indent > 3 || indent >= line.Length || line[indent] != '>')
        {
            return null;
        }

        var hasSpace = indent + 1 < line.Length && IsBlank(line[indent + 1]);
        return new NoteRange(indent, hasSpace ? 2 : 1);
    }

    // ---- 行内 ----

    /// <summary>一串强调标记（`*` `_` `~` 连着的几个）。Start / Count：还没用掉的那一段从哪开始、有几个。</summary>
    private struct Delimiter
    {
        public readonly char Unit;
        public int Start;
        public int Count;
        public readonly bool CanOpen;
        public readonly bool CanClose;

        public Delimiter(char unit, int start, int count, bool canOpen, bool canClose)
        {
            Unit = unit;
            Start = start;
            Count = count;
            CanOpen = canOpen;
            CanClose = canClose;
        }
    }

    /// <summary>还没配上的「[」：Position 是「[」在哪（图片是它前面的「!」后面那个）；SpanCount / DelimiterCount：遇到它的时候
    /// 已经出了几段样式、攒了几串强调标记——配成链接时里面的强调单独配，配成图片时里面的都不要。</summary>
    private readonly record struct Bracket(int Position, bool IsImage, int SpanCount, int DelimiterCount);

    /// <summary>units 里 [lower, upper) 那一段的行内样式：粗体、斜体、删除线、代码、链接、颜色，和各自的标记（Marker）。</summary>
    public static List<Span> Inline(string units, int lower, int upper)
    {
        var spans = new List<Span>();
        var delimiters = new List<Delimiter>();
        var brackets = new List<Bracket>();
        // brackets 里排在这个数前面的「[」已经作废（它们后面配成了链接：链接里不套链接）；图片的不受它管
        var voided = 0;
        var end = upper;
        var index = lower;

        int RunOf(char unit, int start)
        {
            var length = 1;
            while (start + length < end && units[start + length] == unit)
            {
                length++;
            }

            return length;
        }

        static Span MarkerSpan(int location, int length) => new(new NoteRange(location, length), Kind.Marker);

        while (index < end)
        {
            var unit = units[index];
            switch (unit)
            {
                case '\\':
                    // 反斜杠后面的标点不算标记：两个都跳过（都照常显示）
                    index += index + 1 < end && IsPunctuation(units[index + 1]) ? 2 : 1;
                    break;

                case '`':
                {
                    // 行内代码：往后找一串同样长的反引号；找不到就是普通的字
                    var length = RunOf('`', index);
                    var close = index + length;
                    var found = false;
                    while (close < end)
                    {
                        if (units[close] != '`')
                        {
                            close++;
                            continue;
                        }

                        var closing = RunOf('`', close);
                        if (closing == length)
                        {
                            found = true;
                            break;
                        }

                        close += closing;
                    }

                    if (found)
                    {
                        spans.Add(MarkerSpan(index, length));
                        spans.Add(new Span(new NoteRange(index + length, close - index - length), Kind.Code));
                        spans.Add(MarkerSpan(close, length));
                        index = close + length;
                    }
                    else
                    {
                        index += length;
                    }

                    break;
                }

                case '!' when index + 1 < end && units[index + 1] == '[':
                    brackets.Add(new Bracket(index + 1, true, spans.Count, delimiters.Count));
                    index += 2;
                    break;

                case '[':
                    brackets.Add(new Bracket(index, false, spans.Count, delimiters.Count));
                    index++;
                    break;

                case ']':
                {
                    if (brackets.Count == 0)
                    {
                        index++;
                        break;
                    }

                    var bracket = brackets[^1];
                    brackets.RemoveAt(brackets.Count - 1);
                    var isVoid = !bracket.IsImage && brackets.Count < voided;
                    voided = Math.Min(voided, brackets.Count);
                    var textStart = bracket.Position + 1;
                    var textEnd = index;
                    // 颜色：`]` 后面紧跟着 `{名字}`。图片的方括号不是颜色；方括号里的字不能全是空白；颜色里不套颜色
                    // （里面已经认出颜色的，外面这一对不算、原样显示）。配成颜色不看 voided（那是「链接里不套链接」）
                    if (!bracket.IsImage && ColorAfter(index, units, end) is { } tint &&
                        HasNonBlank(units, textStart, textEnd) && !HasColor(spans, bracket.SpanCount))
                    {
                        // 颜色里的强调自己配，不和外面的配；颜色套在它们外面
                        spans.AddRange(Emphasis(delimiters.GetRange(bracket.DelimiterCount, delimiters.Count - bracket.DelimiterCount)));
                        delimiters.RemoveRange(bracket.DelimiterCount, delimiters.Count - bracket.DelimiterCount);
                        spans.Add(MarkerSpan(bracket.Position, 1));
                        spans.Add(new Span(NoteRange.Of(textStart, textEnd), Kind.Color(tint.Color)));
                        spans.Add(MarkerSpan(index, tint.Length));
                        index = tint.End;
                        break;
                    }

                    if (isVoid || Address(units, index, end) is not { } address || !HasNonBlank(units, textStart, textEnd))
                    {
                        index++;
                        break;
                    }

                    if (bracket.IsImage)
                    {
                        // 图片：原样显示，里面认出来的都不要
                        spans.RemoveRange(bracket.SpanCount, spans.Count - bracket.SpanCount);
                        delimiters.RemoveRange(bracket.DelimiterCount, delimiters.Count - bracket.DelimiterCount);
                    }
                    else
                    {
                        // 链接的字里的强调自己配，不和外面的配
                        spans.AddRange(Emphasis(delimiters.GetRange(bracket.DelimiterCount, delimiters.Count - bracket.DelimiterCount)));
                        delimiters.RemoveRange(bracket.DelimiterCount, delimiters.Count - bracket.DelimiterCount);
                        spans.Add(MarkerSpan(bracket.Position, 1));
                        spans.Add(new Span(NoteRange.Of(textStart, textEnd),
                            Kind.Link(units.Substring(address.Start, address.End - address.Start))));
                        // 「](地址)」
                        spans.Add(MarkerSpan(index, address.End + 1 - index));
                        // 链接里不套链接：前面还开着的「[」作废（图片的留着：图片的说明里可以有链接的写法）
                        voided = brackets.Count;
                    }

                    index = address.End + 1;
                    break;
                }

                case '*' or '_' or '~':
                {
                    var length = RunOf(unit, index);
                    var before = index > lower ? units[index - 1] : (char?)null;
                    var after = index + length < end ? units[index + length] : (char?)null;
                    // 开头的标记后面不能是空白，结尾的标记前面不能是空白；下划线两边还得不是字
                    var canOpen = after is { } next && !IsBlank(next);
                    var canClose = before is { } previous && !IsBlank(previous);
                    if (unit == '_')
                    {
                        canOpen = canOpen && !IsWord(before);
                        canClose = canClose && !IsWord(after);
                    }

                    // 两边都是数字的一串星号是乘号（2*3*4、60*40*30）：既不开也不关
                    var isTimes = unit == '*' && IsDigit(before) && IsDigit(after);
                    // 删除线只认正好两个波浪号
                    if (!isTimes && (unit != '~' || length == 2))
                    {
                        delimiters.Add(new Delimiter(unit, index, length, canOpen, canClose));
                    }

                    index += length;
                    break;
                }

                default:
                    index++;
                    break;
            }
        }

        spans.AddRange(Emphasis(delimiters));
        return spans;
    }

    private static bool HasColor(List<Span> spans, int from)
    {
        for (var index = from; index < spans.Count; index++)
        {
            if (spans[index].Kind.Tag == KindTag.Color)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>「]」后面是不是紧跟着「(地址)」：给地址的区间（不含括号，End 是收尾的「)」的位置）。地址里不能有空白，括号要成对，不能是空的。</summary>
    private static (int Start, int End)? Address(string units, int close, int end)
    {
        if (close + 1 >= end || units[close + 1] != '(')
        {
            return null;
        }

        var start = close + 2;
        var depth = 0;
        var index = start;
        // 地址最长 AddressLimit：收尾的「)」最远在 start + AddressLimit
        var limit = Math.Min(end, start + AddressLimit + 1);
        while (index < limit)
        {
            var unit = units[index];
            if (IsBlank(unit))
            {
                return null;
            }

            if (unit == '\\' && index + 1 < end && IsPunctuation(units[index + 1]))
            {
                index += 2;
                continue;
            }

            if (unit == '(')
            {
                depth++;
            }
            else if (unit == ')')
            {
                if (depth == 0)
                {
                    if (index > start)
                    {
                        return (start, index);
                    }

                    return null;
                }

                depth--;
            }

            index++;
        }

        return null;
    }

    /// <summary>`]` 后面紧跟着 `{名字}`：给颜色、`{名字}` 到哪结束（End 是 `}` 后面的位置）、标记多长（`]{名字}`）。
    /// 名字只认全小写的 6 个，中间不许有空白。</summary>
    public static (NoteColor Color, int End, int Length)? ColorAfter(int close, string units, int end)
    {
        if (close + 2 >= end || units[close + 1] != '{')
        {
            return null;
        }

        var index = close + 2;
        while (index < end && units[index] != '}')
        {
            // 名字里只可能是 a–z，碰到别的就不认（也不往后找第二个 }）
            if (units[index] is < 'a' or > 'z')
            {
                return null;
            }

            index++;
        }

        if (index >= end || index <= close + 2)
        {
            return null;
        }

        if (NoteColors.Named(units.Substring(close + 2, index - close - 2)) is not { } color)
        {
            return null;
        }

        return (color, index + 1, index + 1 - close);
    }

    /// <summary>一段颜色：中间那一段字（Range）、它两头的标记（Open 是 `[`，Close 是 `]{名字}`）。</summary>
    public readonly record struct ColorRun(NoteColor Color, NoteRange Range, NoteRange Open, NoteRange Close);

    /// <summary>一行里认出颜色的那几段（按 Inline 的结果）：每段连它两头的标记是哪几个区间。颜色不套颜色，所以每段的两头紧挨着的
    /// 那些标记就是它自己的。标记按位置查字典（一行上几千段颜色时，每段都把全部标记过一遍是平方的）。</summary>
    public static List<ColorRun> ColorRuns(IReadOnlyList<Span> spans)
    {
        var byStart = new Dictionary<int, NoteRange>();
        var byEnd = new Dictionary<int, NoteRange>();
        foreach (var span in spans)
        {
            if (span.Kind.Tag == KindTag.Marker)
            {
                byStart[span.Range.Location] = span.Range;
                byEnd[span.Range.End] = span.Range;
            }
        }

        var found = new List<ColorRun>();
        foreach (var span in spans)
        {
            if (span.Kind.Tag != KindTag.Color)
            {
                continue;
            }

            var color = span.Kind.Ink;
            if (!byEnd.TryGetValue(span.Range.Location, out var open) || open.Length != 1 ||
                !byStart.TryGetValue(span.Range.End, out var close) || close.Length != 3 + NoteColors.Name(color).Length)
            {
                continue;
            }

            found.Add(new ColorRun(color, span.Range, open, close));
        }

        return found;
    }

    /// <summary>一行里只有颜色和它的标记（设置里 Markdown 关着时用：颜色不看这个开关，别的 Markdown 照旧原样显示）。
    /// 没有 `]{` 的行不用扫。</summary>
    public static List<Span> ColorOnlySpans(string line)
    {
        if (!line.Contains("]{", StringComparison.Ordinal))
        {
            return new List<Span>();
        }

        var spans = Inline(line, 0, line.Length);
        var markers = new HashSet<NoteRange>();
        foreach (var run in ColorRuns(spans))
        {
            markers.Add(run.Open);
            markers.Add(run.Close);
        }

        return spans.Where(span => span.Kind.Tag == KindTag.Color ||
                                   (span.Kind.Tag == KindTag.Marker && markers.Contains(span.Range))).ToList();
    }

    private static int Slot(char unit) => unit switch
    {
        '*' => 0,
        '_' => 1,
        _ => 2,
    };

    /// <summary>把一串串强调标记配成对（从左到右，结尾的标记找离它最近的、同一种字符的开头）：两边都还有两个以上就是粗体
    /// （用掉两个），否则是斜体（用掉一个）；`~~` 是删除线。配上的一对中间夹着的开头标记作废（样式不交叉）。</summary>
    private static List<Span> Emphasis(List<Delimiter> delimiters)
    {
        var runs = delimiters.ToArray();
        var spans = new List<Span>();
        // 三种字符各一摞还开着的开头标记（存的是 runs 的下标）
        var openers = new[] { new List<int>(), new List<int>(), new List<int>() };
        for (var current = 0; current < runs.Length; current++)
        {
            var unit = runs[current].Unit;
            var stack = openers[Slot(unit)];
            if (runs[current].CanClose)
            {
                while (runs[current].Count > 0 && stack.Count > 0)
                {
                    var opener = stack[^1];
                    var use = unit == '~' || Math.Min(runs[opener].Count, runs[current].Count) >= 2 ? 2 : 1;
                    // 开头那一串从里面（靠内容的一头）用起，结尾那一串从前面用起
                    var open = runs[opener].Start + runs[opener].Count - use;
                    var close = runs[current].Start;
                    var kind = unit == '~' ? Kind.Strike : use == 2 ? Kind.Bold : Kind.Italic;
                    spans.Add(new Span(new NoteRange(open, use), Kind.Marker));
                    spans.Add(new Span(new NoteRange(open + use, close - open - use), kind));
                    spans.Add(new Span(new NoteRange(close, use), Kind.Marker));
                    runs[opener].Count -= use;
                    runs[current].Start += use;
                    runs[current].Count -= use;
                    foreach (var list in openers)
                    {
                        while (list.Count > 0 && list[^1] > opener)
                        {
                            list.RemoveAt(list.Count - 1);
                        }
                    }

                    if (runs[opener].Count == 0)
                    {
                        stack.RemoveAt(stack.Count - 1);
                    }
                }
            }

            if (runs[current].CanOpen && runs[current].Count > 0)
            {
                stack.Add(current);
            }
        }

        return spans;
    }

    // ---- 代码块 ----

    /// <summary>围栏行：行首（前面最多 3 个空格）三个以上同一种的反引号或波浪号。Count 是几个，IsBare = 后面只有空白
    /// （能当收尾的那一行；开头那行后面可以跟语言名，只显示）。</summary>
    public readonly record struct Fence(char Mark, int Count, bool IsBare);

    /// <summary>代码块里一行的角色。</summary>
    public enum Role
    {
        /// <summary>开头的围栏行。</summary>
        Open = 1,

        /// <summary>块里的行。</summary>
        Content,

        /// <summary>收尾的围栏行。</summary>
        Close,
    }

    /// <summary>一个配上了对的代码块：开头、收尾那两行（整行，连行尾的换行）。</summary>
    public readonly record struct CodeBlock(NoteRange Open, NoteRange Close)
    {
        /// <summary>整块：开头那行的行首到收尾那行的行尾（连换行）。</summary>
        public NoteRange Range => new(Open.Location, Close.End - Open.Location);

        /// <summary>行首在 lineStart 的那一行在这一块里是什么（不在这一块里给 null）。开头的围栏是空的（长度 0：便签墙的卡片只带
        /// 正文的一段，块的开头被截在这一段前面）时没有开头那一行，这一段的第一行是块里的字。</summary>
        public Role? RoleOf(int lineStart)
        {
            if (!Range.Contains(lineStart))
            {
                return null;
            }

            if (lineStart == Open.Location && Open.Length > 0)
            {
                return Role.Open;
            }

            return lineStart == Close.Location ? Role.Close : Role.Content;
        }
    }

    /// <summary>这一行（不含行尾的换行）是不是围栏行。反引号的围栏后面不能再有反引号（「```a```」是一行里的行内代码）。</summary>
    public static Fence? FenceOf(string line) => FenceAt(line, 0, line.Length);

    /// <summary>text 里从 start 起、count 个字的那一行（整篇扫的时候不为每一行取子串）。</summary>
    private static Fence? FenceAt(string text, int start, int count)
    {
        var index = 0;
        while (index < count && index < 4 && text[start + index] == ' ')
        {
            index++;
        }

        if (index > 3 || index >= count)
        {
            return null;
        }

        var mark = text[start + index];
        if (mark != '`' && mark != '~')
        {
            return null;
        }

        var run = 0;
        while (index + run < count && text[start + index + run] == mark)
        {
            run++;
        }

        if (run < 3)
        {
            return null;
        }

        var isBare = true;
        for (var position = index + run; position < count; position++)
        {
            var current = text[start + position];
            if (mark == '`' && current == '`')
            {
                return null;
            }

            if (!IsBlank(current))
            {
                isBare = false;
                if (mark == '~')
                {
                    break;
                }
            }
        }

        return new Fence(mark, run, isBare);
    }

    /// <summary>正文里的代码块（从前到后）。**只认配上了对的**：开头的围栏往后找第一行「同一种字符、不少于开头个数、后面只有空白」
    /// 的围栏收尾，中间夹着的都是块里的字（别的围栏也是）；找不到收尾的那一行不是开头、照普通的一行显示，接着往下找。
    /// （CommonMark 是没关上就一直到正文末尾——边打边变样时，刚打出开头的三个反引号，后面整篇就突然都成了代码。）
    /// ponytail: 找收尾是在同一种字符的「能收尾的围栏」里往后走、跳过个数不够的；找不到时记下「这种字符、不少于几个」再往后都不会有，
    /// 后面同样或更多的开头直接跳过。上限：开头的个数一路递减（1000、999…个反引号的开头一行行往下排）时每一行都要走一遍——
    /// 几十万个反引号才碰得到，真碰上再改成按个数分桶。</summary>
    public static IReadOnlyList<CodeBlock> CodeBlocks(string text)
    {
        var fences = new List<(NoteRange Line, Fence Fence)>();
        var location = 0;
        while (location < text.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(text, location);
            // 先看行首几个字：绝大多数行到这里就不是了，不取整行
            if (FenceAt(text, start, contentsEnd - start) is { } found)
            {
                fences.Add((NoteRange.Of(start, end), found));
            }

            location = Math.Max(end, location + 1);
        }

        // 每种字符能当收尾的围栏（fences 里的下标，从前到后）
        var closers = new Dictionary<char, List<int>>();
        for (var index = 0; index < fences.Count; index++)
        {
            if (!fences[index].Fence.IsBare)
            {
                continue;
            }

            if (!closers.TryGetValue(fences[index].Fence.Mark, out var list))
            {
                list = new List<int>();
                closers[fences[index].Fence.Mark] = list;
            }

            list.Add(index);
        }

        // 某种字符「不少于几个」的收尾在后面已经找不到了
        var hopeless = new Dictionary<char, int>();
        var blocks = new List<CodeBlock>();
        var at = 0;
        while (at < fences.Count)
        {
            var opener = fences[at].Fence;
            if ((hopeless.TryGetValue(opener.Mark, out var limit) && opener.Count >= limit) ||
                !closers.TryGetValue(opener.Mark, out var candidates))
            {
                at++;
                continue;
            }

            // 排在开头后面的第一个
            var (low, high) = (0, candidates.Count);
            while (low < high)
            {
                var middle = (low + high) / 2;
                if (candidates[middle] <= at)
                {
                    low = middle + 1;
                }
                else
                {
                    high = middle;
                }
            }

            var close = -1;
            for (var index = low; index < candidates.Count; index++)
            {
                if (fences[candidates[index]].Fence.Count >= opener.Count)
                {
                    close = candidates[index];
                    break;
                }
            }

            if (close < 0)
            {
                hopeless[opener.Mark] = opener.Count;
                at++;
                continue;
            }

            blocks.Add(new CodeBlock(fences[at].Line, fences[close].Line));
            at = close + 1;
        }

        return blocks;
    }

    /// <summary>行首在 lineStart 的那一行在不在代码块里、是什么角色（blocks 从前到后排好）。</summary>
    public static Role? RoleAt(int lineStart, IReadOnlyList<CodeBlock> blocks)
    {
        var (low, high) = (0, blocks.Count);
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (blocks[middle].Range.End <= lineStart)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }

        return low < blocks.Count ? blocks[low].RoleOf(lineStart) : null;
    }

    // ---- 加标记的快捷键（Ctrl+B / Ctrl+I / Ctrl+Shift+X / Ctrl+E）----

    /// <summary>四种：粗体、斜体、删除线、行内代码。</summary>
    public enum Wrap
    {
        Bold,
        Italic,
        Strike,
        Code,
    }

    public static readonly Wrap[] AllWraps = { Wrap.Bold, Wrap.Italic, Wrap.Strike, Wrap.Code };

    /// <summary>两头各加的那一串。</summary>
    public static string Marker(Wrap wrap) => wrap switch
    {
        Wrap.Bold => "**",
        Wrap.Italic => "*",
        Wrap.Strike => "~~",
        _ => "`",
    };

    /// <summary>右键菜单「格式」里的名字。</summary>
    public static string Title(Wrap wrap) => wrap switch
    {
        Wrap.Bold => "粗体",
        Wrap.Italic => "斜体",
        Wrap.Strike => "删除线",
        _ => "代码",
    };

    /// <summary>扫描器认出来的这种样式（「已经包着」问的是它）。</summary>
    public static Kind KindOf(Wrap wrap) => wrap switch
    {
        Wrap.Bold => Kind.Bold,
        Wrap.Italic => Kind.Italic,
        Wrap.Strike => Kind.Strike,
        _ => Kind.Code,
    };

    /// <summary>两头的标记用几个字（斜体、代码是 1，粗体、删除线是 2）。</summary>
    public static int MarkerLength(Wrap wrap) => wrap is Wrap.Bold or Wrap.Strike ? 2 : 1;

    /// <summary>Shapes 里这种样式占的那一位（重建之后照它比对）。</summary>
    public static int Flag(Wrap wrap) => wrap switch
    {
        Wrap.Bold => 0x0080,
        Wrap.Italic => 0x0100,
        Wrap.Strike => 0x0200,
        _ => 0x0400,
    };

    /// <summary>一行开头的块标记（标题的 #、引用的 >、列表的符号和任务的方框，连后面的空白）到哪为止：加标记从这后面算起。</summary>
    public static int ContentStart(string units)
    {
        if (NoteTasks.PrefixOf(units) is { } prefix)
        {
            return prefix.ContentStart;
        }

        if (Heading(units) is { } heading)
        {
            return heading.Marker.End;
        }

        if (Quote(units) is { } quote)
        {
            return quote.End;
        }

        return 0;
    }

    /// <summary>Ctrl+B 这几个键：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头。
    /// - 没有选区：在光标处插一对标记、光标放中间；光标正夹在一对空的标记中间时（刚按过一次、还没打字）把这对删掉。
    /// - 有选区、粗体 / 斜体 / 删除线整段一种：选区里能加这种格式的字（看得见、去掉空白、不在代码 / 图片里）不是全都是这种格式就都加上
    ///   （原来有的那几段并进来、中间的标记不留），都是就去掉（选区外的照旧，会拆开）；每一行各自重建。
    /// - 有选区、行内代码：每一行各自包 / 去掉。
    /// 「已经包着」不数字符、问扫描器；重建出来扫描器认不出的（两头紧挨着数字）挡住、给 null。都是空白、没有可包的给 null。</summary>
    public static NoteTasks.Change? Toggle(Wrap wrap, string block, NoteRange selection)
        => wrap != Wrap.Code && selection.Length > 0
            ? ToggleFormat(wrap, block, selection)
            : ToggleSingle(wrap, block, selection);

    /// <summary>老的四样加标记：没有选区时插一对、删掉空的一对；有选区时每一行各自包——包的是选区在这一行里的那一段，去掉两头的空白、
    /// 跳过行首的块标记、去掉选进来的这种标记；这一段已经是这种样式的就去掉它两头的标记；几段里有一段还没包，就把没包的都包上，
    /// 都包着才都去掉（同 Ctrl+T）。改完选中的是里面的字（不含标记）。</summary>
    private static NoteTasks.Change? ToggleSingle(Wrap wrap, string block, NoteRange selection)
    {
        var units = block;
        var marker = Marker(wrap);
        var size = marker.Length;
        var mark = marker[0];
        var kind = KindOf(wrap);

        // [position, limit) 里从 position 往后连着几个 mark
        int RunFrom(int position, int limit)
        {
            var count = 0;
            while (position + count < limit && units[position + count] == mark)
            {
                count++;
            }

            return count;
        }

        // position 往前、不越过 limit 连着几个 mark
        int RunBefore(int position, int limit)
        {
            var count = 0;
            while (position - count > limit && units[position - count - 1] == mark)
            {
                count++;
            }

            return count;
        }

        // 第 location 个字所在的行：内容从哪开始（跳过块标记）、到哪为止
        (int Content, int End) LineAt(int at)
        {
            var (start, _, contentsEnd) = NoteText.Line(units, at);
            return (start + ContentStart(units[start..contentsEnd]), contentsEnd);
        }

        bool Fits(NoteRange range) => wrap == Wrap.Code || range.Length == size;

        // 扫描器在这一行里认出来的这种样式里，有没有一段正好是 inner：内容去掉两头紧挨着的别的标记（又粗又斜的 `***粗***`
        // 里斜体的内容是「**粗**」）之后就是 inner。有就给它两头的那一对标记（要去掉的就是它们），没有给 null
        (NoteRange Open, NoteRange Close)? Wrapping(NoteRange inner, List<Span> spans)
        {
            var markers = MarkerRanges(spans);
            foreach (var span in spans)
            {
                if (span.Kind != kind)
                {
                    continue;
                }

                var core = span.Range;
                while (First(markers, m => m.Location == core.Location && m.Length <= core.Length) is { } head)
                {
                    core = new NoteRange(head.End, core.Length - head.Length);
                }

                while (First(markers, m => m.End == core.End && m.Length <= core.Length) is { } tail)
                {
                    core = new NoteRange(core.Location, core.Length - tail.Length);
                }

                // 这一对：紧挨着这一段的两头（强调的标记长度就是加的那一串，代码的是几个反引号）
                if (core != inner)
                {
                    continue;
                }

                var range = span.Range;
                if (First(markers, m => m.End == range.Location && Fits(m)) is not { } open ||
                    First(markers, m => m.Location == range.End && Fits(m)) is not { } close)
                {
                    continue;
                }

                return (open, close);
            }

            return null;
        }

        if (selection.Length == 0)
        {
            var bounds = LineAt(selection.Location);
            var caret = Math.Min(Math.Max(selection.Location, bounds.Content), bounds.End);
            // 光标正夹在一对空的这种标记中间（刚按过一次、还没打字）：在光标处放一个字、用扫描器认一遍——认得出这个字正好是
            // 这种样式、两头紧挨着的就是这一对，才是（`**a**|**b**` 中间的两对各归各的，不是）
            var probe = units[..caret] + "a" + units[caret..];
            if (Wrapping(new NoteRange(caret, 1), Inline(probe, bounds.Content, bounds.End + 1)) is { } pair &&
                pair.Open == new NoteRange(caret - size, size) && pair.Close == new NoteRange(caret + 1, size))
            {
                // 一对空的标记：删掉
                return new NoteTasks.Change(
                    new[]
                    {
                        new NoteTasks.Replacement(new NoteRange(caret - size, size), string.Empty),
                        new NoteTasks.Replacement(new NoteRange(caret, size), string.Empty),
                    },
                    new NoteRange(caret - size, 0));
            }

            return new NoteTasks.Change(
                new[] { new NoteTasks.Replacement(new NoteRange(caret, 0), marker + marker) },
                new NoteRange(caret + size, 0));
        }

        // 每一行里选中的那一段（去掉两头的空白、跳过块标记）：去掉选进来的这种标记之后的字（Start..End），和它是不是已经包着
        // （Wrapped：要去掉的那一对标记；null = 还没包）。标记一半在选区里、一半在外面也认
        var segments = new List<(int Start, int End, (NoteRange Open, NoteRange Close)? Wrapped)>();
        var location = selection.Location;
        var selectionEnd = selection.End;
        do
        {
            var bounds = LineAt(location);
            var start = Math.Max(location, bounds.Content);
            var end = Math.Min(selectionEnd, bounds.End);
            while (start < end && IsBlank(units[start]))
            {
                start++;
            }

            while (end > start && IsBlank(units[end - 1]))
            {
                end--;
            }

            var leading = RunFrom(start, end);
            var trailing = RunBefore(end, start + leading);
            if (end - trailing > start + leading)
            {
                var inner = NoteRange.Of(start + leading, end - trailing);
                segments.Add((inner.Location, inner.End, Wrapping(inner, Inline(units, bounds.Content, bounds.End))));
            }

            // 下一行（行尾的换行后面）
            var next = NoteText.Line(units, location).End;
            location = Math.Max(next, location + 1);
        }
        while (location < selectionEnd);

        if (segments.Count == 0)
        {
            return null;
        }

        var unwraps = segments.All(segment => segment.Wrapped is not null);
        var replacements = new List<NoteTasks.Replacement>();
        // 前面的改动让后面的位置挪了多少；里面的字改完在哪
        var delta = 0;
        var moved = new List<(int Start, int End)>();
        foreach (var segment in segments)
        {
            if (unwraps && segment.Wrapped is { } pair)
            {
                // 去掉这种样式的那一对（又粗又斜里去掉斜体：去的是最外面那两个星号）
                replacements.Add(new NoteTasks.Replacement(pair.Open, string.Empty));
                delta -= pair.Open.Length;
                moved.Add((segment.Start + delta, segment.End + delta));
                replacements.Add(new NoteTasks.Replacement(pair.Close, string.Empty));
                delta -= pair.Close.Length;
            }
            else if (segment.Wrapped is null)
            {
                replacements.Add(new NoteTasks.Replacement(new NoteRange(segment.Start, 0), marker));
                delta += size;
                moved.Add((segment.Start + delta, segment.End + delta));
                replacements.Add(new NoteTasks.Replacement(new NoteRange(segment.End, 0), marker));
                delta += size;
            }
            else
            {
                // 有别的段还没包：已经包着的这段不动
                moved.Add((segment.Start + delta, segment.End + delta));
            }
        }

        var first = moved[0].Start;
        return new NoteTasks.Change(replacements, new NoteRange(first, moved[^1].End - first));
    }

    // ---- 粘贴网址成链接 ----

    /// <summary>选中一段字、剪贴板里是一个能打开的网址时，粘贴成链接：line 是选区所在的那一行（不含行尾的换行），selection 相对
    /// 它的开头，pasted 是剪贴板里的字（两头的空白、换行去掉；中间有空白——几个网址、一段话——就不是）。给的是改动：选中的字换成
    /// 「[字](网址)」、光标放在后面；不该这么粘的给 null（照常粘贴）。拼出来之后还要用同一个扫描器认得出「这一段是链接、地址就是它」
    /// 才算——选中的字在行内代码里、带着方括号、地址里括号不成对，拼出来就不是链接了。</summary>
    public static NoteTasks.Change? LinkPaste(string pasted, string line, NoteRange selection)
    {
        var address = NoteText.TrimSpacesAndNewlines(pasted);
        if (selection.Length <= 0 || selection.End > line.Length || address.Length == 0 ||
            address.Any(NoteText.IsSpaceOrNewline) || Url(address) is null)
        {
            return null;
        }

        var selected = line.Substring(selection.Location, selection.Length);
        if (selected.All(NoteText.IsSpace))
        {
            return null;
        }

        var link = $"[{selected}]({address})";
        var rebuilt = line[..selection.Location] + link + line[selection.End..];
        var text = new NoteRange(selection.Location + 1, selection.Length);
        var wanted = Kind.Link(address);
        if (!Inline(rebuilt, ContentStart(rebuilt), rebuilt.Length).Any(span => span.Range == text && span.Kind == wanted))
        {
            return null;
        }

        return new NoteTasks.Change(
            new[] { new NoteTasks.Replacement(selection, link) },
            new NoteRange(selection.Location + link.Length, 0));
    }

    // ---- 上色 ----

    /// <summary>右键「文字颜色」：给 block 里选区碰到的那几行上色（null = 默认颜色、去掉颜色）。每一行各自处理：选中的那一段去掉两头的
    /// 空白、跳过行首的块标记；把「能上色的字」（不是标记、不在行内代码里、不是图片）设成新颜色；再把这一行所有的颜色标记去掉，按
    /// 「连着的、能上色的、同一种颜色」的一串串重新加 `[` `]{名字}`（一串碰到不能上色的字就断开，所以颜色永远在最里层）。
    /// 拼好之后用同一个扫描器认一遍：每个字除了颜色以外的样子都和原来一样、颜色都是想要的，才算；不然给 null（响一声）。
    /// 替换只动这一行里变了的那几段；改完选区盖着原来选中的那些字（不含标记）。</summary>
    public static NoteTasks.Change? ApplyColor(NoteColor? color, string block, NoteRange selection)
    {
        if (selection.Length <= 0)
        {
            return null;
        }

        var replacements = new List<NoteTasks.Replacement>();
        var (first, last) = (int.MaxValue, 0);
        var location = 0;
        while (location < block.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(block, location);
            var line = block[start..contentsEnd];
            var selStart = Math.Max(selection.Location, start);
            var selEnd = Math.Min(selection.End, start + line.Length);
            if (selEnd > selStart && Recolor(line, selStart - start, selEnd - start, color) is { } lineChange)
            {
                foreach (var replacement in lineChange.Replacements)
                {
                    replacements.Add(new NoteTasks.Replacement(
                        new NoteRange(replacement.Range.Location + start, replacement.Range.Length), replacement.Text));
                }

                first = Math.Min(first, start + lineChange.Selection.Location);
                last = Math.Max(last, start + lineChange.Selection.End);
            }

            location = Math.Max(end, location + 1);
        }

        if (first == int.MaxValue || last < first)
        {
            return null;
        }

        var mappedStart = NoteTasks.MappedPosition(first, replacements, staysBeforeInsertion: false);
        var mappedEnd = NoteTasks.MappedPosition(last, replacements, staysBeforeInsertion: true);
        return new NoteTasks.Change(replacements, new NoteRange(mappedStart, mappedEnd - mappedStart));
    }

    // ---- 格式合并（粗体、斜体、删除线整段一种）----

    /// <summary>一行扫一遍的结果（重建强调、上色、清除格式共用）。Flags：每个字除颜色以外的样子（见 Shapes）；Links：每个字的链接地址；
    /// Visible / Shown：看得见的字在这一行里的位置、和字本身；Hidden：标记字符；Blocked：不能加格式的字（别的标记、行内代码、图片）。</summary>
    private sealed record Scanned(
        int[] Flags,
        string?[] Links,
        int[] Visible,
        string Shown,
        bool[] Hidden,
        bool[] Blocked);

    /// <summary>扫这一行。transparent：这些标记区间不算「不能加格式」（它们反正要删掉，一串可以跨过去）。</summary>
    private static Scanned Scan(string units, HashSet<NoteRange>? transparent = null)
    {
        var count = units.Length;
        var content = ContentStart(units);
        var spans = Inline(units, content, count);
        var shapes = Shapes(units, spans);
        var shown = Visible(units, spans);
        var hidden = new bool[count];
        var blocked = new bool[count];

        void Fill(NoteRange range)
        {
            for (var index = range.Location; index < range.End && index < count; index++)
            {
                blocked[index] = true;
            }
        }

        foreach (var span in spans)
        {
            switch (span.Kind.Tag)
            {
                case KindTag.Marker:
                    for (var index = span.Range.Location; index < span.Range.End && index < count; index++)
                    {
                        hidden[index] = true;
                    }

                    if (transparent is null || !transparent.Contains(span.Range))
                    {
                        Fill(span.Range);
                    }

                    break;
                case KindTag.Code:
                    Fill(span.Range);
                    break;
            }
        }

        for (var index = 0; index < count; index++)
        {
            if (units[index] == '\uFFFC')
            {
                blocked[index] = true;
            }
        }

        foreach (var match in NoteImages.Matches(units))
        {
            Fill(match.Range);
        }

        return new Scanned(shapes.Flags, shapes.Links, shown.Indices, shown.Units, hidden, blocked);
    }

    /// <summary>这一段文字拆成一行行的（和 NoteTasks 里那份一样的拆法：最后一行没有换行时也有一行，以换行结尾时后面的空行也算）。</summary>
    private static List<(int Start, string Units)> Rows(string block)
    {
        var rows = new List<(int Start, string Units)>();
        var location = 0;
        do
        {
            var (start, end, contentsEnd) = NoteText.Line(block, location);
            rows.Add((start, block[start..contentsEnd]));
            if (end == block.Length && contentsEnd < end)
            {
                rows.Add((end, string.Empty));
            }

            location = end;
        }
        while (location < block.Length);

        return rows;
    }

    /// <summary>一行里这种样式两头的标记（`***粗***` 里粗体那一对是里面两个星号）。</summary>
    private static List<NoteRange> MarkersOf(Wrap wrap, List<Span> spans)
    {
        var found = new List<NoteRange>();
        if (wrap == Wrap.Code)
        {
            return found;
        }

        var all = MarkerRanges(spans);
        var kind = KindOf(wrap);
        var length = MarkerLength(wrap);
        foreach (var span in spans)
        {
            if (span.Kind != kind)
            {
                continue;
            }

            var range = span.Range;
            if (First(all, m => m.End == range.Location && m.Length == length) is not { } open ||
                First(all, m => m.Location == range.End && m.Length == length) is not { } close)
            {
                continue;
            }

            found.Add(open);
            found.Add(close);
        }

        return found.OrderBy(r => r.Location).ToList();
    }

    /// <summary>选区里能加这种格式的字（看得见、不是空白、不在代码 / 图片里）是不是全都是这种格式；没有这种字给 null。
    /// 菜单打勾和 Ctrl+B 的「全都是」都用它（不数字符，问扫描器）。</summary>
    public static bool? IsFormatted(Wrap wrap, string block, NoteRange selection)
    {
        if (selection.Length <= 0)
        {
            return null;
        }

        var flag = Flag(wrap);
        var found = false;
        foreach (var row in Rows(block))
        {
            var lineEnd = row.Start + row.Units.Length;
            var lower = Math.Max(selection.Location, row.Start);
            var upper = Math.Min(selection.End, lineEnd);
            if (upper <= lower)
            {
                continue;
            }

            var analyzed = Scan(row.Units);
            for (var index = lower - row.Start; index < upper - row.Start; index++)
            {
                if (analyzed.Hidden[index] || analyzed.Blocked[index] || IsBlank(row.Units[index]))
                {
                    continue;
                }

                found = true;
                if ((analyzed.Flags[index] & flag) == 0)
                {
                    return false;
                }
            }
        }

        return found ? true : (bool?)null;
    }

    /// <summary>一行重建的结果：改了什么（本来就是这样时没有）、选区在这一行里盖着哪一段（没有能加的字时都没有）。</summary>
    private readonly record struct LineOutcome(IReadOnlyList<NoteTasks.Replacement>? Replacements, int? First, int? Last);

    /// <summary>一行里选中的那一段重建这种格式：算出每个看得见的字要不要 → 去掉这一行这种格式的全部标记 → 按连着的、要这种格式的字
    /// 一串串重新加（两头不能是空白，别的标记 / 代码 / 图片断开，这种格式自己的旧标记跨过去）→ 用扫描器认一遍。认不对给 null。</summary>
    private static LineOutcome? FormatLine(Wrap wrap, string units, int sectionLower, int sectionUpper, bool want)
    {
        var count = units.Length;
        var content = ContentStart(units);
        var start = Math.Max(sectionLower, content);
        var end = Math.Min(sectionUpper, count);
        while (start < end && IsBlank(units[start]))
        {
            start++;
        }

        while (end > start && IsBlank(units[end - 1]))
        {
            end--;
        }

        if (start >= end)
        {
            return new LineOutcome(null, null, null);
        }

        var spans = Inline(units, content, count);
        // 只去掉扫描器认出来的这种格式的标记。没配上的 `*` `**` `~~`（数字中间的乘号 `60*40*30`、路径里的 `src/**/a`、单独打的 `~~`）
        // 是用户打的字，原样留着、跟着一起加格式——当成标记删掉就把用户的字删了
        var deletions = MarkersOf(wrap, spans);
        var analyzed = Scan(units, new HashSet<NoteRange>(deletions));
        var oldMarker = new bool[count];
        foreach (var range in deletions)
        {
            for (var index = range.Location; index < range.End && index < count; index++)
            {
                oldMarker[index] = true;
            }
        }

        // 选区里能加的字（改完选区盖着它们）
        var first = int.MaxValue;
        var last = 0;
        for (var index = start; index < end; index++)
        {
            if (!analyzed.Hidden[index] && !analyzed.Blocked[index] && !IsBlank(units[index]))
            {
                first = Math.Min(first, index);
                last = Math.Max(last, index + 1);
            }
        }

        if (first == int.MaxValue)
        {
            return new LineOutcome(null, null, null);
        }

        var flag = Flag(wrap);
        var desired = analyzed.Flags.Select(value => (value & flag) != 0).ToArray();
        for (var index = start; index < end; index++)
        {
            if (!analyzed.Hidden[index] && !analyzed.Blocked[index])
            {
                desired[index] = want;
            }
        }

        // 连着的、要这种格式的字一串串
        var runs = new List<(int Lower, int Upper)>();
        var at = 0;
        while (at < count)
        {
            if (oldMarker[at])
            {
                at++;
                continue;
            }

            if (analyzed.Hidden[at] || analyzed.Blocked[at] || !desired[at])
            {
                at++;
                continue;
            }

            var tail = at + 1;
            var lastDesired = at;
            while (tail < count)
            {
                if (oldMarker[tail])
                {
                    tail++;
                    continue;
                }

                if (analyzed.Hidden[tail] || analyzed.Blocked[tail] || !desired[tail])
                {
                    break;
                }

                lastDesired = tail;
                tail++;
            }

            var lower = at;
            while (lower <= lastDesired && IsBlank(units[lower]))
            {
                lower++;
            }

            var upper = lastDesired;
            while (upper >= lower && IsBlank(units[upper]))
            {
                upper--;
            }

            if (lower <= upper)
            {
                runs.Add((lower, upper + 1));
            }

            at = lastDesired + 1;
        }

        var marker = Marker(wrap);
        var insertions = new List<(int Location, string Text)>();
        foreach (var run in runs)
        {
            insertions.Add((run.Lower, marker));
            insertions.Add((run.Upper, marker));
        }

        // 空白：在一串里面就跟着这一串，不在串里（两头的、被代码 / 标记断开的）就不要这种格式
        var inside = new bool[count];
        foreach (var run in runs)
        {
            for (var position = run.Lower; position < run.Upper; position++)
            {
                inside[position] = true;
            }
        }

        for (var index = 0; index < count; index++)
        {
            if (IsBlank(units[index]) && !inside[index])
            {
                desired[index] = false;
            }
        }

        var (replacements, newUnits) = Edits(units, deletions, insertions.OrderBy(item => item.Location).ToList());
        // 这一行本来就是这样：不动它，但选区还是要盖住它里面的字
        if (newUnits == units || replacements.Count == 0)
        {
            return new LineOutcome(null, first, last);
        }

        if (!FormatMatches(analyzed, newUnits, desired, wrap))
        {
            return null;
        }

        return new LineOutcome(replacements, first, last);
    }

    /// <summary>重建之后认一遍：看得见的字一样、别的格式一样、链接一样、这种格式每个能加的字都对。</summary>
    private static bool FormatMatches(Scanned old, string units, bool[] desired, Wrap wrap)
    {
        var spans = Inline(units, ContentStart(units), units.Length);
        var shown = Visible(units, spans);
        if (old.Shown != shown.Units)
        {
            return false;
        }

        var shapes = Shapes(units, spans);
        var mask = Flag(wrap);
        for (var offset = 0; offset < old.Visible.Length; offset++)
        {
            var oldIndex = old.Visible[offset];
            var newIndex = shown.Indices[offset];
            if ((old.Flags[oldIndex] & ~mask) != (shapes.Flags[newIndex] & ~mask) ||
                old.Links[oldIndex] != shapes.Links[newIndex])
            {
                return false;
            }

            if (old.Hidden[oldIndex] || old.Blocked[oldIndex])
            {
                continue;
            }

            if (((shapes.Flags[newIndex] & mask) != 0) != desired[oldIndex])
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Ctrl+B / I / Shift+X 有选区时的整段一种：先看整个选区是不是全都已经是，再每行各自重建。</summary>
    private static NoteTasks.Change? ToggleFormat(Wrap wrap, string block, NoteRange selection)
    {
        // 「全都是」看整个选区（和菜单打勾问的是同一个）
        if (IsFormatted(wrap, block, selection) is not { } all)
        {
            return null;
        }

        var want = !all;
        var end = selection.End;
        var replacements = new List<NoteTasks.Replacement>();
        var (first, last) = (int.MaxValue, 0);
        foreach (var row in Rows(block))
        {
            var lineEnd = row.Start + row.Units.Length;
            var lower = Math.Max(selection.Location, row.Start);
            var upper = Math.Min(end, lineEnd);
            if (upper <= lower)
            {
                continue;
            }

            if (FormatLine(wrap, row.Units, lower - row.Start, upper - row.Start, want) is not { } result)
            {
                return null;
            }

            if (result.First is not { } lineFirst || result.Last is not { } lineLast)
            {
                continue;
            }

            first = Math.Min(first, row.Start + lineFirst);
            last = Math.Max(last, row.Start + lineLast);
            foreach (var replacement in result.Replacements ?? Array.Empty<NoteTasks.Replacement>())
            {
                replacements.Add(new NoteTasks.Replacement(
                    new NoteRange(replacement.Range.Location + row.Start, replacement.Range.Length), replacement.Text));
            }
        }

        if (first == int.MaxValue || last < first || replacements.Count == 0)
        {
            return null;
        }

        var mappedStart = NoteTasks.MappedPosition(first, replacements, staysBeforeInsertion: false);
        var mappedEnd = NoteTasks.MappedPosition(last, replacements, staysBeforeInsertion: true);
        return new NoteTasks.Change(replacements, new NoteRange(mappedStart, mappedEnd - mappedStart));
    }

    // ---- 块格式、链接、清除格式（右键「格式」）----

    public enum BlockKind
    {
        Heading,
        Quote,
        Bullet,
        Ordered,
    }

    /// <summary>右键「格式」里的块格式（标题 1–3、引用、无序列表、有序列表）。mac 是带关联值的枚举；用工厂建，相等比较才对。</summary>
    public readonly record struct BlockFormat(BlockKind Kind, int Level = 0)
    {
        public static readonly BlockFormat Quote = new(BlockKind.Quote);
        public static readonly BlockFormat Bullet = new(BlockKind.Bullet);
        public static readonly BlockFormat Ordered = new(BlockKind.Ordered);

        public static BlockFormat Heading(int level) => new(BlockKind.Heading, level);
    }

    /// <summary>菜单里的名字。</summary>
    public static string Title(BlockFormat format) => format.Kind switch
    {
        BlockKind.Heading => format.Level switch
        {
            1 => "标题 1",
            2 => "标题 2",
            3 => "标题 3",
            _ => "标题",
        },
        BlockKind.Quote => "引用",
        BlockKind.Bullet => "无序列表",
        _ => "有序列表",
    };

    /// <summary>一行开头原有的块标记（缩进之后）：引用、标题、任务 / 列表可以一层层套（`> # 标题`、`- ☐ 任务`），转换时整串换掉；
    /// 标题后面不再往下认（`# - 字` 里的横杠是标题里的字）。</summary>
    private static (int Indent, int End)? BlockMarker(string units)
    {
        var indent = LeadingSpacesOrTabs(units);
        var position = indent;
        var found = false;
        while (position < units.Length)
        {
            if (QuoteEnd(position, units) is { } afterQuote)
            {
                position = afterQuote;
                found = true;
                continue;
            }

            if (HeadingEnd(position, units) is { } afterHeading)
            {
                position = afterHeading;
                found = true;
                break;
            }

            if (NoteTasks.PrefixOf(units[position..]) is { } prefix)
            {
                position += prefix.ContentStart;
                found = true;
                continue;
            }

            break;
        }

        if (!found)
        {
            return null;
        }

        return (indent, position);
    }

    /// <summary>从 position 起的一个 `>`（连后面那个空格）到哪结束。</summary>
    private static int? QuoteEnd(int position, string units)
    {
        if (position >= units.Length || units[position] != '>')
        {
            return null;
        }

        return position + (position + 1 < units.Length && IsBlank(units[position + 1]) ? 2 : 1);
    }

    /// <summary>从 position 起的一个 `#` 标题标记（连后面那些空白）到哪结束。</summary>
    private static int? HeadingEnd(int position, string units)
    {
        var end = position;
        while (end < units.Length && units[end] == '#')
        {
            end++;
        }

        var hashes = end - position;
        if (hashes is < 1 or > 6)
        {
            return null;
        }

        var blanks = 0;
        while (end + blanks < units.Length && IsBlank(units[end + blanks]))
        {
            blanks++;
        }

        if (blanks == 0 || end + blanks >= units.Length)
        {
            return null;
        }

        return end + blanks;
    }

    /// <summary>去掉的时候只去这一种格式自己的标记（标题去掉 `#`，引用去掉 `> `，列表只去掉符号），别的留着。</summary>
    private static (int Indent, int End)? OwnMarker(BlockFormat format, string units)
    {
        switch (format.Kind)
        {
            case BlockKind.Heading:
            {
                if (Heading(units) is not { } head)
                {
                    return null;
                }

                return (LeadingSpaces(units), head.Marker.End);
            }

            case BlockKind.Quote:
            {
                if (Quote(units) is not { } quote)
                {
                    return null;
                }

                return (LeadingSpacesOrTabs(units), quote.End);
            }

            default:
            {
                if (NoteTasks.PrefixOf(units) is not { } prefix)
                {
                    return null;
                }

                var matches = (format.Kind == BlockKind.Bullet && prefix.Lead.Kind == NoteTasks.LeadKind.Bullet) ||
                              (format.Kind == BlockKind.Ordered && prefix.Lead.Kind == NoteTasks.LeadKind.Ordered);
                if (!matches)
                {
                    return null;
                }

                return (prefix.Indent, prefix.ContentStart);
            }
        }
    }

    /// <summary>这一行是不是这种块格式。</summary>
    private static bool IsOn(BlockFormat format, string units) => format.Kind switch
    {
        BlockKind.Heading => Heading(units)?.Level == format.Level,
        BlockKind.Quote => Quote(units) is not null,
        BlockKind.Bullet => NoteTasks.PrefixOf(units)?.Lead.Kind == NoteTasks.LeadKind.Bullet,
        _ => NoteTasks.PrefixOf(units)?.Lead.Kind == NoteTasks.LeadKind.Ordered,
    };

    /// <summary>选区碰到的这一行：没有选区时光标在行里（或行尾），有选区时和这一行有交集。</summary>
    private static bool Touched((int Start, string Units) row, NoteRange selection)
    {
        var range = new NoteRange(row.Start, row.Units.Length);
        if (selection.Length == 0)
        {
            return selection.Location >= range.Location && selection.Location <= range.End;
        }

        return range.Intersection(selection).Length > 0;
    }

    /// <summary>只有空白的一行。</summary>
    private static bool IsBlankRow(string units) => units.All(IsBlank);

    /// <summary>选区碰到的非空行是不是全都已经是这种块格式（菜单打勾用）；没有非空行给 null。</summary>
    public static bool? BlockIsOn(BlockFormat format, string block, NoteRange selection)
    {
        var found = false;
        foreach (var row in Rows(block))
        {
            if (!Touched(row, selection) || IsBlankRow(row.Units))
            {
                continue;
            }

            found = true;
            if (!IsOn(format, row.Units))
            {
                return false;
            }
        }

        return found ? true : (bool?)null;
    }

    /// <summary>换成这种块格式 / 去掉：选了好几行时空行不动，只有一行时空行也变。标题保留原来的缩进、在缩进后加 `# `；引用给不是引用的行加
    /// `> `（别的标记留着）；无序列表和有序列表把原来的块标记（别级的 #、引用的 >、列表符号、任务方框）换成 `- ` / `1. ` `2. `…；
    /// 有序列表**同一缩进算一组、每组从 1 开始**。没有可改的给 null。</summary>
    public static NoteTasks.Change? Block(BlockFormat format, string block, NoteRange selection)
    {
        var candidates = Rows(block).Where(row => Touched(row, selection)).ToList();
        if (candidates.Count > 1)
        {
            candidates = candidates.Where(row => !IsBlankRow(row.Units)).ToList();
        }

        if (candidates.Count == 0)
        {
            return null;
        }

        var all = candidates.All(row => IsOn(format, row.Units));
        var replacements = new List<NoteTasks.Replacement>();
        var counters = new Dictionary<int, int>();
        foreach (var row in candidates)
        {
            var units = row.Units;
            var indent = LeadingSpacesOrTabs(units);
            if (all)
            {
                if (OwnMarker(format, units) is { } own)
                {
                    replacements.Add(new NoteTasks.Replacement(
                        new NoteRange(row.Start + own.Indent, own.End - own.Indent), string.Empty));
                }

                continue;
            }

            string marker;
            switch (format.Kind)
            {
                case BlockKind.Quote:
                {
                    // 别的标记留着（在缩进后面插「> 」，不换掉标题 / 列表的标记）；已经是引用的不动
                    if (Quote(units) is null)
                    {
                        replacements.Add(new NoteTasks.Replacement(new NoteRange(row.Start + indent, 0), "> "));
                    }

                    continue;
                }

                case BlockKind.Bullet:
                    marker = "- ";
                    break;
                case BlockKind.Ordered:
                {
                    var number = counters.GetValueOrDefault(indent) + 1;
                    counters[indent] = number;
                    marker = $"{number}. ";
                    break;
                }

                default:
                    marker = new string('#', format.Level) + " ";
                    break;
            }

            var markerEnd = BlockMarker(units)?.End ?? indent;
            replacements.Add(new NoteTasks.Replacement(
                new NoteRange(row.Start + indent, markerEnd - indent), marker));
        }

        if (replacements.Count == 0)
        {
            return null;
        }

        return new NoteTasks.Change(replacements, NoteTasks.Mapped(selection, replacements));
    }

    /// <summary>选区是不是跨了好几行（链接那一项要停用）。</summary>
    public static bool CrossesLines(string block, NoteRange selection)
    {
        if (selection.End > block.Length)
        {
            return false;
        }

        for (var index = selection.Location; index < selection.End; index++)
        {
            if (block[index] is '\n' or '\r' or '\u2028' or '\u2029')
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>「链接」那一项：没选字插 `[]()`、光标在方括号里；选了字换成 `[选中的字]()`、光标在小括号里。跨行给 null。</summary>
    public static NoteTasks.Change? Link(string block, NoteRange selection)
    {
        var content = ContentStart(block);
        var start = Math.Max(selection.Location, content);
        var end = Math.Min(selection.End, block.Length);
        if (start > end || CrossesLines(block, selection))
        {
            return null;
        }

        if (start == end)
        {
            return new NoteTasks.Change(
                new[] { new NoteTasks.Replacement(new NoteRange(start, 0), "[]()") },
                new NoteRange(start + 1, 0));
        }

        var text = block[start..end];
        return new NoteTasks.Change(
            new[] { new NoteTasks.Replacement(NoteRange.Of(start, end), $"[{text}]()") },
            new NoteRange(start + 1 + text.Length + 2, 0));
    }

    /// <summary>清除格式：选区里的粗体、斜体、删除线、颜色去掉（走重建，选区外的照旧、会拆开），碰到的行内代码、链接整段去掉标记
    /// （代码去掉反引号、链接留下字、去掉 `[` 和 `](地址)`）；块格式不动。</summary>
    public static NoteTasks.Change? Clear(string block, NoteRange selection)
    {
        if (selection.Length <= 0)
        {
            return null;
        }

        var end = selection.End;
        var replacements = new List<NoteTasks.Replacement>();
        var (first, last) = (int.MaxValue, 0);
        foreach (var row in Rows(block))
        {
            var lineEnd = row.Start + row.Units.Length;
            var lower = Math.Max(selection.Location, row.Start);
            var upper = Math.Min(end, lineEnd);
            if (upper <= lower || ClearLine(row.Units, lower - row.Start, upper - row.Start) is not { } result)
            {
                continue;
            }

            foreach (var replacement in result.Replacements)
            {
                replacements.Add(new NoteTasks.Replacement(
                    new NoteRange(replacement.Range.Location + row.Start, replacement.Range.Length), replacement.Text));
            }

            first = Math.Min(first, row.Start + result.First);
            last = Math.Max(last, row.Start + result.Last);
        }

        if (first == int.MaxValue || last < first || replacements.Count == 0)
        {
            return null;
        }

        var mappedStart = NoteTasks.MappedPosition(first, replacements, staysBeforeInsertion: false);
        var mappedEnd = NoteTasks.MappedPosition(last, replacements, staysBeforeInsertion: true);
        return new NoteTasks.Change(replacements, new NoteRange(mappedStart, mappedEnd - mappedStart));
    }

    /// <summary>一行里清除格式：删掉这一行三种强调和颜色的全部标记、碰到（和选区有交集）的行内代码 / 链接的标记，按「选区里的字去掉、
    /// 选区外照旧」一串串重新加；拼完认一遍。</summary>
    private static (List<NoteTasks.Replacement> Replacements, int First, int Last)? ClearLine(
        string units, int sectionLower, int sectionUpper)
    {
        var count = units.Length;
        var content = ContentStart(units);
        var start = Math.Max(sectionLower, content);
        var end = Math.Min(sectionUpper, count);
        while (start < end && IsBlank(units[start]))
        {
            start++;
        }

        while (end > start && IsBlank(units[end - 1]))
        {
            end--;
        }

        if (start >= end)
        {
            return null;
        }

        var spans = Inline(units, content, count);
        var markerRanges = MarkerRanges(spans);
        var sectionRange = NoteRange.Of(start, end);
        var emphasis = MarkersOf(Wrap.Bold, spans).Concat(MarkersOf(Wrap.Italic, spans)).Concat(MarkersOf(Wrap.Strike, spans))
            .OrderBy(r => r.Location).ToList();
        var colorSegments = ColorRuns(spans);
        var colorMarkers = colorSegments.SelectMany(run => new[] { run.Open, run.Close }).OrderBy(r => r.Location).ToList();

        // 碰到的行内代码、链接：整段去掉标记
        (NoteRange Open, NoteRange Close)? Pair(Span span)
        {
            var range = span.Range;
            if (First(markerRanges, m => m.End == range.Location) is not { } open ||
                First(markerRanges, m => m.Location == range.End) is not { } close)
            {
                return null;
            }

            return (open, close);
        }

        var codeRanges = new List<NoteRange>();
        var linkRanges = new List<NoteRange>();
        var syntax = new List<NoteRange>();
        foreach (var span in spans)
        {
            if (span.Range.Intersection(sectionRange).Length <= 0)
            {
                continue;
            }

            if (span.Kind.Tag is not (KindTag.Code or KindTag.Link))
            {
                continue;
            }

            if (span.Kind.Tag == KindTag.Code)
            {
                codeRanges.Add(span.Range);
            }
            else
            {
                linkRanges.Add(span.Range);
            }

            if (Pair(span) is { } found)
            {
                syntax.Add(found.Open);
                syntax.Add(found.Close);
            }
        }

        var deletions = emphasis.Concat(colorMarkers).Concat(syntax).OrderBy(r => r.Location).ToList();
        var analyzed = Scan(units, new HashSet<NoteRange>(deletions));
        var blocked = (bool[])analyzed.Blocked.Clone();
        var codeFlag = new bool[count];
        foreach (var range in codeRanges)
        {
            for (var index = range.Location; index < range.End && index < count; index++)
            {
                blocked[index] = false;
                codeFlag[index] = true;
            }
        }

        // 要哪种格式：选区里去掉、选区外照旧
        var boldFlag = Flag(Wrap.Bold);
        var italicFlag = Flag(Wrap.Italic);
        var strikeFlag = Flag(Wrap.Strike);
        var bold = analyzed.Flags.Select(value => (value & boldFlag) != 0).ToArray();
        var italic = analyzed.Flags.Select(value => (value & italicFlag) != 0).ToArray();
        var strike = analyzed.Flags.Select(value => (value & strikeFlag) != 0).ToArray();
        var desiredColors = new NoteColor?[count];
        foreach (var run in colorSegments)
        {
            for (var index = run.Range.Location; index < run.Range.End && index < count; index++)
            {
                desiredColors[index] = run.Color;
            }
        }

        var first = int.MaxValue;
        var last = 0;
        for (var index = start; index < end; index++)
        {
            if (!analyzed.Hidden[index] && !blocked[index] && !IsBlank(units[index]))
            {
                first = Math.Min(first, index);
                last = Math.Max(last, index + 1);
            }
        }

        if (first == int.MaxValue)
        {
            return null;
        }

        for (var index = start; index < end; index++)
        {
            if (!analyzed.Hidden[index] && !blocked[index])
            {
                bold[index] = false;
                italic[index] = false;
                strike[index] = false;
                desiredColors[index] = null;
            }
        }

        var insertions = new List<(int Location, string Text)>();
        foreach (var (wrap, desired) in new[] { (Wrap.Bold, bold), (Wrap.Italic, italic), (Wrap.Strike, strike) })
        {
            foreach (var run in FlaggedRuns(desired, units, blocked, analyzed.Hidden))
            {
                insertions.Add((run.Lower, Marker(wrap)));
                insertions.Add((run.Upper, Marker(wrap)));
            }
        }

        foreach (var run in TintedRuns(desiredColors, units, blocked, analyzed.Hidden))
        {
            insertions.Add((run.Lower, "["));
            insertions.Add((run.Upper, $"]{{{NoteColors.Name(run.Color)}}}"));
        }

        // 同一处的插入按加进来的先后（稳定排序）
        var ordered = insertions.OrderBy(item => item.Location).ToList();
        var (replacements, newUnits) = Edits(units, deletions, ordered);
        if (newUnits == units || replacements.Count == 0)
        {
            return null;
        }

        // 认一遍：看得见的字一样、别的格式一样、链接该没的没了、这种格式每个能加的字都对、颜色也对
        var newSpans = Inline(newUnits, ContentStart(newUnits), newUnits.Length);
        var shown = Visible(newUnits, newSpans);
        if (analyzed.Shown != shown.Units)
        {
            return null;
        }

        var shapes = Shapes(newUnits, newSpans);
        var newColors = ColorsAt(newUnits, newSpans);
        var formatMask = boldFlag | italicFlag | strikeFlag;
        var codeMask = Flag(Wrap.Code);
        for (var offset = 0; offset < analyzed.Visible.Length; offset++)
        {
            var oldIndex = analyzed.Visible[offset];
            var newIndex = shown.Indices[offset];
            var expected = analyzed.Flags[oldIndex] & ~formatMask;
            if (codeFlag[oldIndex])
            {
                expected &= ~codeMask;
            }

            if (expected != (shapes.Flags[newIndex] & ~formatMask))
            {
                return null;
            }

            var gone = linkRanges.Any(range => range.Contains(oldIndex));
            if ((gone ? null : analyzed.Links[oldIndex]) != shapes.Links[newIndex])
            {
                return null;
            }

            if (analyzed.Hidden[oldIndex] || blocked[oldIndex])
            {
                continue;
            }

            if (((shapes.Flags[newIndex] & boldFlag) != 0) != bold[oldIndex] ||
                ((shapes.Flags[newIndex] & italicFlag) != 0) != italic[oldIndex] ||
                ((shapes.Flags[newIndex] & strikeFlag) != 0) != strike[oldIndex] ||
                newColors[newIndex] != desiredColors[oldIndex])
            {
                return null;
            }
        }

        for (var index = 0; index < newUnits.Length; index++)
        {
            if (newUnits[index] == '\uFFFC' && newColors[index] is not null)
            {
                return null;
            }
        }

        return (replacements, first, last);
    }

    /// <summary>一种格式要加的地方：连着的、要它的字一串串，两头不能是空白；别的标记 / 代码 / 图片断开，透明的旧标记（藏着但没挡着）跨过去。</summary>
    private static List<(int Lower, int Upper)> FlaggedRuns(bool[] desired, string units, bool[] blocked, bool[] hidden)
    {
        var runs = new List<(int Lower, int Upper)>();
        var count = units.Length;
        var index = 0;
        while (index < count)
        {
            if (hidden[index] && !blocked[index])
            {
                index++;
                continue;
            }

            if (hidden[index] || blocked[index] || !desired[index])
            {
                index++;
                continue;
            }

            var tail = index + 1;
            var lastDesired = index;
            while (tail < count)
            {
                if (hidden[tail] && !blocked[tail])
                {
                    tail++;
                    continue;
                }

                if (hidden[tail] || blocked[tail] || !desired[tail])
                {
                    break;
                }

                lastDesired = tail;
                tail++;
            }

            var lower = index;
            while (lower <= lastDesired && IsBlank(units[lower]))
            {
                lower++;
            }

            var upper = lastDesired;
            while (upper >= lower && IsBlank(units[upper]))
            {
                upper--;
            }

            if (lower <= upper)
            {
                runs.Add((lower, upper + 1));
            }

            index = lastDesired + 1;
        }

        return runs;
    }

    /// <summary>颜色要加的地方（同 FlaggedRuns，一串同一种颜色）。</summary>
    private static List<(int Lower, int Upper, NoteColor Color)> TintedRuns(
        NoteColor?[] desired, string units, bool[] blocked, bool[] hidden)
    {
        var runs = new List<(int Lower, int Upper, NoteColor Color)>();
        var count = units.Length;
        var index = 0;
        while (index < count)
        {
            if (hidden[index] && !blocked[index])
            {
                index++;
                continue;
            }

            if (hidden[index] || blocked[index] || desired[index] is not { } ink)
            {
                index++;
                continue;
            }

            var tail = index + 1;
            var lastDesired = index;
            while (tail < count)
            {
                if (hidden[tail] && !blocked[tail])
                {
                    tail++;
                    continue;
                }

                if (hidden[tail] || blocked[tail] || desired[tail] != ink)
                {
                    break;
                }

                lastDesired = tail;
                tail++;
            }

            var lower = index;
            while (lower <= lastDesired && IsBlank(units[lower]))
            {
                lower++;
            }

            var upper = lastDesired;
            while (upper >= lower && IsBlank(units[upper]))
            {
                upper--;
            }

            if (lower <= upper)
            {
                runs.Add((lower, upper + 1, ink));
            }

            index = lastDesired + 1;
        }

        return runs;
    }

    // ---- 代码块（右键「格式」的「代码块」那一项）----

    /// <summary>选区和代码块的关系：不在任何代码块里 / 选区碰到的行全都在同一个块里（连围栏）/ 一半在块里、一半在外（或者跨了两个块）。</summary>
    public enum CodeSpot
    {
        Outside,
        Inside,
        Straddles,
    }

    /// <summary>光标 / 选区落在代码块的哪：选区碰到的行都在同一个块里算「块里」，碰到的行既有块里的又有块外的算「一半一半」。</summary>
    public static CodeSpot CodeSpotOf(string text, NoteRange selection)
    {
        var blocks = CodeBlocks(text);
        if (blocks.Count == 0)
        {
            return CodeSpot.Outside;
        }

        var rows = NoteText.LineRange(text, selection);
        var touched = blocks.Where(block => rows.Intersection(block.Range).Length > 0).ToList();
        if (touched.Count == 0)
        {
            return CodeSpot.Outside;
        }

        if (touched.Count == 1 && touched[0].Range.Contains(rows.Location) && rows.End <= touched[0].Range.End)
        {
            return CodeSpot.Inside;
        }

        return CodeSpot.Straddles;
    }

    /// <summary>「代码块」那一项（mac codeBlock(in:selection:)）：块里的行（连围栏）→ 去掉两行围栏；光标在空行上 → 插三行、光标在中间；
    /// 别的 → 给选区碰到的行上下各加一行围栏。一半在块里一半在外给 null。围栏一律三个反引号。</summary>
    public static NoteTasks.Change? CodeBlockChange(string text, NoteRange selection)
    {
        switch (CodeSpotOf(text, selection))
        {
            case CodeSpot.Straddles:
                return null;

            case CodeSpot.Inside:
            {
                var rowStart = NoteText.LineRange(text, selection).Location;
                CodeBlock? hit = null;
                foreach (var candidate in CodeBlocks(text))
                {
                    if (candidate.Range.Contains(rowStart))
                    {
                        hit = candidate;
                        break;
                    }
                }

                if (hit is not { } block)
                {
                    return null;
                }

                var open = NoteText.LineRange(text, new NoteRange(block.Range.Location, 0));
                var close = NoteText.LineRange(text, new NoteRange(block.Close.Location, 0));
                if (open.End > close.Location)
                {
                    return null;
                }

                var replacements = new[]
                {
                    new NoteTasks.Replacement(open, string.Empty),
                    new NoteTasks.Replacement(close, string.Empty),
                };
                return new NoteTasks.Change(replacements, NoteTasks.Mapped(selection, replacements));
            }

            default:
            {
                var rows = NoteText.LineRange(text, selection);
                // mac getLineStart(for: selection)：开头是第一行的行首，结尾、内容结尾是最后一行的
                var lastLine = NoteText.Line(text,
                    selection.Length == 0 ? selection.Location : Math.Max(selection.End - 1, selection.Location));
                var (start, end, contentsEnd) = (rows.Location, rows.End, lastLine.ContentsEnd);
                var isEmptyLine = contentsEnd == start;
                var atEnd = end >= text.Length;
                if (isEmptyLine && selection.Length == 0)
                {
                    // 光标在空行上：插三行，光标在中间
                    var body = atEnd && contentsEnd == end ? "```\n\n```" : "```\n\n```\n";
                    return new NoteTasks.Change(
                        new[] { new NoteTasks.Replacement(rows, body) },
                        new NoteRange(rows.Location + 4, 0));
                }

                // 给选区碰到的行上下各加一行围栏
                var closeText = "```\n";
                if (text.Length == 0 || rows.End >= text.Length)
                {
                    var last = text.Length > 0 ? text[^1] : '\0';
                    closeText = last is '\n' or '\r' ? "```\n" : "\n```";
                }

                return new NoteTasks.Change(
                    new[]
                    {
                        new NoteTasks.Replacement(new NoteRange(rows.Location, 0), "```\n"),
                        new NoteTasks.Replacement(new NoteRange(rows.End, 0), closeText),
                    },
                    new NoteRange(selection.Location + 4, selection.Length));
            }
        }
    }

    /// <summary>一行里选中的那一段重新上色。[sectionLower, sectionUpper) 是这一行里的选区；给这一行的替换（相对这一行）和改完选区盖着的
    /// 那一段（相对这一行）。没有字要改、或者拼出来认不对给 null。</summary>
    private static NoteTasks.Change? Recolor(string units, int sectionLower, int sectionUpper, NoteColor? color)
    {
        var count = units.Length;
        var content = ContentStart(units);
        var start = Math.Max(sectionLower, content);
        var end = Math.Min(sectionUpper, count);
        if (start >= end)
        {
            return null;
        }

        while (start < end && IsBlank(units[start]))
        {
            start++;
        }

        while (end > start && IsBlank(units[end - 1]))
        {
            end--;
        }

        if (start >= end)
        {
            return null;
        }

        var spans = Inline(units, content, count);
        // 不能上色的字：标记、行内代码、图片（编辑器里是一张图的 U+FFFC；存的形式里是令牌）。**旧的颜色标记例外**：它们反正要删掉，
        // 上色时不算断开——连着的同一种颜色合成一段（`[12]{red}3123[2312]{red}3` 全选上红 → 一整段）
        var oldRuns = ColorRuns(spans);
        var colorMarkers = new bool[count];
        foreach (var run in oldRuns)
        {
            foreach (var range in new[] { run.Open, run.Close })
            {
                for (var index = range.Location; index < range.End && index < count; index++)
                {
                    colorMarkers[index] = true;
                }
            }
        }

        var blocked = new bool[count];
        foreach (var span in spans)
        {
            switch (span.Kind.Tag)
            {
                case KindTag.Marker:
                    if (colorMarkers[span.Range.Location])
                    {
                        break;
                    }

                    for (var index = span.Range.Location; index < span.Range.End && index < count; index++)
                    {
                        blocked[index] = true;
                    }

                    break;
                case KindTag.Code:
                    for (var index = span.Range.Location; index < span.Range.End && index < count; index++)
                    {
                        blocked[index] = true;
                    }

                    break;
            }
        }

        for (var index = 0; index < count; index++)
        {
            if (units[index] == '\uFFFC')
            {
                blocked[index] = true;
            }
        }

        foreach (var match in NoteImages.Matches(units))
        {
            for (var index = match.Range.Location; index < match.Range.End && index < count; index++)
            {
                blocked[index] = true;
            }
        }

        var desired = new NoteColor?[count];
        foreach (var run in oldRuns)
        {
            for (var index = run.Range.Location; index < run.Range.End && index < count; index++)
            {
                desired[index] = run.Color;
            }
        }

        for (var index = start; index < end; index++)
        {
            if (!blocked[index])
            {
                desired[index] = color;
            }
        }

        // 连着的、能上色的、同一种颜色的一串串（旧的颜色标记跨过去：它们不算断开）
        var runs = new List<(int Lower, int Upper, NoteColor Color)>();
        var at = 0;
        while (at < count)
        {
            if (colorMarkers[at])
            {
                at++;
                continue;
            }

            if (desired[at] is not { } ink || blocked[at])
            {
                at++;
                continue;
            }

            var tail = at + 1;
            var lastIndex = at;
            while (tail < count)
            {
                if (colorMarkers[tail])
                {
                    tail++;
                    continue;
                }

                if (blocked[tail] || desired[tail] != ink)
                {
                    break;
                }

                lastIndex = tail;
                tail++;
            }

            runs.Add((at, lastIndex + 1, ink));
            at = lastIndex + 1;
        }

        var deletions = oldRuns.SelectMany(run => new[] { run.Open, run.Close }).OrderBy(r => r.Location).ToList();
        var insertions = new List<(int Location, string Text)>();
        foreach (var run in runs)
        {
            insertions.Add((run.Lower, "["));
            insertions.Add((run.Upper, $"]{{{NoteColors.Name(run.Color)}}}"));
        }

        // 拼出改完的这一行，再照它认一遍。**和原来不一样就改**（颜色没变、只是标记碎了也要整理）；一模一样就不动（响一声）
        var (replacements, newUnits) = Edits(units, deletions, insertions);
        if (newUnits == units || replacements.Count == 0)
        {
            return null;
        }

        if (!RecolorMatches(units, spans, blocked, newUnits, start, end, color))
        {
            return null;
        }

        return new NoteTasks.Change(replacements, NoteRange.Of(start, end));
    }

    /// <summary>把从前到后排好、互不相交的替换一遍拼出来（mac 是从后往前 replaceCharacters；不相交时结果一样，这里一遍是线性的）。</summary>
    private static string Applied(string text, IReadOnlyList<NoteTasks.Replacement> replacements)
    {
        var builder = new StringBuilder(text.Length + 16);
        var last = 0;
        foreach (var replacement in replacements)
        {
            builder.Append(text, last, replacement.Range.Location - last).Append(replacement.Text);
            last = replacement.Range.End;
        }

        return builder.Append(text, last, text.Length - last).ToString();
    }

    /// <summary>把一行的删除和插入拼成替换（位置都是改之前的），再拼出改完的那一行。同一处的插入按给的顺序接起来；插在被删掉的那一段
    /// 开头 / 里面 / 末尾的并进那一段。两个列表都要按位置从前往后排好（一起扫，一行上几千段颜色也是线性的）。</summary>
    private static (List<NoteTasks.Replacement> Replacements, string NewUnits) Edits(
        string units, List<NoteRange> deletions, List<(int Location, string Text)> insertions)
    {
        var edits = new List<(NoteRange Range, string Text)>();
        var extras = new List<(int Location, string Text)>();
        var index = 0;
        foreach (var range in deletions)
        {
            var text = new StringBuilder();
            while (index < insertions.Count && insertions[index].Location < range.Location)
            {
                extras.Add(insertions[index]);
                index++;
            }

            while (index < insertions.Count && insertions[index].Location <= range.End)
            {
                text.Append(insertions[index].Text);
                index++;
            }

            edits.Add((range, text.ToString()));
        }

        for (; index < insertions.Count; index++)
        {
            extras.Add(insertions[index]);
        }

        var extraText = new Dictionary<int, string>();
        foreach (var (location, text) in extras)
        {
            extraText[location] = (extraText.TryGetValue(location, out var earlier) ? earlier : string.Empty) + text;
        }

        for (var at = 0; at < edits.Count; at++)
        {
            if (extraText.Remove(edits[at].Range.Location, out var more))
            {
                edits[at] = (edits[at].Range, edits[at].Text + more);
            }
        }

        foreach (var (location, text) in extraText.OrderBy(pair => pair.Key))
        {
            edits.Add((new NoteRange(location, 0), text));
        }

        var sorted = edits.OrderBy(edit => edit.Range.Location).ToList();
        var replacements = sorted.Select(edit => new NoteTasks.Replacement(edit.Range, edit.Text)).ToList();
        return (replacements, Applied(units, replacements));
    }

    /// <summary>上色之后照同一个扫描器认一遍：看得见的字一样；每个字除颜色以外的样式和原来一样；颜色都是想要的。新旧两行各只扫一遍。</summary>
    private static bool RecolorMatches(
        string old, List<Span> oldSpans, bool[] blocked, string @new, int sectionLower, int sectionUpper, NoteColor? color)
    {
        var oldVisible = Visible(old, oldSpans);
        var newSpans = Inline(@new, ContentStart(@new), @new.Length);
        var newVisible = Visible(@new, newSpans);
        if (oldVisible.Units != newVisible.Units)
        {
            return false;
        }

        var oldColors = ColorsAt(old, oldSpans);
        var newColors = ColorsAt(@new, newSpans);
        var oldShapes = Shapes(old, oldSpans);
        var newShapes = Shapes(@new, newSpans);
        for (var offset = 0; offset < oldVisible.Indices.Length; offset++)
        {
            var oldIndex = oldVisible.Indices[offset];
            var newIndex = newVisible.Indices[offset];
            if (oldShapes.Flags[oldIndex] != newShapes.Flags[newIndex] || oldShapes.Links[oldIndex] != newShapes.Links[newIndex])
            {
                return false;
            }

            var wanted = oldIndex >= sectionLower && oldIndex < sectionUpper && !blocked[oldIndex] ? color : oldColors[oldIndex];
            if (newColors[newIndex] != wanted)
            {
                return false;
            }
        }

        // 图片的 U+FFFC 不许被包进颜色里
        for (var index = 0; index < @new.Length; index++)
        {
            if (@new[index] == '\uFFFC' && newColors[index] is not null)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>看得见的字（去掉所有标记）和它们在这一行里的位置。</summary>
    private static (int[] Indices, string Units) Visible(string units, List<Span> spans)
    {
        var count = units.Length;
        var hidden = new bool[count];
        foreach (var span in spans)
        {
            if (span.Kind.Tag != KindTag.Marker)
            {
                continue;
            }

            var end = Math.Min(span.Range.End, count);
            for (var index = span.Range.Location; index < end; index++)
            {
                hidden[index] = true;
            }
        }

        var indices = new List<int>(count);
        var shown = new StringBuilder(count);
        for (var index = 0; index < count; index++)
        {
            if (!hidden[index])
            {
                indices.Add(index);
                shown.Append(units[index]);
            }
        }

        return (indices.ToArray(), shown.ToString());
    }

    /// <summary>每个字是什么颜色（同 ColorRuns）。</summary>
    private static NoteColor?[] ColorsAt(string units, List<Span> spans)
    {
        var found = new NoteColor?[units.Length];
        foreach (var run in ColorRuns(spans))
        {
            for (var index = run.Range.Location; index < run.Range.End && index < units.Length; index++)
            {
                found[index] = run.Color;
            }
        }

        return found;
    }

    /// <summary>一种样式在 Shapes 里占的位：任务状态 0 是「不是任务」，五种状态用 1–5（低三位）；标题级别三位；其余每种一位。
    /// 颜色、标记、链接不算（链接的地址另外记）。</summary>
    private static int ShapeFlag(Kind kind) => kind.Tag switch
    {
        KindTag.Box => (int)kind.State + 1,
        KindTag.Done => 0x0008,
        KindTag.Heading => kind.Level << 4,
        KindTag.Bold => 0x0080,
        KindTag.Italic => 0x0100,
        KindTag.Strike => 0x0200,
        KindTag.Code => 0x0400,
        KindTag.Quote => 0x0800,
        KindTag.Bullet => 0x1000,
        KindTag.CodeBlock => 0x2000,
        KindTag.Fence => 0x4000,
        _ => 0,
    };

    /// <summary>每个字除颜色和标记以外的样子：样式按位存，链接的地址另外一字一份。扫一遍区间往数组里填。</summary>
    private static (int[] Flags, string?[] Links) Shapes(string units, List<Span> spans)
    {
        var count = units.Length;
        var flags = new int[count];
        var links = new string?[count];
        foreach (var span in spans)
        {
            var end = Math.Min(span.Range.End, count);
            if (span.Range.Location >= end)
            {
                continue;
            }

            if (span.Kind.Tag == KindTag.Link)
            {
                for (var index = span.Range.Location; index < end; index++)
                {
                    links[index] = span.Kind.Address;
                }

                continue;
            }

            var flag = ShapeFlag(span.Kind);
            if (flag == 0)
            {
                continue;
            }

            for (var index = span.Range.Location; index < end; index++)
            {
                flags[index] |= flag;
            }
        }

        return (flags, links);
    }

    // ---- 颜色的标记 ----

    /// <summary>正文去掉颜色的标记（`[`、`]{red}`）之后的字（字数、搜索用）：别的 Markdown 标记照旧留着（那是用户自己打的）。代码块里的行不动。</summary>
    public static string StrippingColors(string body)
    {
        var markers = ColorMarkers(body);
        if (markers.Count == 0)
        {
            return body;
        }

        return Applied(body, markers.Select(range => new NoteTasks.Replacement(range, string.Empty)).ToList());
    }

    /// <summary>正文里有没有可能是颜色标记的「]{」（便宜的判断：底下那行小字每打一个字都问一遍）。</summary>
    public static bool HasColorMarker(string body) => body.Contains("]{", StringComparison.Ordinal);

    /// <summary>颜色的标记在正文里的位置（从前到后）：StrippingColors 去掉的就是它们；搜索命中换回正文里的位置也要它。代码块里的行不算。</summary>
    public static IReadOnlyList<NoteRange> ColorMarkers(string body)
    {
        if (!HasColorMarker(body))
        {
            return Array.Empty<NoteRange>();
        }

        var blocks = CodeBlocks(body);
        var found = new List<NoteRange>();
        var location = 0;
        while (location < body.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(body, location);
            var line = body[start..contentsEnd];
            if (RoleAt(start, blocks) is null && line.Contains("]{", StringComparison.Ordinal))
            {
                var runs = ColorRuns(Inline(line, 0, line.Length));
                found.AddRange(runs.SelectMany(run => new[] { run.Open, run.Close })
                    .OrderBy(r => r.Location)
                    .Select(r => new NoteRange(r.Location + start, r.Length)));
            }

            location = Math.Max(end, location + 1);
        }

        return found;
    }

    // ---- 颜色 ⇄ <span>（导出 / 导入 Markdown 文件、复制成富文本时换，正文里不存这些）----

    private const string SpanOpening = "<span style=\"color:";

    private const string SpanClosing = "</span>";

    /// <summary>正文 → 导出用的 Markdown：代码块里的行不动；别的行把扫描器认得出的颜色换成 `&lt;span style="color: #A11A14"&gt;字&lt;/span&gt;`
    /// （浅色那套的色值，大小写和空格按我们自己写出去的来）。</summary>
    public static string Html(string body)
    {
        if (!body.Contains("]{", StringComparison.Ordinal))
        {
            return body;
        }

        return MapLines(body, "]{", HtmlLine);
    }

    private static string HtmlLine(string line)
    {
        var runs = ColorRuns(Inline(line, 0, line.Length));
        if (runs.Count == 0)
        {
            return line;
        }

        var deletions = new List<NoteRange>();
        var insertions = new List<(int Location, string Text)>();
        foreach (var run in runs)
        {
            deletions.Add(run.Open);
            deletions.Add(run.Close);
            insertions.Add((run.Open.Location, $"<span style=\"color: #{NoteColors.Light(run.Color):X6}\">"));
            insertions.Add((run.Range.End, SpanClosing));
        }

        return Edits(line, deletions, insertions).NewUnits;
    }

    /// <summary>导入 Markdown 时把**我们自己写出去的那种**颜色换回 `[字]{名字}`：同一行里 `&lt;span style="color: #RRGGBB"&gt;`
    /// （冒号后空格可有可无、末尾分号可有可无、十六进制不分大小写），色值是这 6 个之一，到第一个 `&lt;/span&gt;` 为止、中间不含 `&lt;span`、
    /// 不在行内代码和代码块里。别的 HTML 原样留着（显示成字）。</summary>
    public static string BodyFromHtml(string html)
    {
        if (!html.Contains("<span", StringComparison.Ordinal))
        {
            return html;
        }

        return MapLines(html, "<span", DecodeColors);
    }

    /// <summary>不在代码块里、含 needle 的行换成 change(这一行)，别的行和换行符原样。</summary>
    private static string MapLines(string text, string needle, Func<string, string> change)
    {
        var blocks = CodeBlocks(text);
        var result = new StringBuilder(text.Length);
        var location = 0;
        while (location < text.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(text, location);
            var line = text[start..contentsEnd];
            result.Append(RoleAt(start, blocks) is null && line.Contains(needle, StringComparison.Ordinal) ? change(line) : line);
            result.Append(text, contentsEnd, end - contentsEnd);
            location = Math.Max(end, location + 1);
        }

        return result.ToString();
    }

    private static string DecodeColors(string line)
    {
        var code = Inline(line, 0, line.Length).Where(span => span.Kind.Tag == KindTag.Code).Select(span => span.Range).ToList();
        var edits = new List<NoteTasks.Replacement>();
        var search = 0;
        while (search < line.Length)
        {
            var at = line.IndexOf(SpanOpening, search, StringComparison.Ordinal);
            if (at < 0)
            {
                break;
            }

            var openingEnd = at + SpanOpening.Length;
            if (code.Any(range => range.Contains(at)) || ParseColorSpan(line, openingEnd) is not { } found)
            {
                search = openingEnd;
                continue;
            }

            edits.Add(new NoteTasks.Replacement(NoteRange.Of(at, found.End), $"[{found.Content}]{{{NoteColors.Name(found.Color)}}}"));
            search = found.End;
        }

        return edits.Count == 0 ? line : Applied(line, edits);
    }

    /// <summary>十六进制的一位（同 Swift Character.hexDigitValue：0–9、a–f、A–F 和它们的全角写法）。</summary>
    private static int? HexValue(char ch) => ch switch
    {
        >= '0' and <= '9' => ch - '0',
        >= 'a' and <= 'f' => ch - 'a' + 10,
        >= 'A' and <= 'F' => ch - 'A' + 10,
        >= '\uFF10' and <= '\uFF19' => ch - '\uFF10',
        >= '\uFF41' and <= '\uFF46' => ch - '\uFF41' + 10,
        >= '\uFF21' and <= '\uFF26' => ch - '\uFF21' + 10,
        _ => null,
    };

    /// <summary>从 `&lt;span style="color:` 后面（index）往后认；认得出给颜色、内容、整段到哪结束（`&lt;/span&gt;` 后面）。</summary>
    private static (NoteColor Color, string Content, int End)? ParseColorSpan(string text, int index)
    {
        if (index < text.Length && text[index] == ' ')
        {
            index++;
        }

        if (index + 8 > text.Length || text[index] != '#')
        {
            return null;
        }

        index++;
        var hex = 0;
        for (var digit = 0; digit < 6; digit++)
        {
            if (index >= text.Length || HexValue(text[index]) is not { } value)
            {
                return null;
            }

            hex = hex * 16 + value;
            index++;
        }

        if (index < text.Length && text[index] == ';')
        {
            index++;
        }

        // 我们写的是 style="color: #RRGGBB"：十六进制后面是收尾的引号，再是 >
        if (index < text.Length && text[index] == '"')
        {
            index++;
        }

        if (index >= text.Length || text[index] != '>')
        {
            return null;
        }

        var contentStart = index + 1;
        var closing = text.IndexOf(SpanClosing, contentStart, StringComparison.Ordinal);
        if (closing < 0)
        {
            return null;
        }

        var content = text[contentStart..closing];
        if (content.Length == 0 || content.ToLowerInvariant().Contains("<span", StringComparison.Ordinal) ||
            NoteColors.Value(hex) is not { } color)
        {
            return null;
        }

        return (color, content, closing + SpanClosing.Length);
    }

    // ---- 链接 ----

    /// <summary>链接的地址能不能打开：只认 http、https（要有主机名）和 mailto（冒号后面要有东西）；别的给 null。
    /// .NET 的 Uri 比 mac 的 URL 宽：「http:example.com」「http:\\host」它也认成 http://…、开头的空白它会去掉——这几样先挡掉，
    /// http / https 冒号后面得紧跟两个斜杠。</summary>
    public static Uri? Url(string address)
    {
        if (address.Length == 0 || char.IsWhiteSpace(address[0]) ||
            !Uri.TryCreate(address, UriKind.Absolute, out var uri))
        {
            return null;
        }

        switch (uri.Scheme)
        {
            case "http":
            case "https":
            {
                var colon = address.IndexOf(':');
                if (colon != uri.Scheme.Length || !address.AsSpan(colon + 1).StartsWith("//", StringComparison.Ordinal))
                {
                    return null;
                }

                return uri.Host.Length > 0 ? uri : null;
            }

            case "mailto":
                return address.Length > "mailto:".Length ? uri : null;
            default:
                return null;
        }
    }

    // ---- 去掉标记 ----

    /// <summary>这一行去掉 Markdown 标记之后的字（标题和摘要用）：行内的标记（`**粗**` → 粗、`[字](地址)` → 字），blocks 给 true 时
    /// 连行首引用的 `>`、无序列表的符号一起去。标题的 `#` 和任务的方框由 Note 去（它比这里宽），去过的那一行剩下的是内容，只去行内的
    /// （blocks 给 false）。图片的令牌整段换成「[图片]」（它里面的 `[` `]` `(` `)` 不是标记）。</summary>
    public static string Plain(string line, bool blocks)
    {
        line = NoteImages.Display(line);
        var removed = new List<NoteRange>();
        var start = 0;
        if (blocks && Quote(line) is { } quote)
        {
            removed.Add(new NoteRange(0, quote.End));
            start = quote.End;
        }
        else if (blocks && NoteTasks.PrefixOf(line) is { Lead.Kind: NoteTasks.LeadKind.Bullet } prefix)
        {
            removed.Add(new NoteRange(0, prefix.ContentStart));
            start = prefix.ContentStart;
        }

        removed.AddRange(MarkerRanges(Inline(line, start, line.Length)));
        if (removed.Count == 0)
        {
            return line;
        }

        var kept = new StringBuilder(line.Length);
        var index = 0;
        foreach (var range in removed.OrderBy(r => r.Location))
        {
            if (range.Location > index)
            {
                kept.Append(line, index, range.Location - index);
            }

            index = Math.Max(index, range.End);
        }

        kept.Append(line, index, line.Length - index);
        return kept.ToString();
    }
}
