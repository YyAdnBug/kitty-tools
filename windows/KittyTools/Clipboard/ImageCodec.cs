// 图片编解码：剪贴板里的 DIB 转 PNG、PNG 转 CF_DIBV5 用的 DIB，都走 Windows 自带的
// Windows.Graphics.Imaging（不引第三方库）。WinRT 的异步 API 在后台线程上等，别在 UI 线程上阻塞等。
using System.Buffers.Binary;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal readonly record struct DecodedImage(byte[] Png, int Width, int Height);

internal static class ImageCodec
{
    /// <summary>DIB（CF_DIB / CF_DIBV5 的字节）套一个 BITMAPFILEHEADER，交给系统解码，再编码成 PNG。</summary>
    public static async Task<DecodedImage?> DibToPngAsync(byte[] dib)
    {
        if (!TryWrapBmp(dib, out var bmp))
        {
            return null;
        }

        try
        {
            using var stream = await ToStreamAsync(bmp);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var png = await EncodePngAsync(decoder);
            return png is null ? null : new DecodedImage(png, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>已经是 PNG 的剪贴板内容：只读出尺寸，字节不改（避免二次编码）。</summary>
    public static async Task<DecodedImage?> ReadPngAsync(byte[] png)
    {
        try
        {
            using var stream = await ToStreamAsync(png);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            return new DecodedImage(png, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>PNG → CF_DIBV5 的字节（32 位 BGRA、自下而上）。</summary>
    public static async Task<byte[]?> PngToDibAsync(byte[] png)
    {
        try
        {
            using var stream = await ToStreamAsync(png);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            using var bitmap = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Straight);
            var width = bitmap.PixelWidth;
            var height = bitmap.PixelHeight;
            var stride = width * 4;
            var pixels = new byte[stride * height];
            var buffer = new Windows.Storage.Streams.Buffer((uint)pixels.Length);
            bitmap.CopyToBuffer(buffer);
            using (var reader = DataReader.FromBuffer(buffer))
            {
                reader.ReadBytes(pixels);
            }

            const int headerSize = 124; // BITMAPV5HEADER
            var dib = new byte[headerSize + pixels.Length];
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(0), headerSize);
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(4), width);
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(8), height);
            BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(12), 1);
            BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(14), 32);
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(16), 3); // BI_BITFIELDS
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(20), pixels.Length);
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(40), 0x00FF0000); // red mask
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(44), 0x0000FF00); // green mask
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(48), 0x000000FF); // blue mask
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(52), unchecked((int)0xFF000000)); // alpha mask
            BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(56), 0x73524742); // LCS_sRGB

            // DIB 的正高度是自下而上；SoftwareBitmap 的行是自上而下，倒着拷。
            for (var row = 0; row < height; row++)
            {
                pixels.AsSpan(row * stride, stride)
                    .CopyTo(dib.AsSpan(headerSize + (height - 1 - row) * stride, stride));
            }

            return dib;
        }
        catch
        {
            return null;
        }
    }

    private static async Task<byte[]?> EncodePngAsync(BitmapDecoder decoder)
    {
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        using var bitmap = await decoder.GetSoftwareBitmapAsync();
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
        return await ReadAllAsync(output);
    }

    private static async Task<InMemoryRandomAccessStream> ToStreamAsync(byte[] bytes)
    {
        var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }

        stream.Seek(0);
        return stream;
    }

    private static async Task<byte[]> ReadAllAsync(IRandomAccessStream stream)
    {
        stream.Seek(0);
        var size = (uint)stream.Size;
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync(size);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// <summary>给 DIB 补 14 字节的 BITMAPFILEHEADER，让系统能当 .bmp 解。</summary>
    private static bool TryWrapBmp(byte[] dib, out byte[] bmp)
    {
        bmp = Array.Empty<byte>();
        if (dib.Length < 40)
        {
            return false;
        }

        var headerSize = BinaryPrimitives.ReadInt32LittleEndian(dib);
        if (headerSize < 40 || headerSize > 4096 || dib.Length < headerSize)
        {
            return false;
        }

        var bitCount = BinaryPrimitives.ReadInt16LittleEndian(dib.AsSpan(14));
        var compression = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(16));
        var colorsUsed = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(32));
        long paletteBytes = 0;
        if (bitCount is > 0 and <= 8)
        {
            var colors = colorsUsed > 0 && colorsUsed <= 256 ? colorsUsed : 1 << bitCount;
            paletteBytes = colors * 4L;
        }

        // BITMAPINFOHEADER 的 BI_BITFIELDS：三个掩码跟在头后面。
        if (compression == 3 && headerSize == 40 && bitCount is 16 or 32)
        {
            paletteBytes += 12;
        }

        var offset = 14 + headerSize + paletteBytes;
        if (offset > 14L + dib.Length)
        {
            return false;
        }

        bmp = new byte[14 + dib.Length];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(2), bmp.Length);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(10), (int)offset);
        dib.CopyTo(bmp, 14);
        return true;
    }
}
