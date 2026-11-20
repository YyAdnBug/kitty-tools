// 没边框的 WinUI 窗口真的没边框（issue #38）：SetBorderAndTitleBar(false, false) 之后 WinUI 还给窗口留着 WS_DLGFRAME
// （自己改样式它又加回来），四边各 3 像素（随缩放变宽）系统画的浅色框（2026-11-12 屏上实测 E3 / FF / F0，便签药丸那次）。
// 以前状态屏、截图遮罩把窗口往外扩一圈、让客户区正好盖满整屏：单屏时那圈框在屏幕外看不见，多屏时压在隔壁屏的边上，
// 就是隔壁屏贴着这块屏的那条边上一道白边（issue #38）。这里在 WM_NCCALCSIZE 里直接答「客户区 = 整扇窗」，
// 窗口摆多大就盖多大；顺手关掉 Windows 11 的 DWM 细边框（窗口贴着屏幕边时它就画在屏幕最外一圈）。
// 便签的药丸和标签列（NoteDeckTiny）是同一招，和放开最小宽写在一起。
using System.Runtime.InteropServices;

namespace KittyTools;

internal static unsafe partial class Frameless
{
    private const uint WmNcCalcSize = 0x0083;

    /// <summary>在 SetPresenter 之后、摆窗口之前调；立刻按新规矩重算一次非客户区。</summary>
    public static void Apply(IntPtr hwnd)
    {
        SetWindowSubclass(hwnd, &Proc, 0x3833 /* 本类自己的子类编号 */, 0);
        var none = unchecked((int)0xFFFFFFFE); // DWMWA_COLOR_NONE
        DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &none, sizeof(int));
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020 /* NOSIZE | NOMOVE | NOZORDER | NOACTIVATE | FRAMECHANGED */);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr Proc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
        // 建议的窗口矩形原样当客户区（wParam 真假都一样答 0）
        => message == WmNcCalcSize ? IntPtr.Zero : DefSubclassProc(hwnd, message, wParam, lParam);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(
        IntPtr hwnd, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, UIntPtr, UIntPtr, IntPtr> proc, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
}
