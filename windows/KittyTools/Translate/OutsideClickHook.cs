// 复制即译的浮窗只露出、不激活，所以收不到「失去激活」：装一个 WH_MOUSE_LL 低级鼠标钩子，
// 点到窗口外面就收起。钩子回调里只判断坐标，实际收起丢回 UI 线程。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static unsafe partial class OutsideClickHook
{
    private const int WhMouseLl = 14;
    private const int WmLButtonDown = 0x0201;
    private const int WmRButtonDown = 0x0204;

    private static IntPtr _hook;
    private static Action? _onOutside;
    private static DispatcherQueue? _dispatcher;
    private static HWND _hwnd;

    public static void Install(HWND hwnd, Action onOutside)
    {
        Uninstall();
        _hwnd = hwnd;
        _onOutside = onOutside;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        _hook = SetWindowsHookEx(WhMouseLl, (IntPtr)(delegate* unmanaged[Stdcall]<int, WPARAM, LPARAM, LRESULT>)&Callback,
            module, 0);
        if (_hook == IntPtr.Zero)
        {
            Log.Warn($"translate.hook-failed {Marshal.GetLastWin32Error()}");
        }
    }

    public static void Uninstall()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }

        _onOutside = null;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static LRESULT Callback(int code, WPARAM wParam, LPARAM lParam)
    {
        try
        {
            if (code >= 0 && (wParam.Value == WmLButtonDown || wParam.Value == WmRButtonDown) &&
                PInvoke.GetWindowRect(_hwnd, out var window))
            {
                var point = *(Point*)lParam.Value;
                if (point.X < window.left || point.X > window.right ||
                    point.Y < window.top || point.Y > window.bottom)
                {
                    var dispatcher = _dispatcher;
                    var action = _onOutside;
                    dispatcher?.TryEnqueue(() =>
                    {
                        Uninstall();
                        action?.Invoke();
                    });
                }
            }
        }
        catch
        {
            // 钩子回调里不能抛。
        }

        return new LRESULT((nint)CallNextHookEx(IntPtr.Zero, code, (IntPtr)wParam.Value, (IntPtr)lParam.Value));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    private static partial IntPtr SetWindowsHookEx(int idHook, IntPtr callback, IntPtr module, uint threadId);

    [LibraryImport("user32.dll", EntryPoint = "UnhookWindowsHookEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnhookWindowsHookEx(IntPtr hook);

    [LibraryImport("user32.dll", EntryPoint = "CallNextHookEx", SetLastError = true)]
    private static partial IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
}
