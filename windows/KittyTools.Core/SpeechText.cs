// 朗读读哪段字、单词卡的读音行、真人录音的地址（PLAN-v14 V5–V7，照 mac Translate/Speaker.swift 的纯函数，单测照 SpeakerTests）：
// - ForCard：卡片右上角的喇叭只读译文。单词卡读第一行释义（跳过读音行、拼音行、「例 / Example / e.g.」开头的行，去掉行首
//   n. v. adj. & adv. 这类词性记号）；别的卡先去掉 Markdown 记号再读整段。
// - PhoneticLine：单词卡第一行整行只是「美 /…/」「英 /…/」时拆出读音和剩下的正文（流式中第一行没出完不拆）。
// - RecordingUrl：有道词典的真人录音，只给像英文词的（ASCII 字母、空格、连字符、撇号，1–3 个词、≤ 40 字），别的 null（用系统声音）。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum Accent
{
    Us,
    Uk,
}

public readonly record struct Phonetic(Accent Accent, string Text);

public static partial class SpeechText
{
    [GeneratedRegex(@"(美|英)\s*[/\[]([^/\[\]]+)[/\]]")]
    private static partial Regex PhoneticPattern();

    [GeneratedRegex(@"^(?:[A-Za-z]{1,6}\.\s*(?:&\s*[A-Za-z]{1,6}\.\s*)?)+")]
    private static partial Regex PartOfSpeech();

    [GeneratedRegex(@"^\s*(?:#{1,6}\s+|>\s?|[-*+]\s+)")]
    private static partial Regex BlockMarker();

    [GeneratedRegex(@"\[([^\]]*)\]\([^)]*\)")]
    private static partial Regex Link();

    private const string Tones = "āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ";

    /// <summary>卡片喇叭读的字（mac Speaker.speechText）。</summary>
    public static string ForCard(string result, bool wordStyle)
    {
        var plain = WithoutMarkdown(result);
        if (!wordStyle)
        {
            return plain;
        }

        var meaning = plain.Split('\n')
            .Select(line => line.Trim(' ', '\t', '\r'))
            .FirstOrDefault(line => line.Length > 0 && Phonetics(line) is null && !IsPinyinLine(line) &&
                                    !line.StartsWith('例') && !line.StartsWith("Example", StringComparison.Ordinal) &&
                                    !line.StartsWith("e.g.", StringComparison.Ordinal));
        if (meaning is null)
        {
            return plain;
        }

        var stripped = PartOfSpeech().Replace(meaning, string.Empty).Trim(' ', '\t');
        return stripped.Length == 0 ? meaning : stripped;
    }

    /// <summary>单词卡第一行是读音行时拆出来：读音和剩下的正文。第一行还没出完、或者不全是读音时为 null。</summary>
    public static (IReadOnlyList<Phonetic> Phonetics, string Body)? PhoneticLine(string text)
    {
        var newline = text.IndexOfAny(new[] { '\n', '\r' });
        if (newline < 0 || Phonetics(text[..newline]) is not { } phonetics)
        {
            return null;
        }

        var rest = text[(newline + 1)..];
        if (text[newline] == '\r' && rest.StartsWith('\n'))
        {
            rest = rest[1..];
        }

        return (phonetics, rest);
    }

    /// <summary>一行是不是只有「美 /…/」「英 /…/」（之间随便几个空白；粗体记号去掉再看）。</summary>
    private static List<Phonetic>? Phonetics(string line)
    {
        var value = line.Replace("**", string.Empty, StringComparison.Ordinal).Trim(' ', '\t');
        var matches = PhoneticPattern().Matches(value);
        if (matches.Count == 0 || PhoneticPattern().Replace(value, string.Empty).Trim(' ', '\t').Length > 0)
        {
            return null;
        }

        return matches.Select(match => new Phonetic(match.Groups[1].Value == "英" ? Accent.Uk : Accent.Us, match.Groups[2].Value)).ToList();
    }

    /// <summary>拼音行（汉译英单词卡的第一行 píngguǒ）：全是拼音字母、至少一个带声调。</summary>
    private static bool IsPinyinLine(string line)
        => line.Any(ch => Tones.Contains(ch)) &&
           line.ToLowerInvariant().All(ch => (char.IsAsciiLetter(ch)) || Tones.Contains(ch) || " -'ü".Contains(ch));

    /// <summary>去掉 Markdown 记号：粗体 / 斜体 / 代码的记号、链接只留文字、行首的 # &gt; - * + 和围栏行。</summary>
    public static string WithoutMarkdown(string text)
    {
        var lines = text.ReplaceLineEndings("\n").Split('\n')
            .Where(line => !line.Trim(' ', '\t').StartsWith("```", StringComparison.Ordinal))
            .Select(line =>
            {
                var value = BlockMarker().Replace(line, string.Empty);
                value = Link().Replace(value, match => match.Groups[1].Value);
                return value.Replace("**", string.Empty, StringComparison.Ordinal)
                    .Replace("__", string.Empty, StringComparison.Ordinal)
                    .Replace("`", string.Empty, StringComparison.Ordinal);
            });
        return string.Join("\n", lines).Trim();
    }

    /// <summary>有道词典的真人录音地址（type 1 英、2 美）；不像英文词的 null。</summary>
    public static Uri? RecordingUrl(string word, Accent accent)
    {
        var value = word.Trim();
        var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (value.Length == 0 || value.Length > 40 || words.Length is < 1 or > 3 ||
            !value.All(ch => char.IsAsciiLetter(ch) || " -'’".Contains(ch)))
        {
            return null;
        }

        return new Uri("https://dict.youdao.com/dictvoice?audio=" + Uri.EscapeDataString(value) +
                       "&type=" + (accent == Accent.Uk ? "1" : "2"));
    }

    /// <summary>一个单词在「正在读」里的标识：同一个词的美音、英音分开亮。</summary>
    public static string Key(string word, Accent accent) => word + "\u001F" + (accent == Accent.Uk ? "uk" : "us");

    /// <summary>
    /// 原文是一个英文词时返回它（mac TranslatePanelView.englishWord）：字母文字的一个词、全是 ASCII、检测或固定的源语言是英语
    /// （认不出时也算）。原文框的喇叭、单词卡的读音行拿它放真人发音；不是就 null（用系统声音、不出读音行）。
    /// </summary>
    public static string? EnglishWord(string? text, Lang? source)
    {
        var word = text?.Trim() ?? string.Empty;
        return WordLookup.IsWord(word) && word.All(char.IsAscii) && (source ?? Lang.En) == Lang.En ? word : null;
    }

    /// <summary>设置值 → 口音（只认 uk，别的都是美音）。</summary>
    public static Accent ParseAccent(string? value) => value == "uk" ? Accent.Uk : Accent.Us;
}
