// 设置页的「设置卡」和几个小零件（PLAN-v2 §3.4 / D4）：自己写，几十行，不引 CommunityToolkit。
// 一张卡的组成：标题 + 一行说明，右边是控件（开关 / 下拉 / 按钮）或一个箭头。卡上不放装饰图标、也不留图标位（同 mac 的
// 设置；用户 2026-10-28：有的有图标有的没有很怪）；只有列表里标明「这一项是谁」的才在最左边：功能开关的家族色块、
// 翻译服务的 logo（leading）。
// 子设置放在可以展开的卡里（Expand 参数）。全部颜色走主题资源，深浅色和高对比度自动跟着变。
using KittyTools.Ui;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static class SettingsUi
{
    /// <summary>
    /// 设置卡：（身份图标）+ 标题 + 说明 + 右边控件（control 为 null 时整张卡可点，右侧显示箭头）。
    /// problem：说明写的是配置问题（没找到书签文件、未填密钥），用橙字（配置问题的语义色）。
    /// </summary>
    public static Border Card(
        string title,
        string description,
        FrameworkElement? control = null,
        Action? onClick = null,
        bool enabled = true,
        FrameworkElement? leading = null,
        bool problem = false)
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
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                Foreground = problem ? Theme.Caution() : Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        // 没有身份图标时不建那一列：空列也会吃一份 ColumnSpacing，标题就缩进去了。
        var row = new Grid { ColumnSpacing = 14 };
        var column = 0;
        if (leading is not null)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            leading.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(leading, column++);
            row.Children.Add(leading);
        }

        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(text, column++);
        row.Children.Add(text);
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (control is not null)
        {
            Grid.SetColumn(control, column);
            row.Children.Add(control);
        }
        else if (onClick is not null)
        {
            var chevron = new FontIcon
            {
                Glyph = Glyphs.ChevronRight,
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
            };
            Grid.SetColumn(chevron, column);
            row.Children.Add(chevron);
        }

        var card = new Border
        {
            Style = Theme.Style("Kitty.CardStyle"),
            Child = row,
            IsHitTestVisible = enabled,
            Opacity = enabled ? 1 : 0.55,
        };
        if (onClick is not null)
        {
            // 只认左键：右键是卡上的菜单（翻译服务那几行）。
            card.PointerPressed += (_, e) =>
            {
                if (e.GetCurrentPoint(card).Properties.IsLeftButtonPressed)
                {
                    onClick();
                }
            };
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

    /// <summary>页头：一个家族色块 + 大标题 + 一句说明（PLAN-v7 §3.7）。glyph 是这一页自己的符号（和左栏同一个，同 mac PageHeader 的 page.symbol）。</summary>
    public static UIElement Header(string title, string subtitle, string? glyph = null)
    {
        var texts = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            texts.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = Theme.FontSize("Kitty.FontSize.Body"),
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Margin = new Thickness(2, 0, 2, 8),
        };
        row.Children.Add(KindTile.Create(FamilyOfPage(title), glyph ?? Glyphs.Settings, 32));
        row.Children.Add(texts);
        return row;
    }

    private static string FamilyOfPage(string title) => title switch
    {
        "快捷键" => "shortcut",
        "剪贴板" => "clipboard",
        "翻译" => "translate",
        "启动器" => "launcher",
        "截图" => "capture",
        _ => "general",
    };

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
            row.Children.Add(new TextBlock { Text = "未设置", Foreground = Theme.SecondaryText() });
            return row;
        }

        foreach (var key in shortcut.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            row.Children.Add(KeyCap.Create(key));
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
                Theme.Argb(40, 128, 128, 128)),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = label, FontSize = 10, Foreground = brush },
        };
    }
}
