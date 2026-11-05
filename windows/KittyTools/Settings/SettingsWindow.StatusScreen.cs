// 设置 › 状态屏（PLAN-v12 N5，照 mac Settings/StatusScreenTab.swift + StatusPresetDetail.swift）：启用状态屏 ｜ 状态列表
// （每行 = 表情的静止画面 + 标题 + 一行摘要；点一行编辑，右键 编辑… / 上移 / 下移 / 删除，下面「＋」新状态 / 恢复自带的状态）｜
// 进入（按快捷键直接进入排在最前面的状态）｜ 动画（告示上的动画）｜ 退出（怎么退出 + 速查表、退出提示的开关、退出密码）。
// 编辑是一张对话框（同网页搜索那张列表）：标题、说明、图标格子（无 + 16 个表情）、样式 + 缩小的预览、电源、自动结束。
// 页里不放「进入」「试一下」这类会真的进入状态屏的按钮（mac 同样）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private void BuildStatusScreen()
    {
        _content.Children.Add(Header("状态屏", "盖住屏幕、拦住键盘鼠标的告示"));
        AddFeatureToggle(Feature.StatusScreen);
        var settings = SettingsService.Current;
        var presets = StatusScreenHost.Presets;
        _shownStatuses = settings.StatusScreenPresets;

        void Persist(List<StatusPreset> next)
        {
            // 页面开着时同步换了列表（PLAN-v12 第 7 批，同网页搜索 E19）：别拿建页时那份把别的电脑刚改的盖掉。
            if (!ReferenceEquals(settings.StatusScreenPresets, _shownStatuses))
            {
                NoticeHost.Show("状态刚从别的电脑同步过来", "这一页换成了最新的，再改一次", NoticeTone.Warning);
                BuildPage("statusScreen");
                return;
            }

            settings.StatusScreenPresets = StatusPresets.Sanitized(next);
            SettingsService.Save();
            BuildPage("statusScreen");
        }

        // 状态
        _content.Children.Add(SettingsUi.Section("状态"));
        for (var index = 0; index < presets.Count; index++)
        {
            _content.Children.Add(StatusPresetRow(presets, index, Persist));
        }

        var isFull = presets.Count >= StatusPresets.MaxCount;
        var add = new DropDownButton { Content = new FontIcon { Glyph = "\uE710", FontSize = 14 }, IsEnabled = !isFull };
        AutomationProperties.SetName(add, "添加状态");
        ToolTipService.SetToolTip(add, "新状态 / 恢复自带的状态");
        var addMenu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        var newItem = new MenuFlyoutItem { Text = "新状态" };
        newItem.Click += async (_, _) =>
        {
            var draft = StatusPresets.New();
            if (await EditStatusPresetAsync(draft, isNew: true))
            {
                Persist(StatusPresets.Adding(draft, presets));
            }
        };
        var restore = new MenuFlyoutItem { Text = "恢复自带的状态", IsEnabled = StatusPresets.MissingBuiltIns(presets).Count > 0 };
        restore.Click += (_, _) => Persist(StatusPresets.RestoringBuiltIns(presets));
        addMenu.Items.Add(newItem);
        addMenu.Items.Add(restore);
        add.Flyout = addMenu;
        _content.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0), Children = { add } });
        _content.Children.Add(SettingsUi.Footnote(
            "点一行编辑，右键能上移、下移和删除。" +
            (settings.StatusScreenHotKeyEntersFirst
                ? "排在最前面的状态就是全局快捷键进入的那个。"
                : "按全局快捷键选状态时，卡片也按这个顺序排。") +
            "至少留一个；删掉的自带状态可以从「＋」里恢复。" +
            (isFull ? $"最多 {StatusPresets.MaxCount} 个，已经满了，删掉一个才能再加。" : string.Empty)));

        // 进入
        _content.Children.Add(SettingsUi.Section("进入"));
        AddToggle("按快捷键直接进入排在最前面的状态", "关着时，按快捷键先出一排预览卡片，选一个再进",
            settings.StatusScreenHotKeyEntersFirst,
            isOn =>
            {
                settings.StatusScreenHotKeyEntersFirst = isOn;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote("快捷键在 设置 › 快捷键 里设置，默认没有。在托盘、主界面、启动器里选一个状态，都是直接进入。"));

        // 动画
        _content.Children.Add(SettingsUi.Section("动画"));
        AddToggle("告示上的动画", "关掉后表情不动、进入时不做出场、屏幕边上不冒眼睛；标题照样晃一下",
            settings.StatusScreenAnimations,
            isOn =>
            {
                settings.StatusScreenAnimations = isOn;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote("系统设置里关了「动画效果」时，这些动画都不做，标题也不晃。"));

        // 退出
        _content.Children.Add(SettingsUi.Section("退出"));
        AddShortcutsRow("statusScreen", "怎么退出",
            "按住 Esc 两秒；或者动一下鼠标，再用鼠标按住屏幕底部出现的提示两秒。到了自动结束的时间、解锁电脑回来时，也会结束。");
        AddToggle("有人碰键盘或鼠标时显示怎么退出", "关掉后屏幕上不再提示，只能按住 Esc 两秒退出；键盘上没有 Esc 键的别关",
            settings.StatusScreenExitHint,
            isOn =>
            {
                settings.StatusScreenExitHint = isOn;
                SettingsService.Save();
            });
        _content.Children.Add(PasscodeRow());
        _content.Children.Add(SettingsUi.Footnote(
            "状态屏是告示加防误触，不是安全措施：没设退出密码时照着提示谁都能退出，设了也拦不住 Ctrl+Alt+Del、电源键和合盖。" +
            "要防别人动电脑，进入之后再锁定屏幕（Win+L）：电脑照样不睡，回来解锁就结束——忘了退出密码也这样出来。"));
    }

    /// <summary>一行状态（mac StatusPresetRow）：表情的静止画面（没选的是家族色块）+ 标题 + 摘要；点一下编辑，右键 编辑… / 上移 / 下移 / 删除。</summary>
    private Border StatusPresetRow(List<StatusPreset> presets, int index, Action<List<StatusPreset>> persist)
    {
        var preset = presets[index];
        var dark = _content.ActualTheme == ElementTheme.Dark || Theme.EffectiveTheme == ElementTheme.Dark;
        FrameworkElement leading = preset.Symbol.Length > 0
            ? StatusEmoji.Still(preset.Symbol, 24, dark)
            : KindTile.Create("statusScreen", "\uE8E4", 24);

        async Task EditAsync()
        {
            var draft = preset.Copy();
            if (await EditStatusPresetAsync(draft, isNew: false))
            {
                persist(StatusPresets.Updating(presets, draft));
            }
        }

        async Task RemoveAsync()
        {
            if (presets.Count <= 1)
            {
                return;
            }

            // 和自带的一模一样的直接删（「＋」里能原样加回来），自己加的、改过的先确认。
            if (!StatusPresets.IsPristine(preset))
            {
                var dialog = new ContentDialog
                {
                    RequestedTheme = Theme.ElementTheme,
                    Title = $"删除「{preset.Title}」？",
                    Content = "自己加的、改过的状态删掉就找不回来了。",
                    PrimaryButtonText = "删除",
                    CloseButtonText = "取消",
                    DefaultButton = ContentDialogButton.Close,
                    XamlRoot = _content.XamlRoot,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary)
                {
                    return;
                }
            }

            persist(StatusPresets.Removing(preset.Id, presets));
        }

        var card = SettingsUi.Card(preset.Title, StatusPresets.Summary(preset), null, () => _ = EditAsync(), leading: leading);
        AutomationProperties.SetHelpText(card, "点一下编辑；右键有上移、下移和删除");
        var menu = new MenuFlyout();
        void Add(string text, bool enabled, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("编辑…", true, () => _ = EditAsync());
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("上移", index > 0, () => persist(StatusPresets.Moving(preset.Id, -1, presets)));
        Add("下移", index < presets.Count - 1, () => persist(StatusPresets.Moving(preset.Id, 1, presets)));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(StatusPresets.IsPristine(preset) ? "删除" : "删除…", presets.Count > 1, () => _ = RemoveAsync());
        card.ContextFlyout = menu;
        return card;
    }

    /// <summary>
    /// 编辑一个状态（mac StatusPresetDetail）：标题、说明、图标格子、样式 + 缩小的预览、电源、自动结束；下面橙字写有什么问题。
    /// 改的是传进来的 draft；点「保存」才返回 true。标题空着不让存。
    /// </summary>
    private async Task<bool> EditStatusPresetAsync(StatusPreset draft, bool isNew)
    {
        var title = new TextBox { Header = "标题", Text = draft.Title, PlaceholderText = "如 马上回来" };
        var detail = new TextBox { Header = "说明", Text = draft.Detail ?? string.Empty, PlaceholderText = "可不填" };
        var hint = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Theme.SecondaryText(),
        };
        var previewHost = new Border { HorizontalAlignment = HorizontalAlignment.Left };
        var styles = new ComboBox { Header = "样式", ItemsSource = StatusPresets.Styles.Select(StatusPresets.StyleTitle).ToList(), MinWidth = 160 };
        styles.SelectedIndex = Math.Max(0, Array.IndexOf(StatusPresets.Styles, draft.Style));
        var styleNote = new TextBlock { FontSize = Theme.FontSize("Kitty.FontSize.Label"), Foreground = Theme.SecondaryText() };
        var powers = new ComboBox { Header = "电源", ItemsSource = StatusPresets.Powers.Select(StatusPresets.PowerTitle).ToList(), MinWidth = 160 };
        powers.SelectedIndex = Math.Max(0, Array.IndexOf(StatusPresets.Powers, draft.Power));
        var ends = new ComboBox
        {
            Header = "自动结束",
            ItemsSource = StatusPresets.AutoEndChoices.Select(StatusPresets.AutoEndTitle).ToList(),
            MinWidth = 160,
        };
        ends.SelectedIndex = Math.Max(0, Array.IndexOf(StatusPresets.AutoEndChoices, draft.AutoEndMinutes));

        // 图标格子：第一格「无」，后面 16 个表情的静止画面，选中的外面一圈强调色。
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var icons = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, MaximumRowsOrColumns = 9, ItemWidth = 44, ItemHeight = 44 };
        var iconButtons = new List<(string Id, Button Button)>();
        void SelectIcon(string id)
        {
            draft.Symbol = id;
            foreach (var (value, button) in iconButtons)
            {
                button.BorderBrush = value == id ? new SolidColorBrush(Theme.AccentColor) : new SolidColorBrush(Colors.Transparent);
            }

            Refresh();
        }

        foreach (var id in new[] { string.Empty }.Concat(StatusEmojiCatalog.Choices.Select(choice => choice.Id)))
        {
            var button = new Button
            {
                Width = 40,
                Height = 40,
                Padding = new Thickness(4),
                BorderThickness = new Thickness(2),
                Content = id.Length == 0
                    ? new TextBlock { Text = "无", FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center }
                    : StatusEmoji.Still(id, 28, dark),
            };
            AutomationProperties.SetName(button, id.Length == 0 ? "不要图标" : "图标：" + StatusEmojiCatalog.Name(id));
            var captured = id;
            button.Click += (_, _) => SelectIcon(captured);
            iconButtons.Add((id, button));
            icons.Children.Add(button);
        }

        var iconHeader = new TextBlock { Text = "图标", Margin = new Thickness(0, 4, 0, 0) };
        var panel = new StackPanel { Spacing = 10, MinWidth = 440 };
        panel.Children.Add(title);
        panel.Children.Add(detail);
        panel.Children.Add(iconHeader);
        panel.Children.Add(icons);
        panel.Children.Add(styles);
        panel.Children.Add(styleNote);
        panel.Children.Add(previewHost);
        panel.Children.Add(powers);
        panel.Children.Add(ends);
        panel.Children.Add(SettingsUi.Footnote("电源只管闲置的时候：屏幕锁定后照常熄灭，合上盖子照样睡眠。屏幕常亮时电脑也不睡眠。"));
        panel.Children.Add(hint);
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = isNew ? "新状态" : $"编辑「{draft.Title}」",
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 },
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _content.XamlRoot,
        };

        void Refresh()
        {
            draft.Title = title.Text;
            draft.Detail = detail.Text.Length == 0 ? null : detail.Text;
            draft.Style = StatusPresets.Styles[Math.Max(0, styles.SelectedIndex)];
            draft.Power = StatusPresets.Powers[Math.Max(0, powers.SelectedIndex)];
            draft.AutoEndMinutes = StatusPresets.AutoEndChoices[Math.Max(0, ends.SelectedIndex)];
            styleNote.Text = StatusPresets.StyleExplanation(draft.Style);
            previewHost.Child = StatusScreenView.Preview(draft, 288, 180);
            var problem = StatusPresets.Problem(draft);
            hint.Text = problem ?? $"标题最多 {StatusPresets.MaxTitle} 个字，说明最多 {StatusPresets.MaxDetail} 个字。";
            hint.Foreground = problem is null ? Theme.SecondaryText() : Theme.Caution();
            dialog.IsPrimaryButtonEnabled = StatusPresets.OneLine(draft.Title).Length > 0;
        }

        title.TextChanged += (_, _) => Refresh();
        detail.TextChanged += (_, _) => Refresh();
        styles.SelectionChanged += (_, _) => Refresh();
        powers.SelectionChanged += (_, _) => Refresh();
        ends.SelectionChanged += (_, _) => Refresh();
        SelectIcon(draft.Symbol);
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <summary>
    /// 退出密码一行（mac passcodeRow）：没设时一个密码框（4–8 位数字），开始填了再出「再输一次」和「设置」；设了之后只写「已设置」、
    /// 右边一个「移除」（要换就移除了重设）。改它不用先输旧密码：能打开设置的人本来就在用这台电脑。存在凭据管理器里。
    /// </summary>
    private Border PasscodeRow()
    {
        var isSet = StatusScreenHost.LoadPasscode() is not null;
        if (isSet)
        {
            var remove = new Button { Content = "移除" };
            remove.Click += (_, _) =>
            {
                StatusScreenHost.SavePasscode(null);
                BuildPage("statusScreen");
            };
            return SettingsUi.Card("退出密码", "已设置。按住满两秒之后，还要输入它才能退出。", remove);
        }

        var first = new PasswordBox { PlaceholderText = "4–8 位数字", Width = 120, MaxLength = Passcode.MaxLength };
        var second = new PasswordBox { PlaceholderText = "再输一次", Width = 120, MaxLength = Passcode.MaxLength, Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(first, "退出密码");
        AutomationProperties.SetName(second, "再输一次退出密码");
        var set = new Button { Content = "设置", IsEnabled = false, Visibility = Visibility.Collapsed };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        controls.Children.Add(first);
        controls.Children.Add(second);
        controls.Children.Add(set);
        var card = SettingsUi.Card("退出密码", "设了之后，按住满两秒还要输入这个密码才能退出", controls);

        void Refresh()
        {
            var typing = first.Password.Length > 0;
            second.Visibility = set.Visibility = typing ? Visibility.Visible : Visibility.Collapsed;
            var problem = Passcode.Problem(first.Password, second.Password);
            set.IsEnabled = problem is null;
            SettingsUi.SetDescription(
                card,
                !typing ? "设了之后，按住满两秒还要输入这个密码才能退出" : problem ?? "两遍一样，可以设置了",
                typing && problem is not null);
        }

        void Save()
        {
            if (Passcode.Problem(first.Password, second.Password) is not null)
            {
                return;
            }

            StatusScreenHost.SavePasscode(first.Password);
            BuildPage("statusScreen");
        }

        first.PasswordChanged += (_, _) => Refresh();
        second.PasswordChanged += (_, _) => Refresh();
        second.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                Save();
            }
        };
        set.Click += (_, _) => Save();
        return card;
    }
}
