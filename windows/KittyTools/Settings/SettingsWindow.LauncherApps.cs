// 设置 › 启动器 › 应用（PLAN-v18 L5 + §6 A3 A4 A5，D10「同一页」）：三块——
// 应用别名（PLAN-v27 B6 起照 mac 列出装着的应用、每行一个别名框，能起几个别名；输完整的别名时它排第一；
// 键是 aumid: / exe:，App 更新、快捷方式挪位置照样认）；
// 应用文件夹（「把运行过的程序也列出来」开关 + 用户加的文件夹和单个程序，文件夹往下扫两层；不在了的灰着写「找不到」，不删）；
// 隐藏的应用（启动器里「从启动器里隐藏」的，能恢复）。改了文件夹 / 隐藏 / 开关就重扫应用。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    /// <summary>应用别名那一块的筛选框（截图自检用，FilterAppsForProbe）。</summary>
    private TextBox? _appsFilterForProbe;

    /// <summary>启动器页「应用」那一行的小字。</summary>
    private static string AppsSummary(Settings settings)
    {
        var parts = new List<string>();
        if (settings.LauncherAppAliases is { Count: > 0 } aliases)
        {
            parts.Add($"{aliases.Count} 个别名");
        }

        if (settings.LauncherAppFolders is { Count: > 0 } folders)
        {
            parts.Add($"{folders.Count} 个文件夹或程序");
        }

        if (settings.LauncherHiddenApps is { Count: > 0 } hidden)
        {
            parts.Add($"隐藏了 {hidden.Count} 个");
        }

        return parts.Count == 0 ? "应用别名、便携软件的文件夹、隐藏的应用" : string.Join("，", parts);
    }

    private void BuildLauncherApps()
    {
        var settings = SettingsService.Current;
        _content.Children.Add(SettingsUi.BackButton("启动器", "返回启动器设置", () => OpenLauncherSubpage(null)));
        _content.Children.Add(Header("应用", "应用别名、便携软件的文件夹、隐藏的应用"));
        var apps = AppCatalog.Instance?.Apps ?? Array.Empty<LauncherItem>();

        // ---- 应用别名（PLAN-v27 B6，照 mac AppAliasesPage）：列出装着的应用，每行一个别名框；上面的框按名字或别名筛。
        // 以前是一个搜索框，打了字才在下拉里出几个、点 + 没反应（「应用别名不列出装的应用」）。
        // 行多（几百个）：先出页面，行在空闲时 40 个一批往下补；筛选只换显隐，不重建。
        // ponytail: 不画图标、不虚拟化；上千个应用嫌慢再换 ItemsRepeater。
        _content.Children.Add(SettingsUi.Section("应用别名"));
        var aliases = new Dictionary<string, string>(settings.LauncherAppAliases ?? new Dictionary<string, string>());
        void Store()
        {
            var kept = aliases.Where(pair => AppAliases.Words(pair.Value).Count > 0).ToDictionary(pair => pair.Key, pair => pair.Value);
            settings.LauncherAppAliases = kept.Count == 0 ? null : kept;
            SettingsService.Save();
        }

        // 同一个键（同一个 exe 的开始菜单、桌面两个快捷方式）只列一行；起过别名、这台电脑上没有的排最前面，能清掉
        var installed = apps.Where(app => app.Kind == LauncherKind.App && app.AliasKey is not null)
            .GroupBy(app => app.AliasKey!)
            .Select(group => group.First())
            .OrderBy(app => app.Title, StringComparer.CurrentCulture)
            .ToList();
        // 应用还没读出来时不列「这台电脑上没有」（没得比）；别名都还在设置里，读完重画这一页
        var missing = installed.Count == 0 ? new List<string>() : aliases.Keys.Where(key => installed.All(app => app.AliasKey != key)).ToList();
        var filter = new TextBox { PlaceholderText = "按应用名或别名找" };
        AutomationProperties.SetName(filter, "搜索应用");
        _appsFilterForProbe = filter;
        _content.Children.Add(filter);
        _content.Children.Add(SettingsUi.Footnote("多个别名用逗号隔开，例如 wx, 聊天。原来的名字照样能搜，清空就是去掉别名。"));
        var list = new StackPanel { Spacing = 2 };
        var empty = new TextBlock { Foreground = Theme.SecondaryText(), Margin = new Thickness(4), TextWrapping = TextWrapping.Wrap };
        list.Children.Add(empty);
        var rows = new List<(LauncherItem? App, string Key, FrameworkElement Row)>();

        bool Shows(LauncherItem? app, string key)
        {
            var query = LauncherMatch.Fold(filter.Text.Trim());
            return query.Length == 0 ||
                   (app is not null && LauncherMatch.Score(query, app) > 0) ||
                   LauncherMatch.Fold(aliases.GetValueOrDefault(key) ?? string.Empty).Contains(query, StringComparison.Ordinal);
        }

        void UpdateEmpty()
        {
            var any = missing.Any(key => Shows(null, key)) || installed.Any(app => Shows(app, app.AliasKey!));
            empty.Text = installed.Count == 0
                ? AppCatalog.Instance?.HasScanned == false ? "正在读取应用…" : "没有找到装着的应用"
                : any ? string.Empty : "没有匹配的应用，试试别的名字或别名";
            empty.Visibility = empty.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }

        FrameworkElement Row(LauncherItem? app, string key)
        {
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var title = new TextBlock { Text = app?.Title ?? "（这台电脑上没有）", TextTrimming = TextTrimming.CharacterEllipsis };
            if (app is null)
            {
                title.Foreground = Theme.SecondaryText();
            }

            names.Children.Add(title);
            // 同一个 exe、参数不同的那几个，键是「exe:路径|参数」：显示成命令行的样子（路径 空格 参数）
            var place = key.StartsWith("aumid:", StringComparison.Ordinal) ? "商店应用" : key[4..].Replace('|', ' ');
            names.Children.Add(new TextBlock { Text = place, FontSize = 11, Foreground = Theme.SecondaryText(), TextTrimming = TextTrimming.CharacterEllipsis });
            ToolTipService.SetToolTip(names, app?.Target ?? key);
            row.Children.Add(names);
            var alias = new TextBox
            {
                Text = aliases.GetValueOrDefault(key) ?? string.Empty,
                PlaceholderText = "添加别名",
                MaxLength = AppAliases.EntryLimit,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(alias, $"「{app?.Title ?? key}」的别名");
            alias.TextChanged += (_, _) =>
            {
                aliases[key] = alias.Text;
                Store();
            };
            Grid.SetColumn(alias, 1);
            row.Children.Add(alias);
            row.Visibility = Shows(app, key) ? Visibility.Visible : Visibility.Collapsed;
            return row;
        }

        var pending = missing.Select(key => ((LauncherItem?)null, key))
            .Concat(installed.Select(app => ((LauncherItem?)app, app.AliasKey!)))
            .ToList();
        var next = 0;
        // 第一批 40 行建好、全部补完各用了多久（R115 第 5 步：几百个应用时第一屏超过 300 ms 就把每批改小）
        var built = System.Diagnostics.Stopwatch.StartNew();
        void More()
        {
            // 换了页（行所在的卡片不在页上了）就不补了
            if (list.XamlRoot is null && next > 0)
            {
                return;
            }

            for (var count = 0; count < 40 && next < pending.Count; count++, next++)
            {
                var (app, key) = pending[next];
                var row = Row(app, key);
                rows.Add((app, key, row));
                list.Children.Add(row);
            }

            if (next <= 40 || next == pending.Count)
            {
                Log.Info($"settings.apps-rows {(next == pending.Count ? "all" : "first")}={built.ElapsedMilliseconds}ms rows={next}/{pending.Count}");
            }

            if (next < pending.Count)
            {
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, More);
            }
        }

        filter.TextChanged += (_, _) =>
        {
            foreach (var (app, key, row) in rows)
            {
                row.Visibility = Shows(app, key) ? Visibility.Visible : Visibility.Collapsed;
            }

            UpdateEmpty();
        };
        UpdateEmpty();
        More();
        _content.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6), Background = Theme.CardBackground(), Child = list });
        _content.Children.Add(SettingsUi.Footnote("输完整的别名时那个应用排第一（「vs」→ Visual Studio Code）。认的是应用本身，更新、挪了快捷方式照样认；跟着设置导出导入。每个应用最多 256 字。"));

        // 还没扫过（刚装、第一次开）：扫完重画这一页；扫过的照旧用手上这份，顺手看要不要重扫（下次进来用新的）
        if (AppCatalog.Instance is { } catalog)
        {
            if (installed.Count == 0)
            {
                void Reload()
                {
                    catalog.Changed -= Reload;
                    if (_currentPage == "launcher" && _launcherSubpage == "apps")
                    {
                        BuildPage("launcher");
                    }
                }

                catalog.Changed += Reload;
            }

            catalog.RefreshIfStale();
        }

        // ---- 应用文件夹
        _content.Children.Add(SettingsUi.Section("应用文件夹"));
        AddToggle("把运行过的程序也列出来", "双击运行过的便携软件也能搜到",
            settings.LauncherRecentPrograms, isOn =>
            {
                settings.LauncherRecentPrograms = isOn;
                SettingsService.Save();
                AppCatalog.Instance?.Rescan();
            }, "在资源管理器里双击运行过的程序也列进来；读的是 Windows 记的运行记录，只在这台电脑上。");
        var folders = settings.LauncherAppFolders ?? new List<string>();
        var folderList = new StackPanel { Spacing = 2 };
        if (folders.Count == 0)
        {
            folderList.Children.Add(new TextBlock { Text = "还没有加文件夹或程序", Foreground = Theme.SecondaryText(), Margin = new Thickness(4) });
        }

        void StoreFolders(List<string> updated)
        {
            settings.LauncherAppFolders = updated.Count == 0 ? null : updated;
            SettingsService.Save();
            AppCatalog.Instance?.Rescan();
            BuildPage("launcher");
        }

        foreach (var path in folders.ToList())
        {
            var exists = Directory.Exists(path) || File.Exists(path);
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var pathText = new TextBlock { Text = path, TextTrimming = TextTrimming.CharacterEllipsis };
            if (!exists)
            {
                pathText.Foreground = Theme.SecondaryText();
            }

            names.Children.Add(pathText);
            names.Children.Add(new TextBlock
            {
                Text = exists ? (File.Exists(path) ? "单个程序" : "文件夹（往下两层）") : "找不到",
                FontSize = 11,
                Foreground = Theme.SecondaryText(),
            });
            row.Children.Add(names);
            var remove = new Button { Content = "移除", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
            var target = path;
            remove.Click += (_, _) => StoreFolders(folders.Where(item => !string.Equals(item, target, StringComparison.OrdinalIgnoreCase)).ToList());
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            folderList.Children.Add(row);
        }

        _content.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6), Background = Theme.CardBackground(), Child = folderList });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var addFolder = new Button { Content = "添加文件夹…" };
        addFolder.Click += async (_, _) =>
        {
            var picker = new FolderPicker(AppWindow.Id);
            if (await picker.PickSingleFolderAsync() is { Path: { Length: > 0 } chosen } &&
                !folders.Contains(chosen, StringComparer.OrdinalIgnoreCase))
            {
                StoreFolders(folders.Append(chosen).ToList());
            }
        };
        var addProgram = new Button { Content = "添加程序…" };
        addProgram.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(".exe");
            picker.FileTypeFilter.Add(".lnk");
            if (await picker.PickSingleFileAsync() is { Path: { Length: > 0 } chosen } &&
                !folders.Contains(chosen, StringComparer.OrdinalIgnoreCase))
            {
                StoreFolders(folders.Append(chosen).ToList());
            }
        };
        buttons.Children.Add(addFolder);
        buttons.Children.Add(addProgram);
        _content.Children.Add(buttons);
        _content.Children.Add(SettingsUi.Footnote("便携软件放在哪就加哪个文件夹（往下扫两层，每个文件夹最多 500 个）；卸载、安装、更新这类程序不收。"));

        // ---- 隐藏的应用
        _content.Children.Add(SettingsUi.Section("隐藏的应用"));
        var hidden = settings.LauncherHiddenApps ?? new List<string>();
        var hiddenList = new StackPanel { Spacing = 2 };
        if (hidden.Count == 0)
        {
            hiddenList.Children.Add(new TextBlock { Text = "没有隐藏的应用（启动器里 Ctrl+K「从启动器里隐藏」）", Foreground = Theme.SecondaryText(), Margin = new Thickness(4) });
        }

        foreach (var target in hidden.ToList())
        {
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = target.StartsWith(@"shell:AppsFolder\", StringComparison.OrdinalIgnoreCase)
                ? target[@"shell:AppsFolder\".Length..]
                : Path.GetFileNameWithoutExtension(target);
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            names.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
            names.Children.Add(new TextBlock { Text = target, FontSize = 11, Foreground = Theme.SecondaryText(), TextTrimming = TextTrimming.CharacterEllipsis });
            row.Children.Add(names);
            var restore = new Button { Content = "恢复", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
            var current = target;
            restore.Click += (_, _) =>
            {
                var updated = hidden.Where(item => !string.Equals(item, current, StringComparison.OrdinalIgnoreCase)).ToList();
                settings.LauncherHiddenApps = updated.Count == 0 ? null : updated;
                SettingsService.Save();
                AppCatalog.Instance?.Rescan();
                BuildPage("launcher");
            };
            Grid.SetColumn(restore, 1);
            row.Children.Add(restore);
            hiddenList.Children.Add(row);
        }

        _content.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6), Background = Theme.CardBackground(), Child = hiddenList });
    }
}
