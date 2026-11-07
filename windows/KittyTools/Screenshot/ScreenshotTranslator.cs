// 截图翻译把译文盖回截图上（PLAN-v16 S1 / S1b，mac AppDelegate.overlayTranslate + ScreenshotOverlay.render）：
// 选区的像素 → 识字（带词框）→ 按段分好 → 逐段翻译（整段原文定一次方向，每段按顺序试启用的服务；纯符号段不发请求）
// → Core 的 ScreenshotOverlay.Compose 量基线 / 代码块、排版、去字 → Win2D 按原文的字色把译文画上去（代码词在新位置重画底框）。
// 识字、合成、画字都在后台线程（Win2D 的共享设备不挑线程）；取消点在每段开头，取消后不再发新请求。
// 原文照截图翻译那条路记进剪贴板历史（开了「复制识别出的原文」就当复制一次）；翻译历史记一条整段原文 + 整段译文（不记碎片）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Windows.Graphics.DirectX;
using Windows.UI;

namespace KittyTools;

internal static class ScreenshotTranslator
{
    private const string BodyFont = "Segoe UI";
    private const string CodeFont = "Cascadia Mono, Consolas";

    /// <summary>翻译失败、取消之外的「做不了」：消息直接给遮罩上的提示。</summary>
    internal sealed class Failure(string message) : Exception(message);

    /// <summary>选区（BGRA，宽 × 高）→ 贴了译文的同尺寸 BGRA。progress(第几段, 共几段) 在调用线程上回调。</summary>
    public static async Task<byte[]> TranslateAsync(
        byte[] bgra, int width, int height, Action<int, int> progress, CancellationToken cancellationToken)
    {
        if (!OcrService.HasEngine)
        {
            throw new Failure("没装可用的识字组件");
        }

        var (text, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: true, separator: "\n\n");
        cancellationToken.ThrowIfCancellationRequested();
        if (lines.Count == 0 || string.IsNullOrWhiteSpace(text))
        {
            throw new Failure("没有识别到文字");
        }

        // 原文记进剪贴板历史；开着「截图翻译时复制识别出的原文」就当复制一次
        if (SettingsService.Current.TranslateCopyRecognized && ClipboardWriter.WriteText(text))
        {
            ClipboardService.Instance?.MarkOwnWrite();
        }

        ClipboardService.Instance?.Store.RecordOwnText(text);
        var segments = ScreenshotOverlay.Segments(lines, width, height);
        if (segments.Count == 0)
        {
            throw new Failure("没有识别到文字");
        }

        var translations = await TranslateSegmentsAsync(segments, text, progress, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return await Task.Run(() => Render(bgra, width, height, segments, translations), cancellationToken)
               ?? throw new Failure("合成失败");
    }

    private static async Task<List<string>> TranslateSegmentsAsync(
        IReadOnlyList<OverlaySegment> segments, string source, Action<int, int> progress, CancellationToken cancellationToken)
    {
        var services = TranslateServiceStore.Instance?.Enabled
            .Where(service => TranslateKinds.IsRunnable(service.Kind) && !TranslateKinds.IsDictionary(service.Kind))
            .ToList() ?? new List<TranslateServiceConfig>();
        if (services.Count == 0)
        {
            throw new Failure("没有启用的翻译服务，先在设置 › 翻译里开一个");
        }

        var plan = TranslateCoordinator.PlanRequest(source);
        var results = new List<string>(segments.Count);
        TranslateServiceConfig? used = null;
        for (var index = 0; index < segments.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var segment = segments[index];
            // 纯符号段不发请求（有道这类接口会回错误码，一段失败整张图就白翻了），原样占位；覆盖那一步也会跳过它
            if (!ScreenshotOverlay.HasTranslatableContent(segment.Text))
            {
                results.Add(segment.Text);
                continue;
            }

            progress(index + 1, segments.Count);
            var request = new TranslateRequest(segment.Text, plan.From, plan.To);
            Exception failure = new TranslateError("翻译失败");
            string? translated = null;
            foreach (var service in services)
            {
                try
                {
                    var latest = string.Empty;
                    await foreach (var piece in TranslateServiceStore.Translate(service, request, cancellationToken).WithCancellation(cancellationToken))
                    {
                        latest = piece;
                    }

                    cancellationToken.ThrowIfCancellationRequested();
                    if (latest.Trim().Length == 0)
                    {
                        throw TranslateError.EmptyResult;
                    }

                    translated = latest;
                    used ??= service;
                    break;
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    Log.Info($"screenshot.overlay-next kind={service.Kind} error={(ex as TranslateError)?.Kind.ToString() ?? ex.GetType().Name}");
                    failure = ex;
                }
            }

            results.Add(translated ?? throw failure);
        }

        // 和浮窗那条一样记一份翻译历史（整段原文 + 整段译文）
        var settings = SettingsService.Current;
        if (used is not null && settings.TranslateHistoryEnabled)
        {
            TranslationHistory.Instance?.Add(
                plan.Text, plan.From?.Code(), plan.To.Code(), string.Join("\n\n", results), used.Name, settings.TranslateHistoryLimit);
        }

        return results;
    }

    /// <summary>合成：去字（Core）+ 画字（Win2D）。坐标：Core 是左下原点，Win2D 是左上原点，y 换一下。</summary>
    internal static byte[]? Render(byte[] bgra, int width, int height, IReadOnlyList<OverlaySegment> segments, IReadOnlyList<string> translations)
    {
        var device = CanvasDevice.GetSharedDevice();
        var measure = new Win2DMeasure(device);
        var pixels = new OverlayPixels((byte[])bgra.Clone(), width, height, width * 4);
        var composed = ScreenshotOverlay.Compose(pixels, segments, translations, measure);
        if (composed.Count == 0)
        {
            return null;
        }

        using var target = new CanvasRenderTarget(device, width, height, 96, DirectXPixelFormat.B8G8R8A8UIntNormalized, CanvasAlphaMode.Premultiplied);
        using (var source = CanvasBitmap.CreateFromBytes(device, pixels.Bytes, width, height, DirectXPixelFormat.B8G8R8A8UIntNormalized))
        using (var ds = target.CreateDrawingSession())
        {
            ds.DrawImage(source);
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            foreach (var (span, color) in composed)
            {
                DrawSpan(ds, device, span, ToColor(color), span.Code?.Text is { } codeText ? ToColor(codeText) : ToColor(color), height);
            }
        }

        return target.GetPixelBytes();
    }

    private static Color ToColor(OverlayRgb rgb)
        => Color.FromArgb(255, (byte)Math.Round(rgb.Red * 255), (byte)Math.Round(rgb.Green * 255), (byte)Math.Round(rgb.Blue * 255));

    /// <summary>
    /// 一行行画在原文的行上：第一行的基线和原文第一行齐平，往下每行隔一个原文的行距（等行距排版，基线在行顶下 0.8 行距）。
    /// 先把这一段所有代码词的底框画完再画字：底框比行高，后画的底框会压住上一行字的下伸部。
    /// </summary>
    private static void DrawSpan(CanvasDrawingSession ds, CanvasDevice device, OverlaySpan span, Color color, Color codeColor, int height)
    {
        var baselineTop = height - span.Baseline;
        var lineBaseline = (float)(span.Pitch * 0.8);
        using var layout = Layout(device, span.Text, span.Frame.Width, span.FontSize, span.Code, span.Pitch, color, codeColor);
        var origin = new System.Numerics.Vector2((float)span.Frame.MinX, (float)(baselineTop - lineBaseline));
        if (span.Code is { } code)
        {
            var fill = ToColor(code.Fill);
            foreach (var (start, length) in ScreenshotOverlay.CodeSpans(span.Text, code.Phrases).Ranges)
            {
                foreach (var region in layout.GetCharacterRegions(start, length))
                {
                    var bounds = region.LayoutBounds;
                    var line = Math.Max(0, (int)Math.Floor((bounds.Y + bounds.Height / 2) / span.Pitch));
                    var baseline = baselineTop + line * span.Pitch;
                    var right = bounds.X + bounds.Width - (region.CharacterIndex + region.CharacterCount == start + length ? code.Padding : 0);
                    var rect = new Windows.Foundation.Rect(
                        span.Frame.MinX + bounds.X - code.Padding,
                        baseline - code.Above * span.Scale,
                        Math.Max(1, right - bounds.X + 2 * code.Padding),
                        (code.Above + code.Below) * span.Scale);
                    var radius = (float)Math.Min(rect.Height / 2, rect.Height * 0.24);
                    ds.FillRoundedRectangle(rect, radius, radius, fill);
                    if (code.Border is { } border && code.BorderWidth > 0)
                    {
                        var inset = code.BorderWidth / 2;
                        var stroke = new Windows.Foundation.Rect(rect.X + inset, rect.Y + inset, Math.Max(0, rect.Width - 2 * inset), Math.Max(0, rect.Height - 2 * inset));
                        ds.DrawRoundedRectangle(stroke, Math.Max(0, radius - (float)inset), Math.Max(0, radius - (float)inset), ToColor(border), (float)code.BorderWidth);
                    }
                }
            }
        }

        if (span.Marker is { } marker)
        {
            using var markerLayout = Layout(device, marker, 10_000, span.FontSize, null, span.Pitch, color, color);
            ds.DrawTextLayout(markerLayout, (float)span.Source.MinX, origin.Y, color);
        }

        ds.DrawTextLayout(layout, origin, color);
    }

    /// <summary>量和画共用的一份排版：正文系统字体；代码词等宽字体、小一点、自己的颜色，前后各让出一个留白的宽度。</summary>
    internal static CanvasTextLayout Layout(
        CanvasDevice device, string text, double width, double fontSize, OverlayCode? code, double pitch, Color color, Color codeColor)
    {
        var format = new CanvasTextFormat
        {
            FontFamily = BodyFont,
            FontSize = (float)Math.Max(1, fontSize),
            WordWrapping = CanvasWordWrapping.Wrap,
        };
        if (pitch > 0)
        {
            format.LineSpacingMode = CanvasLineSpacingMode.Uniform;
            format.LineSpacing = (float)pitch;
            format.LineSpacingBaseline = (float)(pitch * 0.8);
        }

        var layout = new CanvasTextLayout(device, text, format, (float)Math.Max(1, width), 1_000_000);
        format.Dispose();
        if (code is not null)
        {
            foreach (var (start, length) in ScreenshotOverlay.CodeSpans(text, code.Phrases).Ranges)
            {
                layout.SetFontFamily(start, length, CodeFont);
                layout.SetFontSize(start, length, (float)(fontSize * ScreenshotOverlay.CodeScale));
                layout.SetColor(start, length, codeColor);
                // 代码串前一个字后面、最后一个字后面各让出一个留白的宽度：底框不压到旁边的字
                if (start > 0)
                {
                    layout.SetCharacterSpacing(start - 1, 1, 0, (float)code.Padding, 0);
                }

                layout.SetCharacterSpacing(start + length - 1, 1, 0, (float)code.Padding, 0);
            }
        }

        return layout;
    }

    /// <summary>量字：和画同一份排版（折法一致）。</summary>
    private sealed class Win2DMeasure(CanvasDevice device) : ITextMeasure
    {
        public int LineCount(string text, double width, double fontSize, OverlayCode? code)
        {
            using var layout = Layout(device, text, width, fontSize, code, 0, Color.FromArgb(255, 0, 0, 0), Color.FromArgb(255, 0, 0, 0));
            return Math.Max(1, layout.LineCount);
        }

        public double Width(string text, double fontSize)
        {
            using var layout = Layout(device, text, 10_000, fontSize, null, 0, Color.FromArgb(255, 0, 0, 0), Color.FromArgb(255, 0, 0, 0));
            return layout.LayoutBounds.Width;
        }
    }
}
