// 录屏中的控制条（第四版第 2 批）：深色 HUD，红点 + 计时 + 「✕ 放弃」+「■ 停止」。
// 放在选区下方（整屏就贴屏幕底部），可以拖动；点「放弃」要两下（2 秒内）才真的丢掉这段。
// 设 WDA_EXCLUDEFROMCAPTURE，尽量不录进画面（GDI 抓屏对它不一定生效，报告里会说明）。
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.Win32;
using KittyTools.Core;
using KittyTools.Infrastructure;
using System.Runtime.InteropServices;

namespace KittyTools;

internal sealed partial class RecordingHud
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    private static RecordingHud? _instance;

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _instance is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_instance._window);

    private readonly Window _window;
    private readonly TextBlock _timer;
    private readonly TextBlock _note;
    private readonly Button _abandon;
    private readonly DispatcherQueueTimer _tick;
    private int _seconds;
    private bool _armed;
    private long _armedAt;
    private PointInt32 _dragOffset;
    private bool _dragging;

    private RecordingHud(PixelBounds region)
    {
        _window = new Window { Title = "录屏" };
        HudFrame.Apply(_window);

        var dot = new Ellipse
        {
            Width = 10,
            Height = 10,
            Fill = new SolidColorBrush(Colors.OrangeRed),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _timer = new TextBlock
        {
            Text = "0:00",
            Foreground = new SolidColorBrush(Colors.White),
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 42,
        };
        _note = new TextBlock
        {
            Foreground = new SolidColorBrush(Theme.Argb(255, 255, 159, 10)),
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 150,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Visibility = Visibility.Collapsed,
        };
        _abandon = new Button
        {
            Content = "✕ 放弃",
            FontSize = 12,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            Foreground = new SolidColorBrush(Colors.White),
            BorderThickness = new Thickness(0),
        };
        _abandon.Click += (_, _) => Abandon();
        var stop = new Button
        {
            Content = "■ 停止",
            FontSize = 12,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.OrangeRed),
            Foreground = new SolidColorBrush(Colors.White),
            BorderThickness = new Thickness(0),
        };
        stop.Click += (_, _) => RecordingHost.Stop();

        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        panel.Children.Add(dot);
        panel.Children.Add(_timer);
        panel.Children.Add(_note);
        panel.Children.Add(new Border
        {
            Width = 1,
            Height = 16,
            Background = new SolidColorBrush(ColorHelper.FromArgb(40, 255, 255, 255)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        panel.Children.Add(_abandon);
        panel.Children.Add(stop);

        // 铺满整扇窗口：圆角、阴影、发丝线由 DWM 画（HudFrame）。
        var root = new Border
        {
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 32, 32, 32)),
            Padding = new Thickness(12, 6, 10, 6),
            Child = panel,
        };
        root.PointerPressed += OnPointerPressed;
        root.PointerMoved += OnPointerMoved;
        root.PointerReleased += (_, _) => _dragging = false;
        root.PointerCaptureLost += (_, _) => _dragging = false;
        _window.Content = root;

        var display = Displays.AtPoint(
            region.Left + region.Width / 2, region.Top + region.Height / 2);
        var placement = HudPlacement.Compute(
            region.Left, region.Top, region.Right, region.Bottom,
            display.Work.Left, display.Work.Top, display.Work.Right, display.Work.Bottom,
            display.Scale);
        _window.AppWindow.MoveAndResize(HudFrame.WithFrame(_window, new RectInt32(
            placement.X, placement.Y, placement.Width, placement.Height)));
        var hwnd = (IntPtr)WinRT.Interop.WindowNative.GetWindowHandle(_window);
        _window.AppWindow.Show(false);
        if (Environment.GetEnvironmentVariable("KITTY_HUD_CAPTURE") != "1")
        {
            // 录制时不把自己录进去；截图自检时用 KITTY_HUD_CAPTURE=1 关掉，才能在截图里看到它。
            SetWindowDisplayAffinity(hwnd, 0x11);
        }
        _tick = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _tick.Interval = TimeSpan.FromSeconds(1);
        _tick.Tick += (_, _) =>
        {
            _seconds++;
            _timer.Text = RecorderRules.Duration(_seconds * 1000);
            var note = RecordingHost.LiveNote;
            _note.Text = note ?? string.Empty;
            _note.Visibility = string.IsNullOrEmpty(note) ? Visibility.Collapsed : Visibility.Visible;
        };
        _tick.Start();
        Log.Info("record.hud-shown");
    }

    public static void Show(PixelBounds region)
    {
        if (_instance is not null)
        {
            return;
        }

        try
        {
            _instance = new RecordingHud(region);
        }
        catch (Exception ex)
        {
            Log.Warn($"record.hud-failed {ex.GetType().Name}");
        }
    }

    public static void Hide()
    {
        if (_instance is not { } hud)
        {
            return;
        }

        _instance = null;
        hud._tick.Stop();
        try
        {
            hud._window.Close();
        }
        catch
        {
            // 已经关了。
        }

        Log.Info("record.hud-hidden");
    }

    private void Abandon()
    {
        var now = Environment.TickCount64;
        if (_armed && now - _armedAt <= 2000)
        {
            RecordingHost.Abandon();
            return;
        }

        _armed = true;
        _armedAt = now;
        _abandon.Content = "再点一次放弃";
        _abandon.Foreground = new SolidColorBrush(Colors.OrangeRed);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed)
        {
            return;
        }

        _dragging = true;
        PInvoke.GetCursorPos(out var cursor);
        _dragOffset = new PointInt32(cursor.X - _window.AppWindow.Position.X,
            cursor.Y - _window.AppWindow.Position.Y);
        (sender as UIElement)?.CapturePointer(e.Pointer);
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        _window.AppWindow.Move(new PointInt32(cursor.X - _dragOffset.X, cursor.Y - _dragOffset.Y));
    }
}
