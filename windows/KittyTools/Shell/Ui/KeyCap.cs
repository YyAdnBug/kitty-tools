// PLAN-v7 §2.2 的共用部件：按刻度从 Styles.xaml 取样式，代码里不再 new 画刷 / 写字面量。
// 一个部件一个文件；这里只放不依赖具体界面的小工厂。
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal static class KeyCap
{
    public static Border Create(string text, bool primary = false, bool danger = false)
    {
        var border = new Border
        {
            Style = Theme.Style(primary ? "Kitty.KeyCap.Primary" : "Kitty.KeyCap"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (danger)
        {
            border.Background = Theme.Brush("Kitty.Danger", Color.FromArgb(255, 196, 43, 28));
        }

        // 危险色实心键帽上的符号用 OnDanger（浅深都是白，高对比度换成窗口底色）。
        var foreground = primary
            ? new SolidColorBrush(Theme.OnAccentColor)
            : danger
                ? Theme.Brush("Kitty.OnDanger", Color.FromArgb(255, 255, 255, 255))
                : Theme.Brush("TextFillColorPrimaryBrush", Color.FromArgb(255, 32, 32, 32));
        border.Child = new TextBlock
        {
            Text = text,
            FontSize = Theme.FontSize("Kitty.FontSize.KeyCap"),
            FontWeight = FontWeights.SemiBold,
            Foreground = foreground,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return border;
    }

    /// <summary>组合键：每个键一个键帽，间距 3。</summary>
    public static StackPanel Combo(IEnumerable<string> keys, bool primary = false)
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 3,
            VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var key in keys)
        {
            panel.Children.Add(Create(key, primary));
        }

        return panel;
    }
}
