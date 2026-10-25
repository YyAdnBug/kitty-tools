// 写剪贴板和发 Ctrl+V / Ctrl+C。PLAN §5.5：
// 收起面板 → 还前台 → 等它真的到前台 → 写剪贴板 → 等修饰键松开 → 发 Ctrl+V。
// 目标窗口是管理员时只写剪贴板、不粘贴，轻提示让用户手动粘。
// 修饰键还按着就补发抬起（Ctrl+Alt+C / Ctrl+Shift+V 那种事故），详见 Core 的 ModifierRelease。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
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
            // 没回到目标窗口就别发 Ctrl+V：那会粘进当时在前台的别的窗口（第二版 §2 第 3 条）。
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

        if (!reached)
        {
            NoticeHost.Show("已复制", "没能切回原窗口，请手动粘贴", NoticeTone.Warning);
            return false;
        }

        var sent = Keyboard.SendCtrlV();
        if (!sent)
        {
            NoticeHost.Show("没能粘贴", "系统没有接受 Ctrl+V", NoticeTone.Error);
        }

        Log.Info($"paste.sent ok={sent} {(Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency:F0}ms");
        return sent;
    }

    public static bool WriteText(string text) => ClipboardWriter.WriteText(text);

    /// <summary>片段里的 {cursor}：粘贴之后往左挪这么多下（第三版 §4）。</summary>
    public static void SendLeft(int count) => Keyboard.SendLeft(count);
}

internal static unsafe class Keyboard
{
    /// <summary>Ctrl / Alt / Shift / Win 都按着时的虚拟键码（等它们松开用）。</summary>
    private static readonly int[] ModifierVirtualKeys =
    {
        0x11, 0x12, 0x10, 0x5B, 0x5C,
    };

    /// <summary>等修饰键松开，最多 maxMs；还按着就按开头读到的状态补发它们的抬起。</summary>
    public static double WaitAndReleaseModifiers(int maxMs)
    {
        var started = Stopwatch.GetTimestamp();
        // 状态在函数开头读一次，作为参数传进纯函数 ModifierRelease.Plan。
        var control = IsDown(0x11);
        var alt = IsDown(0x12);
        var shift = IsDown(0x10);
        var leftWindows = IsDown(0x5B);
        var rightWindows = IsDown(0x5C);
        if (!control && !alt && !shift && !leftWindows && !rightWindows)
        {
            return 0;
        }

        var deadline = started + (long)(Stopwatch.Frequency * maxMs / 1000.0);
        while (Stopwatch.GetTimestamp() < deadline)
        {
            if (ModifierVirtualKeys.All(key => !IsDown(key)))
            {
                return (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
            }

            Thread.Sleep(5);
        }

        var plan = ModifierRelease.Plan(control, alt, shift, leftWindows, rightWindows);
        ReleaseModifiers(plan);
        return (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
    }

    /// <summary>按计划补发抬起：Alt 之前先敲一下没分配的 vkE8，免得目标窗口激活菜单栏。</summary>
    public static void ReleaseModifiers(IReadOnlyList<ModifierKey> plan)
    {
        Span<INPUT> inputs = stackalloc INPUT[1];
        foreach (var key in plan)
        {
            if (ModifierRelease.NeedsAltGuard(key))
            {
                TapUnassigned();
            }

            inputs[0] = KeyInput((VIRTUAL_KEY)ModifierRelease.VirtualKey(key), KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
            SendInputs(inputs);
        }

        if (plan.Count > 0)
        {
            Log.Info($"keys.modifiers-released {string.Join(',', plan)}");
        }
    }

    /// <summary>敲一下没分配的 vkE8（按下 + 抬起）。</summary>
    public static void TapUnassigned()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = KeyInput((VIRTUAL_KEY)ModifierRelease.TapVirtualKey, 0);
        inputs[1] = KeyInput((VIRTUAL_KEY)ModifierRelease.TapVirtualKey, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        SendInputs(inputs);
    }

    /// <summary>还前台失败时的兜底：先敲一下 vkE8 再 SetForegroundWindow（同 PLAN §5.4）。</summary>
    public static void TapAlt() => TapUnassigned();

    public static bool SendCtrlV() => SendCtrlCombo((VIRTUAL_KEY)0x56);

    /// <summary>片段里的 {cursor}：粘贴之后往左挪这么多下（第三版 §4）。</summary>
    public static void SendLeft(int count)
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x25, 0); // VK_LEFT
        inputs[1] = KeyInput((VIRTUAL_KEY)0x25, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        for (var index = 0; index < Math.Min(count, Core.SnippetRules.MaxCursorBackChars); index++)
        {
            SendInputs(inputs);
            Thread.Sleep(8);
        }
    }

    public static bool SendCtrlC() => SendCtrlCombo((VIRTUAL_KEY)0x43);

    private static bool SendCtrlCombo(VIRTUAL_KEY key)
    {
        // 先等修饰键松开（最多 300 ms）；还按着就补发抬起，免得变成 Ctrl+Alt+V / Ctrl+Shift+V。
        WaitAndReleaseModifiers(300);
        Span<INPUT> inputs = stackalloc INPUT[4];
        inputs[0] = KeyInput((VIRTUAL_KEY)0x11, 0);
        inputs[1] = KeyInput(key, 0);
        inputs[2] = KeyInput(key, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        inputs[3] = KeyInput((VIRTUAL_KEY)0x11, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return SendInputs(inputs) == 4;
    }

    public static bool SendHotkey(VIRTUAL_KEY key, bool alt = false)
    {
        Span<INPUT> inputs = stackalloc INPUT[4];
        var index = 0;
        if (alt) inputs[index++] = KeyInput((VIRTUAL_KEY)0x12, 0);
        inputs[index++] = KeyInput(key, 0);
        inputs[index++] = KeyInput(key, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        if (alt) inputs[index++] = KeyInput((VIRTUAL_KEY)0x12, KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP);
        return SendInputs(inputs[..index]) == (uint)index;
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

    private static uint SendInputs(ReadOnlySpan<INPUT> inputs)
    {
        fixed (INPUT* p = inputs)
        {
            return PInvoke.SendInput((uint)inputs.Length, p, (int)sizeof(INPUT));
        }
    }
}
