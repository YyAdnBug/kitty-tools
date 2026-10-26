// 录屏自检用的满屏测试窗口（PLAN-v6 §0 第 3 条）：整块主屏、不透明，画移动色块、滚动文字、帧号，
// 每秒闪一次白、响一声 1 kHz。录屏验证只录这个窗口，不录用户的桌面。
// 闪白跟着提示音的播放位置走（REVIEW R24：两边原来各走各的钟，量出来的音画差没有意义）；
// 右上角 16 格条码是更新计数，SyncProbe 读它查录下来的帧号连不连续。
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
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.UI;

namespace KittyTools;

internal sealed class TestPatternWindow
{
    private static TestPatternWindow? _current;

    private readonly Window _window;
    private readonly Canvas _canvas;
    private MediaPlayer? _player;
    private readonly TextBlock _frame;
    private readonly TextBlock _scroll;
    private readonly TextBlock _clock;
    private readonly List<Rectangle> _blocks = new();
    private readonly Rectangle _flash;
    private readonly Rectangle _marker;
    private readonly Rectangle[] _bits = new Rectangle[BarcodeBits];
    private readonly SolidColorBrush _bitOn = new(Colors.White);
    private readonly SolidColorBrush _bitOff = new(Colors.Black);
    private readonly System.Diagnostics.Stopwatch _clockWatch = System.Diagnostics.Stopwatch.StartNew();
    private int _frameCount;
    private int _renderCount;
    private bool _tonePaused;
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

        // 条码在闪白上面：闪白时照样读得出来。0 位是不透明黑，不是透明。
        for (var index = 0; index < BarcodeBits; index++)
        {
            _bits[index] = new Rectangle { Fill = _bitOff };
            _canvas.Children.Add(_bits[index]);
        }

        _canvas.SizeChanged += (_, _) => LayoutBarcode();

        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += OnRendering;
        _window.Closed += (_, _) =>
        {
            Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= OnRendering;
            _player?.Pause();
        };
    }

    private void OnRendering(object? sender, object args)
    {
        _renderCount++;
        // 闪白每拍都看一次提示音的位置（只改 Opacity，不排版），对齐误差不超过一拍。
        UpdateFlash();
        // Rendering 是 60 Hz；文字和条码按 30 fps 更新，省一半 UI 线程的活。
        _renderToggle = !_renderToggle;
        if (_renderToggle)
        {
            Tick();
        }
    }

    /// <summary>条码的格数和位置（按画布宽高的比例摆，探针按同样的比例读，不用知道 DPI）。</summary>
    public const int BarcodeBits = 16;

    public const double BarcodeLeft = 0.45;

    public const double BarcodeStep = 0.033;

    public const double BarcodeSize = 0.025;

    public const double BarcodeTop = 0.02;

    private void LayoutBarcode()
    {
        var width = _canvas.ActualWidth;
        var height = _canvas.ActualHeight;
        for (var index = 0; index < BarcodeBits; index++)
        {
            _bits[index].Width = width * BarcodeSize;
            _bits[index].Height = width * BarcodeSize;
            Canvas.SetLeft(_bits[index], width * (BarcodeLeft + index * BarcodeStep));
            Canvas.SetTop(_bits[index], height * BarcodeTop);
        }
    }

    /// <summary>提示音每秒前 100 ms 响，闪白就在播放位置落在这 100 ms 里时亮；暂停（静音段）时不闪。</summary>
    private void UpdateFlash()
    {
        var session = _player?.PlaybackSession;
        var playing = !_tonePaused && session is not null &&
            session.PlaybackState == MediaPlaybackState.Playing;
        var lit = playing && session!.Position.TotalMilliseconds % 1000 < 100;
        _flash.Opacity = lit ? 0.85 : 0;
    }

    /// <summary>R24「静音 20 秒后照样同步」：停掉提示音（系统声音回环这时一个包都不出）。</summary>
    public static void PauseTone()
    {
        if (_current is { } current)
        {
            current._tonePaused = true;
            current._player?.Pause();
            Log.Info("test-pattern.tone-paused");
        }
    }

    public static void ResumeTone()
    {
        if (_current is { } current)
        {
            current._tonePaused = false;
            current._player?.Play();
            Log.Info("test-pattern.tone-resumed");
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
            _current.StartPlayer();
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
            current?._player?.Pause();
            current?._window.Close();
        }
        catch
        {
            // 窗口已经没了。
        }
    }

    /// <summary>把测试窗口抢回前台：录屏 HUD 起来后 WinUI 会把后台窗口的渲染降下来。</summary>
    public static void Activate()
    {
        try
        {
            _current?._window.Activate();
        }
        catch
        {
            // 窗口已经没了。
        }
    }

    /// <summary>主屏的物理像素矩形（测试图案是满屏的，录它不会录到别的窗口）。</summary>
    public static void Resize(int width, int height)
    {
        try
        {
            _current?._window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        }
        catch
        {
            // 自检窗口已经关掉就算了。
        }
    }

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
        _clock.Text = $"{_clockWatch.Elapsed.TotalSeconds:F1} s";
        // 色块 / 滚动文字 / 竖条的位移交给 Composition 动画，XAML 每帧只改文字，避免布局把渲染拖到 20 fps。
        for (var index = 0; index < BarcodeBits; index++)
        {
            var on = ((_frameCount >> (BarcodeBits - 1 - index)) & 1) != 0;
            _bits[index].Fill = on ? _bitOn : _bitOff;
        }

        // 记它自己画了多少拍：WGC 收到的帧少时，先看这里是不是测试窗口自己就没在画。
        var second = (int)_clockWatch.Elapsed.TotalSeconds;
        if (second != _lastLoggedSecond)
        {
            _lastLoggedSecond = second;
            Log.Info(
                $"test-pattern.second {second} updates={_frameCount} renders={_renderCount} " +
                $"canvas={width:F0}x{height:F0}");
        }
    }

    private void StartPlayer()
    {
        try
        {
            _player ??= new MediaPlayer
            {
                Source = MediaSource.CreateFromUri(new Uri(EnsureTone())),
                IsLoopingEnabled = true,
            };
            _player.Play();
        }
        catch (Exception ex)
        {
            Log.Warn($"test-pattern.tone {ex.GetType().Name}");
        }
    }

    /// <summary>7 秒的 WAV：每秒前 100 ms 是 1 kHz，剩下静音；循环播放，系统声音回环能采到。</summary>
    private static string EnsureTone()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-test-1khz.wav");
        if (File.Exists(path))
        {
            return path;
        }

        const int rate = 48_000;
        const int seconds = 7;
        var samples = rate * seconds;
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8.ToArray());
        writer.Write(36 + samples * 2);
        writer.Write("WAVEfmt "u8.ToArray());
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8.ToArray());
        writer.Write(samples * 2);
        for (var index = 0; index < samples; index++)
        {
            var inSecond = index % rate;
            var value = inSecond < rate / 10
                ? (short)(Math.Sin(2 * Math.PI * 1000 * inSecond / rate) * 16_000)
                : (short)0;
            writer.Write(value);
        }

        return path;
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
}
