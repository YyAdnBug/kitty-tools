// 剪贴板入库前的敏感文本过滤（纯函数）：看起来像密钥 / 卡号的文本不记录。
// 规则和 mac 版一致：sk- / bearer 只量 token 本身；常见固定前缀的密钥；整段 13–19 位卡号过 Luhn。
namespace KittyTools.Core;

public static class SensitiveText
{
    public static bool LooksSensitive(string text)
    {
        var trimmed = text.Trim();
        if (EncodingByteCount(trimmed) < 8)
        {
            return false;
        }

        // 先折一次小写再按 Ordinal 找：大文本上比逐个前缀 OrdinalIgnoreCase 快一个数量级。
        var lower = trimmed.ToLowerInvariant();
        return HasToken(trimmed, lower, "sk-", 20, IsApiKeyChar)
               || HasToken(trimmed, lower, "bearer ", 24, IsBearerChar)
               || LooksLikeCardNumber(trimmed)
               || HasKnownSecret(trimmed, lower);
    }

    public static bool LooksLikeCardNumber(string text)
    {
        if (EncodingByteCount(text) > 64)
        {
            return false;
        }

        var digits = new char[text.Length];
        var count = 0;
        foreach (var ch in text)
        {
            if (ch is >= '0' and <= '9')
            {
                digits[count++] = ch;
            }
            else if (!char.IsWhiteSpace(ch) && ch != '-')
            {
                return false;
            }
        }

        if (count is < 13 or > 19)
        {
            return false;
        }

        return LuhnValid(new string(digits, 0, count));
    }

    public static bool LuhnValid(string digits)
    {
        var sum = 0;
        var doubleIt = false;
        for (var i = digits.Length - 1; i >= 0; i--)
        {
            var ch = digits[i];
            if (ch is < '0' or > '9')
            {
                return false;
            }

            var value = ch - '0';
            if (doubleIt)
            {
                value *= 2;
                if (value > 9)
                {
                    value -= 9;
                }
            }

            sum += value;
            doubleIt = !doubleIt;
        }

        return sum % 10 == 0;
    }

    private static bool HasKnownSecret(string text, string lower)
    {
        if (ContainsSecret(text, lower, "ghp_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, lower, "gho_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, lower, "ghu_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, lower, "ghs_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, lower, "ghr_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, lower, "github_pat_", 60, c => IsAsciiLetterOrDigit(c) || c == '_') ||
            ContainsSecret(text, lower, "akia", 16, c => IsAsciiLetterOrDigit(c)) ||
            ContainsSecret(text, lower, "xoxb-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "xoxa-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "xoxp-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "xoxo-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "xoxs-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "xoxr-", 10, IsSlackChar) ||
            ContainsSecret(text, lower, "aiza", 35, c => IsAsciiLetterOrDigit(c) || c is '_' or '-'))
        {
            return true;
        }

        if (lower.Contains("-----begin ", StringComparison.Ordinal) &&
            (lower.Contains("private key-----", StringComparison.Ordinal) ||
             lower.Contains("rsa private key-----", StringComparison.Ordinal) ||
             lower.Contains("ec private key-----", StringComparison.Ordinal)))
        {
            return true;
        }

        return LooksLikeJwt(text);
    }

    private static bool ContainsSecret(
        string text,
        string lower,
        string prefixLower,
        int minimumLength,
        Func<char, bool> allowed,
        bool requirePrefix = true)
    {
        var from = 0;
        while (from <= lower.Length - prefixLower.Length)
        {
            var index = lower.IndexOf(prefixLower, from, StringComparison.Ordinal);
            if (index < 0)
            {
                return false;
            }

            from = index + 1;
            if (index > 0 && char.IsAsciiLetterOrDigit(text[index - 1]))
            {
                continue;
            }

            if (!requirePrefix)
            {
                return true;
            }

            var count = 0;
            var cursor = index + prefixLower.Length;
            while (cursor < text.Length && allowed(text[cursor]))
            {
                count++;
                cursor++;
            }

            if (count >= minimumLength)
            {
                return true;
            }
        }

        return false;
    }

    private static bool LooksLikeJwt(string text)
    {
        // 先看有没有 JWT 的第二段标记：大文本里只有 eyJ、没有 .eyJ 时不必逐处找。
        if (!text.Contains(".eyJ", StringComparison.Ordinal))
        {
            return false;
        }

        var from = 0;
        while (from < text.Length - 10)
        {
            var first = text.IndexOf("eyJ", from, StringComparison.Ordinal);
            if (first < 0)
            {
                return false;
            }

            from = first + 1;
            if (first > 0 && char.IsAsciiLetterOrDigit(text[first - 1]))
            {
                continue;
            }

            var second = text.IndexOf(".eyJ", first + 3, StringComparison.Ordinal);
            if (second < 0 || second - (first + 3) < 10)
            {
                continue;
            }

            var third = text.IndexOf('.', second + 4);
            if (third < 0)
            {
                continue;
            }

            var thirdLength = 0;
            var cursor = third + 1;
            while (cursor < text.Length && IsJwtChar(text[cursor]))
            {
                thirdLength++;
                cursor++;
            }

            if (thirdLength >= 10)
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasToken(
        string text,
        string lower,
        string prefixLower,
        int minimumLength,
        Func<char, bool> allowed)
    {
        var from = 0;
        while (from <= lower.Length - prefixLower.Length)
        {
            var index = lower.IndexOf(prefixLower, from, StringComparison.Ordinal);
            if (index < 0)
            {
                return false;
            }

            from = index + 1;
            if (index > 0 && char.IsAsciiLetterOrDigit(text[index - 1]))
            {
                continue;
            }

            var length = 0;
            var hasDigit = false;
            var cursor = index + prefixLower.Length;
            while (cursor < text.Length && allowed(text[cursor]))
            {
                hasDigit |= char.IsAsciiDigit(text[cursor]);
                length++;
                cursor++;
            }

            if (length >= minimumLength && hasDigit)
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsAsciiLetterOrDigit(char ch) => char.IsAsciiLetterOrDigit(ch);

    private static bool IsApiKeyChar(char ch) => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_';

    private static bool IsBearerChar(char ch)
        => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_' or '.' or '~' or '+' or '/' or '=';

    private static bool IsSlackChar(char ch) => char.IsAsciiLetterOrDigit(ch) || ch == '-';

    private static bool IsJwtChar(char ch) => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_';

    private static int EncodingByteCount(string text) => System.Text.Encoding.UTF8.GetByteCount(text);
}
