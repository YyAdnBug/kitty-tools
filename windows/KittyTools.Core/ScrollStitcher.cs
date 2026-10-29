// 长截图的拼接（第三版 §7，纯函数 + 单测；做法照 mac 的 Screenshot/ScrollStitcher.swift 文件头）：
// 相邻两帧都是「同一块选区」的实时画面，下一帧比上一帧多滚了一段。先按整行哈希投票找重叠：
// 用新帧顶部若干行去上一帧里找位置（向下滚），或反过来（向上滚）；哈希对不上再用每隔 4 像素采样的
// 容差比较兜底；吸顶栏（每一帧最上面都一样）不参与投票，避免把页头拼进去两次；输出高度上限 30000。
// 拍的过程中用 ScrollCanvas（REVIEW R43）：拼好的部分按条带存，每拍只拿找重叠要看的那几行比，不再整张重新分配、重新哈希。
using System.Buffers;

namespace KittyTools.Core;

public sealed class ScrollFrame
{
    public ScrollFrame(int width, int height, int[] pixels)
    {
        Width = width;
        Height = height;
        Pixels = pixels;
        Hashes = new uint[height];
        for (var row = 0; row < height; row++)
        {
            var hash = 2166136261u;
            for (var x = 0; x < width; x++)
            {
                hash = (hash ^ (uint)pixels[row * width + x]) * 16777619u;
            }

            Hashes[row] = hash;
        }
    }

    public int Width { get; }

    public int Height { get; }

    public int[] Pixels { get; }

    public uint[] Hashes { get; }
}

public enum ScrollDirection
{
    Down,
    Up,
}

public static class ScrollStitcher
{
    public const int MaxOutputHeight = 30_000;

    public const int MinOverlap = 8;

    public const int MaxOverlap = 800;

    /// <summary>吸顶栏最多算这么多行（StickyRows）。</summary>
    public const int MaxStickyRows = 120;

    /// <summary>把两帧接起来：返回新的整幅画面；接口不清（找不到重叠）时返回 null。</summary>
    public static ScrollFrame? Append(ScrollFrame previous, ScrollFrame next, ScrollDirection direction)
    {
        if (Plan(previous, next, direction, out var previousBody, out var nextBody) is not { } plan)
        {
            return null;
        }

        var body = Combine(previousBody, nextBody, plan.Overlap, up: direction == ScrollDirection.Up);
        return plan.Sticky == 0 ? body : Prepend(previous, plan.Sticky, body);
    }

    /// <summary>两帧怎么接：吸顶栏几行、重叠几行；接口不清（宽度不一样、找不到重叠）返回 null。Append 和 ScrollCanvas 共用。</summary>
    public static (int Sticky, int Overlap)? Plan(ScrollFrame previous, ScrollFrame next, ScrollDirection direction)
        => Plan(previous, next, direction, out _, out _);

    private static (int Sticky, int Overlap)? Plan(
        ScrollFrame previous, ScrollFrame next, ScrollDirection direction, out ScrollFrame previousBody, out ScrollFrame nextBody)
    {
        previousBody = previous;
        nextBody = next;
        if (previous.Width != next.Width)
        {
            return null;
        }

        // 吸顶栏（两帧最上面一样的那几行）不参与拼接：先剥掉，拼完再放回去一次。
        var sticky = StickyRows(previous, next);
        previousBody = Skip(previous, sticky);
        nextBody = Skip(next, sticky);
        var overlap = FindOverlap(previousBody, nextBody, direction);
        return overlap <= 0 ? null : (sticky, overlap);
    }

    /// <summary>找重叠行数：向下滚 = 新帧顶部与上一帧底部重合；向上滚 = 新帧底部与上一帧顶部重合。</summary>
    public static int FindOverlap(ScrollFrame previous, ScrollFrame next, ScrollDirection direction)
    {
        var sticky = StickyRows(previous, next);
        var max = Math.Min(Math.Min(previous.Height, next.Height), MaxOverlap);
        var candidates = new List<(int Overlap, int Votes)>();
        for (var overlap = Math.Max(MinOverlap, sticky); overlap <= max; overlap++)
        {
            var votes = 0;
            var samples = Math.Min(overlap, 40);
            for (var sample = 0; sample < samples; sample++)
            {
                var row = sample * (overlap - 1) / Math.Max(samples - 1, 1);
                var matches = direction == ScrollDirection.Down
                    ? previous.Hashes[previous.Height - overlap + row] == next.Hashes[row]
                    : previous.Hashes[row] == next.Hashes[next.Height - overlap + row];
                if (matches)
                {
                    votes++;
                }
            }

            if (votes >= Math.Max(2, samples * 3 / 4))
            {
                candidates.Add((overlap, votes));
            }
        }

        if (candidates.Count == 0)
        {
            return FuzzyOverlap(previous, next, direction, sticky);
        }

        // 投票数一样时取重叠少的（多拼一点内容）。
        return candidates.OrderByDescending(item => item.Votes).ThenBy(item => item.Overlap).First().Overlap;
    }

    /// <summary>吸顶栏：两帧最上面连续相同的行数（向下滚时不吃进新画面）。最多算 120 行。</summary>
    public static int StickyRows(ScrollFrame previous, ScrollFrame next)
    {
        var limit = Math.Min(Math.Min(previous.Height, next.Height) / 4, MaxStickyRows);
        var rows = 0;
        while (rows < limit && previous.Hashes[rows] == next.Hashes[rows])
        {
            rows++;
        }

        return rows;
    }

    private static int FuzzyOverlap(ScrollFrame previous, ScrollFrame next, ScrollDirection direction, int sticky)
    {
        var max = Math.Min(Math.Min(previous.Height, next.Height), MaxOverlap);
        for (var overlap = max; overlap >= Math.Max(MinOverlap, sticky); overlap--)
        {
            if (Similar(previous, next, overlap, direction))
            {
                return overlap;
            }
        }

        return 0;
    }

    private static bool Similar(ScrollFrame previous, ScrollFrame next, int overlap, ScrollDirection direction)
    {
        var rows = Math.Min(overlap, 60);
        var misses = 0;
        for (var row = 0; row < rows; row++)
        {
            var previousRow = direction == ScrollDirection.Down
                ? previous.Height - overlap + row
                : row;
            var nextRow = direction == ScrollDirection.Down
                ? row
                : next.Height - overlap + row;
            var mismatches = 0;
            var samples = 0;
            for (var x = 0; x < previous.Width; x += 4)
            {
                samples++;
                var a = previous.Pixels[previousRow * previous.Width + x];
                var b = next.Pixels[nextRow * next.Width + x];
                if (!Close(a, b))
                {
                    mismatches++;
                }
            }

            if (mismatches > samples / 8)
            {
                misses++;
            }
        }

        return misses <= Math.Max(1, rows / 10);
    }

    private static bool Close(int a, int b)
    {
        for (var shift = 0; shift < 32; shift += 8)
        {
            var ca = (a >> shift) & 0xFF;
            var cb = (b >> shift) & 0xFF;
            if (Math.Abs(ca - cb) > 6)
            {
                return false;
            }
        }

        return true;
    }

    private static ScrollFrame Combine(ScrollFrame previous, ScrollFrame next, int overlap, bool up)
    {
        // up：next 在上面；down：next 在下面。重叠部分只留一份。
        var top = up ? next : previous;
        var source = up ? previous : next;
        var topRows = up ? next.Height : previous.Height;
        var take = source.Height - overlap;
        var height = Math.Min(topRows + take, MaxOutputHeight);
        var pixels = new int[previous.Width * height];
        Array.Copy(top.Pixels, 0, pixels, 0, Math.Min(topRows, height) * previous.Width);
        if (height > topRows)
        {
            Array.Copy(source.Pixels, overlap * previous.Width, pixels, topRows * previous.Width,
                (height - topRows) * previous.Width);
        }

        return new ScrollFrame(previous.Width, height, pixels);
    }

    /// <summary>去掉最上面 skip 行。</summary>
    private static ScrollFrame Skip(ScrollFrame frame, int skip)
    {
        if (skip <= 0)
        {
            return frame;
        }

        var rows = frame.Height - skip;
        var pixels = new int[frame.Width * rows];
        Array.Copy(frame.Pixels, skip * frame.Width, pixels, 0, pixels.Length);
        return new ScrollFrame(frame.Width, rows, pixels);
    }

    /// <summary>把 frame 最上面 rows 行放到 body 前面。</summary>
    private static ScrollFrame Prepend(ScrollFrame frame, int rows, ScrollFrame body)
    {
        var height = Math.Min(rows + body.Height, MaxOutputHeight);
        var pixels = new int[frame.Width * height];
        Array.Copy(frame.Pixels, 0, pixels, 0, Math.Min(rows, height) * frame.Width);
        if (height > rows)
        {
            Array.Copy(body.Pixels, 0, pixels, rows * frame.Width, (height - rows) * frame.Width);
        }

        return new ScrollFrame(frame.Width, height, pixels);
    }

    /// <summary>从多帧粘成一张（第一帧是起点）。</summary>
    public static ScrollFrame Stitch(IReadOnlyList<ScrollFrame> frames, ScrollDirection direction)
    {
        var current = frames[0];
        foreach (var frame in frames.Skip(1))
        {
            var next = Append(current, frame, direction);
            if (next is null)
            {
                continue;
            }

            current = next;
            if (current.Height >= MaxOutputHeight)
            {
                break;
            }
        }

        return current;
    }
}

/// <summary>
/// 拍到一半的长截图（REVIEW R43）：拼好的部分存成一串条带。以前每拍把整张长图重新分配、重新哈希（1440 × 30000 时一份 172 MB，
/// 有吸顶栏时一拍三份，拷贝量随长度平方涨）；现在每拍只拼一张「找重叠要看的那几行」的小图去和新帧比（ScrollStitcher.Plan），
/// 接上的新行另存一条，Compose 时才合成一张。吸顶栏、重叠的行数和整张逐帧拼的一模一样，结果逐像素相同（单测比过）。
/// </summary>
public sealed class ScrollCanvas
{
    /// <summary>找重叠时要看的最上面几行：外层吸顶栏 ≤ 120 行，剥掉它以后里面再判断一次吸顶栏又是 ≤ 120 行。</summary>
    private const int HeadRows = 2 * ScrollStitcher.MaxStickyRows;

    private readonly List<Strip> _strips = new();

    public ScrollCanvas(ScrollFrame first)
    {
        Width = first.Width;
        Height = first.Height;
        _strips.Add(new Strip(first.Pixels, 0, first.Height));
    }

    public int Width { get; }

    public int Height { get; private set; }

    /// <summary>接上一帧；接口不清（宽度不一样、找不到重叠）返回 false，图不变。同 ScrollStitcher.Append，到 30000 行截掉。</summary>
    public bool Append(ScrollFrame next, ScrollDirection direction)
    {
        if (next.Width != Width || ScrollStitcher.Plan(Probe(direction, next.Height), next, direction) is not { } plan)
        {
            return false;
        }

        var (sticky, overlap) = plan;
        if (direction == ScrollDirection.Down)
        {
            // 整张 + 新帧去掉吸顶栏和重叠的那一截，接在最下面。
            var take = Math.Min(next.Height - sticky - overlap, ScrollStitcher.MaxOutputHeight - Height);
            if (take > 0)
            {
                var rows = new int[take * Width];
                Array.Copy(next.Pixels, (sticky + overlap) * Width, rows, 0, rows.Length);
                _strips.Add(new Strip(rows, 0, take));
                Height += take;
            }

            return true;
        }

        // 往上：上面的吸顶栏 + 新帧去掉吸顶栏的整段 + 原来的身子去掉最上面 overlap 行（重叠的那一截留新帧的）。
        var head = Slice(0, sticky);
        var tail = Slice(sticky + overlap, Height);
        var body = new int[(next.Height - sticky) * Width];
        Array.Copy(next.Pixels, sticky * Width, body, 0, body.Length);
        _strips.Clear();
        _strips.AddRange(head);
        _strips.Add(new Strip(body, 0, next.Height - sticky));
        _strips.AddRange(tail);
        Height = _strips.Sum(strip => strip.Rows);
        Truncate(ScrollStitcher.MaxOutputHeight);
        Compact();
        return true;
    }

    /// <summary>合成一张（完成时调一次）。</summary>
    public ScrollFrame Compose()
    {
        var pixels = new int[Width * Height];
        var offset = 0;
        foreach (var strip in _strips)
        {
            Array.Copy(strip.Pixels, strip.Start * Width, pixels, offset * Width, strip.Rows * Width);
            offset += strip.Rows;
        }

        return new ScrollFrame(Width, Height, pixels);
    }

    /// <summary>
    /// 拿去和新帧比的那张小图：ScrollStitcher.Plan 只读最上面 HeadRows 行，和往下滚时最下面 / 往上滚时紧接着上面的 MaxOverlap 行；
    /// 高不小于新帧（Plan 里取的 min(上一张, 新帧) 才和整张时一样）。整张没那么高时就是整张。
    /// </summary>
    private ScrollFrame Probe(ScrollDirection direction, int nextHeight)
    {
        var height = Math.Max(
            direction == ScrollDirection.Down
                ? HeadRows + ScrollStitcher.MaxOverlap
                : ScrollStitcher.MaxStickyRows + ScrollStitcher.MaxOverlap,
            nextHeight);
        if (Height <= height)
        {
            return Compose();
        }

        var pixels = new int[height * Width];
        if (direction == ScrollDirection.Down)
        {
            CopyRows(0, HeadRows, pixels, 0);
            CopyRows(Height - (height - HeadRows), height - HeadRows, pixels, HeadRows);
        }
        else
        {
            CopyRows(0, height, pixels, 0);
        }

        return new ScrollFrame(Width, height, pixels);
    }

    /// <summary>把第 from 行起的 count 行拷到 destination 的第 at 行。</summary>
    private void CopyRows(int from, int count, int[] destination, int at)
    {
        foreach (var strip in Slice(from, from + count))
        {
            Array.Copy(strip.Pixels, strip.Start * Width, destination, at * Width, strip.Rows * Width);
            at += strip.Rows;
        }
    }

    /// <summary>第 from 到 to 行（不含）那一段的条带（不拷像素）。</summary>
    private List<Strip> Slice(int from, int to)
    {
        var result = new List<Strip>();
        var row = 0;
        foreach (var strip in _strips)
        {
            var start = Math.Max(from, row);
            var end = Math.Min(to, row + strip.Rows);
            if (end > start)
            {
                result.Add(new Strip(strip.Pixels, strip.Start + start - row, end - start));
            }

            row += strip.Rows;
        }

        return result;
    }

    private void Truncate(int maximum)
    {
        if (Height <= maximum)
        {
            return;
        }

        var kept = Slice(0, maximum);
        _strips.Clear();
        _strips.AddRange(kept);
        Height = maximum;
    }

    /// <summary>
    /// 往上拼时旧条带被切掉一截，切剩的不到一半就拷成一份刚好的：不然每拍都留着上一帧整份的像素，拍上百帧能多占好几百 MB。
    /// </summary>
    private void Compact()
    {
        for (var index = 0; index < _strips.Count; index++)
        {
            var strip = _strips[index];
            if (strip.Rows * Width * 2 < strip.Pixels.Length)
            {
                var pixels = new int[strip.Rows * Width];
                Array.Copy(strip.Pixels, strip.Start * Width, pixels, 0, pixels.Length);
                _strips[index] = new Strip(pixels, 0, strip.Rows);
            }
        }
    }

    private readonly record struct Strip(int[] Pixels, int Start, int Rows);
}
