// 轻提示：鼠标所在屏、工作区顶部居中、往下 12 px；
// 深色圆角条，图标 + 标题 + 一行详情，停 2 s 自己收起。新的一条原地替换旧的。
// 不抢焦点、不接鼠标：WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW + SW_SHOWNOACTIVATE。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
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
    private const int WsExNoActivate = 0x08000000;
    private const int SwShowNoActivate = 4;

    private static NoticeHost? _current;
    private readonly Window _window;
    private readonly Border _border;
    private readonly FontIcon _icon;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly HWND _hwnd;
    private readonly DispatcherQueueTimer _timer;
    private bool _shown;

    private NoticeHost()
    {
        _border = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 10, 14, 10),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(235, 32, 32, 32)),
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        _icon = new FontIcon { FontSize = 16, Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)) };
        var texts = new StackPanel { Spacing = 1 };
        _title = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)),
        };
        _detail = new TextBlock
        {
            FontSize = 12,
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(210, 255, 255, 255)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 420,
        };
        texts.Children.Add(_title);
        texts.Children.Add(_detail);
        row.Children.Add(_icon);
        row.Children.Add(texts);
        _border.Child = row;

        _window = new Window
        {
            Title = Paths.ProductName + " 提示",
            Content = _border,
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
        SetWindowLong((IntPtr)_hwnd.Value, GwlExStyle, style | WsExNoActivate | WsExToolWindow | WsExTransparent);
        _timer = _window.DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(2);
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) => Hide();
    }

    public static void Show(string title, string detail, NoticeTone tone)
    {
        _current ??= new NoticeHost();
        _current.ShowCore(title, detail, tone);
    }

    private void ShowCore(string title, string detail, NoticeTone tone)
    {
        _title.Text = title;
        _detail.Text = detail;
        _detail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
        (_icon.Glyph, _border.Background) = tone switch
        {
            NoticeTone.Warning => ("\uE7BA", new SolidColorBrush(Windows.UI.Color.FromArgb(240, 194, 65, 12))),
            NoticeTone.Error => ("\uEA39", new SolidColorBrush(Windows.UI.Color.FromArgb(240, 185, 28, 28))),
            _ => ("\uE946", new SolidColorBrush(Windows.UI.Color.FromArgb(235, 32, 32, 32))),
        };

        PositionAtPointer();
        if (!_shown)
        {
            _shown = true;
        }

        PInvoke.ShowWindow(_hwnd, (SHOW_WINDOW_CMD)SwShowNoActivate);
        PInvoke.DwmFlush();
        _timer.Stop();
        _timer.Start();
    }

    private void Hide()
    {
        _timer.Stop();
        _window.AppWindow.Hide();
    }

    private void PositionAtPointer()
    {
        PInvoke.GetCursorPos(out var cursor);
        var monitor = PInvoke.MonitorFromPoint(cursor, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        if (!PInvoke.GetMonitorInfo(monitor, ref info))
        {
            return;
        }

        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        var width = (int)Math.Round(460 * scale);
        var height = (int)Math.Round(64 * scale);
        var work = info.rcWork;
        var x = work.left + Math.Max(0, (work.right - work.left - width) / 2);
        var y = work.top + (int)Math.Round(12 * scale);
        _window.AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static partial int GetWindowLong(IntPtr hWnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static partial int SetWindowLong(IntPtr hWnd, int index, int value);
}
