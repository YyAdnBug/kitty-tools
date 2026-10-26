// 录屏自检用的满屏测试窗口（PLAN-v6 §0 第 3 条）：整块主屏、不透明，画移动色块、滚动文字、帧号，
// 每秒闪一次白、响一声 1 kHz。录屏验证只录这个窗口，不录用户的桌面。
// 除了 30 fps 的 XAML 更新，再加一条 Composition 动画横条：它在合成线程上跑 60 fps，
// 保证 WGC 一直有新帧可抓（XAML 布局慢了也不会把录制降到十几帧）。
// 由 --test-pattern 打开；--record-test=<秒> 会开窗、录 N 秒、关窗。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace KittyTools;

internal sealed class TestPatternWindow
{
    private static TestPatternWindow? _current;

    private readonly Window _window;
    private readonly Canvas _canvas;
    private readonly DispatcherTimer _beep;
    private readonly TextBlock _frame;
    private readonly TextBlock _scroll;
    private readonly TextBlock _clock;
    private readonly List<Rectangle> _blocks = new();
    private readonly Rectangle _flash;
    private readonly Rectangle _marker;
    private int _frameCount;
    private int _lastLoggedSecond = -1;
    private bool _renderToggle;

    private TestPatternWindow()
    {
        _window = new Window { Title = "Kitty Tools 录屏测试图案" };
        _canvas = new Canvas { Background = new SolidColorBrush(Colors.Black) };
        _window.Content = _canvas;

        _frame = new TextBlock
        {
            Text = "frame 0",
            FontSize = 96,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            Foreground = new SolidColorBrush(Colors.White),
        };
        Canvas.SetLeft(_frame, 80);
        Canvas.SetTop(_frame, 70);
        _canvas.Children.Add(_frame);

        _scroll = new TextBlock
        {
            Text = "KITTY TOOLS — SCROLLING TEST PATTERN — 0123456789 — ",
            FontSize = 42,
            Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 210, 120)),
        };
        Canvas.SetTop(_scroll, 230);
        _canvas.Children.Add(_scroll);

        _clock = new TextBlock
        {
            Text = "0.0 s",
            FontSize = 40,
            Foreground = new SolidColorBrush(Color.FromArgb(255, 160, 220, 255)),
        };
        Canvas.SetLeft(_clock, 80);
        Canvas.SetTop(_clock, 330);
        _canvas.Children.Add(_clock);

        var colors = new[]
        {
            Colors.DeepSkyBlue, Colors.Orange, Colors.MediumSpringGreen, Colors.Violet, Colors.Gold,
        };
        for (var index = 0; index < colors.Length; index++)
        {
            var block = new Rectangle
            {
                Width = 180 + index * 30,
                Height = 140 + index * 20,
                Fill = new SolidColorBrush(colors[index]),
            };
            Canvas.SetTop(block, 460 + index * 130);
            _canvas.Children.Add(block);
            _blocks.Add(block);
        }

        _marker = new Rectangle
        {
            Width = 14,
            Height = 320,
            Fill = new SolidColorBrush(Colors.White),
        };
        Canvas.SetTop(_marker, 430);
        _canvas.Children.Add(_marker);

        // 合成线程上的横条：60 fps 一直动，WGC 才不会因为 XAML 只画了 20 帧而少收帧。
        var sweep = new Rectangle
        {
            Width = 260,
            Height = 18,
            Fill = new SolidColorBrush(Color.FromArgb(255, 80, 255, 160)),
        };
        Canvas.SetTop(sweep, 900);
        Canvas.SetLeft(sweep, 0);
        _canvas.Children.Add(sweep);
        _canvas.Loaded += (_, _) =>
        {
            var visual = ElementCompositionPreview.GetElementVisual(sweep);
            var composer = visual.Compositor;
            var animation = composer.CreateVector3KeyFrameAnimation();
            animation.InsertKeyFrame(0, new System.Numerics.Vector3(-300, 900, 0));
            animation.InsertKeyFrame(1, new System.Numerics.Vector3(2800, 900, 0));
            animation.Duration = TimeSpan.FromSeconds(2.2);
            animation.IterationBehavior = AnimationIterationBehavior.Forever;
            visual.StartAnimation("Offset", animation);
        };

        _flash = new Rectangle
        {
            Width = 10000,
            Height = 10000,
            Fill = new SolidColorBrush(Colors.White),
            Opacity = 0,
        };
        Canvas.SetLeft(_flash, 0);
        Canvas.SetTop(_flash, 0);
        _canvas.Children.Add(_flash);

        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += OnRendering;
        _beep = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _beep.Tick += (_, _) =>
        {
            try
            {
                Beep(1000, 80);
            }
            catch
            {
                // 没有蜂鸣器就算了；麦克风 / 系统声音用别的方式验。
            }
        };
        _window.Closed += (_, _) =>
        {
            _beep.Stop();
            Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= OnRendering;
        };
    }

    private void OnRendering(object? sender, object args)
    {
        // Rendering 是 60 Hz；测试图案按 30 fps 更新，省一半 UI 线程的活。
        _renderToggle = !_renderToggle;
        if (_renderToggle)
        {
            Tick();
        }
    }

    public static void Show()
    {
        if (_current is not null)
        {
            _current._window.Activate();
            return;
        }

        try
        {
            _current = new TestPatternWindow();
            var window = _current._window;
            var bounds = PrimaryBounds();
            if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.SetBorderAndTitleBar(false, false);
                presenter.IsResizable = false;
                presenter.IsMaximizable = false;
                presenter.IsAlwaysOnTop = true;
            }

            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(0, 0, bounds.Width, bounds.Height));
            window.Activate();
            _current._beep.Start();
            Log.Info("test-pattern.show");
        }
        catch (Exception ex)
        {
            Log.Error("test-pattern.failed", ex);
            _current = null;
        }
    }

    public static void Close()
    {
        var current = _current;
        _current = null;
        try
        {
            current?._beep.Stop();
            current?._window.Close();
        }
        catch
        {
            // 窗口已经没了。
        }
    }

    /// <summary>主屏的物理像素矩形（测试图案是满屏的，录它不会录到别的窗口）。</summary>
    public static PixelBounds PrimaryBounds()
    {
        var width = GetSystemMetrics(0);
        var height = GetSystemMetrics(1);
        return new PixelBounds(0, 0, Math.Max(800, width), Math.Max(600, height));
    }

    /// <summary>测试窗口的 HWND（录屏验证录这个窗口本身，不录整个桌面）。</summary>
    public static IntPtr Handle
    {
        get
        {
            try
            {
                return _current is null
                    ? IntPtr.Zero
                    : WinRT.Interop.WindowNative.GetWindowHandle(_current._window);
            }
            catch
            {
                return IntPtr.Zero;
            }
        }
    }

    private void Tick()
    {
        _frameCount++;
        var width = Math.Max(800, _canvas.ActualWidth);
        var height = Math.Max(600, _canvas.ActualHeight);
        _frame.Text = $"frame {_frameCount}";
        _clock.Text = $"{(double)_frameCount / 60:F1} s";
        // 色块 / 滚动文字 / 竖条的位移交给 Composition 动画，XAML 每帧只改文字，避免布局把渲染拖到 20 fps。
        _flash.Opacity = _frameCount % 60 < 6 ? 0.85 : 0;

        var second = _frameCount / 60;
        if (second != _lastLoggedSecond)
        {
            _lastLoggedSecond = second;
            Log.Info($"test-pattern.second {second} frames={_frameCount} canvas={width:F0}x{height:F0}");
        }
    }

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Beep(uint frequency, uint duration);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
}
