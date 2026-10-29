// 录音控制条（REVIEW R28 / PLAN-v6 第 3 批；PLAN-v9 R9 照 mac RecordingHUD 的录音形态）：鼠标所在屏底部居中的深色条，
// 红点 + 计时 + 电平条 + 提示 + 暂停 / 继续 + ✕ 放弃（点两下）+ 停止；待录时是「✕ 关闭」+「开始」。
// 开头 5 s 一直没声音（录了麦克风时）出橙字「没听到声音」，有声音就收起（mac AudioRecorder）。
// 位置：mac 离底 24；Windows 的轻提示也在底部（离任务栏 12、高 46），录音条放在它上面（离底 70），开录那条提示不盖住它。
// 显示时不抢焦点，位置按鼠标所在屏的 DPI 计算。
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

    /// <summary>R33 截图自检（WindowShot）用：当前这扇窗口的 HWND，没开就是 0。</summary>
    internal static IntPtr HandleForProbe =>
        _instance is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(_instance._window);

    private readonly Window _window;
    private readonly TextBlock _timer;
    private readonly Border _levelFill;
    private readonly TextBlock _hint;
    private readonly Button _pause;
    private readonly Button _discard;
    private readonly Button _stop;
    private readonly DispatcherQueueTimer _tick;
    private bool _pending;
    /// <summary>开录时的提示（哪一路没录上）：听到声音后收起。</summary>
    private string? _startNote;
    /// <summary>开录以来听到过声音没有（「没听到声音」）。</summary>
    private bool _heard;
    private bool _armed;
    private long _armedAt;
    private readonly SolidColorBrush _discardNormal = new(Theme.Argb(242, 255, 255, 255));
    private readonly SolidColorBrush _discardArmed = new(Theme.Argb(255, 255, 69, 58));

    /// <summary>低于这个电平算没声音（mac：数字静音约 −120，安静房间的底噪约 −41 到 −51）。</summary>
    private const float SilenceDb = -70;

    /// <summary>开录这么久还没听到声音就提示。</summary>
    private const long SilenceWindowMs = 5000;

    /// <summary>离工作区底边：轻提示那一条（离底 12、高 46）上面再空 12。</summary>
    private const double BottomGapDip = 70;

    private AudioHud(string? note, bool pending)
    {
        _pending = pending;
        _startNote = string.IsNullOrEmpty(note) ? null : note;
        _window = new Window { Title = "录音" };
        HudFrame.Apply(_window);

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

        _discard = new Button
        {
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        _discard.Click += (_, _) => Discard();
        _stop = new Button
        {
            Content = "停止",
            FontSize = Theme.FontSize("Kitty.FontSize.Label"),
            Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Theme.Argb(255, 255, 69, 58)),
            Foreground = new SolidColorBrush(Colors.White),
            BorderThickness = new Thickness(0),
        };
        _stop.Click += (_, _) => AudioHost.Stop();
        AutomationProperties.SetName(_stop, "停止录音");

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
        row.Children.Add(_discard);
        row.Children.Add(_stop);

        // 铺满整扇窗口：圆角、阴影、发丝线由 DWM 画（HudFrame）。
        var root = new Border
        {
            Background = new SolidColorBrush(Theme.Argb(255, 28, 28, 28)),
            Padding = new Thickness(12, 4, 8, 4),
            Child = row,
        };
        _window.Content = root;

        var display = Displays.AtCursor();
        var width = (int)Math.Round(400 * display.Scale);
        var height = (int)Math.Round(40 * display.Scale);
        var x = display.Work.Left + (display.Work.Width - width) / 2;
        var y = display.Work.Bottom - height - (int)Math.Round(BottomGapDip * display.Scale);
        _window.AppWindow.MoveAndResize(HudFrame.WithFrame(_window, new RectInt32(x, y, width, height)));
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
            UpdatePause();
            return;
        }

        _timer.Text = AudioHost.Elapsed;
        var level = Math.Clamp((AudioHost.Level + 60) / 60.0, 0, 1);
        _levelFill.Width = 54 * level;
        if (AudioHost.Level > SilenceDb)
        {
            _heard = true;
        }

        if (_startNote is not null && AudioHost.Level > -45)
        {
            _startNote = null;
        }

        // 断了的那一路（实时）> 没听到声音 > 开录时的提示。
        // ponytail: 电平是两路混在一起的，「两者」时系统声音有声就不提示（mac 只看麦克风那一路）；要分开得让 AudioCaptureSet 各报各的电平。
        var live = AudioHost.StatusNote;
        var silent = !_heard && AudioHost.RecordsMicrophone && !AudioHost.IsPaused &&
                     AudioHost.ElapsedMs >= SilenceWindowMs;
        _hint.Text = !string.IsNullOrEmpty(live) ? live : silent ? "没听到声音" : _startNote ?? string.Empty;
        if (_armed && Environment.TickCount64 - _armedAt > 2000)
        {
            _armed = false;
        }

        UpdatePause();
    }

    private void UpdatePause()
    {
        _pause.Content = _pending ? "开始" : AudioHost.IsPaused ? "继续" : "暂停";
        // 待录：[✕ 关闭][开始]；录着：[暂停][✕ 放弃][停止]（mac RecordingHUD 的 ready / recording）。
        _stop.Visibility = _pending ? Visibility.Collapsed : Visibility.Visible;
        _discard.Content = _pending ? "✕ 关闭" : _armed ? "再点一次放弃" : "✕ 放弃";
        _discard.Foreground = _armed ? _discardArmed : _discardNormal;
        AutomationProperties.SetName(_discard, _pending ? "关闭录音控制条" : "放弃这段录音（点两下）");
    }

    /// <summary>✕：待录时关掉控制条；录着时点两下（2 s 内）才放弃，第一下变红「再点一次放弃」（同录屏的控制条）。</summary>
    private void Discard()
    {
        if (_pending)
        {
            AudioHost.Stop();
            return;
        }

        var now = Environment.TickCount64;
        if (_armed && now - _armedAt <= 2000)
        {
            AudioHost.Abandon();
            return;
        }

        _armed = true;
        _armedAt = now;
        UpdatePause();
    }
}
