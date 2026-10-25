// 设置窗：左侧 NavigationView（带图标），右边每页一个大标题 + 一组组设置卡，Mica。
// AOT 下 NavigationView 崩溃的根因（发布目录缺 PRI）第二版第 2 批已经修好，这一批换回 NavigationView（PLAN-v2 §2b / §3.4）。
using System.Diagnostics;
using System.Text.Json;
using KittyTools.Infrastructure;
using KittyTools.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using Windows.Win32;

namespace KittyTools;

internal sealed class SettingsWindow : Window
{
    // ponytail: R13 修完、集成测试过了改成 true（同步页的开关）。
    private static readonly bool SyncUiVisible = false;

    private readonly Grid _shell;
    private readonly NavigationView _nav;
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _content;
    private readonly InfoBar _hotKeyError;
    private readonly Windows.Win32.Foundation.HWND _hwnd;
    private readonly int _width;
    private readonly int _height;

    private bool _firstRun;
    private bool _suppressNav;
    private string _currentPage = "general";
    private string? _recordingAction;
    private TextBlock? _recordHint;

    private static readonly (string Tag, string Title, string Glyph)[] Pages =
    {
        ("general", "通用", "\uE713"),
        ("hotkeys", "快捷键", "\uE765"),
        ("clipboard", "剪贴板", "\uE8C8"),
        ("translate", "翻译", "\uE774"),
        ("launcher", "启动器", "\uE721"),
        ("screenshot", "截图", "\uE722"),
        ("about", "关于", "\uE946"),
    };

    public SettingsWindow()
    {
        Title = Paths.ProductName + " 设置";
        _content = new StackPanel { Spacing = 8, Margin = new Thickness(0, 0, 8, 0) };
        _scroll = new ScrollViewer
        {
            Content = _content,
            Padding = new Thickness(36, 20, 24, 32),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        _nav = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsSettingsVisible = false,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsPaneToggleButtonVisible = false,
            IsTitleBarAutoPaddingEnabled = false,
            OpenPaneLength = 208,
            PaneTitle = "Kitty Tools",
            Content = _scroll,
            RequestedTheme = Theme.ElementTheme,
        };
        foreach (var (tag, title, glyph) in Pages)
        {
            _nav.MenuItems.Add(new NavigationViewItem
            {
                Content = title,
                Tag = tag,
                Icon = new FontIcon { Glyph = glyph },
            });
        }

        _nav.SelectionChanged += (_, args) =>
        {
            if (_suppressNav)
            {
                return;
            }

            if (args.SelectedItemContainer?.Tag is string tag)
            {
                BuildPage(tag);
            }
        };

        _shell = new Grid { RequestedTheme = Theme.ElementTheme };
        _shell.Children.Add(_nav);

        _hotKeyError = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            IsOpen = false,
            IsClosable = true,
        };
        _shell.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnRecordKeyDown), handledEventsToo: true);

        Content = _shell;
        SystemBackdrop = new MicaThemeBackdrop();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _hwnd = (Windows.Win32.Foundation.HWND)hwnd;
        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        _width = (int)Math.Round(980 * scale);
        _height = (int)Math.Round(720 * scale);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(_width, _height));
        AppWindow.SetIcon(Paths.ExecutablePath);
        Theme.ApplyTitleBar(AppWindow);

        BuildPage("general");
        Closed += (_, _) =>
        {
            IsClosed = true;
            Log.Info("settings.closed");
        };
    }

    public bool IsClosed { get; private set; }

    public void ShowPage(bool welcome, string page = "general")
    {
        Motion.Refresh();
        _firstRun = welcome;
        BuildPage(page);
        Log.Info($"settings.page {page}");
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Restore();
        }

        Activate();
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + Math.Max(0, (area.Width - _width) / 2),
            area.Y + Math.Max(0, (area.Height - _height) / 2)));
        Foreground.Restore(_hwnd);
        // 焦点给内容区，不落在左栏第一项上（REVIEW R10：鼠标打开时不该有焦点框）。
        _scroll.Focus(FocusState.Programmatic);
        Log.Info($"settings.show firstRun={welcome}");
    }

    public void RefreshTheme()
    {
        _nav.RequestedTheme = Theme.ElementTheme;
        Theme.ApplyTitleBar(AppWindow);
        if (_recordingAction is null)
        {
            BuildPage(_currentPage);
        }
    }

    private void BuildPage(string page)
    {
        Log.Info($"settings.build {page}");
        _currentPage = page;
        _content.Children.Clear();
        switch (page)
        {
            case "hotkeys":
                BuildHotKeys();
                break;
            case "clipboard":
                BuildClipboard();
                break;
            case "translate":
                BuildTranslate();
                break;
            case "launcher":
                BuildLauncher();
                break;
            case "screenshot":
                BuildScreenshot();
                break;
            case "about":
                BuildAbout();
                break;
            default:
                BuildGeneral();
                break;
        }

        UpdateNavSelection();
    }

    private void UpdateNavSelection()
    {
        var item = _nav.MenuItems.OfType<NavigationViewItem>()
            .FirstOrDefault(candidate => string.Equals(candidate.Tag as string, _currentPage, StringComparison.Ordinal));
        if (item is not null && !ReferenceEquals(_nav.SelectedItem, item))
        {
            _suppressNav = true;
            _nav.SelectedItem = item;
            _suppressNav = false;
        }
    }

    private void BuildGeneral()
    {
        _content.Children.Add(Header("通用", "启动、外观和更新。"));
        if (_firstRun)
        {
            _content.Children.Add(BuildWelcome());
        }

        AddToggle("登录时自动打开",
            "开机后在托盘里运行，快捷键随时可用。",
            SettingsService.Current.StartWithWindows,
            isOn =>
            {
                if (!Autostart.Set(isOn))
                {
                    NoticeHost.Show("没能写入开机启动", "注册表 Run 项写入失败", NoticeTone.Error);
                    return;
                }

                SettingsService.Current.StartWithWindows = isOn;
                SettingsService.Save();
            });

        AddCombo("外观", "跟随系统 / 浅色 / 深色。",
            new[] { "跟随系统", "浅色", "深色" },
            SettingsService.Current.Theme switch { "light" => 1, "dark" => 2, _ => 0 },
            index =>
            {
                SettingsService.Current.Theme = index switch { 1 => "light", 2 => "dark", _ => "system" };
                SettingsService.Save();
                Theme.ApplyTo(_shell);
                _nav.RequestedTheme = Theme.ElementTheme;
                BuildPage(_currentPage);
            });

        AddCombo("强调色", "品牌粉，或者跟随系统的强调色。",
            new[] { "品牌粉", "跟随系统" },
            SettingsService.Current.Accent == "system" ? 1 : 0,
            index =>
            {
                SettingsService.Current.Accent = index == 1 ? "system" : "brand";
                SettingsService.Save();
                Theme.ApplyAccent();
                BuildPage(_currentPage);
            });

        AddToggle("自动检查更新", "每天检查一次，有新版本时提示。",
            SettingsService.Current.AutoCheckUpdates,
            isOn =>
            {
                SettingsService.Current.AutoCheckUpdates = isOn;
                SettingsService.Save();
            });

        _content.Children.Add(SettingsUi.Section(
            "功能", "用不着的整个关掉：它的热键、托盘菜单项和后台工作一起停；数据和设置都留着。"));
        foreach (var feature in Enum.GetValues<Feature>())
        {
            AddToggle(
                Features.Title(feature),
                Features.Blurb(feature),
                Features.IsOn(feature),
                isOn =>
                {
                    Features.Set(feature, isOn);
                    BuildPage(_currentPage);
                });
        }

        var dataButton = SettingsUi.Card(
            "\uE8B7",
            "数据目录",
            "数据库、图片、日志和设置都放在这里。",
            null,
            OpenDataDirectory);
        _content.Children.Add(dataButton);

        BuildSyncSection();

        _content.Children.Add(SettingsUi.Section(
            "导出与导入", "换电脑、重装或备份时用。密钥默认不带；片段、收藏、生词本是合并，不会删本机已有的。"));
        _content.Children.Add(SettingsUi.Card(
            "\uE896",
            "导出…",
            "把设置、翻译服务、网页搜索、片段与收藏存成一个文件；要带密钥就设一个密码。",
            null,
            () => _ = ExportArchiveAsync()));
        _content.Children.Add(SettingsUi.Card(
            "\uE8B5",
            "导入…",
            "从 Kitty Tools 导出的文件导回来；导入前会先自动备份一次现在的数据。",
            null,
            () => _ = ImportArchiveAsync()));
    }

    /// <summary>导出：按类别勾选，可选密码（第三版 §2.2）。</summary>
    private async Task ExportArchiveAsync()
    {
        try
        {
            var checks = new Dictionary<ArchiveSection, CheckBox>();
            var panel = new StackPanel { Spacing = 8, MinWidth = 360 };
            foreach (var section in Enum.GetValues<ArchiveSection>())
            {
                var check = new CheckBox
                {
                    Content = SectionTitle(section),
                    IsChecked = true,
                };
                checks[section] = check;
                panel.Children.Add(check);
            }

            var password = new PasswordBox
            {
                Header = "给密钥设个密码（可以不填）",
                PlaceholderText = "至少 8 位；留空就不带密钥",
            };
            panel.Children.Add(password);
            panel.Children.Add(new TextBlock
            {
                Text = "密钥会用这个密码加密；Mac 和 Windows 两边都能解开。密码丢了就解不回来。",
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.SecondaryText(),
            });

            var dialog = new ContentDialog
            {
                Title = "导出",
                PrimaryButtonText = "选择文件…",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
                Content = panel,
                XamlRoot = _shell.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            var selected = checks.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key).ToList();
            var secret = password.Password;
            if (secret.Length is > 0 and < SettingsArchive.MinPasswordLength)
            {
                NoticeHost.Show("密码太短", "至少 8 位", NoticeTone.Warning);
                return;
            }

            var picker = new FileSavePicker(AppWindow.Id)
            {
                SuggestedFileName = $"Kitty Tools 设置 {DateTime.Now:yyyy-MM-dd}",
                DefaultFileExtension = ".json",
            };
            picker.FileTypeChoices.Add("JSON 文件", new List<string> { ".json" });
            var file = await picker.PickSaveFileAsync();
            if (file is null || string.IsNullOrEmpty(file.Path))
            {
                return;
            }

            var archive = ArchiveService.Build(selected, secret.Length > 0 ? secret : null);
            if (ArchiveService.WriteFile(file.Path, archive) is null)
            {
                NoticeHost.Show("没能导出", "文件写不进去，或者内容超过了上限", NoticeTone.Error);
                return;
            }

            NoticeHost.Show(
                "已导出", archive.Secrets is null ? "文件里没有密钥" : "密钥已用密码加密", NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("settings.export-failed", ex);
            NoticeHost.Show("没能导出", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>导入：读文件 → 需要时问密码 → 先自动备份 → 合并进本机（第三版 §2.2）。</summary>
    private async Task ImportArchiveAsync()
    {
        try
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(".json");
            var file = await picker.PickSingleFileAsync();
            if (file is null || string.IsNullOrEmpty(file.Path))
            {
                return;
            }

            var info = new FileInfo(file.Path);
            if (!info.Exists || info.Length > SettingsArchive.MaxFileBytes)
            {
                NoticeHost.Show("文件太大", "导出文件最多 32 MB", NoticeTone.Warning);
                return;
            }

            var archive = ArchiveService.Decode(await File.ReadAllTextAsync(file.Path));
            if (archive is null)
            {
                NoticeHost.Show("这不是 Kitty Tools 导出的设置文件", "换一个文件试试", NoticeTone.Error);
                return;
            }

            string? password = null;
            if (archive.Secrets is not null)
            {
                var box = new PasswordBox { Header = "这个文件带了加密的密钥，输入密码（不导密钥就留空）" };
                var dialog = new ContentDialog
                {
                    Title = "导入",
                    PrimaryButtonText = "导入",
                    CloseButtonText = "取消",
                    DefaultButton = ContentDialogButton.Primary,
                    Content = box,
                    XamlRoot = _shell.XamlRoot,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary)
                {
                    return;
                }

                password = box.Password;
            }

            if (ArchiveService.BackupBeforeImport() is null)
            {
                NoticeHost.Show("没能先备份现在的数据", "所以没有导入", NoticeTone.Error);
                return;
            }

            var (outcome, error) = ArchiveService.Apply(archive, password);
            if (error is not null)
            {
                NoticeHost.Show("导入没成功", error, NoticeTone.Error);
                return;
            }

            NoticeHost.Show(
                "已导入",
                $"片段 {outcome.ClipsAdded} 条、收藏 {outcome.ClipsUpdated} 条、生词 {outcome.WordsAdded} 条、" +
                $"服务 {outcome.ServicesAdded} 个、搜索 {outcome.EnginesAdded} 个、密钥 {outcome.Secrets} 个",
                NoticeTone.Normal);
            BuildPage("general");
        }
        catch (Exception ex)
        {
            Log.Error("settings.import-failed", ex);
            NoticeHost.Show("没能导入", ex.GetType().Name, NoticeTone.Error);
        }
    }

    /// <summary>设置 › 通用 › 同步（PLAN-v5 §4.4）：文件夹、状态、四类、别的电脑、立即同步 / 停止。</summary>
    private void BuildSyncSection()
    {
        // ponytail: R13（P0）没修完之前先把这一节藏起来：合并规则还在换（参考 windows/reference/mac-sync），
        // 0.5.0 不能给用户装来同步。接好 SyncEngine、集成测试过了就删掉这个开关。
        if (!SyncUiVisible)
        {
            return;
        }

        var settings = SettingsService.Current;
        _content.Children.Add(SettingsUi.Section(
            "同步", "和 Mac 版（0.7.0 或更新）共用一个同步盘文件夹，互通片段与收藏、生词本、网页搜索和翻译服务。密钥不同步。"));
        AddToggle("开启同步", "每 20 秒一轮，睡眠唤醒时也合一次。",
            settings.SyncEnabled,
            isOn =>
            {
                settings.SyncEnabled = isOn;
                SettingsService.Save();
                if (isOn)
                {
                    if (string.IsNullOrEmpty(settings.SyncFolder))
                    {
                        _ = PickSyncFolderAsync();
                    }
                    else
                    {
                        _ = Syncer.Instance?.RoundAsync();
                    }
                }

                BuildPage("general");
            });

        var folder = string.IsNullOrEmpty(settings.SyncFolder) ? "还没选文件夹" : settings.SyncFolder;
        var status = Syncer.Instance?.Status;
        var statusText = status is null
            ? string.Empty
            : status.State switch
            {
                "syncing" => "正在同步…",
                "idle" => "好了" + (status.LastSync > 0
                    ? "（上次 " + DateTimeOffset.FromUnixTimeMilliseconds(status.LastSync).ToLocalTime()
                        .ToString("HH:mm") + "）"
                    : string.Empty),
                "confirm" => status.Message,
                "stopped" => "停了：" + status.Message,
                _ => "关着",
            };
        _content.Children.Add(SettingsUi.Card(
            "\uE8F7",
            "同步文件夹",
            folder + (statusText.Length > 0 ? "\n" + statusText : string.Empty),
            null,
            () => _ = PickSyncFolderAsync()));

        AddToggle("片段与收藏", "只同步文字里收藏 / 片段的条目和收藏夹。", settings.SyncClips,
            value => { settings.SyncClips = value; SettingsService.Save(); });
        AddToggle("生词本", "收藏的翻译。", settings.SyncVocabulary,
            value => { settings.SyncVocabulary = value; SettingsService.Save(); });
        AddToggle("网页搜索与快捷链接", string.Empty, settings.SyncEngines,
            value => { settings.SyncEngines = value; SettingsService.Save(); });
        AddToggle("翻译服务", "只同步服务配置，密钥每台自己填。", settings.SyncServices,
            value => { settings.SyncServices = value; SettingsService.Save(); });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var syncNow = new Button { Content = "立即同步" };
        syncNow.Click += (_, _) =>
        {
            _ = Syncer.Instance?.RoundAsync();
            NoticeHost.Show("同步", "开始同步…", NoticeTone.Normal);
        };
        row.Children.Add(syncNow);
        var stop = new Button { Content = "停止同步" };
        stop.Click += (_, _) =>
        {
            settings.SyncEnabled = false;
            SettingsService.Save();
            BuildPage("general");
        };
        row.Children.Add(stop);
        _content.Children.Add(row);

        if (status is { Devices.Count: > 0 })
        {
            _content.Children.Add(SettingsUi.Section(
                "别的电脑", string.Join("、", status.Devices)));
        }
    }

    private async Task PickSyncFolderAsync()
    {
        try
        {
            var picker = new FolderPicker(AppWindow.Id);
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null || string.IsNullOrEmpty(folder.Path))
            {
                return;
            }

            // 空文件夹才开（或者已经有我们的标记）；否则提示。
            var disk = new SyncFolder(folder.Path);
            if (disk.Marker() is null && disk.LooksForeign())
            {
                NoticeHost.Show("这个文件夹里已经有别的东西了", "请新建一个空文件夹来同步", NoticeTone.Warning);
                return;
            }

            SettingsService.Current.SyncFolder = folder.Path;
            SettingsService.Current.SyncEnabled = true;
            SettingsService.Save();
            _ = Syncer.Instance?.RoundAsync();
            BuildPage("general");
        }
        catch (Exception ex)
        {
            Log.Error("settings.sync-folder-failed", ex);
        }
    }

    /// <summary>导出全部历史或只有收藏；CSV 或 Anki 用的 TSV（第三版 §3.1）。</summary>
    private async Task ExportHistoryAsync()
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        try
        {
            var favoritesOnly = new CheckBox { Content = "只导出收藏（生词本）" };
            var format = new ComboBox
            {
                Header = "格式",
                Items = { "CSV（Excel 能打开）", "Anki TSV（正面 / 背面）" },
                SelectedIndex = 0,
                MinWidth = 220,
            };
            var panel = new StackPanel { Spacing = 8 };
            panel.Children.Add(format);
            panel.Children.Add(favoritesOnly);
            var dialog = new ContentDialog
            {
                Title = "导出历史",
                PrimaryButtonText = "导出…",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary,
                Content = panel,
                XamlRoot = _shell.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            var entries = history.Search(string.Empty, favoritesOnly.IsChecked == true, limit: 0);
            var rows = entries
                .Select(entry => new HistoryRow(
                    entry.Source, entry.Result, entry.TargetLang, entry.Service, entry.CreatedAt, entry.Favorite))
                .ToList();
            var tsv = format.SelectedIndex == 1;
            var temporary = Path.Combine(Path.GetTempPath(), "kitty-history.txt");
            await File.WriteAllTextAsync(
                temporary,
                tsv ? HistoryExport.AnkiTsv(rows) : HistoryExport.Csv(rows),
                new System.Text.UTF8Encoding(tsv));

            var picker = new FileSavePicker(AppWindow.Id)
            {
                SuggestedFileName = tsv ? "Kitty Tools 生词本" : "Kitty Tools 翻译历史",
                DefaultFileExtension = tsv ? ".txt" : ".csv",
            };
            picker.FileTypeChoices.Add(tsv ? "文本文件" : "CSV 文件",
                new List<string> { tsv ? ".txt" : ".csv" });
            var file = await picker.PickSaveFileAsync();
            if (file is null || string.IsNullOrEmpty(file.Path))
            {
                return;
            }

            File.Copy(temporary, file.Path, overwrite: true);
            NoticeHost.Show("已导出", $"{entries.Count} 条", NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Error("settings.history-export-failed", ex);
            NoticeHost.Show("没能导出", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static string SectionTitle(ArchiveSection section) => section switch
    {
        ArchiveSection.Preferences => "设置",
        ArchiveSection.Hotkeys => "快捷键",
        ArchiveSection.Services => "翻译服务",
        ArchiveSection.Engines => "网页搜索与快捷链接",
        ArchiveSection.Clips => "片段与收藏",
        _ => "生词本",
    };

    private Border BuildWelcome()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = "欢迎使用 Kitty Tools",
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "它会一直在托盘里运行。Windows 11 默认把新图标收进任务栏右下角的「^」溢出区，" +
                   "点开「^」找到 Kitty Tools，可以把它拖到任务栏上。\n\n" +
                   "默认快捷键：剪贴板 Alt+C、启动器 Alt+Space、划词翻译 Alt+E、输入翻译 Alt+T、" +
                   "截图翻译 Alt+S、截图 Alt+X、识字 Alt+O。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });

        var autostart = new CheckBox
        {
            Content = "登录时自动打开",
            IsChecked = SettingsService.Current.StartWithWindows,
        };
        panel.Children.Add(autostart);

        var start = new Button
        {
            Content = "开始使用",
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = Theme.Brush(
                "TextOnAccentFillColorPrimaryBrush",
                Windows.UI.Color.FromArgb(255, 255, 255, 255)),
        };
        start.Click += (_, _) =>
        {
            var enabled = autostart.IsChecked == true;
            SettingsService.Current.StartWithWindows = enabled;
            Autostart.Set(enabled);
            SettingsService.MarkStarted();
            _firstRun = false;
            BuildPage("general");
            NoticeHost.Show("可以开始了", "快捷键随时在托盘菜单里", NoticeTone.Normal);
        };
        panel.Children.Add(start);

        return Card(panel);
    }

    private void BuildClipboard()
    {
        if (!ShowIfDisabled(Feature.Clipboard))
        {
            return;
        }

        _content.Children.Add(Header("剪贴板", "记录文本、图片和文件；面板里按 Ctrl+D 收藏。收藏的条目不受保留天数和图片额度影响。"));
        var service = ClipboardService.Instance;
        if (service is null)
        {
            _content.Children.Add(new TextBlock
            {
                Text = "剪贴板数据库打不开，这一页暂时用不了。看看数据目录里的 kitty.sqlite3 是不是被占着。",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.75,
            });
            return;
        }

        AddToggle("暂停记录", "只在这次运行有效，重启后自动恢复记录。",
            service.Paused,
            isOn => service.Paused = isOn);

        var dayIndex = SettingsService.Current.ClipboardRetentionDays switch
        {
            1 => 0,
            7 => 1,
            30 => 2,
            90 => 3,
            365 => 4,
            _ => 5,
        };
        AddCombo("保留普通历史", "收藏的不清理；选「永久」就不按时间删。",
            new[] { "1 天", "7 天", "30 天", "90 天", "365 天", "永久" },
            dayIndex,
            index =>
            {
                SettingsService.Current.ClipboardRetentionDays = index switch
                {
                    0 => 1,
                    1 => 7,
                    2 => 30,
                    3 => 90,
                    4 => 365,
                    _ => 0,
                };
                SettingsService.Save();
                ReportCleanup(service.EnforceLimits());
            });

        var budgetIndex = SettingsService.Current.ClipboardImageBudgetMB switch
        {
            128 => 0,
            256 => 1,
            1024 => 3,
            0 => 4,
            _ => 2,
        };
        AddCombo("图片最多占用", "只算普通图片；超了从最旧的删起，最新的一张这一轮不删。",
            new[] { "128 MB", "256 MB", "512 MB", "1 GB", "不限" },
            budgetIndex,
            index =>
            {
                SettingsService.Current.ClipboardImageBudgetMB = index switch
                {
                    0 => 128,
                    1 => 256,
                    3 => 1024,
                    4 => 0,
                    _ => 512,
                };
                SettingsService.Save();
                ReportCleanup(service.EnforceLimits());
            });

        AddToggle("不记录疑似密钥和卡号", "看起来像 API Key、Bearer token、私钥或银行卡号的文本不记录。",
            SettingsService.Current.ClipboardBlockSensitive,
            isOn =>
            {
                SettingsService.Current.ClipboardBlockSensitive = isOn;
                SettingsService.Save();
            });

        AddToggle("链接预览", "选中「只有一个网址」的文本时，取网页标题、描述和头图（不访问本机 / 内网地址）。",
            SettingsService.Current.LinkPreviews,
            isOn =>
            {
                SettingsService.Current.LinkPreviews = isOn;
                SettingsService.Save();
                if (!isOn)
                {
                    LinkPreviewService.Clear();
                }
            });

        _content.Children.Add(Section("不记录的应用", "按 exe 名，不分大小写。密码管理器默认就在里面。"));

        foreach (var app in SettingsService.Current.ClipboardExcludedApps.ToList())
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = app,
                VerticalAlignment = VerticalAlignment.Center,
                FontFamily = new FontFamily("Consolas"),
            });
            var remove = new Button { Content = "移除", Padding = new Thickness(10, 2, 10, 2) };
            remove.Click += (_, _) =>
            {
                SettingsService.Current.ClipboardExcludedApps.RemoveAll(
                    value => string.Equals(value, app, StringComparison.OrdinalIgnoreCase));
                SettingsService.Save();
                BuildPage("clipboard");
            };
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            _content.Children.Add(row);
        }

        var addRow = new Grid { ColumnSpacing = 8 };
        addRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        addRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var input = new TextBox { PlaceholderText = "比如 WeChat.exe" };
        var add = new Button { Content = "添加" };
        add.Click += (_, _) =>
        {
            var name = input.Text.Trim();
            if (name.Length == 0)
            {
                return;
            }

            if (!name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                name += ".exe";
            }

            if (SettingsService.Current.ClipboardExcludedApps
                .Any(value => string.Equals(value, name, StringComparison.OrdinalIgnoreCase)))
            {
                return;
            }

            SettingsService.Current.ClipboardExcludedApps.Add(name);
            SettingsService.Save();
            BuildPage("clipboard");
        };
        Grid.SetColumn(add, 1);
        addRow.Children.Add(input);
        addRow.Children.Add(add);
        _content.Children.Add(addRow);

        _content.Children.Add(Section("占用",
            $"普通图片约 {service.Store.OrdinaryImageBytes / 1_048_576.0:F0} MB，共 {service.Store.Count} 条。"));

        var clear = new Button { Content = "立即清空普通历史" };
        var armed = false;
        clear.Click += (_, _) =>
        {
            if (!armed)
            {
                armed = true;
                clear.Content = "再点一次：清空（收藏保留）";
                return;
            }

            var removed = service.Store.ClearOrdinary();
            SettingsService.Save();
            NoticeHost.Show("已清空", $"删了 {removed} 条，收藏还在", NoticeTone.Normal);
            BuildPage("clipboard");
        };
        _content.Children.Add(clear);
    }

    private void BuildLauncher()
    {
        if (!ShowIfDisabled(Feature.Launcher))
        {
            return;
        }

        _content.Children.Add(Header("启动器", "应用、系统设置、系统命令、计算和网址直达；网页搜索只有一个兜底。"));
        var settings = SettingsService.Current;
        var engines = (settings.LauncherSearchEngines ?? WebSearch.Defaults())
            .Select(engine => new KittyTools.Core.SearchEngine
            {
                Id = engine.Id,
                Name = engine.Name,
                Keyword = engine.Keyword,
                UrlTemplate = engine.UrlTemplate,
                Fallback = engine.Fallback,
            })
            .ToList();

        void Persist()
        {
            settings.LauncherSearchEngines = engines;
            SettingsService.Save();
            BuildPage("launcher");
        }

        _content.Children.Add(Section("网页搜索", "有关键词的用「关键词 空格 内容」直达；勾「兜底」的只在没有本地结果时列在最后（只能有一个）。"));
        for (var index = 0; index < engines.Count; index++)
        {
            var engine = engines[index];
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var name = new StackPanel { Spacing = 1 };
            name.Children.Add(new TextBlock
            {
                Text = engine.Name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            name.Children.Add(new TextBlock
            {
                Text = string.IsNullOrEmpty(engine.Keyword) ? "无关键词" : engine.Keyword,
                FontSize = 11,
                Opacity = 0.6,
            });
            Grid.SetColumn(name, 0);
            row.Children.Add(name);

            var url = new TextBlock
            {
                Text = engine.UrlTemplate,
                FontSize = 11,
                Opacity = 0.7,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(url, 2);
            row.Children.Add(url);

            var fallback = new CheckBox
            {
                Content = "兜底",
                IsChecked = engine.Fallback,
                VerticalAlignment = VerticalAlignment.Center,
            };
            fallback.Click += (_, _) =>
            {
                var value = fallback.IsChecked == true;
                foreach (var other in engines)
                {
                    other.Fallback = false;
                }

                engine.Fallback = value;
                Persist();
            };
            Grid.SetColumn(fallback, 3);
            row.Children.Add(fallback);

            var up = new Button { Content = "↑", Padding = new Thickness(8, 2, 8, 2), IsEnabled = index > 0 };
            up.Click += (_, _) =>
            {
                (engines[index - 1], engines[index]) = (engines[index], engines[index - 1]);
                Persist();
            };
            Grid.SetColumn(up, 4);
            row.Children.Add(up);

            var down = new Button
            {
                Content = "↓",
                Padding = new Thickness(8, 2, 8, 2),
                IsEnabled = index < engines.Count - 1,
            };
            down.Click += (_, _) =>
            {
                (engines[index + 1], engines[index]) = (engines[index], engines[index + 1]);
                Persist();
            };
            Grid.SetColumn(down, 5);
            row.Children.Add(down);

            var remove = new Button { Content = "删除", Padding = new Thickness(8, 2, 8, 2) };
            remove.Click += (_, _) =>
            {
                engines.RemoveAt(index);
                Persist();
            };
            Grid.SetColumn(remove, 6);
            row.Children.Add(remove);
            _content.Children.Add(row);
        }

        var add = new Button { Content = "＋ 添加搜索" };
        var addMenu = new MenuFlyout();
        foreach (var preset in KittyTools.Core.WebSearch.Presets
                     .Where(preset => engines.All(engine => engine.Id != preset.Id)))
        {
            var item = new MenuFlyoutItem { Text = preset.Name };
            item.Click += (_, _) =>
            {
                engines.Add(new KittyTools.Core.SearchEngine
                {
                    Id = preset.Id,
                    Name = preset.Name,
                    Keyword = preset.Keyword,
                    UrlTemplate = preset.UrlTemplate,
                    Fallback = false,
                });
                Persist();
            };
            addMenu.Items.Add(item);
        }

        add.Flyout = addMenu;
        _content.Children.Add(add);

        _content.Children.Add(Section("使用记录", "「常用」和排序从这里学；清空后收藏和网页搜索列表不动。"));
        var clear = new Button { Content = "清空使用记录" };
        var armed = false;
        clear.Click += (_, _) =>
        {
            if (!armed)
            {
                armed = true;
                clear.Content = "再点一次：清空";
                return;
            }

            LauncherUsageStore.Instance?.Clear();
            NoticeHost.Show("已清空", "「常用」从头开始学", NoticeTone.Normal);
            BuildPage("launcher");
        };
        _content.Children.Add(clear);
    }

    private void BuildScreenshot()
    {
        if (!ShowIfDisabled(Feature.Screenshot))
        {
            return;
        }

        _content.Children.Add(Header("截图", "框选、标注、识字、钉图和截图翻译；Ctrl+S 快速保存。"));
        _content.Children.Add(Section(
            "快速保存位置",
            "默认是系统的「屏幕截图」文件夹；Ctrl+Shift+S 每次另存为。"));
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var path = new TextBox
        {
            Text = string.IsNullOrWhiteSpace(SettingsService.Current.ScreenshotSaveFolder)
                ? ScreenshotOutput.DefaultFolder()
                : SettingsService.Current.ScreenshotSaveFolder!,
            IsReadOnly = true,
            FontSize = 13,
        };
        row.Children.Add(path);
        var choose = new Button { Content = "选择文件夹…" };
        choose.Click += async (_, _) =>
        {
            try
            {
                var picker = new FolderPicker(AppWindow.Id);
                var result = await picker.PickSingleFolderAsync();
                if (result is not null && !string.IsNullOrEmpty(result.Path))
                {
                    SettingsService.Current.ScreenshotSaveFolder = result.Path;
                    SettingsService.Save();
                    BuildPage("screenshot");
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings.folder-picker-failed", ex);
                NoticeHost.Show("没能选择文件夹", ex.GetType().Name, NoticeTone.Error);
            }
        };
        Grid.SetColumn(choose, 1);
        row.Children.Add(choose);
        var reset = new Button { Content = "恢复默认" };
        reset.Click += (_, _) =>
        {
            SettingsService.Current.ScreenshotSaveFolder = null;
            SettingsService.Save();
            BuildPage("screenshot");
        };
        Grid.SetColumn(reset, 2);
        row.Children.Add(reset);
        _content.Children.Add(row);
        _content.Children.Add(new TextBlock
        {
            Text = "截图不会上传到任何服务；识字和截图翻译只在本机用 Windows 的识字组件。",
            Opacity = 0.65,
            TextWrapping = TextWrapping.Wrap,
        });

        if (Features.IsOn(Feature.Recording))
        {
            _content.Children.Add(Section(
                "录屏", "Alt+R 开始 / 停止；现在录鼠标所在那块屏的整屏，没有声音、没有选区（基础版）。"));
            AddCombo("帧率", "15 够用；30 更顺、文件更大。",
                new[] { "15 fps", "30 fps" },
                SettingsService.Current.RecordFps >= 30 ? 1 : 0,
                index =>
                {
                    SettingsService.Current.RecordFps = index == 1 ? 30 : 15;
                    SettingsService.Save();
                });

            AddToggle("显示点按", "录制画面里画一个圈（左键粉色、右键蓝色）。",
                SettingsService.Current.RecordClicks,
                value =>
                {
                    SettingsService.Current.RecordClicks = value;
                    SettingsService.Save();
                });
            AddToggle("显示按键", "只显示带修饰键的快捷键（如 Ctrl + Shift + S），单个字母不显示。",
                SettingsService.Current.RecordKeys,
                value =>
                {
                    SettingsService.Current.RecordKeys = value;
                    SettingsService.Save();
                });

            var folderRow = new Grid { ColumnSpacing = 8 };
            folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            folderRow.Children.Add(new TextBox
            {
                Text = RecordingHost.Folder,
                IsReadOnly = true,
                FontSize = 13,
            });
            var pick = new Button { Content = "选择文件夹…" };
            pick.Click += async (_, _) =>
            {
                try
                {
                    var picker = new FolderPicker(AppWindow.Id);
                    var result = await picker.PickSingleFolderAsync();
                    if (result is not null && !string.IsNullOrEmpty(result.Path))
                    {
                        SettingsService.Current.RecordDirectory = result.Path;
                        SettingsService.Save();
                        BuildPage("screenshot");
                    }
                }
                catch (Exception ex)
                {
                    Log.Error("settings.record-folder-failed", ex);
                }
            };
            Grid.SetColumn(pick, 1);
            folderRow.Children.Add(pick);
            _content.Children.Add(folderRow);
            _content.Children.Add(SettingsUi.Card(
                "\uE8B7",
                "打开录屏文件夹",
                RecordingHost.Folder,
                null,
                () =>
                {
                    try
                    {
                        Directory.CreateDirectory(RecordingHost.Folder);
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "explorer.exe",
                            Arguments = "\"" + RecordingHost.Folder + "\"",
                            UseShellExecute = true,
                        });
                    }
                    catch (Exception ex)
                    {
                        Log.Warn($"settings.record-folder-open {ex.GetType().Name}");
                    }
                }));
        }
    }

    private void BuildTranslate()
    {
        if (!ShowIfDisabled(Feature.Translate))
        {
            return;
        }

        Log.Info("settings.translate.build-start");
        _content.Children.Add(Header("翻译", "划词、输入和复制即译共用一个浮窗；每个启用的服务一张结果卡。"));
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            _content.Children.Add(new TextBlock { Text = "翻译服务还没准备好。", Opacity = 0.7 });
            return;
        }

        var (first, second) = store.Languages;
        var langValues = Enum.GetValues<KittyTools.Core.Lang>();
        var languages = langValues.Select(lang => lang.Title()).ToArray();

        AddCombo("第一语言", "原文是它就译成第二语言，否则译成第一语言。", languages,
            Array.IndexOf(langValues, first),
            index =>
            {
                SettingsService.Current.TranslateFirstLanguage = langValues[index].Code();
                SettingsService.Save();
                BuildPage("translate");
            });

        AddCombo("第二语言", "和第一语言选成同一种时会退回另一种。", languages,
            Array.IndexOf(langValues, second),
            index =>
            {
                SettingsService.Current.TranslateSecondLanguage = langValues[index].Code();
                SettingsService.Save();
                BuildPage("translate");
            });

        AddCombo("浮窗位置", "跟随鼠标，或者记住上次拖到的位置。",
            new[] { "跟随鼠标", "上次位置" },
            SettingsService.Current.TranslateWindowPosition == "last" ? 1 : 0,
            index =>
            {
                SettingsService.Current.TranslateWindowPosition = index == 1 ? "last" : "pointer";
                SettingsService.Save();
            });

        AddToggle("自动复制第一个服务的结果", "复制即译带来的原文不自动复制，免得盖掉你刚复制的内容。",
            SettingsService.Current.TranslateAutoCopy,
            isOn =>
            {
                SettingsService.Current.TranslateAutoCopy = isOn;
                SettingsService.Save();
            });

        AddToggle("查词（单词模式）", "原文是一个词时，智谱和 AI 服务按词典样式解释；结果不自动复制、不给替换原文。",
            SettingsService.Current.TranslateWordLookup,
            isOn =>
            {
                SettingsService.Current.TranslateWordLookup = isOn;
                SettingsService.Save();
            });

        _content.Children.Add(SettingsUi.Section("历史", "只记第一个服务的完成结果；收藏的不受保留条数影响（就是生词本）。"));
        AddToggle("记录翻译历史", "浮窗里按 Ctrl+H 查看。",
            SettingsService.Current.TranslateHistoryEnabled,
            isOn =>
            {
                SettingsService.Current.TranslateHistoryEnabled = isOn;
                SettingsService.Save();
            });

        var limitIndex = SettingsService.Current.TranslateHistoryLimit switch
        {
            1000 => 0,
            0 => 2,
            _ => 1,
        };
        AddCombo("普通历史保留条数", "收藏的不算、永不淘汰。",
            new[] { "1000 条", "5000 条", "不限" },
            limitIndex,
            index =>
            {
                SettingsService.Current.TranslateHistoryLimit = index switch
                {
                    0 => 1000,
                    2 => 0,
                    _ => 5000,
                };
                SettingsService.Save();
            });

        var historyButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var exportHistory = new Button { Content = "导出历史…" };
        exportHistory.Click += (_, _) => _ = ExportHistoryAsync();
        historyButtons.Children.Add(exportHistory);
        var clearHistory = new Button { Content = "清空历史（收藏保留）" };
        var armedClear = false;
        clearHistory.Click += (_, _) =>
        {
            if (!armedClear)
            {
                armedClear = true;
                clearHistory.Content = "再点一次：清空";
                return;
            }

            TranslationHistory.Instance?.ClearNonFavorites();
            NoticeHost.Show("已清空", "收藏的还在", NoticeTone.Normal);
            BuildPage("translate");
        };
        historyButtons.Children.Add(clearHistory);
        _content.Children.Add(historyButtons);

        _content.Children.Add(Section("服务", "列表顺序就是浮窗里卡片的顺序。密钥只存在凭据管理器，不写 settings.json。"));
        if (TranslateServiceStore.BuiltinZhipuKey is null)
        {
            _content.Children.Add(new TextBlock
            {
                Text = "这个构建没有内置智谱 key：要使用免费的智谱，请点「详情」填自己的 API Key。",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
            });
        }

        foreach (var service in store.Services.ToList())
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var enabled = new CheckBox { IsChecked = service.Enabled, VerticalAlignment = VerticalAlignment.Center };
            enabled.Checked += (_, _) => SetServiceEnabled(service, true);
            enabled.Unchecked += (_, _) => SetServiceEnabled(service, false);
            Grid.SetColumn(enabled, 0);
            row.Children.Add(enabled);

            var info = new StackPanel { Spacing = 2 };
            info.Children.Add(new TextBlock
            {
                Text = service.Name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            info.Children.Add(new TextBlock
            {
                Text = ServiceSubtitle(service),
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            Grid.SetColumn(info, 1);
            row.Children.Add(info);

            var detail = new Button { Content = "详情", Padding = new Thickness(10, 2, 10, 2) };
            detail.Click += (_, _) => ShowServiceDialog(service);
            Grid.SetColumn(detail, 2);
            row.Children.Add(detail);

            var remove = new Button { Content = "删除", Padding = new Thickness(10, 2, 10, 2) };
            remove.Click += (_, _) =>
            {
                store.Remove(service.Id);
                BuildPage("translate");
            };
            Grid.SetColumn(remove, 3);
            row.Children.Add(remove);
            _content.Children.Add(row);
        }

        var add = new Button { Content = "＋ 添加服务" };
        var addMenu = new MenuFlyout();
        foreach (var kind in store.MissingBuiltins)
        {
            var item = new MenuFlyoutItem { Text = TranslateKinds.DefaultName(kind) };
            item.Click += (_, _) =>
            {
                store.AddBuiltin(kind);
                BuildPage("translate");
            };
            addMenu.Items.Add(item);
        }

        if (addMenu.Items.Count > 0)
        {
            addMenu.Items.Add(new MenuFlyoutSeparator());
        }

        foreach (var preset in TranslatePresets.Ai)
        {
            var item = new MenuFlyoutItem { Text = preset.Name };
            item.Click += (_, _) =>
            {
                store.AddAi(preset);
                BuildPage("translate");
            };
            addMenu.Items.Add(item);
        }

        addMenu.Items.Add(new MenuFlyoutSeparator());
        var custom = new MenuFlyoutItem { Text = "自定义 OpenAI 兼容" };
        custom.Click += (_, _) =>
        {
            store.AddCustomAi();
            BuildPage("translate");
        };
        addMenu.Items.Add(custom);
        var customAzure = new MenuFlyoutItem { Text = "自定义 Azure OpenAI" };
        customAzure.Click += (_, _) =>
        {
            var service = store.AddCustomAi();
            service.Protocol = "azure";
            store.Save();
            BuildPage("translate");
        };
        addMenu.Items.Add(customAzure);
        add.Flyout = addMenu;
        _content.Children.Add(add);

        var hint = new TextBlock
        {
            Text = "复制即译和「暂停记录剪贴板」在托盘菜单里；浮窗里按 Ctrl+P 固定、Ctrl+1–9 复制第 N 张卡。",
            FontSize = 12,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        };
        _content.Children.Add(hint);
        Log.Info($"settings.translate.build-done services={store.Services.Count}");
    }

    private static string ServiceSubtitle(TranslateServiceConfig service)
    {
        var kind = service.Kind switch
        {
            TranslateKinds.Zhipu => "智谱 GLM",
            TranslateKinds.Google => "Google",
            TranslateKinds.DeepL => service.UsesDeepLX ? "DeepLX" : "DeepL",
            TranslateKinds.Microsoft => "微软（留空 key 用 Edge 免费接口）",
            _ => service.Protocol switch
            {
                "anthropic" => "AI · Anthropic",
                "azure" => "AI · Azure OpenAI",
                _ => "AI · OpenAI 兼容",
            },
        };
        var model = string.IsNullOrWhiteSpace(service.Model) ? string.Empty : " · " + service.Model;
        return kind + model + (service.Enabled ? string.Empty : " · 已停用");
    }

    private void SetServiceEnabled(TranslateServiceConfig service, bool enabled)
    {
        service.Enabled = enabled;
        TranslateServiceStore.Instance?.Save();
        BuildPage("translate");
    }

    private async void ShowServiceDialog(TranslateServiceConfig service)
    {
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            return;
        }

        var panel = new StackPanel { Spacing = 8, MinWidth = 420 };
        var name = new TextBox { Header = "名称", Text = service.Name };
        panel.Children.Add(name);

        var protocolBox = new ComboBox
        {
            Header = "协议",
            Items = { "OpenAI 兼容", "Azure OpenAI", "Anthropic" },
            SelectedIndex = AiServiceProvider.Protocol(service.Protocol) switch
            {
                AiProtocol.Azure => 1,
                AiProtocol.Anthropic => 2,
                _ => 0,
            },
            Visibility = service.Kind == TranslateKinds.Ai ? Visibility.Visible : Visibility.Collapsed,
        };
        panel.Children.Add(protocolBox);

        TextBox? url = null;
        if (service.Kind == TranslateKinds.Ai)
        {
            url = new TextBox { Header = "服务地址", Text = service.BaseUrl ?? string.Empty, PlaceholderText = "https://api.openai.com/v1" };
            panel.Children.Add(url);
        }

        TextBox? model = null;
        ComboBox? zhipuModel = null;
        if (service.Kind == TranslateKinds.Zhipu)
        {
            zhipuModel = new ComboBox
            {
                Header = "模型",
                Items = { "glm-4-flash", "glm-4.7-flash" },
                SelectedIndex = service.Model == "glm-4.7-flash" ? 1 : 0,
            };
            panel.Children.Add(zhipuModel);
        }
        else if (service.Kind == TranslateKinds.Ai)
        {
            model = new TextBox { Header = "模型", Text = service.Model ?? string.Empty };
            panel.Children.Add(model);
        }

        ToggleSwitch? deepLx = null;
        if (service.Kind == TranslateKinds.DeepL)
        {
            deepLx = new ToggleSwitch { Header = "用自建 DeepLX", IsOn = service.UsesDeepLX };
            panel.Children.Add(deepLx);
            url = new TextBox { Header = "DeepLX 地址", Text = service.BaseUrl ?? string.Empty, PlaceholderText = "http://127.0.0.1:1188/translate" };
            panel.Children.Add(url);
        }

        TextBox? region = null;
        if (service.Kind == TranslateKinds.Microsoft)
        {
            region = new TextBox { Header = "区域（填了 key 时）", Text = service.Region ?? string.Empty };
            panel.Children.Add(region);
        }

        // 一个服务可能有多个密钥字段（百度 App ID + 密钥、火山 Access Key + Secret Key…）。
        var secretBoxes = new List<(string Field, PasswordBox Box)>();
        foreach (var field in TranslateKinds.SecretFields(service.Kind))
        {
            var existingSecret = store.Secret(service, field);
            var box = new PasswordBox
            {
                Header = TranslateKinds.SecretLabel(service.Kind, field),
                PlaceholderText = existingSecret is not null
                    ? "已保存，留空不修改"
                    : service.Kind == TranslateKinds.Zhipu && TranslateServiceStore.BuiltinZhipuKey is not null
                        ? "留空使用内置免费额度"
                        : "填密钥",
            };
            secretBoxes.Add((field, box));
            panel.Children.Add(box);
        }

        var clearKey = new CheckBox { Content = "清除已保存的全部密钥" };
        panel.Children.Add(clearKey);

        var result = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = 0.8,
            IsTextSelectionEnabled = true,
        };
        panel.Children.Add(result);

        var dialog = new ContentDialog
        {
            Title = service.Name,
            PrimaryButtonText = "保存",
            SecondaryButtonText = "测试连接",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            Content = panel,
            XamlRoot = _shell.XamlRoot,
        };

        void Apply()
        {
            if (!string.IsNullOrWhiteSpace(name.Text))
            {
                service.Name = name.Text.Trim();
            }

            if (service.Kind == TranslateKinds.Ai)
            {
                service.Protocol = protocolBox.SelectedIndex switch
                {
                    1 => "azure",
                    2 => "anthropic",
                    _ => "openai",
                };
                service.BaseUrl = url?.Text.Trim();
                service.Model = model?.Text.Trim();
            }

            if (service.Kind == TranslateKinds.Zhipu)
            {
                service.Model = zhipuModel?.SelectedIndex == 1 ? "glm-4.7-flash" : "glm-4-flash";
            }

            if (service.Kind == TranslateKinds.DeepL)
            {
                service.UsesDeepLX = deepLx?.IsOn == true;
                service.BaseUrl = url?.Text.Trim();
            }

            if (service.Kind == TranslateKinds.Microsoft)
            {
                service.Region = string.IsNullOrWhiteSpace(region?.Text) ? null : region.Text.Trim();
            }

            if (clearKey.IsChecked == true)
            {
                foreach (var (field, _) in secretBoxes)
                {
                    store.SetSecret(service, null, field);
                }
            }
            else
            {
                foreach (var (field, box) in secretBoxes)
                {
                    if (!string.IsNullOrEmpty(box.Password))
                    {
                        store.SetSecret(service, box.Password, field);
                    }
                }
            }

            store.Save();
        }

        dialog.PrimaryButtonClick += (_, _) =>
        {
            Apply();
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            args.Cancel = true;
            try
            {
                Apply();
                result.Text = "测试中…";
                result.Text = await TestServiceAsync(service);
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        BuildPage("translate");
    }

    private static async Task<string> TestServiceAsync(TranslateServiceConfig service)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var request = new TranslateRequest("hello", KittyTools.Core.Lang.En, KittyTools.Core.Lang.ZhHans);
            var latest = string.Empty;
            await foreach (var piece in TranslateServiceStore.Translate(service, request, cts.Token))
            {
                latest = piece;
            }

            return string.IsNullOrWhiteSpace(latest) ? "测试失败：服务没有返回内容" : "连接成功：" + latest;
        }
        catch (TranslateError error)
        {
            return "测试失败：" + error.Message;
        }
        catch (OperationCanceledException)
        {
            return "测试失败：超时（20 秒）";
        }
        catch (Exception ex)
        {
            return "测试失败：" + ex.Message;
        }
    }

    /// <summary>功能关掉了：这一页只留一张「已关闭」的卡和去打开的按钮（第三版 §2.3）。</summary>
    private bool ShowIfDisabled(Feature feature)
    {
        if (Features.IsOn(feature))
        {
            return true;
        }

        _content.Children.Add(Header(Features.Title(feature), string.Empty));
        _content.Children.Add(SettingsUi.Card(
            "\uE7E8",
            "已关闭",
            "这个功能关掉了：热键、托盘菜单项和后台工作都停了。到 通用 › 功能 里打开就回来。",
            null,
            () => BuildPage("general")));
        return false;
    }

    private void ReportCleanup(int removed)
    {
        if (removed > 0)
        {
            NoticeHost.Show("已按新上限清理", $"删了 {removed} 条旧记录", NoticeTone.Normal);
        }
    }

    private static UIElement Section(string title, string subtitle)
        => SettingsUi.Section(title, subtitle);

    private void BuildHotKeys()
    {
        _content.Children.Add(Header("快捷键", "点「录制」后按新的组合；至少带 Ctrl 或 Alt，或者单独一个 F1–F24。"));

        _hotKeyError.IsOpen = false;
        _content.Children.Add(_hotKeyError);

        _recordHint = new TextBlock
        {
            Text = " ",
            Foreground = Theme.SecondaryText(),
            FontSize = 12,
        };
        _content.Children.Add(_recordHint);

        foreach (var definition in SettingsDefaults.DefaultHotKeys)
        {
            var shortcut = HotKeyManager.FormatFor(definition.Action);
            var binding = SettingsDefaults.BindingFor(SettingsService.Current, definition.Action);
            var failure = ShellRuntime.Instance?.HotKeys.FailureFor(definition.Action);
            var statusText = binding.VirtualKey == 0
                ? "未设置"
                : failure ?? (ShellRuntime.Instance?.HotKeys.IsRegistered(definition.Action) == true ? "正常" : "");

            var right = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                VerticalAlignment = VerticalAlignment.Center,
            };
            right.Children.Add(SettingsUi.KeyCaps(shortcut));
            var record = new Button { Content = "录制", Tag = definition.Action };
            AutomationProperties.SetName(record, $"录制 {definition.DisplayName} 的快捷键");
            record.Click += (_, _) => BeginRecording(definition.Action);
            var clear = new Button { Content = "清空", Tag = definition.Action };
            AutomationProperties.SetName(clear, $"清空 {definition.DisplayName} 的快捷键");
            clear.Click += (_, _) => ClearHotKey(definition.Action);
            clear.IsEnabled = binding.VirtualKey != 0;
            right.Children.Add(record);
            right.Children.Add(clear);

            var card = SettingsUi.Card(
                "\uE765",
                definition.DisplayName,
                binding.VirtualKey == 0
                    ? "未设置"
                    : failure is null
                        ? statusText == "正常" ? "正在使用" : "已设置"
                        : failure,
                right);
            if (failure is not null)
            {
                // 被占用时红字说明原因（PLAN-v2 §3.4）。
                var text = (card.Child as Grid)?.Children.OfType<StackPanel>().FirstOrDefault();
                if (text?.Children.OfType<TextBlock>().LastOrDefault() is { } detail)
                {
                    detail.Foreground = Theme.Critical();
                }
            }

            _content.Children.Add(card);
        }

        var reset = new Button { Content = "全部恢复默认" };
        AutomationProperties.SetName(reset, "全部恢复默认快捷键");
        reset.Click += (_, _) =>
        {
            SettingsService.Current.HotKeys.Clear();
            SettingsDefaults.Apply(SettingsService.Current);
            SettingsService.Save();
            ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
            BuildPage("hotkeys");
        };
        _content.Children.Add(reset);
    }

    private void BeginRecording(string action)
    {
        _recordingAction = action;
        _hotKeyError.IsOpen = false;
        if (_recordHint is not null)
        {
            _recordHint.Text = $"正在录制「{SettingsDefaults.Find(action)?.DisplayName}」：按新的组合，Esc 取消。";
        }
    }

    private void OnRecordKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_recordingAction is null)
        {
            return;
        }

        e.Handled = true;
        if (e.Key == VirtualKey.Escape)
        {
            StopRecording("已取消");
            return;
        }

        var key = (uint)e.Key;
        var modifiers = HotKeyModifiers.None;
        if (IsDown(VirtualKey.Control)) modifiers |= HotKeyModifiers.Control;
        if (IsDown(VirtualKey.Menu)) modifiers |= HotKeyModifiers.Alt;
        if (IsDown(VirtualKey.Shift)) modifiers |= HotKeyModifiers.Shift;
        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows)) modifiers |= HotKeyModifiers.Win;

        if (HotKeyRules.IsModifierKey(key))
        {
            if (_recordHint is not null)
            {
                _recordHint.Text = "再按一个普通键（修饰键本身不算）。Esc 取消。";
            }
            return;
        }

        var validation = HotKeyRules.Validate(key, modifiers);
        if (!validation.Ok)
        {
            _hotKeyError.Message = validation.Reason ?? "这个组合不能用";
            _hotKeyError.IsOpen = true;
            return;
        }

        var action = _recordingAction;
        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(key, modifiers));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        StopRecording("已保存");
        BuildPage("hotkeys");
        var failure = ShellRuntime.Instance?.HotKeys.FailureFor(action);
        if (failure is not null)
        {
            _hotKeyError.Message = $"组合已保存，但注册失败：{failure}";
            _hotKeyError.IsOpen = true;
        }
    }

    private void ClearHotKey(string action)
    {
        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(0, HotKeyModifiers.None));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        BuildPage("hotkeys");
    }

    private void StopRecording(string hint)
    {
        _recordingAction = null;
        if (_recordHint is not null)
        {
            _recordHint.Text = hint;
        }
    }

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void BuildAbout()
    {
        _content.Children.Add(Header("关于", ""));
        var version = typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";

        var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        // 应用图标（REVIEW R10）：直接从 exe 里取一张 PNG，不额外放一份素材。
        try
        {
            if (ShellIcons.LoadPng(
                    Paths.ExecutablePath,
                    (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1) is { Length: > 0 } icon)
            {
                identity.Children.Add(new Image
                {
                    Width = 48,
                    Height = 48,
                    Stretch = Stretch.Uniform,
                    Source = IconSource(icon),
                });
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"settings.icon-failed {ex.GetType().Name}");
        }

        var identityText = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        identity.Children.Add(identityText);
        identityText.Children.Add(new TextBlock
        {
            Text = $"Kitty Tools {version}",
            FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        identityText.Children.Add(new TextBlock
        {
            Text = "Windows 原生版。剪贴板历史、翻译、启动器和截图。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = Theme.SecondaryText(),
        });
        _content.Children.Add(Card(identity));

        _content.Children.Add(SettingsUi.Section("更新"));
        var updateCard = SettingsUi.Card(
            "\uE895",
            "检查更新",
            UpdateService.AvailableVersion is { } available
                ? $"有可用的新版本 {available}"
                : "每天检查一次；下载后可以直接安装。",
            null,
            () => _ = CheckOrInstallAsync());
        _content.Children.Add(updateCard);

        _content.Children.Add(SettingsUi.Card(
            "\uE8B7",
            "数据目录",
            "数据库、图片、日志和设置都放在这里。",
            null,
            OpenDataDirectory));

        _content.Children.Add(ChangelogBlock());
    }

    private async Task CheckOrInstallAsync()
    {
        if (UpdateService.AvailableVersion is not null)
        {
            await AutoUpdater.StartAsync();
            return;
        }

        await UpdateService.CheckAsync(userInitiated: true);
        BuildPage("about");
    }

    private UIElement ChangelogBlock()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "changelog.json");
            if (!File.Exists(path))
            {
                return new TextBlock { Text = "更新日志不在发布目录里。", Opacity = 0.6 };
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var panel = new StackPanel { Spacing = 8 };
            panel.Children.Add(SettingsUi.Section("更新日志", "按版本分组；标签是这次改动属于哪一类。"));
            if (!root.TryGetProperty("entries", out var entries) || entries.ValueKind != JsonValueKind.Array)
            {
                return panel;
            }

            foreach (var entry in entries.EnumerateArray().Take(6))
            {
                var version = entry.TryGetProperty("version", out var v) ? v.GetString() : "";
                var summary = entry.TryGetProperty("summary", out var s) ? s.GetString() : "";
                var group = new StackPanel { Spacing = 6 };
                group.Children.Add(new TextBlock
                {
                    Text = $"{version}  {summary}",
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (entry.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in items.EnumerateArray())
                    {
                        var type = item.TryGetProperty("type", out var t) ? t.GetString() : null;
                        if (type is not ("feat" or "fix" or "perf" or "ui"))
                        {
                            continue;
                        }

                        var text = item.TryGetProperty("text", out var itemText) ? itemText.GetString() : null;
                        if (string.IsNullOrEmpty(text))
                        {
                            continue;
                        }

                        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                        row.Children.Add(SettingsUi.TypeTag(type));
                        row.Children.Add(new TextBlock
                        {
                            Text = text,
                            TextWrapping = TextWrapping.Wrap,
                            FontSize = 13,
                            Foreground = Theme.SecondaryText(),
                        });
                        group.Children.Add(row);
                    }
                }

                panel.Children.Add(Card(group));
            }

            return panel;
        }
        catch (Exception ex)
        {
            Log.Error("changelog.read-failed", ex);
            return new TextBlock { Text = "更新日志读不出来。", Opacity = 0.6 };
        }
    }

    private void OpenDataDirectory()
    {
        try
        {
            Directory.CreateDirectory(Paths.DataDirectory);
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{Paths.DataDirectory}\"",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Error("settings.open-data-failed", ex);
        }
    }

    private static UIElement Header(string title, string subtitle)
        => SettingsUi.Header(title, subtitle);

    private void AddToggle(string title, string subtitle, bool value, Action<bool> changed, string glyph = "")
        => _content.Children.Add(SettingsUi.Card(
            glyph.Length > 0 ? glyph : GlyphFor(title),
            title,
            subtitle,
            SettingsUi.Toggle(value, changed, title)));

    private void AddCombo(
        string title, string subtitle, string[] items, int selected, Action<int> changed, string glyph = "")
        => _content.Children.Add(SettingsUi.Card(
            glyph.Length > 0 ? glyph : GlyphFor(title),
            title,
            subtitle,
            SettingsUi.Combo(items, selected, changed, title)));

    /// <summary>每个设置项一个有意思的图标（REVIEW R10）；没有合适的就不画图标块。</summary>
    private static string GlyphFor(string title) => title switch
    {
        "登录时自动打开" => "\uE7E8",
        "外观" => "\uE790",
        "强调色" => "\uE790",
        "自动检查更新" => "\uE895",
        "暂停记录" => "\uE769",
        "保留普通历史" => "\uE787",
        "图片最多占用" => "\uEB9F",
        "不记录疑似密钥和卡号" => "\uE72E",
        "第一语言" => "\uE774",
        "第二语言" => "\uE774",
        "浮窗位置" => "\uE7C2",
        "自动复制第一个服务的结果" => "\uE8C8",
        _ => string.Empty,
    };

    private static Border Card(UIElement child) => new()
    {
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(18),
        Background = Theme.CardBackground(),
        Child = child,
    };

    /// <summary>把 PNG 字节变成一个 ImageSource（应用图标用）。</summary>
    private static ImageSource IconSource(byte[] bytes)
    {
        var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
        _ = SetImageAsync(image, bytes);
        return image;
    }

    private static async Task SetImageAsync(Microsoft.UI.Xaml.Media.Imaging.BitmapImage image, byte[] bytes)
    {
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        catch (Exception ex)
        {
            Log.Warn($"settings.icon-load-failed {ex.GetType().Name}");
        }
    }
}
