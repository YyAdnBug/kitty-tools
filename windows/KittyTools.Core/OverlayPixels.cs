// 截图翻译原位覆盖的像素那一半（照 mac ScreenshotOverlay 的 Pixels / Snapshot / TileModes，纯函数配单测）：
// BGRA 各 8 位、不透明（截图）的一块像素；坐标按左下原点（和覆盖层的几何一致），读写时换行号。
// 去字（只换字的像素，用左右上下最近的非字像素插值补）、每小块的底色、每行的基线、行内代码块、段框外一圈的底色都在这里。
namespace KittyTools.Core;

public sealed class OverlayPixels
{
    private readonly byte[] _bytes;

    public OverlayPixels(byte[] bgra, int width, int height, int stride)
    {
        _bytes = bgra;
        Width = width;
        Height = height;
        Stride = stride;
    }

    public int Width { get; }

    public int Height { get; }

    public int Stride { get; }

    /// <summary>底下那份字节（BGRA）。</summary>
    public byte[] Bytes => _bytes;

    /// <summary>改之前的一份拷贝：判断哪些是字、取底色都看它。</summary>
    public OverlayPixels Snapshot() => new((byte[])_bytes.Clone(), Width, Height, Stride);

    public bool Contains(int x, int y) => x >= 0 && x < Width && y >= 0 && y < Height;

    /// <summary>y 按左下原点：数据里第 0 行是图像顶部。预乘的除回去；全透明按白算。</summary>
    public (int R, int G, int B) Raw(int x, int y)
    {
        var offset = (Height - 1 - y) * Stride + x * 4;
        int alpha = _bytes[offset + 3];
        if (alpha <= 4)
        {
            return (255, 255, 255);
        }

        int b = _bytes[offset], g = _bytes[offset + 1], r = _bytes[offset + 2];
        if (alpha >= 255)
        {
            return (r, g, b);
        }

        return (Math.Min(255, r * 255 / alpha), Math.Min(255, g * 255 / alpha), Math.Min(255, b * 255 / alpha));
    }

    public OverlayRgb Color(int x, int y)
    {
        var (r, g, b) = Raw(x, y);
        return new OverlayRgb(r / 255.0, g / 255.0, b / 255.0);
    }

    public void Write(OverlayRgb color, int x, int y)
    {
        var offset = (Height - 1 - y) * Stride + x * 4;
        _bytes[offset] = (byte)Math.Round(Math.Clamp(color.Blue, 0, 1) * 255);
        _bytes[offset + 1] = (byte)Math.Round(Math.Clamp(color.Green, 0, 1) * 255);
        _bytes[offset + 2] = (byte)Math.Round(Math.Clamp(color.Red, 0, 1) * 255);
        _bytes[offset + 3] = 255;
    }

    /// <summary>一块像素里出现最多的颜色（按 5 位量化分桶，桶里取平均）。</summary>
    public OverlayRgb? Mode(int x0, int x1, int y0, int y1)
    {
        var counts = new Dictionary<int, (int Count, int Red, int Green, int Blue)>();
        for (var y = Math.Max(0, y0); y < Math.Min(Height, y1); y++)
        {
            for (var x = Math.Max(0, x0); x < Math.Min(Width, x1); x++)
            {
                var (r, g, b) = Raw(x, y);
                var key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
                counts.TryGetValue(key, out var old);
                counts[key] = (old.Count + 1, old.Red + r, old.Green + g, old.Blue + b);
            }
        }

        if (counts.Count == 0)
        {
            return null;
        }

        var best = counts.Values.MaxBy(value => value.Count);
        var n = best.Count * 255.0;
        return new OverlayRgb(best.Red / n, best.Green / n, best.Blue / n);
    }

    internal TileModes Tiles(int x0, int x1, int y0, int y1, double lineHeight)
    {
        var tile = Math.Max(6, (int)Math.Round(lineHeight, MidpointRounding.AwayFromZero));
        var columns = (x1 - x0 + tile - 1) / tile;
        var rows = (y1 - y0 + tile - 1) / tile;
        var modes = new OverlayRgb[Math.Max(0, columns * rows)];
        for (var ty = 0; ty < rows; ty++)
        {
            for (var tx = 0; tx < columns; tx++)
            {
                modes[ty * columns + tx] = Mode(
                    x0 + tx * tile, Math.Min(x1, x0 + (tx + 1) * tile), y0 + ty * tile, Math.Min(y1, y0 + (ty + 1) * tile)) ?? OverlayRgb.Light;
            }
        }

        return new TileModes(x0, y0, tile, columns, modes);
    }

    internal readonly record struct TileModes(int X0, int Y0, int Tile, int Columns, OverlayRgb[] Modes)
    {
        public OverlayRgb At(int x, int y) => Modes[((y - Y0) / Tile) * Columns + (x - X0) / Tile];
    }

    private static int Down(double value) => (int)Math.Floor(value);

    private static int Up(double value) => (int)Math.Ceiling(value);

    private static int Round(double value) => (int)Math.Round(value, MidpointRounding.AwayFromZero);

    /// <summary>
    /// 把范围里原文的字去掉（写进 this），判断看 original，返回原文的字色（取不到 null）。
    /// ① 每一小块（边长约一个行高）出现最多的颜色当这一块的底色；② 和所在小块的底色差过门槛的像素算字（clearFills 时和页面底
    /// 有一点不一样的也算：代码块的底框连字一起去掉），再往外扩一两像素；③ 字的像素用同一行左右、同一列上下最近的非字像素插值补上。
    /// </summary>
    public OverlayRgb? Inpaint(OverlayRect rect, OverlayPixels original, double lineHeight, OverlayRgb background, bool clearFills)
    {
        var x0 = Math.Max(0, Down(rect.MinX));
        var x1 = Math.Min(Width, Up(rect.MaxX));
        var y0 = Math.Max(0, Down(rect.MinY));
        var y1 = Math.Min(Height, Up(rect.MaxY));
        var w = x1 - x0;
        var h = y1 - y0;
        if (w <= 0 || h <= 0)
        {
            return null;
        }

        var modes = original.Tiles(x0, x1, y0, y1, lineHeight);
        var ink = new bool[w * h];
        var samples = new List<(double, OverlayRgb)>();
        for (var y = y0; y < y1; y++)
        {
            for (var x = x0; x < x1; x++)
            {
                var color = original.Color(x, y);
                var local = modes.At(x, y);
                var distance = color.Distance(local);
                if (distance > ScreenshotOverlay.InkLimit)
                {
                    ink[(y - y0) * w + (x - x0)] = true;
                    if (local.Distance(background) < 0.06)
                    {
                        samples.Add((distance, color));
                    }
                }
                else if (clearFills && color.Distance(background) > ScreenshotOverlay.FillLimit)
                {
                    ink[(y - y0) * w + (x - x0)] = true;
                }
            }
        }

        var radius = Math.Max(1, Round(lineHeight * 0.06));
        var mask = Dilate(ink, w, h, radius);
        var fills = new OverlayRgb?[w * h];
        for (var y = 0; y < h; y++)
        {
            var x = 0;
            while (x < w)
            {
                if (!mask[y * w + x])
                {
                    x++;
                    continue;
                }

                var end = x;
                while (end < w && mask[y * w + end])
                {
                    end++;
                }

                OverlayRgb? left = x > 0 ? original.Color(x0 + x - 1, y0 + y) : null;
                OverlayRgb? right = end < w ? original.Color(x0 + end, y0 + y) : null;
                for (var i = x; i < end; i++)
                {
                    fills[y * w + i] = Blend(left, right, (double)(i - x + 1) / (end - x + 1));
                }

                x = end;
            }
        }

        for (var x = 0; x < w; x++)
        {
            var y = 0;
            while (y < h)
            {
                if (!mask[y * w + x])
                {
                    y++;
                    continue;
                }

                var end = y;
                while (end < h && mask[end * w + x])
                {
                    end++;
                }

                OverlayRgb? low = y > 0 ? original.Color(x0 + x, y0 + y - 1) : null;
                OverlayRgb? high = end < h ? original.Color(x0 + x, y0 + end) : null;
                for (var i = y; i < end; i++)
                {
                    var vertical = Blend(low, high, (double)(i - y + 1) / (end - y + 1));
                    var horizontal = fills[i * w + x];
                    var color = (horizontal, vertical) switch
                    {
                        ({ } a, { } b) => Blend(a, b, 0.5) ?? a,
                        ({ } a, null) => a,
                        (null, { } b) => b,
                        _ => clearFills ? background : modes.At(x0 + x, y0 + i),
                    };
                    Write(color, x0 + x, y0 + i);
                }

                y = end;
            }
        }

        return ScreenshotOverlay.Dominant(samples);
    }

    private static OverlayRgb? Blend(OverlayRgb? a, OverlayRgb? b, double t) => (a, b) switch
    {
        ({ } first, { } second) => new OverlayRgb(
            first.Red + (second.Red - first.Red) * t,
            first.Green + (second.Green - first.Green) * t,
            first.Blue + (second.Blue - first.Blue) * t),
        ({ } first, null) => first,
        (null, { } second) => second,
        _ => null,
    };

    /// <summary>掩码往外扩 radius 像素（先横后竖，方形）。</summary>
    private static bool[] Dilate(bool[] mask, int width, int height, int radius)
    {
        var rows = new bool[mask.Length];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                if (!mask[y * width + x])
                {
                    continue;
                }

                for (var i = Math.Max(0, x - radius); i <= Math.Min(width - 1, x + radius); i++)
                {
                    rows[y * width + i] = true;
                }
            }
        }

        var result = new bool[mask.Length];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                if (!rows[y * width + x])
                {
                    continue;
                }

                for (var j = Math.Max(0, y - radius); j <= Math.Min(height - 1, y + radius); j++)
                {
                    result[j * width + x] = true;
                }
            }
        }

        return result;
    }

    /// <summary>
    /// 段里每一行字的基线（像素、原点左下，从上往下）：每一排数有多少字的像素，按空白的排切成一行行，
    /// 每行里字最密的那一截的下沿就是基线（识字的行框量不准：带行内代码块的行，框会被撑高）。
    /// </summary>
    public List<double> Baselines(OverlayRect box, double lineHeight)
    {
        var result = new List<double>();
        var x0 = Math.Max(0, Down(box.MinX));
        var x1 = Math.Min(Width, Up(box.MaxX));
        var y0 = Math.Max(0, Down(box.MinY));
        var y1 = Math.Min(Height, Up(box.MaxY));
        if (x1 <= x0 || y1 <= y0)
        {
            return result;
        }

        var modes = Tiles(x0, x1, y0, y1, lineHeight);
        var counts = new int[y1 - y0];
        for (var y = y0; y < y1; y++)
        {
            for (var x = x0; x < x1; x++)
            {
                if (Color(x, y).Distance(modes.At(x, y)) > ScreenshotOverlay.InkLimit)
                {
                    counts[y - y0]++;
                }
            }
        }

        var peak = counts.Max();
        if (peak <= 0)
        {
            return result;
        }

        var rows = new List<(int Low, int High)>();
        int? top = null;
        for (var y = y1 - 1; y >= y0 - 1; y--)
        {
            var busy = y >= y0 && counts[y - y0] * 100 > peak;
            if (busy && top is null)
            {
                top = y;
            }

            if (!busy && top is { } start)
            {
                rows.Add((y + 1, start));
                top = null;
            }
        }

        foreach (var (low, high) in rows)
        {
            if (high - low + 1 < lineHeight * 0.25)
            {
                continue;
            }

            var densest = 0;
            for (var y = low; y <= high; y++)
            {
                densest = Math.Max(densest, counts[y - y0]);
            }

            for (var y = low; y <= high; y++)
            {
                if (counts[y - y0] * 2 >= densest)
                {
                    result.Add(y);
                    break;
                }
            }
        }

        return result;
    }

    /// <summary>
    /// 段里哪些词在行内代码块里、代码块长什么样（取第一个量到的；mac Snapshot.code）：词框中间那一半出现最多的颜色和页面底不一样，
    /// 而且从词中间往两边走能在段框附近走到页面底的，就是代码块。落在已经量过的代码块里的词归进那一块，整串一起认。
    /// </summary>
    public OverlayCode? Code(IReadOnlyList<OverlayWord> words, OverlayRect segment, IReadOnlyList<double> baselines, double lineHeight, OverlayRgb background)
    {
        var chips = new List<(int Left, int Right, int Bottom, int Top, List<string> Words)>();
        OverlayCode? style = null;
        var reach = Round(lineHeight);
        var leftLimit = Round(segment.MinX) - reach;
        var rightLimit = Round(segment.MaxX) + reach;
        bool IsFill(int x, int y) => Contains(x, y) && Color(x, y).Distance(background) > ScreenshotOverlay.FillLimit;
        foreach (var word in words)
        {
            var bx0 = Round(word.Box.MinX);
            var bx1 = Round(word.Box.MaxX);
            var by0 = Round(word.Box.MinY);
            var by1 = Round(word.Box.MaxY);
            var middle = (by0 + by1) / 2;
            var center = (bx0 + bx1) / 2;
            var existing = chips.FindIndex(chip => center >= chip.Left && center < chip.Right && middle >= chip.Bottom && middle <= chip.Top);
            if (existing >= 0)
            {
                chips[existing].Words.Add(word.Text);
                continue;
            }

            var quarter = (bx1 - bx0) / 4;
            if (bx1 - bx0 < 4 || by1 - by0 < 2 || Mode(bx0 + quarter, bx1 - quarter, by0, by1) is not { } fill ||
                fill.Distance(background) <= ScreenshotOverlay.FillLimit || fill.Distance(background) >= 0.5)
            {
                continue;
            }

            var left = center;
            while (left > leftLimit && IsFill(left - 1, middle))
            {
                left--;
            }

            var right = center;
            while (right < rightLimit && IsFill(right, middle))
            {
                right++;
            }

            // 走到了段框外一个行高还没碰到页面底：是一整片面板，不是代码块
            if (left <= leftLimit || right >= rightLimit || right - left < (bx1 - bx0) / 2)
            {
                continue;
            }

            bool HasInk(int x)
            {
                for (var y = Math.Max(0, by0); y < Math.Min(Height, by1); y++)
                {
                    if (Color(x, y).Distance(fill) > ScreenshotOverlay.InkLimit)
                    {
                        return true;
                    }
                }

                return false;
            }

            var firstInk = left;
            while (firstInk < right && !HasInk(firstInk))
            {
                firstInk++;
            }

            var lastInk = right - 1;
            while (lastInk > firstInk && !HasInk(lastInk))
            {
                lastInk--;
            }

            var probe = firstInk - left >= 2 ? (left + firstInk) / 2 : (lastInk + 1 + right) / 2;
            int Edge(int step)
            {
                var y = middle;
                while (Math.Abs(y + step - middle) <= reach * 2 && IsFill(probe, y + step) && Color(probe, y + step).Distance(fill) <= 0.02)
                {
                    y += step;
                }

                var rim = 0;
                while (rim < 4 && IsFill(probe, y + step) && Color(probe, y + step).Distance(fill) > 0.02)
                {
                    y += step;
                    rim++;
                }

                return y;
            }

            var top = Edge(1);
            var bottom = Edge(-1);
            chips.Add((left, right, bottom, top, new List<string> { word.Text }));
            if (style is not null)
            {
                continue;
            }

            var baseline = baselines.Cast<double?>().FirstOrDefault(value => value > bottom && value <= top + 1)
                           ?? word.Box.MaxY - word.Box.Height * ScreenshotOverlay.Drop;
            var rimColor = Color(probe, top);
            OverlayRgb? border = null;
            double borderWidth = 0;
            if (rimColor.Distance(fill) > 0.02)
            {
                border = rimColor;
                var y = top;
                while (y > bottom && Color(probe, y).Distance(rimColor) <= 0.03 && borderWidth < 4)
                {
                    borderWidth++;
                    y--;
                }
            }

            var samples = new List<(double, OverlayRgb)>();
            for (var y = Math.Max(0, by0); y < Math.Min(Height, by1); y++)
            {
                for (var x = firstInk; x <= Math.Max(firstInk, lastInk); x++)
                {
                    var color = Color(x, y);
                    var distance = color.Distance(fill);
                    if (distance > ScreenshotOverlay.InkLimit)
                    {
                        samples.Add((distance, color));
                    }
                }
            }

            style = new OverlayCode
            {
                Fill = fill,
                Border = border,
                BorderWidth = borderWidth,
                Text = ScreenshotOverlay.Dominant(samples),
                Padding = (Math.Max(0, firstInk - left) + Math.Max(0, right - 1 - lastInk)) / 2.0,
                Above = top + 1 - baseline,
                Below = baseline - bottom,
            };
        }

        if (chips.Count == 0 || style is null)
        {
            return null;
        }

        return style with { Phrases = chips.Select(chip => (IReadOnlyList<string>)chip.Words).ToList() };
    }

    /// <summary>框外一圈的采样，出现最多的那种颜色：原文的底色（不用亮度中位数：列表第一行常常整行都是行内代码块）。</summary>
    public OverlayRgb? Ring(OverlayRect box)
    {
        var outset = Math.Max(3, box.Height * 0.12);
        var x0 = Down(box.MinX - outset);
        var x1 = Up(box.MaxX + outset);
        var y0 = Down(box.MinY - outset);
        var y1 = Up(box.MaxY + outset);
        if (x1 <= x0 || y1 <= y0)
        {
            return null;
        }

        var stepX = Math.Max(1, (x1 - x0) / 40);
        var stepY = Math.Max(1, (y1 - y0) / 40);
        var counts = new Dictionary<int, (int Count, int Red, int Green, int Blue)>();
        void Collect(int x, int y)
        {
            if (box.Contains(x, y) || !Contains(x, y))
            {
                return;
            }

            var (r, g, b) = Raw(x, y);
            var key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
            counts.TryGetValue(key, out var old);
            counts[key] = (old.Count + 1, old.Red + r, old.Green + g, old.Blue + b);
        }

        for (var x = x0; x < x1; x += stepX)
        {
            Collect(x, y0);
            Collect(x, y1 - 1);
        }

        for (var y = y0; y < y1; y += stepY)
        {
            Collect(x0, y);
            Collect(x1 - 1, y);
        }

        if (counts.Count == 0)
        {
            return null;
        }

        var best = counts.Values.MaxBy(value => value.Count);
        var n = best.Count * 255.0;
        return new OverlayRgb(best.Red / n, best.Green / n, best.Blue / n);
    }
}
