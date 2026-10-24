// 托盘图标和右键菜单（Shell_NotifyIcon，NOTIFYICON_VERSION_4）。
// Windows 11 默认把新图标收进「^」溢出区；资源管理器重启时靠 TaskbarCreated 重新加。
// 菜单是 Win32 浅色菜单（没有公开的深色接口），没做的模块灰着，但右边仍写快捷键。
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
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCmd = 0x0100;

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
                ShowMenu();
                break;
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
            var runtime = ShellRuntime.Instance;
            var settings = SettingsService.Current;
            var clipboardReady = runtime?.Clipboard is not null;

            Append(menu, 1, MenuText("剪贴板历史", HotKeyActions.Clipboard), enabled: clipboardReady);
            Append(menu, 2, MenuText("启动器", HotKeyActions.Launcher), enabled: true);
            Append(menu, 3, MenuText("输入翻译", HotKeyActions.InputTranslate), enabled: true);
            Append(menu, 4, MenuText("截图", HotKeyActions.Screenshot), enabled: true);
            Append(menu, 5, MenuText("截图翻译", HotKeyActions.ScreenshotTranslate), enabled: true);
            Append(menu, 6, MenuText("识字", HotKeyActions.Ocr), enabled: true);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 7, "复制即译", enabled: runtime is not null, @checked: settings.CopyTranslate);
            Append(menu, 8, "暂停记录剪贴板", enabled: clipboardReady, @checked: runtime?.Clipboard?.Paused == true);
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
            Append(menu, 9, "设置…", enabled: true);
            Append(
                menu,
                10,
                UpdateService.AvailableVersion is { } available
                    ? $"更新到 {available}"
                    : "检查更新",
                enabled: true);
            Append(menu, 11, "退出 Kitty Tools", enabled: true);

            PInvoke.SetForegroundWindow(HiddenWindow.Hwnd);
            PInvoke.GetCursorPos(out var point);
            Log.Info("tray.menu-open");
            var raw = PInvoke.TrackPopupMenuEx(
                menu,
                TpmRightButton | TpmReturnCmd,
                point.X,
                point.Y,
                HiddenWindow.Hwnd,
                null);
            PInvoke.PostMessage(HiddenWindow.Hwnd, PInvoke.WM_NULL, default, default);
            Log.Info($"tray.menu-close command={(uint)raw.Value}");

            switch ((uint)raw.Value)
            {
                case 1:
                    runtime?.OpenClipboard();
                    break;
                case 2:
                    OverlayHost.Toggle(OverlayKind.Launcher);
                    break;
                case 3:
                    TranslateHost.ToggleInput();
                    break;
                case 4:
                    ScreenshotSession.Start(ScreenshotMode.Capture);
                    break;
                case 5:
                    ScreenshotSession.Start(ScreenshotMode.Translate);
                    break;
                case 6:
                    ScreenshotSession.Start(ScreenshotMode.Ocr);
                    break;
                case 7:
                    runtime?.ToggleCopyTranslate();
                    break;
                case 8:
                    runtime?.TogglePauseClipboard();
                    break;
                case 9:
                    runtime?.ShowSettings(welcome: false);
                    break;
                case 10:
                    if (UpdateService.AvailableVersion is not null)
                    {
                        _ = AutoUpdater.StartAsync();
                    }
                    else
                    {
                        _ = UpdateService.CheckAsync(userInitiated: true);
                    }

                    break;
                case 11:
                    runtime?.Exit();
                    break;
            }
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
    }

    private static string MenuText(string text, string action)
    {
        var shortcut = ShellRuntime.Instance?.HotKeys.ShortcutFor(action);
        return string.IsNullOrEmpty(shortcut) ? text : $"{text}\t{shortcut}";
    }

    private static void Append(HMENU menu, uint id, string text, bool enabled = true, bool @checked = false)
    {
        var flags = MENU_ITEM_FLAGS.MF_STRING;
        if (!enabled)
        {
            flags |= MENU_ITEM_FLAGS.MF_GRAYED;
        }
        if (@checked)
        {
            flags |= MENU_ITEM_FLAGS.MF_CHECKED;
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
