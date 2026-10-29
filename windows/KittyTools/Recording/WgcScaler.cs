// R29：窗口录制改尺寸时把新画面按比例缩放、居中画进固定大小的输出纹理（四周补黑）。
// PLAN-v9 R5：「标准」清晰度录选区时，把屏幕帧里的那一块（DrawRegion 的源矩形）缩进输出纹理。
// 只在源尺寸 != 输出尺寸时走这里；同尺寸仍然用 D3D11 的 CopySubresourceRegion，避免每帧多一次 Win2D 画。
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.UI;
using Windows.Win32.Graphics.Direct3D11;

namespace KittyTools;

internal sealed unsafe class WgcScaler : IDisposable
{
    private readonly CanvasDevice _device;
    private readonly Dictionary<IntPtr, CanvasRenderTarget> _targets = new();
    private bool _logged;

    private WgcScaler(CanvasDevice device)
    {
        _device = device;
    }

    public static WgcScaler? TryCreate(D3DContext context)
    {
        try
        {
            return new WgcScaler(CanvasDevice.CreateFromDirect3D11Device(context.WinRt));
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.scaler-device 0x{ex.HResult:X8}");
            return null;
        }
    }

    public bool Draw(
        ID3D11Texture2D* source, int sourceWidth, int sourceHeight,
        ID3D11Texture2D* target, int targetWidth, int targetHeight)
        => DrawRegion(source, 0, 0, sourceWidth, sourceHeight, target, targetWidth, targetHeight);

    /// <summary>把源纹理里 (left, top, width, height) 那一块等比缩放、居中画进目标纹理（四周补黑）。</summary>
    public bool DrawRegion(
        ID3D11Texture2D* source, int left, int top, int sourceWidth, int sourceHeight,
        ID3D11Texture2D* target, int targetWidth, int targetHeight)
    {
        if (sourceWidth < 2 || sourceHeight < 2 || targetWidth < 2 || targetHeight < 2)
        {
            return false;
        }

        try
        {
            using var bitmap = CanvasBitmap.CreateFromDirect3D11Surface(
                _device, WgcInterop.SurfaceOf(source));
            var key = (IntPtr)target;
            if (!_targets.TryGetValue(key, out var renderTarget))
            {
                renderTarget = CanvasRenderTarget.CreateFromDirect3D11Surface(
                    _device, WgcInterop.SurfaceOf(target));
                _targets[key] = renderTarget;
            }

            using var session = renderTarget.CreateDrawingSession();
            if (!_logged)
            {
                _logged = true;
                Log.Info($"wgc.scaled {sourceWidth}x{sourceHeight}->{targetWidth}x{targetHeight}");
            }
            session.Clear(Colors.Black);
            // 等比缩放到输出框内，居中；窗口变小 / 变大都补黑。
            var scale = Math.Min((double)targetWidth / sourceWidth, (double)targetHeight / sourceHeight);
            var width = sourceWidth * scale;
            var height = sourceHeight * scale;
            session.DrawImage(
                bitmap,
                new Windows.Foundation.Rect((targetWidth - width) / 2, (targetHeight - height) / 2, width, height),
                new Windows.Foundation.Rect(left, top, sourceWidth, sourceHeight));
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.scale-failed 0x{ex.HResult:X8}");
            return false;
        }
    }

    public void Dispose()
    {
        foreach (var target in _targets.Values)
        {
            target.Dispose();
        }

        _targets.Clear();
        _device.Dispose();
    }
}
