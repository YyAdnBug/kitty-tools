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

internal sealed partial class SettingsWindow : Window
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
                // 从左栏换页：翻译服务的详情子页收起来，回来时是列表。
                _serviceDetail = null;
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

    public void ShowPage(bool welcome, string page = "general", string? service = null)
    {
        Motion.Refresh();
        _firstRun = welcome;
        // R34：同一页反复开关不重建 XAML 树（每次重建约 +5 MB）；换页或第一次才建。
        if (service is not null)
        {
            // 翻译错误卡的「打开设置」：直达那个服务的详情（D3：设置里的子页）。
            _serviceDetail = service;
        }

        if (welcome || _stale || page != _currentPage || _content.Children.Count == 0 || service is not null)
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

        _content.Children.Add(SettingsUi.Card("外观", "跟随系统、浅色或深色。", ThemePicker()));

        _content.Children.Add(SettingsUi.Card("强调色", "跟随系统，或者固定成一种颜色。", AccentPicker()));

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
            _content.Children.Add(SettingsUi.Card(
                Features.Title(feature),
                Features.Blurb(feature),
                SettingsUi.Toggle(Features.IsOn(feature), isOn =>
                {
                    Features.Set(feature, isOn);
                    BuildPage(_currentPage);
                }, Features.Title(feature)),
                leading: FeatureTile(feature)));
        }

        _content.Children.Add(SettingsUi.Section("数据"));
        var dataButton = SettingsUi.Card(
            "数据目录",
            "数据库、图片、日志和设置都放在这里。",
            null,
            OpenDataDirectory);
        _content.Children.Add(dataButton);
        _content.Children.Add(SettingsUi.Card(
            "从这台电脑移除 Kitty Tools…",
            "删掉开始菜单快捷方式、开机启动和保存的密钥；数据可以留着。",
            null,
            () => _ = UninstallAsync()));

        BuildSyncSection();

        _content.Children.Add(SettingsUi.Section(
            "导出与导入", "换电脑、重装或备份时用。密钥默认不带；片段、收藏、生词本是合并，不会删本机已有的。"));
        _content.Children.Add(SettingsUi.Card(
            "导出…",
            "把设置、翻译服务、网页搜索、片段与收藏存成一个文件；要带密钥就设一个密码。",
            null,
            () => _ = ExportArchiveAsync()));
        _content.Children.Add(SettingsUi.Card(
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
        _content.Children.Add(SettingsUi.Card("图片当前占用", $"普通图片约 {service.Store.OrdinaryImageBytes / 1_048_576.0:F0} MB，共 {service.Store.Count} 条"));

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
            });
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
            });
        AddToggle("单击条目直接粘贴", "关着时单击选中、双击粘贴；打开后点一下就粘贴，想先看内容用 ↑↓，Ctrl 单击、Shift 单击照常多选",
            settings.ClipboardPasteOnClick,
            isOn =>
            {
                settings.ClipboardPasteOnClick = isOn;
                SettingsService.Save();
            });

        // 内容
        _content.Children.Add(SettingsUi.Section("内容"));
        AddToggle("默认粘贴为纯文本", "打开后 Enter 粘贴纯文本，Shift+Enter 保留格式；文字的格式总是记下来",
            settings.ClipboardPastePlain,
            isOn =>
            {
                settings.ClipboardPastePlain = isOn;
                SettingsService.Save();
            });
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
            });

        // 隐私
        _content.Children.Add(SettingsUi.Section("隐私"));
        AddToggle("不记录疑似密钥和银行卡号", string.Empty,
            settings.ClipboardBlockSensitive,
            isOn =>
            {
                settings.ClipboardBlockSensitive = isOn;
                SettingsService.Save();
            });
        AddToggle("退出时清空普通历史", string.Empty,
            settings.ClipboardClearOnQuit,
            isOn =>
            {
                settings.ClipboardClearOnQuit = isOn;
                SettingsService.Save();
            });
        AddToggle("锁屏时清空普通历史", string.Empty,
            settings.ClipboardClearOnLock,
            isOn =>
            {
                settings.ClipboardClearOnLock = isOn;
                SettingsService.Save();
            });
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

    /// <summary>
    /// 设置 › 启动器（PLAN-v9-launcher §5，照 mac LauncherTab）：功能开关 ｜ 呼出时切到英文输入法、启动器里的按键 ｜ 文件搜索 ｜
    /// 浏览器书签与历史（只列装了的，每家书签 / 也搜浏览历史两个开关，下面写读到了几条）｜ 网页搜索与快捷链接（每条一个兜底开关、
    /// 能新建和编辑、↑↓ 排序，有问题的橙字写出来）+ 有本地结果时也显示兜底搜索 ｜ 使用记录（清空…，先确认）。
    /// </summary>
    private void BuildLauncher()
    {
        if (!ShowIfDisabled(Feature.Launcher))
        {
            return;
        }

        _content.Children.Add(Header("启动器", "搜应用、系统设置、文件、书签、网址、路径、算式（也能换算单位和进制）和系统命令（lock、quit、kill 这些），Enter 打开，Ctrl+K 看这一项的全部操作。"));
        AddShortcutsLink("launcher");
        var settings = SettingsService.Current;

        AddToggle("呼出时切到英文输入法", "只在搜索框里生效，离开后恢复；要搜中文时先关掉",
            settings.LauncherRomanInput,
            isOn =>
            {
                settings.LauncherRomanInput = isOn;
                SettingsService.Save();
            });

        // 文件搜索
        _content.Children.Add(Section("文件搜索",
            "「open 文件名」搜文件并打开，「find 文件名」在资源管理器中显示；搜的是 Windows 搜索建了索引的位置，不想被搜到的文件夹从索引里去掉。"));
        _content.Children.Add(SettingsUi.Card(
            "建了索引的位置", "设置 › 隐私和安全性 › 搜索 Windows", null,
            () => LauncherOpeners.Start("ms-settings:cortana-windowssearch")));

        // 浏览器书签与历史
        _content.Children.Add(Section("浏览器书签与历史", "只列本机装了的浏览器。"));
        var installed = Browsers.Installed();
        if (installed.Count == 0)
        {
            _content.Children.Add(SettingsUi.Card("没有找到浏览器", "装了 Edge、Chrome、Firefox 这些之后会列在这里"));
        }

        foreach (var browser in installed)
        {
            AddBrowserRows(settings, browser);
        }

        // 读完数据重画这一页时别再读一次：浏览器开着时 History 一直在改，不拦会一遍遍重建、滚动跳回顶部。
        if (!_browsersJustRefreshed)
        {
            _ = RefreshBrowsersAsync(settings);
        }

        _browsersJustRefreshed = false;

        // 网页搜索与快捷链接
        _content.Children.Add(Section("网页搜索与快捷链接",
            "网址里有 {query} 的是搜索（「关键词 空格 内容」直达，开关 = 没有本地结果时兜底），没有的是快捷链接。搜索的关键词重复时用靠前的；点「编辑」改名称、关键词和网址。"));
        var engines = (settings.LauncherSearchEngines ?? WebSearch.Defaults()).Select(Copy).ToList();

        void Persist()
        {
            settings.LauncherSearchEngines = engines;
            SettingsService.Save();
            BuildPage("launcher");
        }

        for (var index = 0; index < engines.Count; index++)
        {
            _content.Children.Add(EngineRow(engines, index, Persist));
        }

        var add = new Button { Content = "＋ 添加搜索或快捷链接" };
        AutomationProperties.SetName(add, "添加搜索或快捷链接");
        var addMenu = new MenuFlyout();
        foreach (var preset in WebSearch.Presets.Where(preset => engines.All(engine => engine.Id != preset.Id)))
        {
            var item = new MenuFlyoutItem { Text = $"{preset.Name}（{preset.Keyword}）" };
            item.Click += (_, _) =>
            {
                engines.Add(Copy(preset));
                Persist();
            };
            addMenu.Items.Add(item);
        }

        if (addMenu.Items.Count > 0)
        {
            addMenu.Items.Add(new MenuFlyoutSeparator());
        }

        var custom = new MenuFlyoutItem { Text = "自定义搜索或快捷链接…" };
        custom.Click += async (_, _) =>
        {
            var engine = new KittyTools.Core.SearchEngine
            {
                Id = "custom-" + Guid.NewGuid().ToString("N")[..8],
                Name = string.Empty,
                Keyword = string.Empty,
                UrlTemplate = "https://",
                Fallback = false,
            };
            if (await EditEngineAsync(engine, engines.Append(engine).ToList()))
            {
                engines.Add(engine);
                Persist();
            }
        };
        addMenu.Items.Add(custom);
        add.Flyout = addMenu;
        _content.Children.Add(add);

        AddToggle("有本地结果时也显示兜底搜索", "关着时只在没有本地结果时才列兜底搜索",
            settings.LauncherFallbackAlways,
            isOn =>
            {
                settings.LauncherFallbackAlways = isOn;
                SettingsService.Save();
            });

        // 使用记录
        _content.Children.Add(Section("使用记录",
            "启动器按用过的次数和时间排序，空搜索框里先列收藏（Ctrl+D 加入），再列「常用」。在「常用」里选中一项按 Ctrl+Delete 可以单独移除，Ctrl+Z 撤销。"));
        var clear = new Button { Content = "清空使用记录…", Foreground = Theme.Critical() };
        clear.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                RequestedTheme = Theme.ElementTheme,
                Title = "清空启动器的使用记录？",
                Content = "「常用」和按使用习惯的排序会从头开始学，收藏不动。",
                PrimaryButtonText = "清空",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = _content.XamlRoot,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }

            LauncherUsageStore.Instance?.Clear();
            NoticeHost.Show("已清空", "「常用」从头开始学", NoticeTone.Normal);
        };
        _content.Children.Add(clear);
    }

    /// <summary>这一次重建是浏览器数据读完触发的（不再触发下一次读）。</summary>
    private bool _browsersJustRefreshed;

    private static KittyTools.Core.SearchEngine Copy(KittyTools.Core.SearchEngine engine) => new()
    {
        Id = engine.Id,
        Name = engine.Name,
        Keyword = engine.Keyword,
        UrlTemplate = engine.UrlTemplate,
        Fallback = engine.Fallback,
    };

    /// <summary>
    /// 一家浏览器（mac browserRows）：书签开关，开着时下面写读到了几条（没读到是橙字）；书签开着时下面缩进一行「也搜浏览历史」（默认关）。
    /// </summary>
    private void AddBrowserRows(Settings settings, BrowserInfo browser)
    {
        var bookmarkIds = Browsers.BookmarkIds(settings).ToList();
        var historyIds = (settings.LauncherHistoryBrowsers ?? new List<string>()).ToList();
        var bookmarksOn = bookmarkIds.Contains(browser.Id);
        // 读到几条写在名字下面（mac browserRows）；书签关着时只有名字。
        var (bookmarkText, bookmarkProblem) = bookmarksOn
            ? StatusText(BrowserIndex.Status(browser.Id, history: false), "书签", "书签文件里一条书签都没有", "没找到书签文件")
            : (string.Empty, false);
        _content.Children.Add(SettingsUi.Card(
            browser.Name,
            bookmarkText,
            SettingsUi.Toggle(bookmarksOn, isOn =>
            {
                var ids = Browsers.BookmarkIds(settings).Where(id => id != browser.Id).ToList();
                if (isOn)
                {
                    ids.Add(browser.Id);
                }

                settings.LauncherBookmarkBrowsers = ids;
                SettingsService.Save();
                BuildPage("launcher");
            }, $"读 {browser.Name} 的书签"),
            problem: bookmarkProblem));
        if (bookmarksOn)
        {
            var historyOn = historyIds.Contains(browser.Id);
            var (historyText, historyProblem) = historyOn
                ? StatusText(BrowserIndex.Status(browser.Id, history: true), "历史", "浏览历史里还没有常去的网页", "没找到浏览历史文件")
                : ("去过两次以上或手输过的网页，排在书签后面", false);
            var historyCard = SettingsUi.Card(
                "也搜浏览历史",
                historyText,
                SettingsUi.Toggle(historyOn, isOn =>
                {
                    var ids = (settings.LauncherHistoryBrowsers ?? new List<string>()).Where(id => id != browser.Id).ToList();
                    if (isOn)
                    {
                        ids.Add(browser.Id);
                    }

                    settings.LauncherHistoryBrowsers = ids;
                    SettingsService.Save();
                    BuildPage("launcher");
                }, $"也搜 {browser.Name} 的浏览历史"),
                problem: historyProblem);
            historyCard.Margin = new Thickness(24, 0, 0, 0);
            _content.Children.Add(historyCard);
        }
    }

    /// <summary>开关下的说明：「已读到 N 条书签」；没读到是问题（橙字）；还没读完写「正在读取…」。</summary>
    private static (string Text, bool Problem) StatusText(BrowserStatus? status, string noun, string empty, string missing)
        => status switch
        {
            null or { State: BrowserReadState.Reading } => ("正在读取…", false),
            { State: BrowserReadState.Read, Count: > 0 } read => ($"已读到 {read.Count} 条{noun}", false),
            { State: BrowserReadState.Read } => (empty, true),
            _ => (missing, true),
        };

    /// <summary>开关变了、页面重建时：浏览器数据该重读就在后台读，读完还停在这一页就再画一次（条数就出来了）。</summary>
    private async Task RefreshBrowsersAsync(Settings settings)
    {
        if (await BrowserIndex.RefreshAsync(Browsers.BookmarkIds(settings), Browsers.HistoryIds(settings), force: true) &&
            _currentPage == "launcher" && !IsClosed)
        {
            _browsersJustRefreshed = true;
            BuildPage("launcher");
        }
    }

    /// <summary>一条搜索 / 快捷链接（mac EngineListRow）：名称 + 种类或橙色的问题、关键词键帽、兜底开关（快捷链接没有）、↑ ↓ 编辑 删除。</summary>
    private Border EngineRow(List<KittyTools.Core.SearchEngine> engines, int index, Action persist)
    {
        var engine = engines[index];
        var problem = WebSearch.Problem(engine, engines);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (engine.Keyword.Length > 0)
        {
            var keyCap = KeyCap.Create(engine.Keyword);
            keyCap.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(keyCap, "关键词 " + engine.Keyword);
            controls.Children.Add(keyCap);
        }

        if (!engine.IsQuicklink)
        {
            controls.Children.Add(SettingsUi.Toggle(engine.Fallback, isOn =>
            {
                engine.Fallback = isOn;
                persist();
            }, $"「{WebSearch.Title(engine)}」没有本地结果时兜底"));
        }

        Button Small(string text, string name, bool enabled, Action action)
        {
            var button = new Button { Content = text, Padding = new Thickness(8, 2, 8, 2), IsEnabled = enabled };
            AutomationProperties.SetName(button, name);
            button.Click += (_, _) => action();
            controls.Children.Add(button);
            return button;
        }

        Small("↑", "上移", index > 0, () =>
        {
            (engines[index - 1], engines[index]) = (engines[index], engines[index - 1]);
            persist();
        });
        Small("↓", "下移", index < engines.Count - 1, () =>
        {
            (engines[index + 1], engines[index]) = (engines[index], engines[index + 1]);
            persist();
        });
        Small("编辑…", "编辑 " + WebSearch.Title(engine), true, async () =>
        {
            if (await EditEngineAsync(engine, engines))
            {
                persist();
            }
        });
        Small("删除", "删除 " + WebSearch.Title(engine), true, async () =>
        {
            // 预置的直接删（「+」里能加回来），自定义的先确认。
            if (!WebSearch.IsPreset(engine.Id))
            {
                var dialog = new ContentDialog
                {
                    RequestedTheme = Theme.ElementTheme,
                    Title = $"删除「{WebSearch.Title(engine)}」？",
                    Content = "自定义的名称、关键词和网址删掉就找不回来了。",
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

            engines.Remove(engine);
            persist();
        });

        return SettingsUi.Card(
            WebSearch.Title(engine),
            problem ?? WebSearch.KindTitle(engine),
            controls,
            problem: problem is not null);
    }

    /// <summary>
    /// 编辑一条（mac SearchEngineDetail，L3）：名称、关键词、网址三个框，下面橙字写现在有什么问题；网址空着或不完整时「保存」置灰。
    /// 改的是传进来的那一条；点「保存」才返回 true。
    /// </summary>
    private async Task<bool> EditEngineAsync(KittyTools.Core.SearchEngine engine, List<KittyTools.Core.SearchEngine> list)
    {
        var draft = Copy(engine);
        var name = new TextBox { Header = "名称", Text = draft.Name, PlaceholderText = "比如：GitHub" };
        var keyword = new TextBox { Header = "关键词（可空）", Text = draft.Keyword, PlaceholderText = "比如：gh" };
        var url = new TextBox
        {
            Header = "网址",
            Text = draft.UrlTemplate,
            PlaceholderText = "https://github.com/search?q={query}",
        };
        var hint = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Theme.SecondaryText(),
        };
        var panel = new StackPanel { Spacing = 10, MinWidth = 420 };
        panel.Children.Add(name);
        panel.Children.Add(keyword);
        panel.Children.Add(url);
        panel.Children.Add(hint);
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = engine.Name.Trim().Length == 0 ? "新建搜索或快捷链接" : "编辑「" + WebSearch.Title(engine) + "」",
            Content = panel,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _content.XamlRoot,
        };

        void Validate()
        {
            draft.Name = name.Text;
            draft.Keyword = keyword.Text.Trim();
            draft.UrlTemplate = url.Text.Trim();
            var others = list.Select(item => item.Id == engine.Id ? draft : item).ToList();
            var problem = WebSearch.Problem(draft, others);
            hint.Text = problem ?? "网址里放 {query} 就是搜索（「关键词 空格 内容」直达），不放就是快捷链接；也可以填 C:\\ 这类文件夹路径。";
            hint.Foreground = problem is null
                ? Theme.SecondaryText()
                : Theme.Brush("SystemFillColorCautionBrush", Windows.UI.Color.FromArgb(255, 157, 93, 0));
            // 名称、网址这两样不对就不让存；关键词重复、用不上只提醒（mac 也只写橙字）。
            dialog.IsPrimaryButtonEnabled = problem is not ("还没填名称" or "网址不完整") &&
                                            !(problem ?? string.Empty).StartsWith("关键词「", StringComparison.Ordinal);
        }

        name.TextChanged += (_, _) => Validate();
        keyword.TextChanged += (_, _) => Validate();
        url.TextChanged += (_, _) => Validate();
        Validate();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return false;
        }

        engine.Name = draft.Name.Trim();
        engine.Keyword = draft.Keyword;
        engine.UrlTemplate = draft.UrlTemplate;
        return true;
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
        _content.Children.Add(SettingsUi.Card("截图历史", "看、拷贝、再钉出来，或者删掉", openHistory));

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

    /// <summary>功能关掉了：这一页只留一张「已关闭」的卡和去打开的按钮（第三版 §2.3）。</summary>
    private bool ShowIfDisabled(Feature feature)
    {
        if (Features.IsOn(feature))
        {
            return true;
        }

        _content.Children.Add(Header(Features.Title(feature), string.Empty));
        _content.Children.Add(SettingsUi.Card(
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
                definition.DisplayName,
                binding.VirtualKey == 0
                    ? "未设置"
                    : failure is null
                        ? statusText == "正常" ? "正在使用" : "已设置"
                        : failure,
                right,
                leading: HotKeyTile(definition.Action));
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
            "检查更新",
            UpdateService.AvailableVersion is { } available
                ? $"有可用的新版本 {available}"
                : "每天检查一次；下载后可以直接安装。",
            null,
            () => _ = CheckOrInstallAsync());
        _content.Children.Add(updateCard);

        _content.Children.Add(SettingsUi.Card(
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

    /// <summary>通用 › 功能一行的家族色块（mac FeatureToggle）：和侧栏那一页同一个；录屏没有自己的页，用截图的粉 + 录制符号。</summary>
    private static Border FeatureTile(Feature feature)
    {
        if (feature == Feature.Recording)
        {
            return KindTile.Create("capture", Glyphs.Record, 20);
        }

        var tag = Features.Key(feature);
        return KindTile.Create(FamilyForPage(tag), Pages.First(page => page.Tag == tag).Glyph, 20);
    }

    /// <summary>快捷键页一行的家族色块（mac HotKeyAction.symbol / color）：剪贴板蓝、启动器紫、翻译绿、截图和录屏粉。</summary>
    private static Border HotKeyTile(string action)
    {
        var family = Features.ForHotKey(action) switch
        {
            Feature.Clipboard => "clipboard",
            Feature.Launcher => "launcher",
            Feature.Translate => "translate",
            _ => "capture",
        };
        var glyph = action switch
        {
            HotKeyActions.Clipboard => Glyphs.ClipboardHistory,
            HotKeyActions.Launcher => Glyphs.Command,
            HotKeyActions.SelectionTranslate => Glyphs.Translate,
            HotKeyActions.InputTranslate => Glyphs.TextTranslate,
            HotKeyActions.ScreenshotTranslate => Glyphs.ScreenshotTranslate,
            HotKeyActions.ScreenshotLast => Glyphs.ToolRectangle,
            HotKeyActions.Ocr => Glyphs.Ocr,
            HotKeyActions.Record => Glyphs.Record,
            HotKeyActions.ShotHistory => Glyphs.Clock,
            HotKeyActions.TranslateReplace => Glyphs.Swap,
            _ => Glyphs.Screenshot,
        };
        return KindTile.Create(family, glyph, 20);
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
        => SettingsUi.Header(title, subtitle, Pages.FirstOrDefault(page => page.Title == title).Glyph);

    /// <summary>UI 截图自检：内容滚到底（设置 › 翻译的服务列表在一屏以下）。</summary>
    internal void ScrollToEndForProbe()
    {
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, _scroll.ScrollableHeight, null, disableAnimation: true);
    }

    /// <summary>启动器的「快捷键速查表」：设置窗排好版之后弹（ContentDialog 要 XamlRoot）。</summary>
    public void ShowShortcutsSheet()
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (_content.XamlRoot is { } root)
            {
                _ = ShortcutsSheet.ShowAsync(root, null);
            }
        });
    }

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

    private void AddToggle(string title, string subtitle, bool value, Action<bool> changed)
        => _content.Children.Add(SettingsUi.Card(
            title,
            subtitle,
            SettingsUi.Toggle(value, changed, title)));

    private void AddCombo(
        string title, string subtitle, string[] items, int selected, Action<int> changed)
        => _content.Children.Add(SettingsUi.Card(
            title,
            subtitle,
            SettingsUi.Combo(items, selected, changed, title)));

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
