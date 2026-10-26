// 轻提示动画逐帧自检（PLAN-v7 第 3 批验收）：`--notice-anim-test=<目录>`。
// 用 WGC 只抓轻提示自己的窗口（GraphicsCaptureItem.CreateForWindow，带透明，不碰桌面别的东西），
// 依次放：长出来 → 原地换成长内容 → 出错（换语气 + 抖）→ 停留到点缩回去。
// 每帧量胶囊的宽度和左边缘（不透明那几行正中一行里 alpha > 128 的像素），另记每段动画期间 XAML 排了几次版
// （只动 Composition 几何时应该接近 0；以前每 16 ms 改一次 Width，一段动画要排二三十次）。
// 报告写到 <目录>\report.md，隔几帧存一张 PNG（透明处铺棋盘格）；跑完就退。
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Windows.Graphics.Capture;
using Windows.Graphics.Imaging;

namespace KittyTools;

internal static class NoticeAnimationProbe
{
    public const string ArgumentPrefix = "--notice-anim-test";

    /// <summary>每段动画从 Show 之后多久开始数排版、数到多久（第一下的量宽度不算）。</summary>
    private const int LayoutWindowStartMs = 30;

    private const int LayoutWindowEndMs = 480;

    /// <summary>最多存多少张 PNG。</summary>
    private const int MaxSavedFrames = 90;

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
            path = Path.Combine(Path.GetTempPath(), "kitty-notice-anim");
        }

        return Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var frames = new ConcurrentQueue<Frame>();
        var phases = new List<Phase>();
        var watch = new Stopwatch();
        D3DContext? context = null;
        CanvasDevice? canvas = null;
        Direct3D11CaptureFramePool? pool = null;
        GraphicsCaptureSession? session = null;
        var exitCode = 1;
        try
        {
            // 先放一条，把轻提示窗口建出来、显示着，WGC 才有窗口可抓。
            NoticeHost.Show("轻提示自检", "准备", NoticeTone.Normal);
            var handle = NoticeHost.HandleForProbe;
            if (handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("notice window missing");
            }

            context = D3DContext.Create(out var error) ?? throw new InvalidOperationException("d3d " + error);
            canvas = CanvasDevice.CreateFromDirect3D11Device(context.WinRt);
            var item = WgcInterop.ForWindow(handle)
                       ?? throw new InvalidOperationException("capture item missing");
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                context.WinRt, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
            var device = canvas;
            var kept = 0;
            pool.FrameArrived += (sender, _) =>
            {
                try
                {
                    using var frame = sender.TryGetNextFrame();
                    if (frame is null)
                    {
                        return;
                    }

                    using var surface = frame.Surface;
                    using var bitmap = CanvasBitmap.CreateFromDirect3D11Surface(device, surface);
                    var width = (int)bitmap.SizeInPixels.Width;
                    var height = (int)bitmap.SizeInPixels.Height;
                    var pixels = bitmap.GetPixelBytes();
                    var (pill, left) = MeasurePill(pixels, width, height);
                    var keep = frames.Count % 3 == 0 && Interlocked.Increment(ref kept) <= MaxSavedFrames;
                    frames.Enqueue(new Frame(watch.Elapsed.TotalMilliseconds, pill, left, width, height,
                        keep ? pixels : null));
                }
                catch (Exception ex)
                {
                    Log.Warn($"notice-anim.frame-failed 0x{ex.HResult:X8}");
                }
            };
            session = pool.CreateCaptureSession(item);
            try
            {
                session.IsCursorCaptureEnabled = false;
                session.IsBorderRequired = false;
            }
            catch
            {
                // 老系统没有这两个属性。
            }

            watch.Start();
            session.StartCapture();

            // 第一条停留 2.0 s + 退场约 0.5 s：先录到它缩回去。
            await Task.Delay(2700);
            await Step(watch, phases, "长出来", () => NoticeHost.Show("已复制", string.Empty, NoticeTone.Normal), 900);
            await Step(watch, phases, "原地换长内容", () => NoticeHost.Show(
                "已复制", "一段比较长的说明文字，用来看胶囊只动宽度、内容直接换", NoticeTone.Normal), 900);
            await Step(watch, phases, "出错（换语气 + 抖）", () => NoticeHost.Show(
                "没能粘贴", "剪贴板被别的程序占着", NoticeTone.Error), 3000);
            // 出错停留 3.0 s，之后退内容 0.12 s + 缩回 0.34 s。
            phases.Add(new Phase("缩回（停留到点）", phases[^1].StartMs + 3000, 0));
            await Task.Delay(900);
            watch.Stop();
            session.Dispose();
            session = null;
            await Task.Delay(100);

            var list = frames.ToList();
            await SaveFramesAsync(directory, list);
            WriteReport(directory, list, phases);
            Log.Info($"notice-anim frames={list.Count} dir={directory}");
            exitCode = list.Count > 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            Log.Error("notice-anim.failed", ex);
        }
        finally
        {
            session?.Dispose();
            pool?.Dispose();
            canvas?.Dispose();
            context?.Dispose();
            Environment.Exit(exitCode);
        }
    }

    /// <summary>放一条提示，数它动画那一段里 XAML 排了几次版，然后等 holdMs。</summary>
    private static async Task Step(
        Stopwatch watch, List<Phase> phases, string name, Action show, int holdMs)
    {
        var start = watch.Elapsed.TotalMilliseconds;
        show();
        await Task.Delay(LayoutWindowStartMs);
        var before = NoticeHost.LayoutPassesForProbe;
        await Task.Delay(LayoutWindowEndMs - LayoutWindowStartMs);
        phases.Add(new Phase(name, start, NoticeHost.LayoutPassesForProbe - before));
        await Task.Delay(Math.Max(0, holdMs - LayoutWindowEndMs));
    }

    /// <summary>不透明的那几行里取正中一行，数 alpha > 128 的像素：胶囊的宽度和左边缘（物理像素）。</summary>
    private static (int Width, int Left) MeasurePill(byte[] bgra, int width, int height)
    {
        int top = -1, bottom = -1;
        for (var y = 0; y < height; y++)
        {
            var row = y * width * 4;
            for (var x = 0; x < width; x++)
            {
                if (bgra[row + x * 4 + 3] > 128)
                {
                    top = top < 0 ? y : top;
                    bottom = y;
                    break;
                }
            }
        }

        if (top < 0)
        {
            return (0, -1);
        }

        var middle = (top + bottom) / 2 * width * 4;
        int first = -1, last = -1;
        for (var x = 0; x < width; x++)
        {
            if (bgra[middle + x * 4 + 3] > 128)
            {
                first = first < 0 ? x : first;
                last = x;
            }
        }

        return first < 0 ? (0, -1) : (last - first + 1, first);
    }

    private static async Task SaveFramesAsync(string directory, List<Frame> frames)
    {
        var folder = Path.Combine(directory, "frames");
        Directory.CreateDirectory(folder);
        foreach (var frame in frames.Where(frame => frame.Pixels is not null))
        {
            var pixels = OverCheckerboard(frame.Pixels!, frame.ImageWidth, frame.ImageHeight);
            var path = Path.Combine(folder, $"t{frame.Ms:00000}.png");
            using var stream = File.Create(path);
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
            encoder.SetPixelData(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Ignore,
                (uint)frame.ImageWidth,
                (uint)frame.ImageHeight,
                96,
                96,
                pixels);
            await encoder.FlushAsync();
        }
    }

    /// <summary>预乘 alpha 的 BGRA 叠到 8 px 的浅灰棋盘格上（透明的地方看得出来）。</summary>
    private static byte[] OverCheckerboard(byte[] bgra, int width, int height)
    {
        var result = new byte[bgra.Length];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var index = (y * width + x) * 4;
                var background = ((x / 8) + (y / 8)) % 2 == 0 ? 236 : 210;
                var inverse = 255 - bgra[index + 3];
                for (var channel = 0; channel < 3; channel++)
                {
                    result[index + channel] = (byte)Math.Min(255, bgra[index + channel] + background * inverse / 255);
                }

                result[index + 3] = 255;
            }
        }

        return result;
    }

    private static void WriteReport(string directory, List<Frame> frames, List<Phase> phases)
    {
        var report = new StringBuilder();
        report.AppendLine("# 轻提示动画逐帧自检（PLAN-v7 第 3 批）");
        report.AppendLine();
        report.AppendLine($"- 帧数：{frames.Count}（WGC 只抓轻提示窗口；宽度 / 左边缘是物理像素）");
        report.AppendLine($"- 排版次数：每段从 Show 后 {LayoutWindowStartMs} ms 数到 {LayoutWindowEndMs} ms（Show 那一下量宽度的排版不算）");
        report.AppendLine();
        report.AppendLine("| 段 | 开始 (ms) | 动画期间排版次数 | 起始宽 | 最大宽 | 最后宽 | 左边缘范围 |");
        report.AppendLine("|---|---|---|---|---|---|---|");
        for (var index = 0; index < phases.Count; index++)
        {
            var phase = phases[index];
            var end = index + 1 < phases.Count ? phases[index + 1].StartMs : double.MaxValue;
            var slice = frames.Where(frame => frame.Ms >= phase.StartMs && frame.Ms < end && frame.Width > 0).ToList();
            if (slice.Count == 0)
            {
                report.AppendLine($"| {phase.Name} | {phase.StartMs:F0} | {phase.LayoutPasses} | – | – | – | – |");
                continue;
            }

            report.AppendLine(
                $"| {phase.Name} | {phase.StartMs:F0} | {phase.LayoutPasses} | {slice[0].Width} | {slice.Max(frame => frame.Width)} | " +
                $"{slice[^1].Width} | {slice.Min(frame => frame.Left)}–{slice.Max(frame => frame.Left)} |");
        }

        report.AppendLine();
        report.AppendLine("| t (ms) | 胶囊宽 | 左边缘 |");
        report.AppendLine("|---|---|---|");
        foreach (var frame in frames)
        {
            report.AppendLine($"| {frame.Ms:F0} | {frame.Width} | {frame.Left} |");
        }

        File.WriteAllText(Path.Combine(directory, "report.md"), report.ToString(), new UTF8Encoding(false));
    }

    private sealed record Frame(double Ms, int Width, int Left, int ImageWidth, int ImageHeight, byte[]? Pixels);

    private sealed record Phase(string Name, double StartMs, int LayoutPasses);
}
