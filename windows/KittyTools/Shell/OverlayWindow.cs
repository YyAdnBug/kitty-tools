// 娴眰锛氬壀璐存澘闈㈡澘鍜屽惎鍔ㄥ櫒鍏辩敤鐨勭獥鍙ｃ€?
// WinUI Window + OverlappedPresenter锛氭棤鏍囬鏍忋€佷繚鐣欒竟妗嗭紙绯荤粺鍦嗚 / 闃村奖 / 缁嗘弿杈癸級銆?
// 缃《銆佷笉鍙缉鏀俱€佷笉杩涗换鍔℃爮鍜?Alt+Tab锛涘唴瀹圭敤浜氬厠鍔涖€?
// 鍏抽棴锛欵sc銆丆trl+W銆佸啀鎸変竴娆＄儹閿€佸け鍘绘縺娲伙紙涓嶈繕鍓嶅彴锛夈€?
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
    private double _scale = 1;
    private double _heightDip = 520;
    private double _heightFrom;
    private double _heightTo;
    private long _heightStarted;

    public OverlayWindow()
    {
        Title = Paths.ProductName + " 娴眰";
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

    public void SetClipboardQuery(string query) => _clipboard?.SetQuery(query);

    public void ShowOverlay(OverlayKind kind)
    {
        IdleReclaimer.Cancel();
        Log.Info($"overlay.begin kind={kind}");
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

        // 鍏堟妸鍐呭濉ソ锛屽啀鎸夊唴瀹圭畻绗竴娆￠珮搴︼紙PLAN-v2 搂3.5锛氶珮搴﹂殢鍐呭锛夈€?
        if (kind == OverlayKind.Clipboard && _clipboard is not null)
        {
            _clipboard.OnShown();
            _heightDip = _clipboard.ContentHeightDip;
        }
        else if (_launcher is not null)
        {
            _launcher.OnShown();
            _heightDip = _launcher.ContentHeightDip;
        }

        Log.Info($"overlay.content kind={kind} height={_heightDip:F0}");
        PositionAtPointer(_heightDip);        _visible = true;
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
        // 鍏ュ満锛氶€忔槑搴?0鈫? + 鍐呭涓嬭惤 6 px锛堝噺寮卞姩鐢绘椂鍙贰鍏ワ級銆?
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
    /// 鍐呭楂樺害鍙樹簡锛氶《杈逛笉鍔紝鍙敼楂樺害锛圥LAN-v2 搂3.5锛夈€傛寜鍐呭鍙樺寲锛堟崲閫変腑銆佹崲鑼冨洿銆佸紑闈㈡澘锛?
    /// 鐢?settle 寮圭哀锛涙瘡鎸変竴涓敭缁撴灉灏卞彉鐨勯偅绉嶄笉甯﹀姩鐢伙紝鐩存帴璺炽€?
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

    public static void SetClipboardQuery(string query) => _window?.SetClipboardQuery(query);

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
