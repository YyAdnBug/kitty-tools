// 打关键词展开片段认关键词的那一小段（照 mac SnippetExpand/KeyBuffer.swift，PLAN-v26 C5；纯状态，配单测）：最近打的字、哪些键让它清空、
// 打完一个字时末尾是不是某个关键词。
// - 只留最长的关键词再多一个字（Capacity），多了从前面丢；不存盘、不进日志
// - 打字：按键盘布局给的字（App 用 ToUnicodeEx 按前台程序的布局换）往后接；Backspace 去掉最后一个；空的（死键的第一下）不动
// - 清空：方向键、回车、Tab、Esc、Delete、Home / End / 翻页、F 键、带 Ctrl / Win 的组合（AltGr = Ctrl + Alt 打出字的照常算字）、
//   控制字符、换了前台窗口（调用方管）
// - 认：末尾正好是某个关键词，而且它前面一个字不是字母或数字（只在词首；清空过之后前面是什么不知道，算词首）；
//   几个都对得上时取最长的。认出来之后清空，免得接着打又认一次
namespace KittyTools.Core;

public sealed class SnippetKeyBuffer
{
    public enum KeyKind
    {
        /// <summary>出字的键（布局给的字）。</summary>
        Characters,
        Backspace,

        /// <summary>让前面的字作废。</summary>
        Reset,

        /// <summary>不管（死键的第一下、只按修饰键）。</summary>
        Ignore,
    }

    public readonly record struct Key(KeyKind Kind, string Characters = "");

    /// <summary>留多少个字：最长的关键词再多一个（要看它前面那一个字是不是字母、数字）。</summary>
    public int Capacity { get; init; } = SnippetKeyword.MaxLength + 1;

    public string Text { get; private set; } = string.Empty;

    /// <summary>按下的键分类：虚拟键码、修饰键、布局给的字。</summary>
    public static Key Classify(uint virtualKey, bool control, bool alt, bool win, string characters)
    {
        // AltGr（欧洲布局 = Ctrl + Alt）打出来的是字，照常算
        var altGr = control && alt && characters.Length > 0 && !characters.Any(char.IsControl);
        if ((control || win) && !altGr)
        {
            return new Key(KeyKind.Reset);
        }

        switch (virtualKey)
        {
            case 0x08: // Backspace
                return new Key(KeyKind.Backspace);
            case 0x2E or 0x25 or 0x26 or 0x27 or 0x28 or 0x24 or 0x23 or 0x21 or 0x22 or 0x0D or 0x09 or 0x1B or 0x2F:
                // Delete、方向键、Home / End、翻页、回车、Tab、Esc、Help
                return new Key(KeyKind.Reset);
            case >= 0x70 and <= 0x87: // F1–F24
                return new Key(KeyKind.Reset);
        }

        if (characters.Length == 0)
        {
            return new Key(KeyKind.Ignore);
        }

        return characters.Any(c => c < 0x20 || c == 0x7F) ? new Key(KeyKind.Reset) : new Key(KeyKind.Characters, characters);
    }

    /// <summary>按下一个键；打完一个字时末尾是某个关键词就给它（并清空），别的时候 null。</summary>
    public string? Press(Key key, IReadOnlySet<string> keywords)
    {
        switch (key.Kind)
        {
            case KeyKind.Characters:
                Text += key.Characters;
                if (Text.Length > Capacity)
                {
                    Text = Text[^Capacity..];
                }

                if (Match(keywords) is not { } keyword)
                {
                    return null;
                }

                Text = string.Empty;
                return keyword;
            case KeyKind.Backspace:
                if (Text.Length > 0)
                {
                    Text = Text[..^1];
                }

                break;
            case KeyKind.Reset:
                Text = string.Empty;
                break;
        }

        return null;
    }

    public void Reset() => Text = string.Empty;

    /// <summary>末尾是哪个关键词（在词首；几个都对得上取最长的，一样长取字典序大的，同 mac）。</summary>
    public string? Match(IReadOnlySet<string> keywords)
    {
        string? best = null;
        foreach (var keyword in keywords)
        {
            if (!Text.EndsWith(keyword, StringComparison.Ordinal))
            {
                continue;
            }

            var before = Text.Length - keyword.Length - 1;
            if (before >= 0 && char.IsLetterOrDigit(Text[before]))
            {
                continue;
            }

            if (best is null || keyword.Length > best.Length || (keyword.Length == best.Length && string.CompareOrdinal(keyword, best) > 0))
            {
                best = keyword;
            }
        }

        return best;
    }
}
