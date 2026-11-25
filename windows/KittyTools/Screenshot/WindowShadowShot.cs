// 单击窗口截图带透明圆角和阴影（PLAN-v26 S3，照 mac 0.10.1 10875af2，Windows 的做法）：设置 › 截图「窗口截图带阴影」开着、单击的是整扇窗口、
// 还没画标注时，出图不从冻结帧里裁，而是用 Windows.Graphics.Capture 单独抓那一扇窗口——被别的窗口挡住的地方也是它自己的内容；
// 四角按窗口自己的圆角挖透明（Windows 11 默认 8 DIP，DWMWA_WINDOW_CORNER_PREFERENCE 说不要圆角的、最大化的、Windows 10 是直角，小圆角 4），
// 四周用 Win2D 的 ShadowEffect 画一圈阴影（参数接近系统窗口的阴影：往下 6、模糊 12、0.4 黑）。抓不到（最小化、WGC 建不起来、3 秒没帧）返回 null，
// 调用方照旧按矩形从冻结帧裁。
// ponytail: 画了标注的不走这里（标注的坐标是冻结帧的，挪到带阴影的图上要整体平移，先不做）；抓的是这一刻的窗口，和冻结的那一帧可能差一点。
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static partial class WindowShadowShot
{
    /// <summary>阴影的几何（DIP）：四周留白、往下偏、模糊。</summary>
    private const float Margin = 32;
    private const float OffsetY = 6;
    private const float Blur = 12;

    public static async Task<byte[]?> CaptureAsync(IntPtr hwnd, double scale)
    {
        if (hwnd == IntPtr.Zero || IsIconic(hwnd))
        {
            return null;
        }

        D3DContext? context = null;
        try
        {
            context = D3DContext.Create(out _);
            if (context is null || WgcInterop.ForWindow(hwnd) is not { } item)
            {
                return null;
            }

            var arrived = new TaskCompletionSource<SoftwareBitmap>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(context.WinRt, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
            pool.FrameArrived += async (sender, _) =>
            {
                try
                {
                    using var frame = sender.TryGetNextFrame();
                    if (frame is null || arrived.Task.IsCompleted)
                    {
                        return;
                    }

                    var copy = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied);
                    if (!arrived.TrySetResult(copy))
                    {
                        copy.Dispose();
                    }
                }
                catch (Exception ex)
                {
                    arrived.TrySetException(ex);
                }
            };
            using var session = pool.CreateCaptureSession(item);
            try
            {
                session.IsCursorCaptureEnabled = false;
                session.IsBorderRequired = false;
            }
            catch
            {
                // 老系统没有这两个属性：抓的时候窗口边上会闪一下黄框，图里没有
            }

            session.StartCapture();
            if (await Task.WhenAny(arrived.Task, Task.Delay(3000)) != arrived.Task)
            {
                Log.Warn("screenshot.window-shadow timeout");
                return null;
            }

            using var bitmap = await arrived.Task;
            return await ComposeAsync(bitmap, (float)scale, CornerRadius(hwnd));
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.window-shadow failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return null;
        }
        finally
        {
            context?.Dispose();
        }
    }

    private static async Task<byte[]> ComposeAsync(SoftwareBitmap window, float scale, float cornerDip)
    {
        var device = CanvasDevice.GetSharedDevice();
        using var source = CanvasBitmap.CreateFromSoftwareBitmap(device, window);
        var width = window.PixelWidth;
        var height = window.PixelHeight;
        var margin = (int)Math.Round(Margin * scale);
        var corner = cornerDip * scale;

        // 先把窗口按圆角挖成一张透明底的图（阴影也照这个形状投）
        using var rounded = new CanvasRenderTarget(device, width, height, 96);
        using (var ds = rounded.CreateDrawingSession())
        {
            ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            if (corner > 0)
            {
                using var clip = CanvasGeometry.CreateRoundedRectangle(ds, 0, 0, width, height, corner, corner);
                using (ds.CreateLayer(1, clip))
                {
                    ds.DrawImage(source);
                }
            }
            else
            {
                ds.DrawImage(source);
            }
        }

        using var target = new CanvasRenderTarget(device, width + margin * 2, height + margin * 2, 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            using var shadow = new ShadowEffect
            {
                Source = rounded,
                BlurAmount = Blur * scale / 3,
                ShadowColor = Windows.UI.Color.FromArgb(102, 0, 0, 0),
            };
            ds.DrawImage(shadow, margin, margin + OffsetY * scale);
            ds.DrawImage(rounded, margin, margin);
        }

        using var stream = new InMemoryRandomAccessStream();
        await target.SaveAsync(stream, CanvasBitmapFileFormat.Png);
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }

    /// <summary>窗口自己的圆角（DIP）：Windows 11 默认 8、小圆角 4；说了不要圆角的、最大化的、Windows 10 是 0。</summary>
    private static float CornerRadius(IntPtr hwnd)
    {
        if (Environment.OSVersion.Version.Build < 22000 || IsZoomed(hwnd))
        {
            return 0;
        }

        var preference = 0;
        // DWMWA_WINDOW_CORNER_PREFERENCE = 33：0 默认、1 不要圆角、2 圆角、3 小圆角
        if (DwmGetWindowAttribute(hwnd, 33, out preference, sizeof(int)) < 0)
        {
            preference = 0;
        }

        return preference switch
        {
            1 => 0,
            3 => 4,
            _ => 8,
        };
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsZoomed(IntPtr hwnd);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
}
