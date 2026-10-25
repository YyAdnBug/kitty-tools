// 读自己写的 MJPEG AVI（压缩用）：拿宽高 / 帧率 / 每一帧的 JPEG 偏移。
// 结构是固定的 RIFF：找到 strf（BITMAPINFOHEADER）和 strh（rate/scale），再从 movi 里扫 00dc。
using System.Buffers.Binary;
using System.Text;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class AviInfo
{
    public int Width { get; init; }

    public int Height { get; init; }

    public int Fps { get; init; }

    public List<byte[]> Frames { get; init; } = new();
}

internal static class AviReader
{
    public static AviInfo? Read(string path)
    {
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception ex)
        {
            Log.Warn($"video.read-failed {ex.GetType().Name}");
            return null;
        }

        var width = 0;
        var height = 0;
        var fps = 15;
        var strf = IndexOf(bytes, "strf"u8);
        if (strf >= 0 && strf + 16 < bytes.Length)
        {
            width = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(strf + 12, 4));
            height = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(strf + 16, 4));
        }

        var strh = IndexOf(bytes, "strh"u8);
        if (strh >= 0 && strh + 32 < bytes.Length)
        {
            var scale = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(strh + 28, 4));
            var rate = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(strh + 32, 4));
            if (scale > 0 && rate > 0 && rate / scale is > 0 and <= 120)
            {
                fps = (int)(rate / scale);
            }
        }

        if (width <= 0 || height <= 0)
        {
            return null;
        }

        var frames = new List<byte[]>();
        var index = IndexOf(bytes, "movi"u8);
        if (index < 0)
        {
            index = 0;
        }

        while (index + 8 <= bytes.Length)
        {
            if (bytes[index] == (byte)'0' && bytes[index + 1] == (byte)'0' &&
                bytes[index + 2] == (byte)'d' && bytes[index + 3] == (byte)'c')
            {
                var length = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(index + 4, 4));
                if (length <= 0 || index + 8 + length > bytes.Length)
                {
                    break;
                }

                frames.Add(bytes.AsSpan(index + 8, length).ToArray());
                index += 8 + length;
                if ((length & 1) != 0)
                {
                    index++;
                }

                continue;
            }

            // idx1 之后没有画面了。
            if (bytes[index] == (byte)'i' && bytes[index + 1] == (byte)'d' && bytes[index + 2] == (byte)'x')
            {
                break;
            }

            index++;
        }

        return frames.Count == 0
            ? null
            : new AviInfo
            {
                Width = width & ~1,
                Height = height & ~1,
                Fps = Math.Clamp(fps, 5, 60),
                Frames = frames,
            };
    }

    private static int IndexOf(byte[] haystack, ReadOnlySpan<byte> needle)
    {
        for (var index = 0; index <= haystack.Length - needle.Length; index++)
        {
            if (haystack.AsSpan(index, needle.Length).SequenceEqual(needle))
            {
                return index;
            }
        }

        return -1;
    }
}
