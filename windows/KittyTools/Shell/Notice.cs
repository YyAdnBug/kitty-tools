// 轻提示（mac 的「刘海岛」）：鼠标所在屏、工作区顶部居中、往下 12 px。
// 第二版 §3.3：真正的胶囊——窗口透明（DWM 把边框扩到客户区，只留下中间那颗 36 DIP 高的深色药丸），
// 宽度从 36 用 settle 弹簧长到实际宽度，内容晚 60 ms 淡入；原地换内容时只动宽度；
// 出错时左右抖一下；系统关了动画效果时只淡入淡出。
// 点得穿：WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW，SW_SHOWNOACTIVATE。
// （只加 WS_EX_TRANSPARENT 的话鼠标照样被挡住——第二版 §2 第 10 条。）
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal enum NoticeTone
{
    Normal,
    Warning,
    Error,
}

internal sealed unsafe partial class NoticeHost
{
    private const int GwlExStyle = -20;
    private const int WsExTransparent = 0x00000020;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExLayered = 0x00080000;
    private const int WsExNoActivate = 0x08000000;
    private const int SwShowNoActivate = 4;
    private const int LwaAlpha = 0x00000002;

    /// <summary>胶囊高度（DIP）。圆角等于高度一半。</summary>
    private const double PillHeight = 36;

    /// <summary>窗口比胶囊四周多出来的透明边：抖动和阴影用。</summary>
    private const double WindowPadding = 10;

    /// <summary>内容最宽（DIP），再长就省略。</summary>
    private const double MaxPillWidth = 460;

    private static NoticeHost? _current;

    private readonly Window _window;
    private readonly Grid _root;
    private readonly Border _pill;
    private readonly FontIcon _icon;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly HWND _hwnd;
    private readonly DispatcherQueueTimer _hideTimer;
    private readonly DispatcherQueueTimer _widthTimer;

    private NoticeTone _tone = NoticeTone.Normal;
    private bool _shown;
    private double _pillWidth = 36;
    private double _widthFrom;
    private double _widthTo;
    private long _widthStarted;
    private bool _growing;

    private NoticeHost()
    {
        _pill = new Border
        {
            Height = PillHeight,
            Width = 36,
            CornerRadius = new CornerRadius(PillHeight / 2),
            Padding = new Thickness(14, 0, 16, 0),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            Background = new SolidColorBrush(Theme.Capsule.Normal),
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9 };
        _icon = new FontIcon
        {
            FontSize = 15,
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var texts = new StackPanel { Spacing = 0, VerticalAlignment = VerticalAlignment.Center };
        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Theme.Shot.HudText),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        _detail = new TextBlock
        {
            FontSize = 12,
            Foreground = new SolidColorBrush(Theme.Shot.HudTextMuted),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 420,
        };
        texts.Children.Add(_title);
        texts.Children.Add(_detail);
        row.Children.Add(_icon);
        row.Children.Add(texts);
        _pill.Child = row;

        _root = new Grid
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        _root.Children.Add(_pill);
        // 读屏：轻提示是活区，出现时用 UIA 通知播报（讲述人 / NVDA 都认这一条）。
        AutomationProperties.SetLiveSetting(_root, AutomationLiveSetting.Polite);
        AutomationProperties.SetName(_root, Paths.ProductName + " 提示");

        _window = new Window
        {
            Title = Paths.ProductName + " 提示",
            Content = _root,
            // 真正的透明（REVIEW R5）：只扩 DWM 边框，胶囊外面会露出一圈窗口底色。
            SystemBackdrop = new TransparentBackdrop(),
        };
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        _window.AppWindow.SetPresenter(presenter);
        _window.AppWindow.IsShownInSwitchers = false;
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(_window);

        // 建好就把「不抢焦点、不接鼠标」的样式挂上：第一次显示也不能激活，
        // 否则会在浮层里复制 / 删除之后把浮层抢掉（浮层失去激活就会收起）。
        var style = GetWindowLong((IntPtr)_hwnd.Value, GwlExStyle);
        SetWindowLong(
            (IntPtr)_hwnd.Value,
            GwlExStyle,
            style | WsExNoActivate | WsExToolWindow | WsExTransparent | WsExLayered);
        SetLayeredWindowAttributes((IntPtr)_hwnd.Value, 0, 255, LwaAlpha);

        // 把 DWM 的边框扩到整个客户区：客户区里 XAML 没画东西的地方就是真透明，
        // 只剩中间那颗胶囊（第二版 §3.3）。
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        var noBorder = unchecked((int)0xFFFFFFFE); // DWMWA_COLOR_NONE
        try
        {
            DwmExtendFrameIntoClientArea((IntPtr)_hwnd.Value, ref margins);
            // 扩了边框之后系统会在窗口四周画一圈 1 px 的边框，胶囊外面会多出一圈白线。
            DwmSetWindowAttribute((IntPtr)_hwnd.Value, 34 /* DWMWA_BORDER_COLOR */, ref noBorder, sizeof(int));
        }
        catch (Exception ex)
        {
            Log.Warn($"notice.transparent-failed {ex.GetType().Name}");
        }

        _hideTimer = _window.DispatcherQueue.CreateTimer();
        _hideTimer.Interval = TimeSpan.FromSeconds(2);
        _hideTimer.IsRepeating = false;
        _hideTimer.Tick += (_, _) => Hide();

        _widthTimer = _window.DispatcherQueue.CreateTimer();
        _widthTimer.Interval = TimeSpan.FromMilliseconds(16);
        _widthTimer.IsRepeating = true;
        _widthTimer.Tick += (_, _) => StepWidth();
    }

    public static void Show(string title, string detail, NoticeTone tone)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, tone);
    }

    private void ShowCore(string title, string detail, NoticeTone tone)
    {
        var toneChanged = tone != _tone;
        _tone = tone;
        _title.Text = title;
        _detail.Text = detail;
        _detail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
        (_icon.Glyph, _pill.Background) = tone switch
        {
            NoticeTone.Warning => ("\uE7BA", new SolidColorBrush(Theme.Capsule.Warning)),
            NoticeTone.Error => ("\uEA39", new SolidColorBrush(Theme.Capsule.Error)),
            _ => ("\uE946", new SolidColorBrush(Theme.Capsule.Normal)),
        };

        var target = MeasurePillWidth();
        PositionAtPointer(target);
        PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)SwShowNoActivate);
        PInvoke.DwmFlush();

        // 第一次长出来：宽度从 36 弹簧到实际宽度，内容晚 60 ms 淡入。
        // 原地换内容：只动宽度，内容直接换。
        if (!_shown || toneChanged)
        {
            _pillWidth = 36;
            _pill.Width = 36;
            Motion.Fade(_pill.Child as FrameworkElement, 0, 0);
            Motion.Fade(_pill.Child as FrameworkElement, 1, MotionCurves.FadeInSeconds, delayMs: 60);
        }

        StartGrow(target);
        if (tone == NoticeTone.Error)
        {
            Motion.Shake(_pill);
        }

        _shown = true;
        _hideTimer.Stop();
        _hideTimer.Start();
        Announce(title, detail);
    }

    private void Announce(string title, string detail)
    {
        try
        {
            var text = string.IsNullOrWhiteSpace(detail) ? title : $"{title}，{detail}";
            var peer = FrameworkElementAutomationPeer.FromElement(_root) ??
                       FrameworkElementAutomationPeer.CreatePeerForElement(_root);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                text,
                "kitty-notice");
        }
        catch (Exception ex)
        {
            Log.Warn($"notice.announce-failed {ex.GetType().Name}");
        }
    }

    private void StartGrow(double target)
    {
        _widthFrom = _pillWidth;
        _widthTo = target;
        if (Math.Abs(_widthTo - _widthFrom) < 0.5 || Motion.Reduced)
        {
            _growing = false;
            _pillWidth = _widthTo;
            _pill.Width = _widthTo;
            return;
        }

        _widthStarted = Environment.TickCount64;
        _growing = true;
        _widthTimer.Start();
    }

    private void StepWidth()
    {
        var spec = MotionCurves.Of(MotionCurve.Island);
        var duration = spec?.Duration ?? 0.42;
        var bounce = spec?.Bounce ?? 0.22;
        var t = (Environment.TickCount64 - _widthStarted) / 1000.0 / duration;
        if (t >= 1)
        {
            _pillWidth = _widthTo;
            _pill.Width = _widthTo;
            _growing = false;
            _widthTimer.Stop();
            return;
        }

        _pillWidth = _widthFrom + (_widthTo - _widthFrom) * SpringEase.Progress(t, bounce);
        _pill.Width = _pillWidth;
    }

    /// <summary>按内容量一遍胶囊要多宽（标题 / 详情不折行，超过上限就省略）。</summary>
    private double MeasurePillWidth()
    {
        _pill.Width = double.NaN;
        _pill.Measure(new Windows.Foundation.Size(MaxPillWidth, PillHeight));
        var width = Math.Clamp(_pill.DesiredSize.Width, 36, MaxPillWidth);
        return width;
    }

    private void Hide()
    {
        if (_growing)
        {
            _widthTimer.Stop();
            _growing = false;
        }

        _hideTimer.Stop();
        _window.AppWindow.Hide();
    }

    /// <summary>窗口按胶囊最终宽度摆好（透明边留给抖动），位置在鼠标所在屏顶部居中。</summary>
    private void PositionAtPointer(double pillWidth)
    {
        var display = Displays.AtCursor();
        var rect = MonitorLayout.Notice(
            display.Work, display.Scale,
            pillWidth + WindowPadding * 2, PillHeight + WindowPadding * 2,
            MonitorLayout.NoticeTopOffsetDip);
        _window.AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hWnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hWnd, int index, int value);

    [LibraryImport("user32.dll", EntryPoint = "SetLayeredWindowAttributes", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmExtendFrameIntoClientArea")]
    private static partial int DwmExtendFrameIntoClientArea(IntPtr hWnd, ref Margins margins);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static partial int DwmSetWindowAttribute(IntPtr hWnd, int attribute, ref int value, int size);
}
