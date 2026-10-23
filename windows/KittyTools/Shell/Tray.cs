// 托盘图标和右键菜单（Shell_NotifyIcon，NOTIFYICON_VERSION_4）。
// 第 0 批只验证「图标加得上、菜单弹得出」；菜单项里还没做的模块灰着。
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe class Tray
{
    private const uint TrayIconId = 1;
    private const uint CallbackMessage = 0x8000 + 1; // WM_APP + 1
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCmd = 0x0100;

    private static HICON _icon;
    private static bool _added;

    public static bool Add()
    {
        if (_added)
        {
            return true;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        var instance = new HINSTANCE(module.Value);

        _icon = PInvoke.LoadIcon(instance, new PCWSTR((char*)32512)); // IDI_APPLICATION：exe 的主图标

        if (_icon == default)
        {
            ProbeLog.Write("tray.icon-failed", ("error", Marshal.GetLastWin32Error()));
        }

        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
            uFlags = NOTIFY_ICON_DATA_FLAGS.NIF_MESSAGE | NOTIFY_ICON_DATA_FLAGS.NIF_ICON | NOTIFY_ICON_DATA_FLAGS.NIF_TIP,
            uCallbackMessage = CallbackMessage,
            hIcon = _icon,
        };
        SetText(ref data.szTip, "Kitty Tools");

        if (!PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_ADD, in data))
        {
            ProbeLog.Write("tray.add-failed", ("error", Marshal.GetLastWin32Error()));
            return false;
        }

        var version = data;
        version.Anonymous.uVersion = 4; // NOTIFYICON_VERSION_4
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_SETVERSION, in version);
        _added = true;

        var identifier = new NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)sizeof(NOTIFYICONIDENTIFIER),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
        };
        var hasRect = PInvoke.Shell_NotifyIconGetRect(identifier, out var rect).Succeeded;
        ProbeLog.Write("tray.added", ("hasRect", hasRect), ("rect", $"{rect.left},{rect.top},{rect.right},{rect.bottom}"));
        return true;
    }

    public static void ReAdd()
    {
        _added = false;
        Add();
    }

    public static void Remove()
    {
        if (!_added)
        {
            return;
        }

        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
        };
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_DELETE, in data);
        _added = false;
    }

    public static void OnCallback(uint message, WPARAM wParam, LPARAM lParam)
    {
        // v4：lParam 低字是鼠标消息，wParam 是图标中心 / 鼠标位置。
        var mouseMessage = (uint)(lParam.Value & 0xFFFF);
        switch (mouseMessage)
        {
            case 0x0205: // WM_RBUTTONUP
            case 0x007B: // WM_CONTEXTMENU
            case 0x0202: // WM_LBUTTONUP
                ShowMenu();
                break;
        }
    }

    public static int MenuItemCount()
    {
        var menu = PInvoke.CreatePopupMenu();
        if (menu == default)
        {
            return 0;
        }

        try
        {
            Append(menu, 1, "剪贴板历史\tAlt+C");
            Append(menu, 2, "启动器\tAlt+Space");
            Append(menu, 3, "输入翻译\tAlt+T", enabled: false);
            Append(menu, 4, "截图\tAlt+X", enabled: false);
            Append(menu, 5, "截图翻译\tAlt+S", enabled: false);
            Append(menu, 6, "识字\tAlt+O", enabled: false);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 7, "复制即译", enabled: false);
            Append(menu, 8, "暂停记录剪贴板", enabled: false);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 9, "设置…", enabled: false);
            Append(menu, 10, "检查更新", enabled: false);
            Append(menu, 11, "退出 Kitty Tools");
            return PInvoke.GetMenuItemCount(menu);
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
    }

    public static void ShowMenu()
    {
        var menu = PInvoke.CreatePopupMenu();
        if (menu == default)
        {
            return;
        }

        try
        {
            Append(menu, 1, "剪贴板历史\tAlt+C");
            Append(menu, 2, "启动器\tAlt+Space");
            Append(menu, 3, "输入翻译\tAlt+T", enabled: false);
            Append(menu, 4, "截图\tAlt+X", enabled: false);
            Append(menu, 5, "截图翻译\tAlt+S", enabled: false);
            Append(menu, 6, "识字\tAlt+O", enabled: false);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 7, "复制即译", enabled: false);
            Append(menu, 8, "暂停记录剪贴板", enabled: false);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 9, "设置…", enabled: false);
            Append(menu, 10, "检查更新", enabled: false);
            Append(menu, 11, "退出 Kitty Tools");

            PInvoke.SetForegroundWindow(HiddenWindow.Hwnd);
            PInvoke.GetCursorPos(out var pt);

            ProbeLog.Write("tray.menu-open");
            var rawCommand = PInvoke.TrackPopupMenuEx(
                menu,
                TpmRightButton | TpmReturnCmd,
                pt.X,
                pt.Y,
                HiddenWindow.Hwnd,
                null);
            var command = (uint)rawCommand.Value;
            ProbeLog.Write("tray.menu-close", ("command", command));

            // 菜单关闭后给隐藏窗口发一条空消息，系统才会把菜单真正收掉。
            PInvoke.PostMessage(HiddenWindow.Hwnd, PInvoke.WM_NULL, default, default);

            switch (command)
            {
                case 1:
                    OverlayHost.ShowClipboard();
                    break;
                case 2:
                    OverlayHost.ShowLauncher();
                    break;
                case 11:
                    ProbeRuntime.Exit();
                    break;
            }
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
    }

    private static void Append(HMENU menu, uint id, string text, bool enabled = true)
    {
        var flags = MENU_ITEM_FLAGS.MF_STRING;
        if (!enabled)
        {
            flags |= MENU_ITEM_FLAGS.MF_GRAYED;
        }
        fixed (char* p = text)
        {
            PInvoke.AppendMenu(menu, flags, id, new PCWSTR(p));
        }
    }

    private static void SetText(ref Windows.Win32.__char_128 buffer, string text)
    {
        var length = Math.Min(text.Length, 127);
        for (var i = 0; i < length; i++)
        {
            buffer[i] = text[i];
        }
        buffer[length] = '\0';
    }
}
