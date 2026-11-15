// 文件名的「自然顺序」（PLAN-v20 N1，mac localizedStandardCompare，纯函数配单测）：连着的数字按数值比（「便签 2」在「便签 10」前面），
// 别的按当前区域、不分大小写比；数值一样时前导零少的在前（「1」在「01」前面），都一样再按原文比，排序结果稳定。
// 便签导入 Markdown 时按它排（超过 2000 个时截掉哪些、别处文件的先后）。
using System.Globalization;

namespace KittyTools.Core;

public sealed class NaturalOrder : IComparer<string>
{
    public static readonly NaturalOrder Instance = new();

    private static readonly CompareInfo Culture = CultureInfo.CurrentCulture.CompareInfo;

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y))
        {
            return 0;
        }

        if (x is null || y is null)
        {
            return x is null ? -1 : 1;
        }

        var i = 0;
        var j = 0;
        while (i < x.Length && j < y.Length)
        {
            var digitX = char.IsAsciiDigit(x[i]);
            var digitY = char.IsAsciiDigit(y[j]);
            var endX = Run(x, i, digitX);
            var endY = Run(y, j, digitY);
            int order;
            if (digitX && digitY)
            {
                order = Numbers(x.AsSpan(i, endX - i), y.AsSpan(j, endY - j));
            }
            else
            {
                order = Culture.Compare(x, i, endX - i, y, j, endY - j, CompareOptions.IgnoreCase);
            }

            if (order != 0)
            {
                return order;
            }

            i = endX;
            j = endY;
        }

        var length = (x.Length - i).CompareTo(y.Length - j);
        return length != 0 ? length : string.CompareOrdinal(x, y);
    }

    /// <summary>从 start 起同一类（都是数字 / 都不是）连着的一段到哪。</summary>
    private static int Run(string text, int start, bool digits)
    {
        var end = start + 1;
        while (end < text.Length && char.IsAsciiDigit(text[end]) == digits)
        {
            end++;
        }

        return end;
    }

    /// <summary>两串数字按数值比（不转成整数，多长都行）；一样大时前导零少的在前。</summary>
    private static int Numbers(ReadOnlySpan<char> x, ReadOnlySpan<char> y)
    {
        var trimmedX = x.TrimStart('0');
        var trimmedY = y.TrimStart('0');
        var order = trimmedX.Length.CompareTo(trimmedY.Length);
        if (order == 0)
        {
            order = trimmedX.SequenceCompareTo(trimmedY);
        }

        return order != 0 ? order : x.Length.CompareTo(y.Length);
    }
}
