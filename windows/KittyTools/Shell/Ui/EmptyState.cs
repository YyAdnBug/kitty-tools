// 空状态（PLAN-v7 §2.2）：符号 28、标题 14 semibold、说明 12，间距 8。
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal static class EmptyState
{
    public static StackPanel Create(string glyph, string title, string detail)
    {
        var panel = new StackPanel
        {
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(24),
        };
        panel.Children.Add(new FontIcon
        {
            Glyph = glyph,
            FontSize = 28,
            Foreground = Theme.TertiaryText(),
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = Theme.FontSize("Kitty.FontSize.RowTitle"),
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        });
        if (!string.IsNullOrWhiteSpace(detail))
        {
            panel.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                Foreground = Theme.Brush("TextFillColorSecondaryBrush", Color.FromArgb(255, 96, 96, 96)),
                HorizontalAlignment = HorizontalAlignment.Center,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        AutomationProperties.SetName(panel, $"{title}，{detail}");
        return panel;
    }
}
