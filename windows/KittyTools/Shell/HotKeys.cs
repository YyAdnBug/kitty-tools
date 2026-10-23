// 全局热键。第 0 批只注册三个验证用的键：Alt+C（剪贴板）、Alt+Space（启动器）、Alt+X（截图）。
// 注册失败 = 被别的程序占了；Windows 能查出来，先记日志，第 1 批再做设置页标红。
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal static class HotKeys
{
    public const int Clipboard = 1;
    public const int Launcher = 2;
    public const int Capture = 3;

    private static readonly (int Id, HOT_KEY_MODIFIERS Modifiers, uint VirtualKey, string Name)[] Bindings =
    {
        (Clipboard, HOT_KEY_MODIFIERS.MOD_ALT | HOT_KEY_MODIFIERS.MOD_NOREPEAT, (uint)'C', "Alt+C"),
        (Launcher, HOT_KEY_MODIFIERS.MOD_ALT | HOT_KEY_MODIFIERS.MOD_NOREPEAT, 0x20, "Alt+Space"),
        (Capture, HOT_KEY_MODIFIERS.MOD_ALT | HOT_KEY_MODIFIERS.MOD_NOREPEAT, (uint)'X', "Alt+X"),
    };

    public static void RegisterAll()
    {
        foreach (var binding in Bindings)
        {
            if (PInvoke.RegisterHotKey(HiddenWindow.Hwnd, binding.Id, binding.Modifiers, binding.VirtualKey))
            {
                ProbeLog.Write("hotkey.registered", ("name", binding.Name), ("id", binding.Id));
            }
            else
            {
                ProbeLog.Write("hotkey.failed", ("name", binding.Name), ("id", binding.Id), ("error", Marshal.GetLastWin32Error()));
            }
        }
    }

    public static void UnregisterAll()
    {
        foreach (var binding in Bindings)
        {
            PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, binding.Id);
        }
    }

    public static void OnHotKey(int id)
    {
        var ticks = System.Diagnostics.Stopwatch.GetTimestamp();
        ProbeLog.Write("hotkey.message", ("id", id));

        switch (id)
        {
            case Clipboard:
                OverlayHost.Toggle(OverlayKind.Clipboard, ticks);
                break;
            case Launcher:
                OverlayHost.Toggle(OverlayKind.Launcher, ticks);
                break;
            case Capture:
                CaptureHost.Toggle(ticks);
                break;
        }
    }
}
