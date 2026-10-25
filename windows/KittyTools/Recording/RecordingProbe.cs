// 录屏自检（R14 / PLAN-v6 第 2 批）：录 6 秒 MP4，系统声音 + 麦克风都开；录的时候循环放一段
// 每秒 100 ms 的 1 kHz 提示音，报告里写帧数、大小、时长、有没有 AAC 音轨、两路采到的包数和峰值。
// 用 --record-probe=<目录> 触发。录的是屏幕左上角 640×480 的小块（自检文件只在本地，不推仓库）。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace KittyTools;

internal static class RecordingProbe
{
    public static async Task RunAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var tone = Path.Combine(folder, "tone.wav");
        WriteTone(tone);
        var player = new MediaPlayer
        {
            Source = MediaSource.CreateFromUri(new Uri(tone)),
            IsLoopingEnabled = true,
        };
        try
        {
            player.Play();
        }
        catch (Exception ex)
        {
            Log.Warn($"record.probe-tone {ex.GetType().Name}");
        }

        var recorder = Mp4Recorder.StartRegion(
            new PixelBounds(0, 0, 640, 480), 30, folder,
            systemAudio: true, microphone: true, out var error, out var note);
        if (recorder is null)
        {
            player.Pause();
            await File.WriteAllTextAsync(Path.Combine(folder, "report.md"), "启动失败：" + error);
            return;
        }

        var seconds = 6;
        if (int.TryParse(Environment.GetEnvironmentVariable("KITTY_RECORD_PROBE_SECONDS"), out var requested))
        {
            seconds = Math.Clamp(requested, 1, 900);
        }

        var process = System.Diagnostics.Process.GetCurrentProcess();
        var cpuStart = process.TotalProcessorTime;
        long mem10 = 0;
        long memEnd = 0;
        for (var second = 1; second <= seconds; second++)
        {
            await Task.Delay(1000);
            if (second % 10 == 0 || second == seconds)
            {
                process.Refresh();
                var memory = process.PrivateMemorySize64;
                if (second == Math.Min(10, seconds))
                {
                    mem10 = memory;
                }

                memEnd = memory;
                Log.Info($"record.probe-mem t={second} mem={memory / 1024 / 1024}MB");
            }
        }

        var cpuSeconds = (process.TotalProcessorTime - cpuStart).TotalSeconds;
        var cpuPercent = seconds <= 0 ? 0 : cpuSeconds * 100 / seconds;
        var path = recorder.Stop();
        recorder.Dispose();
        player.Pause();
        player.Dispose();
        await Task.Delay(500);

        var size = path is not null && File.Exists(path) ? new FileInfo(path).Length : 0;
        var duration = 0.0;
        var decodable = false;
        var hasAac = false;
        if (path is not null && File.Exists(path))
        {
            try
            {
                var bytes = await File.ReadAllBytesAsync(path);
                hasAac = Contains(bytes, "mp4a") && Contains(bytes, "soun");
            }
            catch
            {
                // 读不出来就当没有。
            }

            try
            {
                var media = new Windows.Media.Playback.MediaPlayer
                {
                    Source = Windows.Media.Core.MediaSource.CreateFromUri(new Uri(path)),
                };
                await Task.Delay(1500);
                duration = media.NaturalDuration.TotalSeconds;
                decodable = duration > 0;
                media.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"record.probe-player {ex.GetType().Name}");
            }
        }

        var report = $"""
            # 录屏自检

            - 目录：{folder}
            - 文件：{Path.GetFileName(path ?? "(无)")}
            - 大小：{size} 字节
            - 时长（MediaPlayer）：{duration:F2} 秒
            - 能不能解码：{(decodable ? "能" : "不能")}
            - 有没有 AAC 音轨（mp4a + soun）：{(hasAac ? "有" : "没有")}
            - 帧数：{recorder.Frames}
            - 音频帧数：{recorder.AudioFrames}（{recorder.AudioFrames / 48000.0:F2} 秒）
            - 录制 {seconds} 秒的本进程 CPU（单核）：{cpuPercent:F1}%
            - 专用内存：第 10 秒 {mem10 / 1024 / 1024} MB → 结束 {memEnd / 1024 / 1024} MB
            - 提示：{note ?? "无"}
            - 错误：{error ?? "无"}
            """;
        await File.WriteAllTextAsync(Path.Combine(folder, "report.md"), report);
        Log.Info(
            $"record.probe size={size} duration={duration:F2} decodable={decodable} aac={hasAac} " +
            $"frames={recorder.Frames} audio={recorder.AudioFrames} cpu={cpuPercent:F1}% " +
            $"mem10={mem10 / 1024 / 1024}MB memEnd={memEnd / 1024 / 1024}MB note={note ?? "-"}");
    }

    private static bool Contains(byte[] bytes, string text)
    {
        var needle = Encoding.ASCII.GetBytes(text);
        for (var index = 0; index <= bytes.Length - needle.Length; index++)
        {
            var hit = true;
            for (var offset = 0; offset < needle.Length; offset++)
            {
                if (bytes[index + offset] != needle[offset])
                {
                    hit = false;
                    break;
                }
            }

            if (hit)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>7 秒、48 kHz、16 位单声道 WAV：每秒开头 100 ms 的 1 kHz 正弦，幅度 0.5。</summary>
    private static void WriteTone(string path)
    {
        const int rate = 48_000;
        const int seconds = 7;
        var samples = rate * seconds;
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        using var writer = new BinaryWriter(stream, Encoding.ASCII, leaveOpen: true);
        var dataBytes = samples * 2;
        writer.Write(Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + dataBytes);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data"));
        writer.Write(dataBytes);
        for (var index = 0; index < samples; index++)
        {
            var inSecond = index % rate;
            var value = inSecond < rate / 10
                ? (short)(Math.Sin(2 * Math.PI * 1000 * inSecond / rate) * 16384)
                : (short)0;
            writer.Write(value);
        }
    }
}
