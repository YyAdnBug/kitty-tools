// 剪贴板面板的高度（纯函数，配单测）：高度随内容，封顶 520 DIP。
// 启动器的高度在 LauncherListLayout（PLAN-v9-launcher 照 mac 改成前缀和）。
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
}
