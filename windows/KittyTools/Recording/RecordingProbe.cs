// 录屏自检（第四版第 1 批的验收口径的简化版）：录 4 秒整屏，写 report.md：
// 帧数、时长、大小、能不能被 MediaPlayer 打开。用 --record-probe=<目录> 触发。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class RecordingProbe
{
    public static async Task RunAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var recorder = AviRecorder.Start(15, folder, out var error);
        if (recorder is null)
        {
            await File.WriteAllTextAsync(Path.Combine(folder, "report.md"), "启动失败：" + error);
            return;
        }

        await Task.Delay(4000);
        var path = recorder.Stop();
        recorder.Dispose();
        await Task.Delay(500);

        var size = path is not null && File.Exists(path) ? new FileInfo(path).Length : 0;
        var duration = 0.0;
        var decodable = false;
        if (path is not null)
        {
            try
            {
                var player = new Windows.Media.Playback.MediaPlayer
                {
                    Source = Windows.Media.Core.MediaSource.CreateFromUri(new Uri(path)),
                };
                await Task.Delay(1500);
                duration = player.NaturalDuration.TotalSeconds;
                decodable = duration > 0;
                player.Dispose();
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
            - 帧数：{recorder.Frames}
            - 错误：{recorder.Error ?? "无"}
            """;
        await File.WriteAllTextAsync(Path.Combine(folder, "report.md"), report);
        Log.Info($"record.probe size={size} duration={duration:F2} decodable={decodable} frames={recorder.Frames}");
    }
}
