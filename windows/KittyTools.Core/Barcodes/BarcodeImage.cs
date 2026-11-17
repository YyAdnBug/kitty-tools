// 识字认码（REVIEW R105）用的图：BGRA 转灰度，再按 8×8 的块自适应二值化。
// 每块对比度够（标准差至少是整张图明暗跨度的 12%）就取块里暗、亮两半的平均值的中点当阈值；对比度不够的块（大片空白、码里的
// 大模块中间）用离它最近的有对比度的块的阈值，再按 3×3 块平滑。这样深色底、渐变底、噪点都能分开，大模块中间也不会被当成亮的。
// 除了二值（找定位图案、数游程用），还留着灰度和每块的阈值：取样时在灰度上双线性插值再和阈值比，比按像素的二值准。
namespace KittyTools.Core.Barcodes;

internal sealed class BarcodeImage
{
    public const int BlockSize = 8;

    private readonly byte[] _bits;
    private readonly int[] _thresholds;
    private readonly int _blocksWide;

    private BarcodeImage(int width, int height, byte[] bits, byte[] gray, int[] thresholds, int blocksWide)
    {
        Width = width;
        Height = height;
        _bits = bits;
        Gray = gray;
        _thresholds = thresholds;
        _blocksWide = blocksWide;
    }

    public int Width { get; }

    public int Height { get; }

    /// <summary>灰度，一行接一行。</summary>
    public byte[] Gray { get; }

    /// <summary>(x, y) 这个像素是不是暗的；inverted 时反过来（浅色的码印在深色底上）。</summary>
    public bool Dark(int x, int y, bool inverted) => (_bits[y * Width + x] != 0) != inverted;

    /// <summary>某一点的灰度（像素中心在 +0.5 处），双线性插值。</summary>
    public double Level(double x, double y)
    {
        var fx = Math.Clamp(x - 0.5, 0, Width - 1);
        var fy = Math.Clamp(y - 0.5, 0, Height - 1);
        var x0 = (int)fx;
        var y0 = (int)fy;
        var x1 = Math.Min(x0 + 1, Width - 1);
        var y1 = Math.Min(y0 + 1, Height - 1);
        var ax = fx - x0;
        var ay = fy - y0;
        var top = Gray[y0 * Width + x0] * (1 - ax) + Gray[y0 * Width + x1] * ax;
        var bottom = Gray[y1 * Width + x0] * (1 - ax) + Gray[y1 * Width + x1] * ax;
        return top * (1 - ay) + bottom * ay;
    }

    /// <summary>某一点所在块的阈值。</summary>
    public double Threshold(double x, double y)
    {
        var bx = Math.Clamp((int)x, 0, Width - 1) / BlockSize;
        var by = Math.Clamp((int)y, 0, Height - 1) / BlockSize;
        return _thresholds[by * _blocksWide + bx];
    }

    /// <summary>
    /// BGRA（不预乘的 alpha）→ 灰度，每 step × step 个像素取平均成一个（step 是 1 就是原样）；透明的地方当白的（贴在白底上看）。
    /// 到点了返回 null（每 32 行看一次时间）。
    /// </summary>
    public static (byte[] Gray, int Width, int Height)? Luma(ReadOnlySpan<byte> bgra, int width, int height, int step, Deadline deadline)
    {
        var w = width / step;
        var h = height / step;
        var gray = new byte[w * h];
        var area = step * step;
        for (var y = 0; y < h; y++)
        {
            if (y % 32 == 0 && deadline.Expired)
            {
                return null;
            }

            for (var x = 0; x < w; x++)
            {
                var sum = 0;
                for (var dy = 0; dy < step; dy++)
                {
                    var p = ((y * step + dy) * width + x * step) * 4;
                    for (var dx = 0; dx < step; dx++, p += 4)
                    {
                        var luma = (bgra[p] * 29 + bgra[p + 1] * 150 + bgra[p + 2] * 77) >> 8;
                        var a = bgra[p + 3];
                        sum += (luma * a + 255 * (255 - a)) / 255;
                    }
                }

                gray[y * w + x] = (byte)(sum / area);
            }
        }

        return (gray, w, h);
    }

    /// <summary>长宽各缩一半（2×2 取平均）。</summary>
    public static (byte[] Gray, int Width, int Height) Halve(byte[] gray, int width, int height)
    {
        var w = width / 2;
        var h = height / 2;
        var output = new byte[w * h];
        for (var y = 0; y < h; y++)
        {
            var row0 = 2 * y * width;
            var row1 = row0 + width;
            for (var x = 0; x < w; x++)
            {
                var sum = gray[row0 + 2 * x] + gray[row0 + 2 * x + 1] + gray[row1 + 2 * x] + gray[row1 + 2 * x + 1];
                output[y * w + x] = (byte)((sum + 2) >> 2);
            }
        }

        return (output, w, h);
    }

    /// <summary>二值化；整张图几乎没有明暗差（纯色、空白）时、到点了时返回 null（每几十行看一次时间）。</summary>
    public static BarcodeImage? Binarize(byte[] gray, int width, int height, Deadline deadline)
    {
        // 去掉最暗、最亮各 2% 之后的明暗跨度
        var histogram = new int[256];
        for (var y = 0; y < height; y++)
        {
            if (y % 64 == 0 && deadline.Expired)
            {
                return null;
            }

            for (var i = y * width; i < (y + 1) * width; i++)
            {
                histogram[gray[i]]++;
            }
        }

        var total = width * height;
        var low = 0;
        var seen = 0;
        while (low < 255 && seen + histogram[low] <= total / 50)
        {
            seen += histogram[low];
            low++;
        }

        var high = 255;
        seen = 0;
        while (high > 0 && seen + histogram[high] <= total / 50)
        {
            seen += histogram[high];
            high--;
        }

        var range = high - low;
        if (range < 24)
        {
            return null;
        }

        var minDeviation = Math.Max(6.0, range * 0.12);
        var bw = (width + BlockSize - 1) / BlockSize;
        var bh = (height + BlockSize - 1) / BlockSize;
        var threshold = new int[bw * bh];
        var distance = new int[bw * bh];
        Array.Fill(distance, int.MaxValue / 2);
        var anyKnown = false;
        for (var by = 0; by < bh; by++)
        {
            if (by % 8 == 0 && deadline.Expired)
            {
                return null;
            }

            var y0 = by * BlockSize;
            var y1 = Math.Min(height, y0 + BlockSize);
            for (var bx = 0; bx < bw; bx++)
            {
                var x0 = bx * BlockSize;
                var x1 = Math.Min(width, x0 + BlockSize);
                var sum = 0;
                var squares = 0;
                for (var y = y0; y < y1; y++)
                {
                    for (var x = x0; x < x1; x++)
                    {
                        int v = gray[y * width + x];
                        sum += v;
                        squares += v * v;
                    }
                }

                var count = (y1 - y0) * (x1 - x0);
                var mean = (double)sum / count;
                var variance = (double)squares / count - mean * mean;
                if (variance < minDeviation * minDeviation)
                {
                    continue;
                }

                // 一步 isodata：比平均暗的那一半和亮的那一半，各自平均值的中点
                var darkSum = 0;
                var darkCount = 0;
                var cut = (int)mean;
                for (var y = y0; y < y1; y++)
                {
                    for (var x = x0; x < x1; x++)
                    {
                        int v = gray[y * width + x];
                        if (v <= cut)
                        {
                            darkSum += v;
                            darkCount++;
                        }
                    }
                }

                var lightCount = count - darkCount;
                if (darkCount == 0 || lightCount == 0)
                {
                    continue;
                }

                var b = by * bw + bx;
                threshold[b] = (darkSum / darkCount + (sum - darkSum) / lightCount + 1) / 2;
                distance[b] = 0;
                anyKnown = true;
            }
        }

        if (!anyKnown)
        {
            Array.Fill(threshold, (low + high) / 2);
        }
        else
        {
            // 没对比度的块取最近一个有对比度的块的阈值（正反两遍倒角距离）
            for (var by = 0; by < bh; by++)
            {
                for (var bx = 0; bx < bw; bx++)
                {
                    var b = by * bw + bx;
                    if (bx > 0)
                    {
                        Take(threshold, distance, b, b - 1);
                    }

                    if (by > 0)
                    {
                        Take(threshold, distance, b, b - bw);
                        if (bx > 0)
                        {
                            Take(threshold, distance, b, b - bw - 1);
                        }

                        if (bx < bw - 1)
                        {
                            Take(threshold, distance, b, b - bw + 1);
                        }
                    }
                }
            }

            for (var by = bh - 1; by >= 0; by--)
            {
                for (var bx = bw - 1; bx >= 0; bx--)
                {
                    var b = by * bw + bx;
                    if (bx < bw - 1)
                    {
                        Take(threshold, distance, b, b + 1);
                    }

                    if (by < bh - 1)
                    {
                        Take(threshold, distance, b, b + bw);
                        if (bx < bw - 1)
                        {
                            Take(threshold, distance, b, b + bw + 1);
                        }

                        if (bx > 0)
                        {
                            Take(threshold, distance, b, b + bw - 1);
                        }
                    }
                }
            }
        }

        // 按 3×3 块平滑
        var smooth = new int[bw * bh];
        for (var by = 0; by < bh; by++)
        {
            for (var bx = 0; bx < bw; bx++)
            {
                var sum = 0;
                var count = 0;
                for (var dy = -1; dy <= 1; dy++)
                {
                    var y = by + dy;
                    if (y < 0 || y >= bh)
                    {
                        continue;
                    }

                    for (var dx = -1; dx <= 1; dx++)
                    {
                        var x = bx + dx;
                        if (x < 0 || x >= bw)
                        {
                            continue;
                        }

                        sum += threshold[y * bw + x];
                        count++;
                    }
                }

                smooth[by * bw + bx] = sum / count;
            }
        }

        var bits = new byte[total];
        for (var y = 0; y < height; y++)
        {
            if (y % 64 == 0 && deadline.Expired)
            {
                return null;
            }

            var row = y / BlockSize * bw;
            for (var x = 0; x < width; x++)
            {
                if (gray[y * width + x] < smooth[row + x / BlockSize])
                {
                    bits[y * width + x] = 1;
                }
            }
        }

        return new BarcodeImage(width, height, bits, gray, smooth, bw);
    }

    private static void Take(int[] threshold, int[] distance, int b, int from)
    {
        if (distance[from] + 1 < distance[b])
        {
            distance[b] = distance[from] + 1;
            threshold[b] = threshold[from];
        }
    }
}
