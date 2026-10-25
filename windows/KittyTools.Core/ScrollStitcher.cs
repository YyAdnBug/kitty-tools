// 长截图的拼接（第三版 §7，纯函数 + 单测；做法照 mac 的 Screenshot/ScrollStitcher.swift 文件头）：
// 相邻两帧都是「同一块选区」的实时画面，下一帧比上一帧多滚了一段。先按整行哈希投票找重叠：
// 用新帧顶部若干行去上一帧里找位置（向下滚），或反过来（向上滚）；哈希对不上再用每隔 4 像素采样的
// 容差比较兜底；吸顶栏（每一帧最上面都一样）不参与投票，避免把页头拼进去两次；输出高度上限 30000。
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

    /// <summary>把两帧接起来：返回新的整幅画面；接口不清（找不到重叠）时返回 null。</summary>
    public static ScrollFrame? Append(ScrollFrame previous, ScrollFrame next, ScrollDirection direction)
    {
        if (previous.Width != next.Width)
        {
            return null;
        }

        // 吸顶栏（两帧最上面一样的那几行）不参与拼接：先剥掉，拼完再放回去一次。
        var sticky = StickyRows(previous, next);
        var previousBody = Skip(previous, sticky);
        var nextBody = Skip(next, sticky);
        var overlap = FindOverlap(previousBody, nextBody, direction);
        if (overlap <= 0)
        {
            return null;
        }

        var body = direction == ScrollDirection.Down
            ? Combine(previousBody, nextBody, overlap, up: false)
            : Combine(previousBody, nextBody, overlap, up: true);
        return sticky == 0 ? body : Prepend(previous, sticky, body);
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
        var limit = Math.Min(Math.Min(previous.Height, next.Height) / 4, 120);
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
