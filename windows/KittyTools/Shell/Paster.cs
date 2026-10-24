// 写剪贴板和发 Ctrl+V / Ctrl+C。PLAN §5.5：
// 收起面板 → 还前台 → 等它真的到前台 → 写剪贴板 → 等修饰键松开 → 发 Ctrl+V。
// 目标窗口是管理员时只写剪贴板、不粘贴，轻提示让用户手动粘。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Memory;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static unsafe class Paster
{
    public static bool PasteText(HWND target, string text)
        => Paste(target, () => ClipboardWriter.WriteText(text), ClipboardService.Instance);

    /// <summary>收起面板 → 还前台 → 写剪贴板（由 write 负责）→ 等修饰键 → 发 Ctrl+V。</summary>
    public static bool Paste(HWND target, Func<bool> write, ClipboardService? clipboard)
    {
        var started = Stopwatch.GetTimestamp();
        OverlayHost.Hide(restoreForeground: false);

        var targetPid = Foreground.PidOf(target);
        var targetElevated = Foreground.IsProcessElevated(targetPid);
        var selfElevated = Foreground.IsProcessElevated((uint)Environment.ProcessId);
        var adminBlocked = targetElevated && !selfElevated;

        var reached = Foreground.Restore(target);
        if (!reached)
        {
            Log.Warn("paste.foreground-failed");
        }

        if (!write())
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
            return false;
        }

        clipboard?.MarkOwnWrite();

        if (adminBlocked)
        {
            Log.Info("paste.admin-blocked");
            NoticeHost.Show("已复制", "目标窗口以管理员身份运行，请手动粘贴", NoticeTone.Warning);
            return false;
        }

        Keyboard.WaitModifiersReleased(300);
        var sent = Keyboard.SendCtrlV();
        if (!sent)
        {
            NoticeHost.Show("没能粘贴", "系统没有接受 Ctrl+V", NoticeTone.Error);
        }

        Log.Info($"paste.sent ok={sent} {(Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency:F0}ms");
        return sent;
    }

    public static bool WriteText(string text) => ClipboardWriter.WriteText(text);
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

    public static bool SendHotkey(VIRTUAL_KEY key, bool alt = false)
    {
        Span<INPUT> inputs = stackalloc INPUT[4];
        var index = 0;
        if (alt) inputs[index++] = KeyInput((VIRTUAL_KEY)0x12, 0);
        inputs[index++] = KeyInput(key, 0);
        inputs[index++] = KeyInput(key, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        if (alt) inputs[index++] = KeyInput((VIRTUAL_KEY)0x12, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return Send(inputs[..index]) == (uint)index;
    }

    public static double WaitModifiersReleased(int maxMs)
    {
        var started = Stopwatch.GetTimestamp();
        var deadline = started + (long)(Stopwatch.Frequency * maxMs / 1000.0);
        while (Stopwatch.GetTimestamp() < deadline)
        {
            if (!IsDown(0x11) && !IsDown(0x12) && !IsDown(0x10) && !IsDown(0x5B) && !IsDown(0x5C))
            {
                return (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
            }

            Thread.Sleep(5);
        }

        // 还按着就补发它们的抬起。补 Alt 之前先敲一下没分配的 VK 0xE8，
        // 免得目标窗口把单独一个 Alt 当成「激活菜单栏」。
        if (IsDown(0x12))
        {
            SendHotkey((VIRTUAL_KEY)0xE8, alt: false);
        }

        return (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
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

    private static uint Send(ReadOnlySpan<INPUT> inputs)
    {
        fixed (INPUT* p = inputs)
        {
            return PInvoke.SendInput((uint)inputs.Length, p, (int)sizeof(INPUT));
        }
    }
}
