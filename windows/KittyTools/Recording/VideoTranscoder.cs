// 录屏转 MP4（REVIEW R14 的中间步骤）：MediaTranscoder 把现有的 MJPEG AVI 转成 H.264 + AAC 的 MP4。
// 录制本身还是 AVI（1 GB 上限），转 MP4 在停止后 / 托盘手动触发；系统声音仍未做。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace KittyTools;

internal static class VideoTranscoder
{
    public static async Task<string?> ToMp4Async(string source)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(source);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(source)!);
            var target = await folder.CreateFileAsync(
                Path.GetFileNameWithoutExtension(source) + ".mp4", CreationCollisionOption.ReplaceExisting);

            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
            profile.Video.Bitrate = 8_000_000;
            profile.Audio = AudioEncodingProperties.CreateAac(48_000, 2, 160_000);
            var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
            var result = await transcoder.PrepareFileTranscodeAsync(file, target, profile);
            if (!result.CanTranscode)
            {
                Log.Warn($"video.mp4-refused {result.FailureReason}");
                return null;
            }

            var watch = System.Diagnostics.Stopwatch.StartNew();
            await result.TranscodeAsync().AsTask();
            watch.Stop();
            Log.Info($"video.mp4 {Path.GetFileName(target.Path)} size={new FileInfo(target.Path).Length} ms={watch.ElapsedMilliseconds}");
            return target.Path;
        }
        catch (Exception ex)
        {
            Log.Error("video.mp4-failed", ex);
            return null;
        }
    }

    public static async Task<string?> TranscodeAsync(string path, bool notify)
    {
        if (notify)
        {
            NoticeHost.Show("正在转 MP4", Path.GetFileName(path), NoticeTone.Normal);
        }

        var result = await Task.Run(() => ToMp4Async(path));
        if (notify)
        {
            NoticeHost.Show(
                result is null ? "没能转 MP4" : "MP4 好了",
                result is null ? "系统没有可用的编码器" : Path.GetFileName(result),
                result is null ? NoticeTone.Error : NoticeTone.Normal);
        }

        return result;
    }

    public static async Task<string?> TranscodeLastAsync()
    {
        var path = RecordingHost.LastPath;
        if (path is null || !File.Exists(path))
        {
            NoticeHost.Show("没有可转换的录屏", "先录一段", NoticeTone.Warning);
            return null;
        }

        return await TranscodeAsync(path, notify: true);
    }
}
