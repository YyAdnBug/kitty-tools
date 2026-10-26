// 录屏压缩（PLAN-v6 第 3 批）：MediaTranscoder 把 MP4 重编一遍，码率降到原来的 45%（目标 < 60%）；
// 分辨率 / 帧率 / 音轨不变，输出「原名 压缩版.mp4」。进度写在 CompressionService.Progress，托盘那一项显示「压缩中 43%」。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Foundation;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace KittyTools;

internal static class CompressionService
{
    private static IAsyncActionWithProgress<double>? _running;

    public static double Progress { get; private set; }

    public static bool IsRunning => _running is not null;

    public static async Task<string?> CompressLastAsync()
    {
        var path = RecordingHost.LastPath;
        if (path is null || !File.Exists(path))
        {
            NoticeHost.Show("没有可压缩的录屏", "先录一段", NoticeTone.Warning);
            return null;
        }

        return await CompressAsync(path);
    }

    public static async Task<string?> CompressAsync(string source)
    {
        if (IsRunning)
        {
            NoticeHost.Show("正在压缩", "等这一轮做完", NoticeTone.Warning);
            return null;
        }

        var original = new FileInfo(source).Length;
        var final = CompressionRules.OutputPath(source);
        var temporary = Path.Combine(
            Path.GetDirectoryName(final) ?? ".", $".kitty-compress-{Guid.NewGuid():N}.tmp.mp4");
        Progress = 0;
        try
        {
            NoticeHost.Show("正在压缩录屏", "目标不超过原文件的 60%", NoticeTone.Normal);
            var file = await StorageFile.GetFileFromPathAsync(source);
            var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
            var video = await file.Properties.GetVideoPropertiesAsync();
            if (profile.Video is not null)
            {
                var seconds = Math.Max(1, video.Duration.TotalSeconds);
                var actual = (uint)(original * 8 / seconds);
                var sourceBitrate = actual == 0 ? video.Bitrate : actual;
                profile.Video.Bitrate = Math.Max(
                    200_000u, (uint)(sourceBitrate * CompressionRules.BitrateRatio));
                Log.Info($"video.compress-profile source={sourceBitrate} profile={profile.Video.Bitrate}");
            }

            var audio = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Medium);
            profile.Audio ??= audio.Audio;
            profile.Audio.Bitrate = 160_000;
            profile.Audio.SampleRate = 48_000;
            profile.Audio.ChannelCount = 2;

            var folder = await StorageFolder.GetFolderFromPathAsync(
                Path.GetDirectoryName(temporary) ?? Path.GetTempPath());
            var output = await folder.CreateFileAsync(
                Path.GetFileName(temporary), CreationCollisionOption.ReplaceExisting);
            var transcoder = new MediaTranscoder();
            var prepared = await transcoder.PrepareFileTranscodeAsync(file, output, profile);
            if (!prepared.CanTranscode)
            {
                NoticeHost.Show("没能压缩", "这台机器不支持重新编码这个文件", NoticeTone.Error);
                return null;
            }

            var action = prepared.TranscodeAsync();
            _running = action;
            action.Progress = (_, progress) =>
            {
                Progress = progress;
                Log.Info($"video.compress-progress {(int)(progress * 100)}");
            };
            await action;
            _running = null;
            if (!File.Exists(temporary))
            {
                NoticeHost.Show("没能压缩", "转码没有写出文件", NoticeTone.Error);
                return null;
            }

            if (File.Exists(final))
            {
                File.Delete(final);
            }

            File.Move(temporary, final, overwrite: true);
            var size = new FileInfo(final).Length;
            var percent = original == 0 ? 0 : size * 100 / original;
            Log.Info($"video.compressed from={original} to={size} percent={percent}");
            NoticeHost.Show(
                "压缩完成",
                $"{size / 1024.0 / 1024.0:F1} MB（原来的 {percent}%）· {Path.GetFileName(final)}",
                CompressionRules.IsSmallEnough(original, size) ? NoticeTone.Normal : NoticeTone.Warning);
            return final;
        }
        catch (Exception ex)
        {
            Log.Error("video.compress-failed", ex);
            NoticeHost.Show("没能压缩", "转码失败，详情看日志", NoticeTone.Error);
            return null;
        }
        finally
        {
            _running = null;
            Progress = 0;
            TryDelete(temporary);
        }
    }

    public static void Cancel()
    {
        try
        {
            _running?.Cancel();
        }
        catch
        {
            // 已经结束了。
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // 留给系统清理。
        }
    }
}
