// 截图翻译原位覆盖和文字钉图的自检（PLAN-v16 第 2 批，Windows 自己加的）：`--overlay-translate-probe=<目录>`（只在测试档）。
// 不联网、不发按键：用 Win2D 画几张样图（浅色页面、深色页面带行内代码块、列表），走真的识字（OcrService，带词框）→ 分段 →
// 换成写死的中文译文（代码词原样留着）→ 真的合成和画字（ScreenshotTranslator.Render），存 <名字>-before.png / -after.png；
// 再把三段文字（短句、带缩进的代码、截断的长段）排成钉图卡片，浅色 / 深色各一张。结果写 report.md，跑完就退。
// 对齐复查 R103 加了 mac PR #25 的两组样图（照 mac ScreenshotPopoverTests、ScreenshotReadingTests 的坐标画）：带标题、「New」标签、
// 正文、按钮的气泡（1 倍 / 150 % / 2 倍：分 4 段、标签和按钮居中、描边不动、译后识字认得出），四段英文文章（1 倍 / 2 倍：全排进图、字号）。
// 分段一律走截图翻译那条路（ScreenshotOverlay.Prepare），报告里写每段的容器和排出来的字号。
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

                // 和截图翻译同一条路：按容器和字色分段、顺手量好（对齐复查 R103）
                var segments = await Task.Run(() => ScreenshotOverlay.Prepare(lines, new OverlayPixels(bgra, width, height, width * 4)));
                Check(segments.Count == sample.Paragraphs.Length, $"{sample.Name}：分成 {segments.Count} 段（样图 {sample.Paragraphs.Length} 段）");
                var translations = segments.Select(Translate).ToList();
                var (after, leftovers) = await Task.Run(() => ScreenshotTranslator.Render(bgra, width, height, segments, translations));
                Check(after is not null, $"{sample.Name}：合成出图");
                report.Append($"  放不下的段：{leftovers.Count}").Append('\n');
                if (after is null)
                {
                    continue;
                }

                await SavePngAsync(after, width, height, Path.Combine(directory, $"{sample.Name}-after.png"));
                foreach (var segment in segments)
                {
                    report.Append($"  段：{segment.LineCount} 行，行高 {segment.LineHeight:F1}，基线 {segment.Baseline?.ToString("F0") ?? "-"}，" +
                                  $"行距 {segment.Pitch?.ToString("F1") ?? "-"}，代码块 {(segment.Code is { } code ? string.Join(" / ", code.Phrases.Select(phrase => string.Join(" ", phrase))) : "无")}，" +
                                  $"容器 {(segment.Container is { } box ? $"{box.Width:F0}×{box.Height:F0}" : "无")}\n");
                }

                ReportSizes(report, LaidOut(bgra, width, height, segments, translations, 1), 1);
                if (sample.Code is not null)
                {
                    Check(segments.Any(segment => segment.Code is not null), $"{sample.Name}：认出行内代码块");
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
                        var segments = await Task.Run(() => ScreenshotOverlay.Prepare(cropLines, new OverlayPixels(crop, width, cropHeight, width * 4)));
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

            // 气泡（对齐复查 R103，照 mac ScreenshotPopoverTests）：标题、右上角描边的「New」标签、正文、「Got it」按钮分开翻；
            // 标签和按钮的译文在里面居中、描边一个像素不动；1 倍、150 %、2 倍各一次
            foreach (var scale in new[] { 1.0, 1.5, 2.0 })
            {
                var name = $"popover-{scale:0.#}x";
                var (bgra, width, height) = DrawPopover(scale);
                await SavePngAsync(bgra, width, height, Path.Combine(directory, $"{name}-before.png"));
                var (_, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: false);
                var segments = await Task.Run(() => ScreenshotOverlay.Prepare(lines, new OverlayPixels(bgra, width, height, width * 4)));
                var texts = string.Join(" | ", segments.Select(segment => segment.Text));
                Check(segments.Count == 4, $"{name}：标题、标签、正文、按钮分成 4 段（{segments.Count}：{texts}）");
                Check(segments.Any(segment => segment.Text.Equals("new", StringComparison.OrdinalIgnoreCase)), $"{name}：标签单独一段");
                var translations = segments.Select(segment =>
                {
                    var lower = segment.Text.ToLowerInvariant();
                    return lower == "new" ? "新建"
                        : lower.Contains("pin your", StringComparison.Ordinal) ? "固定你的主页"
                        : lower.Contains("got", StringComparison.Ordinal) ? "知道了"
                        : "选择 github.com 打开时显示主页还是动态内容。在其中一个旁边选择固定选项。";
                }).ToList();
                var started = Environment.TickCount64;
                var (after, leftovers) = await Task.Run(() => ScreenshotTranslator.Render(bgra, width, height, segments, translations, scale));
                report.Append($"  合成 {Environment.TickCount64 - started} ms；段的容器：{string.Join(" / ", segments.Select(segment => segment.Container is { } box ? $"{box.Width:F0}×{box.Height:F0}{(segment.IsControl ? " 控件" : segment.IsHeading ? " 标题" : string.Empty)}" : "无"))}").Append('\n');
                ReportSizes(report, LaidOut(bgra, width, height, segments, translations, scale), scale);
                Check(after is not null && leftovers.Count == 0, $"{name}：全部排进图里（放不下 {leftovers.Count} 段）");
                if (after is null)
                {
                    continue;
                }

                await SavePngAsync(after, width, height, Path.Combine(directory, $"{name}-after.png"));
                var (_, afterLines) = await OcrService.RecognizeAsync(after, width, height, joined: false);
                var recognized = string.Concat(afterLines.Select(line => line.Text)).Replace(" ", string.Empty, StringComparison.Ordinal);
                report.Append($"  译后识字：{recognized}").Append('\n');
                Check(recognized.Contains("新建", StringComparison.Ordinal), $"{name}：译后标签认得出（识字引擎要能读中文）");
                Check(recognized.Contains("知道了", StringComparison.Ordinal), $"{name}：译后按钮认得出");
                Check(recognized.Contains("github.com", StringComparison.OrdinalIgnoreCase), $"{name}：正文没被标题的译文盖掉");
                // 容器的描边不是字：标签左边、标签顶边、按钮左右边、气泡左边各一个像素，去字和画字都不能动（点、原点左下，同 mac）
                var changed = new List<string>();
                foreach (var (x, y) in new[] { (524, 303), (562, 322), (64, 81), (162, 81), (30, 200) })
                {
                    var offset = ((height - 1 - (int)(y * scale)) * width + (int)(x * scale)) * 4;
                    for (var channel = 0; channel < 3; channel++)
                    {
                        if (Math.Abs(bgra[offset + channel] - after[offset + channel]) > 1)
                        {
                            changed.Add($"({x},{y})");
                            break;
                        }
                    }
                }

                Check(changed.Count == 0, $"{name}：描边没动（动了的点：{string.Join(" ", changed)}）");
            }

            // 文章（对齐复查 R103，照 mac ScreenshotReadingTests）：深底灰字 16 号的四段英文译成中文，1 倍、2 倍；
            // 全部排进图里，字号按大写字高还原（mac 的同一张图约 20 像素 / 点）
            foreach (var scale in new[] { 1.0, 2.0 })
            {
                var name = $"article-{scale:0.#}x";
                var (bgra, width, height) = DrawArticle(scale);
                await SavePngAsync(bgra, width, height, Path.Combine(directory, $"{name}-before.png"));
                var (_, lines) = await OcrService.RecognizeAsync(bgra, width, height, joined: false);
                var segments = await Task.Run(() => ScreenshotOverlay.Prepare(lines, new OverlayPixels(bgra, width, height, width * 4)));
                Check(segments.Count == 4, $"{name}：分成 4 段（{segments.Count}）");
                var heights = segments.Select(segment => segment.LineHeight / scale).ToList();
                report.Append($"  识字行高（点）：{string.Join(" / ", heights.Select(value => value.ToString("F1")))}").Append('\n');
                Check(heights.All(value => value is > 10 and < 20), $"{name}：识字行高在原文字面范围里（10–20 点；mac 的 Vision 是这样，Windows 的识字框不同就记下来）");
                var translations = ArticleTranslations.Take(segments.Count).ToList();
                var (after, leftovers) = await Task.Run(() => ScreenshotTranslator.Render(bgra, width, height, segments, translations, scale));
                var spans = LaidOut(bgra, width, height, segments, translations, scale);
                ReportSizes(report, spans, scale);
                Check(after is not null && leftovers.Count == 0, $"{name}：全部排进图里（放不下 {leftovers.Count} 段）");
                Check(spans.Count > 0 && spans.All(span => span.FontSize / scale is >= 16 and <= 24), $"{name}：中文字号 16–24 点（原文 16 号）");
                if (after is not null)
                {
                    await SavePngAsync(after, width, height, Path.Combine(directory, $"{name}-after.png"));
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

    /// <summary>mac ScreenshotReadingTests 里那四段的译文（原样）。</summary>
    private static readonly string[] ArticleTranslations =
    {
        "Claude Haiku 4.5 将继续为个人 GitHub Copilot 订阅者提供年度计划服务。Claude Haiku 4.5 的弃用不适用于这些客户。",
        "请在此日期之前更新您的工作流程和集成，以使用支持的模型。在默认模型启用下，建议的替代方案会自动为 Copilot Enterprise 和 Copilot Business 客户启用，除非管理员关闭了全局默认设置或明确禁用了该模型。如果您关闭了全局默认设置，可以通过 Copilot 设置中的模型策略启用替代模型的访问权限。",
        "启用后，用户将在受支持的 GitHub Copilot 体验中的 Copilot 聊天模型选择器中看到该模型。模型停用后无需采取任何操作即可移除。",
        "如有疑问或顾虑，GitHub Enterprise 客户可联系其账户团队以获取帮助。",
    };

    /// <summary>和 Render 同一套去字前的排版，只拿排好的段（报告里写字号）。</summary>
    private static List<OverlaySpan> LaidOut(
        byte[] bgra, int width, int height, IReadOnlyList<OverlaySegment> segments, IReadOnlyList<string> translations, double pixelsPerPoint)
        => ScreenshotOverlay.Compose(
                new OverlayPixels((byte[])bgra.Clone(), width, height, width * 4), segments, translations,
                new ScreenshotTranslator.Win2DMeasure(CanvasDevice.GetSharedDevice()), pixelsPerPoint)
            .Spans.Select(item => item.Span).ToList();

    private static void ReportSizes(StringBuilder report, IReadOnlyList<OverlaySpan> spans, double scale)
        => report.Append($"  排出来的字号（点）：{string.Join(" / ", spans.Select(span => (span.FontSize / scale).ToString("F1") + (span.Bold ? " 粗" : string.Empty)))}").Append('\n');

    private static Color Rgb(byte red, byte green, byte blue) => Color.FromArgb(255, red, green, blue);

    /// <summary>按基线画一行字（点、原点左下，同 mac 的 CTLineDraw）：等行距排版，基线在行顶下 1.6 个字号。</summary>
    private static void Label(CanvasDrawingSession ds, float canvasHeight, string text, float x, float baseline, float size, bool bold, Color color)
    {
        using var format = new CanvasTextFormat
        {
            FontFamily = "Arial",
            FontSize = size,
            FontWeight = bold ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Normal,
            WordWrapping = CanvasWordWrapping.NoWrap,
            LineSpacingMode = CanvasLineSpacingMode.Uniform,
            LineSpacing = size * 2,
            LineSpacingBaseline = size * 1.6f,
        };
        ds.DrawText(text, x, canvasHeight - baseline - size * 1.6f, color, format);
    }

    /// <summary>
    /// mac ScreenshotPopoverTests 的气泡（点、原点左下，照原样）：深色页面上一个描边气泡，里面粗体标题、右上角描边的「New」标签、
    /// 三行灰色正文、有底色的「Got it」按钮。按 scale 出像素（DPI = 96 × scale）。
    /// </summary>
    private static (byte[] Bgra, int Width, int Height) DrawPopover(double scale)
    {
        const float width = 636;
        const float height = 400;
        var device = CanvasDevice.GetSharedDevice();
        using var target = new CanvasRenderTarget(device, width, height, (float)(96 * scale), DirectXPixelFormat.B8G8R8A8UIntNormalized, CanvasAlphaMode.Premultiplied);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Rgb(13, 17, 23));
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            foreach (var (x, y, w, h, radius, fill, stroke) in new[]
            {
                (30f, 20f, 604f, 338f, 12f, Rgb(1, 4, 9), Rgb(61, 68, 77)),
                (524f, 284f, 76f, 38f, 19f, Rgb(1, 4, 9), Rgb(47, 129, 247)),
                (64f, 54f, 98f, 54f, 12f, Rgb(33, 40, 48), Rgb(61, 68, 77)),
            })
            {
                var rect = new Windows.Foundation.Rect(x, height - y - h, w, h);
                ds.FillRoundedRectangle(rect, radius, radius, fill);
                ds.DrawRoundedRectangle(rect, radius, radius, stroke, 2);
            }

            Label(ds, height, "Pin your homepage", 64, 294, 28, true, Rgb(230, 237, 243));
            Label(ds, height, "New", 538, 294, 24, false, Rgb(47, 129, 247));
            var body = new[] { "Choose whether github.com opens to", "Home or Feed. Select the pin next to", "either one." };
            for (var index = 0; index < body.Length; index++)
            {
                Label(ds, height, body[index], 64, 235 - index * 42, 28, false, Rgb(139, 148, 158));
            }

            Label(ds, height, "Got it", 82, 73, 24, true, Rgb(230, 237, 243));
        }

        return (target.GetPixelBytes(), (int)target.SizeInPixels.Width, (int)target.SizeInPixels.Height);
    }

    /// <summary>mac ScreenshotReadingTests 的文章（点、原点左下，照原样）：深底灰字 16 号、行距 26 的四段英文。</summary>
    private static (byte[] Bgra, int Width, int Height) DrawArticle(double scale)
    {
        const float width = 677;
        const float height = 490;
        var paragraphs = new (float Baseline, string[] Lines)[]
        {
            (440, new[]
            {
                "Claude Haiku 4.5 will remain available to individual GitHub Copilot subscribers",
                "on annual plans. The deprecation of Claude Haiku 4.5 does not apply to these",
                "customers.",
            }),
            (340, new[]
            {
                "Please update your workflows and integrations to use the supported models",
                "before this date. Under default model enablement, the suggested alternatives are",
                "automatically enabled for Copilot Enterprise and Copilot Business customers",
                "unless an administrator has turned off the global default or explicitly disabled the",
                "model. If you have turned off the global default, you can enable access to the",
                "alternative models through their model policies in Copilot settings.",
            }),
            (163, new[]
            {
                "Once enabled, users will see the model in the Copilot Chat model selector in",
                "supported GitHub Copilot experiences. No action is required to remove the",
                "models after they have been deprecated.",
            }),
            (61, new[]
            {
                "GitHub Enterprise customers with questions or concerns are encouraged to",
                "contact their account team for assistance.",
            }),
        };
        var device = CanvasDevice.GetSharedDevice();
        using var target = new CanvasRenderTarget(device, width, height, (float)(96 * scale), DirectXPixelFormat.B8G8R8A8UIntNormalized, CanvasAlphaMode.Premultiplied);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Rgb(1, 4, 9));
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            foreach (var (baseline, lines) in paragraphs)
            {
                for (var index = 0; index < lines.Length; index++)
                {
                    Label(ds, height, lines[index], 44, baseline - index * 26, 16, false, Rgb(139, 148, 158));
                }
            }
        }

        return (target.GetPixelBytes(), (int)target.SizeInPixels.Width, (int)target.SizeInPixels.Height);
    }

    private static async Task SavePngAsync(byte[] bgra, int width, int height, string path)
    {
        var device = CanvasDevice.GetSharedDevice();
        using var bitmap = CanvasBitmap.CreateFromBytes(device, bgra, width, height, DirectXPixelFormat.B8G8R8A8UIntNormalized);
        await bitmap.SaveAsync(path, CanvasBitmapFileFormat.Png);
    }
}
