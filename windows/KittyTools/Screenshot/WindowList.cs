// 冻结那一刻的顶层窗口（Z 序从上到下），给吸附用：看得见、没最小化、没被隐藏、尺寸不为零的窗口；
// 边界取 DWMWA_EXTENDED_FRAME_BOUNDS（不含看不见的拉伸边）。
using System.Runtime.InteropServices;

namespace KittyTools;

internal readonly record struct SnapWindow(PixelBounds Bounds, int Z);

internal static unsafe partial class WindowList
{
    public static List<SnapWindow> Capture()
    {
        var result = new List<SnapWindow>();
        _result = result;
        var callback = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)&Collect;
        EnumWindows(callback, IntPtr.Zero);
        _result = null;
        return result;
    }

    /// <summary>所有窗口的边（左 / 右 / 上 / 下），吸附用。</summary>
    public static List<double> Edges(IReadOnlyList<SnapWindow> windows, PixelBounds monitor)
    {
        var edges = new List<double>
        {
            monitor.Left, monitor.Right, monitor.Top, monitor.Bottom,
        };
        foreach (var window in windows)
        {
            edges.Add(window.Bounds.Left);
            edges.Add(window.Bounds.Right);
            edges.Add(window.Bounds.Top);
            edges.Add(window.Bounds.Bottom);
        }

        return edges;
    }

    private static List<SnapWindow>? _result;

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static int Collect(IntPtr hwnd, IntPtr data)
    {
        try
        {
            if (_result is null || !IsWindowVisible(hwnd) || IsIconic(hwnd))
            {
                return 1;
            }

            if (DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            {
                return 1;
            }

            PixelBounds bounds;
            if (DwmGetWindowAttribute(hwnd, 9, out RECT frame, Marshal.SizeOf<RECT>()) == 0)
            {
                bounds = new PixelBounds(frame.Left, frame.Top, frame.Right, frame.Bottom);
            }
            else if (GetWindowRect(hwnd, out var rect))
            {
                bounds = new PixelBounds(rect.Left, rect.Top, rect.Right, rect.Bottom);
            }
            else
            {
                return 1;
            }

            if (bounds.Width <= 0 || bounds.Height <= 0)
            {
                return 1;
            }

            _result.Add(new SnapWindow(bounds, _result.Count));
        }
        catch
        {
            // 枚举回调里不能抛。
        }

        return 1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial int EnumWindows(IntPtr callback, IntPtr data);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindowVisible(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(IntPtr hwnd);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
}
