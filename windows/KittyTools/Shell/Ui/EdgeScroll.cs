// 滚动条贴外边（2026-11-17 用户：滚动条统一在外部容器）：放在有内边距的容器里（对话框的内容区、卡片、带 Padding 的窗口根）的
// ScrollViewer，默认把滚动条画在内边距里面一层，展开时还压着最右边的字（速查表的键帽被盖掉一截）。
// 这里把它往右撑到容器边上：右边距减掉那条内边距、内容再往里缩回同样多，字还在原处，滚动条落在外边那条空里。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools.Ui;

internal static class EdgeScroll
{
    /// <summary>ContentDialog 内容区四周的内边距（系统资源 ContentDialogPadding）。</summary>
    public const double DialogPadding = 24;

    /// <summary>把 <paramref name="scroll"/> 撑到外层容器的右边：<paramref name="gutter"/> 是外层右边的内边距。</summary>
    public static ScrollViewer ToRightEdge(ScrollViewer scroll, double gutter = DialogPadding)
    {
        var margin = scroll.Margin;
        scroll.Margin = new Thickness(margin.Left, margin.Top, margin.Right - gutter, margin.Bottom);
        var padding = scroll.Padding;
        scroll.Padding = new Thickness(padding.Left, padding.Top, padding.Right + gutter, padding.Bottom);
        return scroll;
    }
}
