// 有道词典（PLAN-v14 V4，照 mac Translate/Providers/FreeProviders.swift 的 YoudaoDict.entry）：网页版查词接口返回的 JSON
// 写成单词卡的样子（纯函数，配单测）。英汉 = 「美 /…/  英 /…/」+ 每个词性一行 + 「变形：…；…」+ 「例：英文 中文」；
// 汉英 = 拼音一行 + 每条「pos 文字」。只有读音、没有释义的算没查到（null）。
// 非官方接口：哪天改了格式就是「有道词典里没有这个词」，再来修。
using System.Text;
using System.Text.Json;

namespace KittyTools.Core;

public static class YoudaoDict
{
    /// <summary>请求地址（只要英汉、汉英、双语例句三节：整份 130 KB，这样约 5 KB）。</summary>
    public static Uri RequestUrl(string word)
        => new("https://dict.youdao.com/jsonapi?q=" + Uri.EscapeDataString(word.Trim()) + "&dicts=" +
               Uri.EscapeDataString("{\"count\":99,\"dicts\":[[\"ec\",\"ce\",\"blng_sents_part\"]]}"));

    public static string? Entry(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var lines = new List<string>();
        if (FirstWord(root, "ec") is { } ec)
        {
            var phonetics = new List<string>();
            foreach (var (label, key) in new[] { ("美", "usphone"), ("英", "ukphone") })
            {
                if (Str(ec, key) is { Length: > 0 } value)
                {
                    phonetics.Add($"{label} /{value}/");
                }
            }

            if (phonetics.Count > 0)
            {
                lines.Add(string.Join("  ", phonetics));
            }

            foreach (var tr in Array(ec, "trs"))
            {
                if (FirstLine(tr) is { } line && Array(line, "i").FirstOrDefault(item => item.ValueKind == JsonValueKind.String)
                        is { ValueKind: JsonValueKind.String } first && first.GetString() is { Length: > 0 } text)
                {
                    lines.Add(text);
                }
            }

            var forms = new List<string>();
            foreach (var item in Array(ec, "wfs"))
            {
                if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("wf", out var wf) &&
                    wf.ValueKind == JsonValueKind.Object && Str(wf, "name") is { } name && Str(wf, "value") is { } value)
                {
                    forms.Add($"{name} {value}");
                }
            }

            if (lines.Count > (phonetics.Count == 0 ? 0 : 1) && forms.Count > 0)
            {
                lines.Add("变形：" + string.Join("；", forms));
            }
        }
        else if (FirstWord(root, "ce") is { } ce)
        {
            if (Str(ce, "phone") is { Length: > 0 } phone)
            {
                lines.Add(phone);
            }

            foreach (var tr in Array(ce, "trs"))
            {
                if (FirstLine(tr) is not { } line)
                {
                    continue;
                }

                // i 是字符串和 {"#text": "name"} 混着的数组
                var text = new StringBuilder();
                foreach (var item in Array(line, "i"))
                {
                    if (item.ValueKind == JsonValueKind.String)
                    {
                        text.Append(item.GetString());
                    }
                    else if (item.ValueKind == JsonValueKind.Object && Str(item, "#text") is { } part)
                    {
                        text.Append(part);
                    }
                }

                var joined = text.ToString().Trim(' ', '\t');
                if (joined.Length == 0)
                {
                    continue;
                }

                var pos = Str(line, "pos") is { } value ? value + " " : string.Empty;
                lines.Add(pos + joined);
            }
        }

        // 只有读音、没有释义的不算查到
        if (!lines.Any(line => !line.StartsWith("美 /", StringComparison.Ordinal) && !line.StartsWith("英 /", StringComparison.Ordinal)))
        {
            return null;
        }

        if (root.TryGetProperty("blng_sents_part", out var sentences) && sentences.ValueKind == JsonValueKind.Object &&
            Array(sentences, "sentence-pair").FirstOrDefault() is { ValueKind: JsonValueKind.Object } pair &&
            Str(pair, "sentence") is { } sentence && Str(pair, "sentence-translation") is { } translation)
        {
            lines.Add($"例：{sentence} {translation}");
        }

        return string.Join("\n", lines);
    }

    private static JsonElement? FirstWord(JsonElement root, string section)
        => root.TryGetProperty(section, out var part) && part.ValueKind == JsonValueKind.Object &&
           Array(part, "word").FirstOrDefault() is { ValueKind: JsonValueKind.Object } word
            ? word
            : null;

    /// <summary>trs 里一条的 tr[0].l。</summary>
    private static JsonElement? FirstLine(JsonElement tr)
        => tr.ValueKind == JsonValueKind.Object && Array(tr, "tr").FirstOrDefault() is { ValueKind: JsonValueKind.Object } first &&
           first.TryGetProperty("l", out var line) && line.ValueKind == JsonValueKind.Object
            ? line
            : null;

    private static IEnumerable<JsonElement> Array(JsonElement element, string name)
        => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) &&
           value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray()
            : Enumerable.Empty<JsonElement>();

    private static string? Str(JsonElement element, string name)
        => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) &&
           value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
