// 截图翻译原位覆盖和文字钉图的自检（PLAN-v16 第 2 批，Windows 自己加的）：`--overlay-translate-probe=<目录>`（只在测试档）。
// 不联网、不发按键：用 Win2D 画几张样图（浅色页面、深色页面带行内代码块、列表），走真的识字（OcrService，带词框）→ 分段 →
// 换成写死的中文译文（代码词原样留着）→ 真的合成和画字（ScreenshotTranslator.Render），存 <名字>-before.png / -after.png；
// 再把三段文字（短句、带缩进的代码、截断的长段）排成钉图卡片，浅色 / 深色各一张。结果写 report.md，跑完就退。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.Graphics.DirectX;
using Windows.UI;

namespace KittyTools;

internal static class OverlayTranslateProbe
{
    public const string ArgumentPrefix = "--overlay-translate-probe";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-overlay-translate-probe")
            : Path.GetFullPath(path);
    }

    private sealed record Sample(string Name, Color Background, Color Text, (Color Fill, Color Border, Color Text)? Code, string[] Paragraphs);

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 截图翻译原位覆盖 / 文字钉图自检（PLAN-v16 第 2 批）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        await Task.Delay(1000);
        try
        {
            var samples = new[]
            {
                new Sample("light", Color.FromArgb(255, 255, 255, 255), Color.FromArgb(255, 31, 35, 40), null, new[]
                {
                    "Kitty Tools keeps your clipboard history, translates selected text and takes screenshots.",
                    "Everything stays on this computer. Nothing is uploaded unless you turn on sync.",
                    "• Press the hotkey again to close the panel.",
                }),
                new Sample("dark-code", Color.FromArgb(255, 1, 4, 9), Color.FromArgb(255, 139, 148, 158),
                    (Color.FromArgb(255, 22, 27, 34), Color.FromArgb(255, 48, 54, 61), Color.FromArgb(255, 230, 237, 243)), new[]
                    {
                        "The field `total_count` holds the number of evaluated comments for the day.",
                        "Use `max_size` to limit how many items are returned in one page of results.",
                    }),
            };
            foreach (var sample in samples)
            {
                var (bgra, width, height) = Draw(sample);
                await SavePngAsync(bgra, width, height, Path.Combine(directory, $"{sample.Name}-before.png"));
                var (text, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: true, separator: "\n\n");
                Check(lines.Count > 0, $"{sample.Name}：识字认出 {lines.Count} 行、{lines.Sum(line => line.Words?.Count ?? 0)} 个词");
                foreach (var line in lines)
                {
                    report.Append($"  行「{line.Text}」{line.Box.X:F0},{line.Box.Y:F0} {line.Box.Width:F0}×{line.Box.Height:F0}").Append('\n');
                }

                var segments = ScreenshotOverlay.Segments(lines, width, height);
                Check(segments.Count == sample.Paragraphs.Length, $"{sample.Name}：分成 {segments.Count} 段（样图 {sample.Paragraphs.Length} 段）");
                var snapshot = new OverlayPixels((byte[])bgra.Clone(), width, height, width * 4);
                var translations = segments.Select(segment => Translate(ScreenshotOverlay.Measure(segment, snapshot))).ToList();
                var (after, leftovers) = await Task.Run(() => ScreenshotTranslator.Render(bgra, width, height, segments, translations));
                Check(after is not null, $"{sample.Name}：合成出图");
                report.Append($"  放不下的段：{leftovers.Count}").Append('\n');
                if (after is null)
                {
                    continue;
                }

                await SavePngAsync(after, width, height, Path.Combine(directory, $"{sample.Name}-after.png"));
                var pixels = new OverlayPixels(bgra, width, height, width * 4).Snapshot();
                var measured = segments.Select(segment => ScreenshotOverlay.Measure(segment, pixels)).ToList();
                foreach (var segment in measured)
                {
                    report.Append($"  段：{segment.LineCount} 行，行高 {segment.LineHeight:F1}，基线 {segment.Baseline?.ToString("F0") ?? "-"}，" +
                                  $"行距 {segment.Pitch?.ToString("F1") ?? "-"}，代码块 {(segment.Code is { } code ? string.Join(" / ", code.Phrases.Select(phrase => string.Join(" ", phrase))) : "无")}\n");
                }

                if (sample.Code is not null)
                {
                    Check(measured.Any(segment => segment.Code is not null), $"{sample.Name}：认出行内代码块");
                }

                // 合成后原文的字去掉了：英文字母的像素少了一大截（译文是中文，换了位置）
                Check(!bgra.SequenceEqual(after), $"{sample.Name}：图变了");
                Log.Info($"overlay-probe sample={sample.Name} text={text.Length}");
            }

            // 小选区（PLAN-v18 S7，150 %）：只框浅色样图的第二段那一行。紧贴着框：到 10 pt 也放不下，图不变、整段进卡片；
            // 上下各留 40 像素：用上周围的空白排，不进卡片
            {
                var light = samples[0];
                var (bgra, width, height) = Draw(light);
                var (_, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: false);
                if (lines.FirstOrDefault(line => line.Text.StartsWith("Everything", StringComparison.Ordinal)) is { } line)
                {
                    var longText = string.Concat(Enumerable.Repeat("这是一段比原文长得多的译文，得折成好几行才放得下。", 3));
                    foreach (var (name, margin, expectLeftover) in new[] { ("tight", 3, true), ("roomy", 40, false) })
                    {
                        var top = Math.Max(0, (int)line.Box.Y - margin);
                        var bottom = Math.Min(height, (int)Math.Ceiling(line.Box.Bottom) + margin);
                        var cropHeight = bottom - top;
                        var crop = new byte[width * cropHeight * 4];
                        Array.Copy(bgra, top * width * 4, crop, 0, crop.Length);
                        var (_, cropLines) = await OcrService.RecognizeAsync(crop, width, cropHeight, joined: true, separator: "\n\n");
                        var segments = ScreenshotOverlay.Segments(cropLines, width, cropHeight);
                        var translations = segments.Select(_ => longText).ToList();
                        var (after, leftovers) = await Task.Run(
                            () => ScreenshotTranslator.Render(crop, width, cropHeight, segments, translations, pixelsPerPoint: 1.5));
                        Check(segments.Count == 1 && (expectLeftover ? after is null && leftovers.Count == 1 : after is not null && leftovers.Count == 0),
                            $"小选区 {name}（高 {cropHeight}）：{segments.Count} 段，{(after is null ? "图没变" : "盖了译文")}，放不下 {leftovers.Count} 段");
                        await SavePngAsync(after ?? crop, width, cropHeight, Path.Combine(directory, $"small-{name}-after.png"));
                    }
                }
                else
                {
                    Check(false, "小选区：样图里没认出第二段那一行");
                }
            }

            // 一键打码（PLAN-v18 S17，照 mac recognizesOnARenderedImage）：三行里电话、邮箱给框，订单号不给
            {
                var redact = new Sample("redact", Color.FromArgb(255, 255, 255, 255), Color.FromArgb(255, 31, 35, 40), null, new[]
                {
                    "电话 138 0013 8000", "订单号 2026111200384756", "邮箱 kitty@example.com",
                });
                var (bgra, width, height) = Draw(redact);
                await SavePngAsync(bgra, width, height, Path.Combine(directory, "redact-before.png"));
                var (_, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: false);
                foreach (var line in lines)
                {
                    report.Append($"  打码样图的行「{line.Text}」，词：{string.Join(" | ", line.Words?.Select(word => word.Text) ?? Array.Empty<string>())}").Append('\n');
                }

                var boxes = KittyTools.Core.Redaction.Boxes(lines);
                Check(boxes.Count == 2, $"一键打码：认出 {boxes.Count} 处（该 2：电话、邮箱）");
                static bool SameRow(KittyTools.Core.RectD box, KittyTools.Core.RectD line) => box.Y < line.Bottom && box.Bottom > line.Y;
                Check(boxes.Count == 2 && lines.Count == 3 && SameRow(boxes[0], lines[0].Box) && SameRow(boxes[1], lines[2].Box),
                    "一键打码：第一处在电话那行、第二处在邮箱那行");
            }

            // 文字钉图卡片
            var cards = new (string Name, string Text)[]
            {
                ("short", "你好，Kitty Tools"),
                ("code", "  if (ready) {\n      Start();\n  }"),
                ("long", string.Concat(Enumerable.Repeat("很长的一段文字，会折行、超过上限后截到整行并补省略号。", 60))),
            };
            foreach (var dark in new[] { false, true })
            {
                foreach (var (name, body) in cards)
                {
                    var card = await PinTextCard.RenderAsync(body, 1, 560, 400, dark);
                    Check(card is { Width: > 0, Height: > 0 } && card.Value.Width <= 560 && card.Value.Height <= 400,
                        $"文字卡片 {name}（{(dark ? "深" : "浅")}）：{card?.Width} × {card?.Height}（上限 560 × 400）");
                    if (card is { } image)
                    {
                        await File.WriteAllBytesAsync(Path.Combine(directory, $"pin-text-{name}-{(dark ? "dark" : "light")}.png"), image.Png);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            report.Append($"\n**{(failures == 0 ? "全过" : $"{failures} 条不对")}**\n");
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info($"overlay-translate-probe done failures={failures}");
            Environment.Exit(0);
        }
    }

    /// <summary>写死的译文：长短跟原文走，代码词原样留着（看代码块跟着词走）。</summary>
    private static string Translate(OverlaySegment segment)
    {
        var words = segment.Code?.Phrases.Select(phrase => string.Join(" ", phrase)).ToList() ?? new List<string>();
        var marker = OcrText.ListMarker(segment.Text) is not null ? "• " : string.Empty;
        var body = segment.Text.Length > 60
            ? "这是一段译文，按原来的位置盖回截图上，字色和行距照原文" + (words.Count > 0 ? $"，字段 {words[0]} 留着原样" : "，段落太长时先缩字号再借下面的空白") + "。"
            : "再按一次快捷键收起面板。";
        return marker + body;
    }

    private static (byte[] Bgra, int Width, int Height) Draw(Sample sample)
    {
        const int width = 900;
        var height = 90 + sample.Paragraphs.Length * 90;
        var device = CanvasDevice.GetSharedDevice();
        using var target = new CanvasRenderTarget(device, width, height, 96, DirectXPixelFormat.B8G8R8A8UIntNormalized, CanvasAlphaMode.Premultiplied);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(sample.Background);
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            using var format = new CanvasTextFormat { FontFamily = "Segoe UI", FontSize = 22, WordWrapping = CanvasWordWrapping.Wrap };
            var y = 40f;
            foreach (var paragraph in sample.Paragraphs)
            {
                var plain = paragraph.Replace("`", string.Empty, StringComparison.Ordinal);
                using var layout = new CanvasTextLayout(device, plain, format, width - 80, 400);
                if (sample.Code is { } code)
                {
                    // 反引号里的词画成行内代码块：底色、描边、等宽字
                    var start = paragraph.IndexOf('`');
                    var end = start >= 0 ? paragraph.IndexOf('`', start + 1) : -1;
                    if (start >= 0 && end > start)
                    {
                        var length = end - start - 1;
                        layout.SetFontFamily(start, length, "Cascadia Mono, Consolas");
                        layout.SetColor(start, length, code.Text);
                        foreach (var region in layout.GetCharacterRegions(start, length))
                        {
                            var bounds = region.LayoutBounds;
                            var rect = new Windows.Foundation.Rect(40 + bounds.X - 6, y + bounds.Y - 3, bounds.Width + 12, bounds.Height + 6);
                            ds.FillRoundedRectangle(rect, 6, 6, code.Fill);
                            ds.DrawRoundedRectangle(rect, 6, 6, code.Border, 1);
                        }
                    }
                }

                ds.DrawTextLayout(layout, 40, y, sample.Text);
                y += (float)layout.LayoutBounds.Height + 34;
            }
        }

        return (target.GetPixelBytes(), width, height);
    }

    private static async Task SavePngAsync(byte[] bgra, int width, int height, string path)
    {
        var device = CanvasDevice.GetSharedDevice();
        using var bitmap = CanvasBitmap.CreateFromBytes(device, bgra, width, height, DirectXPixelFormat.B8G8R8A8UIntNormalized);
        await bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png);
    }
}
