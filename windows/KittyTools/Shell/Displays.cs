// 显示器信息：按目标显示器取工作区和缩放比例（GetDpiForMonitor），
// 不拿窗口当前所在那块屏的 DPI（窗口要挪去的屏缩放不同时尺寸全错，第二版 §2 第 5 条）。
using KittyTools.Core;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;

namespace KittyTools;

internal static unsafe class Displays
{
    /// <summary>一块显示器的工作区和它的缩放比例（1.0 = 100%）。</summary>
    internal readonly record struct Display(WorkArea Work, double Scale)
    {
        public static readonly Display Fallback = new(new WorkArea(0, 0, 1920, 1040), 1.0);
    }

    public static Display AtCursor()
    {
        PInvoke.GetCursorPos(out var cursor);
        return AtMonitor(PInvoke.MonitorFromPoint(cursor, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST));
    }

    public static Display AtPoint(int x, int y)
        => AtMonitor(PInvoke.MonitorFromPoint(
            new System.Drawing.Point(x, y), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST));

    public static Display AtWindow(HWND hwnd)
        => AtMonitor(PInvoke.MonitorFromWindow(hwnd, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST));

    public static Display AtMonitor(HMONITOR monitor)
    {
        if (monitor == default)
        {
            return Display.Fallback;
        }

        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        var work = PInvoke.GetMonitorInfo(monitor, ref info)
            ? new WorkArea(info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom)
            : Display.Fallback.Work;
        return new Display(work, ScaleOf(monitor));
    }

    public static double ScaleOf(HMONITOR monitor)
    {
        if (FakeScale is { } fake)
        {
            return fake;
        }

        if (monitor == default)
        {
            return 1.0;
        }

        uint dpiX = 96;
        uint dpiY = 96;
        if (PInvoke.GetDpiForMonitor(monitor, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, &dpiX, &dpiY).Failed)
        {
            return 1.0;
        }

        return MonitorLayout.ScaleOf(dpiX);
    }

    /// <summary>系统 DPI（后台扫描应用图标时用：那时还没有面板窗口）。</summary>
    public static double SystemScale => MonitorLayout.ScaleOf(PInvoke.GetDpiForSystem());

    /// <summary>调试用 --fake-dpi=150：没有第二块屏也能看 150% 布局；null 表示用真实 DPI。</summary>
    public static double? FakeScale { get; set; }
}
