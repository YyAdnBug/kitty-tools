// 剪贴板列表的几何（前缀和；照 mac ClipboardPanelView.swift 的 ListLayout）：行 40、分组标题 24、选中行按透镜的常数高，
// 不量真实尺寸。列表就按它排（只实例化可见区附近的项），高亮、跟随滚动、吸顶标题都从这里算，所以算出来的位置就是画出来的位置。
// 坐标都不含列表四周的内缩（Inset）。纯函数，配单测。
namespace KittyTools.Core;

public enum ClipListEntryKind
{
    NewSnippet,
    Header,
    Row,
}

/// <summary>列表里的一项：「新建片段」行、分组标题（第几组）、条目行（在条目列表里的下标）。</summary>
public readonly record struct ClipListEntry(ClipListEntryKind Kind, int Section, int Item);

public sealed class ClipListLayout
{
    public const double Inset = 6;

    public const double HeaderHeight = 24;

    public const double RowHeight = ClipLens.Head;

    /// <summary>片段范围第一行「＋ 新建片段」的高度。</summary>
    public const double NewSnippetHeight = RowHeight;

    private readonly double[] _tops;
    private readonly int[] _rowEntry;

    /// <param name="dayKeys">每个条目（按列表顺序）所在的那一天；相邻相同的归一组。</param>
    /// <param name="lensItem">展开透镜的条目下标（没有为 -1）。</param>
    /// <param name="lensHeight">透镜总高（含行头 40）。</param>
    /// <param name="newSnippetRow">片段范围的第一行「＋ 新建片段」。</param>
    public ClipListLayout(IReadOnlyList<long> dayKeys, int lensItem, double lensHeight, bool newSnippetRow = false)
    {
        var entries = new List<ClipListEntry>(dayKeys.Count + 8);
        var tops = new List<double>(dayKeys.Count + 9);
        var sectionTops = new List<double>();
        var sectionCounts = new List<int>();
        _rowEntry = new int[dayKeys.Count];
        double y = 0;
        if (newSnippetRow)
        {
            entries.Add(new ClipListEntry(ClipListEntryKind.NewSnippet, 0, -1));
            tops.Add(0);
            y = NewSnippetHeight;
        }

        for (var item = 0; item < dayKeys.Count; item++)
        {
            if (item == 0 || dayKeys[item] != dayKeys[item - 1])
            {
                entries.Add(new ClipListEntry(ClipListEntryKind.Header, sectionTops.Count, -1));
                tops.Add(y);
                sectionTops.Add(y);
                sectionCounts.Add(0);
                y += HeaderHeight;
            }

            sectionCounts[^1]++;
            _rowEntry[item] = entries.Count;
            entries.Add(new ClipListEntry(ClipListEntryKind.Row, sectionTops.Count - 1, item));
            tops.Add(y);
            y += item == lensItem ? lensHeight : RowHeight;
        }

        tops.Add(y);
        Entries = entries;
        SectionTops = sectionTops;
        SectionCounts = sectionCounts;
        _tops = tops.ToArray();
        LensItem = lensItem;
        LensHeight = lensHeight;
    }

    /// <summary>从上到下的每一项。</summary>
    public IReadOnlyList<ClipListEntry> Entries { get; }

    /// <summary>各分组标题的 y。</summary>
    public IReadOnlyList<double> SectionTops { get; }

    /// <summary>各分组的条数（标题「今天 · 12」里的数）。</summary>
    public IReadOnlyList<int> SectionCounts { get; }

    public int LensItem { get; }

    public double LensHeight { get; }

    /// <summary>内容总高（不含四周内缩）。</summary>
    public double TotalHeight => _tops[^1];

    /// <summary>第 index 项的顶；index == Entries.Count 是总高。</summary>
    public double Top(int index) => _tops[index];

    public double Height(int index) => _tops[index + 1] - _tops[index];

    /// <summary>条目行的顶。</summary>
    public double RowTop(int item) => _tops[_rowEntry[item]];

    public double RowHeightOf(int item) => item == LensItem ? LensHeight : RowHeight;

    public int EntryOfItem(int item) => _rowEntry[item];

    /// <summary>
    /// 可见区 [offset, offset + viewport) 上下各多 overscan 时要实例化的项（二分找起点）。offset 是滚动位置（含上内缩）。
    /// </summary>
    public (int First, int End) Window(double offset, double viewport, double overscan = 320)
    {
        if (Entries.Count == 0)
        {
            return (0, 0);
        }

        var from = offset - Inset - overscan;
        var to = offset - Inset + viewport + overscan;
        var first = Math.Max(0, UpperBound(from) - 1);
        var end = first;
        while (end < Entries.Count && _tops[end] < to)
        {
            end++;
        }

        return (first, end);
    }

    /// <summary>
    /// 吸顶的分组标题：滚到 offset（含上内缩）时，顶上应该贴着哪一组的标题、它的 y（内容坐标，不含内缩）；
    /// 下一组的标题顶上来时把它往上推。还没滚过第一个标题时没有吸顶（返回 -1）。
    /// </summary>
    public (int Section, double Y) Sticky(double offset)
    {
        var top = offset - Inset;
        if (SectionTops.Count == 0 || top <= SectionTops[0])
        {
            return (-1, 0);
        }

        var section = 0;
        while (section + 1 < SectionTops.Count && SectionTops[section + 1] <= top)
        {
            section++;
        }

        var y = top;
        if (section + 1 < SectionTops.Count)
        {
            y = Math.Min(y, SectionTops[section + 1] - HeaderHeight);
        }

        return (section, y);
    }

    /// <summary>
    /// 跟随滚动（照 mac Shell/ListReveal）：条目被挡住时要滚到的位置；没被挡住返回 null。
    /// 往上：行顶对齐、让出吸顶标题；往下：行底对齐、留下内缩。
    /// </summary>
    public double? Reveal(int item, double offset, double viewport)
    {
        if (item < 0 || item >= _rowEntry.Length)
        {
            return null;
        }

        // 行的上面总要让出 24：不是本组第一条时那里贴着吸顶标题，是第一条时那里就是它自己的标题。
        var top = RowTop(item) + Inset - HeaderHeight;
        var bottom = RowTop(item) + Inset + RowHeightOf(item);
        if (top < offset)
        {
            return top <= Inset ? 0 : top;
        }

        if (bottom + Inset > offset + viewport)
        {
            return bottom + Inset - viewport;
        }

        return null;
    }

    /// <summary>第一个顶 &gt; value 的项。</summary>
    private int UpperBound(double value)
    {
        int low = 0, high = Entries.Count;
        while (low < high)
        {
            var mid = (low + high) / 2;
            if (_tops[mid] <= value)
            {
                low = mid + 1;
            }
            else
            {
                high = mid;
            }
        }

        return low;
    }
}
