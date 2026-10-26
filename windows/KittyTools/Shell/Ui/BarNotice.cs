// 底栏左边的就地提示（PLAN-v7 §2.2）：成功是绿色圆底白勾 + secondary 字；「撤销」用 AccentText。
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal static class BarNotice
{
    public static StackPanel Create(string text, string? actionText = null, Action? action = null, bool success = true)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (success)
        {
            var badge = new Border
            {
                Width = 14,
                Height = 14,
                CornerRadius = new CornerRadius(7),
                Background = Theme.Brush("SystemFillColorSuccessBrush", Color.FromArgb(255, 15, 123, 15)),
                Child = new FontIcon
                {
                    Glyph = Glyphs.Check,
                    FontSize = 8,
                    Foreground = new SolidColorBrush(Colors.White),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            row.Children.Add(badge);
        }

        row.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.Brush("TextFillColorSecondaryBrush", Color.FromArgb(255, 96, 96, 96)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (!string.IsNullOrWhiteSpace(actionText) && action is not null)
        {
            var button = new Button
            {
                Content = new TextBlock
                {
                    Text = actionText,
                    FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                    Foreground = new SolidColorBrush(Theme.AccentTextColor),
                },
                Padding = new Thickness(2, 0, 2, 0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(button, actionText);
            button.Click += (_, _) => action();
            row.Children.Add(button);
        }

        return row;
    }
}
