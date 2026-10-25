// 设置页的「设置卡」和几个小零件（PLAN-v2 §3.4 / D4）：自己写，几十行，不引 CommunityToolkit。
// 一张卡的组成：左边 36×36 的图标块 + 标题 + 一行说明，右边是控件（开关 / 下拉 / 按钮）或一个箭头。
// 子设置放在可以展开的卡里（Expand 参数）。全部颜色走主题资源，深浅色和高对比度自动跟着变。
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static class SettingsUi
{
    /// <summary>设置卡：图标 + 标题 + 说明 + 右边控件（control 为 null 时整张卡可点，右侧显示箭头）。</summary>
    public static Border Card(
        string glyph,
        string title,
        string description,
        FrameworkElement? control = null,
        Action? onClick = null,
        bool enabled = true)
    {
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(description))
        {
            text.Children.Add(new TextBlock
            {
                Text = description,
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var row = new Grid { ColumnSpacing = 14 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        FrameworkElement icon;
        if (string.IsNullOrEmpty(glyph))
        {
            icon = new Border { Width = 36, Height = 36 };
        }
        else
        {
            icon = new Border
            {
                Width = 36,
                Height = 36,
                CornerRadius = new CornerRadius(8),
                Background = Theme.Family.Tint(Theme.Family.Clipboard, 24),
                Child = new FontIcon
                {
                    Glyph = glyph,
                    FontSize = 16,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
        }

        Grid.SetColumn(icon, 0);
        row.Children.Add(icon);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);

        if (control is not null)
        {
            Grid.SetColumn(control, 2);
            row.Children.Add(control);
        }
        else if (onClick is not null)
        {
            var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 12, Opacity = 0.6 };
            Grid.SetColumn(chevron, 2);
            row.Children.Add(chevron);
        }

        var card = new Border
        {
            Padding = new Thickness(16, 12, 16, 12),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground(),
            Child = row,
            IsHitTestVisible = enabled,
            Opacity = enabled ? 1 : 0.55,
        };
        if (onClick is not null)
        {
            card.PointerPressed += (_, _) => onClick();
        }

        AutomationProperties.SetName(card, description.Length > 0 ? $"{title}，{description}" : title);
        return card;
    }

    /// <summary>左右并排的小开关（用于卡片右侧）。</summary>
    public static ToggleSwitch Toggle(bool value, Action<bool> changed, string automationName)
    {
        var toggle = new ToggleSwitch
        {
            IsOn = value,
            OnContent = string.Empty,
            OffContent = string.Empty,
            MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        AutomationProperties.SetName(toggle, automationName);
        return toggle;
    }

    /// <summary>卡片右侧的下拉框。</summary>
    public static ComboBox Combo(string[] items, int selected, Action<int> changed, string automationName)
    {
        var combo = new ComboBox
        {
            SelectedIndex = Math.Clamp(selected, 0, Math.Max(0, items.Length - 1)),
            MinWidth = 150,
            VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var item in items)
        {
            combo.Items.Add(item);
        }

        combo.SelectionChanged += (_, _) => changed(combo.SelectedIndex);
        AutomationProperties.SetName(combo, automationName);
        return combo;
    }

    /// <summary>分组标题（一大组设置卡上面那行）。</summary>
    public static UIElement Section(string title, string? subtitle = null)
    {
        var panel = new StackPanel { Spacing = 2, Margin = new Thickness(2, 10, 2, 2) };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 14 });
        if (!string.IsNullOrEmpty(subtitle))
        {
            panel.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        return panel;
    }

    /// <summary>页头：一个大标题 + 一句说明（Windows 11 设置的样子）。</summary>
    public static UIElement Header(string title, string subtitle)
    {
        var panel = new StackPanel { Spacing = 4, Margin = new Thickness(2, 0, 2, 8) };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            panel.Children.Add(new TextBlock
            {
                Text = subtitle,
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        return panel;
    }

    /// <summary>一个键一个键帽（快捷键页用）：强调色底的小方块。</summary>
    public static UIElement KeyCaps(string shortcut)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (string.IsNullOrEmpty(shortcut) || shortcut == "未设置")
        {
            row.Children.Add(new TextBlock { Text = "未设置", Opacity = 0.6 });
            return row;
        }

        foreach (var key in shortcut.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var cap = new Border
            {
                MinWidth = 22,
                Height = 22,
                Padding = new Thickness(6, 0, 6, 0),
                CornerRadius = new CornerRadius(5),
                Background = Theme.Brush(
                    "AccentFillColorDefaultBrush", Theme.BrandPink),
                Child = new TextBlock
                {
                    Text = key,
                    FontSize = 11,
                    FontFamily = new FontFamily("Segoe UI"),
                    Foreground = Theme.Brush(
                        "TextOnAccentFillColorPrimaryBrush",
                        Windows.UI.Color.FromArgb(255, 255, 255, 255)),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            row.Children.Add(cap);
        }

        return row;
    }

    /// <summary>更新日志条目前的类型标签（feat / fix / perf / ui）。</summary>
    public static Border TypeTag(string? type)
    {
        var (label, brush) = type switch
        {
            "feat" => ("新", Theme.Success()),
            "fix" => ("修", Theme.Critical()),
            "perf" => ("快", Theme.Brush("SystemFillColorCautionBrush", Theme.BrandPink)),
            "ui" => ("界面", Theme.Family.Tint(Theme.Family.Launcher, 40)),
            _ => ("", Theme.SecondaryText()),
        };
        return new Border
        {
            Padding = new Thickness(6, 1, 6, 1),
            CornerRadius = new CornerRadius(4),
            Background = Theme.Brush(
                "ControlFillColorSecondaryBrush",
                Windows.UI.Color.FromArgb(40, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = label, FontSize = 10, Foreground = brush },
        };
    }
}
