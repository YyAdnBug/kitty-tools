// 浮层：剪贴板面板和启动器共用的窗口。
// WinUI Window + OverlappedPresenter：无标题栏、保留边框（系统圆角 / 阴影 / 细描边）。
// 置顶、不可缩放、不进任务栏和 Alt+Tab；内容用亚克力。
// 关闭：Esc、Ctrl+W、再按一次热键、失去激活（不还前台）。
using KittyTools.Core;
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

    private readonly Grid _host;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _heightTimer;

    private ClipboardPanel? _clipboard;
    private LauncherPanel? _launcher;
    private OverlayKind _kind;
    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _visible;
    private bool _hiding;
    // 固定面板（第三版 §4）：固定后点别处不收起，粘贴粘进最近一个不是本 App 的前台窗口。
    private bool _pinned;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _foregroundTimer;
    private double _scale = 1;
    private double _heightDip = 520;
    private double _heightFrom;
    private double _heightTo;
    private long _heightStarted;

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

        _heightTimer = DispatcherQueue.CreateTimer();
        _heightTimer.Interval = TimeSpan.FromMilliseconds(16);
        _heightTimer.IsRepeating = true;
        _heightTimer.Tick += (_, _) => StepHeight();
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += OnActivated;
    }

    public bool IsVisible => _visible;

    public OverlayKind Kind => _kind;

    public HWND PasteTarget => _previousForeground;

    /// <summary>给启动器带一个查询（调试 / 从剪贴板等入口打开用）。</summary>
    public void SetLauncherQueryInner(string query) => _launcher?.SetQuery(query);

    /// <summary>Ctrl+P / 底栏图钉：固定后点别处不收起（Esc 照样收）。</summary>
    public void TogglePin()
    {
        _pinned = !_pinned;
        // 提示在面板底栏左边（PLAN-v7 §3.1），图钉跟着换样子。
        _clipboard?.SetPinned(_pinned);
        if (_pinned)
        {
            // 固定时用户可能点进别的程序再回来：隔一会儿记一下「最近一个不是本 App 的前台窗口」，粘贴就粘进它。
            _foregroundTimer ??= DispatcherQueue.CreateTimer();
            _foregroundTimer.Interval = TimeSpan.FromMilliseconds(400);
            _foregroundTimer.IsRepeating = true;
            _foregroundTimer.Tick += (_, _) => TrackExternalForeground();
            _foregroundTimer.Start();
        }
        else
        {
            _foregroundTimer?.Stop();
        }
    }

    private void TrackExternalForeground()
    {
        if (!_visible || !_pinned)
        {
            _foregroundTimer?.Stop();
            return;
        }

        var current = Foreground.Get();
        if (current != default && !Foreground.IsOurs(current) && current != _hwnd)
        {
            _previousForeground = current;
        }
    }
    public void SetClipboardQuery(string query) => _clipboard?.SetQuery(query);

    public void ShowOverlay(OverlayKind kind)
    {
        IdleReclaimer.Cancel();
        Log.Info($"overlay.begin kind={kind}");
        _kind = kind;
        _pinned = false;
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

        // 先把内容填好，再按内容算第一次高度（PLAN-v2 §3.5：高度随内容）。
        if (kind == OverlayKind.Clipboard && _clipboard is not null)
        {
            _clipboard.OnShown();
            _heightDip = _clipboard.ContentHeightDip;
        }
        else if (_launcher is not null)
        {
            _launcher.OnShown();
            _heightDip = _launcher.ContentHeightDip;
            if (OverlayHost.PendingLauncherQuery is { } pending)
            {
                OverlayHost.PendingLauncherQuery = null;
                _launcher.SetQuery(pending);
                _heightDip = _launcher.ContentHeightDip;
            }
        }

        Log.Info($"overlay.content kind={kind} height={_heightDip:F0}");
        PositionAtPointer(_heightDip);
        _visible = true;
        Activate();
        Foreground.Restore(_hwnd);
        if (kind == OverlayKind.Clipboard)
        {
            DispatcherQueue.TryEnqueue(() => _clipboard?.FocusSearch());
        }
        else
        {
            DispatcherQueue.TryEnqueue(() => _launcher?.FocusSearch());
        }

        PInvoke.DwmFlush();
        // 入场：透明度 0→1 + 内容下落 6 px（减弱动画时只淡入）。
        Motion.Entrance(kind == OverlayKind.Clipboard ? _clipboard! : _launcher!);
        Log.Info($"overlay.show kind={kind} height={_heightDip:F0}");
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
            _pinned = false;
            _foregroundTimer?.Stop();
            _clipboard?.OnHidden();
            _launcher?.OnHidden();
            AppWindow.Hide();
            // 所有面板都收起两分钟后回收可以重建的缓存（第二版 §4.2）。
            IdleReclaimer.Schedule();
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

    /// <summary>预建两块面板（不显示），第一次打开就不用再建 XAML 树。</summary>
    public void PrewarmPanels()
    {
        _clipboard ??= CreateClipboardPanel();
        _launcher ??= CreateLauncherPanel();
        Log.Info("overlay.prewarmed");
    }

    public void AuditAccessibility()
    {
        if (_clipboard is not null)
        {
            AccessibilityAudit.Run(_clipboard, "clipboard");
        }

        if (_launcher is not null)
        {
            AccessibilityAudit.Run(_launcher, "launcher");
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
        panel.HeightRequested += RequestHeight;
        // 底栏图钉 / Ctrl+P（以前这条事件没人接，点了没反应）。
        panel.PinRequested += TogglePin;
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
        panel.HeightRequested += RequestHeight;
        return panel;
    }

    /// <summary>
    /// 内容高度变了：顶边不动，只改高度（PLAN-v2 §3.5）。按内容变化（换选中、换范围、开面板）
    /// 用 settle 弹簧；每按一个键结果就变的那种不带动画，直接跳。
    /// </summary>
    private void RequestHeight(double dip, bool animated)
    {
        if (!_visible || Math.Abs(dip - _heightDip) < 1)
        {
            return;
        }

        if (!animated || Motion.Reduced)
        {
            _heightTimer.Stop();
            _heightDip = dip;
            ApplyHeight(dip);
            return;
        }

        _heightFrom = _heightDip;
        _heightTo = dip;
        _heightStarted = Environment.TickCount64;
        _heightTimer.Start();
    }

    private void StepHeight()
    {
        var spec = MotionCurves.Of(MotionCurve.Settle);
        var duration = spec?.Duration ?? 0.24;
        var t = (Environment.TickCount64 - _heightStarted) / 1000.0 / duration;
        if (t >= 1)
        {
            _heightTimer.Stop();
            _heightDip = _heightTo;
            ApplyHeight(_heightTo);
            return;
        }

        var height = SpringEase.Lerp(_heightFrom, _heightTo, t, spec?.Bounce ?? 0);
        _heightDip = height;
        ApplyHeight(height);
    }

    private void ApplyHeight(double dip)
    {
        var widthPx = MonitorLayout.Pixels(WidthDip, _scale);
        var heightPx = MonitorLayout.Pixels(dip, _scale);
        var position = AppWindow.Position;
        AppWindow.MoveAndResize(new RectInt32(position.X, position.Y, widthPx, heightPx));
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding && !_pinned)
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

    private void PositionAtPointer(double heightDip)
    {
        // 鎸夐紶鏍囨墍鍦ㄦ樉绀哄櫒鑷繁鐨勭缉鏀炬瘮渚嬬畻灏哄锛屼笉鐢ㄧ獥鍙ｅ綋鍓嶆墍鍦ㄩ偅鍧楀睆鐨?DPI
        // 锛堜袱鍧楀睆缂╂斁涓嶅悓鏃讹紝720 DIP 浼氱畻鎴愪竴鍧楀睆鐨勫儚绱犮€佹憜鍒板彟涓€鍧楀睆涓婂氨缂╂按浜嗭級銆?
        var display = Displays.AtCursor();
        _scale = display.Scale <= 0 ? 1 : display.Scale;
        var rect = MonitorLayout.Overlay(
            display.Work, _scale, WidthDip, heightDip, MonitorLayout.ClipboardTopFraction);
        AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
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

    public static void AuditAccessibility() => _window?.AuditAccessibility();

    /// <summary>关掉某个功能时把它的浮层收起来（第三版 §2.3）。</summary>
    public static void HideKind(OverlayKind kind)
    {
        if (_window is { IsVisible: true } window && window.Kind == kind)
        {
            window.HideOverlay(restoreForeground: false);
        }
    }

    public static void SetClipboardQuery(string query) => _window?.SetClipboardQuery(query);

    public static void SetLauncherQuery(string query)
    {
        if (_window is { IsVisible: true } window)
        {
            window.SetLauncherQueryInner(query);
            return;
        }

        PendingLauncherQuery = query;
    }

    internal static string? PendingLauncherQuery;

    /// <summary>启动 3 秒后预建浮层和两块面板（第二版 §4.2：第一次按热键 115–256 ms → 十几毫秒）。</summary>
    public static void Prewarm()
    {
        try
        {
            _window ??= new OverlayWindow();
            _window.PrewarmPanels();
        }
        catch (Exception ex)
        {
            Log.Warn($"overlay.prewarm-failed {ex.GetType().Name}");
        }
    }
}
