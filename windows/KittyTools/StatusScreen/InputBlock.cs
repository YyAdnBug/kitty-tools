// 状态屏的输入拦截（PLAN-v12 N5，mac StatusScreen/InputBlock.swift 的 Windows 做法）：WH_KEYBOARD_LL + WH_MOUSE_LL 低级钩子，
// 键盘（含 Win 键、Alt+Tab、媒体键）、鼠标按键和滚轮全吞掉（回调返回 1），鼠标移动放行（退出提示靠它浮出、光标照常动）。
// 吞不掉的：Ctrl+Alt+Del（安全注意序列，正好当最后的出口）、Win+L、电源键、合盖、触屏的边缘手势、UAC 的安全桌面。
// 全 App 只有这里吞输入；状态屏的会话（StatusScreenHost）是唯一的调用方。
// 钩子跑在单独线程的消息循环上（同 InputHooks、EscapeKeyWatch）：回调只把事件丢给 UI 线程、马上返回，UI 线程忙也不会超时被系统摘掉。
// 系统摘钩子不发通知：会话每分钟 Refresh 一次（先装新的再摘旧的，中间不漏）。锁屏时 Pause（登录界面要能用），解锁会话就结束了。
// 自检（Probe = true）：只吞带 ProbeMarker 的注入事件，真的键盘鼠标照常放行——测试和截图自检绝不能真的把人拦住（mac-overlay-panel §11）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static unsafe class InputBlock
{
    /// <summary>自检发的事件带的 dwExtraInfo（"KITT"）：Probe 模式下只吞它。</summary>
    public const nuint ProbeMarker = 0x4B495454;

    private const int WhKeyboardLowLevel = 13;
    private const int WhMouseLowLevel = 14;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int WmMouseMove = 0x0200;
    private const int WmLButtonDown = 0x0201;
    private const int WmLButtonUp = 0x0202;
    private const int WmMouseWheel = 0x020A;
    private const int WmMouseHWheel = 0x020E;
    private const uint LlkhfExtended = 0x01;

    // 钩子线程上的自定义消息（WM_APP 起）：摘掉 / 装上 / 换一份新的。
    private const uint WmPause = 0x8001;
    private const uint WmResume = 0x8002;
    private const uint WmRefresh = 0x8003;

    private static IntPtr _keyboardHook;
    private static IntPtr _mouseHook;
    private static uint _threadId;
    private static Thread? _thread;
    private static volatile bool _running;
    private static volatile bool _swallowing;
    private static volatile bool _probe;
    private static long _lastMove;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _queue;
    private static Action<StatusInput>? _onInput;
    private static Action<int, int>? _onMove;
    private static readonly ManualResetEventSlim Ready = new();

    /// <summary>UI 线程上记着哪些键按着：算连发、算有没有修饰键（LL 钩子不给这两样）。</summary>
    private static readonly HashSet<int> Down = new();

    public static bool Active => _running;

    /// <summary>这一轮拦下了几个事件（自检看它）。只在 UI 线程上加。</summary>
    public static int Swallowed { get; private set; }

    /// <summary>
    /// 在 UI 线程上调：装上钩子，之后每个拦下的事件在 UI 线程上交给 onInput、鼠标移动（每 16 ms 最多一次）交给 onMove。
    /// 装不上返回 false（会话就不进入）。
    /// </summary>
    public static bool Start(Action<StatusInput> onInput, Action<int, int> onMove, bool probe = false)
    {
        if (_running)
        {
            return true;
        }

        _queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _onInput = onInput;
        _onMove = onMove;
        _probe = probe;
        Down.Clear();
        Swallowed = 0;
        _swallowing = true;
        _running = true;
        Ready.Reset();
        _thread = new Thread(Run) { IsBackground = true, Name = "kitty-input-block" };
        _thread.Start();
        Ready.Wait(TimeSpan.FromSeconds(2));
        if (_keyboardHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
        {
            Stop();
            return false;
        }

        Log.Info($"status.block-start probe={probe}");
        return true;
    }

    public static void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        _swallowing = false;
        if (_threadId != 0)
        {
            PostThreadMessageW(_threadId, 0x0012 /* WM_QUIT */, IntPtr.Zero, IntPtr.Zero);
        }

        _thread?.Join(TimeSpan.FromSeconds(2));
        _thread = null;
        _threadId = 0;
        _onInput = null;
        _onMove = null;
        Down.Clear();
        Log.Info($"status.block-stop swallowed={Swallowed}");
    }

    /// <summary>锁屏、会话切走：摘掉钩子（登录界面要能用）。</summary>
    public static void Pause()
    {
        _swallowing = false;
        Down.Clear();
        Post(WmPause);
    }

    public static void Resume()
    {
        _swallowing = true;
        Post(WmResume);
    }

    /// <summary>换一份新钩子（系统万一因为超时摘掉了旧的，不会通知）：先装新的再摘旧的。</summary>
    public static void Refresh() => Post(WmRefresh);

    private static void Post(uint message)
    {
        if (_running && _threadId != 0)
        {
            PostThreadMessageW(_threadId, message, IntPtr.Zero, IntPtr.Zero);
        }
    }

    private static void Run()
    {
        _threadId = GetCurrentThreadId();
        Install();
        Ready.Set();
        if (_keyboardHook == IntPtr.Zero || _mouseHook == IntPtr.Zero)
        {
            Log.Warn($"status.block-hook-failed {Marshal.GetLastPInvokeError()}");
            Uninstall();
            return;
        }

        while (_running && GetMessageW(out var message, IntPtr.Zero, 0, 0) > 0)
        {
            switch (message.Message)
            {
                case WmPause:
                    Uninstall();
                    break;
                case WmResume:
                    if (_keyboardHook == IntPtr.Zero)
                    {
                        Install();
                    }

                    break;
                case WmRefresh:
                    var (oldKeyboard, oldMouse) = (_keyboardHook, _mouseHook);
                    if (oldKeyboard == IntPtr.Zero)
                    {
                        break;
                    }

                    Install();
                    if (_keyboardHook != IntPtr.Zero && _keyboardHook != oldKeyboard)
                    {
                        UnhookWindowsHookEx(oldKeyboard);
                    }

                    if (_mouseHook != IntPtr.Zero && _mouseHook != oldMouse)
                    {
                        UnhookWindowsHookEx(oldMouse);
                    }

                    break;
                default:
                    TranslateMessage(ref message);
                    DispatchMessageW(ref message);
                    break;
            }
        }

        Uninstall();
    }

    private static void Install()
    {
        var keyboard = SetWindowsHookExW(WhKeyboardLowLevel, &KeyboardProc, IntPtr.Zero, 0);
        var mouse = SetWindowsHookExW(WhMouseLowLevel, &MouseProc, IntPtr.Zero, 0);
        if (keyboard != IntPtr.Zero)
        {
            _keyboardHook = keyboard;
        }

        if (mouse != IntPtr.Zero)
        {
            _mouseHook = mouse;
        }
    }

    private static void Uninstall()
    {
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }

        if (_mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
    }

    /// <summary>这个事件吞不吞：暂停着不吞；自检时只吞带标记的。</summary>
    private static bool Claims(nuint extraInfo) => _swallowing && (!_probe || extraInfo == ProbeMarker);

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            var info = (KbdllHookStruct*)lParam;
            if (code >= 0 && Claims(info->ExtraInfo))
            {
                var message = (int)wParam;
                var down = message is WmKeyDown or WmSysKeyDown;
                if (down || message is WmKeyUp or WmSysKeyUp)
                {
                    var key = (int)info->VirtualKey;
                    var scan = (int)info->ScanCode;
                    var extended = (info->Flags & LlkhfExtended) != 0;
                    _queue?.TryEnqueue(() => DeliverKey(down, key, scan, extended));
                }

                return 1;
            }
        }
        catch
        {
            // 钩子回调里不能抛。
        }

        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            var info = (MsllHookStruct*)lParam;
            var message = (int)wParam;
            if (code >= 0 && _swallowing)
            {
                var x = info->X;
                var y = info->Y;
                if (message == WmMouseMove)
                {
                    // 移动放行，只报给会话（每 16 ms 最多一次，1000 Hz 的鼠标也不会把 UI 线程的队列塞满）。
                    var now = Environment.TickCount64;
                    if (now - _lastMove >= 16)
                    {
                        _lastMove = now;
                        _queue?.TryEnqueue(() => _onMove?.Invoke(x, y));
                    }
                }
                else if (Claims(info->ExtraInfo))
                {
                    StatusInputKind? kind = message switch
                    {
                        WmLButtonDown => StatusInputKind.LeftDown,
                        WmLButtonUp => StatusInputKind.LeftUp,
                        WmMouseWheel or WmMouseHWheel => StatusInputKind.Scroll,
                        0x0204 or 0x0207 or 0x020B => StatusInputKind.Touch, // 右键、中键、侧键按下
                        _ => null, // 别的键松开：吞掉，不报
                    };
                    if (kind is { } value)
                    {
                        _queue?.TryEnqueue(() => Deliver(new StatusInput(value, X: x, Y: y)));
                    }
                    else
                    {
                        _queue?.TryEnqueue(() => Swallowed++);
                    }

                    return 1;
                }
            }
        }
        catch
        {
            // 钩子回调里不能抛。
        }

        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    /// <summary>UI 线程：按键补上连发、修饰键两样再交出去。</summary>
    private static void DeliverKey(bool down, int key, int scan, bool extended)
    {
        if (!_running)
        {
            return;
        }

        if (!down)
        {
            Down.Remove(key);
            Deliver(new StatusInput(StatusInputKind.KeyUp, key, scan, extended));
            return;
        }

        var repeat = !Down.Add(key);
        var modifiers = Down.Any(other => other != key && IsModifier(other));
        Deliver(new StatusInput(StatusInputKind.KeyDown, key, scan, extended, repeat, modifiers));
    }

    private static void Deliver(StatusInput input)
    {
        Swallowed++;
        if (_running)
        {
            _onInput?.Invoke(input);
        }
    }

    /// <summary>Shift / Ctrl / Alt（左右两个和通用的）、左右 Win。</summary>
    private static bool IsModifier(int key) => key is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5 or 0x5B or 0x5C;

    /// <summary>
    /// 自检：发一个带标记的按键（默认按下再松开；只按下 / 只松开用来模拟按住）。Probe 模式下钩子吞掉它、真的输入照常放行；
    /// Swallowed 涨了就是拦住了。
    /// </summary>
    public static void SendProbeKey(ushort virtualKey, bool down = true, bool up = true)
    {
        var inputs = stackalloc RawInput[2];
        var count = 0;
        if (down)
        {
            inputs[count++] = new RawInput { Type = 1 /* INPUT_KEYBOARD */, VirtualKey = virtualKey, ExtraInfo = ProbeMarker };
        }

        if (up)
        {
            inputs[count++] = new RawInput { Type = 1, VirtualKey = virtualKey, Flags = 0x0002 /* KEYEVENTF_KEYUP */, ExtraInfo = ProbeMarker };
        }

        if (count > 0)
        {
            SendInput((uint)count, inputs, sizeof(RawInput));
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdllHookStruct
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MsllHookStruct
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    /// <summary>INPUT（键盘那一支）：type 之后是联合体，按 MOUSEINPUT 最大的那一支占位（x64 / ARM64 都是 40 字节）。</summary>
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct RawInput
    {
        [FieldOffset(0)]
        public uint Type;

        [FieldOffset(8)]
        public ushort VirtualKey;

        [FieldOffset(10)]
        public ushort Scan;

        [FieldOffset(12)]
        public uint Flags;

        [FieldOffset(16)]
        public uint Time;

        [FieldOffset(24)]
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Msg
    {
        public IntPtr Hwnd;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookExW(int hook, delegate* unmanaged[Stdcall]<int, IntPtr, IntPtr, IntPtr> callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessageW(out Msg message, IntPtr hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref Msg message);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(ref Msg message);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessageW(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, RawInput* inputs, int size);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
}
