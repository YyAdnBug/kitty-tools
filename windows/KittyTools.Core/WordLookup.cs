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

    /// <summary>
    /// 单词模式提示词里的示例词条（mac WordLookup.example：照着示例写比照着说明写稳得多，免费的 glm-4-flash 会把说明原样抄出来）。
    /// 释义是中文时拿英文词 run 做例子，其它语言拿中文词 苹果 做例子。
    /// </summary>
    public static (string Word, string Entry) Example(Lang target)
        => target.SameLanguage(Lang.ZhHans)
            ? ("run", "美 /rʌn/  英 /rʌn/\nv. 跑；奔跑；运转；经营\nn. 跑步；一段时间；连续\n例：I run every morning. 我每天早上跑步。")
            : ("苹果", "píngguǒ\nn. apple; apple tree\nExample: 我每天吃一个苹果。 I eat an apple every day.");

    /// <summary>智谱的单词模式提示词（中文，mac Zhipu.stream）。</summary>
    public static string ZhipuPrompt(string word, Lang target)
    {
        var (exampleWord, entry) = Example(target);
        return $"你是一部简明词典。把输入的词写成一条词条，释义用{target.Title()}，格式和示例完全一样：第一行读音，" +
               "然后每个词性一行，最后一到两行例句。只输出词条本身，不要任何说明。\n\n" +
               $"输入：{exampleWord}\n输出：\n{entry}\n\n输入：{word}\n输出：";
    }

    /// <summary>大模型服务的单词模式系统提示词（英文，mac AIService.wordPrompt）。</summary>
    public static string AiPrompt(Lang target)
    {
        var (exampleWord, entry) = Example(target);
        return "You are a concise bilingual dictionary. Write the user's word as one dictionary entry with meanings in " +
               $"{target.EnglishName()}, in exactly the same format as the example: pronunciation on the first line, one line " +
               "per part of speech, then one or two example sentences with translations. Output only the entry.\n\n" +
               $"Example input: {exampleWord}\nExample output:\n{entry}";
    }

    private static bool IsCjk(char ch)
        => ch is >= '\u3040' and <= '\u30FF'      // 日文假名
            or >= '\u3400' and <= '\u4DBF'        // 扩展 A
            or >= '\u4E00' and <= '\u9FFF'        // 常用汉字
            or >= '\uF900' and <= '\uFAFF'        // 兼容汉字
            or >= '\uAC00' and <= '\uD7AF';       // 韩文
}
