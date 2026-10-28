// 剪贴板透镜 / 放大预览的纯函数（配单测）：JSON 美化（mac 默认美化，体检 A10）、语法着色（照 mac PreviewView.swift 的
// SyntaxHighlight：数字、关键字、字符串、JSON 的键、注释）、颜色的四种写法和色块上用黑字还是白字（mac ColorCard）。
using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum SyntaxKind : byte
{
    Plain,
    Number,
    Keyword,
    String,
    Key,
    Comment,
}

public static partial class ClipPreviewRules
{
    /// <summary>JSON 美化（缩进 2，中文不转义）；不是合法 JSON 时 null。</summary>
    public static string? PrettyJson(string? text)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length > 512_000)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            using var stream = new MemoryStream();
            using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
            {
                Indented = true,
                Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            }))
            {
                document.WriteTo(writer);
            }

            return System.Text.Encoding.UTF8.GetString(stream.ToArray());
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// 语法着色：返回连续的（起点、长度、种类）段，盖满整段文字（前 2 万字之后都是 Plain）。
    /// 后画的盖前画的（同 mac）：数字 → 关键字 → JSON 的字符串、键 / 代码的字符串和注释（一趟从左往右扫，先开始的赢）。
    /// </summary>
    public static List<(int Start, int Length, SyntaxKind Kind)> Highlight(string text, bool json)
    {
        var limit = Math.Min(text.Length, 20_000);
        var kinds = new SyntaxKind[text.Length];
        var sample = text[..limit];
        void Paint(Regex regex, SyntaxKind kind, int group = 0)
        {
            foreach (Match match in regex.Matches(sample))
            {
                var part = match.Groups[group];
                Array.Fill(kinds, kind, part.Index, part.Length);
            }
        }

        Paint(NumberPattern(), SyntaxKind.Number);
        Paint(json ? JsonWordPattern() : KeywordPattern(), SyntaxKind.Keyword);
        if (json)
        {
            Paint(JsonStringPattern(), SyntaxKind.String);
            Paint(JsonKeyPattern(), SyntaxKind.Key, group: 1);
        }
        else
        {
            foreach (Match match in CodeTokenPattern().Matches(sample))
            {
                Array.Fill(kinds, match.Value.StartsWith('/') ? SyntaxKind.Comment : SyntaxKind.String, match.Index, match.Length);
            }
        }

        var spans = new List<(int Start, int Length, SyntaxKind Kind)>();
        var start = 0;
        for (var index = 1; index <= kinds.Length; index++)
        {
            if (index == kinds.Length || kinds[index] != kinds[start])
            {
                spans.Add((start, index - start, kinds[start]));
                start = index;
            }
        }

        return spans;
    }

    /// <summary>
    /// 颜色的四种写法（透镜里的四枚值胶囊、放大卡）：#RRGGBB(AA)、rgb()、hsl() / hsla()、rgba()。
    /// 第 4 枚照拍板 D6 写 CSS 的 rgba（mac 是 SwiftUI 的 Color(...)）。
    /// </summary>
    public static string[] ColorValues(Rgba color)
    {
        var r = (int)Math.Round(color.Red * 255);
        var g = (int)Math.Round(color.Green * 255);
        var b = (int)Math.Round(color.Blue * 255);
        var translucent = color.Alpha < 1;
        var alpha = color.Alpha.ToString("0.00", CultureInfo.InvariantCulture);
        var (hue, saturation, lightness) = Hsl(color);
        var hsl = $"{hue}, {saturation}%, {lightness}%";
        return new[]
        {
            $"#{r:X2}{g:X2}{b:X2}" + (translucent ? $"{(int)Math.Round(color.Alpha * 255):X2}" : string.Empty),
            $"rgb({r}, {g}, {b})",
            translucent ? $"hsla({hsl}, {alpha})" : $"hsl({hsl})",
            $"rgba({r}, {g}, {b}, {alpha})",
        };
    }

    /// <summary>色块上的字用黑还是白：很透明时底下是浅色棋盘格，按浅色算（mac ColorCard.isLight）。</summary>
    public static bool IsLight(Rgba color)
        => color.Alpha < 0.5 || 0.299 * color.Red + 0.587 * color.Green + 0.114 * color.Blue > 0.62;

    private static (int Hue, int Saturation, int Lightness) Hsl(Rgba color)
    {
        var max = Math.Max(color.Red, Math.Max(color.Green, color.Blue));
        var min = Math.Min(color.Red, Math.Min(color.Green, color.Blue));
        var lightness = (max + min) / 2;
        var delta = max - min;
        double hue = 0, saturation = 0;
        if (delta > 1e-9)
        {
            saturation = delta / (1 - Math.Abs(2 * lightness - 1));
            hue = max == color.Red ? (color.Green - color.Blue) / delta % 6
                : max == color.Green ? (color.Blue - color.Red) / delta + 2
                : (color.Red - color.Green) / delta + 4;
            hue *= 60;
            if (hue < 0)
            {
                hue += 360;
            }
        }

        return ((int)Math.Round(hue) % 360, (int)Math.Round(saturation * 100), (int)Math.Round(lightness * 100));
    }

    [GeneratedRegex(@"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b")]
    private static partial Regex NumberPattern();

    [GeneratedRegex(@"\b(true|false|null)\b")]
    private static partial Regex JsonWordPattern();

    [GeneratedRegex(@"\b(func|let|var|if|else|for|while|return|import|struct|class|enum|case|switch|true|false|nil|null|const|function|def|public|private|static|new|this|self|in|try|catch|async|await|guard|break|continue|type|interface|extends|package|fn|pub|use|mut|impl|match)\b")]
    private static partial Regex KeywordPattern();

    [GeneratedRegex(@"""(?:\\.|[^""\\\n])*""")]
    private static partial Regex JsonStringPattern();

    [GeneratedRegex(@"(""(?:\\.|[^""\\\n])*"")\s*:")]
    private static partial Regex JsonKeyPattern();

    [GeneratedRegex(@"""(?:\\.|[^""\\\n])*""|'(?:\\.|[^'\\\n])*'|//[^\n]*|/\*[\s\S]*?\*/")]
    private static partial Regex CodeTokenPattern();

}
