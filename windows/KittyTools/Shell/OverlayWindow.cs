// 浮层：剪贴板面板和启动器共用的窗口。
// WinUI Window + OverlappedPresenter：无标题栏、保留边框（系统圆角 / 阴影 / 细描边）、
// 置顶、不可缩放、不进任务栏和 Alt+Tab；内容用亚克力。
// 关闭：Esc、Ctrl+W、再按一次热键、失去激活（不还前台）。
using KittyTools.Infrastructure;
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
    private const int LauncherHeightDip = 520;
    private const int ClipboardHeightDip = 520;

    private readonly Grid _host;

    private ClipboardPanel? _clipboard;
    private LauncherPanel? _launcher;
    private OverlayKind _kind;
    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _visible;
    private bool _hiding;

    public OverlayWindow()
    {
        Title = Paths.ProductName + " 浮层";
        _host = new Grid { RequestedTheme = Theme.ElementTheme };

        Content = _host;
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
        Activated += OnActivated;
    }

    public bool IsVisible => _visible;

    public OverlayKind Kind => _kind;

    public HWND PasteTarget => _previousForeground;

    public void SetClipboardQuery(string query) => _clipboard?.SetQuery(query);

    public void ShowOverlay(OverlayKind kind)
    {
        _kind = kind;
        _host.RequestedTheme = Theme.ElementTheme;

        var before = Foreground.Get();
        if (before != default && !Foreground.IsOurs(before))
        {
            _previousForeground = before;
        }

        _host.Children.Clear();
        if (kind == OverlayKind.Clipboard && ClipboardService.Instance is not null)
        {
            _clipboard ??= CreateClipboardPanel();
            _host.Children.Add(_clipboard);
        }
        else
        {
            _launcher ??= CreateLauncherPanel();
            _host.Children.Add(_launcher);
        }

        PositionAtPointer(kind == OverlayKind.Clipboard ? ClipboardHeightDip : LauncherHeightDip);
        _visible = true;
        Activate();
        Foreground.Restore(_hwnd);
        if (kind == OverlayKind.Clipboard)
        {
            _clipboard?.OnShown();
            DispatcherQueue.TryEnqueue(() => _clipboard?.FocusSearch());
        }
        else
        {
            _launcher?.OnShown();
            DispatcherQueue.TryEnqueue(() => _launcher?.FocusSearch());
        }

        PInvoke.DwmFlush();
        Log.Info($"overlay.show kind={kind}");
    }

    public void HideOverlay(bool restoreForeground)
    {
        if (!_visible)
        {
            return;
        }

        _hiding = true;
        try
        {
            _visible = false;
            _clipboard?.OnHidden();
            _launcher?.OnHidden();
            AppWindow.Hide();
            Log.Info($"overlay.hide restore={restoreForeground}");
            if (restoreForeground && _previousForeground != default)
            {
                Foreground.Restore(_previousForeground);
            }
        }
        finally
        {
            _hiding = false;
        }
    }

    private ClipboardPanel CreateClipboardPanel()
    {
        var panel = new ClipboardPanel();
        panel.CloseRequested += () => HideOverlay(restoreForeground: true);
        panel.SettingsRequested += () =>
        {
            HideOverlay(restoreForeground: false);
            ShellRuntime.Instance?.ShowSettings(welcome: false, page: "clipboard");
        };
        return panel;
    }

    private LauncherPanel CreateLauncherPanel()
    {
        var panel = new LauncherPanel();
        panel.CloseRequested += () => HideOverlay(restoreForeground: true);
        panel.SettingsRequested += () =>
        {
            HideOverlay(restoreForeground: false);
            ShellRuntime.Instance?.ShowSettings(welcome: false, page: "launcher");
        };
        return panel;
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding)
        {
            HideOverlay(restoreForeground: false);
            return;
        }

        if (args.WindowActivationState == WindowActivationState.CodeActivated && _visible)
        {
            if (_kind == OverlayKind.Clipboard)
            {
                DispatcherQueue.TryEnqueue(() => _clipboard?.FocusSearch());
            }
            else
            {
                DispatcherQueue.TryEnqueue(() => _launcher?.FocusSearch());
            }
        }
    }

    private void PositionAtPointer(int heightDip)
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
        var height = (int)Math.Round(heightDip * scale);
        var work = info.rcWork;
        var x = work.left + Math.Max(0, (work.right - work.left - width) / 2);
        var y = work.top + (int)Math.Round((work.bottom - work.top) * 0.2);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }
}

internal static class OverlayHost
{
    private static OverlayWindow? _window;

    public static bool IsVisible => _window?.IsVisible == true;

    public static HWND PasteTarget => _window?.PasteTarget ?? default;

    public static void Toggle(OverlayKind kind)
    {
        if (_window is { IsVisible: true })
        {
            if (_window.Kind == kind)
            {
                _window.HideOverlay(restoreForeground: true);
                return;
            }

            TranslateHost.Hide(restoreForeground: false);
            _window.ShowOverlay(kind);
            return;
        }

        Show(kind);
    }

    public static void Show(OverlayKind kind)
    {
        TranslateHost.Hide(restoreForeground: false);
        _window ??= new OverlayWindow();
        _window.ShowOverlay(kind);
    }

    public static void Hide(bool restoreForeground) => _window?.HideOverlay(restoreForeground);

    public static void SetClipboardQuery(string query) => _window?.SetClipboardQuery(query);
}
