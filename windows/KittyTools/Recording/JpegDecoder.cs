// JPEG → BGRA（压缩和转 GIF 共用）：WIC 解码后编成 32 位 BMP，再按行拷出像素，避免手写 WIC COM。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class JpegDecoder
{
    public static async Task<byte[]?> ToBgraAsync(byte[] jpeg, int width, int height)
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
