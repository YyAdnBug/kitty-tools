// REVIEW R24 音画同步量测（--sync-probe=<mp4>）：测试图案（TestPatternWindow）每秒前 100 ms 闪白、
// 同时响 1 kHz，两边都按提示音的播放位置走。这里从视频里找每一次闪白的起点、从音轨里找每一声的起点
// （AudioWavProbe），逐个配对报音画差；再在第 1 / 30 / 最后一秒连着抽 10 帧读条码，看画面是不是一直在动。
// 视频按帧取样，单个音画差带着最多一帧的量化误差（30 fps 是 33 ms）；量同步时录 --record-fps=60。
// 结果只写日志（grep `sync.`），不弹窗。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;

namespace KittyTools;

internal static class SyncProbe
{
    /// <summary>闪白亮 100 ms，按 1/15 s 一步粗扫不会漏；找到亮的再按 1/60 s 往回找起点。</summary>
    private const double Coarse = 1.0 / 15;

    private const double Fine = 1.0 / 60;

    public static async Task RunAsync(string path)
    {
        try
        {
            var started = Environment.TickCount64;
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            var duration = clip.OriginalDuration.TotalSeconds;
            var properties = clip.GetVideoEncodingProperties();
            var fps = properties.FrameRate.Denominator == 0
                ? 30.0
                : properties.FrameRate.Numerator / (double)properties.FrameRate.Denominator;
            var aspect = properties.Width == 0 ? 9.0 / 16 : properties.Height / (double)properties.Width;

            var flashes = await FlashOnsetsAsync(composition, duration);
            var audio = await AudioWavProbe.CheckAsync(path);
            var pairs = AvSync.PairUp(flashes, audio.Onsets);
            foreach (var pair in pairs)
            {
                Log.Info($"sync.pair flash={pair.Flash:F3}s beep={pair.Beep:F3}s diff={pair.Diff * 1000:F0}ms");
            }

            var summary = AvSync.Summarize(pairs, flashes.Count, audio.Onsets.Count);
            var mean = pairs.Count == 0 ? 0 : pairs.Average(pair => pair.Diff);
            var afterSilence = summary.AfterGap is { } gap ? $"{gap * 1000:F0}ms" : "-";
            Log.Info(
                $"sync.summary pairs={summary.Pairs} flashes={summary.Flashes} beeps={summary.Beeps} " +
                $"first={summary.First * 1000:F0}ms last={summary.Last * 1000:F0}ms afterSilence={afterSilence} " +
                $"mean={mean * 1000:F0}ms maxAbs={summary.MaxAbs * 1000:F0}ms fps={fps:F1} passed={summary.Passed}");

            foreach (var at in new[] { 1.0, 30.0, duration - 1.5 })
            {
                if (at < 0 || at + 10 / fps > duration)
                {
                    continue;
                }

                var numbers = await BarcodesAsync(composition, at, 10, fps, aspect);
                Log.Info(
                    $"sync.frames at={at:F1}s numbers={string.Join(',', numbers)} " +
                    $"continuous={AvSync.Continuous(numbers)}");
            }

            Log.Info($"sync.done duration={duration:F1}s probeMs={Environment.TickCount64 - started}");
        }
        catch (Exception ex)
        {
            Log.Warn($"sync.failed {ex.GetType().Name} 0x{ex.HResult:X8}");
        }
    }

    private static async Task<List<double>> FlashOnsetsAsync(MediaComposition composition, double duration)
    {
        var onsets = new List<double>();
        var lit = false;
        var lastDark = 0.0;
        for (var time = 0.0; time <= duration; time += Coarse)
        {
            var bright = await IsBrightAsync(composition, time);
            if (bright && !lit)
            {
                var onset = time;
                for (var back = time - Fine; back > lastDark; back -= Fine)
                {
                    if (!await IsBrightAsync(composition, back))
                    {
                        break;
                    }

                    onset = back;
                }

                onsets.Add(onset);
            }

            if (!bright)
            {
                lastDark = time;
            }

            lit = bright;
        }

        Log.Info($"sync.video flashes={onsets.Count} first={(onsets.Count > 0 ? onsets[0] : -1):F3}s");
        return onsets;
    }

    /// <summary>整帧平均亮度 > 170 算闪白（0.85 的白盖在深色画面上，平时不到 60）。</summary>
    private static async Task<bool> IsBrightAsync(MediaComposition composition, double time)
    {
        var (pixels, width, height) = await FrameAsync(composition, time, 160, 90);
        double sum = 0;
        for (var index = 0; index < pixels.Length; index += 4)
        {
            sum += Luma(pixels, index);
        }

        return sum / (width * height) > 170;
    }

    /// <summary>从 <paramref name="at"/> 起连着 <paramref name="count"/> 帧，读测试图案右上角的条码。</summary>
    private static async Task<List<int>> BarcodesAsync(
        MediaComposition composition, double at, int count, double fps, double aspect)
    {
        const int width = 960;
        var height = Math.Max(1, (int)Math.Round(width * aspect));
        var numbers = new List<int>();
        for (var step = 0; step < count; step++)
        {
            // 取帧中间的时间点，免得 NearestFrame 在两帧的边界上来回跳。
            var (pixels, actualWidth, actualHeight) = await FrameAsync(
                composition, at + (step + 0.5) / fps, width, height);
            var size = actualWidth * TestPatternWindow.BarcodeSize;
            var centerY = (int)(actualHeight * TestPatternWindow.BarcodeTop + size / 2);
            var number = 0;
            for (var bit = 0; bit < TestPatternWindow.BarcodeBits; bit++)
            {
                var centerX = (int)(actualWidth *
                    (TestPatternWindow.BarcodeLeft + bit * TestPatternWindow.BarcodeStep) + size / 2);
                var on = AverageLuma(pixels, actualWidth, actualHeight, centerX, centerY) > 128;
                number = (number << 1) | (on ? 1 : 0);
            }

            numbers.Add(number);
        }

        return numbers;
    }

    private static double AverageLuma(byte[] pixels, int width, int height, int centerX, int centerY)
    {
        double sum = 0;
        var count = 0;
        for (var y = centerY - 1; y <= centerY + 1; y++)
        {
            for (var x = centerX - 1; x <= centerX + 1; x++)
            {
                if (x < 0 || y < 0 || x >= width || y >= height)
                {
                    continue;
                }

                sum += Luma(pixels, (y * width + x) * 4);
                count++;
            }
        }

        return count == 0 ? 0 : sum / count;
    }

    private static double Luma(byte[] pixels, int index) =>
        0.114 * pixels[index] + 0.587 * pixels[index + 1] + 0.299 * pixels[index + 2];

    private static async Task<(byte[] Pixels, int Width, int Height)> FrameAsync(
        MediaComposition composition, double time, int width, int height)
    {
        using var image = await composition.GetThumbnailAsync(
            TimeSpan.FromSeconds(Math.Max(0, time)), width, height, VideoFramePrecision.NearestFrame);
        image.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(image);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
        var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyToBuffer(bytes.AsBuffer());
        return (bytes, bitmap.PixelWidth, bitmap.PixelHeight);
    }
}
