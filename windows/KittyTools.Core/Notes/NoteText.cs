// 便签纯函数共用的几样小工具（PLAN-v13 第 1 批）：mac 那边是 NSString / Character 自带的，C# 这里补上——
// - NoteRange：UTF-16 的区间（mac NSRange；位置都是 UTF-16 的，和 C# 的 string 下标一致）。
// - Line：NSString.getLineStart(_:end:contentsEnd:for:) 的口径：\n、\r、\r\n、U+0085、U+2028、U+2029 都算换行，\r\n 算一个。
// - 字数（Swift 的 String.count 数的是字位簇）：标题截断、摘要截断按它数（StringInfo），不然一个 emoji 算两个字。
// - 空白：Swift 的 .whitespaces（Zs + Tab）和 .whitespacesAndNewlines（再加 U+000A–U+000D、U+0085、U+2028、U+2029）。
using System.Globalization;

namespace KittyTools.Core.Notes;

/// <summary>UTF-16 的区间（mac NSRange）。</summary>
public readonly record struct NoteRange(int Location, int Length)
{
    public int End => Location + Length;

    public bool Contains(int index) => index >= Location && index < End;

    public static NoteRange Of(int start, int end) => new(start, Math.Max(end - start, 0));

    public NoteRange Intersection(NoteRange other)
    {
        var start = Math.Max(Location, other.Location);
        var end = Math.Min(End, other.End);
        return end > start ? new NoteRange(start, end - start) : new NoteRange(start, 0);
    }

    public NoteRange Union(NoteRange other) => Of(Math.Min(Location, other.Location), Math.Max(End, other.End));
}

public static class NoteText
{
    public static bool IsBreak(char ch) => ch is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029';

    /// <summary>mac getLineStart：location 所在那一行的开头、行尾换行之后、换行之前。</summary>
    public static (int Start, int End, int ContentsEnd) Line(string text, int location)
    {
        location = Math.Clamp(location, 0, text.Length);
        var start = location;
        // 落在 \r\n 的 \n 上：这个字属于上一行的行尾
        if (start < text.Length && start > 0 && text[start] == '\n' && text[start - 1] == '\r')
        {
            start--;
        }

        while (start > 0 && !IsBreak(text[start - 1]))
        {
            start--;
        }

        var index = start;
        while (index < text.Length && !IsBreak(text[index]))
        {
            index++;
        }

        var contentsEnd = index;
        var end = index;
        if (index < text.Length)
        {
            end = text[index] == '\r' && index + 1 < text.Length && text[index + 1] == '\n' ? index + 2 : index + 1;
        }

        return (start, end, contentsEnd);
    }

    /// <summary>range 碰到的那几行的整段（mac lineRange(for:)，连最后一行的换行）。</summary>
    public static NoteRange LineRange(string text, NoteRange range)
    {
        var first = Line(text, range.Location);
        if (range.Length == 0)
        {
            return NoteRange.Of(first.Start, first.End);
        }

        var last = Line(text, Math.Max(range.End - 1, range.Location));
        return NoteRange.Of(first.Start, Math.Max(last.End, first.End));
    }

    /// <summary>一行一行（不含行尾的换行）：每行的开头、内容、行尾之后。</summary>
    public static IEnumerable<(int Start, int ContentsEnd, int End)> Lines(string text)
    {
        var location = 0;
        while (location < text.Length)
        {
            var (start, end, contentsEnd) = Line(text, location);
            yield return (start, contentsEnd, end);
            location = Math.Max(end, location + 1);
        }
    }

    /// <summary>Swift .whitespaces：Zs 类和 Tab（不含换行）。</summary>
    public static bool IsSpace(char ch)
        => ch == '\t' || CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.SpaceSeparator;

    /// <summary>Swift .whitespacesAndNewlines。</summary>
    public static bool IsSpaceOrNewline(char ch) => IsSpace(ch) || ch is >= '\n' and <= '\r' || IsBreak(ch);

    public static string TrimSpaces(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsSpace(text[start]))
        {
            start++;
        }

        while (end > start && IsSpace(text[end - 1]))
        {
            end--;
        }

        return text[start..end];
    }

    public static string TrimSpacesAndNewlines(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsSpaceOrNewline(text[start]))
        {
            start++;
        }

        while (end > start && IsSpaceOrNewline(text[end - 1]))
        {
            end--;
        }

        return text[start..end];
    }

    /// <summary>Swift Character.isWhitespace（Unicode 的 White_Space）。</summary>
    public static bool IsWhite(char ch) => char.IsWhiteSpace(ch);

    /// <summary>字数（字位簇，同 Swift String.count）。</summary>
    public static int Count(string text) => text.Length == 0 ? 0 : new StringInfo(text).LengthInTextElements;

    /// <summary>前 count 个字（字位簇）。</summary>
    public static string Prefix(string text, int count)
    {
        if (count <= 0)
        {
            return string.Empty;
        }

        if (text.Length <= count)
        {
            return text;
        }

        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var taken = 0;
        while (enumerator.MoveNext())
        {
            if (taken == count)
            {
                return text[..enumerator.ElementIndex];
            }

            taken++;
        }

        return text;
    }

    /// <summary>超过 length 个字就截断加「…」（mac Note.clipped）。</summary>
    public static string Clipped(string text, int length) => Count(text) > length ? Prefix(text, length) + "…" : text;

    /// <summary>不把一对代理项从中间切开的 UTF-16 前缀（扫描的上限用；按字截太贵）。</summary>
    public static string SafePrefix(string text, int units)
    {
        if (text.Length <= units)
        {
            return text;
        }

        var end = units;
        if (end > 0 && char.IsHighSurrogate(text[end - 1]))
        {
            end--;
        }

        return text[..end];
    }
}
