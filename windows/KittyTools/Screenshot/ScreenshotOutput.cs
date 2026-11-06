// 截图输出：裁出选区的像素、编 PNG、复制（PNG + CF_DIBV5，同时记进剪贴板历史；设置 › 截图「截图拷贝为」选了 PNG 文件时
// 剪贴板里只放一个文件，PLAN-v15）、快速保存（系统的「屏幕截图」文件夹，设置里可改）、另存为（Windows App SDK 的 FileSavePicker）、
// 拖出去 / 拷成文件用的临时文件夹 %TEMP%\kitty-shots 的清理。
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

    /// <summary>
    /// 复制一张已经编好的 PNG，宽高由调用方给：长截图拼出来的那张比选区高得多，
    /// 不能按选区算（REVIEW R62：以前剪贴板历史、预览角标、「已复制截图」都写选区的大小）。
    /// 截图里的每一种「拷贝」都走这里（框选、长截图、长图标注、角落缩略图、钉图、截图历史的单条；PLAN-v15，同 mac copyPNG）：
    /// 设置 › 截图「截图拷贝为」选了 PNG 文件时剪贴板里只放这个文件（CF_HDROP，同在资源管理器里复制一个文件——只搬文字和文件的
    /// 跨电脑剪贴板也传得过去），写不成就照旧放图像；剪贴板历史两种都记成图片（临时文件清掉以后这条照样能用）。
    /// title / source / showSize：提示的标题、剪贴板历史的来源、提示里写不写尺寸（拷成文件时写文件名）。
    /// existingFile：已经有的成品文件（截图历史那条存过的、拖出去的那份），拷成文件时直接用它，不另写临时文件。
    /// </summary>
    public static async Task<bool> CopyPngAsync(
        byte[] png, int width, int height, string title = "已复制截图", string source = "截图",
        bool showSize = true, string? existingFile = null)
    {
        string? file = null;
        if (SettingsService.Current.ScreenshotCopyAs == "file")
        {
            file = existingFile is not null && File.Exists(existingFile) ? existingFile : await WriteCopyFileAsync(png);
        }

        bool written;
        if (file is not null)
        {
            written = ClipboardWriter.WriteFiles(new[] { file });
        }
        else
        {
            // DIB 先在后台转好，写剪贴板时一次写完（第二版 §2 第 7 条）。
            var prepared = await ClipboardWriter.PrepareImageAsync(png);
            written = ClipboardWriter.WriteImagePng(prepared.Png, prepared.Dib);
        }

        if (!written)
        {
            // REVIEW R63：剪贴板被别的程序占着时以前什么都不显示。
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
            Log.Warn("screenshot.copy-failed");
            return false;
        }

        var service = ClipboardService.Instance;
        service?.MarkOwnWrite();
        if (service is not null)
        {
            _ = service.Store.RecordImageAsync(png, width, height, null, source);
        }

        var detail = file is not null ? Path.GetFileName(file) : showSize ? $"{width} × {height}" : string.Empty;
        NoticeHost.Show(title, detail, NoticeTone.Normal);
        Log.Info($"screenshot.copy ok=true {width}x{height} file={file is not null}");
        return true;
    }

    /// <summary>拖出去、拷成文件用的临时文件夹（启动时清空，ShellRuntime；每日维护时删一天以前的，PurgeStaleTemp）。</summary>
    internal static string TempFolder => Path.Combine(Path.GetTempPath(), "kitty-shots");

    /// <summary>
    /// 拷成文件时的那一份：kitty-shots\copy\&lt;编号&gt;\截图 日期 时间.png，每次一个新子文件夹（同一秒拷两次不撞名）。
    /// **用的时候不删**：对方可能过一会儿才粘（跨电脑的剪贴板工具粘的那一刻才来读）。写不成给 null，调用方改放图像。
    /// </summary>
    private static async Task<string?> WriteCopyFileAsync(byte[] png)
    {
        try
        {
            var folder = Path.Combine(TempFolder, "copy", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, $"截图 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.png");
            await File.WriteAllBytesAsync(path, png);
            return path;
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.copy-file-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>
    /// 每日维护时清 kitty-shots（PLAN-v15：托盘程序一开几周，只靠启动时清空会越攒越多）：一天以前的删掉——第一层的 PNG
    /// （角落缩略图拖出去的）、history \ copy 下的子文件夹（截图历史拖出去的、拷成文件的）。正被别的程序读着删不掉的跳过。
    /// </summary>
    public static void PurgeStaleTemp(DateTime nowUtc)
    {
        try
        {
            var root = TempFolder;
            if (!Directory.Exists(root))
            {
                return;
            }

            var entries = Directory.EnumerateFiles(root, "*.png")
                .Select(path => (path, File.GetLastWriteTimeUtc(path)))
                .ToList();
            foreach (var sub in new[] { "history", "copy" })
            {
                var folder = Path.Combine(root, sub);
                if (Directory.Exists(folder))
                {
                    entries.AddRange(Directory.EnumerateDirectories(folder)
                        .Select(path => (path, Directory.GetLastWriteTimeUtc(path))));
                }
            }

            foreach (var path in Core.ShotHistoryRules.StaleTemp(entries, nowUtc))
            {
                try
                {
                    if (Directory.Exists(path))
                    {
                        Directory.Delete(path, recursive: true);
                    }
                    else
                    {
                        File.Delete(path);
                    }
                }
                catch (Exception ex)
                {
                    Log.Warn($"screenshot.temp-purge-skipped {ex.GetType().Name}");
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.temp-purge-failed {ex.GetType().Name}");
        }
    }

    /// <summary>quiet：存成了不弹「已保存截图」（截图历史一起存好几张时最后只说一句）；出错照样提示。</summary>
    public static async Task<string?> QuickSavePngAsync(byte[] png, bool quiet = false)
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
            if (!quiet)
            {
                NoticeHost.Show("已保存截图", Path.GetFileName(path), NoticeTone.Normal,
                    NoticeActions.Reveal(path), NoticeActions.Open(path));
            }

            return path;
        }
        catch (Exception ex)
        {
            Log.Error("screenshot.save-failed", ex);
            NoticeHost.Show("没能保存", "文件写不进去", NoticeTone.Error);
            return null;
        }
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
            NoticeHost.Show("已保存图片", Path.GetFileName(result.Path), NoticeTone.Normal,
                NoticeActions.Reveal(result.Path), NoticeActions.Open(result.Path));
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
