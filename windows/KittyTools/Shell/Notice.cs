// 轻提示（mac 的「刘海岛」；Windows 上没有刘海，就是 mac 无刘海屏那颗胶囊，PLAN-v7 §3.4 / U4）：
// 鼠标所在屏、工作区顶部居中、胶囊顶边往下 8。纯黑 0.92 + white 0.12 发丝线，高 36。
// 窗口一次定死在最大宽（透明、点得穿），只让 Composition 里的圆角矩形几何变形（§2.3）：黑底（ShapeVisual）
// 和裁内容的 clip 走同一组尺寸，内容按最终宽度一次排好、被形体裁出来，动画期间主线程不排版。
// 长出来：36 → 实际宽度（island 弹簧）；内容晚 60 ms 淡入、从 0.9 放大到 1（顶边锚点）。原地换内容只动宽度；
// 出错整颗左右抖 [0, −7, 6, −4, 2, 0] 0.4 s；消失先退内容 0.12 s，0.08 s 后形体 retract 缩回再收窗口。
// 系统关了动画效果时：形体直接到位，只做 0.2 s 的淡入淡出。
// 报得出百分比的（下载更新、转 GIF、压缩）走 ShowProgress：标题后面一条 56 × 4 的细进度条，原地改、不重新出场、不播报。
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

    /// <summary>胶囊高度（DIP）。圆角等于高度一半；收起时缩成 36 × 36 的圆。</summary>
    private const double PillHeight = 36;

    /// <summary>内容最宽（DIP），再长就省略。窗口一直这么宽。</summary>
    private const double MaxPillWidth = 460;

    /// <summary>
    /// 窗口比胶囊左右多出来的透明边：island 弹簧最多冲过头约 8%（36 → 460 时每边多 17）加上抖动 7。
    /// 窗口是透明、点得穿的，宽一点不碍事。
    /// </summary>
    private const double PaddingX = 24;

    /// <summary>上下的透明边：胶囊顶边离工作区顶边正好 8（mac 菜单栏下方 8 pt）。</summary>
    private const double PaddingY = 8;

    private const double StageWidth = MaxPillWidth + PaddingX * 2;

    private const double StageHeight = PillHeight + PaddingY * 2;

    private const double ProgressWidth = 56;

    private static NoticeHost? _current;

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _current is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_current._window);

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
    private readonly Border _progressTrack;
    private readonly Border _progressFill;
    private readonly HWND _hwnd;
    private readonly DispatcherQueueTimer _hideTimer;
    private readonly Compositor _compositor;
    private readonly CompositionRoundedRectangleGeometry _shape;
    private readonly CompositionRoundedRectangleGeometry _clip;
    private readonly Visual _stageVisual;
    private readonly Visual _contentVisual;

    private bool _visible;
    private bool _hiding;
    private bool _progress;
    private double _width = PillHeight;
    private int _generation;

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
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9 };
        row.Children.Add(_iconSlot);
        row.Children.Add(texts);

        // 内容按最终宽度排在正中；外面那层铺满整个窗口，clip 和黑底用同一组坐标。
        _content = new Border
        {
            Height = PillHeight,
            MaxWidth = MaxPillWidth,
            Padding = new Thickness(14, 0, 16, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = row,
        };
        var clipLayer = new Grid();
        clipLayer.Children.Add(_content);
        var shapeHost = new Grid();
        _stage = new Grid { Width = StageWidth, Height = StageHeight };
        _stage.Children.Add(shapeHost);
        _stage.Children.Add(clipLayer);

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
        SetPill(PillHeight);

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
    }

    public static void Show(string title, string detail, NoticeTone tone)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, tone, null);
    }

    /// <summary>
    /// 进行中、报得出百分比（<paramref name="fraction"/> 0–1）：标题后面一条 56 × 4 的细进度条，详情照旧写百分比。
    /// 同一个标题再调就原地改（只动进度条和宽度），不重新出场、不播报；一直挂着，60 s 兜底。只在 UI 线程调。
    /// </summary>
    public static void ShowProgress(string title, string detail, double fraction)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, NoticeTone.Normal, fraction);
    }

    private void ShowCore(string title, string detail, NoticeTone tone, double? fraction)
    {
        _generation++;
        var quiet = fraction is not null && _progress && _visible && !_hiding && _title.Text == title;
        _progress = fraction is not null;
        _title.Text = title;
        _detail.Text = detail;
        _detail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
        _progressTrack.Visibility = _progress ? Visibility.Visible : Visibility.Collapsed;
        ApplyTone(tone);
        if (fraction is { } value)
        {
            SetProgress(value, animate: quiet);
        }

        _hideTimer.Interval = TimeSpan.FromSeconds(
            _progress ? 60 : tone == NoticeTone.Error ? 3.0 : string.IsNullOrEmpty(detail) ? 1.4 : 2.0);
        var target = MeasurePillWidth();

        if (!_visible)
        {
            // 从收着的样子长出来：先缩成 36 的圆、内容藏起来，再一起出场。
            SetPill(PillHeight);
            _stageVisual.StopAnimation("Opacity");
            _stageVisual.Opacity = 1f;
            PositionAtPointer();
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)SwShowNoActivate);
            PInvoke.DwmFlush();
            _visible = true;
            Reveal(target);
        }
        else if (_hiding)
        {
            // 正在缩回又来了新的：从当前的样子接着长回去。
            _stageVisual.StopAnimation("Opacity");
            _stageVisual.Opacity = 1f;
            Reveal(target);
        }
        else
        {
            // 原地换内容：只动宽度，内容直接换。
            AnimatePill(target, MotionCurve.Island);
        }

        _hiding = false;
        if (tone == NoticeTone.Error)
        {
            Shake();
        }

        _hideTimer.Stop();
        _hideTimer.Start();
        if (!quiet)
        {
            Announce(title, detail);
        }
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

    /// <summary>形体长到 <paramref name="target"/>，内容晚 60 ms 淡入、从 0.9 放大到 1（顶边锚点）。</summary>
    private void Reveal(double target)
    {
        if (Motion.Reduced)
        {
            // 关了动画效果：形体直接到位，整颗 0.2 s 淡入。
            SetPill(target);
            _contentVisual.StopAnimation("Scale");
            _contentVisual.StopAnimation("Opacity");
            _contentVisual.Scale = Vector3.One;
            _contentVisual.Opacity = 1f;
            _stageVisual.Opacity = 0f;
            Fade(_stageVisual, 1f, MotionCurves.ReducedFadeSeconds, 0);
            return;
        }

        AnimatePill(target, MotionCurve.Island);
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
            AnimatePill(PillHeight, MotionCurve.Retract, delayMs: 80);
            Fade(_stageVisual, 0f, 0.12, (int)(80 + retract * 1000 - 120));
        }

        batch.End();
    }

    private void HideNow()
    {
        _hideTimer.Stop();
        _window.AppWindow.Hide();
        _visible = false;
        _hiding = false;
        _progress = false;
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

    /// <summary>不动画地把形体定在这个宽度（两个几何一起）。</summary>
    private void SetPill(double width)
    {
        foreach (var geometry in new[] { _shape, _clip })
        {
            geometry.StopAnimation("Size");
            geometry.StopAnimation("Offset");
            geometry.Size = PillSize(width);
            geometry.Offset = PillOffset(width);
        }

        _width = width;
    }

    /// <summary>形体弹簧到这个宽度，从当前的样子（this.StartingValue）接着走；中途再改也不跳。</summary>
    private void AnimatePill(double width, MotionCurve curve, int delayMs = 0)
    {
        if (MotionCurves.Effective(curve, Motion.Reduced) is not { } spring)
        {
            SetPill(width);
            return;
        }

        if (Math.Abs(width - _width) < 0.5)
        {
            return;
        }

        foreach (var geometry in new[] { _shape, _clip })
        {
            geometry.StartAnimation("Size", PillAnimation(PillSize(width), spring, delayMs));
            geometry.StartAnimation("Offset", PillAnimation(PillOffset(width), spring, delayMs));
        }

        _width = width;
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

    private static Vector2 PillSize(double width) => new((float)width, (float)PillHeight);

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

    /// <summary>按内容量一遍胶囊要多宽（标题 / 详情不折行，超过上限就省略）。只在出现 / 换内容时排一次版。</summary>
    private double MeasurePillWidth()
    {
        _content.Measure(new Windows.Foundation.Size(MaxPillWidth, PillHeight));
        return Math.Clamp(_content.DesiredSize.Width, PillHeight, MaxPillWidth);
    }

    /// <summary>窗口定死在最大宽，摆在鼠标所在屏的工作区顶部居中；胶囊顶边离工作区顶边 PaddingY。</summary>
    private void PositionAtPointer()
    {
        var display = Displays.AtCursor();
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
