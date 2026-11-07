// 截图拷贝为文件的自检（PLAN-v15，Windows 核验时加的）：`--copy-file-probe=<目录>`（只在测试档）不开截图界面、不发按键，
// 直接走 ScreenshotOutput.CopyPngAsync 的几条路（图像 / PNG 文件 / 截图历史给的现成文件 / 钉图的提示 / 剪贴板被占着）、
// 设置的导出导入和 PurgeStaleTemp，每步读回剪贴板，结果写 <目录>\report.md，提示卡各拍一张（WindowShot，只抓自己的窗口）。
// 先备份剪贴板、跑完写回去；自检写的每一次都带「别记」的标记（ClipboardWriter.QuietForProbe），用户自己开着的 Kitty Tools
// 和 Win+V 都不记。临时文件夹跟着 %TMP% 走：跑的时候把 TMP 指到一个临时目录，别碰正式版拖出去的那些。跑完就退。
using System.Buffers.Binary;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static class CopyFileProbe
{
    public const string ArgumentPrefix = "--copy-file-probe";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-copy-file-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 截图拷贝为文件自检（PLAN-v15）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        var settings = SettingsService.Current;
        var original = settings.ScreenshotCopyAs;
        var snapshot = ClipboardFormats.CaptureSnapshot();
        ClipboardWriter.QuietForProbe = true;
        // 提示卡平时不让自己被录进去（显示亲和性），这里要拍它（同 --ui-snapshots）。
        Environment.SetEnvironmentVariable("KITTY_HUD_CAPTURE", "1");
        report.Append($"临时文件夹 `{ScreenshotOutput.TempFolder}`；备份剪贴板 {(snapshot is null ? "失败（跑完清空）" : "好了")}\n\n");
        await Task.Delay(1500);

        try
        {
            Check(original == "image", $"默认「截图拷贝为」= {original}（应为 image）");
            const int width = 240;
            const int height = 160;
            var seed = 0;
            // 剪贴板历史按内容去重（同一张再拷只挪到最前、来源不变），所以每拷一次换一张：左上角那个像素不一样。
            async Task<byte[]> NextPngAsync()
            {
                var bgra = new byte[width * height * 4];
                for (var index = 0; index < bgra.Length; index += 4)
                {
                    var pixel = index / 4;
                    bgra[index] = (byte)(pixel % width);
                    bgra[index + 1] = (byte)(pixel / width);
                    bgra[index + 2] = 0xC0;
                    bgra[index + 3] = 0xFF;
                }

                bgra[2] = (byte)(++seed * 7);
                return await ImageCodec.BgraToPngAsync(width, height, bgra) ?? throw new InvalidOperationException("png");
            }

            var png = await NextPngAsync();

            // 1. 图像（默认）：PNG + CF_DIBV5，没有 CF_HDROP；剪贴板历史一条图片；提示写尺寸。
            settings.ScreenshotCopyAs = "image";
            var ok = await ScreenshotOutput.CopyPngAsync(png, width, height);
            var formats = Read();
            Check(ok && formats?[ClipboardFormats.PngFormat]?.SequenceEqual(png) == true && formats[ClipboardFormats.CF_DIBV5] is not null
                  && formats[ClipboardFormats.CF_HDROP] is null,
                $"图像：返回 {ok}，PNG {Size(formats, ClipboardFormats.PngFormat)}、DIBV5 {Size(formats, ClipboardFormats.CF_DIBV5)}、HDROP {Size(formats, ClipboardFormats.CF_HDROP)}");
            Check(formats?[ClipboardFormats.ExcludeFromMonitorFormat] is not null, "自检写的带着「别记」标记");
            await CheckHistoryAsync(Check, "截图", "图像");
            await ShootNoticeAsync(directory, "1-image");

            // 2. PNG 文件：剪贴板里只有 CF_HDROP（一个文件）+ 复制效果；文件在 copy\<编号>\截图 日期 时间.png，内容就是这张；历史照旧是图片。
            settings.ScreenshotCopyAs = "file";
            png = await NextPngAsync();
            ok = await ScreenshotOutput.CopyPngAsync(png, width, height);
            formats = Read();
            var files = Files(formats);
            var file = files.FirstOrDefault();
            var copyRoot = Path.Combine(ScreenshotOutput.TempFolder, "copy");
            Check(ok && files.Count == 1 && file is not null && File.Exists(file) && File.ReadAllBytes(file).SequenceEqual(png),
                $"文件：返回 {ok}，HDROP {files.Count} 个：`{file}`");
            Check(file is not null && string.Equals(Path.GetDirectoryName(Path.GetDirectoryName(file)), copyRoot, StringComparison.OrdinalIgnoreCase)
                  && System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(file), @"^截图 \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\.png$"),
                "文件在 copy\\<编号>\\ 下，名字是「截图 日期 时间.png」");
            Check(formats?[ClipboardFormats.PngFormat] is null && formats?[ClipboardFormats.CF_DIBV5] is null,
                $"文件：剪贴板里没有图像（PNG {Size(formats, ClipboardFormats.PngFormat)}、DIBV5 {Size(formats, ClipboardFormats.CF_DIBV5)}）");
            var effect = formats?[ClipboardFormats.PreferredDropEffectFormat];
            Check(effect is { Length: >= 4 } && BinaryPrimitives.ReadInt32LittleEndian(effect) == 1, "Preferred DropEffect = 1（复制）");
            await CheckHistoryAsync(Check, "截图", "文件");
            await ShootNoticeAsync(directory, "2-file");

            // 同一秒再拷一次：另一个子文件夹，不撞名。
            png = await NextPngAsync();
            await ScreenshotOutput.CopyPngAsync(png, width, height);
            var second = Files(Read()).FirstOrDefault();
            Check(second is not null && file is not null && !string.Equals(Path.GetDirectoryName(second), Path.GetDirectoryName(file), StringComparison.OrdinalIgnoreCase),
                "再拷一次：新的子文件夹");

            // 3. 截图历史给的现成文件（存过的那条）：直接用它；文件已经没了就另写临时文件。
            var saved = Path.Combine(directory, "saved", "截图 存过的.png");
            Directory.CreateDirectory(Path.GetDirectoryName(saved)!);
            await File.WriteAllBytesAsync(saved, png);
            png = await NextPngAsync();
            ok = await ScreenshotOutput.CopyPngAsync(png, width, height, source: "截图历史", existingFile: saved);
            var given = Files(Read());
            Check(ok && given.Count == 1 && string.Equals(given[0], saved, StringComparison.OrdinalIgnoreCase), $"现成文件：给的是 `{given.FirstOrDefault()}`");
            await CheckHistoryAsync(Check, "截图历史", "现成文件");
            var gone = Path.Combine(directory, "saved", "不在了.png");
            png = await NextPngAsync();
            ok = await ScreenshotOutput.CopyPngAsync(png, width, height, source: "截图历史", existingFile: gone);
            given = Files(Read());
            Check(ok && given.Count == 1 && given[0].StartsWith(copyRoot, StringComparison.OrdinalIgnoreCase), $"现成文件不在了：另写 `{given.FirstOrDefault()}`");

            // 4. 钉图的参数（标题「已复制钉图」、来源「钉图」、图像时不写尺寸）。
            png = await NextPngAsync();
            ok = await ScreenshotOutput.CopyPngAsync(png, width, height, "已复制钉图", "钉图", showSize: false);
            Check(ok && Files(Read()).Count == 1, "钉图 · 文件：剪贴板里是文件");
            await CheckHistoryAsync(Check, "钉图", "钉图 · 文件");
            await ShootNoticeAsync(directory, "4-pin-file");
            settings.ScreenshotCopyAs = "image";
            png = await NextPngAsync();
            ok = await ScreenshotOutput.CopyPngAsync(png, width, height, "已复制钉图", "钉图", showSize: false);
            formats = Read();
            Check(ok && formats?[ClipboardFormats.PngFormat] is not null && formats[ClipboardFormats.CF_HDROP] is null, "钉图 · 图像：剪贴板里是图像");
            await ShootNoticeAsync(directory, "4-pin-image");

            // 5. 剪贴板被别的程序占着：两种都返回 false、提示「没能复制」。另一根线程开着剪贴板约 1 秒。
            foreach (var kind in new[] { "image", "file" })
            {
                settings.ScreenshotCopyAs = kind;
                using var held = new ManualResetEventSlim();
                using var release = new ManualResetEventSlim();
                var holder = new Thread(() =>
                {
                    var opened = PInvoke.OpenClipboard(HWND.Null);
                    held.Set();
                    release.Wait(3000);
                    if (opened)
                    {
                        PInvoke.CloseClipboard();
                    }
                });
                holder.Start();
                held.Wait(3000);
                png = await NextPngAsync();
                ok = await ScreenshotOutput.CopyPngAsync(png, width, height);
                release.Set();
                holder.Join(3000);
                Check(!ok, $"剪贴板占着 · {kind}：返回 {ok}（应为 False）");
                await ShootNoticeAsync(directory, "5-busy-" + kind);
            }

            // 6. 导出导入：这一项跟着走，只认 image / file。
            settings.ScreenshotCopyAs = "file";
            var text = ArchiveService.Encode(ArchiveService.Build(new[] { ArchiveSection.Preferences }));
            Check(text.Contains("\"screenshotCopyAs\"", StringComparison.Ordinal) && text.Contains("\"file\"", StringComparison.Ordinal), "导出里有 screenshotCopyAs = file");
            settings.ScreenshotCopyAs = "image";
            var archive = ArchiveService.Decode(text);
            var (_, error) = archive is null ? (null, "decode") : ArchiveService.Apply(archive, null);
            Check(error is null && settings.ScreenshotCopyAs == "file", $"导入后 = {settings.ScreenshotCopyAs}（错误 {error ?? "无"}）");
            var bogus = ArchiveService.Decode(text.Replace("\"file\"", "\"tiff\"", StringComparison.Ordinal));
            settings.ScreenshotCopyAs = "image";
            if (bogus is not null)
            {
                ArchiveService.Apply(bogus, null);
            }

            Check(settings.ScreenshotCopyAs == "image", $"导入不认识的值（tiff）不改：{settings.ScreenshotCopyAs}");

            // 7. 每日维护的清理：一天以前的删（copy、history 下的子文件夹、第一层的 PNG），别的留着。
            var root = ScreenshotOutput.TempFolder;
            var oldCopy = Directory.CreateDirectory(Path.Combine(root, "copy", "probe-old")).FullName;
            var newCopy = Directory.CreateDirectory(Path.Combine(root, "copy", "probe-new")).FullName;
            var oldHistory = Directory.CreateDirectory(Path.Combine(root, "history", "probe-old")).FullName;
            var oldPng = Path.Combine(root, "probe-old.png");
            var newPng = Path.Combine(root, "probe-new.png");
            await File.WriteAllBytesAsync(Path.Combine(oldCopy, "a.png"), png);
            await File.WriteAllBytesAsync(oldPng, png);
            await File.WriteAllBytesAsync(newPng, png);
            var twoDaysAgo = DateTime.Now.AddDays(-2);
            Directory.SetLastWriteTime(oldCopy, twoDaysAgo);
            Directory.SetLastWriteTime(oldHistory, twoDaysAgo);
            File.SetLastWriteTime(oldPng, twoDaysAgo);
            ScreenshotOutput.PurgeStaleTemp(DateTime.UtcNow);
            Check(!Directory.Exists(oldCopy) && !Directory.Exists(oldHistory) && !File.Exists(oldPng), "清理：两天前的 copy \\ history 子文件夹、第一层 PNG 删了");
            Check(Directory.Exists(newCopy) && File.Exists(newPng) && file is not null && File.Exists(file), "清理：新的（含刚才拷的那个文件）还在");
            report.Append($"\n剩下的 copy 子文件夹：{Directory.GetDirectories(copyRoot).Length} 个（下次启动应清空）\n");
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name} {ex.Message}");
        }
        finally
        {
            settings.ScreenshotCopyAs = original;
            SettingsService.Save();
            var restored = snapshot is not null && ClipboardFormats.RestoreSnapshot(snapshot);
            ClipboardWriter.QuietForProbe = false;
            report.Append($"\n剪贴板写回去：{restored}\n\n**{(failures == 0 ? "全过" : $"{failures} 条不对")}**\n");
            await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
            Log.Info($"copy-file-probe done failures={failures}");
            Environment.Exit(0);
        }
    }

    private static Dictionary<uint, byte[]?>? Read() => ClipboardFormats.ReadForProbe(
        ClipboardFormats.PngFormat, ClipboardFormats.CF_DIBV5, ClipboardFormats.CF_HDROP,
        ClipboardFormats.PreferredDropEffectFormat, ClipboardFormats.ExcludeFromMonitorFormat);

    private static string Size(Dictionary<uint, byte[]?>? formats, uint format)
        => formats?.GetValueOrDefault(format) is { } bytes ? $"{bytes.Length} B" : "无";

    /// <summary>DROPFILES 头（pFiles 偏移、fWide）后面的宽字符文件表。</summary>
    private static List<string> Files(Dictionary<uint, byte[]?>? formats)
    {
        if (formats?.GetValueOrDefault(ClipboardFormats.CF_HDROP) is not { Length: > 20 } bytes)
        {
            return new List<string>();
        }

        var offset = BinaryPrimitives.ReadInt32LittleEndian(bytes);
        return Encoding.Unicode.GetString(bytes, offset, bytes.Length - offset)
            .Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .ToList();
    }

    private static async Task CheckHistoryAsync(Action<bool, string> check, string source, string label)
    {
        await Task.Delay(600);
        var top = ClipboardService.Instance?.Store.Items.FirstOrDefault();
        check(top is { Kind: ClipKind.Image } && top.SourceName == source,
            $"{label}：剪贴板历史最上面是 {top?.Kind}，来源「{top?.SourceName}」（应为 Image、「{source}」）");
    }

    private static async Task ShootNoticeAsync(string directory, string name)
    {
        await Task.Delay(900);
        if (NoticeHost.HandleForProbe is var hwnd && hwnd != IntPtr.Zero)
        {
            await WindowShot.SaveAsync(hwnd, Path.Combine(directory, $"notice-{name}.png"));
        }
    }
}
