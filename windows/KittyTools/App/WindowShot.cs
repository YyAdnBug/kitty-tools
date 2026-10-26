// REVIEW R33 截图自检：用 WGC 只抓我们自己的一个窗口（GraphicsCaptureItem.CreateForWindow），
// 透明的部分一起抓下来，裁到不透明的那一块，再垫棋盘格存 PNG。托盘菜单、录制条、录音控制条、
// 轻提示这种透明宿主窗口 RenderTargetBitmap / PrintWindow 拍不全，用它；窗口抓窗口，拍不到别的程序。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Infrastructure;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.Imaging;

namespace KittyTools;

internal static class WindowShot
{
    /// <summary>
    /// 抓 <paramref name="hwnd"/> 的一帧存成 PNG。<paramref name="crop"/> 是窗口里的物理像素矩形；
    /// 不给就裁到 alpha > 8 的范围、四周留 12 px。
    /// </summary>
    public static async Task<bool> SaveAsync(IntPtr hwnd, string path, PixelBounds? crop = null)
    {
        var name = Path.GetFileName(path);
        if (hwnd == IntPtr.Zero)
        {
            Log.Warn($"ui-snapshots {name} no-window");
            return false;
        }

        D3DContext? context = null;
        try
        {
            context = D3DContext.Create(out var error);
            if (context is null)
            {
                Log.Warn($"ui-snapshots {name} d3d-failed {error}");
                return false;
            }

            var item = WgcInterop.ForWindow(hwnd);
            if (item is null)
            {
                Log.Warn($"ui-snapshots {name} no-item");
                return false;
            }

            var arrived = new TaskCompletionSource<SoftwareBitmap>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                context.WinRt, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
            pool.FrameArrived += async (sender, _) =>
            {
                try
                {
                    using var frame = sender.TryGetNextFrame();
                    if (frame is null || arrived.Task.IsCompleted)
                    {
                        return;
                    }

                    var copy = await SoftwareBitmap.CreateCopyFromSurfaceAsync(
                        frame.Surface, BitmapAlphaMode.Premultiplied);
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
                // 老系统没有这两个属性。
            }

            session.StartCapture();
            if (await Task.WhenAny(arrived.Task, Task.Delay(3000)) != arrived.Task)
            {
                Log.Warn($"ui-snapshots {name} wgc-timeout");
                return false;
            }

            using var bitmap = await arrived.Task;
            var width = bitmap.PixelWidth;
            var height = bitmap.PixelHeight;
            var pixels = new byte[width * height * 4];
            bitmap.CopyToBuffer(pixels.AsBuffer());
            var area = crop ?? OpaqueBounds(pixels, width, height, 12);
            var left = Math.Clamp(area.Left, 0, width);
            var top = Math.Clamp(area.Top, 0, height);
            var right = Math.Clamp(area.Right, left, width);
            var bottom = Math.Clamp(area.Bottom, top, height);
            if (right - left < 2 || bottom - top < 2)
            {
                Log.Warn($"ui-snapshots {name} empty {width}x{height}");
                return false;
            }

            var output = OverCheckerboard(pixels, width, left, top, right - left, bottom - top);
            using (var stream = File.Create(path))
            {
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
                encoder.SetPixelData(
                    BitmapPixelFormat.Bgra8,
                    BitmapAlphaMode.Ignore,
                    (uint)(right - left),
                    (uint)(bottom - top),
                    96,
                    96,
                    output);
                await encoder.FlushAsync();
            }

            Log.Info($"ui-snapshots {name} wgc px={right - left}x{bottom - top}");
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"ui-snapshots {name} wgc-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return false;
        }
        finally
        {
            context?.Dispose();
        }
    }

    /// <summary>alpha > 8 的像素外接矩形，四周放宽 <paramref name="padding"/>；整块透明时返回空矩形。</summary>
    private static PixelBounds OpaqueBounds(byte[] pixels, int width, int height, int padding)
    {
        int left = width, top = height, right = -1, bottom = -1;
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                if (pixels[(y * width + x) * 4 + 3] <= 8)
                {
                    continue;
                }

                left = Math.Min(left, x);
                right = Math.Max(right, x);
                top = Math.Min(top, y);
                bottom = Math.Max(bottom, y);
            }
        }

        return right < 0
            ? default
            : new PixelBounds(left - padding, top - padding, right + 1 + padding, bottom + 1 + padding);
    }

    /// <summary>预乘 BGRA 盖在 10 px 的浅灰 / 白棋盘格上：out = src + bg × (1 − α)。</summary>
    private static byte[] OverCheckerboard(byte[] pixels, int stride, int left, int top, int width, int height)
    {
        var output = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var source = ((top + y) * stride + left + x) * 4;
                var target = (y * width + x) * 4;
                var background = ((x / 10) + (y / 10)) % 2 == 0 ? 255 : 230;
                var rest = 255 - pixels[source + 3];
                for (var channel = 0; channel < 3; channel++)
                {
                    output[target + channel] = (byte)Math.Min(255, pixels[source + channel] + background * rest / 255);
                }

                output[target + 3] = 255;
            }
        }

        return output;
    }
}
