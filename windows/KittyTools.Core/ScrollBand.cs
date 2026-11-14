// 长截图里「在动的那一块」（PLAN-v20 W1，照 mac 外部 PR #20 de3fae37 + 审查 b9e96dea；纯函数配单测）：
// 选区里只嵌着一块小滚动区（页面里的一块列表、对话记录）时，两帧之间能接上的位移只和这一块有关，不是选区高——
// 按选区高算自动滚动的领先上限，一次就滚过整块、之后怎么滚都「对不上」，只有往回滚才恢复。
// 所以累计**真滚过（接上了）的那些帧**里和上一帧比变过的行 / 列，取最长的连续一段：没滚时原地变的（选区里的动画、视频、
// 闪烁的输入光标、悬停高亮）不记，不然一开自动滚动，光标就被挪到动画上。块里留白（滚过去还是白的、不算变过）隔 32 行以内
// 连起来，不然量小一半。列只在自动滚动时统计（TracksColumns，要它才能把滚轮落进这一块；手动滚的落点由用户的光标定）。
// 还没量出来时 MovingRows 是空，会话按整个选区算（和以前一样）。
namespace KittyTools.Core;

/// <summary>帧里的一段像素行 / 列：[Start, End)。</summary>
public readonly record struct PixelRun(int Start, int End)
{
    public int Count => Math.Max(End - Start, 0);

    public bool IsEmpty => Count == 0;
}

public sealed class ScrollBand
{
    /// <summary>在动的那一块里允许隔几行没变（同 mac bandGap）：每 20 行一段字、6 行空白时，不连起来 80 行的一块只量出 14 行。</summary>
    public const int BandGap = 32;

    /// <summary>列按这么宽一段算（一段里有一列变了整段算变）；段里每隔 4 像素取一列比（同 ScrollStitcher 的容差比较）。</summary>
    public const int ColumnBin = 16;

    private readonly bool[] _movedRows;
    private readonly bool[] _movedColumns;
    private readonly int _width;

    public ScrollBand(int width, int height)
    {
        _width = Math.Max(width, 0);
        _movedRows = new bool[Math.Max(height, 0)];
        _movedColumns = new bool[(_width + ColumnBin - 1) / ColumnBin];
    }

    /// <summary>自动滚动时由会话打开。</summary>
    public bool TracksColumns { get; set; }

    /// <summary>真滚过的帧里变过的行中最长的连续一段（中间最多隔 BandGap 行）；空 = 还没量出来。</summary>
    public PixelRun MovingRows { get; private set; }

    /// <summary>同上，横向（像素列，按 ColumnBin 一段对齐）；只在 TracksColumns 时统计。</summary>
    public PixelRun MovingColumns { get; private set; }

    /// <summary>这一帧真滚过了（拼上了、长了行）：把和上一次拼上的那帧比变过的行 / 列记进去。</summary>
    public void NoteMoved(ScrollFrame previous, ScrollFrame next)
    {
        if (previous.Width != next.Width || previous.Height != next.Height || next.Height != _movedRows.Length || next.Width != _width)
        {
            return;
        }

        var grew = false;
        for (var row = 0; row < next.Height; row++)
        {
            if (previous.Hashes[row] == next.Hashes[row])
            {
                continue;
            }

            if (!_movedRows[row])
            {
                _movedRows[row] = true;
                grew = true;
            }

            if (!TracksColumns)
            {
                continue;
            }

            var offset = row * _width;
            for (var bin = 0; bin < _movedColumns.Length; bin++)
            {
                if (_movedColumns[bin])
                {
                    continue;
                }

                var end = Math.Min((bin + 1) * ColumnBin, _width);
                for (var x = bin * ColumnBin; x < end; x += 4)
                {
                    if (previous.Pixels[offset + x] != next.Pixels[offset + x])
                    {
                        _movedColumns[bin] = true;
                        grew = true;
                        break;
                    }
                }
            }
        }

        if (!grew)
        {
            return;
        }

        MovingRows = LargestRun(_movedRows, BandGap);
        var columns = LargestRun(_movedColumns, 1);
        if (!columns.IsEmpty)
        {
            MovingColumns = new PixelRun(columns.Start * ColumnBin, Math.Min(columns.End * ColumnBin, _width));
        }
    }

    /// <summary>
    /// moved 里最长的连续一段（中间最多隔 gap 个没动的位置；同 mac largestRun）：光标闪烁、页脚里走的秒表只是零星的几行，
    /// 连不成一段，不会把「在动的那一块」撑成整个选区。一样长时取靠上的那段。
    /// </summary>
    public static PixelRun LargestRun(IReadOnlyList<bool> moved, int gap)
    {
        var best = new PixelRun(0, 0);
        var start = -1;
        var last = -1;
        for (var index = 0; index < moved.Count; index++)
        {
            if (!moved[index])
            {
                continue;
            }

            if (start < 0 || index - last > gap + 1)
            {
                if (start >= 0 && last - start + 1 > best.Count)
                {
                    best = new PixelRun(start, last + 1);
                }

                start = index;
            }

            last = index;
        }

        if (start >= 0 && last - start + 1 > best.Count)
        {
            best = new PixelRun(start, last + 1);
        }

        return best;
    }

    /// <summary>
    /// 在动的那一块在屏幕上的位置（物理像素，同选区的坐标；同 mac ScrollCapture.bandRect）：还不知道是哪些行时是整个选区；
    /// 知道列时只取那几列（选区比这块宽时，滚轮落在两边照样滚到外层页面），夹在选区里。
    /// </summary>
    public static (int Left, int Top, int Width, int Height) BandRect(
        int left, int top, int width, int height, PixelRun rows, PixelRun columns)
    {
        if (rows.IsEmpty)
        {
            return (left, top, width, height);
        }

        var bandTop = top + Math.Clamp(rows.Start, 0, height);
        var bandHeight = Math.Max(Math.Min(rows.End, height) - Math.Clamp(rows.Start, 0, height), 1);
        var bandLeft = left;
        var bandWidth = width;
        if (!columns.IsEmpty)
        {
            var from = left + Math.Clamp(columns.Start, 0, width);
            var to = Math.Min(left + columns.End, left + width);
            if (to > from)
            {
                bandLeft = from;
                bandWidth = to - from;
            }
        }

        return (bandLeft, bandTop, bandWidth, bandHeight);
    }
}
