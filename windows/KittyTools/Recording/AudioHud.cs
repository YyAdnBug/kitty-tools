// 录音控制条（REVIEW R28 / PLAN-v6 第 3 批）：屏幕上方的深色胶囊，红点 + 计时 + 电平条 +
// 暂停 / 继续 + 停止。显示时不抢焦点，位置按鼠标所在屏的 DPI 计算。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.Win32;

namespace KittyTools;

internal sealed partial class AudioHud
{
    private static AudioHud? _instance;

    private readonly Window _window;
    private readonly TextBlock _timer;
    private readonly Border _levelFill;
    private readonly TextBlock _hint;
    private readonly Button _pause;
    private readonly DispatcherQueueTimer _tick;
    private bool _pending;
    private bool _noteCleared;

    private AudioHud(string? note, bool pending)
    {
        _pending = pending;
        _window = new Window { Title = "录音" };
        _window.SystemBackdrop = new TransparentBackdrop();
        _window.AppWindow.IsShownInSwitchers = false;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        _window.AppWindow.SetPresenter(presenter);
        _window.ExtendsContentIntoTitleBar = true;

        var dot = new Ellipse
        {
            Width = 9,
            Height = 9,
            Fill = new SolidColorBrush(Theme.Argb(255, 255, 69, 58)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _timer = new TextBlock
        {
            Text = "0:00",
            Foreground = new SolidColorBrush(Theme.Argb(242, 255, 255, 255)),
            FontSize = Theme.FontSize("Kitty.FontSize.RowTitle"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            MinWidth = 42,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var meter = new Grid { Width = 54, Height = 6, VerticalAlignment = VerticalAlignment.Center };
        meter.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(3),
            Background = new SolidColorBrush(Theme.Argb(38, 255, 255, 255)),
        });
        _levelFill = new Border
        {
            CornerRadius = new CornerRadius(3),
            Background = new SolidColorBrush(Theme.Argb(255, 52, 199, 89)),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
        };
        meter.Children.Add(_levelFill);

        _hint = new TextBlock
        {
            Text = note ?? string.Empty,
            Foreground = new SolidColorBrush(Theme.Argb(255, 255, 159, 10)),
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 120,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        _pause = new Button
        {
            Content = pending ? "开始" : "暂停",
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            Foreground = new SolidColorBrush(Theme.Argb(242, 255, 255, 255)),
            BorderThickness = new Thickness(0),
        };
        _pause.Click += (_, _) =>
        {
            if (_pending)
            {
                _pending = false;
                AudioHost.BeginFromHud();
                UpdatePause();
                return;
            }

            if (AudioHost.IsPaused)
            {
                AudioHost.Resume();
            }
            else
            {
                AudioHost.Pause();
            }

            UpdatePause();
        };
        AutomationProperties.SetName(_pause, "暂停或继续录音");

        var stop = new Button
        {
            Content = "停止",
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Theme.Argb(255, 255, 69, 58)),
            Foreground = new SolidColorBrush(Colors.White),
            BorderThickness = new Thickness(0),
        };
        stop.Click += (_, _) => AudioHost.Stop();
        AutomationProperties.SetName(stop, "停止录音");

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(dot);
        row.Children.Add(_timer);
        row.Children.Add(meter);
        row.Children.Add(_hint);
        row.Children.Add(_pause);
        row.Children.Add(stop);

        var root = new Border
        {
            Height = 40,
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Theme.Argb(235, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(Theme.Argb(36, 255, 255, 255)),
            BorderThickness = new Thickness(0.5),
            Padding = new Thickness(12, 4, 8, 4),
            Child = row,
        };
        _window.Content = root;

        var display = Displays.AtCursor();
        var width = (int)Math.Round(320 * display.Scale);
        var height = (int)Math.Round(40 * display.Scale);
        var x = display.Work.Left + (display.Work.Width - width) / 2;
        var y = display.Work.Top + (int)Math.Round(12 * display.Scale);
        _window.AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        var hwnd = (IntPtr)WinRT.Interop.WindowNative.GetWindowHandle(_window);
        var style = GetWindowLong(hwnd, -20);
        SetWindowLong(hwnd, -20, style | 0x08000000);
        _window.AppWindow.Show(false);

        _tick = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        _tick.Interval = TimeSpan.FromMilliseconds(100);
        _tick.IsRepeating = true;
        _tick.Tick += (_, _) => Refresh();
        _tick.Start();
        Refresh();
    }

    public static void Show(string? note = null) => ShowInternal(note, pending: false);

    public static void ShowPending() => ShowInternal(null, pending: true);

    private static void ShowInternal(string? note, bool pending)
    {
        if (_instance is not null)
        {
            return;
        }

        try
        {
            _instance = new AudioHud(note, pending);
            Log.Info($"audio.hud-shown pending={pending}");
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.hud-failed {ex.GetType().Name}");
        }
    }

    /// <summary>控制条上的 ● 被点了：从“待录”切成计时。</summary>
    public static void MarkStarted()
    {
        if (_instance is not { } hud)
        {
            return;
        }

        hud._pending = false;
        hud.UpdatePause();
        hud.Refresh();
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

        Log.Info("audio.hud-hidden");
    }

    private void Refresh()
    {
        if (_pending)
        {
            _timer.Text = "待录";
            _levelFill.Width = 0;
            return;
        }

        _timer.Text = AudioHost.Elapsed;
        var level = Math.Clamp((AudioHost.Level + 60) / 60.0, 0, 1);
        _levelFill.Width = 54 * level;
        var note = AudioHost.StatusNote;
        if (!string.IsNullOrEmpty(note))
        {
            _hint.Text = note;
            _noteCleared = false;
        }
        else if (!_noteCleared && AudioHost.Level > -45)
        {
            _hint.Text = string.Empty;
            _noteCleared = true;
        }

        UpdatePause();
    }

    private void UpdatePause()
    {
        _pause.Content = AudioHost.IsPaused ? "继续" : "暂停";
    }

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);
}
