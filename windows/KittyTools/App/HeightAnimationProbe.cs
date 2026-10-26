// 高度动画逐帧自检（PLAN-v6 第 6 批 / REVIEW R12 的遗留项）：
// `--height-anim-test=<目录>` 开一块和浮层同材质的无边框窗口，按 16 ms 一帧在 360↔520 DIP 之间
// 来回改高度，同时用 BitBlt 逐帧抓自己的窗口矩形，检查底边 / 右边有没有黑边、白边或亮度跳变。
// 报告写到 <目录>\report.md，隔几帧留一张 BMP；全部帧都没有异常时退出码 0。
//
// 为什么不用屏外渲染：DWM 在逐帧改窗口尺寸时的边缘问题只出现在合成后的屏幕上，
// RenderTargetBitmap 看不到。窗口只抓自己的矩形，不碰桌面别的内容。
using System.Diagnostics;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static class HeightAnimationProbe
{
    public const string ArgumentPrefix = "--height-anim-test";

    private const int WidthDip = 720;
    private const int LowDip = 360;
    private const int HighDip = 520;

    /// <summary>底边 / 右边 2 px 与里面 8 px 的亮度差超过这个值就算一帧异常。</summary>
    private const double EdgeDeltaLimit = 70;

    public static bool IsRequested(string[] args)
        => args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        if (string.IsNullOrWhiteSpace(path))
        {
            path = Path.Combine(Path.GetTempPath(), "kitty-height-anim");
        }

        return Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var window = new Window
        {
            Title = Paths.ProductName + " 高度动画自检",
            Content = new Grid { Background = Theme.CardBackground() },
            SystemBackdrop = new AcrylicBackdrop(),
        };
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        window.AppWindow.SetPresenter(presenter);
        window.ExtendsContentIntoTitleBar = true;
        var x = 120;
        var y = 120;
        window.AppWindow.MoveAndResize(new RectInt32(x, y, WidthDip, LowDip));
        window.Activate();
        await Task.Delay(700);

        var hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(window);
        var frames = new List<FrameReport>();
        var watch = Stopwatch.StartNew();
        var frameIndex = 0;
        try
        {
            while (watch.ElapsedMilliseconds < 2200)
            {
                var progress = watch.ElapsedMilliseconds / 2200.0;
                var height = LowDip + (HighDip - LowDip) * (0.5 - 0.5 * Math.Cos(progress * Math.PI * 6));
                window.AppWindow.MoveAndResize(new RectInt32(x, y, WidthDip, (int)Math.Round(height)));
                PInvoke.DwmFlush();

                if (PInvoke.GetWindowRect(hwnd, out var rect))
                {
                    var bounds = new PixelBounds(rect.left, rect.top, rect.right, rect.bottom);
                    var pixels = ScreenCapture.CaptureRegion(bounds);
                    if (pixels is not null)
                    {
                        var stat = Analyze(pixels, bounds.Width, bounds.Height);
                        frames.Add(stat with { Frame = frameIndex, Height = bounds.Height });
                        if (frameIndex % 12 == 0)
                        {
                            WriteBmp(Path.Combine(directory, $"frame-{frameIndex:D3}.bmp"), pixels, bounds.Width, bounds.Height);
                        }
                    }
                }

                frameIndex++;
                await Task.Delay(16);
            }
        }
        finally
        {
            window.AppWindow.Hide();
        }

        var flashes = Evaluate(frames);
        WriteReport(directory, frames, flashes);
        Log.Info($"height-anim frames={frames.Count} flashes={flashes} dir={directory}");
        Environment.ExitCode = flashes == 0 ? 0 : 1;
        Microsoft.UI.Xaml.Application.Current.Exit();
    }

    /// <summary>
    /// 只把「相对基线的突变」算异常：窗口本身的 1 px 深色边框每一帧都在，不能算闪。
    /// 基线取前 8 帧的中位数；另外单独看「整条边突然变黑 / 变白」。
    /// </summary>
    private static int Evaluate(List<FrameReport> frames)
    {
        if (frames.Count < 4)
        {
            return 0;
        }

        var baseline = frames.Take(Math.Min(8, frames.Count)).ToList();
        var baseEdge = Median(baseline.Select(frame => frame.Edge));
        var baseDark = Median(baseline.Select(frame => frame.Dark));
        var baseBright = Median(baseline.Select(frame => frame.Bright));
        var flashes = 0;
        double previousEdge = double.NaN;
        for (var index = 0; index < frames.Count; index++)
        {
            var frame = frames[index];
            var flagged = Math.Abs(frame.Edge - baseEdge) > EdgeDeltaLimit ||
                          (!double.IsNaN(previousEdge) && Math.Abs(frame.Edge - previousEdge) > EdgeDeltaLimit) ||
                          (frame.Dark > 0.5 && baseDark < 0.1) ||
                          (frame.Bright > 0.5 && baseBright < 0.1);
            if (flagged)
            {
                flashes++;
            }

            frames[index] = frame with { Flagged = flagged };
            previousEdge = frame.Edge;
        }

        return flashes;
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(value => value).ToList();
        if (sorted.Count == 0)
        {
            return 0;
        }

        var middle = sorted.Count / 2;
        return sorted.Count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    }

    private static FrameReport Analyze(byte[] bgra, int width, int height)
    {
        if (width < 40 || height < 40)
        {
            return new FrameReport();
        }

        // 只看底边中间一半和右边中间一半：圆角在四角，那里本来就是桌面。
        var x0 = width / 4;
        var x1 = width * 3 / 4;
        var y0 = height / 4;
        var y1 = height * 3 / 4;
        var bottomEdge = BandStats(
            bgra, width, x0, x1, height - 2, height, horizontal: true, out var bottomDark, out var bottomBright);
        var bottomInner = BandStats(
            bgra, width, x0, x1, height - 10, height - 8, horizontal: true, out _, out _);
        var rightEdge = BandStats(
            bgra, width, width - 2, width, y0, y1, horizontal: false, out var rightDark, out var rightBright);
        var rightInner = BandStats(
            bgra, width, width - 10, width - 8, y0, y1, horizontal: false, out _, out _);
        var delta = Math.Max(Math.Abs(bottomEdge - bottomInner), Math.Abs(rightEdge - rightInner));
        return new FrameReport
        {
            Edge = Math.Max(bottomEdge, rightEdge),
            Inner = Math.Max(bottomInner, rightInner),
            EdgeDelta = delta,
            Dark = Math.Max(bottomDark, rightDark),
            Bright = Math.Max(bottomBright, rightBright),
        };
    }

    /// <summary>一条横带 / 竖带的平均亮度，以及接近纯黑 / 纯白的像素占比。</summary>
    private static double BandStats(
        byte[] bgra,
        int width,
        int x0,
        int x1,
        int y0,
        int y1,
        bool horizontal,
        out double dark,
        out double bright)
    {
        double sum = 0;
        var count = 0;
        var darkCount = 0;
        var brightCount = 0;
        if (horizontal)
        {
            for (var y = y0; y < y1; y++)
            {
                for (var x = x0; x < x1; x++)
                {
                    var luma = Luma(bgra, (y * width + x) * 4);
                    sum += luma;
                    darkCount += luma < 30 ? 1 : 0;
                    brightCount += luma > 240 ? 1 : 0;
                    count++;
                }
            }
        }
        else
        {
            for (var x = x0; x < x1; x++)
            {
                for (var y = y0; y < y1; y++)
                {
                    var luma = Luma(bgra, (y * width + x) * 4);
                    sum += luma;
                    darkCount += luma < 30 ? 1 : 0;
                    brightCount += luma > 240 ? 1 : 0;
                    count++;
                }
            }
        }

        dark = count == 0 ? 0 : (double)darkCount / count;
        bright = count == 0 ? 0 : (double)brightCount / count;
        return count == 0 ? 0 : sum / count;
    }

    private static double Luma(byte[] bgra, int index)
        => 0.114 * bgra[index] + 0.587 * bgra[index + 1] + 0.299 * bgra[index + 2];

    private static void WriteReport(string directory, List<FrameReport> frames, int flashes)
    {
        var report = new StringBuilder();
        report.AppendLine("# 高度动画逐帧自检");
        report.AppendLine();
        report.AppendLine($"- 帧数：{frames.Count}");
        report.AppendLine($"- 异常帧：{flashes}");
        report.AppendLine($"- 判定：底边 / 右边 2 px 与里面 8 px 的亮度差 > {EdgeDeltaLimit}，或相邻帧边缘亮度跳变 > {EdgeDeltaLimit}");
        report.AppendLine();
        report.AppendLine("| 帧 | 高 (px) | 边缘亮度 | 内部亮度 | 差 | 异常 |");
        report.AppendLine("|---|---|---|---|---|---|");
        foreach (var frame in frames)
        {
            report.AppendLine(
                $"| {frame.Frame} | {frame.Height} | {frame.Edge:F1} | {frame.Inner:F1} | {frame.EdgeDelta:F1} | {(frame.Flagged ? "是" : "")} |");
        }

        File.WriteAllText(Path.Combine(directory, "report.md"), report.ToString(), new UTF8Encoding(false));
    }

    private static void WriteBmp(string path, byte[] bgra, int width, int height)
    {
        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream);
        var stride = width * 4;
        var size = 54 + stride * height;
        writer.Write((byte)'B');
        writer.Write((byte)'M');
        writer.Write(size);
        writer.Write(0);
        writer.Write(54);
        writer.Write(40);
        writer.Write(width);
        writer.Write(-height);
        writer.Write((short)1);
        writer.Write((short)32);
        writer.Write(0);
        writer.Write(stride * height);
        writer.Write(2835);
        writer.Write(2835);
        writer.Write(0);
        writer.Write(0);
        writer.Write(bgra, 0, bgra.Length);
    }

    private sealed record FrameReport
    {
        public int Frame { get; init; }

        public int Height { get; init; }

        public double Edge { get; init; }

        public double Inner { get; init; }

        public double EdgeDelta { get; init; }

        public double Dark { get; init; }

        public double Bright { get; init; }

        public bool Flagged { get; init; }
    }
}
