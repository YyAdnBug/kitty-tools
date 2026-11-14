// 设置 › 快捷键 最下面「在这些应用里停用」（PLAN-v17 H5 H7，mac Settings/HotKeyBlockSection.swift）：一行一个应用（图标 + 显示名 +
// 灰色的 exe 名 + 范围下拉 + 移除，照剪贴板「不记录这些应用里的复制」那一节）；下拉是「全部快捷键」或勾几个全局动作（分组同快捷键页、
// 只列开着的功能的）。另有「全屏游戏时停用快捷键」开关（默认开）。名单存法和规则在 Core HotKeyBlock，改了保存后 ShellRuntime 当场重算。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using KittyTools.Ui;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private void BuildHotKeyBlocks()
    {
        _content.Children.Add(SettingsUi.Section("在这些应用里停用"));
        var settings = SettingsService.Current;
        var known = SettingsDefaults.DefaultHotKeys.Select(definition => definition.Action).ToList();
        var sections = VisibleHotKeySections().ToList();
        var shown = sections.SelectMany(section => section.Actions).ToList();
        var running = RunningApps();
        var list = new StackPanel { Spacing = 2 };
        var blocks = HotKeyBlock.List(settings.HotKeyBlockedApps);
        if (blocks.Count == 0)
        {
            list.Children.Add(new TextBlock { Text = "没有停用快捷键的应用", Foreground = Theme.SecondaryText(), Margin = new Thickness(4) });
        }

        void Store(Func<List<HotKeyBlock>, List<HotKeyBlock>> edit)
        {
            // 从设置现读再改（托盘那一项可能刚改过）
            settings.HotKeyBlockedApps = edit(HotKeyBlock.List(settings.HotKeyBlockedApps)).Select(block => block.Entry).ToList();
            SettingsService.Save();
            BuildPage("hotkeys");
        }

        foreach (var block in blocks)
        {
            var path = running.FirstOrDefault(item => string.Equals(Path.GetFileName(item.Path), block.Exe, StringComparison.OrdinalIgnoreCase)).Path;
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new Border { Width = 20, Height = 20, VerticalAlignment = VerticalAlignment.Center, Child = new FontIcon { Glyph = "", FontSize = 14, Foreground = Theme.SecondaryText() } };
            if (path is not null)
            {
                _ = LoadAppIconAsync(icon, path);
            }

            row.Children.Add(icon);
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var title = path is null ? Path.GetFileNameWithoutExtension(block.Exe) : AppDisplayName(path);
            names.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
            names.Children.Add(new TextBlock { Text = block.Exe, FontSize = 11, Foreground = Theme.SecondaryText() });
            Grid.SetColumn(names, 1);
            row.Children.Add(names);

            var scope = new DropDownButton { Content = HotKeyBlock.Scope(block), VerticalAlignment = VerticalAlignment.Center };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(scope, $"「{title}」里停用哪些快捷键");
            var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
            var all = new ToggleMenuFlyoutItem { Text = "全部快捷键", IsChecked = block.Actions is null };
            var exe = block.Exe;
            all.Click += (_, _) => Store(current => current.Select(item =>
                string.Equals(item.Exe, exe, StringComparison.OrdinalIgnoreCase) ? item with { Actions = null } : item).ToList());
            menu.Items.Add(all);
            foreach (var (section, actions) in sections)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(new MenuFlyoutItem { Text = section, IsEnabled = false });
                foreach (var action in actions)
                {
                    var blocked = block.Actions is not null && block.Blocks(action);
                    var item = new ToggleMenuFlyoutItem { Text = SettingsDefaults.RowTitle(action), IsChecked = blocked };
                    var chosen = action;
                    item.Click += (_, _) => Store(current => current.Select(entry =>
                            string.Equals(entry.Exe, exe, StringComparison.OrdinalIgnoreCase)
                                ? entry.Setting(chosen, blocked: entry.Actions is null || !entry.Blocks(chosen), shown, known)
                                : entry)
                        .ToList());
                    menu.Items.Add(item);
                }
            }

            scope.Flyout = menu;
            Grid.SetColumn(scope, 2);
            row.Children.Add(scope);
            var remove = new Button { Content = "移除", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, $"移除「{title}」");
            remove.Click += (_, _) => Store(current =>
                current.Where(item => !string.Equals(item.Exe, exe, StringComparison.OrdinalIgnoreCase)).ToList());
            Grid.SetColumn(remove, 3);
            row.Children.Add(remove);
            list.Children.Add(row);
        }

        _content.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6),
            Background = Theme.CardBackground(),
            Child = list,
        });

        void Add(string exePath)
        {
            var name = Path.GetFileName(exePath);
            if (HotKeyBlock.Parse(name) is null)
            {
                return;
            }

            Store(current =>
            {
                if (!current.Any(item => string.Equals(item.Exe, name, StringComparison.OrdinalIgnoreCase)))
                {
                    current.Add(new HotKeyBlock(name));
                }

                return current;
            });
        }

        var choose = new DropDownButton { Content = "选择应用…" };
        var chooser = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
        var runningMenu = new MenuFlyoutSubItem { Text = "正在运行的程序" };
        foreach (var (path, name) in running.Take(40))
        {
            var item = new MenuFlyoutItem { Text = name };
            item.Click += (_, _) => Add(path);
            runningMenu.Items.Add(item);
        }

        if (runningMenu.Items.Count == 0)
        {
            runningMenu.Items.Add(new MenuFlyoutItem { Text = "（没有找到）", IsEnabled = false });
        }

        chooser.Items.Add(runningMenu);
        var browse = new MenuFlyoutItem { Text = "浏览 exe…" };
        browse.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(".exe");
            var file = await picker.PickSingleFileAsync();
            if (file is not null && !string.IsNullOrEmpty(file.Path))
            {
                Add(file.Path);
            }
        };
        chooser.Items.Add(browse);
        choose.Flyout = chooser;
        _content.Children.Add(choose);
        _content.Children.Add(SettingsUi.Footnote(
            "名单里的应用在前台时，上面的快捷键不响应，按键交给那个应用。也可以在那个应用里打开托盘菜单，从菜单里停用。"));

        AddToggle("全屏游戏时停用快捷键", "独占全屏的游戏和演示模式里不响应快捷键；全屏看视频、F11 的网页不算。无边框全屏的游戏认不出来，要的话加进上面的名单",
            settings.HotKeyBlockFullscreen,
            isOn =>
            {
                SettingsService.Current.HotKeyBlockFullscreen = isOn;
                SettingsService.Save();
            });
    }
}
