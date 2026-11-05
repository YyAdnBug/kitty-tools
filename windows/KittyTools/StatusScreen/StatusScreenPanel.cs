// 状态屏每块显示器上的那几扇窗（PLAN-v12 N5，mac StatusScreenView.swift 的 StatusScreenPanel 在 Windows 上的做法）：
// - 熄屏 / 告示：一扇盖满整块屏（含任务栏）的不透明黑窗，告示那一列、退出提示、密码框、眼睛都在里面。
// - 透出：一扇 Win32 分层压暗层（黑、整体透明度 0.68，后面的窗口看得见），上面一扇 HUD 小窗放那一列（底板）、一扇放退出提示 / 密码框。
//   不用透明的 WinUI 窗口：透明那层在用户机器上是白的（0cc29cf7 删掉 TransparentBackdrop 的原因）；分层窗口同截图「都不要」的那一闪。
//   透出不冒眼睛（眼睛的图有透明边，单独一扇窗画不出来）。
// 都置顶、不进 Alt+Tab；鼠标所在那块屏的黑窗拿前台（全屏的前台窗口会把任务栏压下去），会话每秒把它们再提到最上面一次。
// 先隐身（DWM cloak）再露面，画上几帧再显形：不然一露面先白一块（同轻提示 fb6e2539）。窗口退场不淡出（PLAN-v7 §1）。
// 键盘鼠标由 InputBlock 吞掉，这些窗口自己收不到输入；鼠标按住退出提示由会话按钩子给的坐标自己算（HintHitRect）。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal sealed unsafe partial class StatusScreenPanel
{
    private const string ScrimClass = "KittyTools.StatusScrim";
    private const uint WsPopup = 0x80000000;
    private const uint ScrimExStyle = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ |
                                      0x08000000 /* NOACTIVATE */ | 0x00080000 /* LAYERED */;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> ScrimProcPtr = &ScrimProc;
    private static bool _scrimRegistered;

    private readonly StatusPreset _preset;
    private readonly bool _animates;
    private readonly bool _hasPasscode;
    private readonly double _width;
    private readonly double _height;
    private readonly double _title;

    // 熄屏 / 告示
    private Window? _surface;
    private Grid? _surfaceRoot;
    private Canvas? _overlay;

    // 透出
    private IntPtr _scrim;
    private Window? _plate;
    private Border? _plateContent;
    private Window? _capsuleWindow;

    private StatusScreenView.Column? _column;
    private Border? _hint;
    private ProgressRing? _ring;
    private Storyboard? _ringStory;
    private bool _ringHeld;
    private Border? _passcode;
    private TextBlock? _passcodeLabel;
    private StackPanel? _dots;
    private int _shownMisses;
    private FrameworkElement? _eyes;
    private (double X, double Y) _drift;
    private bool _hintShown;
    private bool _passcodeShown;
    private bool _closed;

    /// <summary>露着的那双眼睛从哪条边探出来（收回去往那边退）。不挂在 Tag 上：C# 的枚举装进 WinRT 的 object 在 AOT 下没把握。</summary>
    private PeekEdge _eyesEdge;

    public StatusScreenPanel(PixelBounds bounds, double scale, StatusPreset preset, bool animates, bool hasPasscode)
    {
        _hasPasscode = hasPasscode;
        Bounds = bounds;
        Scale = scale <= 0 ? 1 : scale;
        _preset = preset;
        _animates = animates;
        _width = bounds.Width / Scale;
        _height = bounds.Height / Scale;
        _title = StatusScreenRules.TitleSize(_height);
    }

    public PixelBounds Bounds { get; }

    public double Scale { get; }

    /// <summary>鼠标按住退出提示的命中范围（物理像素）：提示外扩 8 DIP。</summary>
    public PixelRect HintHit => StatusScreenRules.HintHitRect(new PixelRect(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height), Scale);

    /// <summary>这块屏上我们自己的 WinUI 窗（自检截图只截它们）。</summary>
    public IEnumerable<IntPtr> Handles
        => new[] { Handle(_surface), Handle(_plate), _hintShown || _passcodeShown ? Handle(_capsuleWindow) : IntPtr.Zero }
            .Where(hwnd => hwnd != IntPtr.Zero);

    public bool Contains(int x, int y) => x >= Bounds.Left && x < Bounds.Right && y >= Bounds.Top && y < Bounds.Bottom;

    /// <summary>
    /// 摆出来。key：鼠标所在的那块（拿前台）。footer：小字的第一版。
    /// 建不出来抛出去，会话按「进不去」处理（拦截已经撤了才会抛到用户那里——见 StatusScreenHost.Enter）。
    /// </summary>
    public void Present(bool key, string footer)
    {
        if (_preset.Style == StatusPresets.Dim)
        {
            PresentDim(footer);
        }
        else
        {
            PresentSurface(key, footer);
        }
    }

    private void PresentSurface(bool key, string footer)
    {
        var window = BareWindow(frame: false);
        _surface = window;
        _surfaceRoot = new Grid
        {
            Background = new SolidColorBrush(Colors.Black),
            RequestedTheme = ElementTheme.Dark,
        };
        if (_preset.Style == StatusPresets.Sign)
        {
            var column = StatusScreenView.BuildColumn(_preset, _title, _width * 0.8, _animates, footer);
            _column = column;
            _surfaceRoot.Children.Add(column.Root);
        }

        _overlay = new Canvas();
        _surfaceRoot.Children.Add(_overlay);
        AutomationProperties.SetName(_surfaceRoot, AccessibleName());
        window.Content = _surfaceRoot;
        window.AppWindow.MoveAndResize(new RectInt32(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height));
        var hwnd = Handle(window);
        FitClientToBounds(hwnd);
        RevealWhenDrawn(window, hwnd, key, () => _closed);
        if (_column is not null && _animates)
        {
            PlayEntrance(_column);
        }
    }

    private void PresentDim(string footer)
    {
        _scrim = CreateScrim(Bounds, StatusScreenView.ScrimAlpha(HighContrast()));
        var column = StatusScreenView.BuildColumn(_preset, _title, _width * 0.8, _animates, footer);
        _column = column;
        column.Root.HorizontalAlignment = HorizontalAlignment.Left;
        column.Root.VerticalAlignment = VerticalAlignment.Top;
        _plateContent = new Border
        {
            Background = new SolidColorBrush(StatusScreenView.HudFill),
            Padding = StatusScreenView.PlatePadding(_title),
            RequestedTheme = ElementTheme.Dark,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Child = column.Root,
        };
        AutomationProperties.SetName(_plateContent, AccessibleName());
        var plate = BareWindow(frame: true);
        _plate = plate;
        plate.Content = _plateContent;
        // 先按最大可能摆好、隐身着画一遍，量出那一列多大再摆到正中。
        plate.AppWindow.MoveAndResize(new RectInt32(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height / 2));
        _plateContent.Loaded += (_, _) =>
        {
            PlacePlate();
            if (_animates)
            {
                PlayEntrance(column);
            }
        };
        RevealWhenDrawn(plate, Handle(plate), false, () => _closed);
    }

    /// <summary>透出：底板那扇窗按那一列量出来的大小摆到正中（再加上防残影的挪动）。</summary>
    private void PlacePlate()
    {
        if (_plate is null || _plateContent is null || _closed)
        {
            return;
        }

        _plateContent.Measure(new Windows.Foundation.Size(_width * 0.8 + _title * 1.4, double.PositiveInfinity));
        var size = _plateContent.DesiredSize;
        var width = MonitorLayout.Pixels(size.Width, Scale);
        var height = MonitorLayout.Pixels(size.Height, Scale);
        var x = Bounds.Left + (Bounds.Width - width) / 2 + (int)Math.Round(_drift.X * Scale);
        var y = Bounds.Top + (Bounds.Height - height) / 2 + (int)Math.Round(_drift.Y * Scale);
        _plate.AppWindow.MoveAndResize(HudFrame.WithFrame(_plate, new RectInt32(x, y, width, height)));
    }

    private void PlayEntrance(StatusScreenView.Column column) => StatusScreenView.PlayEntrance(column, _animates);

    /// <summary>读屏读的整屏名字：「状态屏，标题，说明，按住 Esc 两秒退出」。</summary>
    private string AccessibleName()
        => string.Join("，", new[] { "状态屏", _preset.Title, _preset.Detail }.Where(part => !string.IsNullOrEmpty(part))) +
           "，" + StatusScreenRules.ExitWording(_hasPasscode);

    /// <summary>进入时读一遍（mac Island.announce）。</summary>
    public void Announce(string text)
    {
        var element = (FrameworkElement?)_surfaceRoot ?? _plateContent;
        if (element is null)
        {
            return;
        }

        try
        {
            var peer = FrameworkElementAutomationPeer.FromElement(element) ?? FrameworkElementAutomationPeer.CreatePeerForElement(element);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "kitty-status-screen");
        }
        catch (Exception ex)
        {
            Log.Warn($"status.announce-failed {ex.GetType().Name}");
        }
    }

    // ---- 会话每一拍 / 每次触碰调的

    public void SetFooter(string text)
    {
        if (_column is not null)
        {
            _column.Footer.Text = text;
        }
    }

    /// <summary>防残影：告示那一列挪到第几分钟该在的位置（settle；减弱动态效果时直接换）。</summary>
    public void SetDrift((double X, double Y) drift)
    {
        _drift = drift;
        if (_column is null)
        {
            return;
        }

        if (_plate is not null)
        {
            PlacePlate();
        }
        else
        {
            Motion.SlideTo(_column.Root, drift.X, drift.Y, MotionCurve.Settle);
        }
    }

    /// <summary>挡下一次触碰：标题晃一下，动画开着时表情甩一下。</summary>
    public void Shake()
    {
        if (_column is null)
        {
            return;
        }

        Motion.Shake(_column.Title);
        if (_animates && _column.Emoji is { } emoji)
        {
            Motion.Swing(emoji);
        }
    }

    /// <summary>每秒把这几扇窗再提到最上面（任务栏、别的置顶窗口会自己往上冒）。</summary>
    public void RaiseAll()
    {
        foreach (var hwnd in new[] { Handle(_surface), _scrim, Handle(_plate), _hintShown || _passcodeShown ? Handle(_capsuleWindow) : IntPtr.Zero })
        {
            if (hwnd != IntPtr.Zero)
            {
                RaiseTopmost(hwnd);
            }
        }
    }

    /// <summary>退出提示浮出 / 收起；holding：进度环 2 秒线性走满（取消就回到 0）。</summary>
    public void SetHint(bool shown, bool holding)
    {
        if (shown && _hint is null)
        {
            var (content, ring) = StatusScreenView.HintContent();
            _ring = ring;
            _hint = HostCapsule(content, StatusScreenRules.HintWidth);
        }

        if (_hint is not null && shown != _hintShown)
        {
            _hintShown = shown;
            ShowCapsule(_hint, shown, StatusScreenRules.HintWidth);
        }

        // 进度环只在「按住」开始 / 结束时动：会话每次刷新都会调到这里，别把走到一半的环拉回 0。
        if (_ring is null || holding == _ringHeld)
        {
            return;
        }

        _ringHeld = holding;
        _ringStory?.Stop();
        _ringStory = null;
        if (!holding)
        {
            _ring.Value = 0;
            return;
        }

        var animation = new DoubleAnimation
        {
            From = 0,
            To = 100,
            Duration = new Duration(TimeSpan.FromMilliseconds(ExitHold.DurationMs)),
            EnableDependentAnimation = true,
        };
        Storyboard.SetTarget(animation, _ring);
        Storyboard.SetTargetProperty(animation, "Value");
        _ringStory = new Storyboard();
        _ringStory.Children.Add(animation);
        _ringStory.Begin();
    }

    /// <summary>密码框：passcode 为 null 时收起；开着时按输到哪画圆点，又错了一次就晃一下。</summary>
    public void SetPasscode(Passcode? passcode)
    {
        if (passcode is null)
        {
            if (_passcode is not null && _passcodeShown)
            {
                _passcodeShown = false;
                ShowCapsule(_passcode, false, StatusScreenView.PasscodeWidth(_dots?.Children.Count ?? 4));
            }

            return;
        }

        var width = StatusScreenView.PasscodeWidth(passcode.Length);
        if (_passcode is null)
        {
            var (content, label, dots) = StatusScreenView.PasscodeContent(passcode.Length);
            _passcodeLabel = label;
            _dots = dots;
            _passcode = HostCapsule(content, width);
            _shownMisses = passcode.Misses;
        }

        StatusScreenView.ShowTyped(_dots!, _passcodeLabel!, passcode);
        if (passcode.Misses != _shownMisses)
        {
            _shownMisses = passcode.Misses;
            Motion.Shake(_dots!);
        }

        if (!_passcodeShown)
        {
            _passcodeShown = true;
            ShowCapsule(_passcode, true, width);
        }
    }

    /// <summary>
    /// 胶囊（退出提示、密码框）放哪：熄屏 / 告示放进整屏黑窗的底部正中；透出放进一扇 HUD 小窗（同一时刻只有一样，共用这扇窗）。
    /// </summary>
    private Border HostCapsule(UIElement content, double width)
    {
        var capsule = StatusScreenView.Capsule(content, width);
        capsule.Visibility = Visibility.Collapsed;
        if (_overlay is not null)
        {
            Canvas.SetLeft(capsule, (_width - width) / 2);
            Canvas.SetTop(capsule, _height - StatusScreenRules.HintBottom - StatusScreenRules.HintHeight);
            _overlay.Children.Add(capsule);
        }

        return capsule;
    }

    private void ShowCapsule(Border capsule, bool shown, double width)
    {
        if (_overlay is not null)
        {
            capsule.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
            if (shown)
            {
                Motion.Entrance(capsule, MotionCurve.Glide, rise: 8);
            }

            return;
        }

        // 透出：一扇 HUD 小窗，内容换成这一个胶囊（外壳由 DWM 画，胶囊自己的底和圆角去掉）。
        if (!shown)
        {
            if (!_hintShown && !_passcodeShown)
            {
                _capsuleWindow?.AppWindow.Hide();
            }

            return;
        }

        if (_capsuleWindow is null)
        {
            _capsuleWindow = BareWindow(frame: true);
            _capsuleWindow.Content = new Grid { Background = new SolidColorBrush(StatusScreenView.HudFill), RequestedTheme = ElementTheme.Dark };
        }

        var grid = (Grid)_capsuleWindow.Content;
        if (capsule.Parent is Panel parent && !ReferenceEquals(parent, grid))
        {
            parent.Children.Remove(capsule);
        }

        grid.Children.Clear();
        capsule.Visibility = Visibility.Visible;
        capsule.Background = null;
        capsule.BorderThickness = new Thickness(0);
        grid.Children.Add(capsule);
        var rect = StatusScreenRules.HintRect(new PixelRect(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height), Scale, width);
        _capsuleWindow.AppWindow.MoveAndResize(HudFrame.WithFrame(_capsuleWindow, new RectInt32(rect.X, rect.Y, rect.Width, rect.Height)));
        _capsuleWindow.AppWindow.Show(false);
        RaiseAll();
        Motion.Entrance(capsule, MotionCurve.Glide, rise: 8);
    }

    /// <summary>眼睛（只在告示样式上）：从 peek 那条边探出来；null = 缩回去。</summary>
    public void SetPeek(Peek? peek)
    {
        if (_overlay is null)
        {
            return;
        }

        if (peek is null)
        {
            if (_eyes is not { } leaving)
            {
                return;
            }

            _eyes = null;
            var (outX, outY) = StatusScreenRules.Outward(_eyesEdge, _title);
            Motion.SlideTo(leaving, outX, outY, MotionCurve.Retract);
            var timer = DispatcherQueueTimer(450);
            timer.Tick += (sender, _) =>
            {
                sender.Stop();
                _overlay?.Children.Remove(leaving);
            };
            timer.Start();
            return;
        }

        if (_eyes is not null)
        {
            return;
        }

        var side = _title;
        var eyes = StatusEmoji.Create(StatusEmojiCatalog.Eyes, side, animated: true);
        _eyesEdge = peek.Value.Edge;
        eyes.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
        eyes.RenderTransform = new RotateTransform { Angle = StatusScreenRules.EyesDegrees(peek.Value.Edge) };
        var (x, y) = StatusScreenRules.EyesOrigin(_width, _height, side, peek.Value);
        Canvas.SetLeft(eyes, x);
        Canvas.SetTop(eyes, y);
        // 垫在退出提示下面：提示浮出来压在它上面。
        _overlay.Children.Insert(0, eyes);
        _eyes = eyes;
        var (dx, dy) = StatusScreenRules.Outward(peek.Value.Edge, side);
        Motion.SlideFrom(eyes, dx, dy, MotionCurve.Island);
    }

    // ---- 锁屏 / 退出

    /// <summary>锁屏：都收起来（层级很高，别盖住锁屏界面）。解锁会话就结束了，不再露出来。</summary>
    public void Hide()
    {
        _surface?.AppWindow.Hide();
        _plate?.AppWindow.Hide();
        _capsuleWindow?.AppWindow.Hide();
        if (_scrim != IntPtr.Zero)
        {
            ShowWindow(_scrim, 0 /* SW_HIDE */);
        }
    }

    /// <summary>退出：当场关掉（窗口退场不淡出）。</summary>
    public void Close()
    {
        if (_closed)
        {
            return;
        }

        _closed = true;
        _ringStory?.Stop();
        foreach (var window in new[] { _surface, _plate, _capsuleWindow })
        {
            try
            {
                window?.Close();
            }
            catch
            {
                // 已经关了。
            }
        }

        _surface = _plate = _capsuleWindow = null;
        if (_scrim != IntPtr.Zero)
        {
            DestroyWindow(_scrim);
            _scrim = IntPtr.Zero;
        }
    }

    // ---- 窗口

    /// <summary>
    /// 一扇状态屏用的 WinUI 窗：置顶、不进 Alt+Tab、不能改大小。frame = false 是整屏黑窗（没边框、不圆角）；
    /// true 是 HUD 小窗（系统的细边框和 8 圆角、不抢焦点，HudFrame）。Alt+F4 这类系统入口关不掉（键盘本来也被拦着）。
    /// </summary>
    private Window BareWindow(bool frame)
    {
        var window = new Window { Title = "状态屏" };
        if (frame)
        {
            HudFrame.Apply(window);
        }
        else
        {
            window.AppWindow.IsShownInSwitchers = false;
            var presenter = OverlappedPresenter.Create();
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(false, false);
            window.AppWindow.SetPresenter(presenter);
            window.ExtendsContentIntoTitleBar = true;
            var square = 1; // DWMWCP_DONOTROUND：盖满整块屏，角上不留圆
            DwmSetWindowAttribute(Handle(window), 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &square, sizeof(int));
        }

        window.AppWindow.Closing += (_, args) => args.Cancel = !_closed;
        return window;
    }

    private static IntPtr Handle(Window? window) => window is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(window);

    /// <summary>
    /// 没边框的 WinUI 窗还留一圈看不见的缩放边（第 0 批 e4e1d9cd 实测约 3 px；截图遮罩 SelectionOverlayWindow.FixClientArea 同样补）：
    /// 不补的话熄屏 / 告示四边漏出桌面、底部提示的命中范围（按屏幕算）和画出来的错几个像素。按客户区比窗口小多少往外扩。
    /// </summary>
    private void FitClientToBounds(IntPtr hwnd)
    {
        WinRect window;
        WinRect client;
        var origin = default(WinPoint);
        if (!GetWindowRect(hwnd, &window) || !GetClientRect(hwnd, &client) || !ClientToScreen(hwnd, &origin))
        {
            return;
        }

        SetWindowPos(
            hwnd, new IntPtr(-1) /* HWND_TOPMOST */, Bounds.Left - (origin.X - window.Left), Bounds.Top - (origin.Y - window.Top),
            Bounds.Width + (window.Right - window.Left) - client.Right, Bounds.Height + (window.Bottom - window.Top) - client.Bottom,
            0x0010 /* SWP_NOACTIVATE */);
    }

    /// <summary>
    /// 先隐身再露面，画上第一帧、再过 4 次合成且 ≥ 50 ms 才显形（最多藏 300 ms）：同轻提示 Reveal 的做法，不然一露面先白一块。
    /// activate：拿前台（全屏的前台窗口会把任务栏压下去）。closed：窗口已经被关了（关了就不再显形）。提醒的全屏底板也用它。
    /// </summary>
    internal static void RevealWhenDrawn(Window window, IntPtr hwnd, bool activate, Func<bool> closed)
    {
        var cloak = 1;
        DwmSetWindowAttribute(hwnd, 13 /* DWMWA_CLOAK */, &cloak, sizeof(int));
        window.AppWindow.Show(activate);
        if (activate)
        {
            Foreground.Restore((HWND)hwnd);
        }

        RaiseTopmost(hwnd);
        var frames = 0;
        var started = Environment.TickCount64;
        var fallback = DispatcherQueueTimer(300);
        void Uncloak()
        {
            CompositionTarget.Rendering -= OnRendering;
            fallback.Stop();
            if (closed())
            {
                return;
            }

            var visible = 0;
            DwmSetWindowAttribute(hwnd, 13, &visible, sizeof(int));
        }

        void OnRendering(object? sender, object args)
        {
            if (++frames >= 4 && Environment.TickCount64 - started >= 50)
            {
                Uncloak();
            }
        }

        CompositionTarget.Rendering += OnRendering;
        fallback.Tick += (_, _) => Uncloak();
        fallback.Start();
    }

    /// <summary>提到置顶那一层的最上面（不挪、不改大小、不激活）。</summary>
    private static void RaiseTopmost(IntPtr hwnd)
        => SetWindowPos(hwnd, new IntPtr(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 /* NOSIZE | NOMOVE | NOACTIVATE */);

    private static Microsoft.UI.Dispatching.DispatcherQueueTimer DispatcherQueueTimer(int milliseconds)
    {
        var timer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds);
        timer.IsRepeating = false;
        return timer;
    }

    /// <summary>
    /// 透出样式的压暗层：一扇黑底的分层弹出窗，整体透明度 alpha，盖满整块屏（同 ShotFlash 的做法）。建不出来抛异常。
    /// 提醒的全屏（ReminderScreen）也用它；关掉用 DestroyScrim。
    /// </summary>
    internal static IntPtr CreateScrim(PixelBounds bounds, byte alpha)
    {
        EnsureScrimClass();
        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        var hwnd = (IntPtr)Native.CreateWindowEx(
            ScrimExStyle, ScrimClass, "状态屏", WsPopup, bounds.Left, bounds.Top, bounds.Width, bounds.Height,
            default, IntPtr.Zero, new HINSTANCE(module.Value), (void*)0).Value;
        if (hwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException($"状态屏压暗层没建起来（{Marshal.GetLastWin32Error()}）");
        }

        SetLayeredWindowAttributes(hwnd, 0, alpha, 0x2 /* LWA_ALPHA */);
        ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
        return hwnd;
    }

    private static void EnsureScrimClass()
    {
        if (_scrimRegistered)
        {
            return;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = ScrimProcPtr,
            hInstance = new HINSTANCE(module.Value),
            // 黑画刷整个进程只建这一个，不释放。
            hbrBackground = new Windows.Win32.Graphics.Gdi.HBRUSH(CreateSolidBrush(0x00000000)),
        };
        fixed (char* className = ScrimClass)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                throw new InvalidOperationException($"状态屏压暗层的窗口类没注册上（{Marshal.GetLastWin32Error()}）");
            }
        }

        _scrimRegistered = true;
    }

    internal static void DestroyScrim(IntPtr hwnd)
    {
        if (hwnd != IntPtr.Zero)
        {
            DestroyWindow(hwnd);
        }
    }

    internal static void RaiseWindow(IntPtr hwnd) => RaiseTopmost(hwnd);

    internal static bool HighContrast()
    {
        try
        {
            return new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        }
        catch
        {
            return false;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT ScrimProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
        => PInvoke.DefWindowProc(hwnd, msg, wParam, lParam);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateSolidBrush(uint color);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, WinRect* rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetClientRect(IntPtr hwnd, WinRect* rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ClientToScreen(IntPtr hwnd, WinPoint* point);

    [StructLayout(LayoutKind.Sequential)]
    private struct WinRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinPoint
    {
        public int X;
        public int Y;
    }
}
