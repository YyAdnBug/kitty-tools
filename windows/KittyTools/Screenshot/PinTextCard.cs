// 把文字排成一张卡片图再钉（PLAN-v16 S3 / S4，mac PinBoard.textCard）：15 DIP 系统字、行距多 3.5、四周 12，底和字按钉的那一刻
// 的外观（深色：#1E1E1E 底白字；浅色：白底黑字；之后换深浅色不跟，钉图本来就是一张图）。宽按最长的那行、超过上限折行；
// 高超过上限的截到整行、最后一行末尾「…」。按鼠标所在屏的缩放出像素（钉图按像素摆）。圆角由钉图自己裁。
// ponytail: 只排纯文字（不读 RTF / HTML 的格式）；正文先截到 2 万字再排。
using KittyTools.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace KittyTools;

internal static class PinTextCard
{
    /// <summary>排好、出 PNG：返回 PNG 和像素尺寸；排不出来时 null。</summary>
    public static async Task<(byte[] Png, int Width, int Height)?> RenderAsync(string text, double scale, double limitWidth, double limitHeight, bool dark)
    {
        var device = CanvasDevice.GetSharedDevice();
        var body = text.Length > PinText.MaxCharacters ? text[..PinText.MaxCharacters] : text;
        var padding = PinText.Padding;
        var innerWidth = Math.Max(20, limitWidth - padding * 2);
        var innerHeight = Math.Max(20, limitHeight - padding * 2);
        using var format = new CanvasTextFormat
        {
            FontFamily = "Segoe UI",
            FontSize = (float)PinText.FontSize,
            WordWrapping = CanvasWordWrapping.Wrap,
            TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
            TrimmingSign = CanvasTrimmingSign.Ellipsis,
        };
        var natural = Math.Ceiling(PinText.FontSize * 1.33);
        var line = natural + PinText.ExtraLineSpacing;
        format.LineSpacingMode = CanvasLineSpacingMode.Uniform;
        format.LineSpacing = (float)line;
        format.LineSpacingBaseline = (float)(PinText.FontSize * 1.07 + PinText.ExtraLineSpacing / 2);
        // 先不限高量一遍：宽按最长那行、高按实际行数；放不下就截到整行
        using var measure = new CanvasTextLayout(device, body, format, (float)innerWidth, 1_000_000);
        var fittedWidth = Math.Min(Math.Ceiling(measure.LayoutBounds.Width), innerWidth);
        var fittedHeight = measure.LineCount * line;
        var height = fittedHeight <= innerHeight ? fittedHeight : Math.Floor(innerHeight / line) * line;
        var widthDip = fittedWidth + padding * 2;
        var heightDip = Math.Ceiling(height) + padding * 2;
        using var target = new CanvasRenderTarget(device, (float)widthDip, (float)heightDip, (float)(96 * scale));
        using (var layout = new CanvasTextLayout(device, body, format, (float)innerWidth, (float)height))
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(dark ? Color.FromArgb(255, 0x1E, 0x1E, 0x1E) : Color.FromArgb(255, 255, 255, 255));
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            ds.DrawTextLayout(layout, (float)padding, (float)padding, dark ? Color.FromArgb(255, 255, 255, 255) : Color.FromArgb(255, 0, 0, 0));
        }

        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await target.SaveAsync(stream, CanvasBitmapFileFormat.Png);
        var bytes = new byte[stream.Size];
        using (var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
        }

        return (bytes, (int)target.SizeInPixels.Width, (int)target.SizeInPixels.Height);
    }
}
