// 拖边改大小（PLAN-v14 V9，mac 3e94388d 的 ResizeEdge）：用系统的拖边，不自己画拖边条。窗口子类化处理四条消息：
// - WM_NCHITTEST：顶边和两个上角改回 HTCLIENT（顶边不动，同 mac；也免得和「按住空白处拖动挪面板」抢）。
// - WM_SIZING：按拖的那条边把宽、高夹进范围（DIP 换成这块屏的像素），往下长不出工作区。
// - WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE：包住「用户正在拖」，这期间内容变化不改高度（同 mac isDraggingHeight），
//   松手交给调用方记下来、再按新上限改一次高度。
// 替用户定的：下面两个角也能拖（Windows 用户习惯拖角，一次改宽和行数），mac 没有角。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using Windows.Win32.Foundation;

namespace KittyTools;

/// <summary>拖边能拖到的范围（DIP）；高度上限另外不超过工作区底边。</summary>
internal readonly record struct PanelSizeLimits(double MinWidth, double MaxWidth, double MinHeight, double MaxHeight);

internal sealed unsafe partial class PanelResize
{
    private const uint WmNcHitTest = 0x0084;
    private const uint WmSizing = 0x0214;
    private const uint WmEnterSizeMove = 0x0231;
    private const uint WmExitSizeMove = 0x0232;
    private const uint WmNcDestroy = 0x0082;

    private static readonly Dictionary<IntPtr, PanelResize> Windows = new();

    private readonly IntPtr _hwnd;
    private readonly Func<PanelSizeLimits> _limits;
    private PanelSizeLimits _current;
    private Displays.Display _display;
    private RECT _start;

    public PanelResize(HWND hwnd, Func<PanelSizeLimits> limits)
    {
        _hwnd = (IntPtr)hwnd.Value;
        _limits = limits;
        Windows[_hwnd] = this;
        SetWindowSubclass(_hwnd, &Proc, 1, 0);
    }

    /// <summary>用户正在拖边（这期间别按内容改窗口大小）。</summary>
    public bool IsSizing { get; private set; }

    /// <summary>开始拖。</summary>
    public event Action? Started;

    /// <summary>松手：宽变了没有、高变了没有（像素比较；按住没拖就松手两个都是 false）。</summary>
    public event Action<bool, bool>? Ended;

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static IntPtr Proc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        try
        {
            if (Windows.TryGetValue(hwnd, out var self) && self.Handle(message, wParam, lParam) is { } handled)
            {
                return handled;
            }

            if (message == WmNcDestroy)
            {
                Windows.Remove(hwnd);
            }
        }
        catch
        {
            // 窗口过程里不能抛：交给默认处理。
        }

        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private IntPtr? Handle(uint message, IntPtr wParam, IntPtr lParam)
    {
        switch (message)
        {
            case WmNcHitTest:
            {
                var hit = DefSubclassProc(_hwnd, message, wParam, lParam);
                // HTTOP 12 / HTTOPLEFT 13 / HTTOPRIGHT 14 → HTCLIENT 1
                return hit is 12 or 13 or 14 ? 1 : hit;
            }

            case WmEnterSizeMove:
                _current = _limits();
                _display = Displays.AtWindow(new HWND((void*)_hwnd));
                GetWindowRect(_hwnd, out _start);
                IsSizing = true;
                Started?.Invoke();
                return null;
            case WmSizing:
                Clamp((int)wParam, (RECT*)lParam);
                return 1;
            case WmExitSizeMove when IsSizing:
            {
                IsSizing = false;
                GetWindowRect(_hwnd, out var end);
                Ended?.Invoke(end.right - end.left != _start.right - _start.left, end.bottom - end.top != _start.bottom - _start.top);
                return null;
            }

            default:
                return null;
        }
    }

    /// <summary>WMSZ_LEFT 1、RIGHT 2、TOP 3、TOPLEFT 4、TOPRIGHT 5、BOTTOM 6、BOTTOMLEFT 7、BOTTOMRIGHT 8：动拖的那条边，另一边不动。</summary>
    private void Clamp(int edge, RECT* rect)
    {
        var scale = _display.Scale <= 0 ? 1 : _display.Scale;
        var minWidth = MonitorLayout.Pixels(_current.MinWidth, scale);
        var maxWidth = Math.Max(minWidth, Math.Min(MonitorLayout.Pixels(_current.MaxWidth, scale), _display.Work.Right - _display.Work.Left));
        var minHeight = MonitorLayout.Pixels(_current.MinHeight, scale);
        var maxHeight = Math.Max(minHeight, Math.Min(MonitorLayout.Pixels(_current.MaxHeight, scale), _display.Work.Bottom - rect->top));
        var width = Math.Clamp(rect->right - rect->left, minWidth, maxWidth);
        var height = Math.Clamp(rect->bottom - rect->top, minHeight, maxHeight);
        if (edge is 1 or 4 or 7)
        {
            rect->left = rect->right - width;
        }
        else
        {
            rect->right = rect->left + width;
        }

        // 顶边不动（上边、上角在命中测试里已经关掉了，这里再兜一道）
        rect->top = _start.top;
        rect->bottom = rect->top + height;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(
        IntPtr hwnd, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, UIntPtr, UIntPtr, IntPtr> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr hwnd, out RECT rect);
}
