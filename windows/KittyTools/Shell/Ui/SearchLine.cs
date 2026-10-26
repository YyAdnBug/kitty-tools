// 搜索线（PLAN-v7 §2.2 / §3.1）：高 56、左右 18，17 号放大镜 + 20 号无边框输入框，
// 下面一条 hairline；标签胶囊插在放大镜和输入框之间（U2）。
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

public sealed partial class SearchLine : Grid
{
    public SearchLine()
        : this("搜索…")
    {
    }

    public SearchLine(string placeholder)
    {
        Height = 56;
        Padding = new Thickness(18, 0, 18, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var icon = new FontIcon
        {
            Glyph = Glyphs.Search,
            FontSize = 17,
            Foreground = Theme.Brush("TextFillColorTertiaryBrush", Color.FromArgb(255, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
            Width = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        SetColumn(icon, 0);
        Children.Add(icon);

        Chips = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        SetColumn(Chips, 1);
        Children.Add(Chips);

        Box = new TextBox
        {
            PlaceholderText = placeholder,
            Style = Theme.Style("Kitty.InputStyle"),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            FontSize = Theme.FontSize("Kitty.FontSize.Search"),
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            SelectionHighlightColor = new SolidColorBrush(Color.FromArgb(
                71, Theme.AccentColor.R, Theme.AccentColor.G, Theme.AccentColor.B)),
        };
        AutomationProperties.SetName(Box, placeholder);
        foreach (var key in new[]
                 {
                     "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                     "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused",
                     "TextControlElevationBorderFocusedBrush",
                 })
        {
            Box.Resources[key] = new SolidColorBrush(Colors.Transparent);
        }

        SetColumn(Box, 2);
        Children.Add(Box);

        var hairline = new Border
        {
            Height = 1,
            Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        SetColumnSpan(hairline, 3);
        Children.Add(hairline);
    }

    public TextBox Box { get; }

    public StackPanel Chips { get; }

    /// <summary>把焦点放进输入框（面板打开时用）。</summary>
    public void FocusBox() => Box.Focus(FocusState.Programmatic);

    /// <summary>U2 的筛选标签：高 22、12 semibold、强调色 0.12 底 + AccentText 字，带 ×。</summary>
    public Border AddChip(string text, Action? onRemove = null)
    {
        var accent = Theme.AccentColor;
        var border = new Border
        {
            Height = 22,
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(8, 0, 6, 0),
            Background = new SolidColorBrush(Color.FromArgb(31, accent.R, accent.G, accent.B)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Theme.AccentTextColor),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (onRemove is not null)
        {
            var close = new Button
            {
                Content = new FontIcon { Glyph = Glyphs.Close, FontSize = 9 },
                Width = 16,
                Height = 16,
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Theme.AccentTextColor),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(close, $"移除 {text}");
            close.Click += (_, _) => onRemove();
            row.Children.Add(close);
        }

        border.Child = row;
        Chips.Children.Add(border);
        return border;
    }
}
