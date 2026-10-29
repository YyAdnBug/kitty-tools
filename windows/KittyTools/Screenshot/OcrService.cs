// 识字：Windows.Media.Ocr。超过 MaxImageDimension 先等比缩小；字太小时放大再认一遍（OcrScale，同 Text Grab）；中日韩文字之间的空格去掉；
// 按行框切段、段内接行交给 Core 的 OcrText（和 mac 的 OCR.paragraphs / joiningLines 同一套规则）。
// 引擎按「设置里的第一 / 第二语言」挑：用户语言的识字引擎里只有英文时，中文是识别不出来的，
// 要按没装组件处理，而不是随便拿一个引擎硬认（第二版 §2 P3）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using CoreOcrLine = KittyTools.Core.OcrLine;

namespace KittyTools;

internal static class OcrService
{
    public static bool HasEngine => PickEngine() is not null;

    /// <summary>挑一个能读设置里第一 / 第二语言的引擎；一个都读不了就新建不出来（返回 null）。</summary>
    public static OcrEngine? PickEngine()
    {
        try
        {
            var needed = NeededTags();
            foreach (var language in OcrEngine.AvailableRecognizerLanguages)
            {
                if (!needed.Any(tag => Covers(language.LanguageTag, tag)))
                {
                    continue;
                }

                var engine = OcrEngine.TryCreateFromLanguage(language);
                if (engine is not null)
                {
                    return engine;
                }
            }

            return OcrEngine.TryCreateFromUserProfileLanguages();
        }
        catch
        {
            return null;
        }
    }

    public static async Task<(string Text, IReadOnlyList<CoreOcrLine> Lines)> RecognizeAsync(
        byte[] bgra,
        int width,
        int height,
        bool joined = true,
        string separator = "\n")
    {
        var engine = PickEngine() ?? throw new InvalidOperationException("没装可用的识字组件");
        var maximum = (int)OcrEngine.MaxImageDimension;
        var (pixels, scaledWidth, scaledHeight) = Fit(bgra, width, height, maximum);
        var result = await RecognizeOnceAsync(engine, pixels, scaledWidth, scaledHeight);
        // 小字放大再认一遍（OcrScale）；放大后什么都没认出来就用第一遍的。框按放大倍数换回来。
        var scale = 1.0;
        var factor = OcrScale.Factor(AverageWordHeight(result), scaledWidth, scaledHeight, maximum);
        if (factor > 1)
        {
            var largerWidth = (int)Math.Round(scaledWidth * factor);
            var largerHeight = (int)Math.Round(scaledHeight * factor);
            var larger = await Task.Run(() => OcrScale.Resize(pixels, scaledWidth, scaledHeight, largerWidth, largerHeight));
            var retry = await RecognizeOnceAsync(engine, larger, largerWidth, largerHeight);
            if (retry.Lines.Count > 0)
            {
                result = retry;
                scale = (double)largerWidth / scaledWidth;
            }
        }

        var lines = new List<CoreOcrLine>();
        foreach (var line in result.Lines)
        {
            var text = OcrText.RemoveCjkSpaces(line.Text.Trim());
            if (text.Length == 0)
            {
                continue;
            }

            var box = Union(line);
            lines.Add(new CoreOcrLine(text, RectD.FromLtrb(box.X / scale, box.Y / scale, box.Right / scale, box.Bottom / scale)));
        }

        return (OcrText.Text(lines, joined, separator), lines);
    }

    private static async Task<OcrResult> RecognizeOnceAsync(OcrEngine engine, byte[] pixels, int width, int height)
    {
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(
            BufferFrom(pixels), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Premultiplied);
        return await engine.RecognizeAsync(bitmap);
    }

    /// <summary>认出来的字的平均高度（像素）；一个都没有时 0。中日韩文字一个字就是一个 word。</summary>
    private static double AverageWordHeight(OcrResult result)
    {
        double total = 0;
        var count = 0;
        foreach (var line in result.Lines)
        {
            foreach (var word in line.Words)
            {
                total += word.BoundingRect.Height;
                count++;
            }
        }

        return count == 0 ? 0 : total / count;
    }

    private static IReadOnlyList<string> NeededTags()
    {
        var settings = SettingsService.Current;
        var tags = new List<string>(2);
        if (!string.IsNullOrWhiteSpace(settings.TranslateFirstLanguage))
        {
            tags.Add(settings.TranslateFirstLanguage!);
        }

        if (!string.IsNullOrWhiteSpace(settings.TranslateSecondLanguage))
        {
            tags.Add(settings.TranslateSecondLanguage!);
        }

        return tags.Count > 0 ? tags : new[] { "zh-Hans", "en" };
    }

    /// <summary>引擎的语言能不能读我们需要的语言（中文还要看简繁：tag 里没写 script 就当都行）。</summary>
    internal static bool Covers(string engineTag, string neededTag)
    {
        if (string.Equals(engineTag, neededTag, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var engineBase = Base(engineTag);
        if (!string.Equals(engineBase, Base(neededTag), StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!string.Equals(engineBase, "zh", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var engineScript = Script(engineTag);
        var neededScript = Script(neededTag);
        return engineScript is null || neededScript is null ||
               string.Equals(engineScript, neededScript, StringComparison.OrdinalIgnoreCase);
    }

    private static string Base(string tag)
    {
        var dash = tag.IndexOf('-');
        return dash < 0 ? tag : tag[..dash];
    }

    private static string? Script(string tag)
    {
        foreach (var part in tag.Split('-'))
        {
            if (part.Equals("Hans", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("Hant", StringComparison.OrdinalIgnoreCase))
            {
                return part;
            }
        }

        return null;
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
