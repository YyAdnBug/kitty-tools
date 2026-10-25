// 用系统的 WIC（Windows.Graphics.Imaging）把一帧 BGRA 编成 JPEG；不引第三方库。
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class JpegEncoder
{
    public static async Task<byte[]> EncodeAsync(byte[] bgra, int width, int height, float quality)
    {
        using var stream = new InMemoryRandomAccessStream();
        var properties = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue(quality, Windows.Foundation.PropertyType.Single),
        };
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, properties);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore,
            (uint)width, (uint)height, 96, 96, bgra);
        await encoder.FlushAsync();

        stream.Seek(0);
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(bytes);
        return bytes;
    }
}
