// 识字认码（REVIEW R105）：在图上找二维码。照 ISO/IEC 18004 附录的参考做法自己写的：
// 1. 一行一行数游程，找暗亮暗亮暗 1:1:3:1:1 的地方，再竖着、横着交叉核对，得到定位图案的中心和模块大小（findFinders）；
// 2. 三个定位图案凑成直角三角形（两腰差不多长、夹角接近直角、模块差不多大），按叉乘分出左上、右上、左下（triple）；
// 3. 边长：先数两个定位图案之间那条定时图案有几格（看得清时是准的），再按测出的模块大小估，几个候选挨个试；
//    格式信息就在定位图案旁边，先用三点的平行四边形网格读它，读不出就换下一个，省得每个候选都去找校正图形；
// 4. 版本 2 起在右下角附近找校正图形当第四个点，四点透视变换后逐个模块取样（灰度插值、和块阈值比），交给 QrDecoder；
//    版本信息说的边长不一样就照它重来；读不出再按镜像（行列互换）读一遍。
// 先找深底浅码以外的（正常的），一个都没有再按反色找一遍（深色模式里浅色的码）。解出一个码后，落在它里面的候选（数据凑巧像定位图案）不再用。
namespace KittyTools.Core.Barcodes;

internal readonly record struct Finder(double X, double Y, double Module, int Count);

internal static class QrDetector
{
    private const int MaxFinders = 45;

    private const int MaxAttempts = 40;

    /// <summary>
    /// detection 上找定位图案，sampling 上取样（大图在缩小的图上找、原图上取；factor 是缩了几倍）。
    /// </summary>
    public static List<string> Detect(BarcodeImage detection, BarcodeImage sampling, int factor, Deadline deadline)
    {
        var results = new List<string>();
        foreach (var inverted in new[] { false, true })
        {
            // ponytail: 反色的码只在一个正常的都没找到时才找；一张图里两种都有时只认得出正常的那些
            if (deadline.Expired || (inverted && results.Count > 0))
            {
                break;
            }

            var finders = FindFinders(detection, inverted, deadline);
            if (finders.Count < 3)
            {
                continue;
            }

            foreach (var text in DecodeTriples(finders, sampling, factor, inverted, deadline))
            {
                if (!results.Contains(text))
                {
                    results.Add(text);
                }
            }
        }

        return results;
    }

    private static bool FinderRatio(int r0, int r1, int r2, int r3, int r4)
    {
        var total = r0 + r1 + r2 + r3 + r4;
        if (total < 7)
        {
            return false;
        }

        var m = total / 7.0;
        var unit = m * 0.5 + 0.5;
        return Math.Abs(r0 - m) <= unit && Math.Abs(r1 - m) <= unit && Math.Abs(r3 - m) <= unit &&
               Math.Abs(r4 - m) <= unit && Math.Abs(r2 - 3 * m) <= m * 1.2 + 0.5;
    }

    private static List<Finder> FindFinders(BarcodeImage image, bool inverted, Deadline deadline)
    {
        var width = image.Width;
        var height = image.Height;
        var step = Math.Max(1, Math.Min(3, height / 400));
        var found = new List<Finder>();
        var runs = new int[width + 2];
        var starts = new int[width + 2];
        var rowsScanned = 0;
        for (var y = step / 2; y < height; y += step)
        {
            rowsScanned++;
            if (rowsScanned % 32 == 0 && deadline.Expired)
            {
                break;
            }

            // runs[0] 是亮的（可以是 0 长），之后暗亮交替
            var count = 0;
            runs[0] = 0;
            starts[0] = 0;
            var dark = false;
            for (var x = 0; x < width; x++)
            {
                var d = image.Dark(x, y, inverted);
                if (d != dark)
                {
                    count++;
                    runs[count] = 0;
                    starts[count] = x;
                    dark = d;
                }

                runs[count]++;
            }

            count++;
            for (var k = 1; k + 4 < count; k += 2)
            {
                if (!FinderRatio(runs[k], runs[k + 1], runs[k + 2], runs[k + 3], runs[k + 4]))
                {
                    continue;
                }

                var total = runs[k] + runs[k + 1] + runs[k + 2] + runs[k + 3] + runs[k + 4];
                var cx = starts[k + 2] + runs[k + 2] / 2.0;
                if (Confirm(image, inverted, cx, y, total) is { } finder)
                {
                    Add(found, finder);
                }
            }
        }

        // 中心够高、能跨过两行扫描线却只在一行上见到的，多半是噪点
        return found
            .Where(f => f.Count >= 2 || f.Module * 3 < step * 2)
            .OrderByDescending(f => f.Count)
            .Take(MaxFinders)
            .ToList();
    }

    /// <summary>竖着核对、横着核对，再在核对出的列上竖着核对一次。</summary>
    private static Finder? Confirm(BarcodeImage image, bool inverted, double cx, int y, int total)
    {
        if (CrossCheck(image, inverted, (int)cx, y, total, true) is not { } first)
        {
            return null;
        }

        if (CrossCheck(image, inverted, (int)cx, (int)first.Center, total, false) is not { } across)
        {
            return null;
        }

        if (CrossCheck(image, inverted, (int)across.Center, (int)first.Center, first.Total, true) is not { } down)
        {
            return null;
        }

        if (Math.Max(across.Total, down.Total) > 1.6 * Math.Min(across.Total, down.Total))
        {
            return null;
        }

        return new Finder(across.Center, down.Center, (across.Total + down.Total) / 14.0, 1);
    }

    /// <summary>
    /// 过 (x, y) 沿一列（vertical）或一行数 1:1:3:1:1 的五段；对得上返回中心坐标和五段总长。
    /// </summary>
    private static (double Center, int Total)? CrossCheck(BarcodeImage image, bool inverted, int x, int y, int expected, bool vertical)
    {
        var limit = vertical ? image.Height : image.Width;
        var line = vertical ? x : y;
        var other = vertical ? image.Width : image.Height;
        var i = vertical ? y : x;
        if (line < 0 || line >= other || i < 0 || i >= limit)
        {
            return null;
        }

        bool Dark(int p) => vertical ? image.Dark(line, p, inverted) : image.Dark(p, line, inverted);

        if (!Dark(i))
        {
            return null;
        }

        var maxRun = expected;
        var origin = i;
        var c2 = 0;
        while (i >= 0 && Dark(i) && c2 <= maxRun)
        {
            c2++;
            i--;
        }

        if (i < 0 || c2 > maxRun)
        {
            return null;
        }

        var c1 = 0;
        while (i >= 0 && !Dark(i) && c1 <= maxRun)
        {
            c1++;
            i--;
        }

        if (i < 0 || c1 > maxRun)
        {
            return null;
        }

        var c0 = 0;
        while (i >= 0 && Dark(i) && c0 <= maxRun)
        {
            c0++;
            i--;
        }

        if (c0 > maxRun)
        {
            return null;
        }

        i = origin + 1;
        while (i < limit && Dark(i) && c2 <= maxRun)
        {
            c2++;
            i++;
        }

        if (i >= limit || c2 > maxRun)
        {
            return null;
        }

        var c3 = 0;
        while (i < limit && !Dark(i) && c3 <= maxRun)
        {
            c3++;
            i++;
        }

        if (i >= limit || c3 > maxRun)
        {
            return null;
        }

        var c4 = 0;
        while (i < limit && Dark(i) && c4 <= maxRun)
        {
            c4++;
            i++;
        }

        if (c4 > maxRun)
        {
            return null;
        }

        var total = c0 + c1 + c2 + c3 + c4;
        if (total * 2 < expected || total > expected * 2 || !FinderRatio(c0, c1, c2, c3, c4))
        {
            return null;
        }

        return (i - c4 - c3 - c2 / 2.0, total);
    }

    /// <summary>和已有的候选挨得近、模块差不多大就并进去（按次数加权平均），否则另记一个。</summary>
    private static void Add(List<Finder> found, Finder finder)
    {
        for (var i = 0; i < found.Count; i++)
        {
            var f = found[i];
            var module = Math.Max(f.Module, finder.Module);
            if (Math.Abs(f.X - finder.X) <= module * 2 && Math.Abs(f.Y - finder.Y) <= module * 2 &&
                Math.Abs(f.Module - finder.Module) <= module * 0.5)
            {
                double n = f.Count;
                found[i] = new Finder(
                    (f.X * n + finder.X) / (n + 1), (f.Y * n + finder.Y) / (n + 1),
                    (f.Module * n + finder.Module) / (n + 1), f.Count + 1);
                return;
            }
        }

        found.Add(finder);
    }

    private readonly record struct Triple(int TopLeft, int TopRight, int BottomLeft, double Score);

    private static List<string> DecodeTriples(List<Finder> finders, BarcodeImage image, int factor, bool inverted, Deadline deadline)
    {
        var triples = new List<Triple>();
        var n = finders.Count;
        for (var i = 0; i < n; i++)
        {
            for (var j = i + 1; j < n; j++)
            {
                for (var k = j + 1; k < n; k++)
                {
                    if (MakeTriple(finders, i, j, k) is { } triple)
                    {
                        triples.Add(triple);
                    }
                }
            }
        }

        var used = new HashSet<int>();
        var results = new List<string>();
        var attempts = 0;
        foreach (var t in triples.OrderBy(candidate => candidate.Score))
        {
            if (used.Contains(t.TopLeft) || used.Contains(t.TopRight) || used.Contains(t.BottomLeft))
            {
                continue;
            }

            if (attempts >= MaxAttempts || deadline.Expired)
            {
                break;
            }

            attempts++;
            var tl = Scaled(finders[t.TopLeft], image, inverted, factor);
            var tr = Scaled(finders[t.TopRight], image, inverted, factor);
            var bl = Scaled(finders[t.BottomLeft], image, inverted, factor);
            if (DecodeGrid(image, inverted, tl, tr, bl) is not { } decoded)
            {
                continue;
            }

            // 这三个，加上落在这个码里面的候选（数据凑巧像定位图案），都不再用
            used.Add(t.TopLeft);
            used.Add(t.TopRight);
            used.Add(t.BottomLeft);
            for (var i = 0; i < finders.Count; i++)
            {
                if (Inside(decoded.Corners, finders[i].X * factor, finders[i].Y * factor))
                {
                    used.Add(i);
                }
            }

            if (!results.Contains(decoded.Text))
            {
                results.Add(decoded.Text);
            }
        }

        return results;
    }

    /// <summary>点在凸四边形里（两种绕向都行）。</summary>
    private static bool Inside((double X, double Y)[] quad, double x, double y)
    {
        var positive = false;
        var negative = false;
        for (var i = 0; i < 4; i++)
        {
            var a = quad[i];
            var b = quad[(i + 1) % 4];
            var cross = (b.X - a.X) * (y - a.Y) - (b.Y - a.Y) * (x - a.X);
            if (cross > 0)
            {
                positive = true;
            }

            if (cross < 0)
            {
                negative = true;
            }
        }

        return !(positive && negative);
    }

    private static Triple? MakeTriple(List<Finder> f, int i, int j, int k)
    {
        var mMax = Math.Max(f[i].Module, Math.Max(f[j].Module, f[k].Module));
        var mMin = Math.Min(f[i].Module, Math.Min(f[j].Module, f[k].Module));
        if (mMax > mMin * 1.7)
        {
            return null;
        }

        double Squared(int p, int q)
        {
            var dx = f[p].X - f[q].X;
            var dy = f[p].Y - f[q].Y;
            return dx * dx + dy * dy;
        }

        var ij = Squared(i, j);
        var ik = Squared(i, k);
        var jk = Squared(j, k);
        // 最长的边是斜边，对着它的是左上角
        int corner, p, q;
        if (jk >= ij && jk >= ik)
        {
            (corner, p, q) = (i, j, k);
        }
        else if (ik >= ij && ik >= jk)
        {
            (corner, p, q) = (j, i, k);
        }
        else
        {
            (corner, p, q) = (k, i, j);
        }

        var ax = f[p].X - f[corner].X;
        var ay = f[p].Y - f[corner].Y;
        var bx = f[q].X - f[corner].X;
        var by = f[q].Y - f[corner].Y;
        var la = Math.Sqrt(ax * ax + ay * ay);
        var lb = Math.Sqrt(bx * bx + by * by);
        if (la < 1 || lb < 1 || Math.Max(la, lb) > 1.6 * Math.Min(la, lb))
        {
            return null;
        }

        var cosine = (ax * bx + ay * by) / (la * lb);
        if (Math.Abs(cosine) > 0.3)
        {
            return null;
        }

        var module = (f[i].Module + f[j].Module + f[k].Module) / 3;
        var across = (la + lb) / 2 / module;
        if (across < 10 || across > 190)
        {
            return null;
        }

        // 图上 y 向下：(右上 - 左上) × (左下 - 左上) > 0
        if (ax * by - ay * bx < 0)
        {
            (p, q) = (q, p);
        }

        var score = Math.Abs(la - lb) / Math.Max(la, lb) + Math.Abs(cosine) + (mMax / mMin - 1);
        return new Triple(corner, p, q, score);
    }

    /// <summary>缩小图上的定位图案换到原图坐标，在原图上重新核对一下中心。</summary>
    private static Finder Scaled(Finder f, BarcodeImage image, bool inverted, int factor)
    {
        if (factor == 1)
        {
            return f;
        }

        var mapped = new Finder(f.X * factor, f.Y * factor, f.Module * factor, f.Count);
        var total = (int)(mapped.Module * 7);
        var x = (int)mapped.X;
        var y = (int)mapped.Y;
        if (x < 0 || y < 0 || x >= image.Width || y >= image.Height || !image.Dark(x, y, inverted))
        {
            return mapped;
        }

        if (CrossCheck(image, inverted, x, y, total, true) is not { } down ||
            CrossCheck(image, inverted, x, (int)down.Center, total, false) is not { } across)
        {
            return mapped;
        }

        return new Finder(across.Center, down.Center, (down.Total + across.Total) / 14.0, f.Count);
    }

    /// <summary>读出的内容和码在图上的四个角。</summary>
    private static (string Text, (double X, double Y)[] Corners)? DecodeGrid(
        BarcodeImage image, bool inverted, Finder tl, Finder tr, Finder bl)
    {
        var moduleTop = AxisModule(image, inverted, tl, tr) ?? (tl.Module + tr.Module) / 2;
        var moduleLeft = AxisModule(image, inverted, tl, bl) ?? (tl.Module + bl.Module) / 2;
        var module = (moduleTop + moduleLeft) / 2;
        var top = Distance(tl, tr);
        var left = Distance(tl, bl);

        // 边长的候选：定时图案数出来的（看得清时是准的），再按两种量法的模块大小估，各带前后一档；最后再放宽两档
        var sizes = new List<int>();
        if (TimingSize(image, inverted, tl, tr, bl, moduleTop) is { } row)
        {
            sizes.Add(row);
        }

        if (TimingSize(image, inverted, tl, bl, tr, moduleLeft) is { } column)
        {
            sizes.Add(column);
        }

        var finderModule = (tl.Module + tr.Module + bl.Module) / 3;
        foreach (var estimate in new[] { (top / moduleTop + left / moduleLeft) / 2 + 7, (top + left) / 2 / finderModule + 7 })
        {
            var nearest = 17 + 4 * (int)Math.Round((estimate - 17) / 4, MidpointRounding.AwayFromZero);
            sizes.Add(nearest);
            sizes.Add(nearest + 4);
            sizes.Add(nearest - 4);
        }

        sizes.Add(sizes[0] + 8);
        sizes.Add(sizes[0] - 8);

        var tried = new HashSet<int>();
        for (var index = 0; index < sizes.Count; index++)
        {
            var size = sizes[index];
            if (size < 21 || size > 177 || !tried.Add(size))
            {
                continue;
            }

            // 格式信息挨着定位图案，三点的平行四边形网格在那里已经够准：先读它，读不出就不用找校正图形、读别的了
            var affine = Perspective.QuadToQuad(
                new (double X, double Y)[] { (3.5, 3.5), (size - 3.5, 3.5), (size - 3.5, size - 3.5), (3.5, size - 3.5) },
                new (double X, double Y)[] { (tl.X, tl.Y), (tr.X, tr.Y), (tr.X + bl.X - tl.X, tr.Y + bl.Y - tl.Y), (bl.X, bl.Y) });
            bool AffineDark(int x, int y)
            {
                var (px, py) = affine.Map(x + 0.5, y + 0.5);
                return (image.Level(px, py) < image.Threshold(px, py)) != inverted;
            }

            if (!QrDecoder.HasFormat(size, AffineDark) && !QrDecoder.HasFormat(size, (x, y) => AffineDark(y, x)))
            {
                continue;
            }

            if (Grid(image, inverted, tl, tr, bl, size, module) is not { } transform)
            {
                continue;
            }

            // 模块中心的灰度（模块大时和周围四个点一起平均）和那里的块阈值比
            var offsets = module >= 3 ? FivePoints : CenterPoint;
            bool Dark(int x, int y)
            {
                var sum = 0.0;
                foreach (var (ox, oy) in offsets)
                {
                    var (px, py) = transform.Map(x + ox, y + oy);
                    sum += image.Level(px, py);
                }

                var (cx, cy) = transform.Map(x + 0.5, y + 0.5);
                return (sum / offsets.Length < image.Threshold(cx, cy)) != inverted;
            }

            var outcome = QrDecoder.Decode(size, Dark);
            if (outcome.Version > 0)
            {
                // 版本信息读得出、和估的边长不一样：马上照它试
                sizes.Insert(index + 1, 17 + 4 * outcome.Version);
                continue;
            }

            if (outcome.Text is null)
            {
                outcome = QrDecoder.Decode(size, (x, y) => Dark(y, x));  // 镜像的码
            }

            if (outcome.Text is { } text)
            {
                var corners = new (double X, double Y)[]
                {
                    transform.Map(0, 0), transform.Map(size, 0), transform.Map(size, size), transform.Map(0, size),
                };
                return (text, corners);
            }
        }

        return null;
    }

    private static readonly (double X, double Y)[] FivePoints = { (0.5, 0.5), (0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7) };

    private static readonly (double X, double Y)[] CenterPoint = { (0.5, 0.5) };

    private static double Distance(Finder a, Finder b) => Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));

    /// <summary>沿两个定位图案中心的连线量模块大小（中心到外沿是 3.5 个模块）。</summary>
    private static double? AxisModule(BarcodeImage image, bool inverted, Finder a, Finder b)
    {
        if (EdgeDistance(image, inverted, a, b) is not { } x || EdgeDistance(image, inverted, b, a) is not { } y)
        {
            return null;
        }

        return (x + y) / 7;
    }

    /// <summary>从定位图案中心朝另一个走，到它的外沿（暗→亮→暗→亮的第三次变化）有多远。</summary>
    private static double? EdgeDistance(BarcodeImage image, bool inverted, Finder from, Finder to)
    {
        var length = Distance(from, to);
        var ux = (to.X - from.X) / length;
        var uy = (to.Y - from.Y) / length;
        var state = 0;  // 0 中心的暗块，1 亮环，2 暗环
        var pending = false;
        var limit = Math.Min(length / 2, from.Module * 7);
        for (var t = 0.5; t - 0.5 < limit; t += 0.5)
        {
            var px = (int)(from.X + ux * t);
            var py = (int)(from.Y + uy * t);
            if (px < 0 || py < 0 || px >= image.Width || py >= image.Height)
            {
                return null;
            }

            var wanted = state != 1;
            if (image.Dark(px, py, inverted) == wanted)
            {
                pending = false;
                continue;
            }

            // 连着两个点都变了才算（一个孤立的像素是噪点）
            if (!pending)
            {
                pending = true;
                continue;
            }

            pending = false;
            if (state == 2)
            {
                return t - 0.5;
            }

            state++;
        }

        return null;
    }

    /// <summary>
    /// 数定时图案定边长：沿第 6 行（或第 6 列）从一个定位图案走到另一个，中间交替的单个模块有 边长 - 14 个。
    /// 看着不像定时图案时返回 null。
    /// </summary>
    private static int? TimingSize(BarcodeImage image, bool inverted, Finder a, Finder b, Finder side, double module)
    {
        // 从定位图案中心那一行（3.5）往第三个定位图案那边挪 3 个模块，到定时图案那一行（6.5）
        var sideLength = Distance(a, side);
        var ox = (side.X - a.X) / sideLength * module * 3;
        var oy = (side.Y - a.Y) / sideLength * module * 3;
        var x0 = a.X + ox;
        var y0 = a.Y + oy;
        var dx = b.X + ox - x0;
        var dy = b.Y + oy - y0;
        var steps = (int)(Math.Sqrt(dx * dx + dy * dy) / 0.5);
        if (steps < 8)
        {
            return null;
        }

        var runs = new List<double>();
        var current = true;
        var run = 0.0;
        for (var i = 0; i <= steps; i++)
        {
            var t = (double)i / steps;
            var x = (int)(x0 + dx * t);
            var y = (int)(y0 + dy * t);
            if (x < 0 || y < 0 || x >= image.Width || y >= image.Height)
            {
                return null;
            }

            var d = image.Dark(x, y, inverted);
            if (d != current)
            {
                runs.Add(run);
                run = 0;
                current = d;
            }

            run += 0.5;
        }

        runs.Add(run);

        // 不到半个模块的一小段是噪点：和两边并成一段
        for (var i = 1; i < runs.Count - 1;)
        {
            if (runs[i] < module * 0.45)
            {
                runs[i - 1] += runs[i] + runs[i + 1];
                runs.RemoveRange(i, 2);
                i = Math.Max(1, i - 1);
            }
            else
            {
                i++;
            }
        }

        // 暗（定位图案的边）、交替的单个模块、暗（另一个定位图案）：头尾都是暗的
        if (runs.Count < 9 || runs.Count % 2 == 0)
        {
            return null;
        }

        for (var i = 1; i < runs.Count - 1; i++)
        {
            if (runs[i] < module * 0.4 || runs[i] > module * 1.8)
            {
                return null;
            }
        }

        var size = runs.Count - 2 + 14;
        return (size - 17) % 4 == 0 && size <= 177 ? size : null;
    }

    /// <summary>模块坐标 → 图上坐标；码有一截要伸到图外很远时返回 null。</summary>
    private static Perspective? Grid(BarcodeImage image, bool inverted, Finder tl, Finder tr, Finder bl, int size, double module)
    {
        var version = (size - 17) / 4;
        var far = size - 3.5;
        (double X, double Y) corner = (tr.X + bl.X - tl.X, tr.Y + bl.Y - tl.Y);
        var cornerModule = far;
        if (version >= 2)
        {
            // 右下角的校正图形，中心在 (size - 6.5, size - 6.5)；先按平行四边形估个位置，在附近由近到远找
            var f = (size - 10.0) / (size - 7.0);
            var ex = tl.X + (tr.X - tl.X + bl.X - tl.X) * f;
            var ey = tl.Y + (tr.Y - tl.Y + bl.Y - tl.Y) * f;
            var unitX = ((tr.X - tl.X) / (size - 7.0), (tr.Y - tl.Y) / (size - 7.0));
            var unitY = ((bl.X - tl.X) / (size - 7.0), (bl.Y - tl.Y) / (size - 7.0));
            foreach (var radius in new[] { 4.0, 8.0, 14.0 })
            {
                if (FindAlignment(image, inverted, ex, ey, module, radius, unitX, unitY) is { } found)
                {
                    corner = found;
                    cornerModule = size - 6.5;
                    break;
                }
            }
        }

        var transform = Perspective.QuadToQuad(
            new (double X, double Y)[] { (3.5, 3.5), (far, 3.5), (cornerModule, cornerModule), (3.5, far) },
            new (double X, double Y)[] { (tl.X, tl.Y), (tr.X, tr.Y), corner, (bl.X, bl.Y) });
        var margin = module * 2;
        foreach (var (u, v) in new (double U, double V)[] { (0, 0), (size, 0), (size, size), (0, size) })
        {
            var (x, y) = transform.Map(u, v);
            if (!(x >= -margin && y >= -margin && x <= image.Width + margin && y <= image.Height + margin))
            {
                return null;
            }
        }

        return transform;
    }

    /// <summary>
    /// 在 (ex, ey) 周围 radius 个模块里找校正图形（暗、亮、暗各一个模块宽的 5×5 环），按 5×5 对得上几格挑，一样多挑离估计近的；
    /// 25 格里对不上 22 格就当没找到。
    /// </summary>
    private static (double X, double Y)? FindAlignment(
        BarcodeImage image, bool inverted, double ex, double ey, double module, double radius,
        (double X, double Y) unitX, (double X, double Y) unitY)
    {
        var r = radius * module;
        var x0 = Math.Max(0, (int)(ex - r));
        var x1 = Math.Min(image.Width - 1, (int)(ex + r));
        var y0 = Math.Max(0, (int)(ey - r));
        var y1 = Math.Min(image.Height - 1, (int)(ey + r));
        if (x1 - x0 < module * 3 || y1 - y0 < module * 3)
        {
            return null;
        }

        var unit = module * 0.6 + 0.5;
        (double X, double Y)? best = null;
        var bestScore = 0;
        var bestDistance = double.MaxValue;
        var runs = new int[x1 - x0 + 3];
        var starts = new int[x1 - x0 + 3];
        for (var y = y0; y <= y1; y++)
        {
            var count = 0;
            runs[0] = 0;
            starts[0] = x0;
            var dark = false;
            for (var x = x0; x <= x1; x++)
            {
                var d = image.Dark(x, y, inverted);
                if (d != dark)
                {
                    count++;
                    runs[count] = 0;
                    starts[count] = x;
                    dark = d;
                }

                runs[count]++;
            }

            count++;
            // 暗的中心（奇数下标），两边各一个模块宽的亮，再外面还有东西
            for (var k = 3; k + 2 < count; k += 2)
            {
                if (Math.Abs(runs[k] - module) > unit || Math.Abs(runs[k - 1] - module) > unit || Math.Abs(runs[k + 1] - module) > unit)
                {
                    continue;
                }

                var cx = starts[k] + runs[k] / 2.0;
                if (AlignmentCenter(image, inverted, (int)cx, y, module, true) is not { } cy ||
                    AlignmentCenter(image, inverted, (int)cx, (int)cy, module, false) is not { } cx2)
                {
                    continue;
                }

                var score = AlignmentScore(image, inverted, cx2, cy, unitX, unitY);
                var distance = Math.Sqrt((cx2 - ex) * (cx2 - ex) + (cy - ey) * (cy - ey));
                if (score > bestScore || (score == bestScore && distance < bestDistance))
                {
                    best = (cx2, cy);
                    bestScore = score;
                    bestDistance = distance;
                }
            }
        }

        return bestScore >= 22 ? best : null;
    }

    /// <summary>沿一列（vertical）或一行：一个模块宽的暗段、两边各一个模块宽的亮段、再外面是暗的；对得上返回暗段中心。</summary>
    private static double? AlignmentCenter(BarcodeImage image, bool inverted, int x, int y, double module, bool vertical)
    {
        var limit = vertical ? image.Height : image.Width;
        var other = vertical ? image.Width : image.Height;
        var line = vertical ? x : y;
        if (line < 0 || line >= other)
        {
            return null;
        }

        bool Dark(int p) => vertical ? image.Dark(x, p, inverted) : image.Dark(p, y, inverted);

        var origin = vertical ? y : x;
        if (origin < 0 || origin >= limit || !Dark(origin))
        {
            return null;
        }

        var maxRun = (int)(module * 2) + 2;
        var unit = module * 0.6 + 0.5;
        var up = origin;
        while (up >= 0 && Dark(up) && origin - up <= maxRun)
        {
            up--;
        }

        var down = origin;
        while (down < limit && Dark(down) && down - origin <= maxRun)
        {
            down++;
        }

        var center = down - up - 1;
        if (Math.Abs(center - module) > unit)
        {
            return null;
        }

        var lightUp = 0;
        var i = up;
        while (i >= 0 && !Dark(i) && lightUp <= maxRun)
        {
            lightUp++;
            i--;
        }

        if (i < 0 || Math.Abs(lightUp - module) > unit)
        {
            return null;
        }

        var lightDown = 0;
        i = down;
        while (i < limit && !Dark(i) && lightDown <= maxRun)
        {
            lightDown++;
            i++;
        }

        if (i >= limit || Math.Abs(lightDown - module) > unit)
        {
            return null;
        }

        return up + 1 + center / 2.0;
    }

    /// <summary>以 (cx, cy) 为中心的 5×5 里有几格对得上校正图形（外圈暗、中圈亮、中心暗）。</summary>
    private static int AlignmentScore(BarcodeImage image, bool inverted, double cx, double cy, (double X, double Y) unitX, (double X, double Y) unitY)
    {
        var score = 0;
        for (var dy = -2; dy <= 2; dy++)
        {
            for (var dx = -2; dx <= 2; dx++)
            {
                var px = (int)Math.Floor(cx + dx * unitX.X + dy * unitY.X);
                var py = (int)Math.Floor(cy + dx * unitX.Y + dy * unitY.Y);
                if (px < 0 || py < 0 || px >= image.Width || py >= image.Height)
                {
                    continue;
                }

                var ring = Math.Max(Math.Abs(dx), Math.Abs(dy));
                if (image.Dark(px, py, inverted) == (ring != 1))
                {
                    score++;
                }
            }
        }

        return score;
    }
}
