// 轻提示（mac 的「刘海岛」；Windows 上没有刘海，就是 mac 无刘海屏那颗胶囊，PLAN-v7 §3.4 / U4）：
// 鼠标所在屏、工作区顶部居中、胶囊顶边往下 8。纯黑 0.92 + white 0.12 发丝线，高 36。
// 窗口一次定死在最大尺寸（透明），只让 Composition 里的圆角矩形几何变形（§2.3）：黑底（ShapeVisual）
// 和裁内容的 clip 走同一组尺寸，内容按最终尺寸一次排好、被形体裁出来，动画期间主线程不排版。
// 长出来：36 → 实际宽度（island 弹簧）；内容晚 60 ms 淡入、从 0.9 放大到 1（顶边锚点）。原地换内容只动尺寸；
// 出错整颗左右抖 [0, −7, 6, −4, 2, 0] 0.4 s；消失先退内容 0.12 s，0.08 s 后形体 retract 缩回再收窗口。
// 系统关了动画效果时：形体直接到位，只做 0.2 s 的淡入淡出。
// 报得出百分比的（下载更新、转 GIF、压缩）走 ShowProgress：标题后面一条 56 × 4 的细进度条，原地改、不重新出场、不播报。
// 能交互（PLAN-v8 第 5 批 H9–H14，照 mac「刘海岛交互」里和刘海无关的那部分）：平时点得穿；提示开着时每 33 ms 看一次指针，
// 指针动过、落在画出来的形状上才去掉 WS_EX_TRANSPARENT 接鼠标。悬停：停住计时、往下长成卡片（第一行 + 最多 4 行详情），
// 按钮全露出来、加 ×；离开合回一行、接着走剩下的时间（至少 1.5 s）。点胶囊本身只执行「打开」类的按钮。
// 鼠标在上面时来的新提示先排着（只留最新的），进行中那条的结果原地换。
// 点得穿：WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW，SW_SHOWNOACTIVATE。
// （只加 WS_EX_TRANSPARENT 的话鼠标照样被挡住——第二版 §2 第 10 条。）
using System.Numerics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
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

/// <summary>
/// 提示上的一个按钮（PLAN-v8 H11）。第一个是最主要的（收着时只露它）。
/// Opens：「打开」类的（在资源管理器中显示、打开设置……）——点胶囊本身也执行第一个这种；撤销、取消、重试不算。
/// </summary>
internal sealed record NoticeAction(string Title, Action Run, bool Opens = false);

/// <summary>几种常用的按钮（PLAN-v8 H14）。</summary>
internal static class NoticeActions
{
    public static NoticeAction Reveal(string path) => new("在资源管理器中显示", () => RevealInExplorer(path), Opens: true);

    public static NoticeAction Open(string path) => new("打开", () => Launch(path), Opens: true);

    /// <summary>打开系统设置的某一页（ms-settings:…）。</summary>
    public static NoticeAction SystemSettings(string uri) => new("打开设置", () => Launch(uri), Opens: true);

    /// <summary>跳到本 App 设置的某一页。</summary>
    public static NoticeAction AppSettings(string page, string title = "打开设置")
        => new(title, () => ShellRuntime.Instance?.ShowSettings(welcome: false, page), Opens: true);

    public static void RevealInExplorer(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "/select,\"" + path + "\"",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"notice.reveal-failed {ex.GetType().Name}");
        }
    }

    private static void Launch(string target)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"notice.open-failed {ex.GetType().Name}");
            NoticeHost.Show("打不开", ex.GetType().Name, NoticeTone.Error);
        }
    }
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

    /// <summary>胶囊高度（DIP）。圆角等于高度一半；收起时缩成 36 × 36 的圆；展开的卡片圆角也是这么大。</summary>
    private const double PillHeight = 36;

    /// <summary>内容最宽（DIP），再长就省略。窗口一直这么宽。</summary>
    private const double MaxPillWidth = 460;

    /// <summary>展开的卡片最高：第一行 36 + 4 行详情 + 底下 10（mac「完整详情折在下面最多 4 行」）。</summary>
    private const double MaxCardHeight = 124;

    /// <summary>
    /// 窗口比胶囊左右多出来的透明边：island 弹簧最多冲过头约 8%（36 → 460 时每边多 17）加上抖动 7。
    /// 窗口是透明、平时点得穿的，宽一点不碍事。
    /// </summary>
    private const double PaddingX = 24;

    /// <summary>上下的透明边：胶囊顶边离工作区顶边正好 8（mac 菜单栏下方 8 pt）。</summary>
    private const double PaddingY = 8;

    private const double StageWidth = MaxPillWidth + PaddingX * 2;

    private const double StageHeight = MaxCardHeight + PaddingY * 2;

    private const double ProgressWidth = 56;

    /// <summary>内容刚换 / 刚展开这么久之内点胶囊不算（mac 0.3 s）。</summary>
    private const long ClickGraceMs = 300;

    private static NoticeHost? _current;

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _current is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_current._window);

    /// <summary>--ui-snapshots 用：不用鼠标，直接摆出悬停展开的样子（PLAN-v8 第 5 批）。</summary>
    internal static void ExpandForProbe() => _current?.HoverStart();

    /// <summary>--notice-anim-test 用：XAML 一共排了几次版（第 3 批验收「动画期间主线程没有每帧布局」）。</summary>
    internal static int LayoutPassesForProbe { get; private set; }

    private readonly Window _window;
    private readonly Grid _root;
    private readonly Grid _stage;
    private readonly Border _content;
    private readonly FontIcon _icon;
    private readonly Border _iconSlot;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly TextBlock _detailFull;
    private readonly StackPanel _buttons;
    private readonly Button _close;
    private readonly Border _progressTrack;
    private readonly Border _progressFill;
    private readonly HWND _hwnd;
    private readonly DispatcherQueueTimer _hideTimer;
    private readonly DispatcherQueueTimer _pointerTimer;
    private readonly Compositor _compositor;
    private readonly CompositionRoundedRectangleGeometry _shape;
    private readonly CompositionRoundedRectangleGeometry _clip;
    private readonly Visual _stageVisual;
    private readonly Visual _contentVisual;

    private bool _visible;
    private bool _hiding;
    private bool _progress;
    private double _width = PillHeight;
    private double _height = PillHeight;
    private int _generation;
    private IReadOnlyList<NoticeAction> _actions = Array.Empty<NoticeAction>();

    // 指针（H9 / H10）。
    private double _scale = 1;
    private System.Drawing.Point _cursorAtShow;
    private bool _pointerMoved;
    private bool _acceptsMouse;
    private bool _hovered;
    private long _contentChangedAt;
    private long _hideDeadline;
    private long _remainingMs;
    private (string Title, string Detail, NoticeTone Tone, double? Fraction, NoticeAction[] Actions)? _pending;

    private NoticeHost()
    {
        _icon = new FontIcon
        {
            FontSize = 12,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _iconSlot = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(11),
            VerticalAlignment = VerticalAlignment.Center,
            Child = _icon,
        };
        _title = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Theme.Argb(242, 255, 255, 255)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _progressFill = new Border
        {
            Width = ProgressWidth,
            Height = 4,
            CornerRadius = new CornerRadius(2),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        _progressTrack = new Border
        {
            Width = ProgressWidth,
            Height = 4,
            CornerRadius = new CornerRadius(2),
            Background = new SolidColorBrush(Theme.Argb(46, 255, 255, 255)),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            Child = _progressFill,
        };
        _detail = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Foreground = new SolidColorBrush(Theme.Argb(140, 255, 255, 255)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 420,
        };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(_title);
        titleRow.Children.Add(_progressTrack);
        var texts = new StackPanel { Spacing = 0, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(titleRow);
        texts.Children.Add(_detail);
        _buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0),
        };
        _close = MakeCloseButton();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, Height = PillHeight };
        row.Children.Add(_iconSlot);
        row.Children.Add(texts);
        row.Children.Add(_buttons);
        row.Children.Add(_close);

        // 展开后的完整详情：和标题左对齐（前导槽 22 + 间距 9），最多 4 行。
        _detailFull = new TextBlock
        {
            FontSize = 13,
            Foreground = new SolidColorBrush(Theme.Argb(140, 255, 255, 255)),
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 4,
            MaxWidth = MaxPillWidth - 30 - 31,
            Margin = new Thickness(31, 0, 0, 10),
            HorizontalAlignment = HorizontalAlignment.Left,
            Visibility = Visibility.Collapsed,
        };
        var layout = new StackPanel();
        layout.Children.Add(row);
        layout.Children.Add(_detailFull);

        // 内容按最终尺寸排在正中、顶边对齐形体；外面那层铺满整个窗口，clip 和黑底用同一组坐标。
        _content = new Border
        {
            MaxWidth = MaxPillWidth,
            Padding = new Thickness(14, 0, 16, 0),
            Margin = new Thickness(0, PaddingY, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Child = layout,
        };
        var clipLayer = new Grid();
        clipLayer.Children.Add(_content);
        var shapeHost = new Grid();
        _stage = new Grid { Width = StageWidth, Height = StageHeight };
        _stage.Children.Add(shapeHost);
        _stage.Children.Add(clipLayer);
        _stage.Tapped += OnTapped;

        _root = new Grid
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        _root.Children.Add(_stage);
        _root.LayoutUpdated += (_, _) => LayoutPassesForProbe++;
        // 读屏：轻提示是活区，出现时用 UIA 通知播报（讲述人 / NVDA 都认这一条）。
        AutomationProperties.SetLiveSetting(_root, AutomationLiveSetting.Polite);
        AutomationProperties.SetName(_root, Paths.ProductName + " 提示");

        // 唯一的动画源：一个圆角矩形。黑底画它，内容按它裁（§2.3「窗口尺寸一次定死，只让形状变形」）。
        _stageVisual = ElementCompositionPreview.GetElementVisual(_stage);
        _contentVisual = ElementCompositionPreview.GetElementVisual(_content);
        _compositor = _stageVisual.Compositor;
        ElementCompositionPreview.SetIsTranslationEnabled(_stage, true);
        _shape = _compositor.CreateRoundedRectangleGeometry();
        _shape.CornerRadius = new Vector2((float)(PillHeight / 2));
        var pill = _compositor.CreateSpriteShape(_shape);
        pill.FillBrush = _compositor.CreateColorBrush(Theme.Argb(235, 0, 0, 0));
        pill.StrokeBrush = _compositor.CreateColorBrush(Theme.Argb(31, 255, 255, 255));
        pill.StrokeThickness = 1;
        var shapeVisual = _compositor.CreateShapeVisual();
        shapeVisual.Size = new Vector2((float)StageWidth, (float)StageHeight);
        shapeVisual.Shapes.Add(pill);
        ElementCompositionPreview.SetElementChildVisual(shapeHost, shapeVisual);
        _clip = _compositor.CreateRoundedRectangleGeometry();
        _clip.CornerRadius = new Vector2((float)(PillHeight / 2));
        ElementCompositionPreview.GetElementVisual(clipLayer).Clip = _compositor.CreateGeometricClip(_clip);
        SetPill(PillHeight, PillHeight);

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

        // 把 DWM 的边框扩到整个客户区：客户区里没画东西的地方就是真透明，只剩中间那颗胶囊。
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
        _hideTimer.IsRepeating = false;
        _hideTimer.Tick += (_, _) => BeginHide();
        // 只在提示开着时跑；33 ms 看一次指针在不在形状上（H9）。
        _pointerTimer = _window.DispatcherQueue.CreateTimer();
        _pointerTimer.Interval = TimeSpan.FromMilliseconds(33);
        _pointerTimer.IsRepeating = true;
        _pointerTimer.Tick += (_, _) => TrackPointer();
    }

    public static void Show(string title, string detail, NoticeTone tone, params NoticeAction[] actions)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, tone, null, actions);
    }

    /// <summary>
    /// 进行中、报得出百分比（<paramref name="fraction"/> 0–1）：标题后面一条 56 × 4 的细进度条，详情照旧写百分比。
    /// 同一个标题再调就原地改（只动进度条和宽度），不重新出场、不播报；一直挂着，60 s 兜底。只在 UI 线程调。
    /// </summary>
    public static void ShowProgress(string title, string detail, double fraction, params NoticeAction[] actions)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, NoticeTone.Normal, fraction, actions);
    }

    private void ShowCore(string title, string detail, NoticeTone tone, double? fraction, NoticeAction[] actions)
    {
        var quiet = fraction is not null && _progress && _visible && !_hiding && _title.Text == title;
        // H13：鼠标在上面时来的新提示先排着（只留最新一条）；进行中那条的进度和结果原地换。
        if (_hovered && !_progress)
        {
            _pending = (title, detail, tone, fraction, actions);
            return;
        }

        _generation++;
        _pending = null;
        _progress = fraction is not null;
        _actions = actions;
        _title.Text = title;
        _detail.Text = detail;
        _detailFull.Text = detail;
        _progressTrack.Visibility = _progress ? Visibility.Visible : Visibility.Collapsed;
        ApplyTone(tone);
        if (fraction is { } value)
        {
            SetProgress(value, animate: quiet);
        }

        var dwell = _progress ? 60 : actions.Length > 0 ? 6.0 : tone == NoticeTone.Error ? 3.0
            : string.IsNullOrEmpty(detail) ? 1.4 : 2.0;
        var (width, height) = MeasureCard(_hovered);
        _contentChangedAt = Environment.TickCount64;

        if (!_visible)
        {
            // 从收着的样子长出来：先缩成 36 的圆、内容藏起来，再一起出场。
            SetPill(PillHeight, PillHeight);
            _stageVisual.StopAnimation("Opacity");
            _stageVisual.Opacity = 1f;
            PositionAtPointer();
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)SwShowNoActivate);
            PInvoke.DwmFlush();
            _visible = true;
            PInvoke.GetCursorPos(out _cursorAtShow);
            _pointerMoved = false;
            _pointerTimer.Start();
            Reveal(width, height);
        }
        else if (_hiding)
        {
            // 正在缩回又来了新的：从当前的样子接着长回去。
            _stageVisual.StopAnimation("Opacity");
            _stageVisual.Opacity = 1f;
            _pointerTimer.Start();
            Reveal(width, height);
        }
        else
        {
            // 原地换内容：只动尺寸，内容直接换。
            AnimatePill(width, height, MotionCurve.Island);
        }

        _hiding = false;
        if (tone == NoticeTone.Error)
        {
            Shake();
        }

        if (_hovered)
        {
            // 悬停着（进行中那条原地换了结果）：计时停着，离开时再走。
            _remainingMs = (long)(dwell * 1000);
        }
        else
        {
            StartHideTimer((long)(dwell * 1000));
        }

        if (!quiet)
        {
            Announce(title, detail);
        }
    }

    private void StartHideTimer(long milliseconds)
    {
        _hideTimer.Stop();
        _hideTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(1, milliseconds));
        _hideDeadline = Environment.TickCount64 + milliseconds;
        _hideTimer.Start();
    }

    /// <summary>
    /// 排好收着 / 展开的样子，量出形体要多大。展开：第一行露出全部按钮和 ×、详情折到下面最多 4 行，
    /// 至少和收着那一行一样宽（H10）。只在出现、换内容、悬停开合时排一次版。
    /// </summary>
    private (double Width, double Height) MeasureCard(bool expanded)
    {
        ApplyLayout(expanded: false);
        _content.Measure(new Windows.Foundation.Size(MaxPillWidth, double.PositiveInfinity));
        var collapsed = Math.Clamp(_content.DesiredSize.Width, PillHeight, MaxPillWidth);
        if (!expanded)
        {
            return (collapsed, PillHeight);
        }

        ApplyLayout(expanded: true);
        _content.Measure(new Windows.Foundation.Size(MaxPillWidth, double.PositiveInfinity));
        return (Math.Clamp(Math.Max(collapsed, _content.DesiredSize.Width), PillHeight, MaxPillWidth),
            Math.Clamp(_content.DesiredSize.Height, PillHeight, MaxCardHeight));
    }

    private void ApplyLayout(bool expanded)
    {
        var hasDetail = !string.IsNullOrEmpty(_detail.Text);
        _detail.Visibility = hasDetail && !expanded ? Visibility.Visible : Visibility.Collapsed;
        _detailFull.Visibility = hasDetail && expanded ? Visibility.Visible : Visibility.Collapsed;
        _close.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        _buttons.Children.Clear();
        if (_actions.Count == 0)
        {
            return;
        }

        // 收着时只露第一个（最主要的）；展开后全露出来，主按钮放最右、白底黑字（H11）。
        if (!expanded)
        {
            _buttons.Children.Add(MakeButton(_actions[0], primary: false));
            return;
        }

        for (var index = 1; index < _actions.Count; index++)
        {
            _buttons.Children.Add(MakeButton(_actions[index], primary: false));
        }

        _buttons.Children.Add(MakeButton(_actions[0], primary: true));
    }

    private Button MakeButton(NoticeAction action, bool primary)
    {
        var background = new SolidColorBrush(primary ? Microsoft.UI.Colors.White : Theme.Argb(41, 255, 255, 255));
        var foreground = new SolidColorBrush(primary ? Theme.Argb(242, 0, 0, 0) : Theme.Argb(242, 255, 255, 255));
        var button = new Button
        {
            Content = new TextBlock
            {
                Text = action.Title,
                FontSize = Theme.FontSize("Kitty.FontSize.Label"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = foreground,
            },
            Height = 24,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(0),
            Background = background,
            VerticalAlignment = VerticalAlignment.Center,
        };
        KeepLook(button, background, foreground);
        AutomationProperties.SetName(button, action.Title);
        button.Click += (_, _) => Run(action);
        return button;
    }

    private Button MakeCloseButton()
    {
        var background = new SolidColorBrush(Theme.Argb(41, 255, 255, 255));
        var foreground = new SolidColorBrush(Theme.Argb(242, 255, 255, 255));
        var button = new Button
        {
            Content = new FontIcon { Glyph = Glyphs.Close, FontSize = 8, Foreground = foreground },
            Width = 20,
            Height = 20,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(0),
            Background = background,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        KeepLook(button, background, foreground);
        AutomationProperties.SetName(button, "关闭提示");
        button.Click += (_, _) => BeginHide();
        return button;
    }

    /// <summary>
    /// 系统按钮的悬停 / 按下会换成浅灰底（主题资源），胶囊上要保持自己的颜色：用轻量样式把那几个资源盖掉；
    /// 按下缩到 0.96（H11）。
    /// </summary>
    private static void KeepLook(Button button, Brush background, Brush foreground)
    {
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        foreach (var key in new[] { "ButtonBackgroundPointerOver", "ButtonBackgroundPressed" })
        {
            button.Resources[key] = background;
        }

        foreach (var key in new[] { "ButtonForegroundPointerOver", "ButtonForegroundPressed" })
        {
            button.Resources[key] = foreground;
        }

        foreach (var key in new[] { "ButtonBorderBrushPointerOver", "ButtonBorderBrushPressed" })
        {
            button.Resources[key] = transparent;
        }

        void Press(float scale)
        {
            if (Motion.Reduced)
            {
                return;
            }

            var visual = ElementCompositionPreview.GetElementVisual(button);
            visual.CenterPoint = new Vector3((float)(button.ActualWidth / 2), (float)(button.ActualHeight / 2), 0);
            visual.Scale = new Vector3(scale, scale, 1);
        }

        button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => Press(0.96f)), true);
        button.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => Press(1f)), true);
        button.PointerExited += (_, _) => Press(1f);
    }

    /// <summary>点了按钮：执行，然后收起（按钮自己又弹了新提示的话不收，比如「撤销」之后的「已撤销」）。</summary>
    private void Run(NoticeAction action)
    {
        // 先当成不在悬停：按钮自己弹的新提示要马上换上，不能排队（H13 的队只给别处来的）。
        _hovered = false;
        _pending = null;
        var generation = _generation;
        try
        {
            action.Run();
        }
        catch (Exception ex)
        {
            Log.Warn($"notice.action-failed {ex.GetType().Name}");
        }

        if (generation == _generation)
        {
            BeginHide();
        }
    }

    /// <summary>点胶囊本身（不在按钮上）：只执行第一个「打开」类的按钮（H12）；刚换内容 / 刚展开 0.3 s 内不算。</summary>
    private void OnTapped(object sender, TappedRoutedEventArgs args)
    {
        if (IsInsideButton(args.OriginalSource as DependencyObject) ||
            Environment.TickCount64 - _contentChangedAt < ClickGraceMs)
        {
            return;
        }

        if (_actions.FirstOrDefault(action => action.Opens) is { } open)
        {
            args.Handled = true;
            Run(open);
        }
    }

    private static bool IsInsideButton(DependencyObject? element)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current is Button)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// H9 / H10：指针动过、落在画出来的形状上才接鼠标（去掉 WS_EX_TRANSPARENT），移出就加回去；
    /// 落上去算悬停（停住计时、展开），移出合回一行、接着走剩下的时间。
    /// </summary>
    private void TrackPointer()
    {
        if (!_visible || _hiding)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        if (!_pointerMoved)
        {
            // 提示冒在一动不动的指针下面不算悬停。
            if (cursor == _cursorAtShow)
            {
                return;
            }

            _pointerMoved = true;
        }

        var inside = ShapeContains(cursor);
        if (inside != _acceptsMouse)
        {
            SetAcceptsMouse(inside);
        }

        if (inside && !_hovered)
        {
            HoverStart();
        }
        else if (!inside && _hovered)
        {
            HoverEnd();
        }
    }

    /// <summary>形状在屏幕上的矩形（物理像素）。用的是目标尺寸，动画中途差几个像素不要紧。</summary>
    private bool ShapeContains(System.Drawing.Point cursor)
    {
        var origin = _window.AppWindow.Position;
        var left = origin.X + PillOffset(_width).X * _scale;
        var top = origin.Y + PaddingY * _scale;
        return cursor.X >= left && cursor.X < left + _width * _scale &&
               cursor.Y >= top && cursor.Y < top + _height * _scale;
    }

    private void SetAcceptsMouse(bool accepts)
    {
        _acceptsMouse = accepts;
        var style = GetWindowLong((IntPtr)_hwnd.Value, GwlExStyle);
        SetWindowLong(
            (IntPtr)_hwnd.Value,
            GwlExStyle,
            accepts ? style & ~WsExTransparent : style | WsExTransparent);
    }

    private void HoverStart()
    {
        _hovered = true;
        _hideTimer.Stop();
        _remainingMs = Math.Max(0, _hideDeadline - Environment.TickCount64);
        var (width, height) = MeasureCard(expanded: true);
        _contentChangedAt = Environment.TickCount64;
        AnimatePill(width, height, MotionCurve.Island);
    }

    private void HoverEnd()
    {
        _hovered = false;
        if (_pending is { } pending)
        {
            // 鼠标在上面时排着的那条：现在换上。
            _pending = null;
            ShowCore(pending.Title, pending.Detail, pending.Tone, pending.Fraction, pending.Actions);
            return;
        }

        var (width, height) = MeasureCard(expanded: false);
        _contentChangedAt = Environment.TickCount64;
        AnimatePill(width, height, MotionCurve.Retract);
        // 进行中的合回一行、继续挂着；别的接着走剩下的时间，至少 1.5 s。
        StartHideTimer(_progress ? 60_000 : Math.Max(1500, _remainingMs));
    }

    /// <summary>语气符号一律是「语气色圆底 + 符号」：信息 / 进行中用强调色（符号 OnAccent），警告橙、错误红（白符号）；胶囊永远深色，取 mac 的深色值。</summary>
    private void ApplyTone(NoticeTone tone)
    {
        var (glyph, plate, symbol) = tone switch
        {
            NoticeTone.Warning => (Glyphs.Warning, Theme.Argb(255, 255, 159, 10), Microsoft.UI.Colors.White),
            NoticeTone.Error => (Glyphs.Error, Theme.Argb(255, 255, 69, 58), Microsoft.UI.Colors.White),
            _ => (Glyphs.Info, Theme.AccentColor, Theme.OnAccentColor),
        };
        _icon.Glyph = glyph;
        _icon.Foreground = new SolidColorBrush(symbol);
        _iconSlot.Background = new SolidColorBrush(plate);
        _progressFill.Background = new SolidColorBrush(Theme.AccentColor);
    }

    /// <summary>形体长到目标尺寸，内容晚 60 ms 淡入、从 0.9 放大到 1（顶边锚点）。</summary>
    private void Reveal(double width, double height)
    {
        if (Motion.Reduced)
        {
            // 关了动画效果：形体直接到位，整颗 0.2 s 淡入。
            SetPill(width, height);
            _contentVisual.StopAnimation("Scale");
            _contentVisual.StopAnimation("Opacity");
            _contentVisual.Scale = Vector3.One;
            _contentVisual.Opacity = 1f;
            _stageVisual.Opacity = 0f;
            Fade(_stageVisual, 1f, MotionCurves.ReducedFadeSeconds, 0);
            return;
        }

        AnimatePill(width, height, MotionCurve.Island);
        _contentVisual.CenterPoint = new Vector3((float)(_content.DesiredSize.Width / 2), 0, 0);
        _contentVisual.Opacity = 0f;
        Fade(_contentVisual, 1f, 0.28, 60);
        var scale = _compositor.CreateVector3KeyFrameAnimation();
        scale.InsertKeyFrame(0f, new Vector3(0.9f, 0.9f, 1));
        scale.InsertKeyFrame(1f, Vector3.One);
        scale.Duration = TimeSpan.FromSeconds(0.28);
        scale.DelayTime = TimeSpan.FromMilliseconds(60);
        scale.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        _contentVisual.StartAnimation("Scale", scale);
    }

    /// <summary>停留时间到了：先退内容 0.12 s，0.08 s 后形体 retract 缩成 36 的圆、最后 0.12 s 淡掉，全部走完才收窗口。</summary>
    private void BeginHide()
    {
        _hideTimer.Stop();
        _hiding = true;
        _hovered = false;
        _pending = null;
        if (_acceptsMouse)
        {
            SetAcceptsMouse(false);
        }

        var generation = ++_generation;
        var batch = _compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        batch.Completed += (_, _) => _window.DispatcherQueue.TryEnqueue(() =>
        {
            // 中途又来了新的提示（generation 变了）就不收。
            if (generation == _generation)
            {
                HideNow();
            }
        });
        if (Motion.Reduced)
        {
            Fade(_stageVisual, 0f, MotionCurves.ReducedFadeSeconds, 0);
        }
        else
        {
            var retract = MotionCurves.Of(MotionCurve.Retract)?.Duration ?? 0.34;
            Fade(_contentVisual, 0f, 0.12, 0);
            AnimatePill(PillHeight, PillHeight, MotionCurve.Retract, delayMs: 80);
            Fade(_stageVisual, 0f, 0.12, (int)(80 + retract * 1000 - 120));
        }

        batch.End();
    }

    private void HideNow()
    {
        _hideTimer.Stop();
        _pointerTimer.Stop();
        _window.AppWindow.Hide();
        _visible = false;
        _hiding = false;
        _progress = false;
        _hovered = false;
        _actions = Array.Empty<NoticeAction>();
        _buttons.Children.Clear();
    }

    /// <summary>出错时整颗左右抖一下（mac 的岛：[0, −7, 6, −4, 2, 0]，0.4 s）；减弱动画时不做。</summary>
    private void Shake()
    {
        if (Motion.Reduced)
        {
            return;
        }

        var offsets = new[] { 0f, -7f, 6f, -4f, 2f, 0f };
        var shake = _compositor.CreateScalarKeyFrameAnimation();
        shake.Duration = TimeSpan.FromSeconds(0.4);
        for (var index = 0; index < offsets.Length; index++)
        {
            shake.InsertKeyFrame(index / (float)(offsets.Length - 1), offsets[index]);
        }

        _stageVisual.StartAnimation("Translation.X", shake);
    }

    /// <summary>细进度条：填充按比例横向缩放（左端锚点），0.2 s 线性跟着走；减弱动画时直接到位。</summary>
    private void SetProgress(double fraction, bool animate)
    {
        var visual = ElementCompositionPreview.GetElementVisual(_progressFill);
        visual.CenterPoint = Vector3.Zero;
        var value = (float)Math.Clamp(fraction, 0, 1);
        if (!animate || Motion.Reduced)
        {
            visual.StopAnimation("Scale.X");
            visual.Scale = new Vector3(value, 1, 1);
            return;
        }

        var move = _compositor.CreateScalarKeyFrameAnimation();
        move.InsertKeyFrame(1f, value, _compositor.CreateLinearEasingFunction());
        move.Duration = TimeSpan.FromSeconds(0.2);
        visual.StartAnimation("Scale.X", move);
    }

    /// <summary>不动画地把形体定在这个尺寸（两个几何一起）。</summary>
    private void SetPill(double width, double height)
    {
        foreach (var geometry in new[] { _shape, _clip })
        {
            geometry.StopAnimation("Size");
            geometry.StopAnimation("Offset");
            geometry.Size = PillSize(width, height);
            geometry.Offset = PillOffset(width);
        }

        _width = width;
        _height = height;
    }

    /// <summary>形体弹簧到这个尺寸，从当前的样子（this.StartingValue）接着走；中途再改也不跳。</summary>
    private void AnimatePill(double width, double height, MotionCurve curve, int delayMs = 0)
    {
        if (MotionCurves.Effective(curve, Motion.Reduced) is not { } spring)
        {
            SetPill(width, height);
            return;
        }

        if (Math.Abs(width - _width) < 0.5 && Math.Abs(height - _height) < 0.5)
        {
            return;
        }

        foreach (var geometry in new[] { _shape, _clip })
        {
            geometry.StartAnimation("Size", PillAnimation(PillSize(width, height), spring, delayMs));
            geometry.StartAnimation("Offset", PillAnimation(PillOffset(width), spring, delayMs));
        }

        _width = width;
        _height = height;
    }

    /// <summary>
    /// SpringEase（和 mac 同一组 duration / bounce）采样成关键帧（Motion.CurveTo）：起点用 this.StartingValue，
    /// 动画在合成器里跑，主线程每帧不做事。
    /// 不用表达式的 Lerp(start, target, p)：它把 p 夹在 [0, 1]，island 的回弹冲不过头
    /// （--notice-anim-test 量到最大宽 = 最后宽；改成 start + (target − start) × p 之后 36 → 110 → 104）。
    /// </summary>
    private Vector2KeyFrameAnimation PillAnimation(Vector2 target, SpringSpec spring, int delayMs)
    {
        var animation = Motion.CurveTo(_compositor, target, spring);
        if (delayMs > 0)
        {
            animation.DelayTime = TimeSpan.FromMilliseconds(delayMs);
        }

        return animation;
    }

    private static Vector2 PillSize(double width, double height) => new((float)width, (float)height);

    private static Vector2 PillOffset(double width) => new((float)((StageWidth - width) / 2), (float)PaddingY);

    private static void Fade(Visual visual, float to, double seconds, int delayMs)
    {
        var fade = visual.Compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(1f, to);
        fade.Duration = TimeSpan.FromSeconds(seconds);
        if (delayMs > 0)
        {
            fade.DelayTime = TimeSpan.FromMilliseconds(delayMs);
        }

        visual.StartAnimation("Opacity", fade);
    }

    private void Announce(string title, string detail)
    {
        try
        {
            var text = string.IsNullOrWhiteSpace(detail) ? title : $"{title}，{detail}";
            if (_actions.Count > 0)
            {
                text += "。可以" + string.Join("、", _actions.Select(action => action.Title));
            }

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

    /// <summary>窗口定死在最大尺寸，摆在鼠标所在屏的工作区顶部居中；胶囊顶边离工作区顶边 PaddingY。</summary>
    private void PositionAtPointer()
    {
        var display = Displays.AtCursor();
        _scale = display.Scale;
        var rect = MonitorLayout.Notice(display.Work, display.Scale, StageWidth, StageHeight, 0);
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
