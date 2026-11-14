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
    /// "scripts" = 脚本命令，"script-guide" = 怎么写脚本。</summary>
    private string? _launcherSubpage;
    private string _commandFilter = string.Empty;
    private bool _commandOnlyOn;
    private readonly Dictionary<string, TextBox> _aliasBoxes = new();

    private static bool IsCommand(string action) => action.StartsWith(CommandPrefix, StringComparison.Ordinal);

    private static string CommandId(string action) => action[CommandPrefix.Length..];

    /// <summary>启动器页上那一行：「命令和别名 ›」，说明写改过几条、关掉几条。</summary>
    private void AddCommandsRow()
    {
        var settings = LauncherCommandKeys.Settings;
        var changed = settings.Aliases.Count;
        var off = settings.Off.Count;
        var detail = changed == 0 && off == 0
            ? "open、kill、ip、cb、fy、remind、currency 和系统命令：改要打的词、关掉不用的、设快捷键"
            : string.Join("，", new[] { changed > 0 ? $"改了 {changed} 个别名" : null, off > 0 ? $"关了 {off} 条" : null }.OfType<string>());
        AddSubpageRow("命令和别名", detail, () => OpenLauncherSubpage("commands"));
    }

    /// <summary>一行「标题 ›」：点了推进子页（L4：网页搜索、功能开关、命令和别名都这样收成一行）。</summary>
    private void AddSubpageRow(string title, string detail, Action open)
    {
        var chevron = new FontIcon { Glyph = Glyphs.ChevronRight, FontSize = 12, Foreground = Theme.SecondaryText() };
        var card = SettingsUi.Card(title, detail, chevron);
        var button = new Button
        {
            Content = card,
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, title);
        button.Click += (_, _) => open();
        _content.Children.Add(button);
    }

    /// <summary>截图自检：打开启动器 / 通用的子页（sub：commands、web、features；null = 页本身）。</summary>
    internal void OpenSubpageForProbe(string page, string? sub)
    {
        _launcherSubpage = page == "launcher" ? sub : null;
        _featuresPage = page == "general" && sub == "features";
        ShowPage(welcome: false, page);
        BuildPage(page);
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, 0, null, disableAnimation: true);
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
        var back = new HyperlinkButton { Content = "‹ 启动器", Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => OpenLauncherSubpage(null);
        AutomationProperties.SetName(back, "返回启动器设置");
        _content.Children.Add(back);
        _content.Children.Add(Header("命令和别名", "启动器里要打的词、开关和快捷键"));

        var search = new TextBox { PlaceholderText = "按名字或别名找", Text = _commandFilter };
        AutomationProperties.SetName(search, "搜索命令");
        var onlyOn = new CheckBox { Content = "只看开着的", IsChecked = _commandOnlyOn, Margin = new Thickness(12, 0, 0, 0) };
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(search);
        Grid.SetColumn(onlyOn, 1);
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
                ("我的脚本", LauncherCommandKeys.ScriptRows),
                ("自带的命令", LauncherCommandKeys.BundledRows),
                ("关键词命令", LauncherCommandTable.BuiltIns.AsEnumerable()),
                ("系统命令", SystemCommands.Rows()),
            };
            var any = false;
            foreach (var (title, rows) in groups)
            {
                var shown = rows.Where(Shown).OrderBy(row => row.Title, StringComparer.CurrentCulture).ToList();
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
    }

    private static string? CommandHotKey(string id)
        => SettingsService.Current.LauncherCommandHotKeys is { } keys && keys.TryGetValue(id, out var text) && text.Length > 0 ? text : null;

    private static void StoreCommands(LauncherCommandSettings settings)
    {
        SettingsService.Current.LauncherCommandAliases = settings.Aliases.Count == 0 ? null : new Dictionary<string, string>(settings.Aliases);
        SettingsService.Current.LauncherCommandsOff = settings.Off.Count == 0 ? null : settings.Off.OrderBy(id => id, StringComparer.Ordinal).ToList();
        SettingsService.Save();
    }

    /// <summary>别名和别的命令、网页搜索的关键词撞了：那一格描橙框。</summary>
    private void MarkAliasConflicts()
    {
        var settings = LauncherCommandKeys.Settings;
        var engines = (SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults()).Select(engine => engine.Keyword);
        var conflicts = LauncherCommandTable.Conflicts(
            LauncherCommandKeys.Rows.Where(row => settings.IsOn(row.Id)).Select(row => (row.Id, settings.Alias(row.Id, row.Keyword))), engines);
        foreach (var (id, box) in _aliasBoxes)
        {
            if (conflicts.Contains(id))
            {
                box.BorderBrush = Theme.Caution();
                ToolTipService.SetToolTip(box, "和别的命令或网页搜索的关键词撞了");
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
        if (SettingsDefaults.DefaultHotKeys.FirstOrDefault(definition =>
                SettingsDefaults.BindingFor(SettingsService.Current, definition.Action) is var binding &&
                binding.VirtualKey == key && binding.Modifiers == modifiers) is { } global)
        {
            SetCommandMessage(action, $"和全局快捷键「{SettingsDefaults.RowTitle(global.Action)}」重复");
            return;
        }

        if ((SettingsService.Current.LauncherCommandHotKeys ?? new Dictionary<string, string>())
            .FirstOrDefault(pair => pair.Key != id && pair.Value == text) is { Key: { } other })
        {
            var title = LauncherCommandKeys.Rows.FirstOrDefault(row => row.Id == other)?.Title ?? other;
            SetCommandMessage(action, $"和命令「{title}」重复");
            return;
        }

        var keys = new Dictionary<string, string>(SettingsService.Current.LauncherCommandHotKeys ?? new Dictionary<string, string>()) { [id] = text };
        SettingsService.Current.LauncherCommandHotKeys = keys;
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        _recordingAction = null;
        BuildPage("launcher");
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
