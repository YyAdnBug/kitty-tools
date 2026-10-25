// 录屏的点按圈 / 按键胶囊（第四版第 3 批）：WH_MOUSE_LL + WH_KEYBOARD_LL 低级钩子，
// 只看按下；注入的按键（我们的粘贴 / 片段 / 取词）跳过。钩子跑在单独线程 + 消息循环上，
// 回调只把坐标 / 按键丢给 UI 线程，画圈和胶囊由 InputOverlay 做。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static unsafe class InputHooks
{
    public const int WhMouseLowLevel = 14;
    public const int WhKeyboardLowLevel = 13;

    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int WmLButtonDown = 0x0201;
    private const int WmLButtonUp = 0x0202;
    private const int WmRButtonDown = 0x0204;
    private const int WmRButtonUp = 0x0205;
    private const uint LlkhfInjected = 0x10;
    private const uint LlmhfInjected = 0x01;

    private static IntPtr _mouseHook;
    private static IntPtr _keyboardHook;
    private static uint _threadId;
    private static Thread? _thread;
    private static bool _running;
    private static PixelBounds _region;
    private static Action<int, int, bool, bool>? _click;
    private static Action<string>? _key;

    public static bool Active => _running;

    public static void Start(PixelBounds region, Action<int, int, bool, bool> click, Action<string> key)
    {
        if (_running)
        {
            return;
        }

        UIQueue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _region = region;
        _click = click;
        _key = key;
        _running = true;
        _thread = new Thread(Run) { IsBackground = true, Name = "kitty-input-hooks" };
        _thread.Start();
        Log.Info("record.input-hooks-start");
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
        Log.Info("record.input-hooks-stop");
    }

    private static void Run()
    {
        _threadId = GetCurrentThreadId();
        _mouseHook = SetWindowsHookExW(WhMouseLowLevel, &MouseProc, IntPtr.Zero, 0);
        _keyboardHook = SetWindowsHookExW(WhKeyboardLowLevel, &KeyboardProc, IntPtr.Zero, 0);
        if (_mouseHook == IntPtr.Zero || _keyboardHook == IntPtr.Zero)
        {
            Log.Warn($"record.hooks-failed mouse={_mouseHook} key={_keyboardHook}");
            _running = false;
            return;
        }

        while (_running && GetMessageW(out var message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref message);
            DispatchMessageW(ref message);
        }

        if (_mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }

        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0 && _running)
            {
                var info = (MsllHookStruct*)lParam;
                var message = (int)wParam;
                if ((info->Flags & LlmhfInjected) == 0 &&
                    message is WmLButtonDown or WmLButtonUp or WmRButtonDown or WmRButtonUp)
                {
                    var x = info->Point.X;
                    var y = info->Point.Y;
                    if (x >= _region.Left && x < _region.Right && y >= _region.Top && y < _region.Bottom)
                    {
                        var down = message is WmLButtonDown or WmRButtonDown;
                        var right = message is WmRButtonDown or WmRButtonUp;
                        var callback = _click;
                        var relativeX = x - _region.Left;
                        var relativeY = y - _region.Top;
                        if (callback is not null)
                        {
                            DispatcherQueueFor(callback, relativeX, relativeY, down, right);
                        }                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"record.mouse-hook {ex.GetType().Name}");
        }

        return CallNextHookEx(_mouseHook, code, wParam, lParam);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(System.Runtime.CompilerServices.CallConvStdcall) })]
    private static IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0 && _running)
            {
                var info = (KbdllHookStruct*)lParam;
                var message = (int)wParam;
                if (message is WmKeyDown or WmSysKeyDown && (info->Flags & LlkhfInjected) == 0)
                {
                    var text = KeycapText(info->VirtualKey);
                    var callback = _key;
                    if (text is not null && callback is not null)
                    {
                        DispatcherQueueForKey(callback, text);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"record.key-hook {ex.GetType().Name}");
        }

        return CallNextHookEx(_keyboardHook, code, wParam, lParam);
    }

    /// <summary>组合键写成「Ctrl + Shift + S」；单个字母不显示（只显示快捷键），功能键显示。</summary>
    private static string? KeycapText(uint key)
    {
        if (key is 0x11 or 0x12 or 0x10 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5)
        {
            return null;
        }

        var parts = new List<string>();
        if (IsDown(0x11) || IsDown(0xA2)) parts.Add("Ctrl");
        if (IsDown(0x12) || IsDown(0xA3)) parts.Add("Alt");
        if (IsDown(0x10) || IsDown(0xA0)) parts.Add("Shift");
        if (IsDown(0x5B) || IsDown(0x5C)) parts.Add("Win");
        var name = KeyName(key);
        if (name is null)
        {
            return null;
        }

        if (parts.Count == 0 && key is < 0x70 or > 0x87)
        {
            return null; // 单个字母 / 数字不显示
        }

        parts.Add(name);
        return string.Join(" + ", parts);
    }

    private static string? KeyName(uint key) => key switch
    {
        >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x41 and <= 0x5A => ((char)key).ToString(),
        >= 0x70 and <= 0x87 => $"F{key - 0x70 + 1}",
        0x20 => "Space",
        0x0D => "Enter",
        0x09 => "Tab",
        0x1B => "Esc",
        0x08 => "Backspace",
        0x2E => "Delete",
        0x25 => "←",
        0x26 => "↑",
        0x27 => "→",
        0x28 => "↓",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => null,
    };

    private static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    private static void DispatcherQueueFor(Action<int, int, bool, bool> callback, int x, int y, bool down, bool right)
    {
        UIQueue?.TryEnqueue(() => callback(x, y, down, right));
    }

    private static void DispatcherQueueForKey(Action<string> callback, string text)
    {
        UIQueue?.TryEnqueue(() => callback(text));
    }

    internal static Microsoft.UI.Dispatching.DispatcherQueue? UIQueue { get; set; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MsllHookStruct
    {
        public Point Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
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
        public Point Point;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookExW(int hook, delegate* unmanaged[Stdcall]<int, IntPtr, IntPtr, IntPtr> callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

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
