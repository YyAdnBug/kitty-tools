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

        return HasToken(trimmed, "sk-", 20, IsApiKeyChar)
               || HasToken(trimmed, "bearer ", 24, IsBearerChar)
               || LooksLikeCardNumber(trimmed)
               || HasKnownSecret(trimmed);
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

    private static bool HasKnownSecret(string text)
    {
        if (ContainsSecret(text, "ghp_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, "gho_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, "ghu_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, "ghs_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, "ghr_", 36, IsAsciiLetterOrDigit) ||
            ContainsSecret(text, "github_pat_", 60, c => IsAsciiLetterOrDigit(c) || c == '_') ||
            ContainsSecret(text, "AKIA", 16, c => c is >= 'A' and <= 'Z' or >= '0' and <= '9') ||
            ContainsSecret(text, "xoxb-", 10, IsSlackChar) ||
            ContainsSecret(text, "xoxa-", 10, IsSlackChar) ||
            ContainsSecret(text, "xoxp-", 10, IsSlackChar) ||
            ContainsSecret(text, "xoxo-", 10, IsSlackChar) ||
            ContainsSecret(text, "xoxs-", 10, IsSlackChar) ||
            ContainsSecret(text, "xoxr-", 10, IsSlackChar) ||
            ContainsSecret(text, "AIza", 35, c => IsAsciiLetterOrDigit(c) || c is '_' or '-'))
        {
            return true;
        }

        if (text.Contains("-----BEGIN ", StringComparison.Ordinal) &&
            (text.Contains("PRIVATE KEY-----", StringComparison.Ordinal) ||
             text.Contains("RSA PRIVATE KEY-----", StringComparison.Ordinal) ||
             text.Contains("EC PRIVATE KEY-----", StringComparison.Ordinal)))
        {
            return true;
        }

        return LooksLikeJwt(text);
    }

    private static bool ContainsSecret(
        string text,
        string prefix,
        int minimumLength,
        Func<char, bool> allowed,
        bool requirePrefix = true)
    {
        var from = 0;
        while (from <= text.Length - prefix.Length)
        {
            var index = text.IndexOf(prefix, from, StringComparison.OrdinalIgnoreCase);
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
            var cursor = index + prefix.Length;
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

    private static bool HasToken(string text, string prefix, int minimumLength, Func<char, bool> allowed)
    {
        var from = 0;
        while (from <= text.Length - prefix.Length)
        {
            var index = text.IndexOf(prefix, from, StringComparison.OrdinalIgnoreCase);
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
            var cursor = index + prefix.Length;
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
