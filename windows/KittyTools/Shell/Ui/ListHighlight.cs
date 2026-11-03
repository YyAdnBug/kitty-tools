// 列表的滑动高亮（PLAN-v7 §2.2）：一块会移动的 Kitty.Fill.Selected，圆角 4。
// 位置和高度由调用方按前缀和 / 行高算好传进来；键盘移动用 Snap，鼠标点选 / 透镜展开用弹簧。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools.Ui;

internal sealed partial class ListHighlight : Grid
{
    private readonly Border _fill;

    public ListHighlight()
    {
        Height = LauncherListLayout.RowHeight;
        IsHitTestVisible = false;
        Visibility = Visibility.Collapsed;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Top;
        _fill = new Border
        {
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Fill.Selected", Theme.Argb(0x12, 0, 0, 0)),
        };
        Children.Add(_fill);
    }

    /// <summary>瞬时摆到某一行（键盘连发、换列表）。</summary>
    public void SnapTo(double top, double height)
    {
        Height = height;
        Margin = new Thickness(0, top, 0, 0);
        Visibility = Visibility.Visible;
    }
}
