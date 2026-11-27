// 设置 › 启动器 › 命令和别名（PLAN-v18 L2 L3，mac LauncherCommandsSection / LauncherCommandsPage）：启动器页上一行「命令和别名 ›」，
// 点进来是一张「名称 / 别名 / 快捷键 / 启用」的表，两组——关键词命令（open、kill、ip、cb、fy、remind、currency…）、系统命令
// （lock、sleep…），组里按名字排；上面能搜、能只看开着的。最前面是我的脚本、自带的命令（PLAN-v18 第 6–8 批）。
// 别名就是在启动器里要打的那个词：改了旧词不再认，清空就只能按名字搜；和别的命令、网页搜索的关键词撞了那一格描橙框。
// 关掉 = 不出现在搜索、常用、收藏里，关键词也不认。只存改过的（Core LauncherCommandTable，跟着导出导入）。
// 快捷键那一列：同快捷键页的录制框（_recordingAction 带 cmd: 前缀），和全局快捷键、别的命令一起查重；按了直接跑（LauncherCommandKeys）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private const string CommandPrefix = "cmd:";

    /// <summary>启动器页里点进去的子页：null = 启动器页本身，"commands" = 命令和别名，"web" = 网页搜索，"apps" = 应用，
    /// "scripts" = 脚本命令，"script-guide" = 怎么写脚本（PLAN-v28：和别的页的子页、「高级」同一个 _subpage）。</summary>
    private string? _launcherSubpage
    {
        get => _subpage is "commands" or "web" or "apps" or "scripts" or "script-guide" ? _subpage : null;
        set => SetSubpage("launcher", value);
    }
    private string _commandFilter = string.Empty;
    private bool _commandOnlyOn;
    private readonly Dictionary<string, TextBox> _aliasBoxes = new();

    private static bool IsCommand(string action) => action.StartsWith(CommandPrefix, StringComparison.Ordinal);

    private static string CommandId(string action) => action[CommandPrefix.Length..];

    /// <summary>启动器页上那一行：「命令和别名 ›」，小字写各有几条、关了几条（mac commandsSummary，REVIEW R93）。</summary>
    private void AddCommandsRow()
    {
        var settings = LauncherCommandKeys.Settings;
        var mine = LauncherCommandKeys.ScriptRows.ToList();
        var bundled = LauncherCommandKeys.BundledRows.ToList();
        var keyword = LauncherCommandTable.BuiltIns.ToList();
        var system = SystemCommands.Rows().ToList();
        var parts = new List<string>();
        if (mine.Count > 0)
        {
            parts.Add($"{mine.Count} 个我的脚本");
        }

        if (bundled.Count > 0)
        {
            parts.Add($"{bundled.Count} 个自带的命令");
        }

        parts.Add($"{keyword.Count} 个关键词命令");
        parts.Add($"{system.Count} 个系统命令");
        var closed = mine.Concat(bundled).Concat(keyword).Concat(system).Count(row => !settings.IsOn(row.Id));
        Anchor("launcher.commands", AddSubpageRow("命令和别名", string.Join("、", parts) + (closed > 0 ? $"，关了 {closed} 个" : string.Empty),
            () => OpenLauncherSubpage("commands")));
    }

    /// <summary>「命令和别名」表上面那排筛选（mac LauncherCommandsSection.Filter）：0 全部、1 我的脚本、2 自带的命令、3 内置。</summary>
    private int _commandGroup;

    /// <summary>一行「标题 ›」：点了推进子页（L4：网页搜索、功能开关、命令和别名都这样收成一行；PLAN-v28 X1 行尾能写状态）。</summary>
    private Button AddSubpageRow(string title, string detail, Action open, SettingsSummary.RowValue? value = null)
    {
        var button = SettingsUi.PushRow(title, detail, value?.Text, value?.Problem == true, open);
        _content.Children.Add(button);
        return button;
    }

    /// <summary>截图自检：打开启动器 / 通用的子页（sub：commands、web、features；null = 页本身）。</summary>
    internal void OpenSubpageForProbe(string page, string? sub)
    {
        _serviceDetail = null;
        FlushDetail();
        _detail = null;
        SetSubpage(page, sub);
        ShowPage(welcome: false, page);
        BuildPage(page);
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    /// <summary>
    /// 启动器 Ctrl+K「改别名…」（PLAN-v20 L2，mac bda29731）：打开 命令和别名、清掉筛选，滚到那一行、描两秒强调色，光标放进它的别名框。
    /// 那条关着、「只看开着的」勾着时先把勾去掉。
    /// </summary>
    public void FocusCommand(string id)
    {
        _commandOnlyOn = false;
        OpenLauncherSubpage("commands");
        _scroll.UpdateLayout();
        if (FindTagged(_content, "command:" + id) is not Border row)
        {
            return;
        }

        var brush = row.BorderBrush;
        var thickness = row.BorderThickness;
        row.BorderBrush = new SolidColorBrush(Theme.AccentColor);
        row.BorderThickness = new Thickness(2);
        row.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3, AnimationDesired = false });
        if (_aliasBoxes.TryGetValue(id, out var box))
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        }

        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            row.BorderBrush = brush;
            row.BorderThickness = thickness;
        };
        timer.Start();

        static FrameworkElement? FindTagged(DependencyObject node, string tag)
        {
            if (node is FrameworkElement element && element.Tag as string == tag)
            {
                return element;
            }

            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var index = 0; index < count; index++)
            {
                if (FindTagged(VisualTreeHelper.GetChild(node, index), tag) is { } found)
                {
                    return found;
                }
            }

            return null;
        }
    }

    private void OpenLauncherSubpage(string? subpage)
    {
        _launcherSubpage = subpage;
        _commandFilter = string.Empty;
        BuildPage("launcher");
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void BuildLauncherCommands()
    {
        _content.Children.Add(SettingsUi.BackButton("启动器", "返回启动器设置", () => OpenLauncherSubpage(null)));
        _content.Children.Add(Header("命令和别名", "启动器里要打的词、开关和快捷键"));

        var search = new TextBox { PlaceholderText = "按名字或别名找", Text = _commandFilter };
        AutomationProperties.SetName(search, "搜索命令");
        var onlyOn = new CheckBox { Content = "只看开着的", IsChecked = _commandOnlyOn, Margin = new Thickness(12, 0, 0, 0) };
        // 一排筛选（同 mac 的分段控件）；Fill 在下面定义，先占个位
        Action fill = () => { };
        var group = SettingsUi.Segmented(new[] { "全部", "我的脚本", "自带的命令", "内置" }, _commandGroup, index =>
        {
            _commandGroup = index;
            fill();
        }, "只看哪一种命令");
        group.Margin = new Thickness(12, 0, 0, 0);
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(search);
        Grid.SetColumn(group, 1);
        top.Children.Add(group);
        Grid.SetColumn(onlyOn, 2);
        top.Children.Add(onlyOn);
        _content.Children.Add(top);

        var table = new StackPanel { Spacing = 4 };
        _content.Children.Add(table);
        void Fill()
        {
            table.Children.Clear();
            _aliasBoxes.Clear();
            var settings = LauncherCommandKeys.Settings;
            var filter = LauncherMatch.Fold(_commandFilter);
            bool Shown(LauncherBuiltIn row)
                => (!_commandOnlyOn || settings.IsOn(row.Id)) &&
                   (filter.Length == 0 || LauncherMatch.Fold(row.Title).Contains(filter, StringComparison.Ordinal) ||
                    (settings.Alias(row.Id, row.Keyword) ?? string.Empty).Contains(filter, StringComparison.Ordinal) ||
                    row.Keyword.Contains(filter, StringComparison.Ordinal));
            var groups = new[]
            {
                ("我的脚本", LauncherCommandKeys.ScriptRows, 1),
                ("自带的命令", LauncherCommandKeys.BundledRows, 2),
                ("关键词命令", LauncherCommandTable.BuiltIns.AsEnumerable(), 3),
                ("系统命令", SystemCommands.Rows(), 3),
            };
            var any = false;
            foreach (var (title, rows, kind) in groups)
            {
                if (_commandGroup != 0 && _commandGroup != kind)
                {
                    continue;
                }

                var shown = rows.Where(Shown).OrderBy(row => row.Title, StringComparer.CurrentCulture).ToList();
                // 「我的脚本」是空的时候照样列这一组、一行「还没有自己的脚本 · 用例子新建」（mac LauncherCommandsSection，REVIEW R93）
                if (kind == 1 && shown.Count == 0 && !rows.Any() && filter.Length == 0 && !_commandOnlyOn && SettingsService.Current.LauncherScripts)
                {
                    any = true;
                    table.Children.Add(SettingsUi.Section(title));
                    var example = new HyperlinkButton { Content = "用例子新建" };
                    example.Click += (_, _) => NewScriptExample();
                    table.Children.Add(SettingsUi.Card("还没有自己的脚本", "把脚本放进脚本文件夹就是一条命令", example));
                    continue;
                }

                if (shown.Count == 0)
                {
                    continue;
                }

                any = true;
                table.Children.Add(SettingsUi.Section(title));
                table.Children.Add(CommandHeader());
                foreach (var row in shown)
                {
                    table.Children.Add(CommandRow(row, settings));
                }
            }

            if (!any)
            {
                table.Children.Add(new TextBlock { Text = "没有匹配的命令", Foreground = Theme.SecondaryText(), Margin = new Thickness(4) });
            }

            MarkAliasConflicts();
        }

        search.TextChanged += (_, _) =>
        {
            _commandFilter = search.Text;
            Fill();
        };
        onlyOn.Click += (_, _) =>
        {
            _commandOnlyOn = onlyOn.IsChecked == true;
            Fill();
        };
        fill = Fill;
        Fill();
        _content.Children.Add(SettingsUi.Footnote(
            "别名就是在启动器里要打的那个词：改了以后旧词不再认，清空就只能按名字搜；和别的命令、网页搜索的关键词撞了那一格描橙框。" +
            "关掉 = 不出现在搜索、常用、收藏里，关键词也不认。快捷键按了直接跑；要参数、要确认的打开启动器做那一步。"));
    }

    private const double AliasWidth = 120;
    private const double CommandKeyWidth = 150;

    private static Grid CommandHeader()
    {
        var header = CommandGrid();
        header.Margin = new Thickness(46, 0, 12, 0);
        foreach (var (text, column) in new[] { ("名称", 0), ("别名", 1), ("快捷键", 2), ("启用", 3) })
        {
            var label = new TextBlock { Text = text, FontSize = 11, Foreground = Theme.SecondaryText() };
            Grid.SetColumn(label, column);
            header.Children.Add(label);
        }

        AutomationProperties.SetAccessibilityView(header, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return header;
    }

    private static Grid CommandGrid()
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(AliasWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CommandKeyWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
        return grid;
    }

    private Border CommandRow(LauncherBuiltIn row, LauncherCommandSettings settings)
    {
        var on = settings.IsOn(row.Id);
        var grid = CommandGrid();
        var names = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(KindTile.Create("launcher", row.Glyph, 24));
        names.Children.Add(new TextBlock { Text = row.Title, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        grid.Children.Add(names);

        settings.Aliases.TryGetValue(row.Id, out var raw);
        var alias = new TextBox
        {
            Text = raw ?? row.Keyword,
            PlaceholderText = "无",
            VerticalAlignment = VerticalAlignment.Center,
            IsEnabled = on,
        };
        AutomationProperties.SetName(alias, $"「{row.Title}」的别名");
        alias.TextChanged += (_, _) =>
        {
            var current = LauncherCommandKeys.Settings.WithAlias(row.Id, alias.Text, row.Keyword);
            StoreCommands(current);
            MarkAliasConflicts();
        };
        _aliasBoxes[row.Id] = alias;
        Grid.SetColumn(alias, 1);
        grid.Children.Add(alias);

        var action = CommandPrefix + row.Id;
        var key = new Button
        {
            MinHeight = 32,
            Padding = new Thickness(8, 2, 8, 2),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            IsEnabled = on,
        };
        _hotKeyBoxes[action] = key;
        ShowBinding(key, action);
        key.Click += (_, _) =>
        {
            if (_recordingAction != action)
            {
                BeginRecording(action);
            }
        };
        key.LostFocus += (_, _) =>
        {
            if (_recordingAction == action)
            {
                StopRecording(action, null);
            }
        };
        var clear = new MenuFlyoutItem { Text = "清除快捷键", IsEnabled = CommandHotKey(row.Id) is not null };
        clear.Click += (_, _) => ClearHotKey(action);
        key.ContextFlyout = new MenuFlyout { Items = { clear } };
        Grid.SetColumn(key, 2);
        grid.Children.Add(key);

        var toggle = SettingsUi.Toggle(on, isOn =>
        {
            StoreCommands(LauncherCommandKeys.Settings.WithOn(row.Id, isOn));
            alias.IsEnabled = isOn;
            key.IsEnabled = isOn;
        }, $"启用「{row.Title}」");
        toggle.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(toggle, 3);
        grid.Children.Add(toggle);

        var problem = new TextBlock { FontSize = 11, Foreground = Theme.Caution(), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var body = new StackPanel { Spacing = 2 };
        body.Children.Add(grid);
        body.Children.Add(problem);
        var card = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(12, 6, 12, 6),
            Background = Theme.CardBackground(),
            Child = body,
            Tag = "command:" + row.Id,
        };
        _hotKeyCards[action] = card;
        _commandProblems[action] = problem;
        if (ShellRuntime.Instance?.HotKeys.FailureFor(action) is { } failure)
        {
            problem.Text = failure;
            problem.Visibility = Visibility.Visible;
        }

        return card;
    }

    /// <summary>每条命令那一行下面的橙字（录错、注册不上的原因）。</summary>
    private readonly Dictionary<string, TextBlock> _commandProblems = new();

    private void SetCommandMessage(string action, string? message)
    {
        if (_commandProblems.TryGetValue(action, out var problem))
        {
            var text = message ?? ShellRuntime.Instance?.HotKeys.FailureFor(action);
            problem.Text = text ?? string.Empty;
            problem.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        }

        Announce(action, message);
    }

    private static string? CommandHotKey(string id)
        => SettingsService.Current.LauncherCommandHotKeys is { } keys && keys.TryGetValue(id, out var text) && text.Length > 0 ? text : null;

    private static void StoreCommands(LauncherCommandSettings settings)
    {
        SettingsService.Current.LauncherCommandAliases = settings.Aliases.Count == 0 ? null : new Dictionary<string, string>(settings.Aliases);
        SettingsService.Current.LauncherCommandsOff = settings.Off.Count == 0 ? null : settings.Off.OrderBy(id => id, StringComparer.Ordinal).ToList();
        SettingsService.Save();
    }

    /// <summary>别名和别的命令、网页搜索的关键词、应用别名（PLAN-v26 L5）撞了：那一格描橙框。</summary>
    private void MarkAliasConflicts()
    {
        var settings = LauncherCommandKeys.Settings;
        var engines = (SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults()).Select(engine => engine.Keyword);
        var conflicts = LauncherCommandTable.Conflicts(
            LauncherCommandKeys.Rows.Where(row => settings.IsOn(row.Id)).Select(row => (row.Id, settings.Alias(row.Id, row.Keyword))), engines,
            // 一个应用能起几个别名（PLAN-v27 B5）：按词比，不按整段原文
            SettingsService.Current.LauncherAppAliases?.Values.SelectMany(text => AppAliases.Words(text)));
        foreach (var (id, box) in _aliasBoxes)
        {
            if (conflicts.Contains(id))
            {
                box.BorderBrush = Theme.Caution();
                ToolTipService.SetToolTip(box, "和别的命令、网页搜索的关键词或应用别名撞了");
            }
            else
            {
                box.ClearValue(Control.BorderBrushProperty);
                ToolTipService.SetToolTip(box, null);
            }
        }
    }

    /// <summary>录下一条命令的快捷键：规矩同全局快捷键，另外不能和全局快捷键、别的命令一样。</summary>
    private void RecordCommandKey(string action, uint key, HotKeyModifiers modifiers)
    {
        var validation = HotKeyRules.Validate(key, modifiers);
        if (!validation.Ok)
        {
            SetCommandMessage(action, validation.Reason ?? "这个组合不能用");
            return;
        }

        if (HotKeyRules.IsDoubleTap(key, modifiers))
        {
            SetCommandMessage(action, "命令的快捷键不能是连按两下");
            return;
        }

        var text = HotKeyRules.Format(key, modifiers);
        var id = CommandId(action);
        // 和全局动作（关着的功能也算）、和别的命令重复（PLAN-v23 H3，mac saveCommand）
        if (HotKeyConflicts.ForCommand(id, key, modifiers, GlobalOwners(), CommandOwners()) is { } conflict)
        {
            SetCommandMessage(action, conflict);
            return;
        }

        var keys = new Dictionary<string, string>(SettingsService.Current.LauncherCommandHotKeys ?? new Dictionary<string, string>()) { [id] = text };
        SettingsService.Current.LauncherCommandHotKeys = keys;
        SettingsService.Save();
        _recordingAction = null;
        RebuildKeepingRecorder(action, "launcher");
    }

    private void ClearCommandKey(string action)
    {
        if (SettingsService.Current.LauncherCommandHotKeys is { } keys && keys.Remove(CommandId(action)))
        {
            SettingsService.Current.LauncherCommandHotKeys = keys.Count == 0 ? null : keys;
            SettingsService.Save();
            ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        }

        BuildPage("launcher");
    }
}
