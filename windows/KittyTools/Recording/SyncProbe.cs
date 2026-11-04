// REVIEW R24 音画同步量测（--sync-probe=<mp4>）：测试图案（TestPatternWindow）每秒前 100 ms 闪白、
// 同时响 1 kHz，两边都按提示音的播放位置走。这里从视频里找每一次闪白的起点、从音轨里找每一声的起点
// （AudioWavProbe），逐个配对报音画差；再在第 1 / 30 / 最后一秒连着抽 10 帧读条码，看画面是不是一直在动。
// 视频按帧取样，单个音画差带着最多一帧的量化误差（30 fps 是 33 ms）；量同步时录 --record-fps=60。
// 结果只写日志（grep `sync.`），不弹窗。
// 2026-11-04（PLAN-v11 第 7 批）：闪白和条码改成逐帧解码（VideoFrames，按顺序解每一帧、用它自己的时间戳），不再用
// MediaComposition.GetThumbnailAsync 按时间取帧——那样取到的常是附近的另一帧，分不清锯齿是录下来的时间戳还是取帧造成的。
// 另记 sync.timing：每帧时间戳的间隔、条码号（测试图案自己的更新计数）对时间戳的斜率，看录下来的时间是不是匀的。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.Editing;
using Windows.Storage;

namespace KittyTools;

internal static class SyncProbe
{
    public static async Task RunAsync(string path)
    {
        try
        {
            var started = Environment.TickCount64;
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var duration = clip.OriginalDuration.TotalSeconds;
            var properties = clip.GetVideoEncodingProperties();
            var fps = properties.FrameRate.Denominator == 0
                ? 30.0
                : properties.FrameRate.Numerator / (double)properties.FrameRate.Denominator;

            var decoded = await Task.Run(() => Decode(Path.GetFullPath(path)));
            var flashes = decoded.Flashes;
            Log.Info($"sync.video flashes={flashes.Count} first={(flashes.Count > 0 ? flashes[0] : -1):F3}s frames={decoded.Times.Count}");
            LogTiming(decoded);
            // 每一帧的时间戳、真钟、更新计数、亮不亮，写在录像旁边（临时目录），离线看时间戳怎么走。
            var csv = new System.Text.StringBuilder("index,seconds,clock,number\n");
            for (var index = 0; index < decoded.Times.Count; index++)
            {
                csv.Append(System.FormattableString.Invariant(
                    $"{index},{decoded.Times[index]:F4},{decoded.Clocks[index]},{decoded.Numbers[index]}\n"));
            }

            await File.WriteAllTextAsync(Path.ChangeExtension(Path.GetFullPath(path), ".frames.csv"), csv.ToString());
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
                var start = decoded.Times.FindIndex(time => time >= at);
                if (start < 0 || start + 10 > decoded.Times.Count)
                {
                    continue;
                }

                var numbers = decoded.Numbers.GetRange(start, 10);
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

    private sealed record Decoded(List<double> Times, List<int> Numbers, List<double> Flashes, List<int> Clocks);

    /// <summary>按顺序解每一帧：整帧亮度（隔 8 个像素取一个）> 170 算闪白，暗 → 亮那一帧的时间戳就是闪白起点；顺手读条码。</summary>
    private static Decoded Decode(string path)
    {
        var times = new List<double>();
        var numbers = new List<int>();
        var clocks = new List<int>();
        var flashes = new List<double>();
        var lit = false;
        VideoFrames.Read(path, (seconds, bgra, width, height) =>
        {
            double sum = 0;
            var count = 0;
            for (var index = 0; index < bgra.Length; index += 32)
            {
                sum += 0.114 * bgra[index] + 0.587 * bgra[index + 1] + 0.299 * bgra[index + 2];
                count++;
            }

            var bright = count > 0 && sum / count > 170;
            if (bright && !lit)
            {
                flashes.Add(seconds);
            }

            lit = bright;
            times.Add(seconds);
            numbers.Add(Barcode(bgra, width, height, TestPatternWindow.BarcodeTop));
            clocks.Add(Barcode(bgra, width, height, TestPatternWindow.ClockTop));
        });
        return new Decoded(times, numbers, flashes, clocks);
    }

    private static int Barcode(ReadOnlySpan<byte> bgra, int width, int height, double top)
    {
        var size = width * TestPatternWindow.BarcodeSize;
        var centerY = (int)(height * top + size / 2);
        var number = 0;
        for (var bit = 0; bit < TestPatternWindow.BarcodeBits; bit++)
        {
            var centerX = (int)(width * (TestPatternWindow.BarcodeLeft + bit * TestPatternWindow.BarcodeStep) + size / 2);
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

                    var index = (y * width + x) * 4;
                    sum += 0.114 * bgra[index] + 0.587 * bgra[index + 1] + 0.299 * bgra[index + 2];
                    count++;
                }
            }

            number = (number << 1) | (count > 0 && sum / count > 128 ? 1 : 0);
        }

        return number;
    }

    /// <summary>
    /// 录下来的时间匀不匀：相邻两帧时间戳的间隔（最小 / 中位 / 最大）；条码号（测试图案每一拍加一）对时间戳拟合一条直线，
    /// 每秒一段算斜率——时间戳被拉长 / 压短的那几段斜率会偏。
    /// </summary>
    private static void LogTiming(Decoded decoded)
    {
        var times = decoded.Times;
        if (times.Count < 3)
        {
            return;
        }

        var gaps = new List<double>();
        for (var index = 1; index < times.Count; index++)
        {
            gaps.Add(times[index] - times[index - 1]);
        }

        gaps.Sort();
        Log.Info(
            $"sync.timing frames={times.Count} gapMin={gaps[0] * 1000:F1}ms gapMedian={gaps[gaps.Count / 2] * 1000:F1}ms " +
            $"gapMax={gaps[^1] * 1000:F1}ms span={times[^1] - times[0]:F3}s");
        var rates = new List<string>();
        for (var second = 0; second + 1 <= times[^1]; second++)
        {
            var from = times.FindIndex(time => time >= second);
            var to = times.FindLastIndex(time => time < second + 1);
            if (from < 0 || to <= from)
            {
                continue;
            }

            var updates = decoded.Numbers[to] - decoded.Numbers[from];
            var elapsed = times[to] - times[from];
            rates.Add(elapsed > 0 ? (updates / elapsed).ToString("F1", System.Globalization.CultureInfo.InvariantCulture) : "-");
        }

        Log.Info($"sync.timing updatesPerSecond={string.Join(',', rates)}");

        // 真钟（测试图案画进去的 Stopwatch 百分之一秒）对视频时间戳：录下来的时间戳准的话，两者之差只差一个常数
        // （画出来到被抓到的延迟），上下浮动不超过一两帧；时间戳被拉长 / 压短时这个差会一路漂。每 5 秒报一次差的中位数。
        var residuals = new List<(double Time, double Residual)>();
        for (var index = 0; index < times.Count; index++)
        {
            if (decoded.Clocks[index] is var clock and > 0)
            {
                residuals.Add((times[index], times[index] - clock / 100.0));
            }
        }

        if (residuals.Count < 10)
        {
            Log.Info("sync.clock unreadable");
            return;
        }

        var baseline = residuals.Select(item => item.Residual).OrderBy(value => value).ElementAt(residuals.Count / 2);
        var windows = new List<string>();
        for (var start = 0.0; start < times[^1]; start += 5)
        {
            var slice = residuals.Where(item => item.Time >= start && item.Time < start + 5)
                .Select(item => (item.Residual - baseline) * 1000).OrderBy(value => value).ToList();
            if (slice.Count > 0)
            {
                windows.Add(slice[slice.Count / 2].ToString("F0", System.Globalization.CultureInfo.InvariantCulture));
            }
        }

        var all = residuals.Select(item => (item.Residual - baseline) * 1000).OrderBy(value => value).ToList();
        Log.Info(
            $"sync.clock frames={residuals.Count} p5={all[all.Count / 20]:F0}ms p95={all[all.Count * 19 / 20]:F0}ms " +
            $"per5s={string.Join(',', windows)}ms");
    }

}
