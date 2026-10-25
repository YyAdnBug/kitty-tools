// 录屏压缩（第四版第 3 批的简化版）：自己的 MJPEG AVI → 更低 JPEG 质量重编码，目标不超过原文件 60%。
// 不改变分辨率 / 帧率 / 帧数；先 0.5 质量，不够再 0.35、0.25，取最小的一份，仍超过 60% 就提示。
// 转 GIF 没做（报告里记为没做）。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class CompressionService
{
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
        var info = AviReader.Read(source);
        if (info is null)
        {
            NoticeHost.Show("读不了这个录屏", "文件坏了，或者不是 Kitty Tools 录的", NoticeTone.Error);
            return null;
        }

        var original = new FileInfo(source).Length;
        NoticeHost.Show("正在压缩录屏", $"{info.Frames.Count} 帧，目标不超过 60%", NoticeTone.Normal);
        var result = await Task.Run(() => CompressCore(source, info, original));
        if (result is null)
        {
            NoticeHost.Show("没能压缩", "解码 / 编码失败", NoticeTone.Error);
            return null;
        }

        var size = new FileInfo(result).Length;
        var percent = original == 0 ? 0 : size * 100 / original;
        Log.Info($"video.compressed from={original} to={size} percent={percent}");
        NoticeHost.Show(
            "压缩完成",
            $"{size / 1024 / 1024} MB（原来的 {percent}%）· {Path.GetFileName(result)}",
            CompressionRules.IsSmallEnough(original, size) ? NoticeTone.Normal : NoticeTone.Warning);
        return result;
    }

    private static string? CompressCore(string source, AviInfo info, long original)
    {
        var final = CompressionRules.OutputPath(source);
        string? best = null;
        long bestSize = long.MaxValue;
        string sourceName = Path.GetFileName(source);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var temporary = Path.Combine(
                Path.GetDirectoryName(final)!, $".kitty-compress-{Guid.NewGuid():N}.tmp.avi");
            try
            {
                using (var writer = new AviWriter(temporary, info.Width, info.Height, info.Fps))
                {
                    foreach (var frame in info.Frames)
                    {
                        var bgra = JpegToBgra(frame, info.Width, info.Height).GetAwaiter().GetResult();
                        if (bgra is null)
                        {
                            return null;
                        }

                        var quality = CompressionRules.QualityFor(attempt);
                        var jpeg = JpegEncoder
                            .EncodeAsync(bgra, info.Width, info.Height, quality)
                            .GetAwaiter().GetResult();
                        writer.AddFrame(jpeg);
                    }
                }

                var size = new FileInfo(temporary).Length;
                if (size < bestSize)
                {
                    if (best is not null)
                    {
                        TryDelete(best);
                    }

                    best = temporary;
                    bestSize = size;
                }
                else
                {
                    TryDelete(temporary);
                }

                if (CompressionRules.IsSmallEnough(original, size))
                {
                    break;
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"video.compress-attempt {attempt} {ex.GetType().Name}");
                TryDelete(temporary);
                break;
            }
        }

        if (best is null)
        {
            return null;
        }

        try
        {
            File.Move(best, final, overwrite: true);
            Log.Info($"video.compress {sourceName} -> {Path.GetFileName(final)}");
            return final;
        }
        catch (Exception ex)
        {
            Log.Error("video.compress-move", ex);
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

    /// <summary>JPEG → BGRA：走 WIC 解码，再编成 BMP（32 位、不压缩）拿像素，避免手写 COM。</summary>
    private static async Task<byte[]?> JpegToBgra(byte[] jpeg, int width, int height)
    {
        try
        {
            using var input = new InMemoryRandomAccessStream();
            await input.WriteAsync(jpeg.AsBuffer());
            input.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(input);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            using var output = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.BmpEncoderId, output);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync();
            output.Seek(0);
            var bytes = new byte[output.Size];
            using var reader = new DataReader(output.GetInputStreamAt(0));
            await reader.LoadAsync((uint)output.Size);
            reader.ReadBytes(bytes);

            if (bytes.Length < 54 || bytes[0] != (byte)'B' || bytes[1] != (byte)'M')
            {
                return null;
            }

            var offset = BitConverter.ToInt32(bytes, 10);
            var bmpWidth = BitConverter.ToInt32(bytes, 18);
            var bmpHeight = BitConverter.ToInt32(bytes, 22);
            var bits = BitConverter.ToInt16(bytes, 28);
            if (bits != 32 || bmpWidth <= 0)
            {
                return null;
            }

            var topDown = bmpHeight < 0;
            var rows = Math.Abs(bmpHeight);
            var result = new byte[width * height * 4];
            var rowBytes = bmpWidth * 4;
            for (var row = 0; row < Math.Min(rows, height); row++)
            {
                var sourceRow = topDown ? row : rows - 1 - row;
                var sourceOffset = offset + sourceRow * rowBytes;
                var targetOffset = row * width * 4;
                var copy = Math.Min(rowBytes, width * 4);
                if (sourceOffset + copy <= bytes.Length)
                {
                    System.Buffer.BlockCopy(bytes, sourceOffset, result, targetOffset, copy);
                }
            }

            return result;
        }
        catch (Exception ex)
        {
            Log.Warn($"video.decode-frame {ex.GetType().Name}");
            return null;
        }
    }
}
