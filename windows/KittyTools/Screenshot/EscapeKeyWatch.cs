// 长截图期间的 Esc（PLAN-v11 M13）：以前是 RegisterHotKey(VK_ESCAPE) 注册的全局热键，整个长截图期间被拍的程序收不到 Esc
// （想关网页上的弹层就把长图丢了）。改成 WH_KEYBOARD_LL 低级钩子只看不吞：Esc 照样给前台程序，我们这边也收到，
// 交给 ScrollingCapture.RequestCancel（拼长了第一下只上膛）。钩子跑在单独线程的消息循环上（同 InputHooks），
// UI 线程忙着拼图时也不会因为超时被系统摘掉。只认真的按下：注入的、按住不放的自动重复都不算。
// Enter 照旧是临时热键（吞掉）：完成的那一下要是也给了网页，正好落在焦点所在的链接 / 按钮上。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static unsafe class EscapeKeyWatch
{
    private const int WhKeyboardLowLevel = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const uint VkEscape = 0x1B;
    private const uint LlkhfInjected = 0x10;

    private static IntPtr _hook;
    private static uint _threadId;
    private static Thread? _thread;
    private static volatile bool _running;
    private static bool _down;
    private static Action? _onEscape;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _queue;
    private static readonly ManualResetEventSlim Ready = new();

    /// <summary>在 UI 线程上调：之后每按下一次 Esc，onEscape 在 UI 线程上跑一次。</summary>
    public static void Start(Action onEscape)
    {
        if (_running)
        {
            return;
        }

        _queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _onEscape = onEscape;
        _down = false;
        _running = true;
        Ready.Reset();
        _thread = new Thread(Run) { IsBackground = true, Name = "kitty-escape-watch" };
        _thread.Start();
        // 等钩子线程拿到自己的线程号：紧接着 Stop 时 WM_QUIT 才发得到。
        Ready.Wait(TimeSpan.FromSeconds(1));
    }

    public static void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        if (_threadId != 0)
        {
            PostThreadMessageW(_threadId, 0x0012 /*WM_QUIT*/, IntPtr.Zero, IntPtr.Zero);
        }

        _thread?.Join(TimeSpan.FromSeconds(2));
        _thread = null;
        _threadId = 0;
        _onEscape = null;
    }

    private static void Run()
    {
        _threadId = GetCurrentThreadId();
        _hook = SetWindowsHookExW(WhKeyboardLowLevel, &KeyboardProc, IntPtr.Zero, 0);
        Ready.Set();
        if (_hook == IntPtr.Zero)
        {
            Log.Warn($"scroll.esc-hook-failed {Marshal.GetLastPInvokeError()}");
            _running = false;
            return;
        }

        while (_running && GetMessageW(out var message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref message);
            DispatchMessageW(ref message);
        }

        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            var info = (KbdllHookStruct*)lParam;
            if (code >= 0 && _running && info->VirtualKey == VkEscape && (info->Flags & LlkhfInjected) == 0)
            {
                var message = (int)wParam;
                if (message is WmKeyUp or WmSysKeyUp)
                {
                    _down = false;
                }
                else if (message is WmKeyDown or WmSysKeyDown && !_down)
                {
                    _down = true;
                    if (_onEscape is { } callback)
                    {
                        _queue?.TryEnqueue(() => callback());
                    }
                }
            }
        }
        catch
        {
            // 钩子回调里不能抛。
        }

        // 不吞：Esc 照样往下传给前台程序。
        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdllHookStruct
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
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

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
}
