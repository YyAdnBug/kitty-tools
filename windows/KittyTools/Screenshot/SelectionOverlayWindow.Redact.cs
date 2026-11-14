// 截图遮罩里的一键打码（PLAN-v18 S17，mac ee303f55）：打码工具托盘最后的「自动」。识出选区里的字（OcrService，看的是屏幕上现在的样子），
// 手机号、邮箱、银行卡号、身份证号各加一块普通打码标注（当前打码的样式），一起记一步撤销；找哪几段、换成哪几块在 Core Redaction。
// 识字途中：选区变了这次作废；拖着标注就等松手再落；复制、保存、钉图等它做完再出图（ScreenshotSession.SelectionPngAsync 等
// RedactionDone），不让号码跟着图出去。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    private Task? _redaction;

    /// <summary>正在识字找要打码的：出图之前等它。</summary>
    public Task RedactionDone => _redaction ?? Task.CompletedTask;

    private void AutoRedact()
    {
        if (_redaction is { IsCompleted: false } || !_session.HasSelection || _session.SelectionScreen != _screen)
        {
            return;
        }

        _redaction = RedactAsync();
    }

    private async Task RedactAsync()
    {
        CommitText();
        var selection = _session.Selection;
        var rect = ScreenshotOutput.SelectionPixels(_screen, selection);
        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        if (width < 8 || height < 8)
        {
            return;
        }

        var crop = _screen.Crop(rect);
        Flash("正在找手机号、邮箱、卡号、身份证号…", 30_000);
        string message;
        try
        {
            var (_, lines) = await OcrService.RecognizeAsync(crop, width, height, joined: false);
            if (_session.SelectionScreen != _screen || _session.Selection != selection)
            {
                Flash("选区变了，这次没打码", 2000);
                return;
            }

            var area = new RectD(rect.Left, rect.Top, width, height);
            var boxes = Redaction.Boxes(lines).Select(box => box.Offset(rect.Left, rect.Top));
            var existing = _document.Items.Where(item => item.Kind == AnnotationKind.Mosaic).Select(item => item.Rect);
            var areas = Redaction.Areas(boxes, area, existing, 3 * _scale, 2 * _scale);
            while (IsDraggingAnnotation)
            {
                await Task.Delay(50);
            }

            if (areas.Count == 0)
            {
                message = "没找到手机号、邮箱、卡号、身份证号";
            }
            else
            {
                var style = _tool == AnnotationKind.Mosaic ? _style : AnnotationStyle.DefaultFor(AnnotationKind.Mosaic);
                var added = areas.Select(box => new Annotation { Kind = AnnotationKind.Mosaic, Rect = box, Style = style }).ToList();
                _document.Commit(_document.Items.Concat(added));
                UpdateToolbarChrome();
                _canvas.Invalidate();
                message = $"打码了 {added.Count} 处";
            }

            Log.Info($"screenshot.auto-redact count={areas.Count}");
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.auto-redact-failed {ex.GetType().Name}");
            message = "识字没成，这次没打码";
        }

        Flash(message, 2000);
    }
}
