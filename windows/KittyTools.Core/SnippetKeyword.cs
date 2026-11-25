// 片段的关键词（照 mac SnippetExpand/SnippetKeyword.swift，0.10.3）：在任何程序里打出关键词，就换成片段的内容。
// 这里只放关键词本身的规矩（纯函数，配单测 SnippetKeywordTests）：
// - 只收键盘能直接打出来的字：英文字母、数字、符号（可见的 ASCII，不含空格）；输入法上屏的汉字不经过按键，写进去也永远对不上
// - 2–32 个字；大小写严格
// - 两条片段的关键词一样：不让存；一个是另一个的开头：提示「打不出那一条」，照样能存（打完立刻展开，短的先展开）。
//   同步来的、重新存成片段的还是可能撞上：展开时用列表里最前（最近用过）的那条，设置页那一行标出来（Duplicates）
// - 全是字母或数字的：提示「打普通单词时可能误展开，建议用 ; 开头」（不强制前缀）
// 同步、导出导入里来的关键词不合 IsValid：同步那一类整个不落（ClipSync），导出文件里的那一个丢掉。
namespace KittyTools.Core;

public static class SnippetKeyword
{
    public const int MinLength = 2;
    public const int MaxLength = 32;

    /// <summary>输入框里的字收拾成关键词：去掉首尾空白；空的 null（= 没有关键词）。</summary>
    public static string? Normalized(string? raw)
        => raw?.Trim() is { Length: > 0 } trimmed ? trimmed : null;

    /// <summary>能当关键词：长度够、每个字都是可见的 ASCII（不含空格）。全是 ASCII，所以 Length 就是字数。</summary>
    public static bool IsValid(string keyword)
        => keyword.Length is >= MinLength and <= MaxLength && keyword.All(Typeable);

    private static bool Typeable(char c) => c is >= '!' and <= '~';

    public enum ProblemKind
    {
        TooShort,
        TooLong,

        /// <summary>有键盘打不出来的字（汉字、空格、全角符号……）。</summary>
        Untypeable,

        /// <summary>和另一条片段的一样（Title 是那一条的叫法）。</summary>
        Duplicate,
    }

    public sealed record Problem(ProblemKind Kind, string Title = "");

    public enum WarningKind
    {
        /// <summary>这个是另一条的开头：那一条打不出来。</summary>
        Hides,

        /// <summary>另一条是这个的开头：这一条打不出来。</summary>
        HiddenBy,

        /// <summary>全是字母或数字：打普通单词时可能误展开。</summary>
        PlainWord,
    }

    public sealed record Warning(WarningKind Kind, string Title = "");

    /// <summary>别的片段：关键词和叫法（名称，没有就是正文开头）。</summary>
    public sealed record Other(string Keyword, string Title);

    public sealed record Check(Problem? Problem, IReadOnlyList<Warning> Warnings);

    /// <summary>编辑框里打的这个关键词怎么样（others 不含正在编的这一条）。空的（不设关键词）什么都不说。</summary>
    public static Check Evaluate(string? raw, IReadOnlyList<Other> others)
    {
        if (Normalized(raw) is not { } keyword)
        {
            return new Check(null, Array.Empty<Warning>());
        }

        // mac 先按 Unicode 标量查、再按字数：一个表情是两个 char，但已经是「打不出来」了，不影响长度判断
        if (!keyword.All(Typeable))
        {
            return new Check(new Problem(ProblemKind.Untypeable), Array.Empty<Warning>());
        }

        if (keyword.Length < MinLength)
        {
            return new Check(new Problem(ProblemKind.TooShort), Array.Empty<Warning>());
        }

        if (keyword.Length > MaxLength)
        {
            return new Check(new Problem(ProblemKind.TooLong), Array.Empty<Warning>());
        }

        if (others.FirstOrDefault(other => other.Keyword == keyword) is { } same)
        {
            return new Check(new Problem(ProblemKind.Duplicate, same.Title), Array.Empty<Warning>());
        }

        var warnings = new List<Warning>();
        if (others.FirstOrDefault(other => other.Keyword.StartsWith(keyword, StringComparison.Ordinal)) is { } longer)
        {
            warnings.Add(new Warning(WarningKind.Hides, longer.Title));
        }

        if (others.FirstOrDefault(other => keyword.StartsWith(other.Keyword, StringComparison.Ordinal)) is { } shorter)
        {
            warnings.Add(new Warning(WarningKind.HiddenBy, shorter.Title));
        }

        if (keyword.All(char.IsAsciiLetterOrDigit))
        {
            warnings.Add(new Warning(WarningKind.PlainWord));
        }

        return new Check(null, warnings);
    }

    /// <summary>存不了的那句（编辑框下面红字）。</summary>
    public static string Message(Problem problem) => problem.Kind switch
    {
        ProblemKind.TooShort => $"关键词至少 {MinLength} 个字",
        ProblemKind.TooLong => $"关键词最多 {MaxLength} 个字",
        ProblemKind.Untypeable => "关键词只能用英文字母、数字和符号，不能有空格",
        _ => $"和「{problem.Title}」的关键词一样",
    };

    /// <summary>提醒的那句（编辑框下面橙字）。</summary>
    public static string Message(Warning warning) => warning.Kind switch
    {
        WarningKind.Hides => $"打完它就会展开，「{warning.Title}」的关键词打不出来了",
        WarningKind.HiddenBy => $"「{warning.Title}」的关键词是它的开头，打到那里就先展开了",
        _ => "打普通单词时可能误展开，建议用 ; 开头",
    };

    /// <summary>一组片段的关键词里撞上了的（出现不止一次的）：设置页标出来，展开时只有列表里最前那条算数。</summary>
    public static IReadOnlySet<string> Duplicates(IEnumerable<string> keywords)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var duplicates = new HashSet<string>(StringComparer.Ordinal);
        foreach (var keyword in keywords)
        {
            if (!seen.Add(keyword))
            {
                duplicates.Add(keyword);
            }
        }

        return duplicates;
    }

    /// <summary>片段的叫法（提示里说「和「…」重复」）：名称（存在备注里），没有就是正文开头一行（超过 20 个字加 …）。</summary>
    public static string Title(string? note, string? text)
    {
        if (note?.Trim() is { Length: > 0 } name)
        {
            return Prefix(name, 20);
        }

        var line = (text ?? string.Empty).Split('\n', '\r').FirstOrDefault(part => part.Length > 0) ?? string.Empty;
        var head = line.Trim();
        var info = new System.Globalization.StringInfo(head);
        return info.LengthInTextElements > 20 ? info.SubstringByTextElements(0, 20) + "…" : head;
    }

    private static string Prefix(string text, int count)
    {
        var info = new System.Globalization.StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }
}
