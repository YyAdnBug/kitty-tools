// 启动器计算器（纯函数，配单测，第一版只要 PLAN §8 的范围）：+ - * /、括号、乘方（^ 或 **，右结合）、
// 百分号、小数、一元正负号。% 是百分号（同 macOS 计算器）：200*15% = 30、100+10% = 110、50% = 0.5。
// 中文输入法打出来的全角括号 / 数字 / 符号、× ÷、千分位逗号先归一；算式那一栏照常显示原文。
// 手写递归下降，半截表达式返回 null，不会崩。日期（2024-01-01）、单独一个数字不算算式。
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class Calculator
{
    public readonly record struct Result(string Display, string Payload);

    public static LauncherItem? ItemFor(string query)
    {
        var result = ResultFor(query);
        return result is null
            ? null
            : new LauncherItem
            {
                Kind = LauncherKind.Calculation,
                Target = query,
                Title = result.Value.Display,
                Subtitle = "计算结果 · Enter 粘贴 · Tab 接着算",
                Payload = result.Value.Payload,
                Completion = result.Value.Payload,
            };
    }

    public static Result? ResultFor(string query)
    {
        if (!LooksLikeMath(query))
        {
            return null;
        }

        var value = Evaluate(query);
        if (value is null || !double.IsFinite(value.Value))
        {
            return null;
        }

        var formatted = Format(value.Value);
        return new Result(formatted, formatted);
    }

    public static string Normalize(string query)
    {
        var text = query.Normalize(NormalizationForm.FormKC)
            .Replace('×', '*').Replace('✕', '*').Replace('÷', '/');
        return ThousandsRegex().Replace(text, "$1");
    }

    public static bool LooksLikeMath(string query)
    {
        var text = Normalize(query.Trim());
        if (text.Length < 3 || !MathCharsRegex().IsMatch(text) || !text.Any(char.IsAsciiDigit))
        {
            return false;
        }

        if (!OperatorRegex().IsMatch(text))
        {
            return false;
        }

        // 日期不是算式
        return !DateRegex().IsMatch(text);
    }

    public static double? Evaluate(string input)
    {
        var text = Normalize(input).ToLowerInvariant()
            .Replace("**", "^")
            .Where(character => !char.IsWhiteSpace(character))
            .ToArray();
        var parser = new Parser(text);
        var value = parser.Expression();
        return value is { } number && parser.AtEnd && double.IsFinite(number) ? number : null;
    }

    public static string Format(double value)
    {
        if (value == Math.Round(value) && Math.Abs(value) <= 9_007_199_254_740_992)
        {
            return ((long)value).ToString(CultureInfo.InvariantCulture);
        }

        var text = value.ToString("G12", CultureInfo.InvariantCulture);
        // G12 里 0.300000000000 这类已经处理掉；保险起见去掉多余的 0。
        if (text.Contains('.') && !text.Contains('E'))
        {
            text = text.TrimEnd('0').TrimEnd('.');
        }

        return text;
    }

    private sealed class Parser
    {
        private readonly char[] _characters;
        private int _index;

        public Parser(char[] characters) => _characters = characters;

        public bool AtEnd => _index >= _characters.Length;

        private char? Current => _index < _characters.Length ? _characters[_index] : null;

        public double? Expression()
        {
            var value = Term();
            if (value is null)
            {
                return null;
            }

            var result = value.Value.Value;
            while (Current is '+' or '-')
            {
                var op = Current.Value;
                _index++;
                var rhs = Term();
                if (rhs is null)
                {
                    return null;
                }

                var amount = rhs.Value.IsPercent ? result * rhs.Value.Value : rhs.Value.Value;
                result = op == '+' ? result + amount : result - amount;
            }

            return result;
        }

        private (double Value, bool IsPercent)? Term()
        {
            var first = Factor();
            if (first is null)
            {
                return null;
            }

            var value = first.Value.Value;
            var isPercent = first.Value.IsPercent;
            while (Current is '*' or '/')
            {
                var op = Current.Value;
                _index++;
                var rhs = Factor();
                if (rhs is null)
                {
                    return null;
                }

                value = op == '*' ? value * rhs.Value.Value : value / rhs.Value.Value;
                isPercent = false;
            }

            return (value, isPercent);
        }

        private (double Value, bool IsPercent)? Factor()
        {
            var value = Unary();
            if (value is null)
            {
                return null;
            }

            if (Current == '%' &&
                (_index + 1 >= _characters.Length || "+-*/^)".Contains(_characters[_index + 1])))
            {
                _index++;
                return (value.Value / 100, true);
            }

            return (value.Value, false);
        }

        private double? Unary()
        {
            if (Current == '-')
            {
                _index++;
                var value = Unary();
                return value is null ? null : -value;
            }

            if (Current == '+')
            {
                _index++;
                return Unary();
            }

            return Power();
        }

        private double? Power()
        {
            var baseValue = Primary();
            if (baseValue is null)
            {
                return null;
            }

            if (Current != '^')
            {
                return baseValue;
            }

            _index++;
            var exponent = Unary();
            return exponent is null ? null : Math.Pow(baseValue.Value, exponent.Value);
        }

        private double? Primary()
        {
            if (Current == '(')
            {
                _index++;
                var value = Expression();
                if (value is null || Current != ')')
                {
                    return null;
                }

                _index++;
                return value;
            }

            var start = _index;
            while (Current is { } character && (char.IsAsciiDigit(character) || character == '.'))
            {
                _index++;
            }

            if (start == _index)
            {
                return null;
            }

            return double.TryParse(
                new string(_characters, start, _index - start),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var number)
                ? number
                : null;
        }
    }

    [GeneratedRegex(@"(\d)[,，](?=\d)")]
    private static partial Regex ThousandsRegex();

    [GeneratedRegex(@"^[\d\s+\-*/%^().]+$")]
    private static partial Regex MathCharsRegex();

    [GeneratedRegex(@"[+\-*/%^]")]
    private static partial Regex OperatorRegex();

    [GeneratedRegex(@"^\d{2,4}-\d{1,2}-\d{1,4}$")]
    private static partial Regex DateRegex();
}
