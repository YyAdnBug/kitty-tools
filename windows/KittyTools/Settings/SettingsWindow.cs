// 设置窗：左侧 NavigationView（带图标），右边每页一个大标题 + 一组组设置卡，Mica。
// AOT 下 NavigationView 崩溃的根因（发布目录缺 PRI）第二版第 2 批已经修好，这一批换回 NavigationView（PLAN-v2 §2b / §3.4）。
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using KittyTools.Infrastructure;
using KittyTools.Core;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;
using Windows.Win32;

namespace KittyTools;

internal sealed class SettingsWindow : Window
{
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

    // REVIEW R44：别处存了设置（截图记上次区域、翻译窗记位置、托盘里的开关、同步……）时不当场重建这一页，
    // 只记下来，等窗口下次显示、或者从别的窗口切回来时再建；在这一页里自己改的，控件已经是新值，不用重建。
    private bool _stale;
    private bool _active;
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
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                VerticalAlignment = VerticalAlignment.Center,
            };
            row.Children.Add(KindTile.Create(FamilyForPage(tag), glyph, 20));
            row.Children.Add(new TextBlock
            {
                Text = title,
                VerticalAlignment = VerticalAlignment.Center,
            });
            _nav.MenuItems.Add(new NavigationViewItem
            {
                Content = row,
                Tag = tag,
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

        // 没有 Mica 时窗口底色跟系统的深浅色走：设置里选了另一种外观，深色的白字就落在白底上
        // （左栏的页名整个看不见）。铺一层按设置里选的那套取的不透明底，同截图历史窗。
        _shell = new Grid { RequestedTheme = Theme.ElementTheme, Background = PageBackground() };
        _shell.Children.Add(_nav);

        _hotKeyError = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            IsOpen = false,
            IsClosable = true,
        };
        _shell.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnRecordKeyDown), handledEventsToo: true);

        Content = _shell;
        // Mica 在部分机器 / Release AOT 下会在 OnDefaultSystemBackdropConfigurationChanged 抛
        // ArgumentException（R31 冒烟抓到）；设置窗改用不透明卡片底，稳过启动冒烟。
        // ponytail: 要 Mica 时等 WinUI 修好再用，或换成自己挂 DesktopAcrylicController + try/catch。
        SystemBackdrop = null;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _hwnd = (Windows.Win32.Foundation.HWND)hwnd;
        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        _width = (int)Math.Round(980 * scale);
        _height = (int)Math.Round(720 * scale);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(_width, _height));
        AppWindow.SetIcon(Paths.ExecutablePath);
        Theme.ApplyTitleBar(AppWindow);

        BuildPage("general");
        Activated += (_, args) =>
        {
            _active = args.WindowActivationState != WindowActivationState.Deactivated;
            if (_active && _stale && _recordingAction is null)
            {
                BuildPage(_currentPage);
            }
        };
        Closed += (_, _) =>
        {
            IsClosed = true;
            // R27：设置页的卡片 / 键帽 / 缩略图都是代码建的，关窗后放掉，别等下一次开才回收。
            _content.Children.Clear();
            _nav.MenuItems.Clear();
            _nav.FooterMenuItems.Clear();
            _nav.Content = null;
            Log.Info("settings.closed");
            GC.Collect(2, GCCollectionMode.Optimized, blocking: false, compacting: false);
        };
        // R34：设置窗反复开关每次 +5 MB。改成「关 = 隐藏」，全进程只建一次窗口，不再重复分配 XAML 树。
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            IsClosed = false;
            AppWindow.Hide();
            Log.Info("settings.hidden");
        };
    }

    public bool IsClosed { get; private set; }

    private bool _everShown;

    public void ShowPage(bool welcome, string page = "general")
    {
        Motion.Refresh();
        _firstRun = welcome;
        // R34：同一页反复开关不重建 XAML 树（每次重建约 +5 MB）；换页或第一次才建。
        if (welcome || _stale || page != _currentPage || _content.Children.Count == 0)
        {
            BuildPage(page);
        }

        Log.Info($"settings.page {page}");
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Restore();
        }

        if (!_everShown)
        {
            _everShown = true;
            AppWindow.Show();
            Activate();
        }

        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + Math.Max(0, (area.Width - _width) / 2),
            area.Y + Math.Max(0, (area.Height - _height) / 2)));
        Foreground.Restore(_hwnd);
        // 焦点给内容区，不落在左栏第一项上（REVIEW R10：鼠标打开时不该有焦点框）。
        _scroll.Focus(FocusState.Programmatic);
        Log.Info($"settings.show firstRun={welcome}");
    }

    private static Brush PageBackground()
        => Theme.Brush("Kitty.PageBackground", Theme.EffectiveTheme == ElementTheme.Dark
            ? Theme.Argb(255, 32, 32, 32)
            : Theme.Argb(255, 243, 243, 243));

    /// <summary>设置在别处被存了（不是外观 / 强调色 / 功能开关变了）：窗口不在前台时记一下，切回来再重建。</summary>
    public void MarkStale()
    {
        if (!_active)
        {
            _stale = true;
        }
    }

    public void RefreshTheme()
    {
        _shell.RequestedTheme = Theme.ElementTheme;
        _shell.Background = PageBackground();
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
        _stale = false;
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

        _content.Children.Add(SettingsUi.Card(
            Glyphs.Palette, "外观", "跟随系统、浅色或深色。", ThemePicker()));

        _content.Children.Add(SettingsUi.Card(
            Glyphs.Palette, "强调色", "跟随系统，或者固定成一种颜色。", AccentPicker()));

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
        _content.Children.Add(SettingsUi.Card(
            "\uE74D",
            "从这台电脑移除 Kitty Tools…",
            "删掉开始菜单快捷方式、开机启动和保存的密钥；数据可以留着。",
            null,
            () => _ = UninstallAsync()));

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
                RequestedTheme = Theme.ElementTheme,
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
                    RequestedTheme = Theme.ElementTheme,
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
        if (status?.State == "confirm")
        {
            // 刹车停下的那一类：用户看过要删几条之后放行这一轮。
            var confirm = new Button { Content = "照样同步" };
            confirm.Click += (_, _) =>
            {
                Syncer.Instance?.ConfirmDeletions();
                NoticeHost.Show("同步", "开始同步…", NoticeTone.Normal);
            };
            row.Children.Add(confirm);
        }

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
            var disk = new Core.Sync.SyncDisk(folder.Path);
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
                RequestedTheme = Theme.ElementTheme,
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
                   "默认快捷键：剪贴板 Alt+C、划词翻译 Alt+E、输入翻译 Alt+T、" +
                   "截图翻译 Alt+S、截图 Alt+X、识字 Alt+O。\n\n" +
                   "启动器（Alt+Space）和录屏（Alt+R）先关着，要用的话在下面「功能」里打开。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = Theme.SecondaryText(),
        });

        // R37：安装程序装的，安装时已经问过开机启动，照它实际写下的值；不然「开始使用」会把没勾的又写回去。
        if (SetupRecord.IsInstalled)
        {
            SettingsService.Current.StartWithWindows = Autostart.IsEnabled();
        }

        var autostart = new CheckBox
        {
            Content = "登录时自动打开",
            IsChecked = SettingsService.Current.StartWithWindows,
        };
        panel.Children.Add(autostart);

        var start = new Button
        {
            Content = "开始使用",
            Background = new SolidColorBrush(Theme.AccentColor),
            Foreground = new SolidColorBrush(Theme.OnAccentColor),
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

    /// <summary>
    /// 设置 › 剪贴板（照 mac Settings/ClipboardTab.swift 的分节，PLAN-v9-clipboard §5）：历史 ｜ 面板（示意图 + 三个开关）｜
    /// 内容 ｜ 隐私 ｜ 不记录这些应用里的复制。「暂停记录」只在托盘菜单里（D7）。
    /// </summary>
    private void BuildClipboard()
    {
        if (!ShowIfDisabled(Feature.Clipboard))
        {
            return;
        }

        _content.Children.Add(Header("剪贴板", "记录文本、图片和文件；面板里按 Ctrl+D 收藏。收藏和片段不受保留天数和图片占用影响。"));
        AddShortcutsLink("clipboard");
        var service = ClipboardService.Instance;
        if (service is null)
        {
            _content.Children.Add(new TextBlock
            {
                Text = "剪贴板数据库打不开，这一页暂时用不了。看看数据目录里的 kitty.sqlite3 是不是被占着。",
                TextWrapping = TextWrapping.Wrap,
                Foreground = Theme.SecondaryText(),
            });
            return;
        }

        var settings = SettingsService.Current;

        // 历史
        _content.Children.Add(Section("历史", "收藏和片段一直留着，图片占用也只算普通历史里的。"));
        var days = new[] { 1, 7, 30, 90, 365, 0 };
        AddCombo("保留普通历史", string.Empty,
            new[] { "1 天", "7 天", "30 天", "90 天", "1 年", "永久" },
            Math.Max(0, Array.IndexOf(days, settings.ClipboardRetentionDays) is var dayIndex and >= 0 ? dayIndex : 5),
            index =>
            {
                settings.ClipboardRetentionDays = days[index];
                SettingsService.Save();
                ReportCleanup(service.EnforceLimits());
            });

        // 图片占用：512 MB / 1 GB / 2 GB / 5 GB / 不限（= PLAN-v9 C2）；存着别的值（旧的 128 / 256）照原值算，多显示一项，换了就没了。
        var budgets = new List<(int Value, string Title)> { (512, "512 MB"), (1024, "1 GB"), (2048, "2 GB"), (5120, "5 GB"), (0, "不限") };
        if (budgets.All(budget => budget.Value != settings.ClipboardImageBudgetMB))
        {
            budgets.Insert(0, (settings.ClipboardImageBudgetMB, $"{settings.ClipboardImageBudgetMB} MB"));
        }

        AddCombo("图片最多占用", "超了从最旧的删起，最新的一张这一轮不删。",
            budgets.Select(budget => budget.Title).ToArray(),
            budgets.FindIndex(budget => budget.Value == settings.ClipboardImageBudgetMB),
            index =>
            {
                settings.ClipboardImageBudgetMB = budgets[index].Value;
                SettingsService.Save();
                ReportCleanup(service.EnforceLimits());
            });
        _content.Children.Add(SettingsUi.Card(
            "\uEB9F", "图片当前占用", $"普通图片约 {service.Store.OrdinaryImageBytes / 1_048_576.0:F0} MB，共 {service.Store.Count} 条"));

        // 面板
        _content.Children.Add(SettingsUi.Section("面板"));
        _content.Children.Add(ClipboardSketch(settings.ClipboardShowLens, settings.LinkPreviews));
        AddToggle("显示透镜", "选中的条目在原地展开预览；关掉就是纯列表，一屏多露出几行",
            settings.ClipboardShowLens,
            isOn =>
            {
                settings.ClipboardShowLens = isOn;
                SettingsService.Save();
                BuildPage("clipboard");
            }, "\uE8A1");
        AddToggle("链接显示网页标题和图片", "选中链接时联网读取；本机、内网和带登录令牌的网址不读",
            settings.LinkPreviews,
            isOn =>
            {
                settings.LinkPreviews = isOn;
                SettingsService.Save();
                if (!isOn)
                {
                    LinkPreviewService.Clear();
                }

                BuildPage("clipboard");
            }, "\uE71B");
        AddToggle("单击条目直接粘贴", "关着时单击选中、双击粘贴；打开后点一下就粘贴，想先看内容用 ↑↓，Ctrl 单击、Shift 单击照常多选",
            settings.ClipboardPasteOnClick,
            isOn =>
            {
                settings.ClipboardPasteOnClick = isOn;
                SettingsService.Save();
            }, "\uE7C9");

        // 内容
        _content.Children.Add(SettingsUi.Section("内容"));
        AddToggle("默认粘贴为纯文本", "打开后 Enter 粘贴纯文本，Shift+Enter 保留格式；文字的格式总是记下来",
            settings.ClipboardPastePlain,
            isOn =>
            {
                settings.ClipboardPastePlain = isOn;
                SettingsService.Save();
            }, "\uE8D2");
        AddToggle("识别图片中的文字，用于搜索", string.Empty,
            settings.ClipboardImageOcr,
            isOn =>
            {
                settings.ClipboardImageOcr = isOn;
                SettingsService.Save();
                if (isOn)
                {
                    OcrQueue.Kick();
                }
            }, "\uE8C1");

        // 隐私
        _content.Children.Add(SettingsUi.Section("隐私"));
        AddToggle("不记录疑似密钥和银行卡号", string.Empty,
            settings.ClipboardBlockSensitive,
            isOn =>
            {
                settings.ClipboardBlockSensitive = isOn;
                SettingsService.Save();
            }, "\uE72E");
        AddToggle("退出时清空普通历史", string.Empty,
            settings.ClipboardClearOnQuit,
            isOn =>
            {
                settings.ClipboardClearOnQuit = isOn;
                SettingsService.Save();
            }, "\uE7E8");
        AddToggle("锁屏时清空普通历史", string.Empty,
            settings.ClipboardClearOnLock,
            isOn =>
            {
                settings.ClipboardClearOnLock = isOn;
                SettingsService.Save();
            }, "\uE72E");
        var clear = new Button
        {
            Content = "立即清空普通历史…",
            Foreground = Theme.Critical(),
        };
        clear.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                RequestedTheme = Theme.ElementTheme,
                Title = "清空普通历史？",
                Content = "收藏和片段会保留",
                PrimaryButtonText = "清空",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = _content.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            var removed = service.Store.ClearOrdinary();
            NoticeHost.Show("已清空", $"删了 {removed} 条，收藏和片段还在", NoticeTone.Normal);
            BuildPage("clipboard");
        };
        _content.Children.Add(clear);

        // 不记录这些应用里的复制
        _content.Children.Add(Section("不记录这些应用里的复制", "密码管理器通常会自己标记「不要记录」，这里只是兜底。"));
        BuildExcludedApps(settings);
    }

    /// <summary>
    /// 排除的应用：一行一个（图标 + 显示名 + 灰色的 exe 名 + 移除）；「选择应用…」从正在运行的程序里选，或浏览一个 exe。
    /// 存的还是 exe 名（同步、导出的格式不动）；图标和显示名从正在运行的同名程序里取，没在运行的只写 exe 名。
    /// </summary>
    private void BuildExcludedApps(Settings settings)
    {
        var running = RunningApps();
        var list = new StackPanel { Spacing = 2 };
        if (settings.ClipboardExcludedApps.Count == 0)
        {
            list.Children.Add(new TextBlock { Text = "没有排除的应用", Foreground = Theme.SecondaryText(), Margin = new Thickness(4) });
        }

        foreach (var app in settings.ClipboardExcludedApps.ToList())
        {
            var path = running.FirstOrDefault(item => string.Equals(Path.GetFileName(item.Path), app, StringComparison.OrdinalIgnoreCase)).Path;
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 4, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new Border { Width = 20, Height = 20, VerticalAlignment = VerticalAlignment.Center, Child = new FontIcon { Glyph = "\uE7C3", FontSize = 14, Foreground = Theme.SecondaryText() } };
            if (path is not null)
            {
                _ = LoadAppIconAsync(icon, path);
            }

            row.Children.Add(icon);
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            names.Children.Add(new TextBlock { Text = path is null ? Path.GetFileNameWithoutExtension(app) : AppDisplayName(path) });
            names.Children.Add(new TextBlock { Text = app, FontSize = 11, Foreground = Theme.SecondaryText() });
            Grid.SetColumn(names, 1);
            row.Children.Add(names);
            var remove = new Button { Content = "移除", Padding = new Thickness(10, 2, 10, 2), VerticalAlignment = VerticalAlignment.Center };
            remove.Click += (_, _) =>
            {
                settings.ClipboardExcludedApps.RemoveAll(value => string.Equals(value, app, StringComparison.OrdinalIgnoreCase));
                SettingsService.Save();
                BuildPage("clipboard");
            };
            Grid.SetColumn(remove, 2);
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

        void Add(string exe)
        {
            var name = Path.GetFileName(exe);
            if (name.Length == 0 || settings.ClipboardExcludedApps.Any(value => string.Equals(value, name, StringComparison.OrdinalIgnoreCase)))
            {
                return;
            }

            settings.ClipboardExcludedApps.Add(name);
            SettingsService.Save();
            BuildPage("clipboard");
        }

        var choose = new DropDownButton { Content = "选择应用…" };
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
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

        menu.Items.Add(runningMenu);
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
        menu.Items.Add(browse);
        choose.Flyout = menu;
        _content.Children.Add(choose);
    }

    /// <summary>正在运行、有窗口的程序（去重，按显示名排）：给「选择应用…」用。</summary>
    private static List<(string Path, string Name)> RunningApps()
    {
        var apps = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var process in System.Diagnostics.Process.GetProcesses())
        {
            try
            {
                if (process.MainWindowHandle == IntPtr.Zero || process.Id == Environment.ProcessId)
                {
                    continue;
                }

                var path = process.MainModule?.FileName;
                if (!string.IsNullOrEmpty(path) && !apps.ContainsKey(path))
                {
                    apps[path] = AppDisplayName(path);
                }
            }
            catch (Exception)
            {
                // 别的用户 / 提权进程读不到模块路径：跳过。
            }
            finally
            {
                process.Dispose();
            }
        }

        return apps.Select(pair => (pair.Key, pair.Value)).OrderBy(app => app.Value, StringComparer.CurrentCulture).ToList();
    }

    private static string AppDisplayName(string path)
    {
        try
        {
            var description = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileDescription;
            return string.IsNullOrWhiteSpace(description) ? Path.GetFileNameWithoutExtension(path) : description.Trim();
        }
        catch (Exception)
        {
            return Path.GetFileNameWithoutExtension(path);
        }
    }

    private static async Task LoadAppIconAsync(Border host, string path)
    {
        var png = await Task.Run(() => ShellIcons.LoadPng(path, 1.5, 20));
        if (png is not null)
        {
            host.Child = null;
            host.Background = new ImageBrush { ImageSource = IconSource(png), Stretch = Stretch.Uniform };
        }
    }

    /// <summary>
    /// 设置里的面板示意图（mac ClipboardPanelSketch）：一条搜索线 + 几行，「显示透镜」开着时选中那行展开一块透镜；
    /// 「链接显示网页标题和图片」开着时透镜里画一张小头图。
    /// </summary>
    private static Border ClipboardSketch(bool lens, bool linkPreview)
    {
        var ink = Theme.SecondaryText();
        var line = Theme.Brush("Kitty.Hairline", Windows.UI.Color.FromArgb(20, 0, 0, 0));
        var fill = Theme.Brush("Kitty.Fill.Selected", Windows.UI.Color.FromArgb(18, 0, 0, 0));
        var stack = new StackPanel { Width = 300, Spacing = 4, Padding = new Thickness(10) };
        stack.Children.Add(new Border { Height = 14, CornerRadius = new CornerRadius(3), Background = line });
        for (var row = 0; row < 4; row++)
        {
            var selected = row == 1;
            var block = new StackPanel
            {
                Padding = new Thickness(6, 4, 6, 4),
                Spacing = 4,
                CornerRadius = new CornerRadius(4),
                Background = selected ? fill : null,
            };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            head.Children.Add(new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2), Background = new SolidColorBrush(Theme.Family.Clipboard) });
            head.Children.Add(new Border { Width = 120 + row * 17 % 60, Height = 6, CornerRadius = new CornerRadius(3), Background = ink, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center });
            block.Children.Add(head);
            if (selected && lens)
            {
                var body = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(16, 0, 0, 0) };
                if (linkPreview)
                {
                    body.Children.Add(new Border { Width = 48, Height = 28, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(Theme.Family.Url), Opacity = 0.6 });
                }

                var lines = new StackPanel { Spacing = 4 };
                for (var index = 0; index < 3; index++)
                {
                    lines.Children.Add(new Border { Width = 150 - index * 30, Height = 5, CornerRadius = new CornerRadius(2.5), Background = ink, Opacity = 0.3 });
                }

                body.Children.Add(lines);
                block.Children.Add(body);
            }

            stack.Children.Add(block);
        }

        var sketch = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground(),
            Padding = new Thickness(12),
            Child = new Border
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                CornerRadius = new CornerRadius(8),
                BorderBrush = line,
                BorderThickness = new Thickness(1),
                Child = stack,
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(sketch, lens ? "示意图：选中的条目展开预览" : "示意图：纯列表");
        return sketch;
    }

    private void BuildLauncher()
    {
        if (!ShowIfDisabled(Feature.Launcher))
        {
            return;
        }

        _content.Children.Add(Header("启动器", "应用、系统设置、系统命令、计算和网址直达；网页搜索只有一个兜底。"));
        AddShortcutsLink("launcher");
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
                Foreground = Theme.SecondaryText(),
            });
            Grid.SetColumn(name, 0);
            row.Children.Add(name);

            var url = new TextBlock
            {
                Text = engine.UrlTemplate,
                FontSize = 11,
                Foreground = Theme.SecondaryText(),
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
        AddShortcutsLink("screenshot");
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
        AutomationProperties.SetName(path, "截图保存目录");
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
            Foreground = Theme.SecondaryText(),
            TextWrapping = TextWrapping.Wrap,
        });
        AddToggle("识字后把同一段里的换行接起来",
            "识字和截图翻译都看这个。段和段之间保留换行；中文、日文的行直接接上，其它文字之间加空格。",
            SettingsService.Current.OcrJoinLines,
            value =>
            {
                SettingsService.Current.OcrJoinLines = value;
                SettingsService.Save();
            });

        // 截图历史（PLAN-v8 H3）。
        _content.Children.Add(Section(
            "截图历史", "截图、长截图、钉过的图和录制都记在这里，留 30 天、最多 2 GB，超了先删最旧的。"));
        AddToggle("保留截图历史", "关掉后不再记，已经记下的留着",
            SettingsService.Current.ShotHistory,
            value =>
            {
                SettingsService.Current.ShotHistory = value;
                SettingsService.Save();
            });
        var openHistory = new Button { Content = "打开…" };
        openHistory.Click += (_, _) => ShotHistoryWindow.ShowWindow();
        _content.Children.Add(SettingsUi.Card(string.Empty, "截图历史", "看、拷贝、再钉出来，或者删掉", openHistory));

        if (Features.IsOn(Feature.Recording))
        {
            _content.Children.Add(Section(
                "录屏", "Alt+R 开始 / 停止；录鼠标所在那块屏的整屏，可以带系统声音和麦克风。"));
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
            AddToggle("系统声音", "录默认输出设备的声音（WASAPI 回环）；关掉只录麦克风或只有画面。",
                SettingsService.Current.RecordSystemSound,
                value =>
                {
                    SettingsService.Current.RecordSystemSound = value;
                    SettingsService.Save();
                });
            AddToggle("麦克风", "录默认麦克风，和系统声音混成一条音轨。第一次会要系统麦克风权限。",
                SettingsService.Current.RecordMicrophone,
                value =>
                {
                    SettingsService.Current.RecordMicrophone = value;
                    SettingsService.Save();
                });
            AddToggle("按快捷键后立即开始录音",
                "关掉时先出控制条，点 ● 才开始；适合先调麦克风再用。",
                SettingsService.Current.RecordInstantStart,
                value =>
                {
                    SettingsService.Current.RecordInstantStart = value;
                    SettingsService.Save();
                });

            var folderRow = new Grid { ColumnSpacing = 8 };
            folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var folder = new TextBox
            {
                Text = RecordingHost.Folder,
                IsReadOnly = true,
                FontSize = 13,
            };
            AutomationProperties.SetName(folder, "录制保存目录");
            folderRow.Children.Add(folder);
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
        AddShortcutsLink("translate");
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            _content.Children.Add(new TextBlock { Text = "翻译服务还没准备好。", Foreground = Theme.SecondaryText() });
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
                Foreground = Theme.SecondaryText(),
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

            var enabled = new CheckBox
            {
                IsChecked = service.Enabled,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(enabled, service.Name + " 启用");
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
                Foreground = Theme.SecondaryText(),
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
            Foreground = Theme.SecondaryText(),
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
            TranslateKinds.DeepL => service.UsesDeepLX == true ? "DeepLX" : "DeepL",
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
            deepLx = new ToggleSwitch { Header = "用自建 DeepLX", IsOn = service.UsesDeepLX == true };
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
            Foreground = Theme.SecondaryText(),
            IsTextSelectionEnabled = true,
        };
        panel.Children.Add(result);

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
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
        AddShortcutsLink("hotkeys");

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
            var iconTask = Task.Run(() => ShellIcons.LoadPng(
                Paths.ExecutablePath,
                (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1));
            if (iconTask.Wait(500) && iconTask.Result is { Length: > 0 } icon)
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
                return new TextBlock { Text = "更新日志不在发布目录里。", Foreground = Theme.SecondaryText() };
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
            return new TextBlock { Text = "更新日志读不出来。", Foreground = Theme.SecondaryText() };
        }
    }

    public void AuditAccessibility(string page = "settings") => AccessibilityAudit.Run(_content, "settings-" + page);

#if DEBUG
    /// <summary>截图自检用（--uninstall-dialog）：只把卸载对话框弹出来；默认按钮是「取消」。</summary>
    public void ShowUninstallDialogForSnapshot() => _ = UninstallAsync();

    /// <summary>截图自检用（--settings-scroll=）：滚到页面里某一段（超出范围自动停在底部）。</summary>
    public void ScrollForSnapshot(double offset) => _scroll.ChangeView(null, offset, null, disableAnimation: true);
#endif

    private async Task UninstallAsync()
    {
        // R37 / PLAN-setup-inno I11：安装程序装的交给 Inno 的 unins000.exe：它自己确认（含「同时删除我的数据」），
        // 先用 --quit 叫我们退出，删快捷方式、开机启动、凭据、登记和程序文件。这里不再弹自己的对话框。
        if (SetupRecord.Uninstaller() is { } uninstaller)
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uninstaller)
                {
                    UseShellExecute = true,
                });
                Log.Info("uninstall.handoff");
                if (ShellRuntime.Instance is { } runtime)
                {
                    runtime.Exit();
                }
                else
                {
                    Microsoft.UI.Xaml.Application.Current.Exit();
                }

                return;
            }
            catch (Exception ex)
            {
                // 打不开（被拦、被删）就退回下面自己的那一套。
                Log.Warn($"uninstall.handoff-failed {ex.GetType().Name}");
            }
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "从这台电脑移除 Kitty Tools？",
            Content = "会删掉开始菜单快捷方式、开机启动和凭据管理器里的密钥。程序文件要你自己删。",
            PrimaryButtonText = "只卸载",
            SecondaryButtonText = "卸载并删除数据",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = _content.XamlRoot,
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.None)
        {
            return;
        }

        StartMenuShortcut.Remove();
        Autostart.Set(false);
        var deleted = Credentials.DeleteAll();
        var removeData = result == ContentDialogResult.Secondary;
        Log.Info($"uninstall shortcut credentials={deleted} data={removeData}");
        if (removeData)
        {
            // R25：先停掉所有会写数据目录的后台服务、关掉 SQLite，再挪进回收站。
            ShellRuntime.Instance?.PrepareForUninstall();
            if (!UninstallCleanup.Recycle(Paths.DataDirectory))
            {
                var failed = new ContentDialog
                {
                    RequestedTheme = Theme.ElementTheme,
                    Title = "数据目录没删干净",
                    Content = "可能还有程序占用着文件。请手动删除：" + Paths.DataDirectory,
                    PrimaryButtonText = "打开文件夹",
                    CloseButtonText = "关闭",
                    XamlRoot = _content.XamlRoot,
                };
                if (await failed.ShowAsync() == ContentDialogResult.Primary)
                {
                    OpenDataDirectory();
                }
            }
        }

        var exe = Environment.ProcessPath;
        var folder = exe is null ? null : Path.GetDirectoryName(exe);
        if (!string.IsNullOrEmpty(folder))
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + folder + "\"",
                    UseShellExecute = true,
                });
            }
            catch
            {
                // 打不开就算了。
            }
        }

        Microsoft.UI.Xaml.Application.Current.Exit();
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

    private static string FamilyForPage(string tag) => tag switch
    {
        "hotkeys" or "shortcuts" => "shortcut",
        "clipboard" => "clipboard",
        "translate" => "translate",
        "launcher" => "launcher",
        "screenshot" => "capture",
        "about" => "general",
        _ => "general",
    };

    private static UIElement Header(string title, string subtitle)
        => SettingsUi.Header(title, subtitle);

    /// <summary>页头下面一行「查看全部快捷键…」（PLAN-v8 第 4 批）：点开速查表，停在这一页那一类。</summary>
    private void AddShortcutsLink(string page)
    {
        var link = new HyperlinkButton
        {
            Content = "查看全部快捷键…",
            Padding = new Thickness(0),
            Margin = new Thickness(0, -4, 0, 4),
        };
        link.Click += (_, _) => _ = ShortcutsSheet.ShowAsync(_content.XamlRoot, page);
        _content.Children.Add(link);
    }

    /// <summary>PLAN-v7 §3.7：外观三张缩略图（跟随系统 / 浅色 / 深色）。</summary>
    private FrameworkElement ThemePicker()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var options = new[]
        {
            ("system", "跟随系统", Theme.Argb(255, 245, 245, 245), Theme.Argb(255, 32, 32, 32)),
            ("light", "浅色", Theme.Argb(255, 250, 250, 250), Theme.Argb(255, 250, 250, 250)),
            ("dark", "深色", Theme.Argb(255, 28, 28, 28), Theme.Argb(255, 28, 28, 28)),
        };
        var current = SettingsService.Current.Theme;
        foreach (var (key, name, left, right) in options)
        {
            var preview = new Border
            {
                Width = 56,
                Height = 36,
                CornerRadius = new CornerRadius(4),
                Background = new LinearGradientBrush
                {
                    StartPoint = new Windows.Foundation.Point(0, 0),
                    EndPoint = new Windows.Foundation.Point(1, 0),
                    GradientStops =
                    {
                        new GradientStop { Color = left, Offset = 0 },
                        new GradientStop { Color = right, Offset = 1 },
                    },
                },
            };
            var content = new StackPanel { Spacing = 4 };
            content.Children.Add(preview);
            content.Children.Add(new TextBlock
            {
                Text = name,
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            var button = new Button
            {
                Content = content,
                Padding = new Thickness(3),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(current == key || current == "system" && key == "system" ? 2 : 1),
                BorderBrush = current == key
                    ? new SolidColorBrush(Theme.AccentColor)
                    : Theme.Brush("Kitty.Hairline", Theme.Argb(20, 0, 0, 0)),
                CornerRadius = new CornerRadius(6),
            };
            AutomationProperties.SetName(button, "外观：" + name);
            button.Click += (_, _) =>
            {
                SettingsService.Current.Theme = key;
                SettingsService.Save();
                Theme.ApplyTo(_shell);
                _nav.RequestedTheme = Theme.ElementTheme;
                BuildPage(_currentPage);
            };
            row.Children.Add(button);
        }

        return row;
    }

    /// <summary>PLAN-v7 U5：跟随系统 + 8 个色点，选中的中间有白点。</summary>
    private FrameworkElement AccentPicker()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var current = SettingsService.Current.Accent == "brand" ? "pink" : SettingsService.Current.Accent;
        var options = new List<(string Key, string Name, Color Color)>
        {
            ("system", "跟随系统", Theme.AccentColor),
        };
        foreach (var accent in AccentPalette.All)
        {
            options.Add((accent.Key, accent.Name, Theme.ToColor(AccentPalette.Value(accent, Theme.EffectiveTheme == ElementTheme.Dark))));
        }

        foreach (var (key, name, color) in options)
        {
            var selected = string.Equals(current, key, StringComparison.OrdinalIgnoreCase);
            var dot = new Border
            {
                Width = 24,
                Height = 24,
                CornerRadius = new CornerRadius(12),
                Background = new SolidColorBrush(color),
                BorderBrush = new SolidColorBrush(selected ? Theme.OnAccentColor : Theme.Argb(40, 128, 128, 128)),
                BorderThickness = new Thickness(selected ? 2 : 1),
                Child = selected
                    ? new Border
                    {
                        Width = 6,
                        Height = 6,
                        CornerRadius = new CornerRadius(3),
                        Background = new SolidColorBrush(Theme.OnAccentColor),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                    }
                    : null,
            };
            var button = new Button
            {
                Content = dot,
                Width = 32,
                Height = 32,
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(16),
            };
            ToolTipService.SetToolTip(button, name);
            AutomationProperties.SetName(button, "强调色：" + name);
            button.Click += (_, _) =>
            {
                SettingsService.Current.Accent = key;
                SettingsService.Save();
                Theme.ApplyAccent();
                BuildPage(_currentPage);
            };
            row.Children.Add(button);
        }

        return row;
    }

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
