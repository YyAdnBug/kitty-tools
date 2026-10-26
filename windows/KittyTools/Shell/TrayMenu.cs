// 托盘的 WinUI 菜单（PLAN-v2 §3.2 / D2）：MenuFlyout 弹在一个 1×1 的透明宿主窗口里，
// 位置在鼠标处，向上展开（托盘在屏幕底部）。跟随深浅色、Fluent 样式、每项带图标，
// 快捷键右对齐（KeyboardAcceleratorTextOverride）。键盘能操作（方向键 + Enter）。
// 点外面、按 Esc 收起；收起后宿主窗口隐藏。
//
// 为什么不用 Win32 菜单：Win32 菜单没有公开的深色接口，系统深色模式下会突然亮一块（D2）。
using KittyTools.Infrastructure;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Win32;

namespace KittyTools;

internal static partial class TrayMenu
{
    private const int HostWidth = 360;
    private const int HostHeight = 480;
    private const int GwlExStyle = -20;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExLayered = 0x00080000;
    private const uint LwaAlpha = 0x00000002;

    private static Window? _host;

    /// <summary>R33 截图自检用：菜单的宿主窗口（菜单画在它里面）。</summary>
    internal static IntPtr HandleForProbe =>
        _host is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_host);
    private static Grid? _anchor;
    private static MenuFlyout? _menu;
    private static bool _opening;

    public static bool IsOpen => _menu is not null;

    /// <summary>在鼠标位置弹出菜单（托盘右键、左键、键盘选中都走这里）。</summary>
    public static void Show()
    {
        EnsureHost();
        if (_host is null || _anchor is null)
        {
            return;
        }

        // 第一次弹：宿主窗口还没显示过，元素没有 XamlRoot，ShowAt 会抛「This element does not
        // have a XamlRoot」。先激活窗口，等 Loaded 再弹。
        if (_anchor.XamlRoot is null)
        {
            _anchor.Loaded -= OnHostLoaded;
            _anchor.Loaded += OnHostLoaded;
            _host.Activate();
            return;
        }

        ShowCore();
    }

    private static void OnHostLoaded(object sender, RoutedEventArgs e)
    {
        if (_anchor is not null)
        {
            _anchor.Loaded -= OnHostLoaded;
        }

        ShowCore();
    }

    private static void ShowCore()
    {
        if (_opening || _host is null || _anchor is null)
        {
            return;
        }

        _opening = true;
        try
        {
            PInvoke.GetCursorPos(out var cursor);
            // 宿主窗口比菜单大一些，鼠标停在右下角：Flyout 被限制在 XamlRoot 的范围里，
            // 1×1 的窗口会把菜单裁成一条（实测）。整块窗口是透明的，看不见。
            _host.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
                cursor.X - HostWidth + 1, cursor.Y - HostHeight + 1, HostWidth, HostHeight));
            // 每次弹都按现在的外观设：宿主只建一次，运行中换了深浅色菜单不会自己跟着变。
            Theme.ApplyTo(_host.Content as FrameworkElement ?? _anchor);
            _host.Activate();

            _menu = Build();
            _menu.Closed += (_, _) =>
            {
                _menu = null;
                try
                {
                    _host?.AppWindow.Hide();
                }
                catch
                {
                    // 隐藏失败不影响下一次弹菜单。
                }
            };
            // 托盘贴着屏幕底边：往上展开，右边缘对齐鼠标。不给 Position：给了之后菜单把那一点当左上角，往右展开。
            var options = new FlyoutShowOptions
            {
                Placement = FlyoutPlacementMode.TopEdgeAlignedRight,
            };
            _menu.ShowAt(_anchor, options);
        }
        catch (Exception ex)
        {
            Log.Error($"tray.menu-open-failed {ex.Message}");
            _menu = null;
        }
        finally
        {
            _opening = false;
        }
    }

    public static void Close()
    {
        _menu?.Hide();
        _menu = null;
        try
        {
            _host?.AppWindow.Hide();
        }
        catch
        {
            // 同上。
        }
    }

    private static void EnsureHost()
    {
        if (_host is not null && _anchor is not null)
        {
            return;
        }

        // 锚点放在宿主的右下角，也就是鼠标那一点。原来是 Grid 默认的居中：菜单离托盘图标差半个宿主高（约 240 px）。
        _anchor = new Grid
        {
            Width = 1,
            Height = 1,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        _host = new Window
        {
            Title = Paths.ProductName + " 菜单",
            Content = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Children = { _anchor } },
            SystemBackdrop = new TransparentBackdrop(),
        };
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        _host.AppWindow.SetPresenter(presenter);
        _host.AppWindow.IsShownInSwitchers = false;
        Theme.ApplyTo(_host.Content as FrameworkElement ?? _anchor);

        // 客户区透明（和轻提示一样把 DWM 边框扩到整个客户区），菜单外不留下白底。
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(_host);
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        var noBorder = unchecked((int)0xFFFFFFFE);
        try
        {
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
            DwmSetWindowAttribute(hwnd, 34, ref noBorder, sizeof(int));
            // 菜单画在它自己的弹出窗口里（会伸出宿主窗口的范围），宿主只当锚点。上面两步在有的机器上不管用：
            // 宿主整块白、或者留一圈白框（用户截图，360 × 480 正好是宿主大小）。分层 + 透明度 0，
            // 宿主连同系统边框一起看不见，也不挡鼠标；菜单窗口不受影响。
            var style = GetWindowLong(hwnd, GwlExStyle);
            SetWindowLong(hwnd, GwlExStyle, style | WsExLayered | WsExToolWindow);
            SetLayeredWindowAttributes(hwnd, 0, 0, LwaAlpha);
        }
        catch (Exception ex)
        {
            Log.Warn($"tray.menu-transparent-failed {ex.GetType().Name}");
        }
    }

    private static MenuFlyout Build()
    {
        var runtime = ShellRuntime.Instance;
        var settings = SettingsService.Current;
        var clipboardReady = runtime?.Clipboard is not null && Features.IsOn(Feature.Clipboard);
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.TopEdgeAlignedRight };

        // 图标的颜色跟着所在那一节走（mac 菜单栏：暂停记录算剪贴板、复制即译算翻译），最后一节是通用灰。
        var clip = Theme.Family.Clipboard;
        var translate = Theme.Family.Translate;
        var capture = Theme.Family.Capture;
        var general = Theme.Family.General;

        // 第一节：剪贴板与启动器。
        if (Features.IsOn(Feature.Clipboard))
        {
            Add(menu, Glyphs.ClipboardHistory, clip, "剪贴板历史", HotKeyActions.Clipboard,
                () => runtime?.OpenClipboard(), clipboardReady);
        }

        if (Features.IsOn(Feature.Launcher))
        {
            Add(menu, Glyphs.Search, clip, "启动器", HotKeyActions.Launcher, () => OverlayHost.Toggle(OverlayKind.Launcher));
        }

        if (Features.IsOn(Feature.Clipboard))
        {
            var pause = new ToggleMenuFlyoutItem
            {
                Text = "暂停记录剪贴板",
                IsChecked = runtime?.Clipboard?.Paused == true,
                Icon = Icon(Glyphs.Pause, clip),
                IsEnabled = clipboardReady,
            };
            pause.Click += (_, _) => runtime?.TogglePauseClipboard();
            menu.Items.Add(pause);
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        // 第二节：翻译。
        if (Features.IsOn(Feature.Translate))
        {
            Add(menu, Glyphs.TextTranslate, translate, "输入翻译", HotKeyActions.InputTranslate,
                () => TranslateHost.ToggleInput());
            var copyTranslate = new ToggleMenuFlyoutItem
            {
                Text = "复制即译",
                IsChecked = settings.CopyTranslate,
                // mac 的 doc.on.doc：复制一下就翻译。
                Icon = Icon(Glyphs.Copy, translate),
                IsEnabled = runtime is not null,
            };
            copyTranslate.Click += (_, _) => runtime?.ToggleCopyTranslate();
            menu.Items.Add(copyTranslate);
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        // 第三节：截图与录制。
        if (Features.IsOn(Feature.Screenshot))
        {
            Add(menu, Glyphs.Screenshot, capture, "截图", HotKeyActions.Screenshot,
                () => ScreenshotSession.Start(ScreenshotMode.Capture));
            if (Features.IsOn(Feature.Translate))
            {
                Add(menu, Glyphs.ScreenshotTranslate, capture, "截图翻译", HotKeyActions.ScreenshotTranslate,
                    () => ScreenshotSession.Start(ScreenshotMode.Translate));
            }

            Add(menu, Glyphs.Ocr, capture, "识字", HotKeyActions.Ocr, () => ScreenshotSession.Start(ScreenshotMode.Ocr));
            Add(menu, Glyphs.History, capture, "截图历史", HotKeyActions.ShotHistory, ShotHistoryWindow.ShowWindow);
        }

        if (Features.IsOn(Feature.Recording))
        {
            if (RecordingHost.IsRecording)
            {
                Add(menu, Glyphs.Stop, capture, "停止录屏 " + RecordingHost.Elapsed, HotKeyActions.Record,
                    RecordingHost.Stop);
            }
            else
            {
                Add(menu, Glyphs.Record, capture, "录屏", HotKeyActions.Record, RecordingHost.Toggle);
            }

            if (RecordingHost.LastPath is { } last && File.Exists(last) &&
                last.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            {
                Add(menu, Glyphs.File, capture,
                    CompressionService.IsRunning
                        ? $"压缩中 {(int)(CompressionService.Progress * 100)}%"
                        : "压缩最近的录屏（不超过 60%）",
                    string.Empty, () => _ = CompressionService.CompressLastAsync());
                Add(menu, Glyphs.Image, capture, "转成 GIF（10 fps，长边 800）", string.Empty,
                    () => _ = GifService.ConvertLastAsync());
            }

            if (AudioHost.IsRecording)
            {
                Add(menu, Glyphs.Stop, capture, "停止录音 " + AudioHost.Elapsed, string.Empty, AudioHost.Stop);
            }
            else if (AudioHost.IsArmed)
            {
                Add(menu, Glyphs.Close, capture, "取消待录", string.Empty, AudioHost.Toggle);
            }
            else
            {
                Add(menu, Glyphs.Microphone, capture, "录音（麦克风）", string.Empty, AudioHost.Toggle);
            }
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        var settingsItem = new MenuFlyoutItem
        {
            Text = "设置…",
            Icon = Icon(Glyphs.Settings, general),
        };
        settingsItem.Click += (_, _) => runtime?.ShowSettings(welcome: false);
        menu.Items.Add(settingsItem);

        var updateText = AutoUpdater.ProgressMenuText
                         ?? (UpdateService.AvailableVersion is { } available
                             ? $"更新到 {available}"
                             : "检查更新");
        var update = new MenuFlyoutItem
        {
            Text = updateText,
            // 有新版本时用强调色（mac：菜单最上面那一项「更新到 x」）。
            Icon = Icon(Glyphs.Update, UpdateService.AvailableVersion is null ? general : Theme.AccentColor),
            IsEnabled = !AutoUpdater.IsBusy,
        };
        update.Click += (_, _) =>
        {
            if (UpdateService.AvailableVersion is not null)
            {
                _ = AutoUpdater.StartAsync();
            }
            else
            {
                _ = UpdateService.CheckAsync(userInitiated: true);
            }
        };
        menu.Items.Add(update);

        var exit = new MenuFlyoutItem
        {
            Text = "退出 Kitty Tools",
            Icon = Icon(Glyphs.Shutdown, general),
        };
        exit.Click += (_, _) => runtime?.Exit();
        menu.Items.Add(exit);

        return menu;
    }

    private static FontIcon Icon(string glyph, Windows.UI.Color color)
        => new() { Glyph = glyph, Foreground = new SolidColorBrush(color) };

    private static void Add(
        MenuFlyout menu,
        string glyph,
        Windows.UI.Color color,
        string text,
        string action,
        Action invoke,
        bool enabled = true)
    {
        var item = new MenuFlyoutItem
        {
            Text = text,
            Icon = Icon(glyph, color),
            IsEnabled = enabled,
        };
        var shortcut = ShellRuntime.Instance?.HotKeys.ShortcutFor(action);
        if (!string.IsNullOrEmpty(shortcut))
        {
            item.KeyboardAcceleratorTextOverride = shortcut;
        }

        item.Click += (_, _) => invoke();
        menu.Items.Add(item);
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    [System.Runtime.InteropServices.LibraryImport(
        "dwmapi.dll", EntryPoint = "DwmExtendFrameIntoClientArea")]
    private static partial int DwmExtendFrameIntoClientArea(IntPtr hWnd, ref Margins margins);

    [System.Runtime.InteropServices.LibraryImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static partial int DwmSetWindowAttribute(IntPtr hWnd, int attribute, ref int value, int size);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hWnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hWnd, int index, int value);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetLayeredWindowAttributes", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);
}
