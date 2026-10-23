// 隐藏的顶层窗口：收 WM_HOTKEY、WM_CLIPBOARDUPDATE 和托盘回调。
// 不用 HWND_MESSAGE（消息专用窗口收不到 TaskbarCreated 广播）。
// 窗口过程用 [UnmanagedCallersOnly] + 函数指针，不用委托封送。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe class HiddenWindow
{
    private const string ClassName = "KittyTools.HiddenWindow";
    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> WndProcPtr = &WndProc;

    private static HINSTANCE _instance;

    public static HWND Hwnd { get; private set; }

    public static uint TaskbarCreatedMessage { get; private set; }

    public static event Action<uint, WPARAM, LPARAM>? Message;

    public static bool Create()
    {
        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        _instance = new HINSTANCE(module.Value);
        TaskbarCreatedMessage = PInvoke.RegisterWindowMessage("TaskbarCreated");

        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = WndProcPtr,
            hInstance = _instance,
        };

        fixed (char* className = ClassName)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Error($"hidden.class-failed {Marshal.GetLastWin32Error()}");
                return false;
            }
        }

        Hwnd = Native.CreateWindowEx(0, ClassName, "KittyTools.Hidden", 0, 0, 0, 0, 0, default, default, _instance, (void*)0);
        if (Hwnd == default)
        {
            Log.Error($"hidden.create-failed {Marshal.GetLastWin32Error()}");
            return false;
        }

        PInvoke.AddClipboardFormatListener(Hwnd);
        Log.Info("hidden.ready");
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT WndProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
    {
        try
        {
            if (msg == TaskbarCreatedMessage && TaskbarCreatedMessage != 0)
            {
                Tray.ReAdd();
            }

            Message?.Invoke(msg, wParam, lParam);
        }
        catch (Exception ex)
        {
            Log.Error("wndproc.exception", ex);
        }

        return PInvoke.DefWindowProc(hwnd, msg, wParam, lParam);
    }
}

// [LibraryImport] 只包 CreateWindowExW：CsWin32 在 allowMarshaling=false 下生成的
// CreateWindowEx 丢掉了 lpfnWndProc 参数（会按错误的参数个数调用），不能直接用。
// ponytail: 就这一处；CsWin32 修好后删掉。
internal static unsafe partial class Native
{
    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr CreateWindowExRaw(
        uint dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu,
        IntPtr instance,
        void* param);

    public static HWND CreateWindowEx(
        uint exStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        HWND parent,
        IntPtr menu,
        HINSTANCE instance,
        void* param)
        => (HWND)CreateWindowExRaw(exStyle, className, windowName, style, x, y, width, height, (IntPtr)parent.Value, menu, (IntPtr)instance.Value, param);
}
