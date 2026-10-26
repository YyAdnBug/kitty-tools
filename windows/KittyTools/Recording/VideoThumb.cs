// 从录好的 MP4 里抽一张缩略图（PLAN-v6 第 1 批验收：看帧号 / 看效果画上没有）。
// 用系统的 MediaComposition 取帧，不自己解 H.264；只给调试参数 --thumb= 用，普通用户看不到。
using KittyTools.Infrastructure;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class VideoThumb
{
    public static async Task RunAsync(string path, double seconds, string output)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            using var image = await composition.GetThumbnailAsync(
                TimeSpan.FromSeconds(Math.Max(0, seconds)), 1280, 720, VideoFramePrecision.NearestFrame);
            using var memory = new InMemoryRandomAccessStream();
            await RandomAccessStream.CopyAsync(image, memory);
            memory.Seek(0);
            using var reader = new DataReader(memory.GetInputStreamAt(0));
            await reader.LoadAsync((uint)memory.Size);
            var bytes = new byte[memory.Size];
            reader.ReadBytes(bytes);
            await File.WriteAllBytesAsync(output, bytes);
            Log.Info($"video.thumb {Path.GetFileName(output)} bytes={bytes.Length}");
        }
        catch (Exception ex)
        {
            Log.Error("video.thumb-failed", ex);
        }
    }
}
