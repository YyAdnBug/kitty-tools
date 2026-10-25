// 录屏转 GIF（第四版第 3 批）：读自己的 MJPEG AVI，按 10 fps 抽帧、长边缩到 800，
// 用 Core 的 GifWriter 流式写成循环 GIF；不把所有帧攒在内存里。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class GifService
{
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
        var info = AviReader.Read(source);
        if (info is null)
        {
            NoticeHost.Show("读不了这个录屏", "文件坏了，或者不是 Kitty Tools 录的", NoticeTone.Error);
            return null;
        }

        NoticeHost.Show("正在转 GIF", $"{info.Frames.Count} 帧，最多 10 fps", NoticeTone.Normal);
        var result = await Task.Run(() => ConvertCore(source, info));
        if (result is null)
        {
            NoticeHost.Show("没能转 GIF", "解码 / 编码失败", NoticeTone.Error);
            return null;
        }

        var size = new FileInfo(result).Length;
        Log.Info($"video.gif {Path.GetFileName(result)} size={size}");
        NoticeHost.Show("GIF 好了", $"{Path.GetFileName(result)} · {size / 1024} KB", NoticeTone.Normal);
        return result;
    }

    private static string? ConvertCore(string source, AviInfo info)
    {
        var target = GifRules.TargetSize(info.Width, info.Height);
        var step = GifRules.SampleStep(info.Fps);
        var delay = Math.Max(2, 100 / GifRules.TargetFps);
        var final = Path.Combine(
            Path.GetDirectoryName(source) ?? ".",
            Path.GetFileNameWithoutExtension(source) + ".gif");
        var temporary = final + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var writer = new GifWriter(stream, target.Width, target.Height, delay))
            {
                for (var index = 0; index < info.Frames.Count; index += step)
                {
                    var bgra = JpegDecoder.ToBgraAsync(info.Frames[index], info.Width, info.Height)
                        .GetAwaiter().GetResult();
                    if (bgra is null)
                    {
                        continue;
                    }

                    var scaled = GifRules.NearestScale(
                        bgra, info.Width, info.Height, target.Width, target.Height);
                    writer.AddFrame(scaled);
                    if (writer.Frames >= GifRules.MaxFrames(GifRules.TargetFps))
                    {
                        break;
                    }
                }

                writer.Finish();
            }

            File.Move(temporary, final, overwrite: true);
            return final;
        }
        catch (Exception ex)
        {
            Log.Error("video.gif-failed", ex);
            try
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch
            {
                // 留给系统清理。
            }

            return null;
        }
    }
}
