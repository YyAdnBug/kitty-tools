// 翻译语言：应用内语言、按书写系统检测、源 / 目标解析规则（纯函数，配单测）。
// 模型参照 Bob / Easydict：源 = 自动或固定；目标 = 自动或固定；设置里只有第一 / 第二语言。
// - 目标「自动」：原文是第一语言就译成第二语言，否则译成第一语言；
// - 源自动、固定目标正好是原文语言：改按「自动」译，并在界面上写明（FellBack）；
// - 源和目标都固定且相同（旧设置留下的）：目标按「自动」处理。
// Windows 没有 NaturalLanguage：按书写系统认，见 PLAN §7.1；拉丁字母的那一段交给调用方给的识别（App 里是系统的 ELS 语言识别，
// PLAN-v11 C8，以前一律算英文），认不出、太短时按英文。
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

    // PLAN-v26 T1（mac 0.10.0 X1）：常用的 30 种。新的只能加在末尾（浮窗、设置里的列表按这个顺序；代码存进设置、历史和同步）
    Vi,
    Th,
    Id,
    Ms,
    Ar,
    Tr,
    Hi,
    Nl,
    Pl,
    Uk,
    Sv,
    Da,
    Fi,
    Nb,
    Cs,
    El,
    He,
    Hu,
    Ro,
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
        Lang.Vi => "vi",
        Lang.Th => "th",
        Lang.Id => "id",
        Lang.Ms => "ms",
        Lang.Ar => "ar",
        Lang.Tr => "tr",
        Lang.Hi => "hi",
        Lang.Nl => "nl",
        Lang.Pl => "pl",
        Lang.Uk => "uk",
        Lang.Sv => "sv",
        Lang.Da => "da",
        Lang.Fi => "fi",
        Lang.Nb => "nb",
        Lang.Cs => "cs",
        Lang.El => "el",
        Lang.He => "he",
        Lang.Hu => "hu",
        Lang.Ro => "ro",
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
            "vi" or "vi-vn" => Lang.Vi,
            "th" or "th-th" => Lang.Th,
            "id" or "in" => Lang.Id,
            "ms" or "ms-my" => Lang.Ms,
            "ar" or "ar-sa" => Lang.Ar,
            "tr" or "tr-tr" => Lang.Tr,
            "hi" or "hi-in" => Lang.Hi,
            "nl" or "nl-nl" => Lang.Nl,
            "pl" or "pl-pl" => Lang.Pl,
            "uk" or "uk-ua" => Lang.Uk,
            "sv" or "sv-se" => Lang.Sv,
            "da" or "da-dk" => Lang.Da,
            "fi" or "fi-fi" => Lang.Fi,
            "nb" or "no" or "nn" or "nb-no" or "no-no" => Lang.Nb,
            "cs" or "cs-cz" => Lang.Cs,
            "el" or "el-gr" => Lang.El,
            "he" or "iw" => Lang.He,
            "hu" or "hu-hu" => Lang.Hu,
            "ro" or "ro-ro" => Lang.Ro,
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
        Lang.Vi => "越南语",
        Lang.Th => "泰语",
        Lang.Id => "印尼语",
        Lang.Ms => "马来语",
        Lang.Ar => "阿拉伯语",
        Lang.Tr => "土耳其语",
        Lang.Hi => "印地语",
        Lang.Nl => "荷兰语",
        Lang.Pl => "波兰语",
        Lang.Uk => "乌克兰语",
        Lang.Sv => "瑞典语",
        Lang.Da => "丹麦语",
        Lang.Fi => "芬兰语",
        Lang.Nb => "挪威语",
        Lang.Cs => "捷克语",
        Lang.El => "希腊语",
        Lang.He => "希伯来语",
        Lang.Hu => "匈牙利语",
        Lang.Ro => "罗马尼亚语",
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
        Lang.Vi => "Vietnamese",
        Lang.Th => "Thai",
        Lang.Id => "Indonesian",
        Lang.Ms => "Malay",
        Lang.Ar => "Arabic",
        Lang.Tr => "Turkish",
        Lang.Hi => "Hindi",
        Lang.Nl => "Dutch",
        Lang.Pl => "Polish",
        Lang.Uk => "Ukrainian",
        Lang.Sv => "Swedish",
        Lang.Da => "Danish",
        Lang.Fi => "Finnish",
        Lang.Nb => "Norwegian",
        Lang.Cs => "Czech",
        Lang.El => "Greek",
        Lang.He => "Hebrew",
        Lang.Hu => "Hungarian",
        Lang.Ro => "Romanian",
        _ => "English",
    };

    /// <summary>朗读用的 BCP-47（同 mac Lang.speechCode）：挑系统声音时按它的语言部分对。</summary>
    public static string SpeechCode(this Lang lang) => lang switch
    {
        Lang.ZhHans => "zh-CN",
        Lang.ZhHant => "zh-TW",
        Lang.En => "en-US",
        Lang.Ja => "ja-JP",
        Lang.Ko => "ko-KR",
        Lang.Fr => "fr-FR",
        Lang.De => "de-DE",
        Lang.Es => "es-ES",
        Lang.Ru => "ru-RU",
        Lang.Pt => "pt-BR",
        Lang.It => "it-IT",
        Lang.Vi => "vi-VN",
        Lang.Th => "th-TH",
        Lang.Id => "id-ID",
        Lang.Ms => "ms-MY",
        Lang.Ar => "ar-SA",
        Lang.Tr => "tr-TR",
        Lang.Hi => "hi-IN",
        Lang.Nl => "nl-NL",
        Lang.Pl => "pl-PL",
        Lang.Uk => "uk-UA",
        Lang.Sv => "sv-SE",
        Lang.Da => "da-DK",
        Lang.Fi => "fi-FI",
        Lang.Nb => "nb-NO",
        Lang.Cs => "cs-CZ",
        Lang.El => "el-GR",
        Lang.He => "he-IL",
        Lang.Hu => "hu-HU",
        Lang.Ro => "ro-RO",
        _ => "en-US",
    };

    /// <summary>同一种语言（简繁中文算同一种）。</summary>
    public static bool SameLanguage(this Lang lang, Lang other)
        => lang == other || (IsChinese(lang) && IsChinese(other));

    public static bool IsChinese(this Lang lang) => lang is Lang.ZhHans or Lang.ZhHant;

    /// <summary>
    /// 按书写系统检测：假名 → 日文；谚文 → 韩文；汉字 → 中文；泰文、阿拉伯文、希伯来文、天城文、希腊文各是那一种；
    /// 西里尔 → 有乌克兰文独有的字母（і ї є ґ）或 latin 认出 uk 时乌克兰文、否则俄文；
    /// 拉丁字母 → latin 认出的那种（30 种里用拉丁字母的那些），没给 latin、认不出、不到 3 个词时 → 英文。
    /// 中日韩文里夹英文词时，CJK 字数不少于拉丁词数就只看 CJK 部分。
    /// 纯数字 / 符号返回 null。preferring 用来在简繁之间、以及两种 CJK 之外挑一个（比如汉字夹日文假名已经判日文）。
    /// latin：文本 → 最可能的语言标签（「fr」「de-DE」），认不出返回 null（PLAN-v11 C8）。
    /// </summary>
    public static Lang? Detect(string text, IReadOnlyList<Lang>? preferring = null, Func<string, string?>? latin = null)
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

        // 别的书写系统：字数最多的那一种（PLAN-v26 T1）
        var scripts = new (Lang Lang, int Count)[]
        {
            (Lang.Th, Count(sample, ThaiRegex())),
            (Lang.Ar, Count(sample, ArabicRegex())),
            (Lang.He, Count(sample, HebrewRegex())),
            (Lang.Hi, Count(sample, DevanagariRegex())),
            (Lang.El, Count(sample, GreekRegex())),
            (Lang.Ru, cyrillic),
        };
        var script = scripts.MaxBy(item => item.Count);
        if (script.Count > 0)
        {
            if (script.Lang != Lang.Ru)
            {
                return script.Lang;
            }

            return Count(sample, UkrainianRegex()) > 0 ||
                   (latin?.Invoke(sample) is { } tag && tag.Split('-')[0].Equals("uk", StringComparison.OrdinalIgnoreCase))
                ? Lang.Uk
                : Lang.Ru;
        }

        if (latinLetters > 0)
        {
            return LatinLanguage(sample, latinWords, latin);
        }

        return null;
    }

    /// <summary>用拉丁字母写的那几种（30 种里）。</summary>
    private static readonly HashSet<Lang> LatinLangs = new()
    {
        Lang.En, Lang.Fr, Lang.De, Lang.Es, Lang.Pt, Lang.It, Lang.Vi, Lang.Id, Lang.Ms, Lang.Tr, Lang.Nl, Lang.Pl,
        Lang.Sv, Lang.Da, Lang.Fi, Lang.Nb, Lang.Cs, Lang.Hu, Lang.Ro,
    };

    /// <summary>
    /// 拉丁字母的原文是哪种：不到 3 个词不认（一两个词谁都认不准），认出的不是拉丁字母的那几种、或者不在 30 种里，都按英文。
    /// </summary>
    private static Lang LatinLanguage(string sample, int words, Func<string, string?>? latin)
    {
        if (words < 3 || latin?.Invoke(sample) is not { Length: > 0 } tag)
        {
            return Lang.En;
        }

        var primary = tag.Split('-')[0];
        return FromCode(primary) is { } lang && LatinLangs.Contains(lang) ? lang : Lang.En;
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

    [GeneratedRegex(@"[\p{IsThai}]")]
    private static partial Regex ThaiRegex();

    [GeneratedRegex(@"[\p{IsArabic}\p{IsArabicPresentationForms-A}\p{IsArabicPresentationForms-B}]")]
    private static partial Regex ArabicRegex();

    [GeneratedRegex(@"[\p{IsHebrew}]")]
    private static partial Regex HebrewRegex();

    [GeneratedRegex(@"[\p{IsDevanagari}]")]
    private static partial Regex DevanagariRegex();

    [GeneratedRegex(@"[\p{IsGreekandCoptic}\p{IsGreekExtended}]")]
    private static partial Regex GreekRegex();

    [GeneratedRegex(@"[іїєґІЇЄҐ]")]
    private static partial Regex UkrainianRegex();

    [GeneratedRegex(@"[A-Za-z]+")]
    private static partial Regex LatinWordRegex();

    [GeneratedRegex(@"[A-Za-z]")]
    private static partial Regex LatinRegex();

    [GeneratedRegex(@"[A-Za-z0-9]+")]
    private static partial Regex LatinStripRegex();
}
