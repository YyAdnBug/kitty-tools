// 截图第一步：先把每块显示器 BitBlt 成冻结帧（物理像素），再盖遮罩。
// 第 0 批只做单屏也能用的通用枚举；像素格式统一 BGRA、自上而下。
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;

namespace KittyTools;

internal sealed class FrozenMonitor
{
    public required RectInt32 Bounds { get; init; }

    public required byte[] Pixels { get; init; }

    public int Width => Bounds.Width;

    public int Height => Bounds.Height;

    public double FreezeMs { get; init; }

    public double Scale { get; init; } = 1.0;
}

internal static unsafe class ScreenCapture
{
    private const uint SrcCopy = 0x00CC0020;

    private static readonly delegate* unmanaged[Stdcall]<HMONITOR, HDC, RECT*, LPARAM, BOOL> MonitorProc = &OnMonitor;
    private static readonly List<(HMONITOR Handle, RectInt32 Bounds)> Monitors = new();

    public static List<FrozenMonitor> FreezeAll()
    {
        Monitors.Clear();
        PInvoke.EnumDisplayMonitors(default, null, MonitorProc, default);

        var result = new List<FrozenMonitor>(Monitors.Count);
        var screen = PInvoke.GetDC(default);
        if (screen == default)
        {
            ProbeLog.Write("capture.no-screen-dc", ("error", Marshal.GetLastWin32Error()));
            return result;
        }

        try
        {
            foreach (var (handle, bounds) in Monitors)
            {
                var t0 = Stopwatch.GetTimestamp();
                var pixels = CaptureRect(screen, bounds);
                var ms = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
                var scale = 1.0;
                if (PInvoke.GetDpiForMonitor(handle, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, out var dpiX, out _).Succeeded)
                {
                    scale = dpiX / 96.0;
                }
                result.Add(new FrozenMonitor { Bounds = bounds, Pixels = pixels, FreezeMs = ms, Scale = scale });
                ProbeLog.Write(
                    "capture.freeze",
                    ("x", bounds.X),
                    ("y", bounds.Y),
                    ("w", bounds.Width),
                    ("h", bounds.Height),
                    ("scale", scale),
                    ("ms", ms));
            }
        }
        finally
        {
            PInvoke.ReleaseDC(default, screen);
        }

        return result;
    }

    public static byte[] CaptureRect(HDC screen, RectInt32 rect)
    {
        var memory = PInvoke.CreateCompatibleDC(screen);
        var bitmap = PInvoke.CreateCompatibleBitmap(screen, rect.Width, rect.Height);
        if (memory == default || bitmap == default)
        {
            ProbeLog.Write("capture.dc-failed", ("error", Marshal.GetLastWin32Error()));
            return new byte[rect.Width * rect.Height * 4];
        }

        var previous = PInvoke.SelectObject(memory, bitmap);
        try
        {
            if (!PInvoke.BitBlt(memory, 0, 0, rect.Width, rect.Height, screen, rect.X, rect.Y, ROP_CODE.SRCCOPY))
            {
                ProbeLog.Write("capture.bitblt-failed", ("error", Marshal.GetLastWin32Error()));
            }

            var pixels = new byte[rect.Width * rect.Height * 4];
            var info = new BITMAPINFO
            {
                bmiHeader = new BITMAPINFOHEADER
                {
                    biSize = (uint)sizeof(BITMAPINFOHEADER),
                    biWidth = rect.Width,
                    biHeight = -rect.Height,
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = (uint)BI_COMPRESSION.BI_RGB,
                },
            };

            fixed (byte* p = pixels)
            {
                var lines = PInvoke.GetDIBits(memory, bitmap, 0, (uint)rect.Height, p, &info, DIB_USAGE.DIB_RGB_COLORS);
                if (lines != rect.Height)
                {
                    ProbeLog.Write("capture.dib-failed", ("lines", lines), ("error", Marshal.GetLastWin32Error()));
                }
            }

            // GDI 不给 alpha；不补 1 的话 Win2D 会把整张图当透明。
            for (var i = 3; i < pixels.Length; i += 4)
            {
                pixels[i] = 255;
            }

            return pixels;
        }
        finally
        {
            PInvoke.SelectObject(memory, previous);
            PInvoke.DeleteObject(bitmap);
            PInvoke.DeleteDC(memory);
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static BOOL OnMonitor(HMONITOR monitor, HDC hdc, RECT* rect, LPARAM data)
    {
        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        if (!PInvoke.GetMonitorInfo(monitor, ref info))
        {
            return true;
        }

        var rc = info.rcMonitor;
        Monitors.Add((
            monitor,
            new RectInt32(rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top)));
        return true;
    }
}
