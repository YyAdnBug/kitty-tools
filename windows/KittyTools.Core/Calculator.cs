// 启动器计算器（纯函数，配单测；照 mac 版 Launcher/Calculator.swift 原样移植，输出的字一字不差）：
// + - * /、mod（取模）、^ 或 **（幂，右结合）、括号、一元正负号、sqrt abs round floor ceil sin cos tan log（常用对数）ln exp、
// 常量 pi e、0x / 0b / 0o 字面量、科学计数（1.15292150461e18：Tab 把很大 / 很小的结果写回输入框后要能接着算）。
// % 是百分号（同 macOS 计算器）：200*15% = 30、100+10% = 110（a ± b% = a ×（1 ± b/100））、50% = 0.5。
// 中文输入法打出来的全角括号 / 数字 / 符号、× ÷、千分位逗号先归一，算式那一栏照常显示原文。
// 手写递归下降，半截表达式返回 null，不会崩；日期（2024-01-01）、单独一个数字不算算式。
// 全部离线：单位换算「数字 单位 (to|in|=|转) 单位」（长度、质量、温度、数据、时间、面积、体积、速度；英文符号 + 中文名，
// 系数照 Foundation 的 UnitLength 等，下面一张表）；进制「255 in hex / bin / oct」「0xff in dec」。结果大字按千分位分组，
// Enter 粘贴、Tab 写回的仍是不分组的原值，Copies 里另有「复制原始数字」、输入带 0x / 0b 时「复制十六进制 / 二进制」。汇率要联网，不做。
// 数字照 Foundation（ICU）的排法：取最短往返的十进制数字、四舍六入五成双，一律 en_US 样式，不受系统区域影响。
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>动作列表里多出来的一条复制项（「复制原始数字」「复制十六进制」…）。</summary>
public readonly record struct CalcCopy(string Title, string Text);

public static partial class Calculator
{
    /// <summary>一条结果：卡片上的大字（千分位分组、带单位）、Enter 粘贴 / Tab 写回的（不分组）、动作列表里多出来的复制项。</summary>
    public sealed record Result(string Display, string Payload, IReadOnlyList<CalcCopy> Copies);

    /// <summary>2^53：再大的整数 double 不一定精确，按科学计数排，也不出进制。</summary>
    private const double MaxExactInteger = 9_007_199_254_740_992;

    private const string RawNumberTitle = "复制原始数字";

    private static readonly Dictionary<string, UnitName> Units = BuildUnits();

    public static LauncherItem? ItemFor(string query) =>
        ResultFor(query) is { } result
            ? new LauncherItem
            {
                Kind = LauncherKind.Calculation,
                Target = query,
                Title = result.Display,
                Subtitle = "计算结果 · Enter 粘贴 · Tab 接着算",
                Payload = result.Payload,
                Completion = result.Payload,
            }
            : null;

    /// <summary>单位换算 → 进制 → 算式，都不是就 null。</summary>
    public static Result? ResultFor(string query)
    {
        if ((Convert(query) ?? ConvertRadix(query)) is { } converted)
        {
            return converted;
        }

        if (!LooksLikeMath(query) || Evaluate(query) is not { } value)
        {
            return null;
        }

        var result = Number(value);
        return HasRadixLiteral(query)
            ? result with { Copies = result.Copies.Concat(RadixCopies(value, except: 10)).ToArray() }
            : result;
    }

    /// <summary>算式的结果：大字分组，粘贴的不分组；两者不一样时多一条「复制原始数字」。</summary>
    public static Result Number(double value)
    {
        var payload = Format(value);
        var display = Format(value, grouped: true);
        return new Result(
            display,
            payload,
            display == payload ? Array.Empty<CalcCopy>() : new[] { new CalcCopy(RawNumberTitle, payload) });
    }

    /// <summary>
    /// 中文输入法打出来的算式：全角 ！-～（括号、数字、＋－＊／％、字母）转半角（同 mac 的 widthInsensitive，全角空格不动），
    /// × ✕ 换成 *、÷ 换成 /，去掉数字之间的千分位逗号（1,299 → 1299）。
    /// </summary>
    public static string Normalize(string query)
    {
        var characters = query.ToCharArray();
        for (var i = 0; i < characters.Length; i++)
        {
            characters[i] = characters[i] switch
            {
                >= '\uFF01' and <= '\uFF5E' => (char)(characters[i] - 0xFEE0),
                '×' or '✕' => '*',
                '÷' => '/',
                var other => other,
            };
        }

        return ThousandsRegex().Replace(new string(characters), "$1");
    }

    public static bool LooksLikeMath(string query)
    {
        var text = Normalize(TrimSpaces(query));
        return text.Length >= 3
            && MathCharsRegex().IsMatch(text)
            && DigitOrConstantRegex().IsMatch(text)
            // 单独一个 0x / 0b / 0o 字面量也算：出十进制（能复制十六进制 / 二进制）
            && (OperatorRegex().IsMatch(text) || RadixLiteralOnlyRegex().IsMatch(text))
            && !DateRegex().IsMatch(text);
    }

    /// <summary>解析失败、结果不是有限数时返回 null。mod 先换成一个字符（|）再去空白：去了空白「pi mod 2」会粘成一个名字。</summary>
    public static double? Evaluate(string input)
    {
        var text = Normalize(input).ToLowerInvariant().Replace("**", "^").Replace("mod", "|");
        var parser = new Parser(text.Where(character => !char.IsWhiteSpace(character)).ToArray());
        return parser.Expression() is { } value && parser.AtEnd && double.IsFinite(value) ? value : null;
    }

    /// <summary>
    /// 能精确表示的整数（≤ 2^53）原样；太大太小（≥ 1e15、小于 1e-9）用科学计数（1.15292150461E18、9E-13）；
    /// 其余最多 12 位有效数字、去掉末尾的 0。grouped：千分位分组（卡片上的大字），粘贴 / 写回的不分组。
    /// </summary>
    public static string Format(double value, bool grouped = false)
    {
        if (IsExactInteger(value))
        {
            return ((long)value).ToString(grouped ? "#,0" : "0", CultureInfo.InvariantCulture);
        }

        var scientific = Math.Abs(value) >= 1e15 || Math.Abs(value) < 1e-9;
        return Digits(value, 12, significant: true, grouped: grouped, scientific: scientific);
    }

    // MARK: 进制

    /// <summary>「255 in hex」「0xff in dec」「255 转 二进制」：左边是算式（结果要是整数），右边是进制。</summary>
    public static Result? ConvertRadix(string query)
    {
        var match = RadixRegex().Match(TrimSpaces(Normalize(query)));
        if (!match.Success || Evaluate(match.Groups[1].Value) is not { } value || !IsExactInteger(value))
        {
            return null;
        }

        var radix = match.Groups[2].Value.ToLowerInvariant() switch
        {
            "hex" or "十六进制" => 16,
            "bin" or "二进制" => 2,
            "oct" or "八进制" => 8,
            _ => 10,
        };
        if (radix == 10)
        {
            var result = Number(value);
            return result with { Copies = result.Copies.Concat(RadixCopies(value, except: 10)).ToArray() };
        }

        var converted = Radix((long)value, radix);
        return new Result(converted, converted, RadixCopies(value, except: radix));
    }

    /// <summary>0xFF / 0b1010 / 0o17（负数带 -）：写回输入框还能接着算。</summary>
    public static string Radix(long value, int radix)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(radix, 2);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(radix, 36);
        var prefix = radix switch
        {
            16 => "0x",
            2 => "0b",
            8 => "0o",
            _ => "",
        };
        // long.MinValue 取反会溢出，按无符号算绝对值
        var magnitude = unchecked(value < 0 ? 0UL - (ulong)value : (ulong)value);
        var digits = new StringBuilder();
        do
        {
            digits.Insert(0, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"[(int)(magnitude % (ulong)radix)]);
            magnitude /= (ulong)radix;
        }
        while (magnitude != 0);

        return (value < 0 ? "-" : "") + prefix + digits;
    }

    /// <summary>「复制十进制 / 十六进制 / 二进制」（不是整数时没有；except 是结果本身的进制）。</summary>
    public static IReadOnlyList<CalcCopy> RadixCopies(double value, int except)
    {
        if (!IsExactInteger(value))
        {
            return Array.Empty<CalcCopy>();
        }

        var copies = new List<CalcCopy>();
        if (except != 10)
        {
            copies.Add(new CalcCopy("复制十进制", Format(value)));
        }

        if (except != 16)
        {
            copies.Add(new CalcCopy("复制十六进制", Radix((long)value, 16)));
        }

        if (except != 2)
        {
            copies.Add(new CalcCopy("复制二进制", Radix((long)value, 2)));
        }

        return copies;
    }

    public static bool HasRadixLiteral(string query) =>
        RadixLiteralRegex().IsMatch(Normalize(query).ToLowerInvariant());

    // MARK: 单位换算

    /// <summary>
    /// 「10 km to mi」「30 摄氏度 转 华氏度」「1.5GB in MB」：左边一个数加单位，右边单位；两边要是同一类量。
    /// 结果：大字「6.2137 mi」（分组）、Enter 粘贴 / Tab 写回「6.2137 mi」（不分组，接着能换算）、「复制原始数字」6.2137。
    /// </summary>
    public static Result? Convert(string query)
    {
        var match = ConvertRegex().Match(TrimSpaces(Normalize(query)));
        if (!match.Success
            || !double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            || UnitFor(match.Groups[2].Value) is not { } source
            || UnitFor(match.Groups[3].Value) is not { } target
            || source.Family != target.Family)
        {
            return null;
        }

        // 同 Foundation 的 Measurement.converted(to:)：同一个单位原样；不然 值 × 系数 + 常数（Apple 的实现是 fma，
        // 本机逐位比过）换到基本单位，再（基本 − 常数）÷ 系数。换到基本单位时系数 1、常数 0，这一步不改值。
        var converted = source == target
            ? value
            : (Math.FusedMultiplyAdd(value, source.Coefficient, source.Constant) - target.Constant) / target.Coefficient;
        if (!double.IsFinite(converted))
        {
            return null;
        }

        var plain = Quantity(converted, grouped: false);
        return new Result(
            Quantity(converted, grouped: true) + " " + target.Symbol,
            plain + " " + target.Symbol,
            new[] { new CalcCopy(RawNumberTitle, plain) });
    }

    /// <summary>换算结果的数：≥ 1 的最多 4 位小数（6.2137），小于 1 的 6 位有效数字（0.000621371），太大太小科学计数。</summary>
    public static string Quantity(double value, bool grouped)
    {
        var magnitude = Math.Abs(value);
        if (magnitude >= 1e15 || (value != 0 && magnitude < 1e-9))
        {
            return Digits(value, 6, significant: true, grouped: grouped, scientific: true);
        }

        return magnitude >= 1
            ? Digits(value, 4, significant: false, grouped: grouped, scientific: false)
            : Digits(value, 6, significant: true, grouped: grouped, scientific: false);
    }

    /// <summary>同一类量才能换（Family）；值 × 系数 + 常数 = 基本单位；Symbol 是结果里写的符号。</summary>
    private sealed record UnitName(string Family, string Symbol, double Coefficient, double Constant);

    /// <summary>单位名（不分大小写，两头的空格不算）→ 单位。</summary>
    private static UnitName? UnitFor(string name) =>
        Units.TryGetValue(TrimSpaces(name).ToLowerInvariant(), out var unit) ? unit : null;

    /// <summary>
    /// 每一行：类、结果里写的符号、系数、常数、能输入的名字。名字不分大小写，所以 Mb（兆比特）也当 MB。
    /// 基本单位：长度 m、质量 kg、温度 K、数据 B、时间 s、面积 m²、体积 L、速度 m/s；系数、常数是 macOS 上
    /// Foundation 的 UnitLength 等读出来的原值（mi 1609.344、lb 0.453592、°F 0.55555555555556 / 255.37222222222428…）。
    /// ponytail: 常用的中英文名，没有复数变形规则、没有「平方」这类组合；缺了往表里加一行（mac 那张表同步加）
    /// </summary>
    private static Dictionary<string, UnitName> BuildUnits()
    {
        var units = new Dictionary<string, UnitName>(StringComparer.Ordinal);

        void Add(string family, string symbol, double coefficient, double constant, params string[] names)
        {
            var unit = new UnitName(family, symbol, coefficient, constant);
            foreach (var name in names)
            {
                units[name.ToLowerInvariant()] = unit;
            }
        }

        Add("length", "m", 1, 0, "m", "米", "meter", "meters", "metre", "metres");
        Add("length", "km", 1000, 0, "km", "公里", "千米", "kilometer", "kilometers");
        Add("length", "cm", 0.01, 0, "cm", "厘米", "公分", "centimeter", "centimeters");
        Add("length", "mm", 0.001, 0, "mm", "毫米", "millimeter", "millimeters");
        Add("length", "µm", 1e-06, 0, "µm", "μm", "um", "微米");
        Add("length", "nm", 1e-09, 0, "nm", "纳米");
        Add("length", "mi", 1609.344, 0, "mi", "mile", "miles", "英里");
        Add("length", "ft", 0.3048, 0, "ft", "foot", "feet", "英尺", "'");
        Add("length", "in", 0.0254, 0, "in", "inch", "inches", "英寸", "\"");
        Add("length", "yd", 0.9144, 0, "yd", "yard", "yards", "码");
        Add("length", "nmi", 1852, 0, "nmi", "海里");
        Add("length", "里", 500, 0, "里", "华里");
        Add("length", "尺", 1.0 / 3, 0, "尺", "市尺");
        Add("length", "寸", 1.0 / 30, 0, "寸", "市寸");

        Add("mass", "g", 0.001, 0, "g", "克", "gram", "grams");
        Add("mass", "kg", 1, 0, "kg", "公斤", "千克", "kilogram", "kilograms", "kilo", "kilos");
        Add("mass", "mg", 1e-06, 0, "mg", "毫克");
        Add("mass", "t", 1000, 0, "t", "吨", "ton", "tons", "tonne", "tonnes");
        Add("mass", "lb", 0.453592, 0, "lb", "lbs", "pound", "pounds", "磅");
        Add("mass", "oz", 0.0283495, 0, "oz", "ounce", "ounces", "盎司");
        Add("mass", "斤", 0.5, 0, "斤", "市斤");
        Add("mass", "两", 0.05, 0, "两");

        Add("temperature", "°C", 1, 273.15, "c", "°c", "℃", "celsius", "摄氏度", "摄氏", "度");
        Add("temperature", "°F", 0.55555555555556, 255.37222222222428, "f", "°f", "℉", "fahrenheit", "华氏度", "华氏");
        Add("temperature", "K", 1, 0, "k", "kelvin", "开尔文", "开");

        Add("data", "B", 1, 0, "b", "byte", "bytes", "字节");
        Add("data", "bit", 0.125, 0, "bit", "bits", "比特", "位");
        Add("data", "KB", 1000, 0, "kb", "千字节");
        Add("data", "MB", 1000000, 0, "mb", "兆字节", "兆");
        Add("data", "GB", 1000000000, 0, "gb", "吉字节", "g字节");
        Add("data", "TB", 1000000000000, 0, "tb");
        Add("data", "PB", 1000000000000000, 0, "pb");
        Add("data", "KiB", 1024, 0, "kib");
        Add("data", "MiB", 1048576, 0, "mib");
        Add("data", "GiB", 1073741824, 0, "gib");
        Add("data", "TiB", 1099511627776, 0, "tib");
        Add("data", "kbit", 125, 0, "kbit", "kbps");
        Add("data", "Mbit", 125000, 0, "mbit", "mbps");
        Add("data", "Gbit", 125000000, 0, "gbit", "gbps");

        Add("duration", "s", 1, 0, "s", "sec", "secs", "second", "seconds", "秒", "秒钟");
        Add("duration", "ms", 0.001, 0, "ms", "毫秒", "millisecond", "milliseconds");
        Add("duration", "min", 60, 0, "min", "mins", "minute", "minutes", "分钟", "分");
        Add("duration", "h", 3600, 0, "h", "hr", "hrs", "hour", "hours", "小时", "钟头");
        Add("duration", "天", 86400, 0, "d", "day", "days", "天", "日");
        Add("duration", "周", 604800, 0, "w", "wk", "week", "weeks", "周", "星期");

        Add("area", "m²", 1, 0, "m2", "m²", "sqm", "平方米", "平米");
        Add("area", "km²", 1000000, 0, "km2", "km²", "平方公里", "平方千米");
        Add("area", "cm²", 0.0001, 0, "cm2", "cm²", "平方厘米");
        Add("area", "ft²", 0.09290304, 0, "ft2", "ft²", "sqft", "平方英尺");
        Add("area", "in²", 0.00064516, 0, "in2", "in²", "平方英寸");
        Add("area", "mi²", 2589988.110336, 0, "mi2", "mi²", "平方英里");
        Add("area", "ha", 10000, 0, "ha", "hectare", "hectares", "公顷");
        Add("area", "ac", 4046.8564224, 0, "ac", "acre", "acres", "英亩");
        Add("area", "亩", 2000.0 / 3, 0, "亩");

        Add("volume", "L", 1, 0, "l", "liter", "liters", "litre", "litres", "升", "公升");
        Add("volume", "mL", 0.001, 0, "ml", "milliliter", "milliliters", "毫升");
        Add("volume", "m³", 1000, 0, "m3", "m³", "立方米", "方");
        Add("volume", "cm³", 0.001, 0, "cm3", "cm³", "cc", "立方厘米");
        Add("volume", "gal", 3.78541, 0, "gal", "gallon", "gallons", "加仑");
        Add("volume", "qt", 0.946353, 0, "qt", "quart", "quarts");
        Add("volume", "pt", 0.473176, 0, "pt", "pint", "pints", "品脱");
        Add("volume", "cup", 0.24, 0, "cup", "cups", "杯");
        Add("volume", "fl oz", 0.0295735, 0, "fl oz", "floz", "液盎司");
        Add("volume", "tbsp", 0.0147868, 0, "tbsp", "汤匙");
        Add("volume", "tsp", 0.00492892, 0, "tsp", "茶匙");

        Add("speed", "m/s", 1, 0, "m/s", "mps", "米每秒", "米/秒");
        Add("speed", "km/h", 0.277778, 0, "km/h", "kmh", "kph", "公里每小时", "公里/小时", "千米每小时");
        Add("speed", "mph", 0.44704, 0, "mph", "英里每小时");
        Add("speed", "kn", 0.514444, 0, "kn", "knot", "knots", "节");
        return units;
    }

    // MARK: 数字的排法

    private static bool IsExactInteger(double value) => double.IsInteger(value) && Math.Abs(value) <= MaxExactInteger;

    /// <summary>
    /// 照 Foundation（ICU）排一个 double：取最短往返的十进制数字，四舍六入五成双截到 count 位有效数字（significant）
    /// 或 count 位小数，去掉末尾的 0。scientific 写成 1.5E20 / 9E-13（不分组）；不然整数部分按 grouped 每三位一个逗号。
    /// 6 万个随机数（含各位上的五）和 mac 的 format / quantity 逐字比过。
    /// </summary>
    private static string Digits(double value, int count, bool significant, bool grouped, bool scientific)
    {
        if (!double.IsFinite(value))
        {
            return double.IsNaN(value) ? "NaN" : value > 0 ? "∞" : "-∞";
        }

        var sign = double.IsNegative(value) ? "-" : "";
        // "R" 是最短往返的数字，样子有 6.283185307179586、0.000123、1.5E-05、1E+20 这几种。
        // 前面垫一个 0 接住进位：值 = 0.d₀d₁d₂… × 10^position
        var text = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);
        var exponentAt = text.IndexOf('E');
        var mantissa = exponentAt < 0 ? text : text[..exponentAt];
        var exponent = exponentAt < 0
            ? 0
            : int.Parse(text[(exponentAt + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var point = mantissa.IndexOf('.');
        var digits = ("0" + mantissa.Replace(".", "")).ToCharArray();
        var position = (point < 0 ? mantissa.Length : point) + exponent + 1;
        var first = Array.FindIndex(digits, digit => digit != '0');
        if (first < 0)
        {
            return sign + "0";
        }

        var length = digits.Length;
        var keep = significant ? first + count : position + count;
        if (keep < length)
        {
            if (keep < 1)
            {
                return sign + "0";
            }

            var next = digits[keep];
            var roundUp = next > '5'
                || (next == '5'
                    && (Array.FindIndex(digits, keep + 1, digit => digit != '0') >= 0 || (digits[keep - 1] - '0') % 2 == 1));
            length = keep;
            if (roundUp)
            {
                var i = keep - 1;
                while (digits[i] == '9')
                {
                    digits[i--] = '0';
                }

                digits[i]++;
            }
        }

        var start = 0;
        while (start < length && digits[start] == '0')
        {
            start++;
        }

        while (length > start && digits[length - 1] == '0')
        {
            length--;
        }

        if (start == length)
        {
            return sign + "0";
        }

        var kept = new string(digits, start, length - start);
        position -= start;
        if (scientific)
        {
            return sign + kept[..1] + (kept.Length > 1 ? "." + kept[1..] : "") + "E"
                + (position - 1).ToString(CultureInfo.InvariantCulture);
        }

        var integer = position <= 0 ? "0"
            : position >= kept.Length ? kept + new string('0', position - kept.Length)
            : kept[..position];
        var fraction = position <= 0 ? new string('0', -position) + kept
            : position >= kept.Length ? ""
            : kept[position..];
        return sign + (grouped ? Group(integer) : integer) + (fraction.Length > 0 ? "." + fraction : "");
    }

    private static string Group(string integer)
    {
        var builder = new StringBuilder();
        for (var i = 0; i < integer.Length; i++)
        {
            if (i > 0 && (integer.Length - i) % 3 == 0)
            {
                builder.Append(',');
            }

            builder.Append(integer[i]);
        }

        return builder.ToString();
    }

    /// <summary>同 Swift 的 trimmingCharacters(in: .whitespaces)：只去两头的空格类（Zs）和制表符，换行不去。</summary>
    private static string TrimSpaces(string text)
    {
        static bool IsSpace(char character) =>
            character == '\t' || char.GetUnicodeCategory(character) == UnicodeCategory.SpaceSeparator;

        var start = 0;
        var end = text.Length;
        while (start < end && IsSpace(text[start]))
        {
            start++;
        }

        while (end > start && IsSpace(text[end - 1]))
        {
            end--;
        }

        return text[start..end];
    }

    private sealed class Parser
    {
        private readonly char[] _characters;
        private int _index;

        public Parser(char[] characters) => _characters = characters;

        public bool AtEnd => _index == _characters.Length;

        private char? Current => _index < _characters.Length ? _characters[_index] : null;

        private bool Eat(char character)
        {
            if (Current != character)
            {
                return false;
            }

            _index++;
            return true;
        }

        /// <summary>expression := term (('+' | '-') term)*；右边是单独一个百分数时 a ± b% = a ×（1 ± b/100）。</summary>
        public double? Expression()
        {
            if (Term() is not { } first)
            {
                return null;
            }

            var value = first.Value;
            while (Current is '+' or '-')
            {
                var op = _characters[_index++];
                if (Term() is not { } rhs)
                {
                    return null;
                }

                var amount = rhs.IsPercent ? value * rhs.Value : rhs.Value;
                value = op == '+' ? value + amount : value - amount;
            }

            return value;
        }

        /// <summary>term := factor (('*' | '/' | mod) factor)*。IsPercent：整个 term 就是一个百分数（「10%」），给 a ± b% 用。</summary>
        private (double Value, bool IsPercent)? Term()
        {
            if (Factor() is not { } first)
            {
                return null;
            }

            var (value, isPercent) = first;
            while (Current is '*' or '/' or '|')
            {
                var op = _characters[_index++];
                if (Factor() is not { } rhs)
                {
                    return null;
                }

                isPercent = false;
                value = op switch
                {
                    '*' => value * rhs.Value,
                    '/' => value / rhs.Value,
                    _ => value % rhs.Value, // 同 Swift 的 truncatingRemainder（fmod）
                };
            }

            return (value, isPercent);
        }

        /// <summary>factor := unary '%'?：% 紧跟在数字 / 右括号后面、再往后是结尾、运算符或右括号时是百分号（b% = b/100）。</summary>
        private (double Value, bool IsPercent)? Factor()
        {
            if (Unary() is not { } value)
            {
                return null;
            }

            var next = _index + 1;
            if (Current != '%' || (next != _characters.Length && !"+-*/^|)".Contains(_characters[next])))
            {
                return (value, false);
            }

            _index = next;
            return (value / 100, true);
        }

        /// <summary>unary := '-' unary | '+' unary | power</summary>
        private double? Unary()
        {
            // 几千层括号 / 负号：算不出就算了，不让栈溢出把进程带走（所有递归都经过这里；mac 那边是直接崩）
            if (!RuntimeHelpers.TryEnsureSufficientExecutionStack())
            {
                return null;
            }

            if (Eat('-'))
            {
                return -Unary();
            }

            return Eat('+') ? Unary() : Power();
        }

        /// <summary>power := primary ('^' unary)?（右结合，指数可以带负号）</summary>
        private double? Power()
        {
            if (Primary() is not { } baseValue)
            {
                return null;
            }

            if (!Eat('^'))
            {
                return baseValue;
            }

            return Unary() is { } exponent ? Math.Pow(baseValue, exponent) : null;
        }

        /// <summary>primary := number | constant | function '(' expression ')' | '(' expression ')'</summary>
        private double? Primary()
        {
            if (Eat('('))
            {
                var value = Expression();
                return Eat(')') ? value : null;
            }

            return Current is { } character && char.IsLetter(character) ? Named() : Literal();
        }

        private double? Named()
        {
            var start = _index;
            while (Current is { } character && char.IsLetter(character))
            {
                _index++;
            }

            var name = new string(_characters, start, _index - start);
            switch (name)
            {
                case "pi":
                    return Math.PI;
                case "e":
                    return Math.E;
            }

            if (!Eat('(') || Expression() is not { } argument || !Eat(')'))
            {
                return null;
            }

            return name switch
            {
                "sqrt" => Math.Sqrt(argument),
                "abs" => Math.Abs(argument),
                "round" => Math.Round(argument, MidpointRounding.AwayFromZero), // Swift 的 rounded()：.5 远离 0
                "floor" => Math.Floor(argument),
                "ceil" => Math.Ceiling(argument),
                "sin" => Math.Sin(argument),
                "cos" => Math.Cos(argument),
                "tan" => Math.Tan(argument),
                "log" => Math.Log10(argument),
                "ln" => Math.Log(argument),
                "exp" => Math.Exp(argument),
                _ => null,
            };
        }

        private double? Literal()
        {
            if (Current == '0' && _index + 1 < _characters.Length && _characters[_index + 1] is 'x' or 'b' or 'o')
            {
                var radix = _characters[_index + 1] switch
                {
                    'x' => 16,
                    'b' => 2,
                    _ => 8,
                };
                _index += 2;
                long result = 0;
                var count = 0;
                while (Current is { } character && DigitValue(character) is { } digit && digit < radix)
                {
                    // 同 Swift 的 Int(_, radix:)：超出 Int64 是 nil
                    if (result > (long.MaxValue - digit) / radix)
                    {
                        return null;
                    }

                    result = result * radix + digit;
                    count++;
                    _index++;
                }

                if (count == 0)
                {
                    return null;
                }

                return result;
            }

            var begin = _index;
            while (Current is { } character && (char.IsAsciiDigit(character) || character == '.'))
            {
                _index++;
            }

            // 科学计数（1.15e18、9e-13）：只有 e 后面紧跟数字（或正负号加数字）才算指数，单独的 e 仍是常数
            if (_index > begin && Current == 'e')
            {
                var end = _index + 1;
                if (end < _characters.Length && _characters[end] is '+' or '-')
                {
                    end++;
                }

                if (end < _characters.Length && char.IsAsciiDigit(_characters[end]))
                {
                    _index = end;
                    while (Current is { } character && char.IsAsciiDigit(character))
                    {
                        _index++;
                    }
                }
            }

            return double.TryParse(
                new string(_characters, begin, _index - begin),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var number)
                ? number
                : null;
        }

        private static int? DigitValue(char character) => character switch
        {
            >= '0' and <= '9' => character - '0',
            >= 'a' and <= 'f' => character - 'a' + 10,
            >= 'A' and <= 'F' => character - 'A' + 10,
            _ => null,
        };
    }

    [GeneratedRegex(@"(\d)[,，](?=\d)")]
    private static partial Regex ThousandsRegex();

    [GeneratedRegex(@"\A[\d\s+\-*/%.()^a-zA-Z]+\z")]
    private static partial Regex MathCharsRegex();

    [GeneratedRegex(@"\d|\b(?:pi|e)\b")]
    private static partial Regex DigitOrConstantRegex();

    [GeneratedRegex(@"[+\-*/%^]|[a-z]+\s*\(|\bmod\b")]
    private static partial Regex OperatorRegex();

    [GeneratedRegex(@"\A0[xbo][0-9a-fA-F]+\z")]
    private static partial Regex RadixLiteralOnlyRegex();

    [GeneratedRegex(@"\A\d{2,4}-\d{1,2}-\d{1,4}\z")]
    private static partial Regex DateRegex();

    [GeneratedRegex(@"(?:^|[^0-9a-z])0[xbo][0-9a-f]")]
    private static partial Regex RadixLiteralRegex();

    [GeneratedRegex(
        @"\A([+\-]?\d+(?:\.\d+)?(?:e[+\-]?\d+)?)\s*(.+?)\s*(?:\s(?:to|in|as)\s|转换成|转成|换成|转|=|->|→)\s*(.+)\z",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ConvertRegex();

    [GeneratedRegex(
        @"\A(.+?)\s*(?:\s(?:in|to|as)\s|转换成|转成|转|=)\s*(hex|bin|oct|dec|十六进制|二进制|八进制|十进制)\z",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex RadixRegex();
}
