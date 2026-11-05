// 便签里的任务和列表（PLAN-v13 第 1 批，照 mac Notes/NoteTasks.swift）：全是纯函数，编辑器只管调。
// - 存储：正文里任务就是行首的五个方框之一（前面可以有空格 / Tab 缩进）：☐ 待办、◧ 进行中、▣ 紧急、☑ 完成、☒ 取消。
//   方框后面得是一个空格或者行尾（「☐abc」不算），行中间的方框不算。无序列表项是「- 」「* 」「+ 」开头，有序的是「1. 」「1) 」。
// - 改字的几件事都写成「这一行（或选区碰到的那几行）+ 光标在哪 → 换哪几段、换成什么、换完选区在哪」（Change），位置都是 UTF-16 的、
//   相对给进来的那段文字的开头：Ctrl+T 切换（Toggle）、改状态（SetState）、回车续行和空项退出（Newline）、Tab / Shift+Tab 缩进（Indent）、
//   打出「- [ ]」再按空格的自动转换（Shorthand）。
// - 和 Markdown 互转（导出导入用）：「☐ 」↔「- [ ] 」、「◧ 」↔「- [/] 」、「▣ 」↔「- [!] 」、「☑ 」↔「- [x] 」、「☒ 」↔「- [-] 」，
//   缩进和换行符原样；代码块里的行不换。
// - 任务进度（做完几条 / 共几条）：做完 = 完成，共 = 除了取消的全部；只有取消的没有进度。
// 完成 / 取消算「关掉了」（内容划线变淡）；点方框：待办 / 进行中 / 紧急 → 完成，完成 / 取消 → 待办。
using System.Text;

namespace KittyTools.Core.Notes;

public enum NoteTaskState
{
    Todo,
    Doing,
    Urgent,
    Done,
    Cancelled,
}

public static class NoteTasks
{
    public static readonly NoteTaskState[] AllStates =
        { NoteTaskState.Todo, NoteTaskState.Doing, NoteTaskState.Urgent, NoteTaskState.Done, NoteTaskState.Cancelled };

    public static char Character(NoteTaskState state) => state switch
    {
        NoteTaskState.Todo => '☐',
        NoteTaskState.Doing => '◧',
        NoteTaskState.Urgent => '▣',
        NoteTaskState.Done => '☑',
        _ => '☒',
    };

    public static string Title(NoteTaskState state) => state switch
    {
        NoteTaskState.Todo => "待办",
        NoteTaskState.Doing => "进行中",
        NoteTaskState.Urgent => "紧急",
        NoteTaskState.Done => "完成",
        _ => "取消",
    };

    /// <summary>Markdown 的方括号里那个字。</summary>
    public static char Markdown(NoteTaskState state) => state switch
    {
        NoteTaskState.Todo => ' ',
        NoteTaskState.Doing => '/',
        NoteTaskState.Urgent => '!',
        NoteTaskState.Done => 'x',
        _ => '-',
    };

    public static bool IsClosed(NoteTaskState state) => state is NoteTaskState.Done or NoteTaskState.Cancelled;

    public static bool CountsAsProgress(NoteTaskState state) => state != NoteTaskState.Cancelled;

    public static NoteTaskState? StateOf(char box) => box switch
    {
        '☐' => NoteTaskState.Todo,
        '◧' => NoteTaskState.Doing,
        '▣' => NoteTaskState.Urgent,
        '☑' => NoteTaskState.Done,
        '☒' => NoteTaskState.Cancelled,
        _ => null,
    };

    /// <summary>Markdown 方括号里那个字 → 状态（大小写都认 x）。</summary>
    public static NoteTaskState? StateOfMarkdown(char mark) => char.ToLowerInvariant(mark) switch
    {
        ' ' => NoteTaskState.Todo,
        '/' => NoteTaskState.Doing,
        '!' => NoteTaskState.Urgent,
        'x' => NoteTaskState.Done,
        '-' => NoteTaskState.Cancelled,
        _ => null,
    };

    public enum LeadKind
    {
        Task,
        Bullet,
        Ordered,
    }

    /// <summary>行首（缩进之后）的列表标记。Task 带 State；Bullet 带 Symbol（- * +）；Ordered 带 Number 和 Symbol（. 或 )）。</summary>
    public readonly record struct Lead(LeadKind Kind, NoteTaskState State = NoteTaskState.Todo, char Symbol = '\0', int Number = 0);

    /// <summary>一行开头的列表标记（位置是 UTF-16 的、相对行首）。</summary>
    public readonly record struct Prefix(int Indent, Lead Lead, int MarkerLength, bool HasSpace)
    {
        /// <summary>标记（连后面的空格）到哪为止 = 内容从哪开始。</summary>
        public int ContentStart => Indent + MarkerLength + (HasSpace ? 1 : 0);
    }

    public readonly record struct Replacement(NoteRange Range, string Text);

    /// <summary>一次改动：若干处替换（从前到后、互不相交，位置都是改之前的）和改完之后的选区。</summary>
    public sealed record Change(IReadOnlyList<Replacement> Replacements, NoteRange Selection)
    {
        /// <summary>把改动用到 text 上（从后往前换，位置都是改之前的）。</summary>
        public string Apply(string text)
        {
            var builder = new StringBuilder(text);
            for (var index = Replacements.Count - 1; index >= 0; index--)
            {
                var replacement = Replacements[index];
                builder.Remove(replacement.Range.Location, replacement.Range.Length);
                builder.Insert(replacement.Range.Location, replacement.Text);
            }

            return builder.ToString();
        }
    }

    // ---- 认标记 ----

    public static Prefix? PrefixOf(string line)
    {
        var indent = 0;
        while (indent < line.Length && line[indent] is ' ' or '\t')
        {
            indent++;
        }

        if (indent >= line.Length)
        {
            return null;
        }

        var first = line[indent];
        char? follower = indent + 1 < line.Length ? line[indent + 1] : null;
        if (StateOf(first) is { } state)
        {
            if (follower is not null && follower != ' ')
            {
                return null;
            }

            return new Prefix(indent, new Lead(LeadKind.Task, state), 1, follower is not null);
        }

        if (first is '-' or '*' or '+')
        {
            return follower == ' ' ? new Prefix(indent, new Lead(LeadKind.Bullet, Symbol: first), 1, true) : null;
        }

        var digits = 0;
        while (indent + digits < line.Length && char.IsAsciiDigit(line[indent + digits]))
        {
            digits++;
        }

        var end = indent + digits;
        if (digits is < 1 or > 9 || end + 1 >= line.Length || line[end + 1] != ' ' || line[end] is not ('.' or ')'))
        {
            return null;
        }

        var number = 0;
        for (var index = indent; index < end; index++)
        {
            number = number * 10 + (line[index] - '0');
        }

        return new Prefix(indent, new Lead(LeadKind.Ordered, Symbol: line[end], Number: number), digits + 1, true);
    }

    /// <summary>这一行是任务的话，方框那个字在第几个位置；不是任务给 null。</summary>
    public static int? Box(string line)
        => PrefixOf(line) is { Lead.Kind: LeadKind.Task } prefix ? prefix.Indent : null;

    public static NoteTaskState? StateOfLine(string line)
        => PrefixOf(line) is { Lead.Kind: LeadKind.Task } prefix ? prefix.Lead.State : null;

    /// <summary>点方框：待办 / 进行中 / 紧急 → 完成；完成 / 取消 → 待办。</summary>
    public static char Flipped(char box)
        => StateOf(box) is { } state ? Character(IsClosed(state) ? NoteTaskState.Todo : NoteTaskState.Done) : box;

    private static bool IsBlank(string line) => line.All(ch => ch is ' ' or '\t');

    private static int IndentOf(string line)
    {
        var indent = 0;
        while (indent < line.Length && line[indent] is ' ' or '\t')
        {
            indent++;
        }

        return indent;
    }

    // ---- Ctrl+T 和「任务状态」----

    /// <summary>Ctrl+T：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头。都已经是任务 → 都去掉标记；
    /// 否则把还不是任务的变成待办（「- 」「* 」「+ 」换成 ☐，别的在缩进后面加「☐ 」）。选了好几行时空行不动；只有一行时空行也变。</summary>
    public static Change? Toggle(string block, NoteRange selection)
    {
        var lines = LinesInBlock(block);
        var candidates = lines.Count == 1 ? lines : lines.Where(line => !IsBlank(line.Text)).ToList();
        if (candidates.Count == 0)
        {
            return null;
        }

        var prefixes = candidates.Select(line => PrefixOf(line.Text)).ToList();
        var allTasks = prefixes.All(prefix => prefix is { Lead.Kind: LeadKind.Task });
        var replacements = new List<Replacement>();
        for (var index = 0; index < candidates.Count; index++)
        {
            var line = candidates[index];
            var prefix = prefixes[index];
            if (allTasks && prefix is { } task)
            {
                replacements.Add(new Replacement(
                    new NoteRange(line.Start + task.Indent, task.ContentStart - task.Indent), string.Empty));
            }
            else if (prefix is { Lead.Kind: LeadKind.Task })
            {
                continue;
            }
            else if (prefix is { Lead.Kind: LeadKind.Bullet } bullet)
            {
                replacements.Add(new Replacement(new NoteRange(line.Start + bullet.Indent, 1),
                    Character(NoteTaskState.Todo).ToString()));
            }
            else
            {
                replacements.Add(new Replacement(new NoteRange(line.Start + IndentOf(line.Text), 0),
                    $"{Character(NoteTaskState.Todo)} "));
            }
        }

        return replacements.Count == 0 ? null : new Change(replacements, Mapped(selection, replacements));
    }

    /// <summary>右键菜单「任务状态 ›」：把选区碰到的每一行改成 state。一行都不用改时给 null。</summary>
    public static Change? SetState(NoteTaskState state, string block, NoteRange selection)
    {
        var lines = LinesInBlock(block);
        var candidates = lines.Count == 1 ? lines : lines.Where(line => !IsBlank(line.Text)).ToList();
        if (candidates.Count == 0)
        {
            return null;
        }

        var replacements = new List<Replacement>();
        foreach (var line in candidates)
        {
            var prefix = PrefixOf(line.Text);
            if (prefix is { Lead.Kind: LeadKind.Task } task)
            {
                if (task.Lead.State == state)
                {
                    continue;
                }

                replacements.Add(new Replacement(new NoteRange(line.Start + task.Indent, 1), Character(state).ToString()));
            }
            else if (prefix is { Lead.Kind: LeadKind.Bullet } bullet)
            {
                replacements.Add(new Replacement(new NoteRange(line.Start + bullet.Indent, 1), Character(state).ToString()));
            }
            else
            {
                var indent = prefix?.Indent ?? IndentOf(line.Text);
                replacements.Add(new Replacement(new NoteRange(line.Start + indent, 0), $"{Character(state)} "));
            }
        }

        return replacements.Count == 0 ? null : new Change(replacements, Mapped(selection, replacements));
    }

    /// <summary>选区碰到的每一行是任务的话，都是同一种状态时给那种；没有任务、或不一样给 null。</summary>
    public static NoteTaskState? StateIn(string block, NoteRange selection)
    {
        NoteTaskState? found = null;
        foreach (var (start, contentsEnd, _) in NoteText.Lines(block))
        {
            var lineRange = NoteRange.Of(start, contentsEnd);
            var touched = selection.Length == 0
                ? lineRange.Contains(selection.Location) || selection.Location == lineRange.End
                : lineRange.Intersection(selection).Length > 0;
            if (!touched || StateOfLine(block[start..contentsEnd]) is not { } state)
            {
                continue;
            }

            if (found is not null && found != state)
            {
                return null;
            }

            found = state;
        }

        return found;
    }

    /// <summary>选区经过这些替换之后在哪（光标停在插入点上时挪到插进去的字后面；一段选区的开头停在插入点上时不挪）。</summary>
    public static NoteRange Mapped(NoteRange selection, IReadOnlyList<Replacement> replacements)
    {
        var start = MappedPosition(selection.Location, replacements, staysBeforeInsertion: selection.Length > 0);
        var end = MappedPosition(selection.End, replacements, staysBeforeInsertion: false);
        return new NoteRange(start, Math.Max(end - start, 0));
    }

    public static int MappedPosition(int position, IReadOnlyList<Replacement> replacements, bool staysBeforeInsertion)
    {
        var shift = 0;
        foreach (var replacement in replacements)
        {
            var range = replacement.Range;
            var added = replacement.Text.Length;
            if (position > range.End || (position == range.End && (range.Length > 0 || !staysBeforeInsertion)))
            {
                shift += added - range.Length;
            }
            else if (position > range.Location)
            {
                return range.Location + shift + added;
            }
            else
            {
                break;
            }
        }

        return position + shift;
    }

    // ---- 回车、Tab、自动转换 ----

    /// <summary>回车（没有选区时）：列表行、任务行下一行带同样的标记（任务一律「☐ 」，有序是下一个数字），保留缩进；
    /// 空的列表项 / 空任务：去掉这一行的标记（留着缩进）。不是列表行、光标在标记前面：null = 照常换行。</summary>
    public static Change? Newline(string line, int caret)
    {
        if (PrefixOf(line) is not { } prefix || caret < prefix.ContentStart || caret > line.Length)
        {
            return null;
        }

        if (line.Skip(prefix.ContentStart).All(ch => ch is ' ' or '\t'))
        {
            return new Change(
                new[] { new Replacement(new NoteRange(prefix.Indent, line.Length - prefix.Indent), string.Empty) },
                new NoteRange(prefix.Indent, 0));
        }

        var marker = prefix.Lead.Kind switch
        {
            LeadKind.Task => $"{Character(NoteTaskState.Todo)} ",
            LeadKind.Bullet => $"{prefix.Lead.Symbol} ",
            _ => $"{prefix.Lead.Number + 1}{prefix.Lead.Symbol} ",
        };
        var inserted = "\n" + line[..prefix.Indent] + marker;
        return new Change(
            new[] { new Replacement(new NoteRange(caret, 0), inserted) },
            new NoteRange(caret + inserted.Length, 0));
    }

    public const int IndentWidth = 2;

    /// <summary>Tab / Shift+Tab（没有选区时）：列表行缩进 / 退回一级。不是列表行：null = 照常。没有缩进可退：空改动（吞掉这一下）。</summary>
    public static Change? Indent(string line, int caret, bool outdent)
    {
        if (PrefixOf(line) is null)
        {
            return null;
        }

        if (!outdent)
        {
            return new Change(
                new[] { new Replacement(new NoteRange(0, 0), new string(' ', IndentWidth)) },
                new NoteRange(caret + IndentWidth, 0));
        }

        var spaces = 0;
        while (spaces < line.Length && line[spaces] == ' ')
        {
            spaces++;
        }

        var removed = line.Length > 0 && line[0] == '\t' ? 1 : Math.Min(spaces, IndentWidth);
        if (removed == 0)
        {
            return new Change(Array.Empty<Replacement>(), new NoteRange(caret, 0));
        }

        return new Change(
            new[] { new Replacement(new NoteRange(0, removed), string.Empty) },
            new NoteRange(Math.Max(caret - removed, 0), 0));
    }

    /// <summary>打字自动转换：行首（缩进之后）已经是「- [ ]」、光标紧跟在后面时按空格——换成方框 + 空格。</summary>
    public static Change? Shorthand(string line, int caret)
    {
        var indent = IndentOf(line);
        if (caret != indent + 5 || line.Length < caret)
        {
            return null;
        }

        var typed = line.Substring(indent, 5);
        if (typed[0] is not ('-' or '*' or '+') || typed[1] != ' ' || typed[2] != '[' || typed[4] != ']')
        {
            return null;
        }

        if (StateOfMarkdown(typed[3]) is not { } state)
        {
            return null;
        }

        return new Change(
            new[] { new Replacement(new NoteRange(indent, 5), $"{Character(state)} ") },
            new NoteRange(indent + 2, 0));
    }

    // ---- 和 Markdown 互转 ----

    /// <summary>正文 → Markdown：任务行的方框换成「- [ ]」等，代码块里的行不换。</summary>
    public static string MarkdownFromBody(string body)
    {
        var blocks = CodeBlocks(body);
        return MapLines(body, blocks, line =>
            PrefixOf(line) is { Lead.Kind: LeadKind.Task } prefix
                ? new Replacement(new NoteRange(prefix.Indent, 1), $"- [{Markdown(prefix.Lead.State)}]")
                : null);
    }

    /// <summary>Markdown → 正文：行首的「- [ ]」等（`*` `+` 开头也算，后面得是空格或行尾）换成方框；代码块里的行不换。</summary>
    public static string BodyFromMarkdown(string markdown)
    {
        var blocks = CodeBlocks(markdown);
        return MapLines(markdown, blocks, line =>
        {
            var indent = IndentOf(line);
            if (line.Length < indent + 5 || (line.Length != indent + 5 && line[indent + 5] != ' '))
            {
                return null;
            }

            var typed = line.Substring(indent, 5);
            if (typed[0] is not ('-' or '*' or '+') || typed[1] != ' ' || typed[2] != '[' || typed[4] != ']' ||
                StateOfMarkdown(typed[3]) is not { } state)
            {
                return null;
            }

            return new Replacement(new NoteRange(indent, 5), Character(state).ToString());
        });
    }

    private static IReadOnlyList<NoteMarkdown.CodeBlock> CodeBlocks(string text)
        => text.Contains("```", StringComparison.Ordinal) || text.Contains("~~~", StringComparison.Ordinal)
            ? NoteMarkdown.CodeBlocks(text)
            : Array.Empty<NoteMarkdown.CodeBlock>();

    private static string MapLines(string text, IReadOnlyList<NoteMarkdown.CodeBlock> blocks, Func<string, Replacement?> change)
    {
        var result = new StringBuilder(text.Length + 16);
        var location = 0;
        while (location < text.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(text, location);
            var line = text[start..contentsEnd];
            if (NoteMarkdown.RoleAt(start, blocks) is null && change(line) is { } replacement)
            {
                line = line[..replacement.Range.Location] + replacement.Text + line[replacement.Range.End..];
            }

            result.Append(line).Append(text, contentsEnd, end - contentsEnd);
            location = end;
        }

        return result.ToString();
    }

    /// <summary>把 block 拆成行（每行的 Start 相对 block 的开头；不含行尾的换行；block 以换行结尾时后面的空行也算一行）。</summary>
    private static List<(int Start, string Text)> LinesInBlock(string block)
    {
        var lines = new List<(int Start, string Text)>();
        var location = 0;
        do
        {
            var (start, end, contentsEnd) = NoteText.Line(block, location);
            lines.Add((start, block[start..contentsEnd]));
            if (end == block.Length && contentsEnd < end)
            {
                lines.Add((end, string.Empty));
            }

            location = end;
        }
        while (location < block.Length);

        return lines;
    }

    // ---- 进度 ----

    /// <summary>任务做完几条 / 共几条；一条都不算（没有任务、只有取消的）是 null。代码块里的行不算。</summary>
    public static (int Done, int Total)? Progress(string body)
    {
        var blocks = CodeBlocks(body);
        var (finished, total) = (0, 0);
        var location = 0;
        while (location < body.Length)
        {
            var (start, end, contentsEnd) = NoteText.Line(body, location);
            var box = start;
            while (box < contentsEnd && body[box] is ' ' or '\t')
            {
                box++;
            }

            if (box < contentsEnd && (box + 1 == contentsEnd || body[box + 1] == ' ') &&
                StateOf(body[box]) is { } state && CountsAsProgress(state) && NoteMarkdown.RoleAt(start, blocks) is null)
            {
                total++;
                if (state == NoteTaskState.Done)
                {
                    finished++;
                }
            }

            location = Math.Max(end, location + 1);
        }

        return total > 0 ? (finished, total) : null;
    }
}
