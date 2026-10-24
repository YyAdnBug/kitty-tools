// 截图输出：裁出选区的像素、编 PNG、复制（PNG + CF_DIBV5，同时记进剪贴板历史）、
// 快速保存（系统的「屏幕截图」文件夹，设置里可改）、另存为（Windows App SDK 的 FileSavePicker）。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal static partial class ScreenshotOutput
{
    public static PixelBounds SelectionPixels(FrozenScreen screen, Core.RectD selection)
    {
        var rect = Core.RegionMath.PixelRect(selection, 1, screen.Width, screen.Height);
        return new PixelBounds(
            (int)Math.Round(rect.X), (int)Math.Round(rect.Y),
            (int)Math.Round(rect.Right), (int)Math.Round(rect.Bottom));
    }

    public static async Task<byte[]?> PngAsync(FrozenScreen screen, Core.RectD selection)
    {
        var rect = SelectionPixels(screen, selection);
        var bgra = screen.Crop(rect);
        return await ImageCodec.BgraToPngAsync(rect.Width, rect.Height, bgra);
    }

    public static async Task<bool> CopyAsync(FrozenScreen screen, Core.RectD selection)
    {
        var rect = SelectionPixels(screen, selection);
        var png = await PngAsync(screen, selection);
        return png is not null && await CopyPngAsync(png, screen, selection);
    }

    public static Task<bool> CopyPngAsync(byte[] png, FrozenScreen screen, Core.RectD selection)
    {
        var rect = SelectionPixels(screen, selection);
        if (!ClipboardWriter.WriteImagePng(png))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
            return Task.FromResult(false);
        }

        var service = ClipboardService.Instance;
        service?.MarkOwnWrite();
        service?.Store.RecordImage(png, rect.Width, rect.Height, null, "截图");
        NoticeHost.Show("已复制截图", $"{rect.Width} × {rect.Height}", NoticeTone.Normal);
        return Task.FromResult(true);
    }

    public static async Task<string?> QuickSaveAsync(FrozenScreen screen, Core.RectD selection)
    {
        var png = await PngAsync(screen, selection);
        return png is null ? null : await QuickSavePngAsync(png);
    }

    public static async Task<string?> QuickSavePngAsync(byte[] png)
    {
        var folder = string.IsNullOrWhiteSpace(SettingsService.Current.ScreenshotSaveFolder)
            ? DefaultFolder()
            : SettingsService.Current.ScreenshotSaveFolder!;
        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception ex)
        {
            NoticeHost.Show("没能保存", "截图文件夹创建不了", NoticeTone.Error);
            Log.Error("screenshot.folder-failed", ex);
            return null;
        }

        var path = UniquePath(folder, $"截图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
        try
        {
            await File.WriteAllBytesAsync(path, png);
            NoticeHost.Show("已保存截图", Path.GetFileName(path), NoticeTone.Normal);
            return path;
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.save-failed", ex);
            NoticeHost.Show("没能保存", "文件写不进去", NoticeTone.Error);
            return null;
        }
    }

    public static async Task<string?> SaveAsAsync(Microsoft.UI.Windowing.AppWindow appWindow, FrozenScreen screen, Core.RectD selection)
    {
        var png = await PngAsync(screen, selection);
        if (png is null)
        {
            return null;
        }

        return await SavePngAsAsync(appWindow, png);
    }

    public static async Task<string?> SavePngAsAsync(Microsoft.UI.Windowing.AppWindow appWindow, byte[] png)
    {
        try
        {
            var picker = new FileSavePicker(appWindow.Id)
            {
                SuggestedFileName = $"截图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}",
                DefaultFileExtension = ".png",
            };
            picker.FileTypeChoices.Add("PNG 图片", new List<string> { ".png" });
            var result = await picker.PickSaveFileAsync();
            if (result is null || string.IsNullOrEmpty(result.Path))
            {
                return null;
            }

            await File.WriteAllBytesAsync(result.Path, png);
            NoticeHost.Show("已保存图片", Path.GetFileName(result.Path), NoticeTone.Normal);
            return result.Path;
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.save-as-failed", ex);
            NoticeHost.Show("没能保存", ex.GetType().Name, NoticeTone.Error);
            return null;
        }
    }

    public static string DefaultFolder()
    {
        try
        {
            var id = new Guid("b7bede81-df94-4682-a7d8-57a52620b86f"); // FOLDERID_Screenshots
            if (SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out var pointer) == 0 && pointer != IntPtr.Zero)
            {
                try
                {
                    var path = Marshal.PtrToStringUni(pointer);
                    if (!string.IsNullOrEmpty(path))
                    {
                        return path;
                    }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(pointer);
                }
            }
        }
        catch
        {
            // 取不到就用图片目录下的 Screenshots。
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
    }

    private static string UniquePath(string folder, string fileName)
    {
        var path = Path.Combine(folder, fileName);
        if (!File.Exists(path))
        {
            return path;
        }

        var name = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 2; index < 1000; index++)
        {
            path = Path.Combine(folder, $"{name} ({index}){extension}");
            if (!File.Exists(path))
            {
                return path;
            }
        }

        return Path.Combine(folder, $"{name} {Guid.NewGuid():N}{extension}");
    }

    [LibraryImport("shell32.dll", EntryPoint = "SHGetKnownFolderPath")]
    private static partial int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
}
