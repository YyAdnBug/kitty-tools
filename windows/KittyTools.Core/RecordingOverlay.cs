// 录屏的点按圈 / 按键胶囊（第四版第 3 批）：直接画进录制的画面里（BGRA），不依赖透明窗口。
// 点按圈：按下时一个圈从 8 px 扩到 24 px、0.4 秒淡出（左键品牌粉、右键蓝）；
// 按键胶囊：底部居中，深色圆角条 + 白色文字（5×7 点阵字体，只画 ASCII 大写 / 数字 / + / 空格），1.5 秒淡出。
// 纯函数、配单测；录屏线程每帧调用一次。
namespace KittyTools.Core;

public readonly record struct ClickRing(int X, int Y, bool Right, long DownAt, long UpAt);

public readonly record struct Keycap(string Text, long At);

public static class RecordingOverlay
{
    public const int RingDurationMs = 400;

    public const int KeycapDurationMs = 1500;

    public const int RingMaxRadius = 24;

    public const int KeycapHeight = 34;

    /// <summary>把当前的点按圈 / 按键胶囊画到 BGRA 上（原地改）。</summary>
    public static void Render(
        byte[] bgra, int width, int height, long now,
        IReadOnlyList<ClickRing> rings, Keycap? keycap)
    {
        foreach (var ring in rings)
        {
            var start = ring.DownAt;
            var end = ring.UpAt > start ? Math.Min(ring.UpAt, start + RingDurationMs) : start + RingDurationMs;
            if (now < start || now > end)
            {
                continue;
            }

            var progress = (double)(now - start) / Math.Max(1, end - start);
            var radius = (int)(8 + (RingMaxRadius - 8) * progress);
            var alpha = (int)(200 * (1 - progress));
            var color = ring.Right ? (R: 74, G: 144, B: 255) : (R: 255, G: 150, B: 186);
            DrawCircle(bgra, width, height, ring.X, ring.Y, radius, color, Math.Clamp(alpha, 20, 200));
        }

        if (keycap is { } cap && now - cap.At <= KeycapDurationMs && !string.IsNullOrEmpty(cap.Text))
        {
            var fade = now - cap.At > KeycapDurationMs - 300
                ? 1 - (now - cap.At - (KeycapDurationMs - 300)) / 300.0
                : 1.0;
            DrawKeycap(bgra, width, height, cap.Text, Math.Clamp(fade, 0, 1));
        }
    }

    private static void DrawCircle(
        byte[] bgra, int width, int height, int cx, int cy, int radius,
        (int R, int G, int B) color, int alpha)
    {
        var minX = Math.Max(0, cx - radius - 2);
        var maxX = Math.Min(width - 1, cx + radius + 2);
        var minY = Math.Max(0, cy - radius - 2);
        var maxY = Math.Min(height - 1, cy + radius + 2);
        for (var y = minY; y <= maxY; y++)
        {
            for (var x = minX; x <= maxX; x++)
            {
                var dx = x - cx;
                var dy = y - cy;
                var distance = Math.Sqrt(dx * dx + dy * dy);
                if (Math.Abs(distance - radius) <= 2.2)
                {
                    Blend(bgra, (y * width + x) * 4, color, alpha);
                }
            }
        }
    }

    private static void DrawKeycap(byte[] bgra, int width, int height, string text, double fade)
    {
        var label = text.ToUpperInvariant();
        var scale = 2;
        var textWidth = label.Length * 6 * scale;
        var boxWidth = Math.Min(width - 8, textWidth + 24);
        var left = Math.Max(4, (width - boxWidth) / 2);
        var top = Math.Max(4, height - KeycapHeight - 16);
        var alpha = (int)(215 * fade);
        for (var y = top; y < Math.Min(height, top + KeycapHeight); y++)
        {
            for (var x = left; x < Math.Min(width, left + boxWidth); x++)
            {
                var edge = x <= left + 1 || x >= left + boxWidth - 2 || y <= top + 1 || y >= top + KeycapHeight - 2;
                Blend(bgra, (y * width + x) * 4, edge ? (120, 120, 130) : (32, 32, 36), alpha);
            }
        }

        var startX = left + (boxWidth - textWidth) / 2;
        var startY = top + (KeycapHeight - 7 * scale) / 2;
        for (var index = 0; index < label.Length; index++)
        {
            var glyph = Glyph(label[index]);
            for (var row = 0; row < 7; row++)
            {
                for (var column = 0; column < 5; column++)
                {
                    if (!glyph[row, column])
                    {
                        continue;
                    }

                    for (var sy = 0; sy < scale; sy++)
                    {
                        for (var sx = 0; sx < scale; sx++)
                        {
                            var x = startX + index * 6 * scale + column * scale + sx;
                            var y = startY + row * scale + sy;
                            if (x >= 0 && x < width && y >= 0 && y < height)
                            {
                                Blend(bgra, (y * width + x) * 4, (250, 250, 252), alpha);
                            }
                        }
                    }
                }
            }
        }
    }

    private static void Blend(byte[] bgra, int offset, (int R, int G, int B) color, int alpha)
    {
        var a = alpha / 255.0;
        bgra[offset] = (byte)(bgra[offset] * (1 - a) + color.B * a);
        bgra[offset + 1] = (byte)(bgra[offset + 1] * (1 - a) + color.G * a);
        bgra[offset + 2] = (byte)(bgra[offset + 2] * (1 - a) + color.R * a);
    }

    private static bool[,] Glyph(char ch) => ch switch
    {
        'A' => G("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
        'B' => G("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
        'C' => G("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
        'D' => G("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
        'E' => G("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
        'F' => G("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
        'G' => G("01110", "10001", "10000", "10111", "10001", "10001", "01111"),
        'H' => G("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
        'I' => G("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
        'J' => G("00111", "00010", "00010", "00010", "00010", "10010", "01100"),
        'K' => G("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
        'L' => G("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
        'M' => G("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
        'N' => G("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
        'O' => G("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
        'P' => G("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
        'Q' => G("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
        'R' => G("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
        'S' => G("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
        'T' => G("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
        'U' => G("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
        'V' => G("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
        'W' => G("10001", "10001", "10001", "10101", "10101", "11011", "10001"),
        'X' => G("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
        'Y' => G("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
        'Z' => G("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
        '0' => G("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
        '1' => G("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
        '2' => G("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
        '3' => G("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
        '4' => G("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
        '5' => G("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
        '6' => G("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
        '7' => G("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
        '8' => G("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
        '9' => G("01110", "10001", "10001", "01111", "00001", "00010", "01100"),
        '+' => G("00000", "00100", "00100", "11111", "00100", "00100", "00000"),
        ' ' => G("00000", "00000", "00000", "00000", "00000", "00000", "00000"),
        _ => G("11111", "10001", "10001", "10001", "10001", "10001", "11111"),
    };

    private static bool[,] G(params string[] rows)
    {
        var glyph = new bool[7, 5];
        for (var row = 0; row < Math.Min(7, rows.Length); row++)
        {
            for (var column = 0; column < Math.Min(5, rows[row].Length); column++)
            {
                glyph[row, column] = rows[row][column] == '1';
            }
        }

        return glyph;
    }
}
