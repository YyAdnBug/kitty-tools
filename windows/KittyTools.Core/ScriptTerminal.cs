// 全部输出那一页认终端颜色（PLAN-v18 L1，mac ScriptTerminal.swift 第三轮 A2；纯函数，配单测）：SGR 颜色码 → 一段段带「笔」的字。
// 颜色：0–255 是调色板（0–15 由 App 按深浅色调过，16–255 照 xterm 的算法），24 位的记成 0x1000000 | RGB；粗体、暗、斜体、下划线、
// 删除线。别的控制码（光标移动、标题、超链接）去掉；单独的回车同终端（ScriptText.CarriageReturns）。截在一个控制码中间的末尾那半截先不要。
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public sealed record TerminalPen
{
    public int? Foreground { get; init; }

    public int? Background { get; init; }

    public bool Bold { get; init; }

    public bool Dim { get; init; }

    public bool Italic { get; init; }

    public bool Underline { get; init; }

    public bool Strike { get; init; }

    public static readonly TerminalPen Plain = new();

    /// <summary>24 位颜色的标记位。</summary>
    public const int RgbFlag = 0x1000000;
}

public readonly record struct TerminalSpan(string Text, TerminalPen Pen);

public static partial class ScriptTerminal
{
    [GeneratedRegex(@"\u001B(?:\[([0-9;:?]*)[ -/]*([@-~])|\][^\u0007\u001B]*(?:\u0007|\u001B\\)?|[@-_])")]
    private static partial Regex EscapePattern();

    public static List<TerminalSpan> Spans(string output)
    {
        var text = DroppingPartialEscape(ScriptText.CarriageReturns(output));
        var spans = new List<TerminalSpan>();
        var pen = TerminalPen.Plain;
        var start = 0;
        void Add(int end)
        {
            if (end > start)
            {
                spans.Add(new TerminalSpan(text[start..end], pen));
            }
        }

        if (text.IndexOf('\u001B') < 0)
        {
            Add(text.Length);
            return spans;
        }

        foreach (Match match in EscapePattern().Matches(text))
        {
            Add(match.Index);
            start = match.Index + match.Length;
            if (match.Groups[2].Value == "m" && !match.Groups[1].Value.Contains('?'))
            {
                pen = Apply(match.Groups[1].Value, pen);
            }
        }

        Add(text.Length);
        return spans;
    }

    /// <summary>截在一个控制码中间的（边跑边显示时写到一半）：末尾那半截先不要。</summary>
    public static string DroppingPartialEscape(string text)
    {
        var escape = text.LastIndexOf('\u001B');
        if (escape < 0)
        {
            return text;
        }

        var rest = text[(escape + 1)..];
        var complete = rest.Length switch
        {
            0 => false,
            _ when rest[0] == '[' => rest[1..].Any(ch => ch is >= '@' and <= '~'),
            _ when rest[0] == ']' => rest.Contains('\u0007') || rest.Contains("\u001B\\"),
            _ => true,
        };
        return complete ? text : text[..escape];
    }

    /// <summary>一个 SGR 改笔：0 重来；38 / 48 带 5;n（256 色）或 2;r;g;b（24 位）；认不出的跳过。</summary>
    public static TerminalPen Apply(string parameters, TerminalPen pen)
    {
        var codes = parameters.Length == 0
            ? new List<int> { 0 }
            : parameters.Split(';', ':').Select(part => int.TryParse(part, out var value) ? value : 0).ToList();
        for (var index = 0; index < codes.Count; index++)
        {
            var code = codes[index];
            switch (code)
            {
                case 0:
                    pen = TerminalPen.Plain;
                    break;
                case 1:
                    pen = pen with { Bold = true };
                    break;
                case 2:
                    pen = pen with { Dim = true };
                    break;
                case 3:
                    pen = pen with { Italic = true };
                    break;
                case 4:
                    pen = pen with { Underline = true };
                    break;
                case 9:
                    pen = pen with { Strike = true };
                    break;
                case 22:
                    pen = pen with { Bold = false, Dim = false };
                    break;
                case 23:
                    pen = pen with { Italic = false };
                    break;
                case 24:
                    pen = pen with { Underline = false };
                    break;
                case 29:
                    pen = pen with { Strike = false };
                    break;
                case >= 30 and <= 37:
                    pen = pen with { Foreground = code - 30 };
                    break;
                case >= 90 and <= 97:
                    pen = pen with { Foreground = code - 90 + 8 };
                    break;
                case 39:
                    pen = pen with { Foreground = null };
                    break;
                case >= 40 and <= 47:
                    pen = pen with { Background = code - 40 };
                    break;
                case >= 100 and <= 107:
                    pen = pen with { Background = code - 100 + 8 };
                    break;
                case 49:
                    pen = pen with { Background = null };
                    break;
                case 38 or 48:
                    int? color = null;
                    if (index + 2 < codes.Count && codes[index + 1] == 5)
                    {
                        color = Math.Clamp(codes[index + 2], 0, 255);
                        index += 2;
                    }
                    else if (index + 4 < codes.Count && codes[index + 1] == 2)
                    {
                        color = TerminalPen.RgbFlag | (Math.Clamp(codes[index + 2], 0, 255) << 16) |
                                (Math.Clamp(codes[index + 3], 0, 255) << 8) | Math.Clamp(codes[index + 4], 0, 255);
                        index += 4;
                    }

                    if (color is { } chosen)
                    {
                        pen = code == 38 ? pen with { Foreground = chosen } : pen with { Background = chosen };
                    }

                    break;
            }
        }

        return pen;
    }

    /// <summary>调色板 16–255 的 RGB（xterm：6×6×6 的立方 + 24 级灰）；0–15 由 App 按深浅色给。</summary>
    public static int PaletteRgb(int index)
    {
        if (index >= 232)
        {
            var level = 8 + (index - 232) * 10;
            return (level << 16) | (level << 8) | level;
        }

        var cube = index - 16;
        static int Step(int value) => value == 0 ? 0 : 55 + value * 40;
        return (Step(cube / 36 % 6) << 16) | (Step(cube / 6 % 6) << 8) | Step(cube % 6);
    }
}
