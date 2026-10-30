// 录屏的点按圈 / 按键胶囊画在 GPU 纹理上（PLAN-v6 第 1 批）：Win2D 的 CanvasRenderTarget 包住
// SinkWriter 要编码的那张 D3D11 纹理，直接在上面画；颜色 / 时长照 RecordingOverlay 的旧实现。
// 只在有点按或按键要显示时才画，平时不碰这张纹理。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.UI;
using Windows.Win32.Graphics.Direct3D11;

namespace KittyTools;

internal sealed class WgcEffects : IDisposable
{
    private readonly CanvasDevice _device;
    private readonly Dictionary<IntPtr, CanvasRenderTarget> _targets = new();

    private WgcEffects(CanvasDevice device)
    {
        _device = device;
    }

    public static WgcEffects? TryCreate(D3DContext context)
    {
        try
        {
            var device = CanvasDevice.CreateFromDirect3D11Device(context.WinRt);
            return new WgcEffects(device);
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.effects-device 0x{ex.HResult:X8}");
            return null;
        }
    }

    /// <summary>
    /// 在 <paramref name="texture"/> 上画；没有要画的就返回 false。scale：输出比录的那一块小多少（「标准」清晰度缩过时 &lt; 1，
    /// 点按圈的位置跟着乘，PLAN-v9 R5）。
    /// </summary>
    public unsafe bool Draw(
        ID3D11Texture2D* texture, int width, int height, int originX, int originY,
        IReadOnlyList<ClickRing> rings, Keycap? keycap, long now, double scale = 1)
    {
        if ((rings.Count == 0 && keycap is null) || width < 2 || height < 2)
        {
            return false;
        }

        CanvasRenderTarget? target = null;
        try
        {
            var key = (IntPtr)texture;
            if (!_targets.TryGetValue(key, out target))
            {
                // 包装用完就关（REVIEW R27）：CanvasRenderTarget 自己拿着这张纹理，包装不关要等 GC 才放设备。
                using var surface = WgcInterop.SurfaceOf(texture);
                target = CanvasRenderTarget.CreateFromDirect3D11Surface(_device, surface);
                _targets[key] = target;
            }

            using var session = target.CreateDrawingSession();
            foreach (var ring in rings)
            {
                var start = ring.DownAt;
                var end = ring.UpAt > start
                    ? Math.Min(ring.UpAt, start + RecordingOverlay.RingDurationMs)
                    : start + RecordingOverlay.RingDurationMs;
                if (now < start || now > end)
                {
                    continue;
                }

                var progress = (double)(now - start) / Math.Max(1, end - start);
                var radius = (float)(8 + (RecordingOverlay.RingMaxRadius - 8) * progress);
                var alpha = (byte)Math.Clamp((int)(200 * (1 - progress)), 20, 200);
                var color = ring.Right
                    ? Theme.Argb(alpha, 74, 144, 255)
                    : Theme.Argb(alpha, 255, 150, 186);
                session.DrawCircle(
                    (float)((ring.X - originX) * scale), (float)((ring.Y - originY) * scale), radius, color,
                    (float)Math.Max(2, 4 - progress * 2));
            }

            if (keycap is { } cap && now - cap.At <= RecordingOverlay.KeycapDurationMs &&
                !string.IsNullOrEmpty(cap.Text))
            {
                var fade = now - cap.At > RecordingOverlay.KeycapDurationMs - 300
                    ? 1 - (now - cap.At - (RecordingOverlay.KeycapDurationMs - 300)) / 300.0
                    : 1.0;
                var alpha = (byte)Math.Clamp((int)(215 * fade), 0, 255);
                using var format = new CanvasTextFormat
                {
                    FontFamily = "Segoe UI Variable",
                    FontSize = 22,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    HorizontalAlignment = CanvasHorizontalAlignment.Center,
                    VerticalAlignment = CanvasVerticalAlignment.Center,
                };
                var textWidth = (float)Math.Min(width - 16, cap.Text.Length * 14 + 28);
                var left = (width - textWidth) / 2;
                var top = height - RecordingOverlay.KeycapHeight - 16;
                session.FillRoundedRectangle(
                    new Windows.Foundation.Rect(left, top, textWidth, RecordingOverlay.KeycapHeight),
                    10, 10, Theme.Argb(alpha, 32, 32, 36));
                session.DrawText(
                    cap.Text,
                    new Windows.Foundation.Rect(left, top, textWidth, RecordingOverlay.KeycapHeight),
                    Theme.Argb(alpha, 250, 250, 252), format);
            }

            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.effects-draw 0x{ex.HResult:X8}");
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
