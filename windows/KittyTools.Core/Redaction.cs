// 一键打码（PLAN-v18 S17，照 mac Screenshot/Redaction.swift，ee303f55）：打码托盘上的「自动」。在识出来的每一行里找手机号、邮箱、
// 银行卡号、身份证号，各加一块普通打码标注（能挪、能删、能撤销）。这里是找哪几段、换成哪几块的纯函数，配单测；识字在
// App 的 OcrService，什么时候跑、结果落进标注列表归截图遮罩。
// 只认格式明确的几类，宁可漏也不乱打：卡号 15–19 位、按卡组织号段开头、过 Luhn；身份证号的地区码、出生日期、校验位都对得上——
// 单靠 Luhn / 校验位，时间戳、订单号、雪花 ID 一成上下会碰巧过（mac 评审随机实测）。认出来的几段互相重叠时合成一段（隐私功能，
// 宁可多盖，不能丢掉一段把号码露出半截）。
// Windows 和 mac 不一样的一处：Windows 的识字给的是一个个词的框（中日文一个字一个词），没有「这几个字在哪」，所以一行的字按词拼起来
// （词之间一个空格），认出来的那一段盖住和它沾边的所有词的框；没有词框的行整行盖。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class Redaction
{
    [GeneratedRegex(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}")]
    private static partial Regex Email();

    /// <summary>中国大陆手机号：1 开头 11 位，可带 +86，可按 3-4-4 用空格或横线隔开；后面不能紧挨别的数字（前面见 StartsClean）。</summary>
    [GeneratedRegex(@"(?:\+?86[ \-]?)?1[3-9][0-9](?:[ \-]?[0-9]{4}){2}(?![0-9])")]
    private static partial Regex Mobile();

    [GeneratedRegex(@"[0-9]{17}[0-9Xx](?![0-9A-Za-z])")]
    private static partial Regex IdNumber();

    /// <summary>
    /// 卡号的写法：连着写 15–19 位，或四位一组用空格 / 横线隔开（最后一组 1–4 位）；后面不能紧挨数字。
    /// 不许任意两位之间都能断开：不然一行里按空格分组的两个手机号会被连成一串「卡号」。
    /// </summary>
    [GeneratedRegex(@"(?:[0-9]{15,19}|[0-9]{4}(?:[ \-][0-9]{4}){2,3}(?:[ \-][0-9]{1,4})?)(?![0-9])")]
    private static partial Regex CardNumber();

    /// <summary>一行字里要打码的那几段（起点、长度；按出现顺序，重叠的合成一段）。thisYear：身份证号的出生年最多到哪年（单测注入）。</summary>
    public static List<(int Start, int Length)> Ranges(string text, int? thisYear = null)
    {
        var year = thisYear ?? DateTime.UtcNow.Year;
        var found = new List<(int Start, int End)>();
        foreach (Match match in Email().Matches(text))
        {
            if (!IsAssetName(match.Value))
            {
                found.Add((match.Index, match.Index + match.Length));
            }
        }

        foreach (Match match in IdNumber().Matches(text))
        {
            if (StartsClean(text, match.Index, letters: true) && IsIDNumber(match.Value, year))
            {
                found.Add((match.Index, match.Index + match.Length));
            }
        }

        foreach (Match match in CardNumber().Matches(text))
        {
            if (StartsClean(text, match.Index) && IsCardNumber(match.Value.Where(char.IsAsciiDigit).Select(c => c - '0').ToList()))
            {
                found.Add((match.Index, match.Index + match.Length));
            }
        }

        foreach (Match match in Mobile().Matches(text))
        {
            if (StartsClean(text, match.Index))
            {
                found.Add((match.Index, match.Index + match.Length));
            }
        }

        var merged = new List<(int Start, int End)>();
        foreach (var range in found.OrderBy(range => range.Start))
        {
            if (merged.Count > 0 && merged[^1].End > range.Start)
            {
                merged[^1] = (merged[^1].Start, Math.Max(merged[^1].End, range.End));
            }
            else
            {
                merged.Add(range);
            }
        }

        return merged.Select(range => (range.Start, range.End - range.Start)).ToList();
    }

    /// <summary>
    /// 银行卡号：15–19 位，开头是卡组织的号段（3 开头的运通 / JCB / 大来、4 Visa、5 万事达、6 银联 / 发现，2221–2720 的
    /// 万事达新号段），过 Luhn。2 开头的日期式订单号、1 开头的时间戳都不认。
    /// </summary>
    public static bool IsCardNumber(IReadOnlyList<int> digits)
    {
        if (digits.Count is < 15 or > 19)
        {
            return false;
        }

        var prefix = digits.Take(4).Aggregate(0, (sum, digit) => sum * 10 + digit);
        return (digits[0] is >= 3 and <= 6 || prefix is >= 2221 and <= 2720) && PassesLuhn(digits);
    }

    /// <summary>Luhn 校验（银行卡号）：从右往左每隔一位乘 2，各位相加能被 10 整除。</summary>
    public static bool PassesLuhn(IReadOnlyList<int> digits)
    {
        var sum = 0;
        for (var index = 0; index < digits.Count; index++)
        {
            var digit = digits[digits.Count - 1 - index];
            var value = index % 2 == 0 ? digit : digit * 2;
            sum += value > 9 ? value - 9 : value;
        }

        return digits.Count > 0 && sum % 10 == 0;
    }

    /// <summary>
    /// 18 位身份证号（GB 11643）：地区码首位 1–8，第 7–14 位是 1900 年到 thisYear 之间真有的日子，
    /// 校验位对（前 17 位乘权重求和模 11，对应 1 0 X 9 8 7 6 5 4 3 2）。
    /// </summary>
    public static bool IsIDNumber(string text, int thisYear)
    {
        var characters = text.ToUpperInvariant();
        if (characters.Length != 18 || characters[0] is < '1' or > '8' ||
            !int.TryParse(characters.AsSpan(6, 8), out var birthday) || !IsBirthday(birthday, thisYear))
        {
            return false;
        }

        int[] weights = { 7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2 };
        var sum = 0;
        for (var index = 0; index < 17; index++)
        {
            if (!char.IsAsciiDigit(characters[index]))
            {
                return false;
            }

            sum += (characters[index] - '0') * weights[index];
        }

        return "10X98765432"[sum % 11] == characters[17];
    }

    /// <summary>yyyyMMdd 是不是 1900 年到 thisYear 之间真有的一天（公历）。</summary>
    private static bool IsBirthday(int value, int thisYear)
    {
        var (year, month, day) = (value / 10000, value / 100 % 100, value % 100);
        return year >= 1900 && year <= thisYear && month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month);
    }

    /// <summary>图片资源名（icon@2x.png、AppIcon@3x.png）长得像邮箱：@ 后面是「数字 + x」的不算。</summary>
    private static bool IsAssetName(string text)
    {
        var at = text.IndexOf('@');
        if (at < 0)
        {
            return false;
        }

        var domain = text[(at + 1)..].Split('.')[0];
        return domain.Length >= 2 && domain[^1] == 'x' && domain[..^1].All(char.IsAsciiDigit);
    }

    /// <summary>前面不紧挨着数字（letters：也不挨着字母）。</summary>
    private static bool StartsClean(string text, int start, bool letters = false)
    {
        if (start == 0)
        {
            return true;
        }

        var previous = text[start - 1];
        return !(char.IsAscii(previous) && (char.IsAsciiDigit(previous) || letters && char.IsAsciiLetter(previous)));
    }

    /// <summary>
    /// 识字结果里要盖的那几块（和识字同一个坐标系）：每一行按词拼成一串（词之间一个空格，同 Windows 识字给的写法），认出来的每一段盖住和它
    /// 沾边的所有词的框（并起来）；没有词框的行有一段就整行盖。
    /// </summary>
    public static List<RectD> Boxes(IReadOnlyList<OcrLine> lines, int? thisYear = null)
    {
        var boxes = new List<RectD>();
        foreach (var line in lines)
        {
            if (line.Words is not { Count: > 0 } words)
            {
                if (Ranges(line.Text, thisYear).Count > 0)
                {
                    boxes.Add(line.Box);
                }

                continue;
            }

            var spans = new List<(int Start, int End)>();
            var builder = new System.Text.StringBuilder();
            foreach (var word in words)
            {
                if (builder.Length > 0)
                {
                    builder.Append(' ');
                }

                spans.Add((builder.Length, builder.Length + word.Text.Length));
                builder.Append(word.Text);
            }

            foreach (var (start, length) in Ranges(builder.ToString(), thisYear))
            {
                RectD? union = null;
                for (var index = 0; index < words.Count; index++)
                {
                    if (spans[index].Start < start + length && spans[index].End > start)
                    {
                        var box = words[index].Box;
                        union = union is { } soFar ? RectD.FromLtrb(
                            Math.Min(soFar.X, box.X), Math.Min(soFar.Y, box.Y), Math.Max(soFar.Right, box.Right), Math.Max(soFar.Bottom, box.Bottom)) : box;
                    }
                }

                if (union is { } covered)
                {
                    boxes.Add(covered);
                }
            }
        }

        return boxes;
    }

    /// <summary>
    /// 字框换成打码框：四周各放 pad（框贴着字，留点边才盖得严），夹回 area（选区）里；字框本身不到 minimum 的是识错的碎渣，
    /// 夹回之后太窄的（字压在区域边上）也不要；已经被某块打码整个盖住的不要（连按两下不叠两层）。
    /// ponytail: 只按「整个盖住」去重（同 mac），和已有打码只部分重叠的照样加一块。
    /// </summary>
    public static List<RectD> Areas(IEnumerable<RectD> boxes, RectD area, IEnumerable<RectD> existing, double pad, double minimum)
    {
        var covered = existing.ToList();
        var result = new List<RectD>();
        foreach (var box in boxes)
        {
            if (box.Width < minimum || box.Height < minimum)
            {
                continue;
            }

            var left = Math.Max(box.X - pad, area.X);
            var top = Math.Max(box.Y - pad, area.Y);
            var right = Math.Min(box.Right + pad, area.Right);
            var bottom = Math.Min(box.Bottom + pad, area.Bottom);
            if (right - left < minimum * 1.5 || bottom - top < minimum * 1.5)
            {
                continue;
            }

            var rect = RectD.FromLtrb(left, top, right, bottom);
            if (covered.Concat(result).Any(other => other.X <= rect.X && other.Y <= rect.Y && other.Right >= rect.Right && other.Bottom >= rect.Bottom))
            {
                continue;
            }

            result.Add(rect);
        }

        return result;
    }
}
