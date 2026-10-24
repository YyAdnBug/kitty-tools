// 汉字转拼音（纯函数，表是嵌入资源 Resources/pinyin.txt）：含汉字才转，
// 「活动监视器」→ (huodongjianshiqi, hdjsq)；夹着的英文词原样保留。
// 表是 `拼音<空格>同音字…` 一行，生成脚本见 windows/tools/pinyin-table.swift。
using System.Collections.Concurrent;
using System.Text;

namespace KittyTools.Core;

public static class Pinyin
{
    private static readonly Lazy<Dictionary<char, string>> Table = new(Load);

    public static (string Full, string Initials)? For(string text)
    {
        if (!text.Any(IsHan))
        {
            return null;
        }

        var syllables = new List<string>();
        var latin = new StringBuilder();
        void Flush()
        {
            if (latin.Length > 0)
            {
                syllables.Add(latin.ToString());
                latin.Clear();
            }
        }

        foreach (var character in text)
        {
            if (IsHan(character))
            {
                Flush();
                if (Table.Value.TryGetValue(character, out var syllable))
                {
                    syllables.Add(syllable);
                }
            }
            else if (char.IsLetterOrDigit(character))
            {
                latin.Append(char.ToLowerInvariant(character));
            }
            else
            {
                Flush();
            }
        }

        Flush();
        if (syllables.Count == 0)
        {
            return null;
        }

        var full = string.Concat(syllables);
        var initials = new string(syllables.Select(syllable => syllable[0]).ToArray());
        return (full, initials);
    }

    public static bool IsHan(char character)
        => character is >= '\u4E00' and <= '\u9FFF' or >= '\u3400' and <= '\u4DBF'
            or >= '\uF900' and <= '\uFAFF';

    private static Dictionary<char, string> Load()
    {
        var map = new Dictionary<char, string>(20_000);
        using var stream = typeof(Pinyin).Assembly
            .GetManifestResourceStream("KittyTools.Core.Resources.pinyin.txt");
        if (stream is null)
        {
            return map;
        }

        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            var space = line.IndexOf(' ');
            if (space <= 0 || space >= line.Length - 1)
            {
                continue;
            }

            var syllable = line[..space];
            for (var index = space + 1; index < line.Length; index++)
            {
                map.TryAdd(line[index], syllable);
            }
        }

        return map;
    }
}
