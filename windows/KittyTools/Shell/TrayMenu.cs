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
using Windows.Foundation;
using Windows.Win32;

namespace KittyTools;

internal static partial class TrayMenu
{
    private const int HostWidth = 360;
    private const int HostHeight = 480;

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
            // 托盘贴着屏幕底边：往上展开，右边缘对齐鼠标。
            var options = new FlyoutShowOptions
            {
                Placement = FlyoutPlacementMode.TopEdgeAlignedRight,
                Position = new Point(0, 0),
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

        _anchor = new Grid { Width = 1, Height = 1 };
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

        // 第一节：剪贴板与启动器。
        if (Features.IsOn(Feature.Clipboard))
        {
            Add(menu, Glyphs.Copy, "剪贴板历史", HotKeyActions.Clipboard, () => runtime?.OpenClipboard(), clipboardReady);
        }

        if (Features.IsOn(Feature.Launcher))
        {
            Add(menu, Glyphs.Search, "启动器", HotKeyActions.Launcher, () => OverlayHost.Toggle(OverlayKind.Launcher));
        }

        if (Features.IsOn(Feature.Clipboard))
        {
            var pause = new ToggleMenuFlyoutItem
            {
                Text = "暂停记录剪贴板",
                IsChecked = runtime?.Clipboard?.Paused == true,
                Icon = new FontIcon { Glyph = Glyphs.Pause },
                IsEnabled = clipboardReady,
            };
            pause.Click += (_, _) => runtime?.TogglePauseClipboard();
            menu.Items.Add(pause);
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        // 第二节：翻译。
        if (Features.IsOn(Feature.Translate))
        {
            Add(menu, Glyphs.Translate, "输入翻译", HotKeyActions.InputTranslate, () => TranslateHost.ToggleInput());
            var copyTranslate = new ToggleMenuFlyoutItem
            {
                Text = "复制即译",
                IsChecked = settings.CopyTranslate,
                Icon = new FontIcon { Glyph = Glyphs.Language },
                IsEnabled = runtime is not null,
            };
            copyTranslate.Click += (_, _) => runtime?.ToggleCopyTranslate();
            menu.Items.Add(copyTranslate);
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        // 第三节：截图与录制。
        if (Features.IsOn(Feature.Screenshot))
        {
            Add(menu, Glyphs.Screenshot, "截图", HotKeyActions.Screenshot, () => ScreenshotSession.Start(ScreenshotMode.Capture));
            if (Features.IsOn(Feature.Translate))
            {
                Add(menu, Glyphs.Language, "截图翻译", HotKeyActions.ScreenshotTranslate,
                    () => ScreenshotSession.Start(ScreenshotMode.Translate));
            }

            Add(menu, Glyphs.Text, "识字", HotKeyActions.Ocr, () => ScreenshotSession.Start(ScreenshotMode.Ocr));
            Add(menu, Glyphs.History, "截图历史", HotKeyActions.ShotHistory, ShotHistoryWindow.ShowWindow);
        }

        if (Features.IsOn(Feature.Recording))
        {
            if (RecordingHost.IsRecording)
            {
                Add(menu, Glyphs.Stop, "停止录屏 " + RecordingHost.Elapsed, HotKeyActions.Record, RecordingHost.Stop);
            }
            else
            {
                Add(menu, Glyphs.Record, "录屏", HotKeyActions.Record, RecordingHost.Toggle);
            }

            if (RecordingHost.LastPath is { } last && File.Exists(last) &&
                last.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            {
                Add(menu, Glyphs.File,
                    CompressionService.IsRunning
                        ? $"压缩中 {(int)(CompressionService.Progress * 100)}%"
                        : "压缩最近的录屏（不超过 60%）",
                    string.Empty, () => _ = CompressionService.CompressLastAsync());
                Add(menu, Glyphs.Image, "转成 GIF（10 fps，长边 800）", string.Empty,
                    () => _ = GifService.ConvertLastAsync());
            }

            if (AudioHost.IsRecording)
            {
                Add(menu, Glyphs.Stop, "停止录音 " + AudioHost.Elapsed, string.Empty, AudioHost.Stop);
            }
            else if (AudioHost.IsArmed)
            {
                Add(menu, Glyphs.Close, "取消待录", string.Empty, AudioHost.Toggle);
            }
            else
            {
                Add(menu, Glyphs.Microphone, "录音（麦克风）", string.Empty, AudioHost.Toggle);
            }
        }

        menu.Items.Add(new MenuFlyoutSeparator());

        var settingsItem = new MenuFlyoutItem
        {
            Text = "设置…",
            Icon = new FontIcon { Glyph = Glyphs.Settings },
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
            Icon = new FontIcon { Glyph = Glyphs.Update },
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
            Icon = new FontIcon { Glyph = Glyphs.Shutdown },
        };
        exit.Click += (_, _) => runtime?.Exit();
        menu.Items.Add(exit);

        return menu;
    }

    private static void Add(
        MenuFlyout menu,
        string glyph,
        string text,
        string action,
        Action invoke,
        bool enabled = true)
    {
        var item = new MenuFlyoutItem
        {
            Text = text,
            Icon = new FontIcon { Glyph = glyph },
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
}
