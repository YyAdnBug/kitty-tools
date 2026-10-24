// 冻结帧：按下热键先把每块显示器 BitBlt 成 32 位 BGRA（物理像素、自上而下），
// 之后框选、裁剪、放大镜都只读这一帧，不会出现「框完再截」时画面已经变了。
// 受保护内容（DRM）截出来是黑的；HDR 按 SDR，见 PLAN §9.1 的 ponytail。
using System.Runtime.InteropServices;

namespace KittyTools;

internal readonly record struct PixelBounds(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;

    public int Height => Bottom - Top;

    public bool Contains(int x, int y) => x >= Left && x < Right && y >= Top && y < Bottom;
}

internal sealed class FrozenScreen
{
    public required int Index { get; init; }

    public required PixelBounds Bounds { get; init; }

    public required double Scale { get; init; }

    public required byte[] Bgra { get; init; }

    public int Width => Bounds.Width;

    public int Height => Bounds.Height;

    public byte[] Crop(PixelBounds rect)
    {
        var left = Math.Clamp(rect.Left, 0, Width);
        var top = Math.Clamp(rect.Top, 0, Height);
        var right = Math.Clamp(rect.Right, left, Width);
        var bottom = Math.Clamp(rect.Bottom, top, Height);
        var width = right - left;
        var height = bottom - top;
        var result = new byte[width * height * 4];
        for (var row = 0; row < height; row++)
        {
            Buffer.BlockCopy(
                Bgra,
                ((top + row) * Width + left) * 4,
                result,
                row * width * 4,
                width * 4);
        }

        return result;
    }

    /// <summary>放大镜取色：物理像素坐标（屏内），返回 #RRGGBB。</summary>
    public string HexAt(int x, int y)
    {
        x = Math.Clamp(x, 0, Width - 1);
        y = Math.Clamp(y, 0, Height - 1);
        var index = (y * Width + x) * 4;
        return $"#{Bgra[index + 2]:X2}{Bgra[index + 1]:X2}{Bgra[index]:X2}";
    }
}

internal static unsafe partial class ScreenCapture
{
    public static List<FrozenScreen> CaptureAll()
    {
        var monitors = new List<IntPtr>();
        _collected = monitors;
        var callback = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, IntPtr, RECT*, IntPtr, int>)&CollectMonitor;
        EnumDisplayMonitors(IntPtr.Zero, null, callback, IntPtr.Zero);
        _collected = null;

        var screens = new List<FrozenScreen>();
        var index = 0;
        foreach (var monitor in monitors)
        {
            var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(monitor, ref info))
            {
                continue;
            }

            var dpiX = 96u;
            var dpiY = 96u;
            GetDpiForMonitor(monitor, 0, ref dpiX, ref dpiY);
            var bounds = new PixelBounds(
                info.rcMonitor.Left, info.rcMonitor.Top, info.rcMonitor.Right, info.rcMonitor.Bottom);
            var bgra = Capture(bounds);
            if (bgra is null)
            {
                continue;
            }

            screens.Add(new FrozenScreen
            {
                Index = index++,
                Bounds = bounds,
                Scale = Math.Max(1.0, dpiX / 96.0),
                Bgra = bgra,
            });
        }

        return screens.OrderBy(screen => screen.Bounds.Left).ThenBy(screen => screen.Bounds.Top).ToList();
    }

    private static List<IntPtr>? _collected;

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static int CollectMonitor(IntPtr monitor, IntPtr hdc, RECT* clip, IntPtr data)
    {
        _collected?.Add(monitor);
        return 1;
    }

    private static byte[]? Capture(PixelBounds bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
        {
            return null;
        }

        var screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
        {
            return null;
        }

        IntPtr memoryDc = IntPtr.Zero;
        IntPtr bitmap = IntPtr.Zero;
        IntPtr previous = IntPtr.Zero;
        try
        {
            memoryDc = CreateCompatibleDC(screenDc);
            if (memoryDc == IntPtr.Zero)
            {
                return null;
            }

            var info = new BITMAPINFO
            {
                bmiHeader = new BITMAPINFOHEADER
                {
                    biSize = (uint)sizeof(BITMAPINFOHEADER),
                    biWidth = bounds.Width,
                    biHeight = -bounds.Height,
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = 0,
                },
            };
            bitmap = CreateDIBSection(screenDc, &info, 0, out var bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
            {
                return null;
            }

            previous = SelectObject(memoryDc, bitmap);
            if (!BitBlt(memoryDc, 0, 0, bounds.Width, bounds.Height, screenDc, bounds.Left, bounds.Top, 0x00CC0020))
            {
                return null;
            }

            var bytes = new byte[bounds.Width * bounds.Height * 4];
            new ReadOnlySpan<byte>((void*)bits, bytes.Length).CopyTo(bytes);
            // GDI 的 32 位 DIB 里 alpha 是垃圾值，统一置不透明。
            for (var index = 3; index < bytes.Length; index += 4)
            {
                bytes[index] = 255;
            }

            return bytes;
        }
        finally
        {
            if (memoryDc != IntPtr.Zero && previous != IntPtr.Zero)
            {
                SelectObject(memoryDc, previous);
            }

            if (bitmap != IntPtr.Zero)
            {
                DeleteObject(bitmap);
            }

            if (memoryDc != IntPtr.Zero)
            {
                DeleteDC(memoryDc);
            }

            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial int EnumDisplayMonitors(IntPtr hdc, RECT* clip, IntPtr callback, IntPtr data);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [LibraryImport("shcore.dll")]
    private static partial int GetDpiForMonitor(IntPtr monitor, int dpiType, ref uint dpiX, ref uint dpiY);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetDC(IntPtr window);

    [LibraryImport("user32.dll")]
    private static partial int ReleaseDC(IntPtr window, IntPtr dc);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateCompatibleDC(IntPtr dc);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateDIBSection(
        IntPtr dc, BITMAPINFO* info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr SelectObject(IntPtr dc, IntPtr obj);

    [LibraryImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool BitBlt(
        IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint rop);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteObject(IntPtr obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteDC(IntPtr dc);
}
