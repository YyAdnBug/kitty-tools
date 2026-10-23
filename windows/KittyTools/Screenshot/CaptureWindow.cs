// 截图遮罩：每块屏一个无边框 WinUI 窗口，里面是 Win2D CanvasControl。
// 冻结帧按 1 物理像素 = 1 像素画，四角用 DWMWA_WINDOW_CORNER_PREFERENCE=DONOTROUND。
using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Dwm;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal sealed unsafe class CaptureWindow : Window
{
    private readonly FrozenMonitor _monitor;
    private readonly CanvasControl _canvas;
    private readonly bool _verifyMode;
    private readonly double _dipWidth;
    private readonly double _dipHeight;
    private CanvasBitmap? _bitmap;
    private HWND _hwnd;

    public CaptureWindow(FrozenMonitor monitor, double scale, bool verifyMode)
    {
        _monitor = monitor;
        _verifyMode = verifyMode;
        _dipWidth = monitor.Width / scale;
        _dipHeight = monitor.Height / scale;
        Title = "Kitty Tools 截图";
        _canvas = new CanvasControl
        {
            Width = _dipWidth,
            Height = _dipHeight,
        };
        _canvas.Draw += OnDraw;
        _canvas.CreateResources += (sender, e) =>
        {
            _bitmap = CanvasBitmap.CreateFromBytes(
                sender.Device,
                monitor.Pixels,
                monitor.Width,
                monitor.Height,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                96,
                CanvasAlphaMode.Ignore);
            ProbeLog.Write("capture.canvas-resources", ("w", monitor.Width), ("h", monitor.Height));
            _canvas.Invalidate();
        };
        _canvas.Draw += (_, _) => ProbeLog.Write("capture.canvas-draw");
        var root = new Grid
        {
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Blue),
        };
        root.Children.Add(_canvas);
        Content = root;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;

        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);

        // 不让 DWM 把四角磨圆，否则会露出活的桌面。
        var corner = DWM_WINDOW_CORNER_PREFERENCE.DWMWCP_DONOTROUND;
        PInvoke.DwmSetWindowAttribute(_hwnd, DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(DWM_WINDOW_CORNER_PREFERENCE));
    }

    public FrozenMonitor Monitor => _monitor;

    public HWND Hwnd => _hwnd;

    public void ShowAtBounds(bool activate)
    {
        AppWindow.MoveAndResize(_monitor.Bounds);

        // OverlappedPresenter 仍留了一圈 3 px 的不可见缩放边框，客户区比窗口小。
        // 把窗口往左上挪这么多、再补上右边的差额，客户区才正好等于这块屏。
        var client = default(RECT);
        PInvoke.GetClientRect(_hwnd, out client);
        var origin = default(System.Drawing.Point);
        PInvoke.ClientToScreen(_hwnd, ref origin);
        var left = origin.X - _monitor.Bounds.X;
        var top = origin.Y - _monitor.Bounds.Y;
        var right = _monitor.Bounds.Width - (left + (client.right - client.left));
        var bottom = _monitor.Bounds.Height - (top + (client.bottom - client.top));

        // OverlappedPresenter.IsAlwaysOnTop 有时抢不过已经在最上面的普通窗口，显式再钉一次。
        PInvoke.SetWindowPos(
            _hwnd,
            new HWND((IntPtr)(-1)),
            _monitor.Bounds.X - left,
            _monitor.Bounds.Y - top,
            _monitor.Bounds.Width + left + right,
            _monitor.Bounds.Height + top + bottom,
            SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE | SET_WINDOW_POS_FLAGS.SWP_SHOWWINDOW);
        if (activate)
        {
            Activate();
        }
        else
        {
            AppWindow.Show();
        }

        _canvas.Invalidate();

        PInvoke.GetClientRect(_hwnd, out client);
        origin = default;
        PInvoke.ClientToScreen(_hwnd, ref origin);
        ProbeLog.Write(
            "capture.client",
            ("x", origin.X),
            ("y", origin.Y),
            ("w", client.right - client.left),
            ("h", client.bottom - client.top));
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (_bitmap is null)
        {
            return;
        }

        var destination = new Rect(0, 0, _dipWidth, _dipHeight);
        args.DrawingSession.DrawImage(_bitmap, destination);
        if (_verifyMode)
        {
            return;
        }

        // 第 0 批没有选区的交互，画一个居中的示意选区：压暗 45% + 强调色边框。
        var hole = new Rect(_dipWidth * 0.25, _dipHeight * 0.25, _dipWidth * 0.5, _dipHeight * 0.5);
        var dim = Windows.UI.Color.FromArgb(255 * 45 / 100, 0, 0, 0);
        var session = args.DrawingSession;
        session.FillRectangle(new Rect(0, 0, _dipWidth, hole.Y), dim);
        session.FillRectangle(new Rect(0, hole.Bottom, _dipWidth, _dipHeight - hole.Bottom), dim);
        session.FillRectangle(new Rect(0, hole.Y, hole.X, hole.Height), dim);
        session.FillRectangle(new Rect(hole.Right, hole.Y, _dipWidth - hole.Right, hole.Height), dim);
        session.DrawRectangle(hole, Theme.BrandPink, 2);
    }

    public void CloseOverlay()
    {
        _canvas.Draw -= OnDraw;
        _bitmap?.Dispose();
        _bitmap = null;
        Close();
    }
}

internal static unsafe class CaptureHost
{
    private static readonly List<CaptureWindow> OpenWindows = new();

    public static bool IsOpen => OpenWindows.Count > 0;

    public static void Toggle(long hotkeyTicks)
    {
        if (IsOpen)
        {
            CloseAll();
            return;
        }

        Open(hotkeyTicks, verifyMode: false);
    }

    public static void Open(long hotkeyTicks, bool verifyMode)
    {
        var t0 = Stopwatch.GetTimestamp();
        var monitors = ScreenCapture.FreezeAll();
        if (monitors.Count == 0)
        {
            ProbeLog.Write("capture.no-monitors");
            return;
        }

        foreach (var monitor in monitors)
        {
            var window = new CaptureWindow(monitor, monitor.Scale, verifyMode);
            OpenWindows.Add(window);
            window.ShowAtBounds(activate: OpenWindows.Count == 1);
        }

        PInvoke.DwmFlush();
        var visible = Stopwatch.GetTimestamp();
        ProbeLog.Write(
            "capture.visible",
            ("from_hotkey_ms", (visible - hotkeyTicks) * 1000.0 / Stopwatch.Frequency),
            ("freeze_to_visible_ms", (visible - t0) * 1000.0 / Stopwatch.Frequency),
            ("monitors", monitors.Count),
            ("verify", verifyMode));

        foreach (var window in OpenWindows)
        {
            ProbeLog.Write(
                "capture.window",
                ("hwnd", ((IntPtr)window.Hwnd.Value).ToInt64()),
                ("x", window.Monitor.Bounds.X),
                ("y", window.Monitor.Bounds.Y),
                ("w", window.Monitor.Bounds.Width),
                ("h", window.Monitor.Bounds.Height));
        }
    }

    public static void CloseAll()
    {
        foreach (var window in OpenWindows)
        {
            window.CloseOverlay();
        }
        OpenWindows.Clear();
        ProbeLog.Write("capture.closed");
    }

    public static void Collect()
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
    }

    // 第 0 批的像素校验：把同一张冻结帧用 Win2D 画进 CanvasRenderTarget，
    // 再和 BitBlt 拿到的 BGRA 逐像素比（RGBA 三通道；alpha 是补出来的 255）。
    // 这条验证了 Win2D + AOT 的绘制路径和像素对齐；屏幕上的一致性受环境限制，见报告。
    public static void Verify()
    {
        var t0 = Stopwatch.GetTimestamp();
        var monitors = ScreenCapture.FreezeAll();
        var shots = Environment.GetEnvironmentVariable("KITTY_SHOTS_DIR");
        if (string.IsNullOrWhiteSpace(shots))
        {
            shots = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-shots");
        }
        Directory.CreateDirectory(shots);

        foreach (var monitor in monitors)
        {
            var device = CanvasDevice.GetSharedDevice();
            using var bitmap = CanvasBitmap.CreateFromBytes(
                device,
                monitor.Pixels,
                monitor.Width,
                monitor.Height,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                96,
                CanvasAlphaMode.Ignore);

            using var target = new CanvasRenderTarget(device, monitor.Width, monitor.Height, 96);
            using (var session = target.CreateDrawingSession())
            {
                session.DrawImage(bitmap, new Rect(0, 0, monitor.Width, monitor.Height));
            }

            var colors = target.GetPixelColors();
            var mismatched = 0;
            var maxDelta = 0;
            var expected = monitor.Width * monitor.Height;
            if (colors.Length == expected)
            {
                for (var i = 0; i < expected; i++)
                {
                    var color = colors[i];
                    var offset = i * 4;
                    var dr = Math.Abs(color.R - monitor.Pixels[offset + 2]);
                    var dg = Math.Abs(color.G - monitor.Pixels[offset + 1]);
                    var db = Math.Abs(color.B - monitor.Pixels[offset]);
                    var delta = Math.Max(dr, Math.Max(dg, db));
                    if (delta != 0)
                    {
                        mismatched++;
                        maxDelta = Math.Max(maxDelta, delta);
                    }
                }
            }

            var path = System.IO.Path.Combine(shots, $"freeze-{monitor.Width}x{monitor.Height}.png");
            try
            {
                bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                ProbeLog.Write("capture.save-failed", ("type", ex.GetType().Name));
            }

            ProbeLog.Write(
                "capture.verify",
                ("w", monitor.Width),
                ("h", monitor.Height),
                ("scale", monitor.Scale),
                ("pixels", expected),
                ("colors", colors.Length),
                ("mismatched", mismatched),
                ("max_delta", maxDelta),
                ("png", path),
                ("ms", (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency));
        }
    }

    private static void SaveBytes(string path, byte[] pixels, int width, int height)
    {
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            using var bitmap = CanvasBitmap.CreateFromBytes(
                device,
                pixels,
                width,
                height,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                96,
                CanvasAlphaMode.Ignore);
            bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            ProbeLog.Write("capture.save-failed", ("type", ex.GetType().Name));
        }
    }

    public static void SaveFrozenPng(string path)
    {
        var monitors = ScreenCapture.FreezeAll();
        if (monitors.Count == 0)
        {
            return;
        }

        var monitor = monitors[0];
        var device = CanvasDevice.GetSharedDevice();
        using var bitmap = CanvasBitmap.CreateFromBytes(
            device,
            monitor.Pixels,
            monitor.Width,
            monitor.Height,
            Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
            96,
            CanvasAlphaMode.Ignore);
        bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
        ProbeLog.Write("capture.saved", ("path", path), ("w", monitor.Width), ("h", monitor.Height));
    }

    // 屏上逐像素校验：遮罩以「只画冻结帧」的模式铺满每块屏，等一帧后 BitBlt 屏幕，
    // 和冻结帧逐像素比。四角是否被磨圆、DPI 换算对不对，都会在这里露出来。
    public static void ScreenVerify()
    {
        var monitors = ScreenCapture.FreezeAll();
        if (monitors.Count == 0)
        {
            return;
        }

        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        OpenWindows.Clear();
        foreach (var monitor in monitors)
        {
            var window = new CaptureWindow(monitor, monitor.Scale, verifyMode: true);
            OpenWindows.Add(window);
            window.ShowAtBounds(activate: OpenWindows.Count == 1);
        }
        PInvoke.DwmFlush();

        var thread = new Thread(() =>
        {
            Thread.Sleep(900);
            var screen = PInvoke.GetDC(default);
            try
            {
                foreach (var monitor in monitors)
                {
                    var actual = ScreenCapture.CaptureRect(screen, monitor.Bounds);
                    var expected = monitor.Width * monitor.Height;
                    var mismatched = 0;
                    var maxDelta = 0;
                    long sumDelta = 0;
                    var small = 0;
                    var medium = 0;
                    var large = 0;
                    var minX = monitor.Width;
                    var minY = monitor.Height;
                    var maxX = -1;
                    var maxY = -1;
                    for (var i = 0; i < expected; i++)
                    {
                        var offset = i * 4;
                        var db = Math.Abs(actual[offset] - monitor.Pixels[offset]);
                        var dg = Math.Abs(actual[offset + 1] - monitor.Pixels[offset + 1]);
                        var dr = Math.Abs(actual[offset + 2] - monitor.Pixels[offset + 2]);
                        var delta = Math.Max(dr, Math.Max(dg, db));
                        sumDelta += delta;
                        if (delta != 0)
                        {
                            mismatched++;
                            maxDelta = Math.Max(maxDelta, delta);
                            if (delta <= 2) small++;
                            else if (delta <= 16) medium++;
                            else large++;
                            var x = i % monitor.Width;
                            var y = i / monitor.Width;
                            if (x < minX) minX = x;
                            if (x > maxX) maxX = x;
                            if (y < minY) minY = y;
                            if (y > maxY) maxY = y;
                        }
                    }

                    ProbeLog.Write(
                        "capture.screen-verify",
                        ("w", monitor.Width),
                        ("h", monitor.Height),
                        ("scale", monitor.Scale),
                        ("pixels", expected),
                        ("mismatched", mismatched),
                        ("max_delta", maxDelta),
                        ("mean_delta", (double)sumDelta / expected),
                        ("small", small),
                        ("medium", medium),
                        ("large", large),
                        ("bounds", $"{minX},{minY},{maxX},{maxY}"));

                    var shots = Environment.GetEnvironmentVariable("KITTY_SHOTS_DIR");
                    if (!string.IsNullOrWhiteSpace(shots))
                    {
                        Directory.CreateDirectory(shots);
                        SaveBytes(Path.Combine(shots, "verify-frozen.png"), monitor.Pixels, monitor.Width, monitor.Height);
                        SaveBytes(Path.Combine(shots, "verify-actual.png"), actual, monitor.Width, monitor.Height);
                    }

                    // 采样几个点，判断是整体位移还是颜色换算。
                    var sample = new (int X, int Y)[] { (100, 100), (1280, 720), (2500, 1400) };
                    foreach (var (sx, sy) in sample)
                    {
                        var o = ((sy * monitor.Width) + sx) * 4;
                        ProbeLog.Write(
                            "capture.sample",
                            ("x", sx),
                            ("y", sy),
                            ("frozen", $"{monitor.Pixels[o]},{monitor.Pixels[o + 1]},{monitor.Pixels[o + 2]}"),
                            ("actual", $"{actual[o]},{actual[o + 1]},{actual[o + 2]}"));
                    }

                    foreach (var dx in new[] { -1, 0, 1 })
                    {
                        foreach (var dy in new[] { -1, 0, 1 })
                        {
                            long sum = 0;
                            var n = 0;
                            for (var y = 2; y < monitor.Height - 2; y += 17)
                            {
                                for (var x = 2; x < monitor.Width - 2; x += 17)
                                {
                                    var ai = (((y + dy) * monitor.Width) + (x + dx)) * 4;
                                    var fi = ((y * monitor.Width) + x) * 4;
                                    sum += Math.Abs(actual[ai] - monitor.Pixels[fi]);
                                    n++;
                                }
                            }
                            ProbeLog.Write("capture.offset", ("dx", dx), ("dy", dy), ("mean", (double)sum / n));
                        }
                    }
                }
            }
            finally
            {
                PInvoke.ReleaseDC(default, screen);
            }

            dispatcher.TryEnqueue(CloseAll);
        })
        {
            IsBackground = true,
            Name = "KittyTools.ScreenVerify",
        };
        thread.Start();
    }
}
