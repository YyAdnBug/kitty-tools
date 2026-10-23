// 写剪贴板和发 Ctrl+V / Ctrl+C。第 0 批只覆盖纯文本。
// 顺序照 PLAN §5.5：还前台 → 等它真的到前台 → 写剪贴板 → 等修饰键松开 → 发 Ctrl+V。
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static unsafe class Paster
{
    // CF_UNICODETEXT，取自 winuser.h。CsWin32 把它放进 CLIPBOARD_FORMAT 枚举，
    // allowMarshaling=false 时那个枚举的命名空间随元数据版本变，写死一个数更稳。
    private const uint CF_UNICODETEXT = 13;

    public static bool PasteText(HWND target, string text)
    {
        var t0 = Stopwatch.GetTimestamp();
        OverlayHost.Hide(restoreForeground: false);

        var targetPid = Foreground.PidOf(target);
        var targetElevated = Foreground.IsProcessElevated(targetPid);
        var selfElevated = Foreground.IsProcessElevated((uint)Environment.ProcessId);
        var adminBlocked = targetElevated && !selfElevated;
        ProbeLog.Write(
            "paste.target",
            ("pid", targetPid),
            ("elevated", targetElevated),
            ("self_elevated", selfElevated),
            ("admin_blocked", adminBlocked));

        var reached = Foreground.Restore(target);
        if (!reached)
        {
            ProbeLog.Write("paste.abort", ("reason", "foreground"));
        }

        WriteText(text);
        var sequence = PInvoke.GetClipboardSequenceNumber();
        ProbeLog.Write("paste.clipboard", ("chars", text.Length), ("sequence", sequence));

        if (adminBlocked)
        {
            ProbeLog.Write("paste.admin-blocked", ("ms", Ms(t0, Stopwatch.GetTimestamp())));
            return false;
        }

        var waited = Keyboard.WaitModifiersReleased(300);
        ProbeLog.Write("paste.modifiers", ("waited_ms", waited));

        var sent = Keyboard.SendCtrlV();
        PInvoke.DwmFlush();
        ProbeLog.Write("paste.sent", ("ok", sent), ("total_ms", Ms(t0, Stopwatch.GetTimestamp())));
        return sent;
    }

    public static bool WriteText(string text)
    {
        if (!PInvoke.OpenClipboard(HiddenWindow.Hwnd))
        {
            ProbeLog.Write("clipboard.open-failed", ("error", Marshal.GetLastWin32Error()));
            return false;
        }

        try
        {
            if (!PInvoke.EmptyClipboard())
            {
                ProbeLog.Write("clipboard.empty-failed", ("error", Marshal.GetLastWin32Error()));
                return false;
            }

            var bytes = (nuint)((text.Length + 1) * sizeof(char));
            var memory = PInvoke.GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, bytes);
            if (memory == default)
            {
                ProbeLog.Write("clipboard.alloc-failed", ("error", Marshal.GetLastWin32Error()));
                return false;
            }

            var destination = PInvoke.GlobalLock(memory);
            if (destination is null)
            {
                PInvoke.GlobalFree(memory);
                return false;
            }

            text.AsSpan().CopyTo(new Span<char>(destination, text.Length));
            ((char*)destination)[text.Length] = '\0';
            PInvoke.GlobalUnlock(memory);

            if (PInvoke.SetClipboardData(CF_UNICODETEXT, new HANDLE(memory.Value)) == default)
            {
                PInvoke.GlobalFree(memory);
                ProbeLog.Write("clipboard.set-failed", ("error", Marshal.GetLastWin32Error()));
                return false;
            }

            return true;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    private static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}

internal static unsafe class Keyboard
{
    public static void TapAlt()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x12, KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY);
        inputs[1] = KeyInput((VIRTUAL_KEY)0x12, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP | KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY);
        Send(inputs);
    }

    public static bool SendCtrlV()
    {
        Span<INPUT> inputs = stackalloc INPUT[4];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x11, 0);
        inputs[1] = KeyInput((VIRTUAL_KEY)0x56, 0);
        inputs[2] = KeyInput((VIRTUAL_KEY)0x56, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        inputs[3] = KeyInput((VIRTUAL_KEY)0x11, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return Send(inputs) == 4;
    }

    public static bool SendEnter()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x0D, 0);
        inputs[1] = KeyInput((VIRTUAL_KEY)0x0D, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return Send(inputs) == 2;
    }

    public static bool SendEscape()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x1B, 0);
        inputs[1] = KeyInput((VIRTUAL_KEY)0x1B, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return Send(inputs) == 2;
    }

    public static bool SendText(string text)
    {
        var inputs = new INPUT[text.Length * 2];
        for (var i = 0; i < text.Length; i++)
        {
            inputs[i * 2] = UnicodeInput(text[i], false);
            inputs[(i * 2) + 1] = UnicodeInput(text[i], true);
        }

        fixed (INPUT* p = inputs)
        {
            return PInvoke.SendInput((uint)inputs.Length, p, (int)sizeof(INPUT)) == (uint)inputs.Length;
        }
    }

    public static bool SendHotkey(VIRTUAL_KEY key, bool alt = true, bool ctrl = false, bool shift = false)
    {
        var inputs = new List<INPUT>(8);
        if (ctrl) inputs.Add(KeyInput((VIRTUAL_KEY)0x11, 0));
        if (alt) inputs.Add(KeyInput((VIRTUAL_KEY)0x12, 0));
        if (shift) inputs.Add(KeyInput((VIRTUAL_KEY)0x10, 0));
        inputs.Add(KeyInput(key, 0));
        inputs.Add(KeyInput(key, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP));
        if (shift) inputs.Add(KeyInput((VIRTUAL_KEY)0x10, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP));
        if (alt) inputs.Add(KeyInput((VIRTUAL_KEY)0x12, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP));
        if (ctrl) inputs.Add(KeyInput((VIRTUAL_KEY)0x11, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP));

        fixed (INPUT* p = inputs.ToArray())
        {
            var sent = PInvoke.SendInput((uint)inputs.Count, p, (int)sizeof(INPUT));
            ProbeLog.Write("input.sent", ("count", sent), ("expected", inputs.Count), ("error", Marshal.GetLastWin32Error()));
            return sent == (uint)inputs.Count;
        }
    }

    public static double WaitModifiersReleased(int maxMs)
    {
        var t0 = Stopwatch.GetTimestamp();
        var deadline = t0 + (long)(Stopwatch.Frequency * maxMs / 1000.0);
        while (Stopwatch.GetTimestamp() < deadline)
        {
            if (!IsDown(0x11) && !IsDown(0x12) && !IsDown(0x10) && !IsDown(0x5B) && !IsDown(0x5C))
            {
                return Ms(t0, Stopwatch.GetTimestamp());
            }
            Thread.Sleep(5);
        }

        // 还按着就补发它们的抬起。补 Alt 之前先敲一下没分配的 VK 0xE8，
        // 免得目标窗口把单独一个 Alt 当成「激活菜单栏」。
        if (IsDown(0x12))
        {
            SendHotkey((VIRTUAL_KEY)0xE8, alt: false);
        }

        return Ms(t0, Stopwatch.GetTimestamp());
    }

    public static bool IsDown(int vk) => (PInvoke.GetAsyncKeyState(vk) & 0x8000) != 0;

    private static INPUT KeyInput(VIRTUAL_KEY key, KEYBD_EVENT_FLAGS flags) => new()
    {
        type = INPUT_TYPE.INPUT_KEYBOARD,
        Anonymous = new INPUT._Anonymous_e__Union
        {
            ki = new KEYBDINPUT
            {
                wVk = key,
                wScan = 0,
                dwFlags = flags,
            },
        },
    };

    private static INPUT UnicodeInput(char ch, bool up) => new()
    {
        type = INPUT_TYPE.INPUT_KEYBOARD,
        Anonymous = new INPUT._Anonymous_e__Union
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = ch,
                dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE | (up ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0),
            },
        },
    };

    private static uint Send(ReadOnlySpan<INPUT> inputs)
    {
        fixed (INPUT* p = inputs)
        {
            return PInvoke.SendInput((uint)inputs.Length, p, (int)sizeof(INPUT));
        }
    }

    private static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}
