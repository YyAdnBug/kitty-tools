// 写剪贴板：文本（可选带 HTML / RTF）、图片（PNG + CF_DIBV5）、文件（CF_HDROP + 复制效果）。
// 写完由 ClipboardService.MarkOwnWrite() 记下序号，监听那边就跳过这次自己写入。
// 图片要的 DIB 有几百毫秒的转换：先在后台转好（PrepareImageAsync），再打开剪贴板一次写完，
// 不占着全局剪贴板等编码（第二版 §2 第 7 条）。
using System.Buffers.Binary;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;

namespace KittyTools;

internal static class ClipboardWriter
{
    /// <summary>准备写进剪贴板的图片：PNG 原字节 + 后台转好的 CF_DIBV5 字节。</summary>
    internal readonly record struct PreparedImage(byte[] Png, byte[]? Dib);

    /// <summary>在后台把 PNG 转成 DIB（大图要几百毫秒，别放在 UI 线程上，也别占着剪贴板等）。</summary>
    public static async Task<PreparedImage> PrepareImageAsync(byte[] png)
    {
        var dib = await Task.Run(() => ImageCodec.PngToDibAsync(png));
        return new PreparedImage(png, dib);
    }

    public static async Task<PreparedImage?> PrepareImageAsync(ClipEntry entry)
    {
        if (!File.Exists(Paths.ImagesFile(entry.Id)))
        {
            return null;
        }

        try
        {
            var png = await File.ReadAllBytesAsync(Paths.ImagesFile(entry.Id));
            return await PrepareImageAsync(png);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.read-image-failed", ex);
            return null;
        }
    }

    public static bool WriteEntry(ClipEntry entry, string? html, string? rtf, bool plainText, byte[]? dib = null)
    {
        return entry.Kind switch
        {
            ClipKind.Image => WriteImage(entry, dib),
            ClipKind.Files => WriteFiles(entry.Files),
            _ => WriteText(entry.Text ?? string.Empty, plainText ? null : html, plainText ? null : rtf),
        };
    }

    public static bool WriteText(string text, string? html = null, string? rtf = null)
    {
        if (!ClipboardFormats.OpenClipboard())
        {
            Log.Warn("clipboard.write-open-failed");
            return false;
        }

        try
        {
            if (!PInvoke.EmptyClipboard())
            {
                Log.Warn($"clipboard.empty-failed {System.Runtime.InteropServices.Marshal.GetLastWin32Error()}");
                return false;
            }

            if (!SetBytes(ClipboardFormats.CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0")))
            {
                return false;
            }

            if (!string.IsNullOrEmpty(html))
            {
                SetBytes(ClipboardFormats.HtmlFormat, Encoding.UTF8.GetBytes(html));
            }

            if (!string.IsNullOrEmpty(rtf))
            {
                SetBytes(ClipboardFormats.RtfFormat, Encoding.ASCII.GetBytes(rtf));
            }

            return true;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    public static bool WriteImage(ClipEntry entry, byte[]? dib = null)
    {
        if (!File.Exists(Paths.ImagesFile(entry.Id)))
        {
            return false;
        }

        byte[] png;
        try
        {
            png = File.ReadAllBytes(Paths.ImagesFile(entry.Id));
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.read-image-failed", ex);
            return false;
        }

        return WriteImagePng(png, dib);
    }

    /// <summary>截图 / 钉图 / 剪贴板条目用：把 PNG 字节写进剪贴板（PNG + CF_DIBV5）。</summary>
    public static bool WriteImagePng(byte[] png, byte[]? dib = null)
    {
        // 没转好就当场转，但一定在打开剪贴板之前转完：转换期间别的程序还要能用剪贴板。
        // 转换必须在后台线程上等（WinRT 的异步 API 在 UI 线程上阻塞等会等不到结果）。
        dib ??= Task.Run(() => ImageCodec.PngToDibAsync(png)).GetAwaiter().GetResult();
        if (!ClipboardFormats.OpenClipboard())
        {
            Log.Warn("clipboard.write-open-failed");
            return false;
        }

        try
        {
            if (!PInvoke.EmptyClipboard())
            {
                return false;
            }

            return WriteImageCore(png, dib);
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    private static bool WriteImageCore(byte[] png, byte[]? dib)
    {
        SetBytes(ClipboardFormats.PngFormat, png);
        if (dib is { Length: > 0 })
        {
            SetBytes(ClipboardFormats.CF_DIBV5, dib);
        }

        return true;
    }

    public static bool WriteFiles(IReadOnlyList<string> paths)
    {
        // 只有全都不在原处才算失败（PLAN §6.3 / mac）：还有的在，就只写还在的那几个。
        var existing = paths.Where(path => File.Exists(path) || Directory.Exists(path)).ToList();
        if (existing.Count == 0)
        {
            return false;
        }

        if (existing.Count != paths.Count)
        {
            Log.Info($"clipboard.write-files partial total={paths.Count} existing={existing.Count}");
        }

        if (!ClipboardFormats.OpenClipboard())
        {
            return false;
        }

        try
        {
            if (!PInvoke.EmptyClipboard())
            {
                return false;
            }

            SetBytes(ClipboardFormats.CF_HDROP, BuildDropFiles(existing));

            // DROPEFFECT_COPY：资源管理器粘贴时是「复制」，不是「移动」。
            var effect = new byte[4];
            BinaryPrimitives.WriteInt32LittleEndian(effect, 1);
            if (ClipboardFormats.PreferredDropEffectFormat != 0)
            {
                SetBytes(ClipboardFormats.PreferredDropEffectFormat, effect);
            }

            return true;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>DROPFILES 头 + 宽字符文件表（双 \0 结尾）。</summary>
    private static byte[] BuildDropFiles(IReadOnlyList<string> paths)
    {
        var names = paths.Select(path => path.Replace('/', '\\')).ToList();
        var chars = names.Sum(name => name.Length + 1) + 1;
        var header = 20;
        var bytes = new byte[header + chars * sizeof(char)];
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(0), header);
        var fWide = 1;
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(16), fWide);
        var cursor = header;
        foreach (var name in names)
        {
            var encoded = Encoding.Unicode.GetBytes(name);
            encoded.CopyTo(bytes, cursor);
            cursor += encoded.Length;
            cursor += sizeof(char); // 名字的结尾 \0
        }

        return bytes;
    }

    private static unsafe bool SetBytes(uint format, byte[] bytes)
    {
        var memory = PInvoke.GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, (nuint)bytes.Length);
        if (memory == default)
        {
            return false;
        }

        var destination = PInvoke.GlobalLock(memory);
        if (destination is null)
        {
            PInvoke.GlobalFree(memory);
            return false;
        }

        bytes.AsSpan().CopyTo(new Span<byte>(destination, bytes.Length));
        PInvoke.GlobalUnlock(memory);

        if (PInvoke.SetClipboardData(format, new HANDLE(memory.Value)) == default)
        {
            PInvoke.GlobalFree(memory);
            Log.Warn($"clipboard.set-failed format={format}");
            return false;
        }

        return true;
    }
}
