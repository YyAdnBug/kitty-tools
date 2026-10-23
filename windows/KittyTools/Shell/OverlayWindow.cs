// 浮层：剪贴板面板和启动器共用的窗口（第 1 批只有壳和占位内容）。
// WinUI Window + OverlappedPresenter：无标题栏、保留边框（系统圆角 / 阴影 / 细描边）、
// 置顶、不可缩放、不进任务栏和 Alt+Tab；内容用亚克力。
// 关闭：Esc、Ctrl+W、再按一次热键、失去激活（不还前台）。
using System.Runtime.InteropServices;
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
    private const int HeightDip = 360;

    private readonly TextBlock _title;
    private readonly TextBox _input;
    private readonly TextBlock _body;
    private readonly Grid _root;

    private OverlayKind _kind;
    private HWND _hwnd;
    private HWND _previousForeground;
    private bool _visible;
    private bool _hiding;

    public OverlayWindow()
    {
        Title = Paths.ProductName + " 浮层";
        _root = new Grid
        {
            Padding = new Thickness(20, 16, 20, 16),
            RowSpacing = 10,
            Background = new SolidColorBrush(Colors.Transparent),
            RequestedTheme = Theme.ElementTheme,
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
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

        _input = new TextBox
        {
            PlaceholderText = "搜索剪贴板…",
            FontSize = 20,
            Height = 56,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        _input.KeyDown += OnKeyDown;

        _body = new TextBlock
        {
            Text = "第 1 批只做了壳：这里以后放真正的列表。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.65,
            Margin = new Thickness(2, 4, 0, 0),
        };

        var card = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            Background = new SolidColorBrush(Theme.ElementTheme == ElementTheme.Dark
                ? Windows.UI.Color.FromArgb(36, 255, 255, 255)
                : Windows.UI.Color.FromArgb(20, 0, 0, 0)),
            Child = _body,
        };

        Grid.SetRow(header, 0);
        Grid.SetRow(_input, 1);
        Grid.SetRow(card, 2);
        _root.Children.Add(header);
        _root.Children.Add(_input);
        _root.Children.Add(card);

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
        Activated += OnActivated;
    }

    public bool IsVisible => _visible;

    public OverlayKind Kind => _kind;

    public void ShowOverlay(OverlayKind kind)
    {
        _kind = kind;
        _root.RequestedTheme = Theme.ElementTheme;
        var clipboard = kind == OverlayKind.Clipboard;
        _title.Text = clipboard ? "剪贴板历史" : "启动器";
        _input.PlaceholderText = clipboard ? "搜索剪贴板…" : "搜索应用、设置、命令…";
        _input.Text = string.Empty;
        _body.Text = clipboard
            ? "第 1 批只做了壳：剪贴板历史在第 2 批接上。"
            : "第 1 批只做了壳：应用、设置和命令在第 4 批接上。";

        var before = Foreground.Get();
        if (before != default && !Foreground.IsOurs(before))
        {
            _previousForeground = before;
        }

        PositionAtPointer();
        _visible = true;
        Activate();
        Foreground.Restore(_hwnd);
        _input.Focus(FocusState.Programmatic);
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

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding)
        {
            HideOverlay(restoreForeground: false);
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            e.Handled = true;
            HideOverlay(restoreForeground: true);
        }
        else if (e.Key == Windows.System.VirtualKey.W &&
                 Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                     .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
        {
            e.Handled = true;
            HideOverlay(restoreForeground: true);
        }
        else if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            NoticeHost.Show("还没做", "第 1 批只有壳，这个面板的内容在后面几批接上", NoticeTone.Normal);
        }
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
        var width = (int)Math.Round(WidthDip * scale);
        var height = (int)Math.Round(HeightDip * scale);
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

    public static void Toggle(OverlayKind kind)
    {
        if (_window is { IsVisible: true })
        {
            if (_window.Kind == kind)
            {
                _window.HideOverlay(restoreForeground: true);
                return;
            }

            _window.ShowOverlay(kind);
            return;
        }

        Show(kind);
    }

    public static void Show(OverlayKind kind)
    {
        _window ??= new OverlayWindow();
        _window.ShowOverlay(kind);
    }

    public static void Hide(bool restoreForeground) => _window?.HideOverlay(restoreForeground);
}
