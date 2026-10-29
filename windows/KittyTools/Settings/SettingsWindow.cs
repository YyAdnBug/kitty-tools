// 设置窗：左侧 NavigationView（带图标），右边每页一个大标题 + 一组组设置卡，Mica。
// AOT 下 NavigationView 崩溃的根因（发布目录缺 PRI）第二版第 2 批已经修好，这一批换回 NavigationView（PLAN-v2 §2b / §3.4）。
// 2026-10-29 用户要求各页的布局和 mac 一致：侧栏同序、顶上「搜索设置」、关于用 App 图标、记住上次的页；
// 每组的说明写在组下面（脚注）；功能页第一行是「启用 X」，功能关着时下面变灰（同 mac gated）；和 mac 不一样的地方见 MAC-DIFF.md。
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
    private readonly NavigationViewItem _noMatch;
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _content;
    private readonly Windows.Win32.Foundation.HWND _hwnd;
    private readonly int _width;
    private readonly int _height;

    private bool _firstRun;
    private bool? _microphoneAllowed;

    // 功能关着时这一页变灰（mac gated(by:)）：「启用 X」那一行之后加的都变灰、不接点击，_ungated 里的（清空、导出这类管数据的）除外。
    private Feature? _gateFeature;
    private int _gateFrom;
    private readonly HashSet<UIElement> _ungated = new();
    private bool _suppressNav;
    private string _currentPage = "general";
    private string? _recordingAction;

    // REVIEW R44：别处存了设置（截图记上次区域、翻译窗记位置、托盘里的开关、同步……）时不当场重建这一页，
    // 只记下来，等窗口下次显示、或者从别的窗口切回来时再建；在这一页里自己改的，控件已经是新值，不用重建。
    private bool _stale;
    private bool _active;

    // 侧栏顺序同 mac：通用 / 剪贴板 / 启动器 / 翻译 / 截图 / 录制 / 快捷键 / 关于（mac 独有的几页没有）。
    private static readonly (string Tag, string Title, string Glyph)[] Pages =
    {
        ("general", "通用", "\uE713"),
        ("clipboard", "剪贴板", "\uE8C8"),
        ("launcher", "启动器", "\uE721"),
        ("translate", "翻译", "\uE774"),
        ("screenshot", "截图", "\uE722"),
        ("record", "录制", Glyphs.Record),
        ("hotkeys", "快捷键", "\uE765"),
        ("about", "关于", "\uE946"),
    };

    /// <summary>侧栏「搜索设置」按页名和这些词筛（同 mac SettingsPage.keywords，换成 Windows 上的说法）。</summary>
    private static readonly Dictionary<string, string[]> PageKeywords = new()
    {
        ["general"] = new[]
        {
            "外观", "浅色", "深色", "暗黑", "主题", "跟随系统", "强调色", "主题色", "颜色", "开机", "登录", "自启", "启动", "权限", "麦克风",
            "隐私", "导出", "导入", "备份", "恢复", "迁移", "换电脑", "配置", "功能", "模块", "关闭", "停用", "启用", "不用",
            "同步", "OneDrive", "云盘", "多台", "几台", "另一台", "数据", "目录", "卸载", "移除",
        },
        ["clipboard"] = new[]
        {
            "历史", "天数", "保留", "永久", "图片", "占用", "预览", "链接", "网页", "格式", "纯文本", "识别", "文字", "OCR", "隐私",
            "密钥", "银行卡", "清空", "退出", "锁屏", "排除", "应用", "收藏", "收藏夹", "片段", "密码", "敏感", "标题", "透镜", "单击",
            "双击", "点击", "粘贴",
        },
        ["launcher"] = new[]
        {
            "英文", "输入法", "书签", "浏览历史", "历史", "浏览器", "Edge", "Chrome", "Firefox", "Brave", "索引", "搜索", "引擎",
            "快捷链接", "关键词", "兜底", "使用记录", "常用", "最近", "收藏", "文件", "open", "find", "按键", "速查",
        },
        ["translate"] = new[]
        {
            "语言", "第一语言", "第二语言", "字号", "换行", "自动复制", "复制即译", "历史", "导出", "CSV", "Anki", "位置", "浮窗位置",
            "鼠标", "清空", "服务", "密钥", "查词", "词典", "单词", "音标", "例句", "生词本", "收藏", "智谱", "OpenAI", "Anthropic",
            "DeepL", "Google", "百度", "有道", "微软", "火山", "腾讯", "AI", "模型", "按键", "速查",
        },
        ["screenshot"] = new[]
        {
            "保存", "存储", "目录", "文件夹", "识字", "换行", "标注", "长截图", "钉图", "截图历史", "按键", "速查",
        },
        ["record"] = new[]
        {
            "录屏", "录音", "视频", "保存", "文件夹", "系统声音", "麦克风", "来源", "立即开始", "控制条", "帧率", "点按", "按键", "速查",
        },
        ["hotkeys"] = new[] { "快捷键", "热键", "冲突", "录制", "恢复默认", "速查", "按键", "钉图" },
        ["about"] = new[] { "版本", "更新", "日志", "发布", "检查更新", "自动检查" },
    };

    public SettingsWindow()
    {
        Title = Paths.ProductName + " 设置";
        // 透明底：功能关着时变灰的卡不接点击（IsHitTestVisible = false），滚轮落在它们上面时也要能滚动这一页。
        _content = new StackPanel
        {
            Spacing = 8,
            Margin = new Thickness(0, 0, 8, 0),
            Background = new SolidColorBrush(Colors.Transparent),
        };
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
            Content = _scroll,
            RequestedTheme = Theme.ElementTheme,
        };
        // 侧栏顶上「搜索设置」（mac .searchable(placement: .sidebar)）：按页名和每页的关键词筛侧栏。
        var search = new AutoSuggestBox { PlaceholderText = "搜索设置", QueryIcon = new SymbolIcon(Symbol.Find) };
        AutomationProperties.SetName(search, "搜索设置");
        search.TextChanged += (_, args) =>
        {
            if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            {
                FilterPages(search.Text);
            }
        };
        search.QuerySubmitted += (_, _) => FilterPages(search.Text);
        _nav.AutoSuggestBox = search;
        foreach (var (tag, title, glyph) in Pages)
        {
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                VerticalAlignment = VerticalAlignment.Center,
            };
            // 关于用 App 图标（mac：裁掉四周留白的 App 图标，和别的色块一样大）。
            row.Children.Add(tag == "about" ? AppIconImage(20) : (FrameworkElement)KindTile.Create(FamilyForPage(tag), glyph, 20));
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

        _noMatch = new NavigationViewItem
        {
            Content = new TextBlock { Text = "没有匹配的设置", Foreground = Theme.SecondaryText() },
            IsEnabled = false,
            SelectsOnInvoked = false,
            Visibility = Visibility.Collapsed,
        };
        _nav.MenuItems.Add(_noMatch);

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
        // 标题栏左上角的图标（2026-10-29 用户反馈：以前传 exe 路径，SetIcon 不认，显示的是系统默认图标）。
        AppWindow.SetIcon(Paths.AppIconFile);
        Theme.ApplyTitleBar(AppWindow);

        BuildPage("general");
        Activated += (_, args) =>
        {
            _active = args.WindowActivationState != WindowActivationState.Deactivated;
            // 从 Windows 设置里改了麦克风权限回来：通用 › 权限那一行跟上（mac 窗口变成 key 时刷新）。
            var microphoneChanged = _active && _currentPage == "general" && _microphoneAllowed != MicrophoneAllowed();
            if (_active && (_stale || microphoneChanged) && _recordingAction is null)
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

    /// <summary>page 不给 = 上次停在的那一页（同 mac 记住上次的页；欢迎页总在通用）。</summary>
    public void ShowPage(bool welcome, string? page = null, string? service = null)
    {
        Motion.Refresh();
        _firstRun = welcome;
        page ??= welcome ? "general" : _currentPage;
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
        _browserRefreshers.Clear();
        _hotKeyCards.Clear();
        _gateFeature = null;
        _ungated.Clear();
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
            case "record":
                BuildRecord();
                break;
            case "about":
                BuildAbout();
                break;
            default:
                BuildGeneral();
                break;
        }

        ApplyGate();
        UpdateNavSelection();
    }

    /// <summary>
    /// 侧栏「搜索设置」：只留页名或关键词对得上的页；当前页不在结果里就跳到第一个，搜的正好是页名时停在那页
    /// （同 mac SettingsPage.page(for:current:)）。
    /// </summary>
    private void FilterPages(string text)
    {
        var query = text.Trim();
        var matches = Pages
            .Where(page => query.Length == 0 || page.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                           PageKeywords[page.Tag].Any(word => word.Contains(query, StringComparison.OrdinalIgnoreCase)))
            .Select(page => page.Tag)
            .ToList();
        foreach (var item in _nav.MenuItems.OfType<NavigationViewItem>())
        {
            if (item.Tag is string tag)
            {
                item.Visibility = matches.Contains(tag) ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        _noMatch.Visibility = matches.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var exact = Pages.FirstOrDefault(page => page.Title == query).Tag;
        var target = exact ?? (matches.Contains(_currentPage) ? null : matches.FirstOrDefault());
        if (target is not null && target != _currentPage && _recordingAction is null)
        {
            _serviceDetail = null;
            BuildPage(target);
        }
    }

    /// <summary>功能页第一行「启用 X」（mac FeatureToggle inPage）：和 通用 › 功能 那一排绑同一个开关；拨了整页重画成变灰 / 不变灰。</summary>
    private void AddFeatureToggle(Feature feature)
    {
        var title = "启用" + Features.Title(feature);
        _content.Children.Add(SettingsUi.Card(title, Features.Blurb(feature),
            SettingsUi.Toggle(Features.IsOn(feature), isOn =>
            {
                Features.Set(feature, isOn);
                BuildPage(_currentPage);
            }, title)));
        _gateFeature = feature;
        _gateFrom = _content.Children.Count;
    }

    /// <summary>功能关着时也能用的（清空、导出这类管数据的：关掉剪贴板的人可能正想清空它，同 mac）。</summary>
    private T Ungated<T>(T element) where T : UIElement
    {
        _ungated.Add(element);
        return element;
    }

    private void ApplyGate()
    {
        if (_gateFeature is not { } feature || Features.IsOn(feature))
        {
            return;
        }

        for (var index = _gateFrom; index < _content.Children.Count; index++)
        {
            var child = _content.Children[index];
            if (!_ungated.Contains(child))
            {
                child.Opacity = 0.55;
                child.IsHitTestVisible = false;
                DisableControls(child);
            }
        }
    }

    /// <summary>变灰的那几块里的控件也停用：Tab 走不进去、键盘拨不动（mac 的 .disabled）。页是代码建的，Panel / Border 往下找就够。</summary>
    private static void DisableControls(UIElement element)
    {
        switch (element)
        {
            case Control control:
                control.IsEnabled = false;
                break;
            case Panel panel:
                foreach (var child in panel.Children)
                {
                    DisableControls(child);
                }

                break;
            case Border { Child: { } child }:
                DisableControls(child);
                break;
        }
    }

    /// <summary>App 图标（侧栏「关于」、关于页的大图标）：从 exe 里取一张 PNG，取到之前是空的。</summary>
    private Image AppIconImage(double size)
    {
        var image = new Image { Width = size, Height = size, Stretch = Stretch.Uniform };
        AutomationProperties.SetAccessibilityView(image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        // 侧栏的那个在窗口句柄拿到之前就建了：按系统缩放取（多屏缩放不一样时最多糊一点）。
        _ = LoadAppIconAsync(image, PInvoke.GetDpiForSystem() / 96.0, size);
        return image;
    }

    private static async Task LoadAppIconAsync(Image image, double scale, double size)
    {
        var png = await Task.Run(() => ShellIcons.LoadPng(Paths.ExecutablePath, scale, size));
        if (png is { Length: > 0 })
        {
            image.Source = IconSource(png);
        }
    }

    /// <summary>
    /// 这台电脑上桌面应用能不能用麦克风：设置 › 隐私和安全性 › 麦克风 里的总开关和「允许桌面应用访问你的麦克风」，
    /// 有一个关着就是不能（读注册表里系统记的那两个值；读不到当能用）。
    /// </summary>
    private static bool MicrophoneAllowed()
    {
        const string store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
        try
        {
            static bool Denied(Microsoft.Win32.RegistryKey root, string path)
            {
                using var key = root.OpenSubKey(path, writable: false);
                return string.Equals(key?.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
            }

            return !Denied(Microsoft.Win32.Registry.LocalMachine, store) &&
                   !Denied(Microsoft.Win32.Registry.CurrentUser, store) &&
                   !Denied(Microsoft.Win32.Registry.CurrentUser, store + @"\NonPackaged");
        }
        catch (Exception ex)
        {
            Log.Warn($"settings.microphone-consent {ex.GetType().Name}");
            return true;
        }
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

    /// <summary>
    /// 设置 › 通用（照 mac GeneralTab 的分组和顺序）：功能 ｜ 外观、强调色 ｜ 启动 ｜ 权限 ｜ 同步 ｜ 导出与导入 ｜ 数据。
    /// mac 的「动效」「菜单栏」两组 Windows 没有，「自动检查更新」在关于页（同 mac），见 MAC-DIFF.md。
    /// </summary>
    private void BuildGeneral()
    {
        _content.Children.Add(Header("通用", "外观、登录时打开、权限、同步、设置的导出与导入"));
        if (_firstRun)
        {
            _content.Children.Add(BuildWelcome());
        }

        // 功能
        _content.Children.Add(SettingsUi.Section("功能"));
        foreach (var feature in Enum.GetValues<Feature>())
        {
            _content.Children.Add(SettingsUi.Card(
                Features.Title(feature),
                Features.Blurb(feature),
                SettingsUi.Toggle(Features.IsOn(feature), isOn =>
                {
                    // 不重建这一页：这一页只有这排开关跟着功能变，它自己已经拨过去了（以前重建两遍，整页的开关都闪）。
                    // 热键、托盘菜单在 ShellRuntime.OnSettingsChanged 里跟着换；功能自己那一页是点进去时才建的。
                    Features.Set(feature, isOn);
                }, Features.Title(feature)),
                leading: FeatureTile(feature)));
        }

        _content.Children.Add(SettingsUi.Footnote(
            "关掉的功能不出现在快捷键、托盘菜单和启动器里，也不在后台运行；它的数据和设置都留着，打开就回来。"));

        // 外观、强调色（mac 这一组没有组标题，空一截隔开）
        _content.Children.Add(new Border { Height = 8 });
        _content.Children.Add(SettingsUi.Card("外观", string.Empty, ThemePicker()));
        _content.Children.Add(SettingsUi.Card(
            "强调色",
            SettingsService.Current.Accent == "system"
                ? "跟随 设置 › 个性化 › 颜色 里的强调色"
                : "右键菜单、焦点框这些由系统绘制，仍使用系统强调色",
            AccentPicker()));

        // 启动
        _content.Children.Add(SettingsUi.Section("启动"));
        AddToggle("登录时自动打开", string.Empty,
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

        // 权限：Windows 上截图、粘贴回原程序都不用授权，只有麦克风（mac 还有辅助功能、屏幕录制、剪贴板访问）。
        _content.Children.Add(SettingsUi.Section("权限"));
        _microphoneAllowed = MicrophoneAllowed();
        FrameworkElement microphoneControl;
        if (_microphoneAllowed == true)
        {
            var granted = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            granted.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 14, Foreground = Theme.Success() });
            granted.Children.Add(new TextBlock { Text = "已允许", Foreground = Theme.SecondaryText() });
            microphoneControl = granted;
        }
        else
        {
            var open = new Button { Content = "打开设置" };
            AutomationProperties.SetName(open, "打开麦克风的隐私设置");
            open.Click += (_, _) => LauncherOpeners.Start("ms-settings:privacy-microphone");
            microphoneControl = open;
        }

        _content.Children.Add(SettingsUi.Card(
            "麦克风",
            _microphoneAllowed == true
                ? "录屏、录音时录下你的声音"
                : "录屏、录音时录下你的声音；设置 › 隐私和安全性 › 麦克风 里现在不让桌面应用用",
            microphoneControl,
            leading: KindTile.Create("capture", Glyphs.Microphone, 24),
            problem: _microphoneAllowed != true));

        BuildSyncSection();

        // 导出与导入：一行两个按钮（mac TransferSection）。每天自动备份那几行是 0.2.0 的 G2。
        _content.Children.Add(SettingsUi.Section("导出与导入"));
        var transfer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var export = new Button { Content = "导出…" };
        export.Click += (_, _) => _ = ExportArchiveAsync();
        var import = new Button { Content = "导入…" };
        import.Click += (_, _) => _ = ImportArchiveAsync();
        transfer.Children.Add(export);
        transfer.Children.Add(import);
        _content.Children.Add(SettingsUi.Card(
            "设置与数据",
            "设置、快捷键、翻译服务、网页搜索、片段和文字收藏、生词本存成一个文件，换电脑或重装后导回来",
            transfer));
        _content.Children.Add(SettingsUi.Footnote(
            "普通历史、图片和文件类的收藏不在文件里；截图的存储文件夹、登录时打开和系统权限要在新电脑上重新设。导入前会先把现在的存一份。"));

        // 数据
        _content.Children.Add(SettingsUi.Section("数据"));
        var reveal = new Button { Content = "在资源管理器中显示" };
        AutomationProperties.SetName(reveal, "在资源管理器中显示数据目录");
        reveal.Click += (_, _) => OpenDataDirectory();
        _content.Children.Add(SettingsUi.Card(
            "数据目录", "剪贴板和翻译历史的数据库、图片、设置、日志和每日备份都在这里", reveal));
        // Windows 才有：没装进开始菜单的便携版也要能干净地拿掉（MAC-DIFF.md）。
        _content.Children.Add(SettingsUi.Card(
            "从这台电脑移除 Kitty Tools…",
            "删掉开始菜单快捷方式、开机启动和保存的密钥；数据可以留着",
            null,
            () => _ = UninstallAsync()));
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

    /// <summary>
    /// 设置 › 通用 › 同步（PLAN-v5 §4.4；布局照 mac SyncSection）：没开时一行「选择文件夹…」；开着时文件夹 +「停止同步」+
    /// 「立即同步」（等确认时换成「继续同步」），说明是状态，出了问题橙字；下面四类各一个开关，跟着的功能关着时说一声；最后是其他电脑。
    /// mac 另外能同步设置、便签、状态屏和启动器收藏，Windows 这一版只有四类（MAC-DIFF.md）。
    /// </summary>
    private void BuildSyncSection()
    {
        var settings = SettingsService.Current;
        _content.Children.Add(SettingsUi.Section("同步"));
        var status = Syncer.Instance?.Status;
        if (!settings.SyncEnabled || string.IsNullOrEmpty(settings.SyncFolder))
        {
            var choose = new Button { Content = "选择文件夹…" };
            choose.Click += (_, _) => _ = PickSyncFolderAsync();
            _content.Children.Add(SettingsUi.Card(
                "在几台电脑之间同步",
                "选一个几台电脑都看得到的空文件夹，比如在 OneDrive 里新建一个；每台电脑选同一个（Mac 版 0.7.0 起也能选它）",
                choose));
        }
        else
        {
            var folder = settings.SyncFolder ?? string.Empty;
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            name.Children.Add(new FontIcon { Glyph = "\uE8B7", FontSize = 14, Foreground = Theme.SecondaryText() });
            name.Children.Add(new TextBlock
            {
                Text = ShellIcons.DisplayName(folder),
                MaxWidth = 180,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = Theme.SecondaryText(),
            });
            ToolTipService.SetToolTip(name, folder);
            controls.Children.Add(name);
            var stop = new HyperlinkButton { Content = "停止同步" };
            ToolTipService.SetToolTip(stop, "文件夹里的东西留着，这台电脑上的也不动");
            stop.Click += (_, _) =>
            {
                settings.SyncEnabled = false;
                SettingsService.Save();
                BuildPage("general");
            };
            controls.Children.Add(stop);
            if (status?.State == "confirm")
            {
                // 刹车停下的那一类：用户看过要删几条之后放行这一轮。
                var resume = new Button { Content = "继续同步" };
                resume.Click += (_, _) =>
                {
                    Syncer.Instance?.ConfirmDeletions();
                    BuildPage("general");
                };
                controls.Children.Add(resume);
            }
            else
            {
                var now = new Button { Content = "立即同步" };
                now.Click += (_, _) => _ = Syncer.Instance?.RoundAsync();
                controls.Children.Add(now);
            }

            var message = status?.Message;
            var trouble = status?.State switch
            {
                "confirm" => string.IsNullOrEmpty(message) ? "这一轮要删的太多，先停下来等你确认" : message,
                "stopped" => string.IsNullOrEmpty(message) ? "上一轮没同步成" : message,
                _ => null,
            };
            _content.Children.Add(SettingsUi.Card("同步文件夹", trouble ?? SyncStatusLine(status), controls, problem: trouble is not null));

            AddSyncPart("片段与收藏", "文字的片段、收藏和收藏夹；图片和文件的收藏不同步", Feature.Clipboard,
                settings.SyncClips, value => settings.SyncClips = value);
            AddSyncPart("生词本", "翻译里收藏的词句", Feature.Translate,
                settings.SyncVocabulary, value => settings.SyncVocabulary = value);
            AddSyncPart("网页搜索与快捷链接", "启动器里的网页搜索和快捷链接", Feature.Launcher,
                settings.SyncEngines, value => settings.SyncEngines = value);
            AddSyncPart("翻译服务", "哪几个服务、顺序和设置；密钥不同步，别的电脑上要自己填一次", Feature.Translate,
                settings.SyncServices, value => settings.SyncServices = value);

            var peers = status is { Devices.Count: > 0 }
                ? string.Join("、", status.Devices)
                : status is { LastSync: > 0 }
                    ? "还没有——在另一台电脑的 设置 › 通用 里选同一个文件夹"
                    : "同步一轮之后列在这里";
            _content.Children.Add(SettingsUi.Card("其他电脑", peers));
        }

        _content.Children.Add(SettingsUi.Footnote(
            "勾上的几类在几台电脑之间保持一样，取消一类只是不再同步它。同步文件夹里放的是不加密的文本文件，能打开这个文件夹的人都看得到。" +
            "每台电脑只往自己的那份里写、读所有电脑的，改动一般几十秒到几分钟传过去（看同步盘多快）。两台都改了同一条时，后改的留下；" +
            "一轮要删的太多会先停下来问。密钥不同步。停止同步后，文件夹里的东西留着，这台电脑上的也不动。"));
    }

    /// <summary>同步的一类：勾上才同步；它跟着的功能关着时说一声（勾着也先不同步，Syncer 里同样这么判断）。</summary>
    private void AddSyncPart(string title, string detail, Feature feature, bool value, Action<bool> set)
        => AddToggle(title,
            Features.IsOn(feature) ? detail : $"{Features.Title(feature)}关着，先不同步；在上面「功能」里打开就接着同步",
            value,
            isOn =>
            {
                set(isOn);
                SettingsService.Save();
            });

    /// <summary>状态：上次同步的时刻（第一轮还没完时说正在同步）。</summary>
    private static string SyncStatusLine(SyncStatus? status)
    {
        if (status is { LastSync: > 0 })
        {
            var at = DateTimeOffset.FromUnixTimeMilliseconds(status.LastSync).ToLocalTime();
            var minutes = (DateTimeOffset.Now - at).TotalMinutes;
            var ago = minutes < 1 ? "刚刚"
                : minutes < 60 ? $"{(int)minutes} 分钟前"
                : at.Date == DateTime.Today ? $"今天 {at:HH:mm}"
                : $"{at.Month} 月 {at.Day} 日 {at:HH:mm}";
            return "上次同步：" + ago;
        }

        return status?.State == "syncing" ? "正在同步…" : "还没同步过";
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
                   "默认快捷键：剪贴板 Alt+C、启动器 Alt+Space、划词翻译 Alt+E、输入翻译 Alt+T、" +
                   "截图翻译 Alt+S、截图 Alt+X、识字 Alt+O、录屏 Alt+R。\n\n" +
                   "用不着的功能可以在下面「功能」里整个关掉。",
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
        _content.Children.Add(Header("剪贴板", "历史上限、面板、内容格式和隐私"));
        AddFeatureToggle(Feature.Clipboard);
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
        _content.Children.Add(SettingsUi.Section("历史"));
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

        AddCombo("图片最多占用", string.Empty,
            budgets.Select(budget => budget.Title).ToArray(),
            budgets.FindIndex(budget => budget.Value == settings.ClipboardImageBudgetMB),
            index =>
            {
                settings.ClipboardImageBudgetMB = budgets[index].Value;
                SettingsService.Save();
                ReportCleanup(service.EnforceLimits());
            });
        _content.Children.Add(SettingsUi.Card("图片当前占用", string.Empty, new TextBlock
        {
            Text = $"普通图片约 {service.Store.OrdinaryImageBytes / 1_048_576.0:F0} MB · 共 {service.Store.Count} 条",
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        }));
        _content.Children.Add(SettingsUi.Footnote("收藏和片段一直留着，图片占用也只算普通历史里的。"));

        // 面板
        _content.Children.Add(SettingsUi.Section("面板"));
        var sketch = ClipboardSketch(settings.ClipboardShowLens, settings.LinkPreviews);
        _content.Children.Add(sketch);
        // 两个开关只换上面那张示意图，不重建整页（重建时整页的开关都闪一下，2026-10-29 用户反馈）。
        void RedrawSketch()
        {
            var index = _content.Children.IndexOf(sketch);
            if (index >= 0)
            {
                sketch = ClipboardSketch(settings.ClipboardShowLens, settings.LinkPreviews);
                _content.Children[index] = sketch;
            }
        }

        AddToggle("显示透镜", "选中的条目在原地展开预览；关掉就是纯列表，一屏多露出几行",
            settings.ClipboardShowLens,
            isOn =>
            {
                settings.ClipboardShowLens = isOn;
                SettingsService.Save();
                RedrawSketch();
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

                RedrawSketch();
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

        // 隐私：清空这几样功能关着也能用（同 mac，只有「不记录疑似密钥」跟着变灰）
        _content.Children.Add(Ungated(SettingsUi.Section("隐私")));
        AddToggle("不记录疑似密钥和银行卡号", string.Empty,
            settings.ClipboardBlockSensitive,
            isOn =>
            {
                settings.ClipboardBlockSensitive = isOn;
                SettingsService.Save();
            });
        Ungated(AddToggle("退出 Kitty Tools 时清空普通历史", string.Empty,
            settings.ClipboardClearOnQuit,
            isOn =>
            {
                settings.ClipboardClearOnQuit = isOn;
                SettingsService.Save();
            }));
        Ungated(AddToggle("锁屏时清空普通历史", string.Empty,
            settings.ClipboardClearOnLock,
            isOn =>
            {
                settings.ClipboardClearOnLock = isOn;
                SettingsService.Save();
            }));
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
        _content.Children.Add(Ungated(clear));

        // 不记录这些应用里的复制
        _content.Children.Add(SettingsUi.Section("不记录这些应用里的复制"));
        BuildExcludedApps(settings);
        _content.Children.Add(SettingsUi.Footnote("密码管理器通常会自己标记「不要记录」，这里只是兜底。"));
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
        _content.Children.Add(Header("启动器", "搜索应用、文件、书签与历史、网页搜索与快捷链接"));
        AddFeatureToggle(Feature.Launcher);
        var settings = SettingsService.Current;

        _content.Children.Add(new Border { Height = 8 });
        AddToggle("呼出时切到英文输入法", "只在搜索框里生效，离开后恢复；要搜中文时先关掉",
            settings.LauncherRomanInput,
            isOn =>
            {
                settings.LauncherRomanInput = isOn;
                SettingsService.Save();
            });
        AddShortcutsRow("launcher", "启动器里的按键",
            "搜应用、系统设置、文件、书签、网址、路径、算式（也能换算单位和进制）和系统命令（lock、quit、kill 这些），" +
            "Enter 打开，Ctrl+K 看这一项的全部操作");

        // 文件搜索
        _content.Children.Add(SettingsUi.Section("文件搜索"));
        _content.Children.Add(SettingsUi.Card(
            "建了索引的位置", "设置 › 隐私和安全性 › 搜索 Windows", null,
            () => LauncherOpeners.Start("ms-settings:cortana-windowssearch")));
        _content.Children.Add(SettingsUi.Footnote(
            "「open 文件名」搜文件并打开，「find 文件名」在资源管理器中显示；搜的是 Windows 搜索建了索引的位置，不想被搜到的文件夹从索引里去掉。"));

        // 浏览器书签与历史
        _content.Children.Add(SettingsUi.Section("浏览器书签与历史"));
        var installed = Browsers.Installed();
        if (installed.Count == 0)
        {
            _content.Children.Add(SettingsUi.Card("没有找到浏览器", "装了 Edge、Chrome、Firefox 这些之后会列在这里"));
        }

        foreach (var browser in installed)
        {
            AddBrowserRows(settings, browser);
        }

        _content.Children.Add(SettingsUi.Footnote("只列本机装了的浏览器。"));

        // 后台读浏览器数据，读完原地改各行的条数（不重建整页：以前读完整页重画，开关全闪一下、滚动跳回顶部）。
        _ = RefreshBrowsersAsync(settings);

        // 网页搜索与快捷链接
        _content.Children.Add(SettingsUi.Section("网页搜索与快捷链接"));
        var engines = (settings.LauncherSearchEngines ?? WebSearch.Defaults()).Select(Copy).ToList();

        void Save()
        {
            settings.LauncherSearchEngines = engines;
            SettingsService.Save();
        }

        // 增删、挪位置、改名要重画这一节；只拨兜底开关的不重画（Save），免得整页的开关都闪一下。
        void Persist()
        {
            Save();
            BuildPage("launcher");
        }

        for (var index = 0; index < engines.Count; index++)
        {
            _content.Children.Add(EngineRow(engines, index, Persist, Save));
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

        AddToggle("有本地结果时也显示兜底搜索", string.Empty,
            settings.LauncherFallbackAlways,
            isOn =>
            {
                settings.LauncherFallbackAlways = isOn;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "网址里有 {query} 的是搜索（「关键词 空格 内容」直达，开关 = 没有本地结果时兜底），没有的是快捷链接。搜索的关键词重复时用靠前的；点「编辑」改名称、关键词和网址。"));

        // 使用记录：功能关着也能清（同 mac）
        _content.Children.Add(Ungated(SettingsUi.Section("使用记录")));
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
        _content.Children.Add(Ungated(clear));
        _content.Children.Add(Ungated(SettingsUi.Footnote(
            "启动器按用过的次数和时间排序，空搜索框里先列收藏（Ctrl+D 加入），再列「常用」。在「常用」里选中一项按 Ctrl+Delete 可以单独移除，Ctrl+Z 撤销。")));
    }

    /// <summary>这一页浏览器各行「读到几条」的原地刷新（BuildPage 换页时清空）。</summary>
    private readonly List<Action> _browserRefreshers = new();

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
        // 开关一变只原地改这两行（说明文字、历史那一行露不露），不重建整页（2026-10-29 用户反馈：别的开关跟着闪）。
        var bookmarkCard = SettingsUi.Card(
            browser.Name,
            string.Empty,
            SettingsUi.Toggle(Browsers.BookmarkIds(settings).Contains(browser.Id), isOn =>
            {
                var ids = Browsers.BookmarkIds(settings).Where(id => id != browser.Id).ToList();
                if (isOn)
                {
                    ids.Add(browser.Id);
                }

                settings.LauncherBookmarkBrowsers = ids;
                SettingsService.Save();
                RefreshAllBrowserRows();
                _ = RefreshBrowsersAsync(settings);
            }, $"读 {browser.Name} 的书签"));
        var historyCard = SettingsUi.Card(
            "也搜浏览历史",
            string.Empty,
            SettingsUi.Toggle((settings.LauncherHistoryBrowsers ?? new List<string>()).Contains(browser.Id), isOn =>
            {
                var ids = (settings.LauncherHistoryBrowsers ?? new List<string>()).Where(id => id != browser.Id).ToList();
                if (isOn)
                {
                    ids.Add(browser.Id);
                }

                settings.LauncherHistoryBrowsers = ids;
                SettingsService.Save();
                RefreshAllBrowserRows();
                _ = RefreshBrowsersAsync(settings);
            }, $"也搜 {browser.Name} 的浏览历史"));
        historyCard.Margin = new Thickness(24, 0, 0, 0);
        _content.Children.Add(bookmarkCard);
        _content.Children.Add(historyCard);

        // 读到几条写在名字下面（mac browserRows）；书签关着时只有名字、历史那一行不露。
        void Refresh()
        {
            var bookmarksOn = Browsers.BookmarkIds(settings).Contains(browser.Id);
            var (bookmarkText, bookmarkProblem) = bookmarksOn
                ? StatusText(BrowserIndex.Status(browser.Id, history: false), "书签", "书签文件里一条书签都没有", "没找到书签文件")
                : (string.Empty, false);
            SettingsUi.SetDescription(bookmarkCard, bookmarkText, bookmarkProblem);
            historyCard.Visibility = bookmarksOn ? Visibility.Visible : Visibility.Collapsed;
            var historyOn = (settings.LauncherHistoryBrowsers ?? new List<string>()).Contains(browser.Id);
            var (historyText, historyProblem) = historyOn
                ? StatusText(BrowserIndex.Status(browser.Id, history: true), "历史", "浏览历史里还没有常去的网页", "没找到浏览历史文件")
                : ("去过两次以上或手输过的网页，排在书签后面", false);
            SettingsUi.SetDescription(historyCard, historyText, historyProblem);
        }

        _browserRefreshers.Add(Refresh);
        Refresh();
    }

    private void RefreshAllBrowserRows()
    {
        foreach (var refresh in _browserRefreshers.ToArray())
        {
            refresh();
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

    /// <summary>开关变了、进这一页时：浏览器数据该重读就在后台读，读完还停在这一页就原地改各行的条数。</summary>
    private async Task RefreshBrowsersAsync(Settings settings)
    {
        if (await BrowserIndex.RefreshAsync(Browsers.BookmarkIds(settings), Browsers.HistoryIds(settings), force: true) &&
            _currentPage == "launcher" && !IsClosed)
        {
            RefreshAllBrowserRows();
        }
    }

    /// <summary>一条搜索 / 快捷链接（mac EngineListRow）：名称 + 种类或橙色的问题、关键词键帽、兜底开关（快捷链接没有）、↑ ↓ 编辑 删除。</summary>
    private Border EngineRow(List<KittyTools.Core.SearchEngine> engines, int index, Action persist, Action save)
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
                save();
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

    /// <summary>
    /// 设置 › 截图（照 mac ScreenshotTab）：启用截图 ｜ 快速保存到 ｜ 截图历史 ｜ 识字 ｜ 框选、标注、长截图和录屏的按键。
    /// 快门声、截完图放哪、截图历史的保留天数和占用是 0.2.0 的 S6–S8（MAC-DIFF.md）。
    /// </summary>
    private void BuildScreenshot()
    {
        _content.Children.Add(Header("截图", "快速保存、截图历史和识字"));
        AddFeatureToggle(Feature.Screenshot);

        // 快速保存到：功能关着也能改（mac 这一行在变灰的那块外面）
        _content.Children.Add(Ungated(new Border { Height = 8 }));
        _content.Children.Add(Ungated(SaveFolderRow(
            "快速保存到",
            string.IsNullOrWhiteSpace(SettingsService.Current.ScreenshotSaveFolder)
                ? ScreenshotOutput.DefaultFolder()
                : SettingsService.Current.ScreenshotSaveFolder!,
            !string.IsNullOrWhiteSpace(SettingsService.Current.ScreenshotSaveFolder),
            folder => SettingsService.Current.ScreenshotSaveFolder = folder)));
        _content.Children.Add(Ungated(SettingsUi.Footnote(
            "按 Ctrl+S 或工具栏的「存储」存到这里，文件名是「截图 日期 时间.png」，重名自动加序号；Ctrl+Shift+S 每次另存为。" +
            "没选过时存到系统的「屏幕截图」文件夹。截图不会上传到任何服务。")));

        // 截图历史（PLAN-v8 H3）
        _content.Children.Add(SettingsUi.Section("截图历史"));
        AddToggle("保留截图历史", "关掉后不再记，已经记下的留着",
            SettingsService.Current.ShotHistory,
            value =>
            {
                SettingsService.Current.ShotHistory = value;
                SettingsService.Save();
            });
        var openHistory = new Button { Content = "打开截图历史…" };
        openHistory.Click += (_, _) => ShotHistoryWindow.ShowWindow();
        _content.Children.Add(SettingsUi.Card("截图历史", "看、拷贝、再钉出来，或者删掉", openHistory));
        _content.Children.Add(SettingsUi.Footnote("截图、长截图、钉过的图和录制都记在这里，留 30 天、最多 2 GB，超了先删最旧的。"));

        // 识字
        _content.Children.Add(new Border { Height = 8 });
        AddToggle("识字后把同一段里的换行接起来", string.Empty,
            SettingsService.Current.OcrJoinLines,
            value =>
            {
                SettingsService.Current.OcrJoinLines = value;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "同一段里的行接起来，段和段之间保留换行：中文、日文的行直接接上，其它文字之间加空格。识字和截图翻译都看这个；只在本机用 Windows 的识字组件。"));

        _content.Children.Add(new Border { Height = 8 });
        AddShortcutsRow("screenshot", "框选、标注、长截图和录屏的按键",
            "拖动框选，数字键 1–0 换标注工具，Enter 拷贝，S 长截图，R 录屏");
    }

    /// <summary>
    /// 设置 › 录制（照 mac RecordTab）：启用录屏 ｜ 保存到 ｜ 录屏 ｜ 录音 ｜ 录屏和录音的按键。
    /// 保存位置和截图分开（录屏默认在「视频」里，同系统的截图工具，MAC-DIFF.md）；帧率 30 / 60、录音的来源（PLAN-v9 V3、V5）；
    /// 清晰度、倒数、显示光标这些是 R1–R7。
    /// </summary>
    private void BuildRecord()
    {
        _content.Children.Add(Header("录制", "录屏的帧率和按键，录音的来源"));
        AddFeatureToggle(Feature.Recording);

        _content.Children.Add(Ungated(new Border { Height = 8 }));
        _content.Children.Add(Ungated(SaveFolderRow(
            "保存到",
            RecordingHost.Folder,
            !string.IsNullOrWhiteSpace(SettingsService.Current.RecordDirectory),
            folder => SettingsService.Current.RecordDirectory = folder)));
        _content.Children.Add(Ungated(SettingsUi.Footnote(
            "文件名是「录屏 日期 时间.mp4」「录音 日期 时间.m4a」。没选过时存到「视频」里的「Screen Recordings」，和截图的「快速保存到」分开。")));

        _content.Children.Add(SettingsUi.Section("录屏"));
        AddCombo("帧率", string.Empty,
            new[] { "30 fps", "60 fps" },
            SettingsService.Current.RecordFps >= 60 ? 1 : 0,
            index =>
            {
                SettingsService.Current.RecordFps = index == 1 ? 60 : 30;
                SettingsService.Save();
            });
        AddToggle("显示点按", "录制画面里画一个圈（左键粉色、右键蓝色）",
            SettingsService.Current.RecordClicks,
            value =>
            {
                SettingsService.Current.RecordClicks = value;
                SettingsService.Save();
            });
        AddToggle("显示按键", "只显示带修饰键的快捷键（如 Ctrl + Shift + S），单个字母不显示",
            SettingsService.Current.RecordKeys,
            value =>
            {
                SettingsService.Current.RecordKeys = value;
                SettingsService.Save();
            });
        AddToggle("系统声音", "录默认输出设备的声音；关掉只录麦克风或只有画面",
            SettingsService.Current.RecordSystemSound,
            value =>
            {
                SettingsService.Current.RecordSystemSound = value;
                SettingsService.Save();
            });
        AddToggle("麦克风", "录默认麦克风，和系统声音混成一条音轨",
            SettingsService.Current.RecordMicrophone,
            value =>
            {
                SettingsService.Current.RecordMicrophone = value;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "60 fps 更顺，文件大约大一半；大屏上可能录不满 60。框一块区域、或在遮罩里单击一扇窗口录它，倒数 3 秒后开始；录的时候选区外一圈粉线，线不进画面。" +
            "第一次录麦克风时，要在 设置 › 隐私和安全性 › 麦克风 里允许桌面应用。"));

        _content.Children.Add(SettingsUi.Section("录音"));
        var sources = new[] { "microphone", "system", "both" };
        AddCombo("来源", string.Empty, new[] { "麦克风", "系统声音", "两者" },
            Math.Max(0, Array.IndexOf(sources, SettingsService.Current.AudioSource)),
            index =>
            {
                SettingsService.Current.AudioSource = sources[index];
                SettingsService.Save();
            });
        AddToggle("按快捷键后立即开始录音", string.Empty,
            SettingsService.Current.RecordInstantStart,
            value =>
            {
                SettingsService.Current.RecordInstantStart = value;
                SettingsService.Save();
            });
        _content.Children.Add(SettingsUi.Footnote(
            "和录屏的「系统声音」「麦克风」分开；麦克风用不了（设置 › 隐私和安全性 › 麦克风 里关着）时改成录系统声音。只录麦克风时锁屏照录，录了系统声音的锁屏会停。" +
            "立即开始关着时，按快捷键（或点托盘、启动器里的「录音」）先在屏幕底部打开录音控制条，点「开始」或再按一次才开始录。"));

        _content.Children.Add(new Border { Height = 8 });
        AddShortcutsRow("screenshot", "录屏和录音的按键",
            "框选和截图一样，Enter 或双击选区开始，Esc 取消；录着时再按一次快捷键停止并保存");
    }

    /// <summary>
    /// 「快速保存到」「保存到」那一行（mac SaveDirectoryRow）：文件夹图标 + 资源管理器里的名字（悬停看完整路径）+
    /// 选过时「恢复默认」+「更改…」。set(null) = 恢复默认。
    /// </summary>
    private Border SaveFolderRow(string title, string folder, bool customized, Action<string?> set)
    {
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(new FontIcon { Glyph = "\uE8B7", FontSize = 14, Foreground = Theme.SecondaryText() });
        name.Children.Add(new TextBlock
        {
            Text = ShellIcons.DisplayName(folder),
            MaxWidth = 200,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = Theme.SecondaryText(),
        });
        ToolTipService.SetToolTip(name, folder);
        AutomationProperties.SetName(name, $"{title}：{folder}");
        controls.Children.Add(name);
        if (customized)
        {
            var reset = new HyperlinkButton { Content = "恢复默认" };
            reset.Click += (_, _) =>
            {
                set(null);
                SettingsService.Save();
                BuildPage(_currentPage);
            };
            controls.Children.Add(reset);
        }

        var change = new Button { Content = "更改…" };
        AutomationProperties.SetName(change, $"更改{title}的文件夹");
        change.Click += async (_, _) =>
        {
            try
            {
                var picker = new FolderPicker(AppWindow.Id);
                var result = await picker.PickSingleFolderAsync();
                if (result is not null && !string.IsNullOrEmpty(result.Path))
                {
                    set(result.Path);
                    SettingsService.Save();
                    BuildPage(_currentPage);
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings.folder-picker-failed", ex);
                NoticeHost.Show("没能选择文件夹", ex.GetType().Name, NoticeTone.Error);
            }
        };
        controls.Children.Add(change);
        return SettingsUi.Card(title, string.Empty, controls);
    }

    private void ReportCleanup(int removed)
    {
        if (removed > 0)
        {
            NoticeHost.Show("已按新上限清理", $"删了 {removed} 条旧记录", NoticeTone.Normal);
        }
    }

    /// <summary>快捷键页每一行的卡（录制时原地改那一行的橙字，不重建页：重建会把焦点从录制框上拿走，按键就收不到了）。</summary>
    private readonly Dictionary<string, Border> _hotKeyCards = new();

    /// <summary>每一行的录制框（录制时原地换成「按下快捷键」）。</summary>
    private readonly Dictionary<string, Button> _hotKeyBoxes = new();

    /// <summary>
    /// 设置 › 快捷键（照 mac HotkeysTab）：按 剪贴板与启动器 / 翻译 / 截图与录制 分组（只列开着的功能），每行 = 家族色块 + 动作名
    /// （出问题、录制时的提示用橙字写在下面）+ 输入框样子的录制框（点一下录，✕ 清除，右键「恢复默认」）。
    /// 面板里的按键不写进页里，最后一行「查看全部快捷键…」打开速查表。
    /// </summary>
    private void BuildHotKeys()
    {
        _content.Children.Add(Header("快捷键", "所有全局快捷键"));
        _hotKeyBoxes.Clear();
        foreach (var (title, actions) in VisibleHotKeySections())
        {
            _content.Children.Add(SettingsUi.Section(title));
            foreach (var action in actions)
            {
                if (SettingsDefaults.Find(action) is { } definition)
                {
                    _content.Children.Add(HotKeyRow(definition));
                }
            }
        }

        _content.Children.Add(new Border { Height = 8 });
        AddShortcutsRow(null, "面板里的按键", "剪贴板、启动器、翻译浮窗和截图里按什么键，都在速查表里");
        _content.Children.Add(SettingsUi.Footnote(
            "点录制框后按下新组合；Esc 取消，Backspace 清除，右键可恢复默认。至少带 Ctrl 或 Alt，或者单独一个 F1–F24。"));
    }

    /// <summary>
    /// 快捷键的分组（同 mac HotKeyAction.sections，和托盘菜单、速查表同名同序）：关着的功能的动作去掉、空了的节去掉；
    /// 两个功能合一节的只剩一个功能时，节标题换成它的名字。表里漏掉的新动作排进最后一节，免得加了动作这一页看不到。
    /// </summary>
    private static IEnumerable<(string Title, List<string> Actions)> VisibleHotKeySections()
    {
        var sections = new List<(string Title, List<string> Actions)>
        {
            ("剪贴板与启动器", new List<string> { HotKeyActions.Clipboard, HotKeyActions.Launcher }),
            ("翻译", new List<string>
            {
                HotKeyActions.SelectionTranslate, HotKeyActions.InputTranslate, HotKeyActions.TranslateReplace,
                HotKeyActions.ScreenshotTranslate,
            }),
            ("截图与录制", new List<string>
            {
                HotKeyActions.Screenshot, HotKeyActions.ScreenshotLast, HotKeyActions.Ocr, HotKeyActions.Record,
                HotKeyActions.Audio, HotKeyActions.PinClipboard, HotKeyActions.ShotHistory,
            }),
        };
        var known = sections.SelectMany(section => section.Actions).ToHashSet();
        sections[^1].Actions.AddRange(SettingsDefaults.DefaultHotKeys
            .Select(definition => definition.Action)
            .Where(action => !known.Contains(action)));
        foreach (var (title, actions) in sections)
        {
            var visible = actions.Where(action => Features.IsOn(Features.ForHotKey(action))).ToList();
            if (visible.Count == 0)
            {
                continue;
            }

            var shared = actions.Select(Features.ForHotKey).Distinct().Count() > 1;
            var alone = visible.Select(Features.ForHotKey).Distinct().Count() == 1;
            yield return (shared && alone ? Features.Title(Features.ForHotKey(visible[0])) : title, visible);
        }
    }

    private Border HotKeyRow(HotKeyDefault definition)
    {
        var action = definition.Action;
        var binding = SettingsDefaults.BindingFor(SettingsService.Current, action);
        var failure = binding.VirtualKey == 0 ? null : ShellRuntime.Instance?.HotKeys.FailureFor(action);
        var box = new Button
        {
            MinWidth = 180,
            MinHeight = 32,
            Padding = new Thickness(10, 2, 30, 2),
            HorizontalContentAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _hotKeyBoxes[action] = box;
        ShowBinding(box, action);
        // 录着时按空格 / Enter 也会触发 Click：只在没在录这一行时才开始录。
        box.Click += (_, _) =>
        {
            if (_recordingAction != action)
            {
                BeginRecording(action);
            }
        };
        // 点到别处 = 不录了（mac 录制框失去焦点时同样取消）。
        box.LostFocus += (_, _) =>
        {
            if (_recordingAction == action)
            {
                StopRecording(action, null);
            }
        };
        var restore = new MenuFlyoutItem
        {
            Text = "恢复默认",
            IsEnabled = binding.VirtualKey != definition.VirtualKey || binding.Modifiers != definition.Modifiers,
        };
        restore.Click += (_, _) => RestoreHotKey(action);
        box.ContextFlyout = new MenuFlyout { Items = { restore } };
        AutomationProperties.SetHelpText(box, "点一下后按新的组合；右键可恢复默认");

        var clear = new Button
        {
            Content = new FontIcon { Glyph = "\uE711", FontSize = 10 },
            Padding = new Thickness(6),
            Margin = new Thickness(0, 0, 3, 0),
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Visibility = binding.VirtualKey == 0 ? Visibility.Collapsed : Visibility.Visible,
        };
        AutomationProperties.SetName(clear, $"清除「{definition.DisplayName}」的快捷键");
        ToolTipService.SetToolTip(clear, "清除");
        clear.Click += (_, _) => ClearHotKey(action);
        var recorder = new Grid { VerticalAlignment = VerticalAlignment.Center };
        recorder.Children.Add(box);
        recorder.Children.Add(clear);

        var card = SettingsUi.Card(
            definition.DisplayName, failure ?? string.Empty, recorder, leading: HotKeyTile(action), problem: failure is not null);
        _hotKeyCards[action] = card;
        return card;
    }

    /// <summary>录制框里显示的：录着时「按下快捷键」（强调色边），平时是键帽 / 未设置。</summary>
    private void ShowBinding(Button box, string action)
    {
        var name = SettingsDefaults.Find(action)?.DisplayName ?? action;
        if (_recordingAction == action)
        {
            box.Content = new TextBlock { Text = "按下快捷键", Foreground = Theme.SecondaryText() };
            box.BorderBrush = new SolidColorBrush(Theme.AccentColor);
            AutomationProperties.SetName(box, $"正在录「{name}」的快捷键：按下新组合，Esc 取消");
            return;
        }

        var shortcut = HotKeyManager.FormatFor(action);
        box.Content = SettingsUi.KeyCaps(shortcut);
        box.ClearValue(Control.BorderBrushProperty);
        AutomationProperties.SetName(box, $"{name}：{shortcut}");
    }

    private void BeginRecording(string action)
    {
        if (_recordingAction is { } previous && previous != action)
        {
            StopRecording(previous, null);
        }

        _recordingAction = action;
        if (_hotKeyBoxes.TryGetValue(action, out var box))
        {
            ShowBinding(box, action);
        }

        SetHotKeyMessage(action, null);
    }

    private void StopRecording(string action, string? message)
    {
        if (_recordingAction == action)
        {
            _recordingAction = null;
        }

        if (_hotKeyBoxes.TryGetValue(action, out var box))
        {
            ShowBinding(box, action);
        }

        SetHotKeyMessage(action, message);
    }

    /// <summary>那一行下面的橙字：录制时的提示、这个组合不能用；null = 回到注册失败的原因（没有就收起）。</summary>
    private void SetHotKeyMessage(string action, string? message)
    {
        if (!_hotKeyCards.TryGetValue(action, out var card))
        {
            return;
        }

        var text = message ?? (SettingsDefaults.BindingFor(SettingsService.Current, action).VirtualKey == 0
            ? null
            : ShellRuntime.Instance?.HotKeys.FailureFor(action));
        SettingsUi.SetDescription(card, text ?? string.Empty, problem: true);
    }

    private void OnRecordKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_recordingAction is not { } action)
        {
            return;
        }

        e.Handled = true;
        if (e.Key == VirtualKey.Escape)
        {
            StopRecording(action, null);
            return;
        }

        var key = (uint)e.Key;
        var modifiers = HotKeyModifiers.None;
        if (IsDown(VirtualKey.Control)) modifiers |= HotKeyModifiers.Control;
        if (IsDown(VirtualKey.Menu)) modifiers |= HotKeyModifiers.Alt;
        if (IsDown(VirtualKey.Shift)) modifiers |= HotKeyModifiers.Shift;
        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows)) modifiers |= HotKeyModifiers.Win;

        // 单按 Backspace = 清除（同 mac 录制框里的 ⌫）。
        if (e.Key == VirtualKey.Back && modifiers == HotKeyModifiers.None)
        {
            StopRecording(action, null);
            ClearHotKey(action);
            return;
        }

        if (HotKeyRules.IsModifierKey(key))
        {
            SetHotKeyMessage(action, "再按一个普通键（修饰键本身不算）");
            return;
        }

        var validation = HotKeyRules.Validate(key, modifiers);
        if (!validation.Ok)
        {
            SetHotKeyMessage(action, validation.Reason ?? "这个组合不能用");
            return;
        }

        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(key, modifiers));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        _recordingAction = null;
        // 重画后那一行自己写注册失败的原因（被别的程序占着之类）。
        BuildPage("hotkeys");
    }

    private void ClearHotKey(string action)
    {
        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(0, HotKeyModifiers.None));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        BuildPage("hotkeys");
    }

    /// <summary>右键「恢复默认」：这一个动作换回默认键（mac 录制框右键菜单）。</summary>
    private void RestoreHotKey(string action)
    {
        SettingsDefaults.ResetBinding(SettingsService.Current, action);
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        BuildPage("hotkeys");
    }

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private const string ReleasesPage = "https://github.com/YyAdnBug/kitty-tools/releases";

    /// <summary>关于页的检查状态：idle / checking / latest / failed（有新版本、正在更新从 UpdateService / AutoUpdater 读）。</summary>
    private string _updateState = "idle";

    /// <summary>关于页那一行更新状态（原地换，不重画整页）。</summary>
    private Border? _updateRow;

    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _updateTicker;

    /// <summary>
    /// 设置 › 关于（照 mac AboutTab 的品牌页，没有页头）：128 的 App 图标 + 字标 + 品牌粉版本胶囊 + 更新状态一行 +「自动检查更新」+
    /// 「打开发布页」，下面是更新日志时间线（当前版本品牌粉圆点）。在这里点的检查结果、更新进度写在页上（同 mac）。
    /// mac 的「未来计划」「重看欢迎引导」Windows 还没有（MAC-DIFF.md）。
    /// </summary>
    private void BuildAbout()
    {
        var version = typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        var ink = new SolidColorBrush(dark ? Theme.BrandPink : Theme.BrandPinkDeep);
        var hero = new StackPanel { Spacing = 12, Padding = new Thickness(0, 36, 0, 24) };
        var icon = AppIconImage(128);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Content);
        AutomationProperties.SetName(icon, "Kitty Tools 图标");
        hero.Children.Add(icon);
        hero.Children.Add(new TextBlock
        {
            Text = "Kitty Tools",
            FontSize = 26,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        hero.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 4, 10, 4),
            Background = new SolidColorBrush(Color.FromArgb(31, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B)),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = new TextBlock
            {
                Text = $"版本 {version}",
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = ink,
                IsTextSelectionEnabled = true,
            },
        });
        _updateRow = new Border { HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 32, Child = UpdateRow() };
        hero.Children.Add(_updateRow);
        var autoCheck = new CheckBox
        {
            Content = "自动检查更新",
            IsChecked = SettingsService.Current.AutoCheckUpdates,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = Theme.SecondaryText(),
        };
        autoCheck.Click += (_, _) =>
        {
            SettingsService.Current.AutoCheckUpdates = autoCheck.IsChecked == true;
            SettingsService.Save();
        };
        hero.Children.Add(autoCheck);
        var releases = new HyperlinkButton { Content = "打开发布页", HorizontalAlignment = HorizontalAlignment.Center };
        releases.Click += (_, _) => LauncherOpeners.Start(ReleasesPage);
        hero.Children.Add(releases);

        // 顶上一层品牌色淡下去的底（mac 是奶油色渐变）。
        var wash = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(0, 1),
        };
        wash.GradientStops.Add(new GradientStop { Color = Color.FromArgb(24, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B), Offset = 0 });
        wash.GradientStops.Add(new GradientStop { Color = Color.FromArgb(0, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B), Offset = 1 });
        _content.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = wash, Child = hero });
        _content.Children.Add(ChangelogBlock(version, ink));
    }

    /// <summary>版本胶囊下面那一行（mac updateRow）：强调色只给现在该点的「更新并重新打开」，其余是文字链接。</summary>
    private FrameworkElement UpdateRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        TextBlock Text(string text, Brush? brush = null) => new()
        {
            Text = text,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = brush ?? Theme.SecondaryText(),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 420,
        };
        HyperlinkButton Link(string text, Action click)
        {
            var link = new HyperlinkButton { Content = text, Padding = new Thickness(2, 0, 2, 0), VerticalAlignment = VerticalAlignment.Center };
            link.Click += (_, _) => click();
            return link;
        }

        if (AutoUpdater.IsBusy)
        {
            row.Children.Add(new ProgressBar { Width = 140, IsIndeterminate = true, VerticalAlignment = VerticalAlignment.Center });
            row.Children.Add(Text(AutoUpdater.ProgressMenuText ?? "正在更新…"));
            StartUpdateTicker();
        }
        else if (UpdateService.AvailableVersion is { } available)
        {
            row.Children.Add(Text($"有新版本 {available}", Theme.Brush("TextFillColorPrimaryBrush", Theme.Argb(255, 0, 0, 0))));
            var install = new Button { Content = "更新并重新打开", Style = Theme.Style("AccentButtonStyle") };
            install.Click += (_, _) =>
            {
                _ = AutoUpdater.StartAsync();
                RefreshUpdateRow();
            };
            row.Children.Add(install);
            row.Children.Add(Link("更新内容", UpdateService.OpenAvailable));
        }
        else
        {
            switch (_updateState)
            {
                case "checking":
                    row.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true, VerticalAlignment = VerticalAlignment.Center });
                    row.Children.Add(Text("正在检查更新…"));
                    break;
                case "latest":
                    row.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 14, Foreground = Theme.Success(), VerticalAlignment = VerticalAlignment.Center });
                    row.Children.Add(Text("已是最新版本"));
                    row.Children.Add(Link("再查一次", () => _ = CheckUpdatesFromPageAsync()));
                    break;
                case "failed":
                    row.Children.Add(Text("检查更新失败：网络不通或 GitHub 暂时打不开", Theme.Critical()));
                    row.Children.Add(Link("重试", () => _ = CheckUpdatesFromPageAsync()));
                    break;
                default:
                    row.Children.Add(Link("检查更新", () => _ = CheckUpdatesFromPageAsync()));
                    break;
            }
        }

        return row;
    }

    private void RefreshUpdateRow()
    {
        if (_currentPage == "about" && _updateRow is not null)
        {
            _updateRow.Child = UpdateRow();
        }
    }

    private async Task CheckUpdatesFromPageAsync()
    {
        _updateState = "checking";
        RefreshUpdateRow();
        // 不弹「已是最新」那类提示：结果写在页上（同 mac 关于页）。
        await UpdateService.CheckAsync(userInitiated: false);
        // 结果可能是排到 UI 线程上才落地的（UpdateService.ApplyResult）：排在它后面再读。
        DispatcherQueue.TryEnqueue(() =>
        {
            _updateState = UpdateService.LastCheckFailed ? "failed" : "latest";
            RefreshUpdateRow();
        });
    }

    /// <summary>正在下载更新时每半秒换一次那一行的百分比；离开关于页、下载完就停。</summary>
    private void StartUpdateTicker()
    {
        if (_updateTicker is not null)
        {
            return;
        }

        _updateTicker = DispatcherQueue.CreateTimer();
        _updateTicker.Interval = TimeSpan.FromMilliseconds(500);
        _updateTicker.IsRepeating = true;
        _updateTicker.Tick += (_, _) =>
        {
            if (_currentPage != "about" || !AutoUpdater.IsBusy)
            {
                _updateTicker?.Stop();
                _updateTicker = null;
            }

            RefreshUpdateRow();
        };
        _updateTicker.Start();
    }

    /// <summary>更新日志时间线（mac ReleaseView）：左边竖线 + 圆点（当前版本品牌粉），右边版本号、「当前版本」、日期、摘要和逐条改动。</summary>
    private static UIElement ChangelogBlock(string currentVersion, Brush ink)
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "changelog.json");
            if (!File.Exists(path))
            {
                return new TextBlock { Text = "更新日志不在发布目录里。", Foreground = Theme.SecondaryText() };
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var panel = new StackPanel { Margin = new Thickness(16, 8, 16, 0) };
            panel.Children.Add(new TextBlock
            {
                Text = "更新日志",
                FontSize = 15,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Margin = new Thickness(0, 0, 0, 12),
            });
            if (!document.RootElement.TryGetProperty("entries", out var entries) || entries.ValueKind != JsonValueKind.Array)
            {
                return panel;
            }

            var releases = entries.EnumerateArray().Take(6).ToList();
            var hairline = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0));
            for (var index = 0; index < releases.Count; index++)
            {
                var entry = releases[index];
                var version = entry.TryGetProperty("version", out var v) ? v.GetString() ?? string.Empty : string.Empty;
                var date = entry.TryGetProperty("date", out var d) ? d.GetString() ?? string.Empty : string.Empty;
                var summary = entry.TryGetProperty("summary", out var s) ? s.GetString() ?? string.Empty : string.Empty;
                var current = version == currentVersion;

                var release = new Grid { ColumnSpacing = 14 };
                release.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
                release.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var rail = new Grid();
                rail.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                rail.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                rail.Children.Add(new Border
                {
                    Width = 10,
                    Height = 10,
                    CornerRadius = new CornerRadius(5),
                    Margin = new Thickness(0, 6, 0, 0),
                    Background = current ? new SolidColorBrush(Theme.BrandPink) : Theme.TertiaryText(),
                });
                if (index < releases.Count - 1)
                {
                    var line = new Border { Width = 1, Background = hairline, HorizontalAlignment = HorizontalAlignment.Center };
                    Grid.SetRow(line, 1);
                    rail.Children.Add(line);
                }

                release.Children.Add(rail);

                var body = new StackPanel { Spacing = 8, Padding = new Thickness(0, 0, 0, 22) };
                var head = new Grid { ColumnSpacing = 8 };
                head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                head.Children.Add(new TextBlock { Text = version, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                if (current)
                {
                    var badge = new Border
                    {
                        CornerRadius = new CornerRadius(8),
                        Padding = new Thickness(6, 1, 6, 1),
                        VerticalAlignment = VerticalAlignment.Center,
                        Background = new SolidColorBrush(Color.FromArgb(31, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B)),
                        Child = new TextBlock { Text = "当前版本", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = ink },
                    };
                    Grid.SetColumn(badge, 1);
                    head.Children.Add(badge);
                }

                var when = new TextBlock
                {
                    Text = date,
                    FontSize = 12,
                    Foreground = Theme.SecondaryText(),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(when, 2);
                head.Children.Add(when);
                body.Children.Add(head);
                if (summary.Length > 0)
                {
                    body.Children.Add(new TextBlock
                    {
                        Text = summary,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = Theme.SecondaryText(),
                        IsTextSelectionEnabled = true,
                    });
                }

                if (entry.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in items.EnumerateArray())
                    {
                        var type = item.TryGetProperty("type", out var t) ? t.GetString() : null;
                        var text = item.TryGetProperty("text", out var itemText) ? itemText.GetString() : null;
                        if (type is not ("feat" or "fix" or "perf" or "ui") || string.IsNullOrEmpty(text))
                        {
                            continue;
                        }

                        var change = new Grid { ColumnSpacing = 8 };
                        change.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        change.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                        var tag = SettingsUi.TypeTag(type);
                        tag.Margin = new Thickness(0, 2, 0, 0);
                        change.Children.Add(tag);
                        var line = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
                        Grid.SetColumn(line, 1);
                        change.Children.Add(line);
                        body.Children.Add(change);
                    }
                }

                Grid.SetColumn(body, 1);
                release.Children.Add(body);
                panel.Children.Add(release);
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

    /// <summary>通用 › 功能一行的家族色块（mac FeatureToggle）：和侧栏那一页同一个；录屏是「录制」页的截图粉 + 录制符号。</summary>
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
            HotKeyActions.Audio => Glyphs.Microphone,
            HotKeyActions.PinClipboard => Glyphs.Pin,
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
        "screenshot" or "record" => "capture",
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

    /// <summary>
    /// 「X 里的按键」一行（mac 各页最后的 ShortcutsButton 那一行，N11）：一句话 + 右边「查看全部快捷键…」，
    /// 点开速查表停在这一页那一类（page = null 停在第一类）。按键说明不写进页里。
    /// </summary>
    private Border AddShortcutsRow(string? page, string title, string subtitle)
    {
        var button = new Button { Content = "查看全部快捷键…" };
        AutomationProperties.SetName(button, $"{title}：查看全部快捷键");
        button.Click += (_, _) => _ = ShortcutsSheet.ShowAsync(_content.XamlRoot, page);
        var card = SettingsUi.Card(title, subtitle, button);
        _content.Children.Add(card);
        return card;
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

    /// <summary>加一张带开关的卡；返回这张卡，别的开关要原地改它的说明 / 能不能点时用（SettingsUi.SetDescription / SetEnabled）。</summary>
    private Border AddToggle(string title, string subtitle, bool value, Action<bool> changed)
    {
        var card = SettingsUi.Card(title, subtitle, SettingsUi.Toggle(value, changed, title));
        _content.Children.Add(card);
        return card;
    }

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
