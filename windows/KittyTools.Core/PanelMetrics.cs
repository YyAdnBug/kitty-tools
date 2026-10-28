// 浮层（剪贴板面板 / 启动器）的高度（纯函数，配单测）：高度随内容，最矮三行、最高八行、封顶 520 DIP。
// 数字要和两个面板的 XAML 结构对上：搜索框 56、上边距、行高（剪贴板 40 / 启动器 48）、底栏 36。
namespace KittyTools.Core;

public static class PanelMetrics
{
    public const int MinRows = 3;

    /// <summary>116 + 8 × 48 = 500：启动器八行就到顶了。</summary>
    public const int LauncherMaxRows = 8;

    public const double MaxHeightDip = 520;

    /// <summary>启动器：上边距 12 + 搜索 56 + 间距 6 + 列表 + 间距 6 + 底栏 36。</summary>
    public const double LauncherChrome = 116;

    public const double LauncherRowHeight = 40;

    /// <summary>计算结果那一行更高：28 号数字 + 下面一行说明（REVIEW R7）。</summary>
    public const double LauncherCalculationRowHeight = 64;

    /// <summary>
    /// 剪贴板透镜指令条（照 mac ClipboardPanelView.height）：搜索线 56（含发丝线）+ 列表区 + 底栏 36。
    /// 列表区 = min(上下内缩 12 + 24 × 分组数 + 40 × 行数 + 透镜预留 158, 428)，空列表 140；透镜预留是常数，
    /// 按 ↑↓ 改选中行时窗口不动，只有条数 / 分组数变了才改高度。关掉透镜时预留为 0。
    /// </summary>
    public const double ClipboardPanelChrome = 56 + 36;

    public const double ClipboardListMax = MaxHeightDip - ClipboardPanelChrome;

    public static double ClipboardHeightFor(int rows, int groups, bool reservesLens = true)
    {
        if (rows <= 0)
        {
            return ClipboardPanelChrome + 140;
        }

        var list = 2 * ClipListLayout.Inset + ClipListLayout.HeaderHeight * groups + ClipListLayout.RowHeight * rows +
                   (reservesLens ? ClipLens.Reserve : 0);
        return ClipboardPanelChrome + Math.Min(list, ClipboardListMax);
    }

    public static double LauncherHeight(int rows)
        => Math.Clamp(
            LauncherChrome + Math.Clamp(rows, MinRows, LauncherMaxRows) * LauncherRowHeight,
            LauncherChrome + MinRows * LauncherRowHeight,
            MaxHeightDip);

    /// <summary>
    /// 启动器按每行实际高度算（计算结果行 64、普通行 48）：取前八行，至少按三行普通行的高度算，
    /// 再封顶 520（REVIEW R7：结果行 28 号字会顶出 48 的行高）。
    /// </summary>
    public static double LauncherHeightFor(IReadOnlyList<double> rowHeights)
    {
        var visible = rowHeights.Take(LauncherMaxRows).Sum();
        var minimum = MinRows * LauncherRowHeight;
        return Math.Clamp(
            LauncherChrome + Math.Max(visible, minimum),
            LauncherChrome + minimum,
            MaxHeightDip);
    }
}
