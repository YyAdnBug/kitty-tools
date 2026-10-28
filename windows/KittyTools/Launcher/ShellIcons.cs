// 图标：按「32 DIP × 缩放」的像素数取清晰的那一档（150% 下要 48 px，不再是 32 px 放大成 48 的发糊图）。
// 两种来源：
//   1. SHGetFileInfo(SHGFI_ICONLOCATION) 拿到图标所在的 exe / dll / ico + 序号，
//      再用 SHDefExtractIcon 按要的尺寸直接取出（系统会挑最接近的一档并缩放）；
//   2. 取不到图标位置时退回 SHGetFileInfo 的大图标（32 px），用 DrawIconEx 缩放到目标尺寸。
// 都是 HICON → 32 位 DIB → PNG。都在后台扫描线程上用，不碰 UI 线程。
// 第二版 §2 第 13 条点名 IShellItemImageFactory；CsWin32 在这个配置下生成的
// IShellItemImageFactory 是托管接口（AOT 下不能用运行时 COM 封送），改用上面这条公开的等价路子，
// 见提交正文的「和 PLAN 不一样的地方」。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class ShellIcons
{
    /// <summary>启动器里的图标画成 32 DIP（剪贴板的行图标 24）：按显示器缩放取出对应像素数的图。</summary>
    public static byte[]? LoadPng(string path, double scale = 1.0, double dip = 32)
    {
        var size = MonitorLayout.Pixels(dip, Math.Max(1.0, scale));
        var info = default(SHFILEINFOW);
        fixed (char* name = path)
        {
            if (PInvoke.SHGetFileInfo(
                    new PCWSTR(name), default, &info, (uint)sizeof(SHFILEINFOW),
                    SHGFI_FLAGS.SHGFI_ICONLOCATION) == 0)
            {
                return null;
            }
        }

        if (LoadFromIconLocation(info.szDisplayName.ToString(), info.iIcon, size) is { } png)
        {
            return png;
        }

        return LoadLargeIcon(path, size);
    }

    /// <summary>按图标位置（exe / dll / ico + 序号）和像素尺寸直接取一档图标。</summary>
    private static byte[]? LoadFromIconLocation(string iconPath, int index, int size)
    {
        if (string.IsNullOrWhiteSpace(iconPath))
        {
            return null;
        }

        fixed (char* location = iconPath)
        {
            HICON large = default;
            var result = PInvoke.SHDefExtractIcon(
                new PCWSTR(location), index, 0, &large, null, (uint)(size | (size << 16)));
            if (result.Failed || large == default)
            {
                return null;
            }

            try
            {
                return IconToPng(large, size);
            }
            finally
            {
                PInvoke.DestroyIcon(large);
            }
        }
    }

    private static byte[]? LoadLargeIcon(string path, int size)
    {
        var info = default(SHFILEINFOW);
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
                return IconToPng(info.hIcon, size);
            }
            finally
            {
                PInvoke.DestroyIcon(info.hIcon);
            }
        }
    }

    private static byte[]? IconToPng(HICON icon, int size)
    {
        var bitmap = CreateBitmap(size);
        if (bitmap == default)
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

            return ToPng(bitmap);
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

            PInvoke.DeleteObject(new HGDIOBJ(bitmap.Value));
        }
    }

    private static HBITMAP CreateBitmap(int size)
    {
        var bitmapInfo = new BITMAPINFO
        {
            bmiHeader = new BITMAPINFOHEADER
            {
                biSize = (uint)sizeof(BITMAPINFOHEADER),
                biWidth = size,
                biHeight = -size, // 自上而下
                biPlanes = 1,
                biBitCount = 32,
                biCompression = 0, // BI_RGB
            },
        };
        void* bits = null;
        return PInvoke.CreateDIBSection(default, &bitmapInfo, DIB_USAGE.DIB_RGB_COLORS, &bits, default, 0);
    }

    /// <summary>32 位 HBITMAP → PNG（GetObject 拿 DIBSECTION 的像素指针，不用再开 DC 拷一遍）。</summary>
    private static byte[]? ToPng(HBITMAP bitmap)
    {
        var section = default(DIBSECTION);
        if (PInvoke.GetObject(new HGDIOBJ(bitmap.Value), sizeof(DIBSECTION), &section) == 0)
        {
            return null;
        }

        var width = section.dsBm.bmWidth;
        var height = Math.Abs(section.dsBm.bmHeight);
        var stride = section.dsBm.bmWidthBytes;
        var bits = (byte*)section.dsBm.bmBits;
        if (width <= 0 || height <= 0 || bits is null || section.dsBm.bmBitsPixel != 32)
        {
            return null;
        }

        // 位图是 CreateBitmap 按「自上而下」建的（biHeight 传负数），第一行就是最上面一行，照原样拷。
        // 不能看 GetObject 回来的 dsBmih.biHeight 判断行序：GDI 对自上而下的 DIB 也报正数，按它倒着拷整张图就上下颠倒了
        // （2026-10-28 用户报剪贴板和启动器里的程序图标是倒着的）。
        var pixels = new byte[width * height * 4];
        for (var row = 0; row < height; row++)
        {
            new ReadOnlySpan<byte>(bits + row * stride, width * 4)
                .CopyTo(pixels.AsSpan(row * width * 4, width * 4));
        }

        // 编码放到线程池上做、这里同步等：BgraToPngAsync 里的 await 会抓调用方的线程上下文，
        // 直接在 UI 线程上 GetResult 的话续体要回 UI 线程、UI 线程又在等它——死锁，整个 App 白屏（kill 列表那次就是）。
        // 这样不管谁在哪个线程上调 LoadPng 都不会卡死。
        return Task.Run(() => ImageCodec.BgraToPngAsync(width, height, OpaqueIfNoAlpha(pixels))).GetAwaiter().GetResult();
    }

    /// <summary>图标没有 alpha 通道时全填不透明（不然整张图透明）。</summary>
    private static byte[] OpaqueIfNoAlpha(byte[] bgra)
    {
        for (var index = 3; index < bgra.Length; index += 4)
        {
            if (bgra[index] != 0)
            {
                return bgra;
            }
        }

        for (var index = 3; index < bgra.Length; index += 4)
        {
            bgra[index] = 255;
        }

        return bgra;
    }
}
