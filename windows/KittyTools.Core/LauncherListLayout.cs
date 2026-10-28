// 启动器列表的前缀和布局（纯函数，配单测；照 mac LauncherPanelView.offset / span / height）：
// 列表四周内缩 6，分组标题 28 排在它那一组第一行的前面，普通行 40、计算卡 64；
// 面板高度 = 搜索线 56（含发丝线）+ 列表（上下内缩 + 28 × 分组数 + 最多 8.5 行）+ 底栏 36，
// 没有结果时一行字 52（空查询什么都没有时连这行字都没有）；Ctrl+K 菜单开着时至少放得下菜单。
namespace KittyTools.Core;

public sealed class LauncherListLayout
{
    public const double Inset = 6;
    public const double GroupHeight = 28;
    public const double RowHeight = 40;
    public const double CalculationHeight = 64;
    public const double SearchHeight = 56;
    public const double BarHeight = 36;

    /// <summary>没有结果时那一行字（mac rowHeight + 12）。</summary>
    public const double EmptyHeight = RowHeight + 12;

    /// <summary>多露出半行，让人看得出下面还能滚。</summary>
    public const double VisibleRows = 8.5;

    private readonly double[] _heights;
    private readonly double[] _tops;
    private readonly HashSet<int> _groupStarts;

    /// <param name="rowHeights">每一行的高（40 / 64）。</param>
    /// <param name="groupRows">每个分组标题排在第几行前面（升序，可以是 0）。</param>
    public LauncherListLayout(IReadOnlyList<double> rowHeights, IReadOnlyList<int> groupRows)
    {
        _heights = rowHeights.ToArray();
        _groupStarts = groupRows.Where(row => row >= 0 && row < _heights.Length).ToHashSet();
        GroupRows = groupRows.Where(row => row >= 0 && row < _heights.Length).Distinct().OrderBy(row => row).ToArray();
        _tops = new double[_heights.Length];
        var y = 0.0;
        for (var row = 0; row < _heights.Length; row++)
        {
            if (_groupStarts.Contains(row))
            {
                y += GroupHeight;
            }

            _tops[row] = y;
            y += _heights[row];
        }

        TotalHeight = y;
    }

    public static double HeightOf(LauncherKind kind) => kind == LauncherKind.Calculation ? CalculationHeight : RowHeight;

    public int Count => _heights.Length;

    /// <summary>分组标题排在哪几行前面（去重、升序、只留有行的）。</summary>
    public IReadOnlyList<int> GroupRows { get; }

    /// <summary>所有行和分组标题叠起来的高（不含四周内缩）。</summary>
    public double TotalHeight { get; }

    /// <summary>第 row 行的顶（内容坐标，不含内缩）。</summary>
    public double Top(int row) => row >= 0 && row < _tops.Length ? _tops[row] : TotalHeight;

    public double Height(int row) => row >= 0 && row < _heights.Length ? _heights[row] : 0;

    /// <summary>某个分组标题的顶（排在 row 前面的那一个）。</summary>
    public double GroupTop(int row) => Top(row) - GroupHeight;

    public bool StartsGroup(int row) => _groupStarts.Contains(row);

    /// <summary>
    /// 选中跟随滚动（mac span + ListReveal）：要露出第 row 行（它是一组第一行时连分组标题一起），上下各留一格内缩。
    /// 返回新的滚动位置；已经露全了返回 null。
    /// </summary>
    public double? Reveal(int row, double offset, double viewport)
    {
        if (row < 0 || row >= _heights.Length)
        {
            return null;
        }

        var top = Inset + Top(row) - (StartsGroup(row) ? GroupHeight : 0);
        var bottom = Inset + Top(row) + Height(row);
        if (top - Inset < offset)
        {
            return Math.Max(0, top - Inset);
        }

        if (bottom + Inset > offset + viewport)
        {
            return bottom + Inset - viewport;
        }

        return null;
    }

    /// <summary>列表区的高：上下内缩 + 分组标题 + 最多 8.5 行（多的那半行按第 9 行的一半算）。</summary>
    public static double ListHeight(IReadOnlyList<double> rowHeights, int groups)
    {
        if (rowHeights.Count == 0)
        {
            return 0;
        }

        var full = (int)VisibleRows;
        var rows = rowHeights.Take(full).Sum();
        if (rowHeights.Count > full)
        {
            rows += rowHeights[full] / 2;
        }

        return 2 * Inset + groups * GroupHeight + rows;
    }

    /// <summary>
    /// 面板高度（mac height(for:)）：showsEmpty = 有查询却没有结果（显示一行字）；menuHeight = Ctrl+K 菜单的高（没开是 0），
    /// 菜单锚在底栏上方 4、离搜索线至少 8。
    /// </summary>
    public static double PanelHeight(IReadOnlyList<double> rowHeights, int groups, bool showsEmpty, double menuHeight = 0)
    {
        var height = SearchHeight + BarHeight;
        if (showsEmpty)
        {
            height += EmptyHeight;
        }
        else
        {
            height += ListHeight(rowHeights, groups);
        }

        if (menuHeight > 0)
        {
            height = Math.Max(height, SearchHeight + 8 + menuHeight + 4 + BarHeight);
        }

        return height;
    }
}
