// 托盘图标（Shell_NotifyIcon，NOTIFYICON_VERSION_4）。
// Windows 11 默认把新图标收进「^」溢出区；资源管理器重启时靠 TaskbarCreated 重新加。
// 菜单是系统的 Win32 弹出菜单（Shell/TrayMenu.cs，2026-10-27 R66；以前是 WinUI 的 MenuFlyout）。
// v4 下右键会先后收到 WM_RBUTTONUP 和 WM_CONTEXTMENU，只认后者；左键认 NIN_SELECT，键盘认 NIN_KEYSELECT。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class Tray
{
    private const uint TrayIconId = 1;
    public const uint CallbackMessage = 0x8000 + 1; // WM_APP + 1

    // NOTIFYICON_VERSION_4 的回调消息（WM_APP + 1 之外的那几种通知码）。
    private const uint NinSelect = 0x0400;     // 左键单击
    private const uint NinKeySelect = 0x0401;  // 键盘选中
    private const uint NinContextMenu = 0x0403; // 右键（键盘菜单键也是它）
    private const uint WmContextMenu = 0x007B;

    private static HICON _icon;
    private static bool _added;

    public static bool Add()
    {
        if (_added)
        {
            return true;
        }

        // 自检进程不登记：每个不同路径的 exe 都会在「其他系统托盘图标」里永久多一条（AutomatedRun 文件头）。
        if (AutomatedRun.IsActive)
        {
            Log.Info("tray.skipped automated-run");
            return true;
        }

        _icon = LoadTrayIcon();
        if (_icon == default)
        {
            Log.Error($"tray.icon-failed {Marshal.GetLastWin32Error()}");
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
        SetText(ref data.szTip, Paths.ProductName);

        if (!PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_ADD, in data))
        {
            Log.Error($"tray.add-failed {Marshal.GetLastWin32Error()}");
            return false;
        }

        var version = data;
        version.Anonymous.uVersion = 4; // NOTIFYICON_VERSION_4
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_SETVERSION, in version);
        _added = true;
        Log.Info("tray.added");

        var identifier = new NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)sizeof(NOTIFYICONIDENTIFIER),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
        };
        if (PInvoke.Shell_NotifyIconGetRect(identifier, out var rect).Succeeded)
        {
            Log.Info($"tray.rect {rect.left},{rect.top},{rect.right},{rect.bottom}");
        }

        return true;
    }

    /// <summary>
    /// 按当前 DPI 取托盘该用的那一档（图标里有手调过的 16 px 就用它），不再拿 32 px 的大图标硬缩（PLAN §5.2）。
    /// 用 SHDefExtractIcon 按像素尺寸取：应用清单没有引 comctl32 v6，LoadIconWithScaleDown 在这个进程里
    /// 找不到入口点（实测 EntryPointNotFoundException），所以不走它。
    /// </summary>
    private static HICON LoadTrayIcon()
    {
        var size = Math.Max(16, PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXSMICON));
        var path = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(path))
        {
            fixed (char* location = path)
            {
                HICON icon = default;
                if (PInvoke.SHDefExtractIcon(
                        new PCWSTR(location), 0, 0, &icon, null, (uint)(size | (size << 16))).Succeeded &&
                    icon != default)
                {
                    return icon;
                }
            }
        }

        // 取不到（极少数精简系统）：退回 exe 主图标。
        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        return PInvoke.LoadIcon(new HINSTANCE(module.Value), new PCWSTR((char*)32512));
    }

    /// <summary>
    /// 菜单收起后把焦点还给通知区域（NOTIFYICON_VERSION_4 的规矩：图标弹的界面做完了要 NIM_SETFOCUS）。
    /// REVIEW R67：不还的话，用过一次右键菜单以后再点图标常常没反应。
    /// </summary>
    public static void ReturnFocus()
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
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_SETFOCUS, in data);
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
            // 只认 WM_CONTEXTMENU：右键在 v4 下先来一个 WM_RBUTTONUP，两个都弹菜单会弹两次或重入。
            case WmContextMenu:
            case NinContextMenu:
            // 左键 / 键盘选中：v4 发 NIN_SELECT 和 NIN_KEYSELECT，不再发 WM_LBUTTONUP。
            case NinSelect:
            case NinKeySelect:
            {
                // v4 的 wParam 是这次弹菜单的位置（鼠标处；键盘选中时是图标处），屏幕物理坐标。照微软
                // NotificationIcon 示例在这一点弹；以前一律取鼠标位置，键盘选中时菜单跑到鼠标那儿去了。
                var x = (short)(wParam.Value & 0xFFFF);
                var y = (short)((wParam.Value >> 16) & 0xFFFF);
                TrayMenu.Show(x, y);
                break;
            }
        }
    }

    public static void ShowMenu() => TrayMenu.Show();

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
