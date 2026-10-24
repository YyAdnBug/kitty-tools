// 剪贴板搜索（纯函数）：空白分词，每个词都要命中（AND）；不区分大小写、全半角、变音符号。
// 只过滤、不排序；调用方按复制时间新→旧拿列表，搜索后顺序不变。
using System.Globalization;
using System.Text;

namespace KittyTools.Core;

public static class Search
{
    public const int MaxIndexedCharacters = 20_000;

    private static readonly CompareOptions CompareOptions =
        System.Globalization.CompareOptions.IgnoreCase |
        System.Globalization.CompareOptions.IgnoreWidth |
        System.Globalization.CompareOptions.IgnoreNonSpace;

    public static string Fold(string text)
    {
        var normalized = text.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(normalized.Length);
        foreach (var ch in normalized)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(ch);
            }
        }

        return builder.ToString().Normalize(NormalizationForm.FormC);
    }

    public static byte[] FoldBytes(string text) => Encoding.UTF8.GetBytes(Fold(text));

    public static string[] Tokens(string query)
        => query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public static bool Contains(ReadOnlySpan<byte> haystack, ReadOnlySpan<byte> needle)
        => needle.Length > 0 && haystack.IndexOf(needle) >= 0;

    public static bool Matches(ReadOnlySpan<byte> folded, string[] tokens)
    {
        foreach (var token in tokens)
        {
            if (!Contains(folded, FoldBytes(token)))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>一次搜索里所有词只折叠一遍（5000 条时别每条都折）。</summary>
    public static byte[][] FoldTokens(string[] tokens)
    {
        var folded = new byte[tokens.Length][];
        for (var i = 0; i < tokens.Length; i++)
        {
            folded[i] = FoldBytes(tokens[i]);
        }

        return folded;
    }

    public static bool Matches(ReadOnlySpan<byte> folded, ReadOnlySpan<byte[]> foldedTokens)
    {
        foreach (var token in foldedTokens)
        {
            if (!Contains(folded, token))
            {
                return false;
            }
        }

        return true;
    }

    /// 命中摘录：命中前留 before 个字、命中后留 after 个字，截掉的那头补「…」。
    /// 没有搜索词、没有命中，或命中就在开头 before 个字以内时返回 null。
    public static string? Excerpt(string text, string query, int before = 40, int after = 40)
    {
        var tokens = Tokens(query);
        if (tokens.Length == 0)
        {
            return null;
        }

        var info = CultureInfo.InvariantCulture.CompareInfo;
        var bestIndex = -1;
        var bestLength = 0;
        foreach (var token in tokens)
        {
            var index = info.IndexOf(text, token, CompareOptions);
            if (index < 0)
            {
                continue;
            }

            if (bestIndex < 0 || index < bestIndex)
            {
                bestIndex = index;
                bestLength = token.Length;
            }
        }

        if (bestIndex <= before || bestIndex < 0)
        {
            return null;
        }

        var start = bestIndex - before;
        var end = Math.Min(text.Length, bestIndex + bestLength + after);
        var builder = new StringBuilder();
        builder.Append('…');
        builder.Append(text.AsSpan(start, end - start));
        if (end < text.Length)
        {
            builder.Append('…');
        }

        return builder.ToString();
    }
}
