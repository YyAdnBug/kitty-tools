// 前台窗口的记住 / 归还，以及目标进程是否以管理员身份运行。
// 第 0 批按 PLAN §5.5：SetForegroundWindow 失败时先补一次 Alt 按下抬起再试，
// 最多等 100 ms；管理员窗口只写剪贴板、不粘贴。
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security;
using Windows.Win32.System.Threading;

namespace KittyTools;

internal static class Foreground
{
    public static HWND Get() => PInvoke.GetForegroundWindow();

    public static bool IsOurs(HWND hwnd)
    {
        if (hwnd == default)
        {
            return false;
        }

        PInvoke.GetWindowThreadProcessId(hwnd, out var pid);
        return pid == (uint)Environment.ProcessId;
    }

    public static bool Restore(HWND target)
    {
        if (target == default || !PInvoke.IsWindow(target) || !PInvoke.IsWindowVisible(target))
        {
            ProbeLog.Write("foreground.restore-skip");
            return false;
        }

        var t0 = Stopwatch.GetTimestamp();
        var ok = PInvoke.SetForegroundWindow(target);
        if (!ok)
        {
            // 老办法：先补一次 Alt 按下抬起，让系统认为我们刚有过用户输入。
            Keyboard.TapAlt();
            ok = PInvoke.SetForegroundWindow(target);
        }

        var deadline = t0 + (long)(Stopwatch.Frequency * 0.100);
        while (Stopwatch.GetTimestamp() < deadline)
        {
            if (PInvoke.GetForegroundWindow() == target)
            {
                ProbeLog.Write("foreground.restored", ("ms", Ms(t0, Stopwatch.GetTimestamp())), ("alt_tap", !ok));
                return true;
            }
            Thread.Sleep(2);
        }

        var reached = PInvoke.GetForegroundWindow() == target;
        ProbeLog.Write("foreground.restore-timeout", ("ms", Ms(t0, Stopwatch.GetTimestamp())), ("reached", reached));
        return reached;
    }

    public static unsafe bool IsProcessElevated(uint pid)
    {
        var process = PInvoke.OpenProcess(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == default)
        {
            ProbeLog.Write("elev.open-failed", ("pid", pid), ("error", Marshal.GetLastWin32Error()));
            return false;
        }

        HANDLE token = default;
        try
        {
            if (!PInvoke.OpenProcessToken(process, TOKEN_ACCESS_MASK.TOKEN_QUERY, &token))
            {
                ProbeLog.Write("elev.token-open-failed", ("pid", pid), ("error", Marshal.GetLastWin32Error()));
                return false;
            }

            var elevation = default(TOKEN_ELEVATION);
            var size = (uint)sizeof(TOKEN_ELEVATION);
            if (!PInvoke.GetTokenInformation(
                    token,
                    TOKEN_INFORMATION_CLASS.TokenElevation,
                    &elevation,
                    size,
                    &size))
            {
                ProbeLog.Write("elev.token-failed", ("pid", pid), ("error", Marshal.GetLastWin32Error()));
                return false;
            }

            return elevation.TokenIsElevated != 0;
        }
        finally
        {
            if (token != default)
            {
                PInvoke.CloseHandle(token);
            }
            PInvoke.CloseHandle(process);
        }
    }

    public static uint PidOf(HWND hwnd)
    {
        PInvoke.GetWindowThreadProcessId(hwnd, out var pid);
        return pid;
    }

    private static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}
