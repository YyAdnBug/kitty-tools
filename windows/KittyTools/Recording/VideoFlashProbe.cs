// R24 音画同步量测：从录好的 MP4 里找第一次闪白的时间。测试图案每秒前 100 ms 闪白 + 响 1 kHz，
// 音频起点由 AudioWavProbe 的 audio.starts 给出，两边一对就是音画差。
using KittyTools.Infrastructure;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class VideoFlashProbe
{
    public static async Task<double?> FirstFlashAsync(string path, double seconds = 2.0)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            var step = 1.0 / 60.0;
            for (var time = 0.0; time <= seconds; time += step)
            {
                using var image = await composition.GetThumbnailAsync(
                    TimeSpan.FromSeconds(time), 160, 90, VideoFramePrecision.NearestFrame);
                image.Seek(0);
                var decoder = await BitmapDecoder.CreateAsync(image);
                using var bitmap = await decoder.GetSoftwareBitmapAsync(
                    BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
                var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
                bitmap.CopyToBuffer(bytes.AsBuffer());
                double sum = 0;
                for (var index = 0; index < bytes.Length; index += 4)
                {
                    sum += 0.114 * bytes[index] + 0.587 * bytes[index + 1] + 0.299 * bytes[index + 2];
                }

                var luma = sum / (bitmap.PixelWidth * bitmap.PixelHeight);
                if (luma > 170)
                {
                    Log.Info($"sync.video first-flash={time:F3}s luma={luma:F0}");
                    return time;
                }
            }

            Log.Warn("sync.video no-flash");
            return null;
        }
        catch (Exception ex)
        {
            Log.Warn($"sync.video-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return null;
        }
    }
}
