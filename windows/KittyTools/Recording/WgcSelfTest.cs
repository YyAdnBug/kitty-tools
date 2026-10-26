// WGC 自检（PLAN-v6 第 1 批）：建 D3D 设备、抓主屏 2 秒，记下帧数 / 尺寸 / 纹理格式。
// 只用来确认 WGC + DXGI 这条链在这台机器上能跑；正常录屏走 WgcRecorder。
using System.Diagnostics;
using KittyTools.Infrastructure;
using Windows.Graphics.Capture;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi.Common;
using Windows.Win32.Graphics.Gdi;

namespace KittyTools;

internal static unsafe class WgcSelfTest
{
    public static void Run()
    {
        D3DContext? context = null;
        try
        {
            context = D3DContext.Create(out var error);
            if (context is null)
            {
                Log.Info($"wgc.probe d3d-failed {error}");
                return;
            }

            var monitor = PInvoke.MonitorFromPoint(
                new System.Drawing.Point(0, 0), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTOPRIMARY);
            var item = WgcInterop.ForMonitor((IntPtr)monitor.Value);
            if (item is null)
            {
                Log.Info("wgc.probe no-item");
                return;
            }

            var frames = 0;
            var width = 0;
            var height = 0;
            var format = DXGI_FORMAT.DXGI_FORMAT_UNKNOWN;
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                context.WinRt, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                2, item.Size);
            pool.FrameArrived += (sender, _) =>
            {
                using var frame = sender.TryGetNextFrame();
                ID3D11Texture2D* texture = null;
                try
                {
                    using var surface = frame.Surface;
                    texture = WgcInterop.TextureOf(surface);
                    D3D11_TEXTURE2D_DESC desc;
                    texture->GetDesc(&desc);
                    format = desc.Format;
                    width = (int)desc.Width;
                    height = (int)desc.Height;
                    frames++;
                }
                catch (Exception ex)
                {
                    Log.Warn($"wgc.probe-frame-failed 0x{ex.HResult:X8}");
                }
                finally
                {
                    if (texture is not null)
                    {
                        texture->Release();
                    }
                }
            };
            using var session = pool.CreateCaptureSession(item);
            try
            {
                session.IsCursorCaptureEnabled = false;
            }
            catch
            {
                // 老系统没有这个属性。
            }

            try
            {
                session.IsBorderRequired = false;
            }
            catch
            {
                // 同上。
            }

            var watch = Stopwatch.StartNew();
            session.StartCapture();
            Thread.Sleep(2000);
            session.Dispose();
            Log.Info($"wgc.probe frames={frames} size={width}x{height} format={format} ms={watch.ElapsedMilliseconds}");
        }
        catch (Exception ex)
        {
            Log.Error("wgc.probe-failed", ex);
        }
        finally
        {
            context?.Dispose();
        }
    }
}
