// 剪贴板面板的高度（纯函数，配单测）：高度随内容，封顶 520 DIP。
// 启动器的高度在 LauncherListLayout（PLAN-v9-launcher 照 mac 改成前缀和）。
// 拖边改大小（PLAN-v14 V10，照 mac PanelSizeTests）：宽 560–1200，最多几行 6.5–14.5、按半行吸附，默认 8.5 行就是原来的 428。
namespace KittyTools.Core;

public static class PanelMetrics
{
    public const double MaxHeightDip = 520;

    /// <summary>
    /// 剪贴板透镜指令条（照 mac ClipboardPanelView.height）：搜索线 56（含发丝线）+ 列表区 + 底栏 36。
    /// 列表区 = min(上下内缩 12 + 24 × 分组数 + 40 × 行数 + 透镜预留 158, 428)，空列表 140；透镜预留是常数，
    /// 按 ↑↓ 改选中行时窗口不动，只有条数 / 分组数变了才改高度。关掉透镜时预留为 0。
    /// </summary>
    public const double ClipboardPanelChrome = 56 + 36;

    public const double ClipboardListMax = MaxHeightDip - ClipboardPanelChrome;

    /// <summary>启动器、剪贴板拖左右边能拖到多宽（mac Style.listPanelWidths），默认 720。</summary>
    public const double MinPanelWidth = 560;

    public const double MaxPanelWidth = 1200;

    public const double DefaultPanelWidth = 720;

    /// <summary>拖下边能定的行数（mac rowRange）：默认 8.5，按半行吸附。</summary>
    public const double MinRows = 6.5;

    public const double MaxRows = 14.5;

    public const double DefaultRows = 8.5;

    /// <summary>列表区最高多高：拖出来的行数（null / 0 = 默认）每多一行加一行高。</summary>
    public static double ClipboardListMaxFor(double? rows)
        => rows is > 0 ? ClipboardListMax + (rows.Value - DefaultRows) * ClipListLayout.RowHeight : ClipboardListMax;

    public static double ClipboardHeightFor(int rows, int groups, bool reservesLens = true, double? maxRows = null)
    {
        if (rows <= 0)
        {
            return ClipboardPanelChrome + 140;
        }

        var list = 2 * ClipListLayout.Inset + ClipListLayout.HeaderHeight * groups + ClipListLayout.RowHeight * rows +
                   (reservesLens ? ClipLens.Reserve : 0);
        return ClipboardPanelChrome + Math.Min(list, ClipboardListMaxFor(maxRows));
    }

    /// <summary>对话框开着时给满：搜索线 + 最高的列表区 + 底栏。</summary>
    public static double ClipboardMaxHeight(double? rows) => ClipboardPanelChrome + ClipboardListMaxFor(rows);

    /// <summary>拖下边时剪贴板面板能多高：列表区 6.5 到 14.5 行。</summary>
    public static (double Min, double Max) ClipboardHeightRange()
        => (ClipboardMaxHeight(MinRows), ClipboardMaxHeight(MaxRows));

    /// <summary>拖到这么高对应最多几行：按半行吸附，夹在 6.5–14.5 里（mac rows(forHeight:)）。</summary>
    public static double ClipboardRowsFor(double height)
        => SnapRows(DefaultRows + (height - ClipboardPanelChrome - ClipboardListMax) / ClipListLayout.RowHeight);

    /// <summary>行数吸到最近的 x.5、夹在范围里（Swift 的 rounded() 是四舍五入，不是银行家舍入）。</summary>
    public static double SnapRows(double rows)
        => Math.Clamp(Math.Round(rows - 0.5, MidpointRounding.AwayFromZero) + 0.5, MinRows, MaxRows);

    /// <summary>记着的行数：没记过 / 不在范围里的当默认（null）。</summary>
    public static double? StoredRows(double? rows) => rows is >= MinRows and <= MaxRows ? rows : null;

    /// <summary>记着的宽：夹在 560–1200 和这块屏工作区的宽里；没记过是默认 720（也不超过工作区）。</summary>
    public static double PanelWidth(double? stored, double workWidth)
        => Math.Min(Math.Clamp(stored ?? DefaultPanelWidth, MinPanelWidth, MaxPanelWidth), Math.Max(workWidth, 1));
}
