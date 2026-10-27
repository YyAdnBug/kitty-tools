// 轻提示（0.1.0 用户定：不学 mac 的刘海岛，用 Windows 自己的样子）：像 Win11 调音量 / 亮度时任务栏上方那块浮层。
// 就是一扇和卡片一样大的小窗口：系统亚克力、DWM 画的 8 圆角 / 阴影 / 发丝线，鼠标所在屏的工作区底部居中、离任务栏 12。
// 不再用「大透明窗口 + 里面画一颗胶囊」：透明那一层在这台机器上一直是白的（0.1.0 用户反馈「外面一圈白色容器」）。
// 出场 / 收起交给系统（DWM 给窗口的淡入淡出），按钮、进度条都是系统控件（主按钮 AccentButtonStyle）。
// 报得出百分比的（下载更新、转 GIF、压缩）走 ShowProgress：标题后面一条细进度条，原地改、不重新出场、不播报。
// 能交互（PLAN-v8 第 5 批 H9–H14）：鼠标进来算悬停：停住计时、往上长成卡片（第一行 + 最多 4 行详情），
// 按钮全露出来、加 ×；离开合回一行、接着走剩下的时间（至少 1.5 s）。点卡片本身只执行「打开」类的按钮。
// 鼠标在上面时来的新提示先排着（只留最新的），进行中那条的结果原地换。
// 窗口不抢焦点：WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW，SW_SHOWNOACTIVATE。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
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
/// Opens：「打开」类的（在资源管理器中显示、打开设置……）——点浮层本身也执行第一个这种；撤销、取消、重试不算。
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
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private const int SwShowNoActivate = 4;

    /// <summary>一行的高度（DIP）。</summary>
    private const double RowHeight = 46;

    /// <summary>内容最宽（DIP），再长就省略。</summary>
    private const double MaxCardWidth = 460;

    /// <summary>展开的卡片最高：第一行 46 + 4 行详情 + 底下 10。</summary>
    private const double MaxCardHeight = 134;

    /// <summary>卡片底边离工作区底边（任务栏上沿）的距离，Win11 音量浮层也是这么高。</summary>
    private const double BottomGap = 12;

    private const double ProgressWidth = 56;

    /// <summary>内容刚换 / 刚展开这么久之内点卡片不算（mac 0.3 s）。</summary>
    private const long ClickGraceMs = 300;

    private static NoticeHost? _current;

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _current is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_current._window);

    /// <summary>--ui-snapshots 用：不用鼠标，直接摆出悬停展开的样子（PLAN-v8 第 5 批）。</summary>
    internal static void ExpandForProbe() => _current?.HoverStart();

    /// <summary>--notice-anim-test 用：XAML 一共排了几次版。</summary>
    internal static int LayoutPassesForProbe { get; private set; }

    private readonly Window _window;
    private readonly Grid _root;
    private readonly Border _content;
    private readonly FontIcon _icon;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly TextBlock _detailFull;
    private readonly StackPanel _buttons;
    private readonly Button _close;
    private readonly ProgressBar _progressBar;
    private readonly HWND _hwnd;
    private readonly DispatcherQueueTimer _hideTimer;

    private bool _visible;
    private bool _progress;
    private int _generation;
    private IReadOnlyList<NoticeAction> _actions = Array.Empty<NoticeAction>();
    private bool _hovered;
    private long _contentChangedAt;
    private long _hideDeadline;
    private long _remainingMs;
    private (string Title, string Detail, NoticeTone Tone, double? Fraction, NoticeAction[] Actions)? _pending;

    private NoticeHost()
    {
        _icon = new FontIcon
        {
            FontSize = 16,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _title = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _progressBar = new ProgressBar
        {
            Width = ProgressWidth,
            Minimum = 0,
            Maximum = 1,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _detail = new TextBlock
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 400,
        };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(_title);
        titleRow.Children.Add(_progressBar);
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
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Height = RowHeight };
        row.Children.Add(_icon);
        row.Children.Add(texts);
        row.Children.Add(_buttons);
        row.Children.Add(_close);

        // 展开后的完整详情：和标题左对齐（图标 16 + 间距 12），最多 4 行。
        _detailFull = new TextBlock
        {
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 4,
            MaxWidth = MaxCardWidth - 32 - 28,
            Margin = new Thickness(28, 0, 0, 10),
            HorizontalAlignment = HorizontalAlignment.Left,
            Visibility = Visibility.Collapsed,
        };
        var layout = new StackPanel();
        layout.Children.Add(row);
        layout.Children.Add(_detailFull);

        _content = new Border
        {
            MaxWidth = MaxCardWidth,
            Padding = new Thickness(16, 0, 10, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Child = layout,
        };
        _root = new Grid
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        _root.Children.Add(_content);
        _root.Tapped += OnTapped;
        _root.PointerEntered += (_, _) =>
        {
            if (_visible && !_hovered)
            {
                HoverStart();
            }
        };
        _root.PointerExited += (_, _) =>
        {
            if (_visible && _hovered)
            {
                HoverEnd();
            }
        };
        _root.LayoutUpdated += (_, _) => LayoutPassesForProbe++;
        // 读屏：轻提示是活区，出现时用 UIA 通知播报（讲述人 / NVDA 都认这一条）。
        AutomationProperties.SetLiveSetting(_root, AutomationLiveSetting.Polite);
        AutomationProperties.SetName(_root, Paths.ProductName + " 提示");

        _window = new Window
        {
            Title = Paths.ProductName + " 提示",
            Content = _root,
            // 系统的亚克力：和 Win11 的音量 / 亮度浮层、开始菜单同一种材质，浅色 / 深色跟着窗口主题走。
            SystemBackdrop = new DesktopAcrylicBackdrop(),
        };
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        // 留着系统的细边框：圆角、阴影、发丝线都由 DWM 画（同截图卡片）。
        presenter.SetBorderAndTitleBar(true, false);
        _window.AppWindow.SetPresenter(presenter);
        _window.AppWindow.IsShownInSwitchers = false;
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(_window);

        // 建好就把「不抢焦点」的样式挂上：第一次显示也不能激活，
        // 否则会在浮层里复制 / 删除之后把浮层抢掉（浮层失去激活就会收起）。
        var style = GetWindowLong((IntPtr)_hwnd.Value, GwlExStyle);
        SetWindowLong((IntPtr)_hwnd.Value, GwlExStyle, style | WsExNoActivate | WsExToolWindow);
        var round = 2; // DWMWCP_ROUND：8 圆角
        DwmSetWindowAttribute((IntPtr)_hwnd.Value, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));

        _hideTimer = _window.DispatcherQueue.CreateTimer();
        _hideTimer.IsRepeating = false;
        _hideTimer.Tick += (_, _) => Hide();
    }

    public static void Show(string title, string detail, NoticeTone tone, params NoticeAction[] actions)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, tone, null, actions);
    }

    /// <summary>
    /// 进行中、报得出百分比（<paramref name="fraction"/> 0–1）：标题后面一条 56 宽的系统进度条，详情照旧写百分比。
    /// 同一个标题再调就原地改（只动进度条和宽度），不重新出场、不播报；一直挂着，60 s 兜底。只在 UI 线程调。
    /// </summary>
    public static void ShowProgress(string title, string detail, double fraction, params NoticeAction[] actions)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, NoticeTone.Normal, fraction, actions);
    }

    private void ShowCore(string title, string detail, NoticeTone tone, double? fraction, NoticeAction[] actions)
    {
        var quiet = fraction is not null && _progress && _visible && _title.Text == title;
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
        _root.RequestedTheme = Theme.ElementTheme;
        _title.Text = title;
        _detail.Text = detail;
        _detailFull.Text = detail;
        _detail.Foreground = Theme.SecondaryText();
        _detailFull.Foreground = Theme.SecondaryText();
        _progressBar.Visibility = _progress ? Visibility.Visible : Visibility.Collapsed;
        if (fraction is { } value)
        {
            _progressBar.Value = Math.Clamp(value, 0, 1);
        }

        ApplyTone(tone);
        var dwell = _progress ? 60 : actions.Length > 0 ? 6.0 : tone == NoticeTone.Error ? 3.0
            : string.IsNullOrEmpty(detail) ? 1.4 : 2.0;
        _contentChangedAt = Environment.TickCount64;
        Place(_hovered);
        if (!_visible)
        {
            // 出场交给系统：DWM 给不激活的窗口自己的淡入，内容再跟一个淡入。
            PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)SwShowNoActivate);
            _visible = true;
            Motion.Appear(_content);
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
    /// 排好收着 / 展开的样子，把窗口摆成卡片那么大：鼠标所在屏的工作区底部居中、底边离任务栏 12，
    /// 展开时底边不动往上长（H10）。窗口带系统边框，客户区比窗口小一圈，按客户区算再把边框加回去。
    /// </summary>
    private void Place(bool expanded)
    {
        ApplyLayout(expanded: false);
        _content.Measure(new Windows.Foundation.Size(MaxCardWidth, double.PositiveInfinity));
        var width = Math.Clamp(_content.DesiredSize.Width, RowHeight, MaxCardWidth);
        var height = RowHeight;
        if (expanded)
        {
            ApplyLayout(expanded: true);
            _content.Measure(new Windows.Foundation.Size(MaxCardWidth, double.PositiveInfinity));
            width = Math.Clamp(Math.Max(width, _content.DesiredSize.Width), RowHeight, MaxCardWidth);
            height = Math.Clamp(_content.DesiredSize.Height, RowHeight, MaxCardHeight);
        }

        var display = _visible ? Displays.AtWindow(_hwnd) : Displays.AtCursor();
        var scale = display.Scale;
        var frameX = Math.Max(0, _window.AppWindow.Size.Width - _window.AppWindow.ClientSize.Width) / scale;
        var frameY = Math.Max(0, _window.AppWindow.Size.Height - _window.AppWindow.ClientSize.Height) / scale;
        var rect = MonitorLayout.Notice(display.Work, scale, width + frameX, height + frameY, BottomGap);
        _window.AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
    }

    private void ApplyLayout(bool expanded)
    {
        var hasDetail = !string.IsNullOrEmpty(_detail.Text);
        _detail.Visibility = hasDetail && !expanded ? Visibility.Visible : Visibility.Collapsed;
        _detailFull.Visibility = hasDetail && expanded ? Visibility.Visible : Visibility.Collapsed;
        _close.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        // 收着时字给按钮让地方：以前详情长了，右边的按钮被裁掉一半。
        var narrow = !expanded && _actions.Count > 0;
        _title.MaxWidth = narrow ? 230 : 400;
        _detail.MaxWidth = narrow ? 230 : 400;
        _buttons.Children.Clear();
        if (_actions.Count == 0)
        {
            return;
        }

        // 收着时只露第一个（最主要的）；展开后全露出来，主按钮放最右、强调色（H11）。
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

    /// <summary>系统按钮：主按钮是 AccentButtonStyle（强调色填满），其余是默认按钮。</summary>
    private Button MakeButton(NoticeAction action, bool primary)
    {
        var button = new Button
        {
            Content = action.Title,
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Padding = new Thickness(10, 3, 10, 4),
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (primary && Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style) && style is Style accent)
        {
            button.Style = accent;
        }

        AutomationProperties.SetName(button, action.Title);
        button.Click += (_, _) => Run(action);
        return button;
    }

    private Button MakeCloseButton()
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = Glyphs.Close, FontSize = 10 },
            Width = 28,
            Height = 28,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(button, "关闭提示");
        button.Click += (_, _) => Hide();
        return button;
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
            Hide();
        }
    }

    /// <summary>点卡片本身（不在按钮上）：只执行第一个「打开」类的按钮（H12）；刚换内容 / 刚展开 0.3 s 内不算。</summary>
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

    /// <summary>悬停（H10）：停住计时，往上长成卡片，按钮全露出来、加 ×。</summary>
    private void HoverStart()
    {
        _hovered = true;
        _hideTimer.Stop();
        _remainingMs = Math.Max(0, _hideDeadline - Environment.TickCount64);
        _contentChangedAt = Environment.TickCount64;
        Place(expanded: true);
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

        _contentChangedAt = Environment.TickCount64;
        Place(expanded: false);
        // 进行中的合回一行、继续挂着；别的接着走剩下的时间，至少 1.5 s。
        StartHideTimer(_progress ? 60_000 : Math.Max(1500, _remainingMs));
    }

    /// <summary>语气图标：信息 / 进行中用强调色，警告橙、错误红（Windows 的 InfoBar 也是这几种颜色）。</summary>
    private void ApplyTone(NoticeTone tone)
    {
        var (glyph, color) = tone switch
        {
            NoticeTone.Warning => (Glyphs.Warning, Theme.Argb(255, 255, 159, 10)),
            NoticeTone.Error => (Glyphs.Error, Theme.Argb(255, 232, 17, 35)),
            _ => (Glyphs.Info, Theme.AccentColor),
        };
        _icon.Glyph = glyph;
        _icon.Foreground = new SolidColorBrush(color);
    }

    /// <summary>收起：交给系统（DWM 给窗口自己的淡出）。</summary>
    private void Hide()
    {
        _hideTimer.Stop();
        _window.AppWindow.Hide();
        _visible = false;
        _progress = false;
        _hovered = false;
        _pending = null;
        _actions = Array.Empty<NoticeAction>();
        _buttons.Children.Clear();
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

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hWnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hWnd, int index, int value);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static partial int DwmSetWindowAttribute(IntPtr hWnd, int attribute, ref int value, int size);
}
