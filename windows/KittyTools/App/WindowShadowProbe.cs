// PLAN-v26 S3 的自检（只在测试档）：`--window-shadow-probe=<目录>`。打开本 App 的设置窗，用 WindowShadowShot 单独抓它、带阴影出图，
// 存成 window-shadow.png，再量几处像素记日志：四个角是不是透明（圆角挖掉了）、正下方的阴影有没有（半透明的黑）、窗口中间是不是不透明。
// 只抓自己的窗口（windows-shots 里不能有别人的东西）。跑完就退。
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class WindowShadowProbe
{
    public const string ArgumentPrefix = "--window-shadow-probe=";

    public static string? DirectoryFrom(string[] args)
        => Paths.IsTestProfile && args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase)) is { } argument
            ? Path.GetFullPath(argument[ArgumentPrefix.Length..])
            : null;

    public static async Task RunAsync(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            ShellRuntime.Instance?.ShowSettings(welcome: false, "screenshot");
            await Task.Delay(2500);
            var window = ShellRuntime.Instance?.SettingsWindowForProbe;
            if (window is null)
            {
                Log.Warn("window-shadow-probe no-window");
                return;
            }

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            var scale = window.Content?.XamlRoot?.RasterizationScale ?? 1.0;
            var png = await WindowShadowShot.CaptureAsync(hwnd, scale);
            if (png is null)
            {
                Log.Warn("window-shadow-probe capture-failed");
                return;
            }

            await File.WriteAllBytesAsync(Path.Combine(directory, "window-shadow.png"), png);
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(png));
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, new BitmapTransform(),
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            var pixels = data.DetachPixelData();
            var width = (int)decoder.PixelWidth;
            var height = (int)decoder.PixelHeight;
            int Alpha(int x, int y) => pixels[(Math.Clamp(y, 0, height - 1) * width + Math.Clamp(x, 0, width - 1)) * 4 + 3];
            var margin = (int)Math.Round(32 * scale);
            var corner = Alpha(margin + 1, margin + 1);
            var inside = Alpha(margin + (int)(12 * scale), margin + (int)(12 * scale));
            var center = Alpha(width / 2, height / 2);
            var shadowBelow = Alpha(width / 2, height - margin + (int)(8 * scale));
            var outside = Alpha(2, 2);
            Log.Info($"window-shadow-probe size={width}x{height} scale={scale:0.##} corner={corner} inside={inside} center={center} shadow-below={shadowBelow} far={outside}");
        }
        catch (Exception ex)
        {
            Log.Error("window-shadow-probe failed", ex);
        }
        finally
        {
            Log.Info("window-shadow-probe done");
            Environment.Exit(0);
        }
    }
}
