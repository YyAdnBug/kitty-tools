// 长文分段翻译（照 mac Translate/LongText.swift，0.10.0 X2 = PLAN-v11 F2，PLAN-v26 T2）：大模型一次只能出 max_tokens 那么多
// （内置智谱 1024，ZhipuProvider.MaxTokens），原文估出来的译文超过它的六成时，按段（空行、换行）切开、一段太长再按句、还长就硬切，
// 依次翻、接着显示在同一张卡里。流的约定照旧：每次给出到目前为止的整段译文（前面翻完的段 + 段间原来的空白 + 这一段到目前为止的）；
// 某一段被截断或出错就停在那里（截断的卡照常显示半截、标「只翻了前一部分」）。单词模式、传统接口（没有输出 token 上限）、讲解不切。
// ponytail: 译文 token 按「中日韩泰文一字一个、别的字三个一个」估，阿拉伯文、印地文这类一个字更费 token 的语言还可能被截断（卡片照常标出来）；
// 真要准就按各家的分词器算。段与段各翻各的，前后文不互相看到。
// 纯函数，单测 LongTextTests（期望值照 mac TranslateTests）；按 Unicode 标量算（同 Swift unicodeScalars），一个字素当一个字切。
using System.Globalization;
using System.Text;

namespace KittyTools.Core;

public static class LongText
{
    /// <summary>切开的一段：发给服务的字 + 它后面原文里的空白（拼译文时原样接回去）。</summary>
    public readonly record struct Piece(string Text, string Separator);

    /// <summary>一段最多估多少 token 的译文：输出上限的六成（留出译文比原文长、估得不准的余量）。</summary>
    public static double Budget(int outputTokens) => outputTokens * 0.6;

    /// <summary>估这段字翻出来大约多少 token（按三分之一个 token 数整数再除，免得一个个 1/3 加出 1.9999…）。</summary>
    public static double Weight(string text)
    {
        var thirds = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                continue;
            }

            thirds += IsDense(rune.Value) ? 3 : 1;
        }

        return thirds / 3.0;
    }

    /// <summary>一个字差不多就是一个 token 的文字：汉字、假名、谚文、泰文。</summary>
    private static bool IsDense(int value)
        => value is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF
            or >= 0x0E00 and <= 0x0E7F or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x2FA1F;

    /// <summary>切成每段都不超过 budget 的几段；不超过的整段返回一段。各段 Text + Separator 依次拼起来就是原文。</summary>
    public static IReadOnlyList<Piece> Split(string text, double budget)
    {
        if (Weight(text) <= budget)
        {
            return new[] { new Piece(text, string.Empty) };
        }

        var pieces = new List<Piece>();
        var current = new StringBuilder();
        var currentWeight = 0.0;
        foreach (var atom in Atoms(text, budget))
        {
            var weight = Weight(atom);
            if (current.Length > 0 && currentWeight + weight > budget)
            {
                pieces.Add(ToPiece(current.ToString()));
                current.Clear();
                currentWeight = 0;
            }

            current.Append(atom);
            currentWeight += weight;
        }

        if (current.Length > 0)
        {
            pieces.Add(ToPiece(current.ToString()));
        }

        return pieces;
    }

    /// <summary>把末尾的空白拆成 Separator。</summary>
    private static Piece ToPiece(string chunk)
    {
        var end = chunk.Length;
        while (end > 0 && char.IsWhiteSpace(chunk[end - 1]))
        {
            end--;
        }

        return new Piece(chunk[..end], chunk[end..]);
    }

    private static bool IsNewline(char c) => c is '\n' or '\r' or '\u2028' or '\u2029' or '\u0085' or '\u000B' or '\u000C';

    /// <summary>最小的单位：一行（带后面的换行）；一行超过 budget 的拆成句子，一句还超过的按字硬切。每个单位带着它后面的空白。</summary>
    private static IEnumerable<string> Atoms(string text, double budget)
    {
        var lines = new List<string>();
        var line = new StringBuilder();
        foreach (var c in text)
        {
            if (IsNewline(c))
            {
                line.Append(c);
                continue;
            }

            if (line.Length > 0 && IsNewline(line[^1]))
            {
                lines.Add(line.ToString());
                line.Clear();
            }

            line.Append(c);
        }

        if (line.Length > 0)
        {
            lines.Add(line.ToString());
        }

        return lines.SelectMany(item => Weight(item) > budget
            ? Sentences(item).SelectMany(sentence => HardSplit(sentence, budget))
            : new[] { item });
    }

    private const string ClosingAfterEnd = "”’」』)）\"'";
    private const string ClosingAfterDot = "”’\"')";

    /// <summary>按句末标点切：中日文的 。！？ 直接切；. ! ? 后面跟空白才算句末（3.14、e.g.x 不切）。句末的引号、括号和后面的空白跟着这一句。</summary>
    public static IReadOnlyList<string> Sentences(string line)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        var ended = false;
        for (var index = 0; index < line.Length; index++)
        {
            var c = line[index];
            if (ended && !(char.IsWhiteSpace(c) || ClosingAfterEnd.Contains(c)))
            {
                result.Add(current.ToString());
                current.Clear();
                ended = false;
            }

            current.Append(c);
            if (c is '。' or '！' or '？')
            {
                ended = true;
            }
            else if (c is '.' or '!' or '?')
            {
                var next = index + 1 < line.Length ? line[index + 1] : ' ';
                if (char.IsWhiteSpace(next) || ClosingAfterDot.Contains(next))
                {
                    ended = true;
                }
            }
        }

        if (current.Length > 0)
        {
            result.Add(current.ToString());
        }

        return result;
    }

    /// <summary>一句还超过 budget：按字（字素）切成几块（尽量在空白处断）。</summary>
    private static IEnumerable<string> HardSplit(string sentence, double budget)
    {
        if (Weight(sentence) <= budget)
        {
            return new[] { sentence };
        }

        var result = new List<string>();
        var current = new StringBuilder();
        var size = 0.0;
        var elements = StringInfo.GetTextElementEnumerator(sentence);
        while (elements.MoveNext())
        {
            var element = (string)elements.Current;
            var cost = Weight(element);
            if (size + cost > budget && current.Length > 0)
            {
                // 往回找最近的空白，在那里断（找不到就在这里断）
                var text = current.ToString();
                var space = LastWhiteSpace(text);
                if (space > 0)
                {
                    result.Add(text[..(space + 1)]);
                    current.Clear().Append(text[(space + 1)..]);
                }
                else
                {
                    result.Add(text);
                    current.Clear();
                }

                size = Weight(current.ToString());
            }

            current.Append(element);
            size += cost;
        }

        if (current.Length > 0)
        {
            result.Add(current.ToString());
        }

        return result;
    }

    private static int LastWhiteSpace(string text)
    {
        for (var index = text.Length - 1; index >= 0; index--)
        {
            if (char.IsWhiteSpace(text[index]))
            {
                return index;
            }
        }

        return -1;
    }
}
