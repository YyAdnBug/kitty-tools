// 翻译语言：应用内语言、按书写系统检测、源 / 目标解析规则（纯函数，配单测）。
// 模型参照 Bob / Easydict：源 = 自动或固定；目标 = 自动或固定；设置里只有第一 / 第二语言。
// - 目标「自动」：原文是第一语言就译成第二语言，否则译成第一语言；
// - 源自动、固定目标正好是原文语言：改按「自动」译，并在界面上写明（FellBack）；
// - 源和目标都固定且相同（旧设置留下的）：目标按「自动」处理。
// Windows 没有 NaturalLanguage：只按书写系统认（拉丁字母一律算英文），见 PLAN §7.1。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum Lang
{
    ZhHans,
    ZhHant,
    En,
    Ja,
    Ko,
    Fr,
    De,
    Es,
    Ru,
    Pt,
    It,
}

public readonly record struct LangPlan(Lang? From, Lang To, bool FellBack);

public static partial class Langs
{
    public static string Code(this Lang lang) => lang switch
    {
        Lang.ZhHans => "zh-Hans",
        Lang.ZhHant => "zh-Hant",
        Lang.En => "en",
        Lang.Ja => "ja",
        Lang.Ko => "ko",
        Lang.Fr => "fr",
        Lang.De => "de",
        Lang.Es => "es",
        Lang.Ru => "ru",
        Lang.Pt => "pt",
        Lang.It => "it",
        _ => "en",
    };

    public static Lang? FromCode(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return null;
        }

        return code.Trim().ToLowerInvariant() switch
        {
            "zh-hans" or "zh-cn" or "zh" => Lang.ZhHans,
            "zh-hant" or "zh-tw" or "zh-hk" => Lang.ZhHant,
            "en" or "en-us" or "en-gb" => Lang.En,
            "ja" or "ja-jp" => Lang.Ja,
            "ko" or "ko-kr" => Lang.Ko,
            "fr" or "fr-fr" => Lang.Fr,
            "de" or "de-de" => Lang.De,
            "es" or "es-es" => Lang.Es,
            "ru" or "ru-ru" => Lang.Ru,
            "pt" or "pt-br" or "pt-pt" => Lang.Pt,
            "it" or "it-it" => Lang.It,
            _ => null,
        };
    }

    public static string Title(this Lang lang) => lang switch
    {
        Lang.ZhHans => "简体中文",
        Lang.ZhHant => "繁体中文",
        Lang.En => "英语",
        Lang.Ja => "日语",
        Lang.Ko => "韩语",
        Lang.Fr => "法语",
        Lang.De => "德语",
        Lang.Es => "西班牙语",
        Lang.Ru => "俄语",
        Lang.Pt => "葡萄牙语",
        Lang.It => "意大利语",
        _ => "英语",
    };

    public static string EnglishName(this Lang lang) => lang switch
    {
        Lang.ZhHans => "Simplified Chinese",
        Lang.ZhHant => "Traditional Chinese",
        Lang.En => "English",
        Lang.Ja => "Japanese",
        Lang.Ko => "Korean",
        Lang.Fr => "French",
        Lang.De => "German",
        Lang.Es => "Spanish",
        Lang.Ru => "Russian",
        Lang.Pt => "Portuguese",
        Lang.It => "Italian",
        _ => "English",
    };

    /// <summary>同一种语言（简繁中文算同一种）。</summary>
    public static bool SameLanguage(this Lang lang, Lang other)
        => lang == other || (IsChinese(lang) && IsChinese(other));

    public static bool IsChinese(this Lang lang) => lang is Lang.ZhHans or Lang.ZhHant;

    /// <summary>
    /// 按书写系统检测：假名 → 日文；谚文 → 韩文；汉字 → 中文；西里尔 → 俄文；拉丁字母 → 英文。
    /// 中日韩文里夹英文词时，CJK 字数不少于拉丁词数就只看 CJK 部分。
    /// 纯数字 / 符号返回 null。preferring 用来在简繁之间、以及两种 CJK 之外挑一个（比如汉字夹日文假名已经判日文）。
    /// </summary>
    public static Lang? Detect(string text, IReadOnlyList<Lang>? preferring = null)
    {
        var sample = text.Length > 2000 ? text[..2000] : text;
        var kana = Count(sample, KanaRegex());
        var hangul = Count(sample, HangulRegex());
        var han = Count(sample, HanRegex());
        var cyrillic = Count(sample, CyrillicRegex());
        var latinWords = LatinWordRegex().Matches(sample).Count;
        var latinLetters = Count(sample, LatinRegex());

        var cjk = kana + hangul + han;
        // 中日韩文里夹英文词：CJK 占多数才只看 CJK 部分；拉丁词多就按拉丁字母算英文。
        var cjkDominant = cjk > 0 && cjk >= latinWords;
        if (cjkDominant)
        {
            var onlyCjk = StripLatin(sample);
            kana = Count(onlyCjk, KanaRegex());
            hangul = Count(onlyCjk, HangulRegex());
            han = Count(onlyCjk, HanRegex());

            if (kana > 0)
            {
                return Lang.Ja;
            }

            if (hangul > 0)
            {
                return Lang.Ko;
            }

            if (han > 0)
            {
                return PreferChinese(preferring) ?? Lang.ZhHans;
            }
        }

        if (cyrillic > 0)
        {
            return Lang.Ru;
        }

        if (latinLetters > 0)
        {
            return Lang.En;
        }

        return null;
    }

    /// <summary>两个选成同一种时第二语言退回英语（第一语言是英语就退回简体中文）。</summary>
    public static (Lang First, Lang Second) Pair(string? firstCode, string? secondCode)
    {
        var first = FromCode(firstCode) ?? Lang.ZhHans;
        var second = FromCode(secondCode) ?? Lang.En;
        if (second.SameLanguage(first))
        {
            second = first == Lang.En ? Lang.ZhHans : Lang.En;
        }

        return (first, second);
    }

    /// <summary>
    /// source：null = 自动检测；target：null = 自动（第一 ⇄ 第二语言）。
    /// 只比同一种写法：原文简体、目标繁体是用户要的转换，不算「同语言」。
    /// </summary>
    public static LangPlan Resolve(
        Lang? source,
        Lang? target,
        Lang? detected,
        Lang first,
        Lang second)
    {
        var original = source ?? detected;
        var auto = original?.SameLanguage(first) == true ? second : first;
        if (target is null || target == source)
        {
            return new LangPlan(source, auto, false);
        }

        if (source is null && original == target)
        {
            return new LangPlan(null, auto, true);
        }

        return new LangPlan(source, target.Value, false);
    }

    /// <summary>复制即译的过滤条件（PLAN §7.4）：网址、单行路径、纯数字 / 符号都跳过。</summary>
    public static bool IsUrlLike(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Any(char.IsWhiteSpace))
        {
            return false;
        }

        return trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
               || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
               || trimmed.StartsWith("file://", StringComparison.OrdinalIgnoreCase)
               || trimmed.StartsWith("www.", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsPathLike(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Contains('\n') || trimmed.Contains('\r'))
        {
            return false;
        }

        return trimmed.StartsWith('/') || trimmed.StartsWith("~/", StringComparison.Ordinal)
               || trimmed.StartsWith(@"\\", StringComparison.Ordinal)
               || (trimmed.Length > 2 && char.IsAsciiLetter(trimmed[0]) && trimmed[1] == ':' &&
                   (trimmed[2] == '\\' || trimmed[2] == '/'));
    }

    private static Lang? PreferChinese(IReadOnlyList<Lang>? preferring)
    {
        if (preferring is null)
        {
            return null;
        }

        foreach (var lang in preferring)
        {
            if (IsChinese(lang))
            {
                return lang;
            }
        }

        return null;
    }

    private static string StripLatin(string text) => LatinStripRegex().Replace(text, " ");

    private static int Count(string text, Regex regex) => regex.Matches(text).Count;

    [GeneratedRegex(@"[\p{IsHiragana}\p{IsKatakana}]")]
    private static partial Regex KanaRegex();

    [GeneratedRegex(@"[\p{IsHangulSyllables}\p{IsHangulJamo}]")]
    private static partial Regex HangulRegex();

    [GeneratedRegex(@"[\p{IsCJKUnifiedIdeographs}]")]
    private static partial Regex HanRegex();

    [GeneratedRegex(@"[\p{IsCyrillic}]")]
    private static partial Regex CyrillicRegex();

    [GeneratedRegex(@"[A-Za-z]+")]
    private static partial Regex LatinWordRegex();

    [GeneratedRegex(@"[A-Za-z]")]
    private static partial Regex LatinRegex();

    [GeneratedRegex(@"[A-Za-z0-9]+")]
    private static partial Regex LatinStripRegex();
}
