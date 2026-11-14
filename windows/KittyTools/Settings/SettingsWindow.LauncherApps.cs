// 设置 › 启动器 › 应用（PLAN-v18 L5 + §6 A3 A4 A5，D10「同一页」）：三块——
// 应用别名（给一个应用起个短词，输完整的别名时它排第一；键是 aumid: / exe:，App 更新、快捷方式挪位置照样认）；
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
        var back = new HyperlinkButton { Content = "‹ 启动器", Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => OpenLauncherSubpage(null);
        AutomationProperties.SetName(back, "返回启动器设置");
        _content.Children.Add(back);
        _content.Children.Add(Header("应用", "应用别名、便携软件的文件夹、隐藏的应用"));
        var apps = AppCatalog.Instance?.Apps ?? Array.Empty<LauncherItem>();

        // ---- 应用别名
        _content.Children.Add(SettingsUi.Section("应用别名"));
        var aliases = new Dictionary<string, string>(settings.LauncherAppAliases ?? new Dictionary<string, string>());
        var list = new StackPanel { Spacing = 2 };
        void Store()
        {
            var kept = aliases.Where(pair => AppAliases.Normalized(pair.Value).Length > 0).ToDictionary(pair => pair.Key, pair => pair.Value);
            settings.LauncherAppAliases = kept.Count == 0 ? null : kept;
            SettingsService.Save();
        }

        void AddRow(string key, bool focus)
        {
            var app = apps.FirstOrDefault(item => item.AliasKey == key);
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var title = new TextBlock { Text = app?.Title ?? "（这台电脑上没有）", TextTrimming = TextTrimming.CharacterEllipsis };
            if (app is null)
            {
                title.Foreground = Theme.SecondaryText();
            }

            names.Children.Add(title);
            names.Children.Add(new TextBlock { Text = key.StartsWith("aumid:", StringComparison.Ordinal) ? "商店应用" : key[4..], FontSize = 11, Foreground = Theme.SecondaryText(), TextTrimming = TextTrimming.CharacterEllipsis });
            row.Children.Add(names);
            var alias = new TextBox { Text = aliases.GetValueOrDefault(key) ?? string.Empty, PlaceholderText = "别名", MaxLength = AppAliases.AliasLimit, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(alias, $"「{app?.Title ?? key}」的别名");
            alias.TextChanged += (_, _) =>
            {
                aliases[key] = alias.Text;
                Store();
            };
            Grid.SetColumn(alias, 1);
            row.Children.Add(alias);
            var remove = new Button { Content = "移除", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
            remove.Click += (_, _) =>
            {
                aliases.Remove(key);
                Store();
                list.Children.Remove(row);
            };
            Grid.SetColumn(remove, 2);
            row.Children.Add(remove);
            list.Children.Add(row);
            if (focus)
            {
                alias.Loaded += (_, _) => alias.Focus(FocusState.Programmatic);
            }
        }

        foreach (var key in aliases.Keys)
        {
            AddRow(key, focus: false);
        }

        _content.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6), Background = Theme.CardBackground(), Child = list });
        var pick = new AutoSuggestBox { PlaceholderText = "搜应用名，给它起个别名", QueryIcon = new SymbolIcon(Symbol.Add) };
        AutomationProperties.SetName(pick, "添加应用别名");
        pick.TextChanged += (sender, args) =>
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
            {
                return;
            }

            var folded = LauncherMatch.Fold(sender.Text);
            sender.ItemsSource = folded.Length == 0
                ? null
                : apps.Where(app => app.AliasKey is not null && (LauncherMatch.Fold(app.Title).Contains(folded, StringComparison.Ordinal) ||
                                                                   app.Names.Any(name => name.StartsWith(folded, StringComparison.Ordinal))))
                    .Take(12)
                    .Select(app => app.Title)
                    .ToList();
        };
        pick.SuggestionChosen += (sender, args) =>
        {
            if (args.SelectedItem is string title && apps.FirstOrDefault(app => app.Title == title && app.AliasKey is not null) is { AliasKey: { } key } &&
                !aliases.ContainsKey(key))
            {
                aliases[key] = string.Empty;
                AddRow(key, focus: true);
            }

            sender.Text = string.Empty;
        };
        _content.Children.Add(pick);
        _content.Children.Add(SettingsUi.Footnote("输完整的别名时那个应用排第一（「vs」→ Visual Studio Code）。认的是应用本身，更新、挪了快捷方式照样认；跟着设置导出导入。"));

        // ---- 应用文件夹
        _content.Children.Add(SettingsUi.Section("应用文件夹"));
        AddToggle("把运行过的程序也列出来", "在资源管理器里双击运行过的程序（便携软件）也能搜到；读的是 Windows 记的运行记录，只在这台电脑上",
            settings.LauncherRecentPrograms, isOn =>
            {
                settings.LauncherRecentPrograms = isOn;
                SettingsService.Save();
                AppCatalog.Instance?.Rescan();
            });
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
