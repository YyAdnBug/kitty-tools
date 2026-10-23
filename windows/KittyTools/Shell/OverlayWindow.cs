// 浮层：剪贴板面板和启动器共用的窗口（第 0 批只验证窗口本身）。
// WinUI Window + OverlappedPresenter：无标题栏、保留边框（拿系统圆角 / 阴影 / 细描边）、
// 置顶、不可缩放、不进任务栏和 Alt+Tab；内容用亚克力。
using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal enum OverlayKind
{
    Clipboard,
    Launcher,
}

internal sealed unsafe class OverlayWindow : Window
{
    private const int WidthDip = 720;
    private const int HeightDip = 360;

    private readonly TextBlock _title;
    private readonly TextBox _search;
    private readonly TextBlock _hint;
    private readonly Grid _root;

    private OverlayKind _kind;
    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _renderingHooked;

    public OverlayWindow()
    {
        Title = "Kitty Tools";

        _root = new Grid
        {
            Padding = new Thickness(20, 16, 20, 16),
            RowSpacing = 10,
            Background = new SolidColorBrush(Colors.Transparent),
            RequestedTheme = ProbeRuntime.ForcedTheme,
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
        };
        header.Children.Add(new FontIcon
        {
            Glyph = "\uE8C8",
            FontSize = 16,
            Foreground = new SolidColorBrush(Theme.BrandPink),
        });
        _title = new TextBlock
        {
            Text = "剪贴板历史",
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        header.Children.Add(_title);

        _search = new TextBox
        {
            PlaceholderText = "搜索剪贴板…",
            FontSize = 20,
            Height = 56,
            VerticalContentAlignment = VerticalAlignment.Center,
        };

        _hint = new TextBlock
        {
            Text = "还没有记录",
            Opacity = 0.6,
            Margin = new Thickness(2, 0, 0, 0),
        };

        _search.KeyDown += OnSearchKeyDown;
        _search.TextChanged += (_, _) =>
        {
            _hint.Text = string.IsNullOrEmpty(_search.Text)
                ? "还没有记录"
                : $"搜索：{_search.Text}";
        };

        var card = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            // 样机不直接查主题资源：Release AOT 下 Application.Resources 里暂时拿不到
            // CardBackgroundFillColorDefaultBrush（Debug 可以）。正式界面用 XAML 的
            // {ThemeResource ...}，见报告「待定 / 给第 1 批」。
            Background = new SolidColorBrush(ProbeRuntime.ForcedTheme == ElementTheme.Dark
                ? Windows.UI.Color.FromArgb(36, 255, 255, 255)
                : Windows.UI.Color.FromArgb(20, 0, 0, 0)),
            Child = new TextBlock
            {
                Text = "第 0 批验证样机：这里只放一块卡片看材质和圆角。",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.7,
            },
        };

        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(card);
        body.Children.Add(_hint);

        Grid.SetRow(header, 0);
        Grid.SetRow(_search, 1);
        Grid.SetRow(body, 2);
        _root.Children.Add(header);
        _root.Children.Add(_search);
        _root.Children.Add(body);

        Content = _root;
        SystemBackdrop = new AcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);

        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated)
            {
                _search.Focus(FocusState.Programmatic);
            }
        };
    }

    public OverlayKind Kind => _kind;

    public bool IsShown { get; private set; }

    public void ShowOverlay(OverlayKind kind, long hotkeyTicks)
    {
        _kind = kind;
        var clipboard = kind == OverlayKind.Clipboard;
        _title.Text = clipboard ? "剪贴板历史" : "启动器";
        _search.PlaceholderText = clipboard ? "搜索剪贴板…" : "搜索应用、设置、命令…";
        _search.Text = string.Empty;

        var before = PInvoke.GetForegroundWindow();
        if (before != default && !Foreground.IsOurs(before))
        {
            _previousForeground = before;
        }

        PositionAtPointer();

        var t0 = Stopwatch.GetTimestamp();
        IsShown = true;
        Activate();
        if (!Foreground.Restore(_hwnd))
        {
            PInvoke.SetForegroundWindow(_hwnd);
        }
        _search.Focus(FocusState.Programmatic);
        PInvoke.DwmFlush();
        var tVisible = Stopwatch.GetTimestamp();

        var focused = _search.FocusState != FocusState.Unfocused;
        ProbeLog.Write(
            "overlay.visible",
            ("kind", kind.ToString()),
            ("from_hotkey_ms", Ms(hotkeyTicks, tVisible)),
            ("from_activate_ms", Ms(t0, tVisible)),
            ("focused", focused),
            ("foreground_ok", PInvoke.GetForegroundWindow() == _hwnd),
            ("hwnd", ((IntPtr)_hwnd.Value).ToInt64()),
            ("rect", $"{AppWindow.Position.X},{AppWindow.Position.Y},{AppWindow.Size.Width},{AppWindow.Size.Height}"));

        HookFirstFrame(tVisible);
        LogLayoutLater();
    }

    private void LogLayoutLater()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(500);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            ProbeLog.Write(
                "overlay.layout",
                ("root_w", _root.ActualWidth),
                ("root_h", _root.ActualHeight),
                ("search_w", _search.ActualWidth),
                ("search_h", _search.ActualHeight),
                ("xamlroot", _root.XamlRoot is not null),
                ("focus", _search.FocusState.ToString()),
                ("active", AppWindow.IsVisible),
                ("same_content", ReferenceEquals(Content, _root)),
                ("visibility", _root.Visibility.ToString()),
                ("opacity", _root.Opacity),
                ("loaded", _root.IsLoaded),
                ("children", Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(_root)),
                ("theme", _root.ActualTheme.ToString()),
                ("hwnd", ((IntPtr)_hwnd.Value).ToInt64()));
        };
        timer.Start();
    }

    private void HookFirstFrame(long tVisible)
    {
        if (_renderingHooked)
        {
            return;
        }

        _renderingHooked = true;
        void OnRendering(object? sender, object e)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
            ProbeLog.Write("overlay.first-frame", ("from_visible_ms", Ms(tVisible, Stopwatch.GetTimestamp())));
        }

        CompositionTarget.Rendering += OnRendering;
    }

    public void HideOverlay(bool restoreForeground)
    {
        if (!IsShown)
        {
            return;
        }

        var target = _previousForeground;
        IsShown = false;
        AppWindow.Hide();
        ProbeLog.Write("overlay.hidden", ("restore", restoreForeground));

        if (restoreForeground && target != default)
        {
            Foreground.Restore(target);
        }
    }

    private unsafe void PositionAtPointer()
    {
        PInvoke.GetCursorPos(out var cursor);
        var monitor = PInvoke.MonitorFromPoint(cursor, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        if (!PInvoke.GetMonitorInfo(monitor, ref info))
        {
            return;
        }

        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        var width = (int)Math.Round(WidthDip * scale);
        var height = (int)Math.Round(HeightDip * scale);
        var work = info.rcWork;
        var x = work.left + Math.Max(0, (work.right - work.left - width) / 2);
        var y = work.top + (int)Math.Round((work.bottom - work.top) * 0.2);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            e.Handled = true;
            HideOverlay(restoreForeground: true);
        }
        else if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            var text = _search.Text;
            if (text.Length > 0 && _previousForeground != default)
            {
                Paster.PasteText(_previousForeground, text);
            }
        }
        else if (e.Key == Windows.System.VirtualKey.W &&
                 Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                     .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
        {
            e.Handled = true;
            HideOverlay(restoreForeground: true);
        }
    }

    private static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}

internal static class OverlayHost
{
    private static OverlayWindow? _window;

    public static void Toggle(OverlayKind kind, long hotkeyTicks)
    {
        if (_window is { IsShown: true })
        {
            if (_window.Kind == kind)
            {
                _window.HideOverlay(restoreForeground: true);
                return;
            }

            _window.ShowOverlay(kind, hotkeyTicks);
            return;
        }

        _window ??= new OverlayWindow();
        _window.ShowOverlay(kind, hotkeyTicks);
    }

    public static void ShowClipboard() => Toggle(OverlayKind.Clipboard, Stopwatch.GetTimestamp());

    public static void ShowLauncher() => Toggle(OverlayKind.Launcher, Stopwatch.GetTimestamp());

    public static void Hide(bool restoreForeground) => _window?.HideOverlay(restoreForeground);

    public static void Destroy()
    {
        _window?.Close();
        _window = null;
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
    }

    public static void ToggleForProbe(OverlayKind kind) => Toggle(kind, Stopwatch.GetTimestamp());
}
