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

    /// <summary>(x, y) 落在某块接着的显示器上（那块屏拔掉了就不在）。钉回「当初框的那一块」之前先看一眼（第四轮体检 E3）。</summary>
    public static bool IsOnScreen(int x, int y)
        => PInvoke.MonitorFromPoint(new System.Drawing.Point(x, y), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONULL) != default;

    /// <summary>(x, y) 所在显示器的整块范围（含任务栏；主界面拿它和工作区比，看任务栏在哪条边）。</summary>
    public static WorkArea MonitorBoundsAt(int x, int y)
    {
        var monitor = PInvoke.MonitorFromPoint(new System.Drawing.Point(x, y), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        return monitor != default && PInvoke.GetMonitorInfo(monitor, ref info)
            ? new WorkArea(info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom)
            : Display.Fallback.Work;
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

    /// <summary>每块显示器（物理像素）：名字（「显示器 1」起，主显示器在最前、其余按左上排）、整块、工作区（去掉任务栏）、缩放、
    /// 是不是主显示器。便签屏幕边缘那叠、浮动便签用（PLAN-v13；那叠的摆法认第一块是主显示器）。</summary>
    // ponytail: 名字按排列顺序起，不读系统里的显示器型号（DisplayConfig 的接口一大套）；换了排列，「指定的那块」可能指到另一块。
    public static List<(string Name, WorkArea Bounds, WorkArea Work, double Scale, bool Primary)> All()
    {
        var result = new List<(string Name, WorkArea Bounds, WorkArea Work, double Scale, bool Primary)>();
        var index = 1;
        var monitors = ScreenCapture.Monitors()
            .Select(monitor => (monitor.Bounds, monitor.Scale,
                Primary: monitor.Bounds.Left <= 0 && monitor.Bounds.Top <= 0 && monitor.Bounds.Right > 0 && monitor.Bounds.Bottom > 0))
            .OrderByDescending(monitor => monitor.Primary).ThenBy(monitor => monitor.Bounds.Left).ThenBy(monitor => monitor.Bounds.Top);
        foreach (var (bounds, scale, primary) in monitors)
        {
            var display = AtPoint(bounds.Left + 1, bounds.Top + 1);
            var whole = new WorkArea(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
            result.Add(($"显示器 {index++}", whole, display.Work, scale, primary));
        }

        if (result.Count == 0)
        {
            result.Add(("显示器 1", Display.Fallback.Work, Display.Fallback.Work, 1.0, true));
        }

        return result;
    }

    /// <summary>系统 DPI（后台扫描应用图标时用：那时还没有面板窗口）。</summary>
    public static double SystemScale => MonitorLayout.ScaleOf(PInvoke.GetDpiForSystem());

    /// <summary>调试用 --fake-dpi=150：没有第二块屏也能看 150% 布局；null 表示用真实 DPI。</summary>
    public static double? FakeScale { get; set; }
}
