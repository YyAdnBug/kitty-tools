// 录屏的控制条（第四版第 2 批；PLAN-v9 R6 R7 照 mac RecordingHUD）：深色 HUD，放在选区下方（整屏就贴屏幕底部），可以拖动。
// 倒数态（R6）：[3 秒后开始] ｜ [✕ 取消]，数字每秒换一下（淡入），点数字马上开始；倒数 0 秒时直接是录制态。
// 录制态：红点 + 计时 + 两个只读的声音图标（系统声音、麦克风：录 = 强调色，不录 = 灰的划掉的图标，中途断了变橙，R7）
// + 橙字备注 +「✕ 放弃」（点两下，2 秒内）+「■ 停止」。宽 300（多了两个图标，268 放不下「再点一次放弃」）。
// 设 WDA_EXCLUDEFROMCAPTURE，尽量不录进画面（GDI 抓屏对它不一定生效，报告里会说明）。
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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

    /// <summary>录制条的宽（DIP）：比 HudPlacement 默认的 268 宽一点，放得下两个声音图标。</summary>
    private const double WidthDip = 300;

    private static RecordingHud? _instance;

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _instance is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_instance._window);

    private readonly Window _window;
    private readonly StackPanel _countdownPanel;
    private readonly Button _countdownButton;
    private readonly TextBlock _countdownText;
    private readonly StackPanel _recordingPanel;
    private readonly TextBlock _timer;
    private readonly FontIcon _systemIcon;
    private readonly FontIcon _microphoneIcon;
    private readonly TextBlock _note;
    private readonly Button _abandon;
    private DispatcherQueueTimer? _tick;
    private int _seconds;
    private bool _armed;
    private long _armedAt;
    private PointInt32 _dragOffset;
    private bool _dragging;

    private RecordingHud(PixelBounds region)
    {
        _window = new Window { Title = "录屏" };
        HudFrame.Apply(_window);
        var white = new SolidColorBrush(Colors.White);

        // ---- 倒数态
        _countdownText = new TextBlock
        {
            Foreground = white,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _countdownButton = new Button
        {
            Content = _countdownText,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(_countdownButton, "马上开始");
        _countdownButton.Click += (_, _) => RecordingCountdown.StartNow();
        var cancel = new Button
        {
            Content = "✕ 取消",
            FontSize = 12,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            Foreground = white,
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(cancel, "取消录屏");
        cancel.Click += (_, _) => RecordingCountdown.Cancel();
        _countdownPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _countdownPanel.Children.Add(_countdownButton);
        _countdownPanel.Children.Add(Separator());
        _countdownPanel.Children.Add(cancel);

        // ---- 录制态
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
            Foreground = white,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 40,
        };
        _systemIcon = new FontIcon { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        _microphoneIcon = new FontIcon { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        var sources = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        sources.Children.Add(_systemIcon);
        sources.Children.Add(_microphoneIcon);
        _note = new TextBlock
        {
            Foreground = new SolidColorBrush(Theme.Argb(255, 255, 159, 10)),
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 120,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Visibility = Visibility.Collapsed,
        };
        _abandon = new Button
        {
            Content = "✕ 放弃",
            FontSize = 12,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            Foreground = white,
            BorderThickness = new Thickness(0),
        };
        _abandon.Click += (_, _) => Abandon();
        var stop = new Button
        {
            Content = "■ 停止",
            FontSize = 12,
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.OrangeRed),
            Foreground = white,
            BorderThickness = new Thickness(0),
        };
        stop.Click += (_, _) => RecordingHost.Stop();
        _recordingPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 7,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _recordingPanel.Children.Add(dot);
        _recordingPanel.Children.Add(_timer);
        _recordingPanel.Children.Add(sources);
        _recordingPanel.Children.Add(_note);
        _recordingPanel.Children.Add(Separator());
        _recordingPanel.Children.Add(_abandon);
        _recordingPanel.Children.Add(stop);

        var content = new Grid();
        content.Children.Add(_countdownPanel);
        content.Children.Add(_recordingPanel);

        // 铺满整扇窗口：圆角、阴影、发丝线由 DWM 画（HudFrame）。
        var root = new Border
        {
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 32, 32, 32)),
            Padding = new Thickness(12, 6, 10, 6),
            Child = content,
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
            display.Scale, WidthDip);
        _window.AppWindow.MoveAndResize(HudFrame.WithFrame(_window, new RectInt32(
            placement.X, placement.Y, placement.Width, placement.Height)));
        var hwnd = (IntPtr)WinRT.Interop.WindowNative.GetWindowHandle(_window);
        _window.AppWindow.Show(false);
        if (Environment.GetEnvironmentVariable("KITTY_HUD_CAPTURE") != "1")
        {
            // 录制时不把自己录进去；截图自检时用 KITTY_HUD_CAPTURE=1 关掉，才能在截图里看到它。
            SetWindowDisplayAffinity(hwnd, 0x11);
        }

        Log.Info("record.hud-shown");
    }

    private static Border Separator() => new()
    {
        Width = 1,
        Height = 16,
        Background = new SolidColorBrush(ColorHelper.FromArgb(40, 255, 255, 255)),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>倒数开始时就出控制条（R6，同 mac：倒数时录制条已经在了）。</summary>
    public static void ShowCountdown(PixelBounds region, int seconds)
    {
        if (_instance is null)
        {
            Create(region);
        }

        _instance?.EnterCountdown(seconds);
    }

    /// <summary>倒数走了一秒：换数字。</summary>
    public static void Countdown(int remaining) => _instance?.EnterCountdown(remaining);

    /// <summary>开录：倒数时出来的那一条原地换成录制态；没倒数就新开一条。</summary>
    public static void Show(PixelBounds region)
    {
        if (_instance is null)
        {
            Create(region);
        }

        _instance?.EnterRecording();
    }

    private static void Create(PixelBounds region)
    {
        try
        {
            _instance = new RecordingHud(region);
        }
        catch (Exception ex)
        {
            Log.Warn($"record.hud-failed {ex.GetType().Name}");
        }
    }

    private void EnterCountdown(int remaining)
    {
        _countdownText.Text = $"{remaining} 秒后开始";
        AutomationProperties.SetName(_countdownButton, $"{remaining} 秒后开始录屏，点一下马上开始");
        if (_countdownPanel.Visibility != Visibility.Visible)
        {
            _countdownPanel.Visibility = Visibility.Visible;
            _recordingPanel.Visibility = Visibility.Collapsed;
        }
        else
        {
            Motion.Appear(_countdownText);
        }
    }

    private void EnterRecording()
    {
        if (_tick is not null)
        {
            return;
        }

        _countdownPanel.Visibility = Visibility.Collapsed;
        _recordingPanel.Visibility = Visibility.Visible;
        Refresh();
        _tick = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _tick.Interval = TimeSpan.FromSeconds(1);
        _tick.Tick += (_, _) =>
        {
            _seconds++;
            _timer.Text = RecorderRules.Duration(_seconds * 1000);
            Refresh();
        };
        _tick.Start();
    }

    /// <summary>橙字备注和两个声音图标（R7）：录不录跟着开录时的设置，备注里说哪一路断了就把那个图标染橙。</summary>
    private void Refresh()
    {
        var note = RecordingHost.LiveNote;
        _note.Text = note ?? string.Empty;
        _note.Visibility = string.IsNullOrEmpty(note) ? Visibility.Collapsed : Visibility.Visible;
        ShowSource(_systemIcon, RecordingHost.WithSystemAudio, note?.Contains("系统声音", StringComparison.Ordinal) == true,
            Glyphs.Volume, Glyphs.VolumeOff, "系统声音");
        ShowSource(_microphoneIcon, RecordingHost.WithMicrophone, note?.Contains("麦克风", StringComparison.Ordinal) == true,
            Glyphs.Microphone, Glyphs.MicrophoneOff, "麦克风");
    }

    private static void ShowSource(FontIcon icon, bool on, bool lost, string glyph, string offGlyph, string name)
    {
        icon.Glyph = on ? glyph : offGlyph;
        icon.Foreground = new SolidColorBrush(
            lost ? Theme.Argb(255, 255, 159, 10) : on ? Theme.AccentColor : Theme.Argb(110, 255, 255, 255));
        AutomationProperties.SetName(icon, $"{name}：{(lost ? "断了" : on ? "在录" : "不录")}");
        ToolTipService.SetToolTip(icon, $"{name}{(lost ? "断了" : on ? "" : "（不录）")}");
    }

    public static void Hide()
    {
        if (_instance is not { } hud)
        {
            return;
        }

        _instance = null;
        hud._tick?.Stop();
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
