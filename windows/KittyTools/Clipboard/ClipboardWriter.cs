// 写剪贴板：文本（可选带 HTML / RTF）、图片（PNG + CF_DIBV5）、文件（CF_HDROP + 复制效果）。
// 写完由 ClipboardService.MarkOwnWrite() 记下序号，监听那边就跳过这次自己写入。
using System.Buffers.Binary;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;

namespace KittyTools;

internal static unsafe class ClipboardWriter
{
    public static bool WriteEntry(ClipEntry entry, string? html, string? rtf, bool plainText)
    {
        return entry.Kind switch
        {
            ClipKind.Image => WriteImage(entry),
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

    public static bool WriteImage(ClipEntry entry)
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

            SetBytes(ClipboardFormats.PngFormat, png);

            // WinRT 的解码在后台线程上等，别在 UI 线程上等它。
            var dib = Task.Run(() => ImageCodec.PngToDibAsync(png)).GetAwaiter().GetResult();
            if (dib is { Length: > 0 })
            {
                SetBytes(ClipboardFormats.CF_DIBV5, dib);
            }

            return true;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    public static bool WriteFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return false;
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

            SetBytes(ClipboardFormats.CF_HDROP, BuildDropFiles(paths));

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

    private static bool SetBytes(uint format, byte[] bytes)
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
