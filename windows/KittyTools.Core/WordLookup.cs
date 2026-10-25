// 查词（单词模式）的判断（第三版 §3.4，纯函数 + 单测，规则照 mac 的 Translate/WordLookup.swift 的 isWord）：
// 字母文字 1–3 个词、总长 ≤ 40；中日文 1–4 个字（不含标点和空白）。是「一个词」时，
// 智谱和 AI 服务改用单词模式的提示词；结果不自动复制、不给「替换原文」。
namespace KittyTools.Core;

public static class WordLookup
{
    public const int MaxLatinLength = 40;

    public const int MaxCjkLength = 4;

    public static bool IsWord(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var value = text.Trim();
        if (value.Length == 0)
        {
            return false;
        }

        var cjk = value.Count(ch => IsCjk(ch));
        if (cjk > 0)
        {
            // 中日文：整条都是 1–4 个字（没有空格、标点、字母数字混着）。
            return cjk == value.Length && value.Length <= MaxCjkLength;
        }

        if (value.Length > MaxLatinLength)
        {
            return false;
        }

        if (value.Any(ch => !char.IsLetter(ch) && ch != '-' && ch != '\'' && ch != ' '))
        {
            return false;
        }

        var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length is >= 1 and <= 3;
    }

    private static bool IsCjk(char ch)
        => ch is >= '\u3040' and <= '\u30FF'      // 日文假名
            or >= '\u3400' and <= '\u4DBF'        // 扩展 A
            or >= '\u4E00' and <= '\u9FFF'        // 常用汉字
            or >= '\uF900' and <= '\uFAFF'        // 兼容汉字
            or >= '\uAC00' and <= '\uD7AF';       // 韩文
}
