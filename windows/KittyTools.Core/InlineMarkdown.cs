// 大模型结果里的 Markdown（纯函数，配单测；PLAN-v9-translate F15）。行内：**粗** __粗__ *斜* `代码` ~~删除线~~ [字](网址)；
// 记号要成对才算：找不到收尾的照字面显示；* 后面是空白的不算开头（「2 * 3」不变斜体），单个 _ 一律照字面（snake_case）。
// 行内记号只在一行里配对。块级（2026-10-29 用户反馈「结果没解析 Markdown」：大模型照原文保留了标题、列表）：
// # 标题 → 粗体，- * + 列表 → •，> 引用 → 淡色，--- 分隔线 → 一段淡色横线，``` 围栏里的行 → 等宽、不解析（围栏行本身去掉）；
// 编号列表本来就好读，原样。换行原样保留。
// ponytail: 表格、任务框、嵌套引用的层级都按普通行显示；真要整套 Markdown 再换成按块排的视图。
using System.Text;

namespace KittyTools.Core;

public readonly record struct MarkdownSpan(
    string Text,
    bool Bold = false,
    bool Italic = false,
    bool Code = false,
    bool Strike = false,
    string? Link = null,
    bool Dim = false);

public static class InlineMarkdown
{
    private const string RuleLine = "────────";

    private enum Block
    {
        Plain,
        Heading,
        Bullet,
        Quote,
        Rule,
    }

    /// <summary>有没有值得按 Markdown 显示的记号（mac ProviderCardView.hasMarkdown，另加块级的行首记号）。</summary>
    public static bool Has(string text)
        => text.Contains("**", StringComparison.Ordinal) || text.Contains("__", StringComparison.Ordinal) ||
           text.Contains('`') || text.Contains("](", StringComparison.Ordinal) ||
           text.Split('\n').Any(line => Classify(line.TrimEnd('\r')).Kind != Block.Plain);

    public static List<MarkdownSpan> Parse(string text)
    {
        var spans = new List<MarkdownSpan>();
        var fenced = false;
        var first = true;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.TrimStart().StartsWith("```", StringComparison.Ordinal))
            {
                fenced = !fenced;
                continue;
            }

            if (!first)
            {
                spans.Add(new MarkdownSpan("\n"));
            }

            first = false;
            if (fenced)
            {
                if (line.Length > 0)
                {
                    spans.Add(new MarkdownSpan(line, Code: true));
                }

                continue;
            }

            var (kind, prefix, body) = Classify(line);
            if (prefix.Length > 0)
            {
                spans.Add(new MarkdownSpan(prefix, Dim: kind == Block.Rule));
            }

            var start = spans.Count;
            Inline(body, spans);
            for (var index = start; index < spans.Count; index++)
            {
                if (kind == Block.Heading)
                {
                    spans[index] = spans[index] with { Bold = true };
                }
                else if (kind == Block.Quote)
                {
                    spans[index] = spans[index] with { Dim = true };
                }
            }
        }

        return spans;
    }

    /// <summary>一行是哪种块：prefix 是替换行首记号后显示的字（列表的缩进 + •、分隔线），body 是剩下要按行内解析的。</summary>
    private static (Block Kind, string Prefix, string Body) Classify(string line)
    {
        var indent = line.Length - line.TrimStart(' ', '\t').Length;
        var rest = line[indent..];
        var hashes = rest.Length - rest.TrimStart('#').Length;
        if (hashes is >= 1 and <= 6 && (rest.Length == hashes || rest[hashes] == ' '))
        {
            return (Block.Heading, string.Empty, rest[hashes..].Trim());
        }

        var compact = rest.Replace(" ", string.Empty, StringComparison.Ordinal);
        if (compact.Length >= 3 && compact.All(character => character == compact[0]) && compact[0] is '-' or '*' or '_')
        {
            return (Block.Rule, RuleLine, string.Empty);
        }

        if (rest.Length >= 2 && rest[0] is '-' or '*' or '+' && rest[1] == ' ')
        {
            return (Block.Bullet, line[..indent] + "• ", rest[2..]);
        }

        if (rest.StartsWith('>'))
        {
            return (Block.Quote, string.Empty, rest.TrimStart('>', ' '));
        }

        return (Block.Plain, string.Empty, line);
    }

    private static void Inline(string text, List<MarkdownSpan> spans)
    {
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
