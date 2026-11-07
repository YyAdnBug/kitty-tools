// 截图遮罩里的就地翻译（PLAN-v16 S1，mac SelectionView.translateInPlace）：设置 › 翻译「截图翻译时把译文直接盖回截图上」开着时，
// 截图翻译（框完松手自动翻）和工具栏的「翻译」都不收起遮罩——选区上一条浅白扫光等待（1.1 s 一轮，减弱动态效果时只压暗），
// 翻完把译文图贴回冻结帧的选区位置；已经画的标注留着（它们一直画在冻结帧上面），人还在截图页，可以接着标注 / 复制 / 保存。
// Esc、收起遮罩、右键重新框都停掉翻译（取消点在每段开头，取消后不再发新请求）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    private const double SweepSeconds = 1.1;

    private CancellationTokenSource? _translateCts;
    private bool _translating;
    private long _translateStarted;

    /// <summary>就地翻译中（选区上扫光）。</summary>
    public bool IsTranslating => _translating;

    /// <summary>就地翻译选区：裁出冻结帧（不带标注）→ 识字、逐段翻译、合成 → 贴回冻结帧。</summary>
    public async void TranslateInPlace()
    {
        if (_translating || !_session.HasSelection || _session.SelectionScreen != _screen)
        {
            return;
        }

        CommitText();
        var rect = ScreenshotOutput.SelectionPixels(_screen, _session.Selection);
        if (rect.Width < 2 || rect.Height < 2)
        {
            return;
        }

        var crop = _screen.Crop(rect);
        var cts = new CancellationTokenSource();
        _translateCts = cts;
        _translating = true;
        _translateStarted = Environment.TickCount64;
        if (!Motion.Reduced)
        {
            CompositionTarget.Rendering += OnTranslateFrame;
        }

        _canvas.Invalidate();
        Log.Info("screenshot.overlay-begin");
        string message;
        try
        {
            var patch = await ScreenshotTranslator.TranslateAsync(crop, rect.Width, rect.Height, (index, count) =>
            {
                if (!cts.IsCancellationRequested)
                {
                    Flash($"翻译中… {index}/{count}", 60_000);
                }
            }, cts.Token);
            if (cts.IsCancellationRequested || _screen.Bgra.Length == 0)
            {
                return;
            }

            Paste(patch, rect);
            message = "已替换为译文";
            Log.Info("screenshot.overlay-done");
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (ScreenshotTranslator.Failure failure)
        {
            message = failure.Message;
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.overlay-failed {ex.GetType().Name}");
            message = ex is TranslateError ? ex.Message : "翻译失败";
            NoticeHost.Show("翻译失败", message, NoticeTone.Error);
        }
        finally
        {
            if (ReferenceEquals(_translateCts, cts))
            {
                StopTranslating();
            }

            cts.Dispose();
        }

        Flash(message, 2000);
    }

    /// <summary>停掉就地翻译：Esc 收起截图、右键重新框、这块屏被清掉时都要调。</summary>
    public void CancelTranslation()
    {
        if (_translateCts is { } cts)
        {
            cts.Cancel();
        }

        StopTranslating();
    }

    private void StopTranslating()
    {
        _translateCts = null;
        CompositionTarget.Rendering -= OnTranslateFrame;
        if (!_translating)
        {
            return;
        }

        _translating = false;
        _flash = null;
        _canvas.Invalidate();
    }

    private void OnTranslateFrame(object? sender, object args) => _canvas.Invalidate();

    /// <summary>顶部提示临时换成一句（mac flashHint）。</summary>
    private void Flash(string text, int milliseconds)
    {
        _flash = text;
        _flashUntil = Environment.TickCount64 + milliseconds;
        _canvas.Invalidate();
    }

    /// <summary>把译文图贴回冻结帧的选区位置；冻结帧的位图、画好的标注缓存（马赛克读的是冻结帧）重建。</summary>
    private void Paste(byte[] patch, PixelBounds rect)
    {
        var width = rect.Right - rect.Left;
        for (var row = 0; row < rect.Bottom - rect.Top; row++)
        {
            Buffer.BlockCopy(patch, row * width * 4, _screen.Bgra, ((rect.Top + row) * _screen.Width + rect.Left) * 4, width * 4);
        }

        _bitmap?.Dispose();
        _bitmap = null;
        _layer?.Dispose();
        _layer = null;
        _layerItems = null;
        _canvas.Invalidate();
    }

    /// <summary>
    /// 翻译中：选区先压暗一点（白底上白光叠白也看得出），再一条浅白渐变从左扫到右（1.1 s 一轮，缓进缓出）；
    /// 减弱动态效果时不扫，只留压暗那一层。
    /// </summary>
    private void DrawTranslating(CanvasDrawingSession ds, RectD selection)
    {
        if (!_translating)
        {
            return;
        }

        var rect = new Windows.Foundation.Rect(
            selection.X / _scale, selection.Y / _scale, selection.Width / _scale, selection.Height / _scale);
        ds.FillRectangle(rect, Color.FromArgb(26, 0, 0, 0));
        if (Motion.Reduced)
        {
            return;
        }

        var band = Math.Max(60, rect.Width * 0.5);
        var distance = rect.Width + band;
        var t = (Environment.TickCount64 - _translateStarted) / 1000.0 / SweepSeconds % 1;
        var eased = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
        var left = rect.X - band + eased * distance;
        using var layer = ds.CreateLayer(1, rect);
        using var brush = new CanvasLinearGradientBrush(ds, new[]
        {
            new CanvasGradientStop { Position = 0, Color = Color.FromArgb(0, 255, 255, 255) },
            new CanvasGradientStop { Position = 0.5f, Color = Color.FromArgb(140, 255, 255, 255) },
            new CanvasGradientStop { Position = 1, Color = Color.FromArgb(0, 255, 255, 255) },
        })
        {
            StartPoint = new System.Numerics.Vector2((float)left, 0),
            EndPoint = new System.Numerics.Vector2((float)(left + band), 0),
        };
        ds.FillRectangle(new Windows.Foundation.Rect(left, rect.Y, band, rect.Height), brush);
    }
}
