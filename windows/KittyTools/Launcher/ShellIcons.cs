// 桌面应用 /.lnk 的图标：SHGetFileInfo 取 HICON，DrawIconEx 画进 32 位 DIB，
// 再交给 ImageCodec 编成 PNG。都在后台扫描线程上用，不碰 UI 线程。
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe class ShellIcons
{
    public static byte[]? LoadPng(string path, int size = 32)
    {
        var info = default(SHFILEINFOW);
        byte[]? png = null;
        fixed (char* name = path)
        {
            var result = PInvoke.SHGetFileInfo(
                new PCWSTR(name),
                default,
                &info,
                (uint)sizeof(SHFILEINFOW),
                SHGFI_FLAGS.SHGFI_ICON | SHGFI_FLAGS.SHGFI_LARGEICON);
            if (result == 0 || info.hIcon == default)
            {
                return null;
            }

            try
            {
                png = IconToPng(info.hIcon, size);
            }
            finally
            {
                PInvoke.DestroyIcon(info.hIcon);
            }
        }

        return png;
    }

    private static byte[]? IconToPng(HICON icon, int size)
    {
        var bitmapInfo = new BITMAPINFO
        {
            bmiHeader = new BITMAPINFOHEADER
            {
                biSize = (uint)sizeof(BITMAPINFOHEADER),
                biWidth = size,
                biHeight = -size,
                biPlanes = 1,
                biBitCount = 32,
                biCompression = 0, // BI_RGB
            },
        };
        void* bits = null;
        var bitmap = PInvoke.CreateDIBSection(
            default, &bitmapInfo, DIB_USAGE.DIB_RGB_COLORS, &bits, default, 0);
        if (bitmap == default || bits is null)
        {
            return null;
        }

        var dc = PInvoke.CreateCompatibleDC(default);
        HGDIOBJ previous = default;
        try
        {
            previous = PInvoke.SelectObject(dc, new HGDIOBJ(bitmap.Value));
            if (!PInvoke.DrawIconEx(dc, 0, 0, icon, size, size, 0, default, DI_FLAGS.DI_NORMAL))
            {
                return null;
            }
        }
        finally
        {
            if (previous != default)
            {
                PInvoke.SelectObject(dc, previous);
            }

            if (dc != default)
            {
                PInvoke.DeleteDC(dc);
            }
        }

        try
        {
            var bgra = new byte[size * size * 4];
            new ReadOnlySpan<byte>(bits, bgra.Length).CopyTo(bgra);
            var hasAlpha = false;
            for (var index = 3; index < bgra.Length; index += 4)
            {
                if (bgra[index] != 0)
                {
                    hasAlpha = true;
                    break;
                }
            }

            if (!hasAlpha)
            {
                for (var index = 3; index < bgra.Length; index += 4)
                {
                    bgra[index] = 255;
                }
            }

            return ImageCodec.BgraToPngAsync(size, size, bgra).GetAwaiter().GetResult();
        }
        finally
        {
            PInvoke.DeleteObject(new HGDIOBJ(bitmap.Value));
        }
    }
}
