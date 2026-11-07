// 识字的文字整理（纯函数，配单测）：按行框切段，段内的行接成一行。
// 中日文之间直接连、其它加一个空格；行尾是紧跟字母的连字符时，下一行小写开头是断开的单词（exam-/ple），
// 大写开头是复合词（State-/Of-the-art），连字符留着。空行是段落分隔。
// PLAN-v16（mac 2cd75c5b 的 OCR.groups）：列表项（• / 1. / ① 开头的行）另起一段；句末短行后面跟着的一行，第一个词在上一行剩下的
// 地方放不下（被长词挤断的）不算段落结尾。截图翻译的原位覆盖要每段的行框和词框，所以先按段分组行本身（Groups）。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>识字的一个词和它的框（像素、左上原点）。</summary>
public readonly record struct OcrWord(string Text, RectD Box);

/// <summary>识字的一行：文字 + 行框（像素、左上原点）+ 各个词（截图翻译认行内代码块用；别处不用可以不给）。</summary>
public readonly record struct OcrLine(string Text, RectD Box, IReadOnlyList<OcrWord>? Words = null);

public static partial class OcrText
{
    [GeneratedRegex(@"^(?:[•◦▪▫‣●○■□·・]|[-*–]\s|\d{1,3}[.)]\s|\d{1,3}、|[(（]\d{1,3}[)）]|[①-⑳])\s*")]
    private static partial Regex ListMarkerPattern();

    /// <summary>行首的列表记号（连同后面的空白）；不是列表项时 null（mac OCR.listMarker）。</summary>
    public static string? ListMarker(string text) => ListMarkerPattern().Match(text) is { Success: true } match ? match.Value : null;

    public static List<List<string>> Paragraphs(IReadOnlyList<OcrLine> lines)
        => Groups(lines).Select(group => group.Select(line => line.Text).ToList()).ToList();

    /// <summary>按段分组的行本身（mac OCR.groups）：截图翻译要每段的行框。</summary>
    public static List<List<OcrLine>> Groups(IReadOnlyList<OcrLine> lines)
    {
        var result = new List<List<OcrLine>>();
        if (lines.Count == 0)
        {
            return result;
        }

        var heights = lines.Select(line => line.Box.Height).OrderBy(value => value).ToList();
        var widths = lines.Select(line => line.Box.Width).OrderBy(value => value).ToList();
        var rights = lines.Select(line => line.Box.Right).OrderBy(value => value).ToList();
        var lineHeight = heights[heights.Count / 2];
        var lineWidth = widths[widths.Count / 2];
        var lineRight = rights[rights.Count / 2];
        OcrLine? previous = null;
        foreach (var line in lines)
        {
            if (previous is { } last)
            {
                var gap = line.Box.Y - last.Box.Bottom;
                var endsSentence = last.Text.Length > 0 && "。！？.!?".Contains(last.Text[^1]);
                // 句末短行：上一行剩下的地方连下一行的第一个词都放得下，才是段落结尾；放不下说明是被长词挤断的
                var room = lineRight - last.Box.Right;
                var wrapped = line.Words is { Count: > 0 } words && IsLatin(words[0].Text) && words[0].Box.Width > room;
                var breaks = gap > 1.2 * lineHeight || gap < -0.5 * lineHeight ||
                             (endsSentence && last.Box.Width < 0.8 * lineWidth && !wrapped) ||
                             ListMarker(line.Text) is not null;
                if (breaks)
                {
                    result.Add(new List<OcrLine>());
                }
            }
            else
            {
                result.Add(new List<OcrLine>());
            }

            result[^1].Add(line);
            previous = line;
        }

        return result;
    }

    /// <summary>拉丁词（mac 的 words 只收字母、数字、下划线组成的词；中日文随便哪个字都能断行，不算挤断）。</summary>
    private static bool IsLatin(string text) => text.Length > 0 && char.IsAscii(text[0]) && char.IsLetterOrDigit(text[0]);

    /// <summary>段内接起来，段间用 separator（识字 \n，截图翻译 \n\n）；不接时一行一行原样。</summary>
    public static string Text(IReadOnlyList<OcrLine> lines, bool joined, string separator = "\n")
        => joined
            ? string.Join(separator, Paragraphs(lines).Select(paragraph => JoinLine(paragraph)))
            : string.Join("\n", lines.Select(line => line.Text));

    /// <summary>纯文本的「把同一段里的换行接起来」：空行分段，段内按 JoinLine 接。</summary>
    public static string JoiningLines(string text, string paragraphSeparator = "\n")
    {
        var paragraphs = System.Text.RegularExpressions.Regex.Split(
            text, @"\r?\n[ \t\r]*\n\s*");
        return string.Join(
            paragraphSeparator,
            paragraphs
                .Select(paragraph => JoinLine(paragraph.Split('\n')))
                .Where(joined => joined.Length > 0));
    }

    public static string JoinLine(IEnumerable<string> lines)
    {
        var joined = new System.Text.StringBuilder();
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (joined.Length == 0 || line.Length == 0)
            {
                joined.Append(line);
                continue;
            }

            var last = joined[^1];
            var first = line[0];
            if (last == '-' && joined.Length > 1 && char.IsLetter(joined[^2]))
            {
                if (char.IsLower(first))
                {
                    joined.Length--;
                }
            }
            else if (!(IsCjk(last) || IsCjk(first)))
            {
                joined.Append(' ');
            }

            joined.Append(line);
        }

        return joined.ToString();
    }

    public static bool IsCjk(char character) => character is
        >= '\u3000' and <= '\u30FF' or
        >= '\u3400' and <= '\u4DBF' or
        >= '\u4E00' and <= '\u9FFF' or
        >= '\uF900' and <= '\uFAFF' or
        >= '\uFF00' and <= '\uFFEF';

    /// <summary>Windows 的识字会在汉字 / 假名之间插空格：两边都是 CJK 的空格去掉（英文词之间的保留）。</summary>
    public static string RemoveCjkSpaces(string text)
    {
        var builder = new System.Text.StringBuilder(text.Length);
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (char.IsWhiteSpace(character) && builder.Length > 0 && index + 1 < text.Length &&
                IsCjk(builder[^1]) && IsCjk(text[index + 1]))
            {
                continue;
            }

            builder.Append(character);
        }

        return builder.ToString();
    }
}
