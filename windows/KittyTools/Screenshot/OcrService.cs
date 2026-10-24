// 识字：Windows.Media.Ocr。超过 MaxImageDimension 先等比缩小；中日韩文字之间的空格去掉；
// 按行框切段、段内接行交给 Core 的 OcrText（和 mac 的 OCR.paragraphs / joiningLines 同一套规则）。
using KittyTools.Core;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using CoreOcrLine = KittyTools.Core.OcrLine;

namespace KittyTools;

internal static class OcrService
{
    public static bool HasEngine => OcrEngine.TryCreateFromUserProfileLanguages() is not null;

    public static async Task<(string Text, IReadOnlyList<CoreOcrLine> Lines)> RecognizeAsync(
        byte[] bgra,
        int width,
        int height,
        bool joined = true,
        string separator = "\n")
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                     ?? throw new InvalidOperationException("没装可用的识字组件");
        var (pixels, scaledWidth, scaledHeight) = Fit(bgra, width, height, (int)OcrEngine.MaxImageDimension);
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(
            BufferFrom(pixels), BitmapPixelFormat.Bgra8, scaledWidth, scaledHeight, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        var lines = new List<CoreOcrLine>();
        foreach (var line in result.Lines)
        {
            var text = OcrText.RemoveCjkSpaces(line.Text.Trim());
            if (text.Length == 0)
            {
                continue;
            }

            var box = Union(line);
            lines.Add(new CoreOcrLine(text, box));
        }

        return (OcrText.Text(lines, joined, separator), lines);
    }

    private static RectD Union(Windows.Media.Ocr.OcrLine line)
    {
        double left = double.MaxValue, top = double.MaxValue, right = 0, bottom = 0;
        var any = false;
        foreach (var word in line.Words)
        {
            any = true;
            var rect = word.BoundingRect;
            left = Math.Min(left, rect.X);
            top = Math.Min(top, rect.Y);
            right = Math.Max(right, rect.Right);
            bottom = Math.Max(bottom, rect.Bottom);
        }

        return any ? RectD.FromLtrb(left, top, right, bottom) : default;
    }

    private static (byte[] Pixels, int Width, int Height) Fit(byte[] bgra, int width, int height, int maximum)
    {
        if (width <= maximum && height <= maximum)
        {
            return (bgra, width, height);
        }

        var scale = Math.Min((double)maximum / width, (double)maximum / height);
        var targetWidth = Math.Max(1, (int)(width * scale));
        var targetHeight = Math.Max(1, (int)(height * scale));
        var pixels = new byte[targetWidth * targetHeight * 4];
        for (var y = 0; y < targetHeight; y++)
        {
            var sourceY = Math.Min(height - 1, y * height / targetHeight);
            for (var x = 0; x < targetWidth; x++)
            {
                var sourceX = Math.Min(width - 1, x * width / targetWidth);
                var source = (sourceY * width + sourceX) * 4;
                var destination = (y * targetWidth + x) * 4;
                pixels[destination] = bgra[source];
                pixels[destination + 1] = bgra[source + 1];
                pixels[destination + 2] = bgra[source + 2];
                pixels[destination + 3] = bgra[source + 3];
            }
        }

        return (pixels, targetWidth, targetHeight);
    }

    private static IBuffer BufferFrom(byte[] bytes)
    {
        var writer = new DataWriter();
        writer.WriteBytes(bytes);
        return writer.DetachBuffer();
    }
}
