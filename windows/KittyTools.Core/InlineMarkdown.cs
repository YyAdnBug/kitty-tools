// 大模型结果里的行内 Markdown（纯函数，配单测；mac 用 AttributedString(markdown:, .inlineOnlyPreservingWhitespace)，PLAN-v9-translate F15）：
// **粗** __粗__ *斜* `代码` ~~删除线~~ [字](网址)，块级标记（# 标题、- 列表）原样显示，换行原样保留。
// 记号要成对才算：找不到收尾的照字面显示；* 后面是空白的不算开头（「2 * 3」不变斜体），单个 _ 一律照字面（snake_case）。
using System.Text;

namespace KittyTools.Core;

public readonly record struct MarkdownSpan(
    string Text,
    bool Bold = false,
    bool Italic = false,
    bool Code = false,
    bool Strike = false,
    string? Link = null);

public static class InlineMarkdown
{
    /// <summary>有没有值得按 Markdown 显示的记号（mac ProviderCardView.hasMarkdown）。</summary>
    public static bool Has(string text)
        => text.Contains("**", StringComparison.Ordinal) || text.Contains("__", StringComparison.Ordinal) ||
           text.Contains('`') || text.Contains("](", StringComparison.Ordinal);

    public static List<MarkdownSpan> Parse(string text)
    {
        var spans = new List<MarkdownSpan>();
        var buffer = new StringBuilder();
        bool bold = false, italic = false, strike = false;

        void Flush()
        {
            if (buffer.Length > 0)
            {
                spans.Add(new MarkdownSpan(buffer.ToString(), bold, italic, Strike: strike));
                buffer.Clear();
            }
        }

        var index = 0;
        while (index < text.Length)
        {
            var current = text[index];
            if (current == '\\' && index + 1 < text.Length && IsEscapable(text[index + 1]))
            {
                buffer.Append(text[index + 1]);
                index += 2;
                continue;
            }

            if (current == '`' && text.IndexOf('`', index + 1) is var end && end > index + 1)
            {
                Flush();
                spans.Add(new MarkdownSpan(text[(index + 1)..end], bold, italic, Code: true, Strike: strike));
                index = end + 1;
                continue;
            }

            if (current == '[' && Link(text, index) is { } link)
            {
                Flush();
                spans.Add(new MarkdownSpan(link.Label, bold, italic, Strike: strike, Link: link.Url));
                index = link.End;
                continue;
            }

            var pair = index + 1 < text.Length ? text.Substring(index, 2) : string.Empty;
            if (pair is "**" or "__" && (bold || text.IndexOf(pair, index + 2, StringComparison.Ordinal) > index + 2))
            {
                Flush();
                bold = !bold;
                index += 2;
                continue;
            }

            if (pair == "~~" && (strike || text.IndexOf("~~", index + 2, StringComparison.Ordinal) > index + 2))
            {
                Flush();
                strike = !strike;
                index += 2;
                continue;
            }

            if (current == '*' && pair != "**" &&
                (italic
                    ? index > 0 && !char.IsWhiteSpace(text[index - 1])
                    : index + 1 < text.Length && !char.IsWhiteSpace(text[index + 1]) && text.IndexOf('*', index + 2) > 0))
            {
                Flush();
                italic = !italic;
                index++;
                continue;
            }

            buffer.Append(current);
            index++;
        }

        Flush();
        return spans;
    }

    /// <summary>[字](网址)：字里不跨行、网址不带空白；只认 http(s) 和 mailto（别的照字面显示）。</summary>
    private static (string Label, string Url, int End)? Link(string text, int start)
    {
        var close = text.IndexOf("](", start + 1, StringComparison.Ordinal);
        if (close <= start + 1)
        {
            return null;
        }

        var paren = text.IndexOf(')', close + 2);
        if (paren <= close + 2)
        {
            return null;
        }

        var label = text[(start + 1)..close];
        var url = text[(close + 2)..paren];
        if (label.Contains('\n') || label.Contains('[') || url.Any(char.IsWhiteSpace) ||
            !(url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
              url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
              url.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase)))
        {
            return null;
        }

        return (label, url, paren + 1);
    }

    private static bool IsEscapable(char character) => character is '\\' or '`' or '*' or '_' or '~' or '[' or ']' or '(' or ')' or '#';
}
