// 浮层（剪贴板面板 / 启动器）的高度（纯函数，配单测）：高度随内容，最矮三行、最高八行、封顶 520 DIP。
// 数字要和两个面板的 XAML 结构对上：搜索框 56、上边距、行高（剪贴板 40 / 启动器 48）、底栏 36。
namespace KittyTools.Core;

public static class PanelMetrics
{
    public const int MinRows = 3;

    /// <summary>122 + 10 × 40 = 522，夹到 520：剪贴板最多能放到十行。</summary>
    public const int ClipboardMaxRows = 10;

    /// <summary>116 + 8 × 48 = 500：启动器八行就到顶了。</summary>
    public const int LauncherMaxRows = 8;

    public const double MaxHeightDip = 520;

    /// <summary>剪贴板面板：上边距 14 + 搜索 56 + 间距 8 + 列表 + 间距 8 + 底栏 36 + 下边距 0。</summary>
    public const double ClipboardChrome = 122;

    public const double ClipboardRowHeight = 40;

    /// <summary>启动器：上边距 12 + 搜索 56 + 间距 6 + 列表 + 间距 6 + 底栏 36。</summary>
    public const double LauncherChrome = 116;

    public const double LauncherRowHeight = 48;

    /// <summary>计算结果那一行更高：28 号数字 + 下面一行说明（REVIEW R7）。</summary>
    public const double LauncherCalculationRowHeight = 64;

    public static double ClipboardHeight(int rows)
        => Math.Clamp(
            ClipboardChrome + Math.Clamp(rows, MinRows, ClipboardMaxRows) * ClipboardRowHeight,
            ClipboardChrome + MinRows * ClipboardRowHeight,
            MaxHeightDip);

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
