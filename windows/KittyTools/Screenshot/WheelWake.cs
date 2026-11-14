// 长截图手动滚时「滚轮一来就醒」（PLAN-v20 W2，mac c7756c75 的 NSEvent 全局滚轮监听）：鼠标的 Raw Input（RIDEV_INPUTSINK，
// 挂在 HiddenWindow 上，只听不拦），只在手动长截图期间注册——注册着时每一下鼠标移动都会来一条 WM_INPUT，所以用完马上摘。
// 自己 SendInput 发的滚轮（自动滚动）hDevice 是 0，滤掉。回调给的是这一刻的光标位置（物理像素），落没落在选区里由调用方看。
// 键盘那一份（连按修饰键，ModifierTapListener）是另一个 usage，两边互不影响；它的 WM_INPUT 处理只认键盘，这里只认鼠标。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static unsafe partial class WheelWake
{
    private const uint WmInput = 0x00FF;
    private const uint RidInput = 0x10000003;
    private const uint RimTypeMouse = 0;
    private const uint RidevInputSink = 0x00000100;
    private const uint RidevRemove = 0x00000001;
    private const ushort RiMouseWheel = 0x0400;
    private const ushort RiMouseHWheel = 0x0800;

    private static Action<int, int>? _wheel;
    private static bool _listening;

    public static void Start(Action<int, int> wheel)
    {
        _wheel = wheel;
        if (_listening || !Register(on: true))
        {
            return;
        }

        _listening = true;
        HiddenWindow.Message += OnMessage;
    }

    public static void Stop()
    {
        _wheel = null;
        if (!_listening)
        {
            return;
        }

        _listening = false;
        HiddenWindow.Message -= OnMessage;
        Register(on: false);
    }

    private static bool Register(bool on)
    {
        var device = new RawInputDevice
        {
            UsagePage = 0x01,
            Usage = 0x02,
            Flags = on ? RidevInputSink : RidevRemove,
            Target = on ? (IntPtr)HiddenWindow.Hwnd.Value : IntPtr.Zero,
        };
        if (RegisterRawInputDevices(&device, 1, (uint)sizeof(RawInputDevice)))
        {
            return true;
        }

        Log.Warn($"scroll.wheel-wake-register-failed on={on} {Marshal.GetLastWin32Error()}");
        return false;
    }

    private static void OnMessage(uint msg, WPARAM wParam, LPARAM lParam)
    {
        if (msg != WmInput || _wheel is not { } wheel)
        {
            return;
        }

        // RAWINPUTHEADER（x64 / ARM64 是 24 字节）+ RAWMOUSE（usFlags 2 + 对齐 2 + usButtonFlags 2 + usButtonData 2 + …，共 24 字节）
        var buffer = stackalloc byte[64];
        var size = 64u;
        if (GetRawInputData(lParam.Value, RidInput, buffer, &size, 24) == uint.MaxValue || size < 32)
        {
            return;
        }

        var type = *(uint*)buffer;
        var device = *(IntPtr*)(buffer + 8);
        if (type != RimTypeMouse || device == IntPtr.Zero)
        {
            // 不是鼠标，或者是程序发的（SendInput 的 hDevice 是 0：自动滚动自己发的滚轮）
            return;
        }

        var buttons = *(ushort*)(buffer + 28);
        if ((buttons & (RiMouseWheel | RiMouseHWheel)) == 0)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        wheel(cursor.X, cursor.Y);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RawInputDevice
    {
        public ushort UsagePage;
        public ushort Usage;
        public uint Flags;
        public IntPtr Target;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterRawInputDevices(RawInputDevice* devices, uint count, uint size);

    [LibraryImport("user32.dll")]
    private static partial uint GetRawInputData(IntPtr rawInput, uint command, void* data, uint* size, uint headerSize);
}
