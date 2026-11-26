// 设置页的「设置卡」和几个小零件（PLAN-v2 §3.4 / D4）：自己写，几十行，不引 CommunityToolkit。
// 一张卡的组成：标题 + 一行说明，右边是控件（开关 / 下拉 / 按钮）或一个箭头。卡上不放装饰图标、也不留图标位（同 mac 的
// 设置；用户 2026-10-28：有的有图标有的没有很怪）；只有列表里标明「这一项是谁」的才在最左边：功能开关的家族色块、
// 翻译服务的 logo（leading）。
// 子设置放在可以展开的卡里（Expand 参数）。全部颜色走主题资源，深浅色和高对比度自动跟着变。
using System.Runtime.CompilerServices;
using KittyTools.Ui;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static class SettingsUi
{
    /// <summary>
    /// 设置卡：（身份图标）+ 标题 + 说明 + 右边控件（control 为 null 时整张卡可点，右侧显示箭头）。
    /// problem：说明写的是配置问题（没找到书签文件、未填密钥），用橙字（配置问题的语义色）。
    /// tag：标题后面的一枚小标签（翻译服务行的「免费」，PLAN-v22 F3），读屏跟着标题读。
    /// </summary>
    public static Border Card(
        string title,
        string description,
        FrameworkElement? control = null,
        Action? onClick = null,
        bool enabled = true,
        FrameworkElement? leading = null,
        bool problem = false,
        string? tag = null)
    {
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Name = CardTextName };
        var heading = new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        };
        if (tag is null)
        {
            text.Children.Add(heading);
        }
        else
        {
            var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            titleRow.Children.Add(heading);
            titleRow.Children.Add(Tag(tag));
            text.Children.Add(titleRow);
            title = $"{title}（{tag}）";
        }
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
            // Tapped（按下再松开、中间没拖动）：拖动排序的列表里按住卡拖走时不算点（以前用 PointerPressed，一按就打开了）；
            // 右键是卡上的菜单（RightTapped，不触发这里）。点在卡上的开关、按钮上时（Tapped 会冒泡上来）也不算点卡。
            card.Tapped += (_, e) =>
            {
                for (var node = e.OriginalSource as DependencyObject;
                     node is not null && !ReferenceEquals(node, card);
                     node = VisualTreeHelper.GetParent(node))
                {
                    if (node is Control)
                    {
                        return;
                    }
                }

                onClick();
            };
            Clicks.AddOrUpdate(card, onClick);
        }

        AutomationProperties.SetName(card, description.Length > 0 ? $"{title}，{description}" : title);
        Groupable.AddOrUpdate(card, new CardLayout(card.Margin, card.Padding));
        return card;
    }

    private const string CardTextName = "KittyCardText";

    /// <summary>可点的卡点了做什么、右键菜单里各项做什么（列表的键盘操作要用，PLAN-v23 L1）。</summary>
    private static readonly ConditionalWeakTable<Border, Action> Clicks = new();

    /// <summary>Card() 建的卡：GroupCards 只连这些（别的 Border 不动）。值是卡原来的边距和内边距。</summary>
    private static readonly ConditionalWeakTable<Border, CardLayout> Groupable = new();

    /// <summary>子设置那一行（「也搜浏览历史」这种跟着上一行的）：连在组里时内容往里缩一档。</summary>
    private static readonly ConditionalWeakTable<Border, object> ChildRows = new();

    private sealed record CardLayout(Thickness Margin, Thickness Padding)
    {
        public bool Watched { get; set; }
    }

    /// <summary>标成上一行的子设置（mac 里缩进的那行）：连成一组时左边多缩 28，不再单独一张往里挪的卡。</summary>
    public static void MarkChild(Border card) => ChildRows.AddOrUpdate(card, new object());

    /// <summary>
    /// 相邻的设置卡连成一块（mac 设置的分组表单：一节一个圆角框、行和行之间一条细线；2026-11-17 用户：
    /// 「在 mac 上是一整块区域，windows 是分开的」）。分组标题、脚注、空隙这些不是卡的东西把它们隔开；
    /// 收起的不算、也不隔开。卡的显隐变了（子设置跟着开关露出来）就重连一遍。
    /// spacing 是 content 的 Spacing：连着的卡往上挪这么多贴住上一张。
    /// </summary>
    public static void GroupCards(Panel content, double spacing)
    {
        var radius = Theme.Corner("Kitty.Corner.Card").TopLeft;
        var run = new List<Border>();

        void Flush()
        {
            for (var index = 0; index < run.Count; index++)
            {
                var card = run[index];
                var layout = Groupable.TryGetValue(card, out var found) ? found : null;
                if (layout is null)
                {
                    continue;
                }

                var first = index == 0;
                var last = index == run.Count - 1;
                card.CornerRadius = new CornerRadius(first ? radius : 0, first ? radius : 0, last ? radius : 0, last ? radius : 0);
                // 上一张的下边线就是两行之间那条细线：不是第一张的去掉上边线，免得叠成两像素
                card.BorderThickness = new Thickness(1, first ? 1 : 0, 1, 1);
                card.Margin = new Thickness(layout.Margin.Left, first ? layout.Margin.Top : -spacing, layout.Margin.Right, layout.Margin.Bottom);
                var indent = ChildRows.TryGetValue(card, out _) ? 28 : 0;
                card.Padding = new Thickness(layout.Padding.Left + indent, layout.Padding.Top, layout.Padding.Right, layout.Padding.Bottom);
            }

            run.Clear();
        }

        foreach (var child in content.Children)
        {
            if (child.Visibility == Visibility.Collapsed)
            {
                continue;
            }

            if (child is Border card && Groupable.TryGetValue(card, out var layout))
            {
                run.Add(card);
                if (!layout.Watched)
                {
                    layout.Watched = true;
                    card.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => GroupCards(content, spacing));
                }
            }
            else
            {
                Flush();
            }
        }

        Flush();

        // 收起的卡回到单独一张的样子（再露出来时重连会改）
        foreach (var child in content.Children)
        {
            if (child.Visibility == Visibility.Collapsed && child is Border card && Groupable.TryGetValue(card, out var layout))
            {
                card.CornerRadius = new CornerRadius(radius);
                card.BorderThickness = new Thickness(1);
                card.Margin = layout.Margin;
                card.Padding = layout.Padding;
            }
        }
    }

    private static readonly ConditionalWeakTable<Border, Dictionary<string, Action>> MenuActions = new();

    /// <summary>记下卡上右键菜单的一项（灰着的不记）；名字去掉末尾的「…」（「删除…」「删除」都记成「删除」）。</summary>
    public static void RememberAction(Border card, string text, bool enabled, Action action)
    {
        if (enabled)
        {
            MenuActions.GetOrCreateValue(card)[text.TrimEnd('…')] = action;
        }
    }

    /// <summary>做卡上右键菜单里的那一项（没有、灰着的返回 false）。</summary>
    public static bool RunAction(Border card, string text)
    {
        if (!MenuActions.TryGetValue(card, out var actions) || !actions.TryGetValue(text, out var action))
        {
            return false;
        }

        action();
        return true;
    }

    /// <summary>点这张卡（同鼠标点它；不可点的返回 false）。</summary>
    public static bool Open(Border card)
    {
        if (!Clicks.TryGetValue(card, out var action) || !card.IsHitTestVisible)
        {
            return false;
        }

        action();
        return true;
    }

    /// <summary>一张 <see cref="Card"/> 的标题和说明（设置搜索落到哪一行用，PLAN-v26 G1）；不是卡片是 null。</summary>
    public static (string Title, string Detail)? TextOf(Border card)
    {
        if (card.Child is not Grid row ||
            row.Children.OfType<StackPanel>().FirstOrDefault(panel => panel.Name == CardTextName) is not { } text)
        {
            return null;
        }

        var parts = text.Children.Count > 0 && text.Children[0] is StackPanel titleRow
            ? titleRow.Children.OfType<TextBlock>().Select(block => block.Text)
            : text.Children.OfType<TextBlock>().Take(1).Select(block => block.Text);
        var detail = text.Children.OfType<TextBlock>().Skip(text.Children[0] is TextBlock ? 1 : 0).FirstOrDefault()?.Text ?? string.Empty;
        return (string.Join(" ", parts), detail);
    }

    /// <summary>
    /// 原地改一张 <see cref="Card"/> 的说明（空 = 收起那一行）。开关旁边的说明、下面那一行要跟着变时用它，
    /// 别整页重建：重建时整页的开关都换成新建的，看着每个都闪一下（2026-10-29 用户反馈）。
    /// </summary>
    public static void SetDescription(Border card, string description, bool problem = false)
    {
        if (card.Child is not Grid row ||
            row.Children.OfType<StackPanel>().FirstOrDefault(panel => panel.Name == CardTextName) is not { } text)
        {
            return;
        }

        var label = text.Children.Count > 1 ? text.Children[1] as TextBlock : null;
        if (string.IsNullOrEmpty(description))
        {
            if (label is not null)
            {
                label.Visibility = Visibility.Collapsed;
            }

            return;
        }

        if (label is null)
        {
            label = new TextBlock
            {
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                TextWrapping = TextWrapping.Wrap,
            };
            text.Children.Add(label);
        }

        label.Text = description;
        label.Foreground = problem ? Theme.Caution() : Theme.SecondaryText();
        label.Visibility = Visibility.Visible;
    }

    /// <summary>一张 <see cref="Card"/> 此刻的说明（收起了是空串）。</summary>
    public static string DescriptionOf(Border card)
        => card.Child is Grid row &&
           row.Children.OfType<StackPanel>().FirstOrDefault(panel => panel.Name == CardTextName) is { } text &&
           text.Children.Count > 1 && text.Children[1] is TextBlock { Visibility: Visibility.Visible } label
            ? label.Text
            : string.Empty;

    /// <summary>原地改一张 <see cref="Card"/> 能不能点（和 Card 的 enabled 参数同一套：0.55 透明、不接点击）。</summary>
    public static void SetEnabled(Border card, bool enabled)
    {
        card.IsHitTestVisible = enabled;
        card.Opacity = enabled ? 1 : 0.55;
    }

    /// <summary>标题后面的小标签（翻译服务行的「免费」）：和翻译浮窗目标语言上的「自动」同一个样子（强调色 0.16 底、强调色字、10 号半粗）。</summary>
    public static Border Tag(string text)
    {
        var accent = Theme.AccentColor;
        return new Border
        {
            Padding = new Thickness(4, 1, 4, 1),
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Theme.Argb(41, accent.R, accent.G, accent.B)),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = text,
                FontSize = 10,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Theme.AccentTextColor),
            },
        };
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

    /// <summary>
    /// 卡片右侧的分段按钮（mac .pickerStyle(.segmented)：2–3 个短选项，2026-11-17 用户「mac 上是按钮选择」）。
    /// WinUI 没有分段控件：一排 ToggleButton 放在浅底圆角槽里，选中那个是强调色底（ToggleButton 自己的选中态），
    /// 点已选中的不取消；←→ 换选项。读屏按「名字：选项」读每一个，选没选中读开关状态。
    /// </summary>
    public static FrameworkElement Segmented(string[] items, int selected, Action<int> changed, string automationName)
    {
        var buttons = new List<ToggleButton>();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        var current = Math.Clamp(selected, 0, Math.Max(0, items.Length - 1));

        void Select(int index, bool notify)
        {
            for (var i = 0; i < buttons.Count; i++)
            {
                buttons[i].IsChecked = i == index;
            }

            if (notify && index != current)
            {
                current = index;
                changed(index);
            }

            current = index;
        }

        for (var index = 0; index < items.Length; index++)
        {
            var at = index;
            var button = new ToggleButton
            {
                Content = items[index],
                MinWidth = 56,
                Padding = new Thickness(12, 4, 12, 5),
                BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            };
            button.Click += (_, _) => Select(at, notify: true);
            button.KeyDown += (_, args) =>
            {
                var step = args.Key switch
                {
                    Windows.System.VirtualKey.Left => -1,
                    Windows.System.VirtualKey.Right => 1,
                    _ => 0,
                };
                if (step != 0 && at + step >= 0 && at + step < buttons.Count)
                {
                    args.Handled = true;
                    Select(at + step, notify: true);
                    buttons[at + step].Focus(FocusState.Keyboard);
                }
            };
            AutomationProperties.SetName(button, $"{automationName}：{items[index]}");
            buttons.Add(button);
            row.Children.Add(button);
        }

        Select(current, notify: false);
        var slot = new Border
        {
            Child = row,
            Padding = new Thickness(2),
            CornerRadius = Theme.Corner("Kitty.Corner.Control"),
            Background = Theme.Brush("Kitty.Fill.Control", Windows.UI.Color.FromArgb(15, 0, 0, 0)),
            BorderBrush = Theme.Brush("Kitty.Hairline", Windows.UI.Color.FromArgb(20, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        AutomationProperties.SetName(slot, automationName);
        return slot;
    }

    /// <summary>
    /// 卡片右侧一行横排的单选（mac radios：3–5 个选项、.radioGroup + 横排），系统的 RadioButton；
    /// 去掉它默认 120 的最小宽度，挨着排。
    /// </summary>
    public static FrameworkElement Radios(string[] items, int selected, Action<int> changed, string automationName)
    {
        var group = "kitty-radios-" + Guid.NewGuid().ToString("N");
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, VerticalAlignment = VerticalAlignment.Center };
        var current = Math.Clamp(selected, 0, Math.Max(0, items.Length - 1));
        for (var index = 0; index < items.Length; index++)
        {
            var at = index;
            var radio = new RadioButton
            {
                Content = items[index],
                GroupName = group,
                MinWidth = 0,
                IsChecked = index == current,
            };
            radio.Checked += (_, _) =>
            {
                if (at != current)
                {
                    current = at;
                    changed(at);
                }
            };
            row.Children.Add(radio);
        }

        AutomationProperties.SetName(row, automationName);
        return row;
    }

    /// <summary>
    /// 详情页里竖排表单用的「标题 + 分段 / 单选」（顶替带 Header 的 ComboBox）：SelectedIndex、SelectionChanged 同 ComboBox，
    /// 放进页面的是 View。
    /// </summary>
    public sealed class ChoiceView
    {
        public required FrameworkElement View { get; init; }

        public int SelectedIndex { get; internal set; }

        public event EventHandler? SelectionChanged;

        internal void Raise(int index)
        {
            SelectedIndex = index;
            SelectionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>上面一行标题、下面一组分段按钮（radios = true 时是横排单选）。</summary>
    public static ChoiceView Choice(string header, string[] items, int selected, bool radios = false)
    {
        ChoiceView? choice = null;
        var control = radios
            ? Radios(items, selected, index => choice!.Raise(index), header)
            : Segmented(items, selected, index => choice!.Raise(index), header);
        control.HorizontalAlignment = HorizontalAlignment.Left;
        var view = new StackPanel { Spacing = 6, Margin = new Thickness(0, 4, 0, 4) };
        view.Children.Add(new TextBlock { Text = header });
        view.Children.Add(control);
        choice = new ChoiceView { View = view, SelectedIndex = Math.Clamp(selected, 0, Math.Max(0, items.Length - 1)) };
        return choice;
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

    /// <summary>
    /// 组脚注（mac SectionFootnote）：解释整组的话写在这一组卡片的下面，12 secondary、靠左；卡片里不单独放一行说明（PLAN-v7 §3.7）。
    /// </summary>
    public static UIElement Footnote(string text) => new TextBlock
    {
        Text = text,
        FontSize = 12,
        Foreground = Theme.SecondaryText(),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(2, 0, 2, 4),
    };

    /// <summary>
    /// 子页左上角回上一层的那个按钮（PLAN-v23 W3）：Segoe 的左箭头 + 上一页的名字，平时没底色、次要字色，
    /// 指上去才铺一层浅底、字变深（Windows 设置里无边框按钮的样子）。左边往外挪 8，箭头和下面的标题对齐。
    /// </summary>
    public static Button BackButton(string previousTitle, string automationName, Action click)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = previousTitle, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var button = new Button
        {
            Content = content,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Foreground = Theme.SecondaryText(),
            Padding = new Thickness(8, 5, 10, 6),
            Margin = new Thickness(-8, 0, 0, 4),
        };
        button.Click += (_, _) => click();
        AutomationProperties.SetName(button, automationName);
        ToolTipService.SetToolTip(button, "返回（Alt + ←）");
        return button;
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
        row.Children.Add(KindTile.Create(FamilyOfPage(title), glyph ?? FeatureIcons.General, 32));
        row.Children.Add(texts);
        return row;
    }

    private static string FamilyOfPage(string title) => title switch
    {
        "快捷键" => "shortcut",
        "剪贴板" => "clipboard",
        "翻译" => "translate",
        "启动器" => "launcher",
        "截图" or "录制" => "capture",
        // PLAN-v20：后加的几页照侧栏的家族色（以前漏了，页头是灰的）
        "便签" => "notes",
        "提醒" => "reminders",
        "状态屏" => "statusScreen",
        "保持唤醒" => "keepAwake",
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

    /// <summary>
    /// 更新日志条目前的种类标签（同 mac 关于页的 ChangeRow）：新增绿、修复橙、性能紫、界面蓝，字是种类色、底是同色 12%。
    /// </summary>
    public static Border TypeTag(string? type)
    {
        var (label, color) = type switch
        {
            "feat" => ("新增", Theme.Family.Translate),
            "fix" => ("修复", Theme.Family.Shortcut),
            "perf" => ("性能", Theme.Family.Launcher),
            "ui" => ("界面", Theme.Family.Clipboard),
            _ => (type ?? string.Empty, Theme.Family.General),
        };
        return new Border
        {
            Padding = new Thickness(5, 1, 5, 1),
            CornerRadius = new CornerRadius(4),
            Background = Theme.Family.Tint(color, 31),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock
            {
                Text = label,
                FontSize = 10,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(color),
            },
        };
    }
}
