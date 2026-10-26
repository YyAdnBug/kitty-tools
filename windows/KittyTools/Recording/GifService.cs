// 录屏转 GIF（PLAN-v6 第 3 批）：MediaComposition 从 MP4 按 10 fps 抽帧（长边 800），
// 每帧八叉树量化成 ≤ 256 色 + 局部调色板，交给 GifWriter 流式写出循环 GIF。
// 进度写在 GifService.Progress；托盘那一项显示「转 GIF 43%」；能取消。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class GifService
{
    private static CancellationTokenSource? _cancel;

    public static double Progress { get; private set; }

    public static bool IsRunning => _cancel is not null;

    public static async Task<string?> ConvertLastAsync()
    {
        var path = RecordingHost.LastPath;
        if (path is null || !File.Exists(path))
        {
            NoticeHost.Show("没有可转换的录屏", "先录一段", NoticeTone.Warning);
            return null;
        }

        return await ConvertAsync(path);
    }

    public static async Task<string?> ConvertAsync(string source)
    {
        if (IsRunning)
        {
            NoticeHost.Show("正在转 GIF", "等这一轮做完", NoticeTone.Warning);
            return null;
        }

        _cancel = new CancellationTokenSource();
        Progress = 0;
        var final = Path.ChangeExtension(source, ".gif");
        var temporary = final + ".tmp";
        try
        {
            NoticeHost.Show("正在转 GIF", "10 fps，长边 800", NoticeTone.Normal);
            var file = await StorageFile.GetFileFromPathAsync(source);
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            var properties = clip.GetVideoEncodingProperties();
            var target = GifRules.TargetSize((int)properties.Width, (int)properties.Height);
            var seconds = Math.Min(GifRules.MaxSeconds, clip.OriginalDuration.TotalSeconds);
            var frames = Math.Max(1, (int)(seconds * GifRules.TargetFps));
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var writer = new GifWriter(stream, target.Width, target.Height, 100 / GifRules.TargetFps))
            {
                for (var index = 0; index <= frames; index++)
                {
                    _cancel.Token.ThrowIfCancellationRequested();
                    var secondsAt = index / (double)GifRules.TargetFps;
                    using var image = await composition.GetThumbnailAsync(
                        TimeSpan.FromSeconds(secondsAt), target.Width, target.Height,
                        VideoFramePrecision.NearestFrame);
                    var bgra = await DecodeAsync(image, target.Width, target.Height);
                    if (bgra is null)
                    {
                        continue;
                    }

                    var (indices, palette) = OctreeQuantizer.Quantize(bgra, target.Width, target.Height);
                    writer.AddFrameWithPalette(indices, palette);
                    Progress = (double)index / frames;
                    if (writer.Frames >= GifRules.MaxFrames(GifRules.TargetFps))
                    {
                        break;
                    }
                }

                writer.Finish();
            }

            if (File.Exists(final))
            {
                File.Delete(final);
            }

            File.Move(temporary, final, overwrite: true);
            var size = new FileInfo(final).Length;
            Log.Info($"video.gif {Path.GetFileName(final)} size={size}");
            NoticeHost.Show("GIF 好了", $"{Path.GetFileName(final)} · {size / 1024} KB", NoticeTone.Normal);
            return final;
        }
        catch (OperationCanceledException)
        {
            NoticeHost.Show("已取消转 GIF", string.Empty, NoticeTone.Normal);
            return null;
        }
        catch (Exception ex)
        {
            Log.Error("video.gif-failed", ex);
            NoticeHost.Show("没能转 GIF", "解码 / 编码失败，详情看日志", NoticeTone.Error);
            return null;
        }
        finally
        {
            _cancel?.Dispose();
            _cancel = null;
            Progress = 0;
            TryDelete(temporary);
        }
    }

    public static void Cancel()
    {
        try
        {
            _cancel?.Cancel();
        }
        catch
        {
            // 已经结束了。
        }
    }

    private static async Task<byte[]?> DecodeAsync(IRandomAccessStreamWithContentType image, int width, int height)
    {
        try
        {
            var decoder = await BitmapDecoder.CreateAsync(image);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            var buffer = new Windows.Storage.Streams.Buffer((uint)(width * height * 4));
            bitmap.CopyToBuffer(buffer);
            return buffer.ToArray();
        }
        catch (Exception ex)
        {
            Log.Warn($"video.gif-decode {ex.GetType().Name}");
            return null;
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
