// 文本条目的内容形态（行图标、透镜、筛选用；照 mac Clipboard/ContentForm.swift），优先级：颜色 > JSON > 链接 > 代码。纯函数，配单测。
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum ContentForm
{
    Color,
    Json,
    Link,
    Code,
}

/// <summary>0…1 的 sRGB 分量。</summary>
public readonly record struct Rgba(double Red, double Green, double Blue, double Alpha);

public static partial class ContentForms
{
    public static string Title(ContentForm form) => form switch
    {
        ContentForm.Color => "颜色",
        ContentForm.Json => "JSON",
        ContentForm.Link => "链接",
        _ => "代码",
    };

    /// <summary>没有特别形态时 null（普通文本）。</summary>
    public static ContentForm? Detect(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        var trimmed = text.Trim();
        if (Color(trimmed) is not null)
        {
            return ContentForm.Color;
        }

        if (IsJson(trimmed))
        {
            return ContentForm.Json;
        }

        if (LinkPreviewRules.SingleUrl(trimmed) is not null)
        {
            return ContentForm.Link;
        }

        return LooksLikeCode(trimmed) ? ContentForm.Code : null;
    }

    /// <summary>整段是一个颜色值：#RGB / #RGBA / #RRGGBB / #RRGGBBAA、rgb()/rgba()、hsl()/hsla()。</summary>
    public static Rgba? Color(string? text)
    {
        if (text is null)
        {
            return null;
        }

        text = text.Trim();
        if (text.Length is 0 or > 64)
        {
            return null;
        }

        if (HexColor().Match(text) is { Success: true } hexMatch)
        {
            var hex = hexMatch.Groups[1].Value;
            if (hex.Length <= 4)
            {
                hex = string.Concat(hex.Select(ch => new string(ch, 2)));
            }

            if (hex.Length == 6)
            {
                hex += "ff";
            }

            var value = uint.Parse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            double Channel(int shift) => ((value >> shift) & 0xff) / 255.0;
            return new Rgba(Channel(24), Channel(16), Channel(8), Channel(0));
        }

        if (FunctionColor().Match(text.ToLowerInvariant()) is not { Success: true } match)
        {
            return null;
        }

        var parts = match.Groups[2].Value.Split(',').Select(part => part.Trim()).ToArray();
        var values = new List<double>();
        foreach (var part in parts)
        {
            var number = part.EndsWith('%') ? part[..^1] : part;
            if (!double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
            {
                return null;
            }

            values.Add(parsed);
        }

        if (values.Count is < 3 or > 4)
        {
            return null;
        }

        var alpha = values.Count == 4 ? Math.Clamp(values[3], 0, 1) : 1;
        if (match.Groups[1].Value.StartsWith("rgb", StringComparison.Ordinal))
        {
            double Clamp(double v) => Math.Clamp(v, 0, 255) / 255;
            return new Rgba(Clamp(values[0]), Clamp(values[1]), Clamp(values[2]), alpha);
        }

        // HSL → RGB
        var hue = values[0] % 360 / 360;
        var saturation = Math.Clamp(values[1], 0, 100) / 100;
        var lightness = Math.Clamp(values[2], 0, 100) / 100;
        var q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation;
        var p = 2 * lightness - q;
        double Component(double offset)
        {
            var t = hue + offset;
            if (t < 0)
            {
                t += 1;
            }

            if (t > 1)
            {
                t -= 1;
            }

            if (t < 1.0 / 6)
            {
                return p + (q - p) * 6 * t;
            }

            if (t < 1.0 / 2)
            {
                return q;
            }

            return t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
        }

        return new Rgba(Component(1.0 / 3), Component(0), Component(-1.0 / 3), alpha);
    }

    /// <summary>文本里第一个 http(s) 链接（Ctrl+O「打开链接」用）。</summary>
    public static Uri? FirstLink(string? text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > 512_000)
        {
            return null;
        }

        foreach (Match match in LinkCandidate().Matches(text))
        {
            var candidate = match.Value.TrimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}', '。', '，', '；', '：', '！', '？', '）', '」', '』', '"', '\'');
            if (Uri.TryCreate(candidate, UriKind.Absolute, out var uri) &&
                (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
            {
                return uri;
            }
        }

        return null;
    }

    private static bool IsJson(string text)
    {
        if (text.Length == 0 || (text[0] != '{' && text[0] != '[') || text.Length > 512_000)
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>ponytail: 关键词 + 符号的粗略启发式（照 mac），会有漏判误判；够筛选和挑字体用。</summary>
    private static bool LooksLikeCode(string text)
    {
        var sample = text.Length > 4000 ? text[..4000] : text;
        if (sample.StartsWith("#!", StringComparison.Ordinal))
        {
            return true;
        }

        var lines = sample.Split('\n');
        if (lines.Length < 2)
        {
            return false;
        }

        if (KeywordLine().IsMatch(sample))
        {
            return true;
        }

        var semicolonLines = lines.Count(line => line.TrimEnd('\r', ' ', '\t').EndsWith(';'));
        return lines.Length >= 3 && ((sample.Contains('{') && sample.Contains('}')) || semicolonLines >= 2);
    }

    [GeneratedRegex("^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")]
    private static partial Regex HexColor();

    [GeneratedRegex(@"^(rgba?|hsla?)\(([^()]*)\)$")]
    private static partial Regex FunctionColor();

    [GeneratedRegex(@"https?://\S+", RegexOptions.IgnoreCase)]
    private static partial Regex LinkCandidate();

    [GeneratedRegex(
        @"^\s*(import|export|func|function|class|struct|const|let|var|def|#include|package|public|private|interface|enum|select|insert|update|create|return)\b",
        RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex KeywordLine();
}
