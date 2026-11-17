// 识字认码（REVIEW R105）：一维码 EAN-13、EAN-8、UPC-A（按 EAN-13 读，前面补 0，同 mac 的 Vision）、UPC-E（8 位）、
// Code 128、Code 39、ITF（交叉 25 码）。照各自的规范（GS1 通用规范、ISO/IEC 15417、16388、16390）自己写的。
// 扫描线：每隔几行一条横线、每隔几列一条竖线，再加偏 ±6°、±12° 的斜线（码转过一点、条又短时横线穿不过整个码）。
// 每条线上按灰度和阈值（线上前后约 20 个点里最暗最亮的中点；那一带没什么明暗时用块阈值）找边，边的位置按相邻两点线性插值到
// 零点几个像素：2.1 像素一个模块、边缘抗锯齿的截图也量得准。正反两个方向各解一遍（码倒过来）。
// 防误认：码前后要有至少 5 个模块的空白（或空白一直到线头）；同一个结果至少两条线都读出来才算（Code 39、ITF 没有校验位，三条）；
// Code 39、ITF 要求只有两种宽度（ITF 卡得更严）；一条斜线从条的一头出去时能读出个短的假码，所以落在同一块地方的两个结果只留长的那个。
namespace KittyTools.Core.Barcodes;

internal static class LinearBarcodes
{
    // EAN / UPC 左侧奇校验（L）的四段宽度（空、条、空、条）；偶校验（G）是它倒过来；右侧（R）宽度同 L，从条开始
    private static readonly int[][] LCodes =
    {
        new[] { 3, 2, 1, 1 }, new[] { 2, 2, 2, 1 }, new[] { 2, 1, 2, 2 }, new[] { 1, 4, 1, 1 }, new[] { 1, 1, 3, 2 },
        new[] { 1, 2, 3, 1 }, new[] { 1, 1, 1, 4 }, new[] { 1, 3, 1, 2 }, new[] { 1, 2, 1, 3 }, new[] { 3, 1, 1, 2 },
    };

    // Enumerable.Reverse 写全：C# 14 起数组的 .Reverse() 会绑到 Span 的就地反转上
    private static readonly int[][] GCodes = LCodes.Select(code => Enumerable.Reverse(code).ToArray()).ToArray();

    /// <summary>EAN-13 左边六位的奇偶排法 → 第一位数字。</summary>
    private static readonly string[] Ean13Parity =
        { "LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL" };

    /// <summary>UPC-E（号码系统 0）六位的奇偶排法 → 校验位；号码系统 1 是它反过来。</summary>
    private static readonly string[] UpceParity =
        { "GGGLLL", "GGLGLL", "GGLLGL", "GGLLLG", "GLGGLL", "GLLGGL", "GLLLGG", "GLGLGL", "GLGLLG", "GLLGLG" };

    // Code 128 的 0–105（103–105 是起始符 A B C），每个六段、共 11 个模块
    private static readonly int[][] Code128 = new[]
    {
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
        "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
        "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
        "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
        "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
        "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
        "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
        "114131", "311141", "411131", "211412", "211214", "211232",
    }.Select(pattern => pattern.Select(digit => digit - '0').ToArray()).ToArray();

    /// <summary>Code 128 的终止符：七段、13 个模块。</summary>
    private static readonly int[][] Code128Stop = { new[] { 2, 3, 3, 1, 1, 1, 2 } };

    // Code 39：九段（条空交替，第一段是条）里哪三段宽，最高位是第一段
    private const string Code39Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%*";

    private static readonly int[] Code39Patterns =
    {
        0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064,
        0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C,
        0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016,
        0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x0A8,
        0x0A2, 0x08A, 0x02A, 0x094,
    };

    /// <summary>ITF 每个数字五段里哪两段宽，最高位是第一段。</summary>
    private static readonly int[] ItfPatterns = { 0b00110, 0b10001, 0b01001, 0b11000, 0b00101, 0b10100, 0b01100, 0b00011, 0b10010, 0b01010 };

    /// <summary>EAN / UPC 一位数字四段加起来和标准差多少个模块算认得出。</summary>
    private const double DigitError = 1.3;

    /// <summary>一个结果和读到它的地方（读到它的每一段线的外框）。</summary>
    private sealed class Read
    {
        public Read(string text, int need, double minX, double minY, double maxX, double maxY)
        {
            Text = text;
            Need = need;
            MinX = minX;
            MinY = minY;
            MaxX = maxX;
            MaxY = maxY;
        }

        public string Text { get; }

        /// <summary>要几条线读到才算：有校验位的 2 条，Code 39、ITF 没有校验位，3 条（REVIEW R105 审查第 3 条）。</summary>
        public int Need { get; set; }

        public int Hits { get; set; } = 1;

        public double MinX { get; set; }

        public double MinY { get; set; }

        public double MaxX { get; set; }

        public double MaxY { get; set; }
    }

    public static List<string> Detect(BarcodeImage image, Deadline deadline)
    {
        var reads = new List<Read>();
        var longest = (int)Math.Sqrt((double)image.Width * image.Width + (double)image.Height * image.Height) + 2;
        var runs = new double[longest + 2];
        var reversed = new double[longest + 2];
        var levels = new double[longest];
        var thresholds = new double[longest];
        var xs = new double[longest];
        var ys = new double[longest];
        var chunkLow = new double[longest / 8 + 2];
        var chunkHigh = new double[longest / 8 + 2];

        // 线上的位置（第 i 个点占 [i, i + 1)）→ 图上的点
        (double X, double Y) Point(double position, int length)
        {
            var u = Math.Clamp(position - 0.5, 0, length - 1);
            var i = (int)u;
            var j = Math.Min(i + 1, length - 1);
            var f = u - i;
            return (xs[i] + (xs[j] - xs[i]) * f, ys[i] + (ys[j] - ys[i]) * f);
        }

        void Record(List<(string Text, int First, int Last, bool Checked)> found, double[] line, bool flipped, int length)
        {
            foreach (var (text, first, last, checkDigit) in found)
            {
                var start = 0.0;
                for (var i = 0; i < first; i++)
                {
                    start += line[i];
                }

                var end = start;
                for (var i = first; i <= last; i++)
                {
                    end += line[i];
                }

                if (flipped)
                {
                    (start, end) = (length - end, length - start);
                }

                var a = Point(start, length);
                var b = Point(end, length);
                var need = checkDigit ? 2 : 3;
                var read = reads.Find(r => r.Text == text);
                if (read is null)
                {
                    reads.Add(new Read(text, need, Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y)));
                    continue;
                }

                read.Hits++;
                read.Need = Math.Min(read.Need, need);
                read.MinX = Math.Min(read.MinX, Math.Min(a.X, b.X));
                read.MinY = Math.Min(read.MinY, Math.Min(a.Y, b.Y));
                read.MaxX = Math.Max(read.MaxX, Math.Max(a.X, b.X));
                read.MaxY = Math.Max(read.MaxY, Math.Max(a.Y, b.Y));
            }
        }

        // levels / thresholds 里放好一条线之后：找边、数游程，正反各解一遍
        void Scan(int length)
        {
            // 线上的阈值：前后约 20 个点里最暗和最亮的中点（那一带明暗差够大时，即条码上），不然用块阈值（空白、平的地方）
            var chunks = (length + 7) / 8;
            for (var c = 0; c < chunks; c++)
            {
                var low = 255.0;
                var high = 0.0;
                for (var i = c * 8; i < Math.Min(length, c * 8 + 8); i++)
                {
                    low = Math.Min(low, levels[i]);
                    high = Math.Max(high, levels[i]);
                }

                chunkLow[c] = low;
                chunkHigh[c] = high;
            }

            for (var c = 0; c < chunks; c++)
            {
                var low = 255.0;
                var high = 0.0;
                for (var n = Math.Max(0, c - 2); n <= Math.Min(chunks - 1, c + 2); n++)
                {
                    low = Math.Min(low, chunkLow[n]);
                    high = Math.Max(high, chunkHigh[n]);
                }

                if (high - low >= 48)
                {
                    for (var i = c * 8; i < Math.Min(length, c * 8 + 8); i++)
                    {
                        thresholds[i] = (low + high) / 2;
                    }
                }
            }

            // 边：灰度跨过阈值的地方，在相邻两点之间线性插值
            var count = 0;
            var last = 0.0;
            var dark = false;
            for (var i = 0; i < length; i++)
            {
                var d = levels[i] < thresholds[i];
                if (d == dark)
                {
                    continue;
                }

                var edge = 0.0;
                if (i > 0)
                {
                    var a = levels[i - 1];
                    var b = levels[i];
                    var f = a == b ? 0.5 : Math.Clamp((thresholds[i] - a) / (b - a), 0, 1);
                    edge = i - 0.5 + f;
                }

                runs[count++] = edge - last;
                last = edge;
                dark = d;
            }

            runs[count++] = length - last;
            Record(DecodeLine(runs, count), runs, false, length);

            // 倒过来读（码是倒着的）：保持第一段是亮的
            var r = 0;
            if (count % 2 == 0)
            {
                reversed[r++] = 0;
            }

            for (var i = count - 1; i >= 0; i--)
            {
                reversed[r++] = runs[i];
            }

            Record(DecodeLine(reversed, r), reversed, true, length);
        }

        // 横线、竖线照原样读像素
        var rowStep = Math.Min(16, Math.Max(2, image.Height / 120));
        var lines = 0;
        for (var y = rowStep / 2; y < image.Height; y += rowStep)
        {
            if (++lines % 16 == 0 && deadline.Expired)
            {
                break;
            }

            for (var x = 0; x < image.Width; x++)
            {
                levels[x] = image.Gray[y * image.Width + x];
                thresholds[x] = image.Threshold(x, y);
                xs[x] = x + 0.5;
                ys[x] = y + 0.5;
            }

            Scan(image.Width);
        }

        var columnStep = Math.Min(16, Math.Max(2, image.Width / 120));
        for (var x = columnStep / 2; x < image.Width && !deadline.Expired; x += columnStep)
        {
            for (var y = 0; y < image.Height; y++)
            {
                levels[y] = image.Gray[y * image.Width + x];
                thresholds[y] = image.Threshold(x, y);
                xs[y] = x + 0.5;
                ys[y] = y + 0.5;
            }

            Scan(image.Height);
        }

        // 再加稍微斜一点的线：码转过 10° 左右、条又不高时，横线穿不过整个码
        // ponytail: 只到两条轴两边各 12°；转了 30°–60° 的一维码读不出，要读再加角度（每多一个方向约多 1/8 的时间）
        double width = image.Width;
        double height = image.Height;
        var radius = Math.Sqrt(width * width + height * height) / 2;
        foreach (var degrees in new[] { 6.0, -6.0, 96.0, 84.0, 12.0, -12.0, 102.0, 78.0 })
        {
            if (deadline.Expired)
            {
                break;
            }

            var angle = degrees * Math.PI / 180;
            var dx = Math.Cos(angle);
            var dy = Math.Sin(angle);
            var across = Math.Abs(dx) > Math.Abs(dy) ? image.Height : image.Width;
            // ponytail: 斜线 4–32 像素一条；条的高度比这还短的码可能从两条线之间漏过去
            double spacing = Math.Min(32, Math.Max(4, across / 60));
            for (var offset = -radius + spacing / 2; offset < radius && !deadline.Expired; offset += spacing)
            {
                // 过中心偏 offset 的那条线：c + n·offset + d·t，只取图里面的那一段（按两组平行边界各求一次 t 的范围）
                var px = width / 2 - dy * offset;
                var py = height / 2 + dx * offset;
                var low = -radius;
                var high = radius;
                if (Math.Abs(dx) > 1e-9)
                {
                    var t0 = (0 - px) / dx;
                    var t1 = (width - 0.001 - px) / dx;
                    low = Math.Max(low, Math.Min(t0, t1));
                    high = Math.Min(high, Math.Max(t0, t1));
                }

                if (Math.Abs(dy) > 1e-9)
                {
                    var t0 = (0 - py) / dy;
                    var t1 = (height - 0.001 - py) / dy;
                    low = Math.Max(low, Math.Min(t0, t1));
                    high = Math.Min(high, Math.Max(t0, t1));
                }

                var length = 0;
                for (var t = Math.Ceiling(low); t <= high && length < levels.Length; t++)
                {
                    var x = px + dx * t;
                    var y = py + dy * t;
                    if (x < 0 || y < 0 || x >= width || y >= height)
                    {
                        continue;
                    }

                    levels[length] = image.Level(x, y);
                    thresholds[length] = image.Threshold(x, y);
                    xs[length] = x;
                    ys[length] = y;
                    length++;
                }

                if (length > 20)
                {
                    Scan(length);
                }
            }
        }

        // 一条线读出来的可能是巧合（满是文字的截图里）：有校验位的至少两条线读到，Code 39、ITF 至少三条（误认了会让这次识字整个跳过）。
        // 一条线从条的一头出去时能读出个短的假码，落在同一块地方的两个结果只留长的（一样长留读到次数多的）
        var confirmed = reads
            .Where(read => read.Hits >= read.Need)
            .OrderByDescending(read => read.Text.Length)
            .ThenByDescending(read => read.Hits)
            .ToList();
        var kept = new List<Read>();
        foreach (var read in confirmed)
        {
            if (!kept.Any(other => Overlaps(other, read)))
            {
                kept.Add(read);
            }
        }

        // 按第一次读到的先后排
        return reads.Where(kept.Contains).Select(read => read.Text).ToList();
    }

    private static bool Overlaps(Read a, Read b)
    {
        const double pad = 4;
        var width = Math.Min(a.MaxX, b.MaxX) - Math.Max(a.MinX, b.MinX) + 2 * pad;
        var height = Math.Min(a.MaxY, b.MaxY) - Math.Max(a.MinY, b.MinY) + 2 * pad;
        if (width <= 0 || height <= 0)
        {
            return false;
        }

        var areaA = (a.MaxX - a.MinX + 2 * pad) * (a.MaxY - a.MinY + 2 * pad);
        var areaB = (b.MaxX - b.MinX + 2 * pad) * (b.MaxY - b.MinY + 2 * pad);
        return width * height >= Math.Min(areaA, areaB) * 0.25;
    }

    /// <summary>一条线上解出的码、它第一条和最后一条条的游程下标、有没有校验位。runs[0] 是亮的，奇数下标是条。</summary>
    private static List<(string Text, int First, int Last, bool Checked)> DecodeLine(double[] runs, int count)
    {
        var found = new List<(string Text, int First, int Last, bool Checked)>();
        for (var k = 1; k < count;)
        {
            // 每种码都以不超过两个模块宽的条开头，前面至少五个模块的空白：不像的直接跳过
            if (!(runs[k - 1] >= runs[k] * 2.5 || (k == 1 && runs[0] > 0)))
            {
                k += 2;
                continue;
            }

            var checkDigit = true;
            var attempt = Ean13(runs, count, k) ?? Ean8(runs, count, k) ?? Upce(runs, count, k) ?? Code128Read(runs, count, k);
            if (attempt is null)
            {
                checkDigit = false;
                attempt = Code39(runs, count, k) ?? Itf(runs, count, k);
            }

            if (attempt is { } result)
            {
                found.Add((result.Text, k, result.End, checkDigit));
                k = result.End + 2;
            }
            else
            {
                k += 2;
            }
        }

        return found;
    }

    private static double Sum(double[] runs, int from, int length)
    {
        var total = 0.0;
        for (var i = from; i < from + length; i++)
        {
            total += runs[i];
        }

        return total;
    }

    /// <summary>第 k 段条前面的空白够宽（或空白一直到线头）。</summary>
    private static bool QuietBefore(double[] runs, int k, double need) => runs[k - 1] >= need || (k == 1 && runs[0] > 0);

    /// <summary>第 end 段条后面的空白够宽（或空白一直到线尾）。</summary>
    private static bool QuietAfter(double[] runs, int count, int end, double need) =>
        end + 1 < count && (runs[end + 1] >= need || end + 2 == count);

    /// <summary>这几段都是窄的（一个模块上下）。</summary>
    private static bool Narrow(double[] runs, int from, int length, double unit)
    {
        for (var i = from; i < from + length; i++)
        {
            var r = runs[i] / unit;
            if (!(r >= 0.4 && r <= 1.8))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>最像的那个图案和差了多少个模块。</summary>
    private static (int Index, double Error) Match(double[] runs, int at, int[][] patterns, int modules)
    {
        var length = patterns[0].Length;
        var unit = Sum(runs, at, length) / modules;
        if (!(unit > 0))
        {
            return (-1, double.MaxValue);
        }

        var best = -1;
        var bestError = double.MaxValue;
        for (var index = 0; index < patterns.Length; index++)
        {
            var error = 0.0;
            for (var j = 0; j < length; j++)
            {
                error += Math.Abs(runs[at + j] - patterns[index][j] * unit);
            }

            if (error < bestError)
            {
                bestError = error;
                best = index;
            }
        }

        return (best, bestError / unit);
    }

    /// <summary>这几段的总宽和 modules 个模块差不超过 30%。</summary>
    private static bool Consistent(double[] runs, int at, int length, int modules, double unit)
    {
        var width = Sum(runs, at, length);
        var expected = modules * unit;
        return width >= expected * 0.7 && width <= expected * 1.3;
    }

    private static (string Text, int End)? Ean13(double[] runs, int count, int k)
    {
        if (k + 59 > count)
        {
            return null;
        }

        var unit = Sum(runs, k, 59) / 95;
        if (!Narrow(runs, k, 3, unit) || !Narrow(runs, k + 27, 5, unit) || !Narrow(runs, k + 56, 3, unit) ||
            !QuietBefore(runs, k, unit * 5) || !QuietAfter(runs, count, k + 58, unit * 5))
        {
            return null;
        }

        var digits = new int[13];
        var parity = new char[6];
        for (var d = 0; d < 6; d++)
        {
            var at = k + 3 + 4 * d;
            if (!Consistent(runs, at, 4, 7, unit) || LeftDigit(runs, at) is not { } digit)
            {
                return null;
            }

            digits[d + 1] = digit.Value;
            parity[d] = digit.Parity;
        }

        var first = Array.IndexOf(Ean13Parity, new string(parity));
        if (first < 0)
        {
            return null;
        }

        digits[0] = first;
        for (var d = 0; d < 6; d++)
        {
            var at = k + 32 + 4 * d;
            if (!Consistent(runs, at, 4, 7, unit))
            {
                return null;
            }

            var (value, error) = Match(runs, at, LCodes, 7);
            if (!(error <= DigitError))
            {
                return null;
            }

            digits[d + 7] = value;
        }

        return ChecksumOk(digits) ? (DigitText(digits), k + 58) : null;
    }

    private static (string Text, int End)? Ean8(double[] runs, int count, int k)
    {
        if (k + 43 > count)
        {
            return null;
        }

        var unit = Sum(runs, k, 43) / 67;
        if (!Narrow(runs, k, 3, unit) || !Narrow(runs, k + 19, 5, unit) || !Narrow(runs, k + 40, 3, unit) ||
            !QuietBefore(runs, k, unit * 5) || !QuietAfter(runs, count, k + 42, unit * 5))
        {
            return null;
        }

        var digits = new int[8];
        for (var d = 0; d < 8; d++)
        {
            var at = d < 4 ? k + 3 + 4 * d : k + 24 + 4 * (d - 4);
            if (!Consistent(runs, at, 4, 7, unit))
            {
                return null;
            }

            var (value, error) = Match(runs, at, LCodes, 7);
            if (!(error <= DigitError))
            {
                return null;
            }

            digits[d] = value;
        }

        return ChecksumOk(digits) ? (DigitText(digits), k + 42) : null;
    }

    private static (string Text, int End)? Upce(double[] runs, int count, int k)
    {
        if (k + 33 > count)
        {
            return null;
        }

        var unit = Sum(runs, k, 33) / 51;
        if (!Narrow(runs, k, 3, unit) || !Narrow(runs, k + 27, 6, unit) ||
            !QuietBefore(runs, k, unit * 5) || !QuietAfter(runs, count, k + 32, unit * 5))
        {
            return null;
        }

        var digits = new int[6];
        var parity = new char[6];
        for (var d = 0; d < 6; d++)
        {
            var at = k + 3 + 4 * d;
            if (!Consistent(runs, at, 4, 7, unit) || LeftDigit(runs, at) is not { } digit)
            {
                return null;
            }

            digits[d] = digit.Value;
            parity[d] = digit.Parity;
        }

        var system = 0;
        var check = Array.IndexOf(UpceParity, new string(parity));
        if (check < 0)
        {
            var flipped = new string(parity.Select(p => p == 'L' ? 'G' : 'L').ToArray());
            check = Array.IndexOf(UpceParity, flipped);
            system = 1;
        }

        if (check < 0)
        {
            return null;
        }

        var full = new List<int> { system };
        full.AddRange(ExpandUpce(digits));
        full.Add(check);
        if (!ChecksumOk(full.ToArray()))
        {
            return null;
        }

        return ((char)('0' + system) + DigitText(digits) + (char)('0' + check), k + 32);
    }

    /// <summary>EAN / UPC 左侧一位：L 和 G 里更像的那个，和它是哪种。</summary>
    private static (int Value, char Parity)? LeftDigit(double[] runs, int at)
    {
        var (l, lError) = Match(runs, at, LCodes, 7);
        var (g, gError) = Match(runs, at, GCodes, 7);
        if (!(Math.Min(lError, gError) <= DigitError))
        {
            return null;
        }

        return lError <= gError ? (l, 'L') : (g, 'G');
    }

    /// <summary>UPC-E 六位代表的 UPC-A 中间十位。</summary>
    private static int[] ExpandUpce(int[] d) => d[5] switch
    {
        0 or 1 or 2 => new[] { d[0], d[1], d[5], 0, 0, 0, 0, d[2], d[3], d[4] },
        3 => new[] { d[0], d[1], d[2], 0, 0, 0, 0, 0, d[3], d[4] },
        4 => new[] { d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4] },
        _ => new[] { d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, d[5] },
    };

    private static string DigitText(int[] digits) => new(digits.Select(d => (char)('0' + d)).ToArray());

    /// <summary>GS1 校验：从右数（含校验位）奇数位乘 1、偶数位乘 3，加起来是 10 的倍数。</summary>
    private static bool ChecksumOk(int[] digits)
    {
        var total = 0;
        for (var i = 0; i < digits.Length; i++)
        {
            var fromRight = digits.Length - 1 - i;
            total += fromRight % 2 == 0 ? digits[i] : digits[i] * 3;
        }

        return total % 10 == 0;
    }

    private static (string Text, int End)? Code128Read(double[] runs, int count, int k)
    {
        if (k + 13 > count)
        {
            return null;
        }

        var (start, startError) = Match(runs, k, Code128, 11);
        if (start < 103 || !(startError <= 1.5))
        {
            return null;
        }

        var unit = Sum(runs, k, 6) / 11;
        if (!QuietBefore(runs, k, unit * 5))
        {
            return null;
        }

        var values = new List<int>();
        var end = -1;
        for (var j = k + 6; j + 6 <= count; j += 6)
        {
            if (j + 7 <= count && Consistent(runs, j, 7, 13, unit) && Match(runs, j, Code128Stop, 13).Error <= 1.5 &&
                QuietAfter(runs, count, j + 6, unit * 5))
            {
                end = j + 6;
                break;
            }

            if (!Consistent(runs, j, 6, 11, unit))
            {
                return null;
            }

            var (value, error) = Match(runs, j, Code128, 11);
            if (!(error <= 1.5) || value >= 103 || values.Count >= 120)
            {
                return null;
            }

            values.Add(value);
        }

        if (end < 0 || values.Count < 2)
        {
            return null;
        }

        // 校验符 = (起始符 + Σ 位置 × 值) mod 103
        var total = start;
        for (var i = 0; i < values.Count - 1; i++)
        {
            total += (i + 1) * values[i];
        }

        if (total % 103 != values[^1])
        {
            return null;
        }

        values.RemoveAt(values.Count - 1);
        var text = Code128Text(start, values);
        return text.Length > 0 ? (text, end) : null;
    }

    /// <summary>
    /// Code 128 的码值 → 文字：三套字符（A 大写和控制字符、B 可打印 ASCII、C 两位数字）、切换（CODE A/B/C）、
    /// 只管下一个字符的 SHIFT、FNC4（加 128 的扩展 ASCII，单个只管下一个、连着两个是锁定）；FNC1 不在开头时是分隔符 GS。
    /// </summary>
    private static string Code128Text(int start, List<int> values)
    {
        var set = start - 103;  // 0 A、1 B、2 C
        var text = new System.Text.StringBuilder();
        var shift = false;
        var fnc4Pending = false;
        var fnc4Latch = false;

        void Append(int code)
        {
            var extended = fnc4Latch != fnc4Pending;
            text.Append((char)(extended ? code + 128 : code));
            fnc4Pending = false;
        }

        void Fnc4()
        {
            if (fnc4Pending)
            {
                fnc4Latch = !fnc4Latch;
                fnc4Pending = false;
            }
            else
            {
                fnc4Pending = true;
            }
        }

        for (var i = 0; i < values.Count; i++)
        {
            var v = values[i];
            var current = shift ? (set == 0 ? 1 : 0) : set;
            shift = false;
            if (current == 2)
            {
                if (v < 100)
                {
                    text.Append(v.ToString("D2", System.Globalization.CultureInfo.InvariantCulture));
                }
                else if (v == 100)
                {
                    set = 1;
                }
                else if (v == 101)
                {
                    set = 0;
                }
                else if (i > 0)
                {
                    text.Append('\u001D');
                }

                continue;
            }

            if (current == 0 && v < 64)
            {
                Append(v + 32);
                continue;
            }

            if (current == 0 && v < 96)
            {
                Append(v - 64);
                continue;
            }

            if (current == 1 && v < 96)
            {
                Append(v + 32);
                continue;
            }

            switch (v)
            {
                case 96 or 97:  // FNC3、FNC2：不出字
                    break;
                case 98:
                    shift = true;
                    break;
                case 99:
                    set = 2;
                    break;
                case 100:
                    if (current == 0)
                    {
                        set = 1;
                    }
                    else
                    {
                        Fnc4();
                    }

                    break;
                case 101:
                    if (current == 1)
                    {
                        set = 0;
                    }
                    else
                    {
                        Fnc4();
                    }

                    break;
                default:  // FNC1
                    if (i > 0)
                    {
                        text.Append('\u001D');
                    }

                    break;
            }
        }

        return text.ToString();
    }

    /// <summary>Code 39 的一个字符（九段里最宽的三段是宽的）、它的总宽、窄段的平均宽。</summary>
    private static (char Char, double Width, double Narrow)? Code39Char(double[] runs, int at)
    {
        var sorted = new double[9];
        Array.Copy(runs, at, sorted, 0, 9);
        Array.Sort(sorted);
        var wideMin = sorted[6];
        var narrowMax = sorted[5];
        if (!(wideMin >= narrowMax * 1.3))
        {
            return null;
        }

        var threshold = (wideMin + narrowMax) / 2;
        var pattern = 0;
        var narrowSum = 0.0;
        for (var i = 0; i < 9; i++)
        {
            pattern <<= 1;
            if (runs[at + i] > threshold)
            {
                pattern |= 1;
            }
            else
            {
                narrowSum += runs[at + i];
            }
        }

        var index = Array.IndexOf(Code39Patterns, pattern);
        return index < 0 ? null : (Code39Chars[index], Sum(runs, at, 9), narrowSum / 6);
    }

    private static (string Text, int End)? Code39(double[] runs, int count, int k)
    {
        if (k + 29 > count || Code39Char(runs, k) is not { Char: '*' } start)
        {
            return null;
        }

        if (!QuietBefore(runs, k, start.Narrow * 4))
        {
            return null;
        }

        var text = new System.Text.StringBuilder();
        for (var j = k + 9; j + 10 <= count; j += 9)
        {
            // 字符之间的空
            if (runs[j] > start.Narrow * 3)
            {
                return null;
            }

            j++;
            if (Code39Char(runs, j) is not { } next || next.Width < start.Width * 0.7 || next.Width > start.Width * 1.3)
            {
                return null;
            }

            if (next.Char == '*')
            {
                if (text.Length == 0 || !QuietAfter(runs, count, j + 8, start.Narrow * 4) || !TwoWidths(runs, k, j + 9 - k, 0.45))
                {
                    return null;
                }

                return (text.ToString(), j + 8);
            }

            text.Append(next.Char);
            if (text.Length > 80)
            {
                return null;
            }
        }

        return null;
    }

    /// <summary>
    /// Code 39、ITF 只有两种宽度：每段离它那一类的平均不超过 spread，宽的至少是窄的 1.8 倍（Code 128 有四种宽度，
    /// 硬分成两类就过不去）。ITF 没有别的校验，用更紧的 spread。
    /// </summary>
    private static bool TwoWidths(double[] runs, int from, int length, double spread)
    {
        var low = double.MaxValue;
        var high = 0.0;
        for (var i = from; i < from + length; i++)
        {
            low = Math.Min(low, runs[i]);
            high = Math.Max(high, runs[i]);
        }

        var threshold = (low + high) / 2;
        var narrowMean = 0.0;
        var wideMean = 0.0;
        for (var round = 0; round < 3; round++)
        {
            var narrowSum = 0.0;
            var narrowCount = 0;
            var wideSum = 0.0;
            var wideCount = 0;
            for (var i = from; i < from + length; i++)
            {
                if (runs[i] > threshold)
                {
                    wideSum += runs[i];
                    wideCount++;
                }
                else
                {
                    narrowSum += runs[i];
                    narrowCount++;
                }
            }

            if (narrowCount == 0 || wideCount == 0)
            {
                return false;
            }

            narrowMean = narrowSum / narrowCount;
            wideMean = wideSum / wideCount;
            threshold = (narrowMean + wideMean) / 2;
        }

        if (wideMean < narrowMean * 1.8)
        {
            return false;
        }

        for (var i = from; i < from + length; i++)
        {
            var mean = runs[i] > threshold ? wideMean : narrowMean;
            if (Math.Abs(runs[i] - mean) > mean * spread)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>ITF 的一个数字（五段里最宽的两段是宽的）。</summary>
    private static int ItfDigit(double a, double b, double c, double d, double e)
    {
        Span<double> elements = stackalloc double[] { a, b, c, d, e };
        Span<double> sorted = stackalloc double[5];
        elements.CopyTo(sorted);
        sorted.Sort();
        var wideMin = sorted[3];
        var narrowMax = sorted[2];
        if (!(wideMin >= narrowMax * 1.4))
        {
            return -1;
        }

        var threshold = (wideMin + narrowMax) / 2;
        var pattern = 0;
        foreach (var v in elements)
        {
            pattern = (pattern << 1) | (v > threshold ? 1 : 0);
        }

        return Array.IndexOf(ItfPatterns, pattern);
    }

    private static (string Text, int End)? Itf(double[] runs, int count, int k)
    {
        if (k + 4 + 10 + 3 > count)
        {
            return null;
        }

        // 起始符：四个窄段（条空条空）
        var n = Sum(runs, k, 4) / 4;
        if (!Narrow(runs, k, 4, n) || !QuietBefore(runs, k, n * 5))
        {
            return null;
        }

        var digits = new System.Text.StringBuilder();
        for (var j = k + 4; j + 3 <= count; j += 10)
        {
            // 终止符：宽条、窄空、窄条，后面是空白
            if (runs[j] >= n * 1.8 && runs[j + 1] < n * 1.8 && runs[j + 2] < n * 1.8 && QuietAfter(runs, count, j + 2, n * 5))
            {
                if (digits.Length < 6 || !TwoWidths(runs, k, j + 3 - k, 0.3))
                {
                    return null;
                }

                return (digits.ToString(), j + 2);
            }

            if (j + 10 > count)
            {
                return null;
            }

            // 一对数字：五个条是前一位，五个空是后一位
            var width = Sum(runs, j, 10);
            if (width < n * 14 * 0.7 || width > n * 18 * 1.3)
            {
                return null;
            }

            var first = ItfDigit(runs[j], runs[j + 2], runs[j + 4], runs[j + 6], runs[j + 8]);
            var second = ItfDigit(runs[j + 1], runs[j + 3], runs[j + 5], runs[j + 7], runs[j + 9]);
            if (first < 0 || second < 0 || digits.Length > 80)
            {
                return null;
            }

            digits.Append((char)('0' + first)).Append((char)('0' + second));
        }

        return null;
    }
}
