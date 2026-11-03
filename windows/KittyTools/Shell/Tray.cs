// 托盘图标（Shell_NotifyIcon，NOTIFYICON_VERSION_4；悬停提示是系统画的标准提示，靠 NIF_SHOWTIP）。
// Windows 11 默认把新图标收进「^」溢出区；资源管理器重启时靠 TaskbarCreated 重新加。
// 菜单是系统的 Win32 弹出菜单（Shell/TrayMenu.cs，2026-10-27 R66；以前是 WinUI 的 MenuFlyout）。
// v4 下右键会先后收到 WM_RBUTTONUP 和 WM_CONTEXTMENU，只认后者；左键认 NIN_SELECT，键盘认 NIN_KEYSELECT。
// PLAN-v10 §5：左键 / 在图标上按 Enter、空格 → 主界面（HomePanel，贴着任务栏弹出）；右键、菜单键 → 照旧弹菜单（主界面开着就先收起）。
// 图标跟着状态换（Refresh，PLAN-v11 F9，mac X13）：录屏 / 录音中右下角红点（PLAN-v4 V8，图早就生成了、以前没接上），
// 暂停记录剪贴板时灰色暂停角标（暂停只在这次运行里有效，容易忘了自己暂停过），平时是应用图标；悬停提示跟着写。
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

    private enum TrayState
    {
        Normal,
        Recording,
        Paused,
    }

    private static TrayState _state;

    /// <summary>录屏 / 录音中 → 红点；暂停记录剪贴板（剪贴板功能开着时）→ 暂停角标；都不是 → 应用图标。录制优先。</summary>
    private static TrayState CurrentState()
        => RecordingHost.IsRecording || AudioHost.IsRecording
            ? TrayState.Recording
            : ShellRuntime.Instance?.Clipboard?.Paused == true && Features.IsOn(Feature.Clipboard)
                ? TrayState.Paused
                : TrayState.Normal;

    private static string TipFor(TrayState state) => state switch
    {
        TrayState.Recording => Paths.ProductName + " · 正在录制",
        TrayState.Paused => Paths.ProductName + " · 已暂停记录剪贴板",
        _ => Paths.ProductName,
    };

    /// <summary>
    /// 状态变了就换图标和悬停提示（录制开始 / 停止、暂停 / 恢复记录、关掉剪贴板功能时调；没变什么都不做）。
    /// </summary>
    public static void Refresh()
    {
        var state = CurrentState();
        if (!_added || state == _state)
        {
            return;
        }

        var icon = LoadTrayIcon(state);
        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
            uFlags = NOTIFY_ICON_DATA_FLAGS.NIF_ICON | NOTIFY_ICON_DATA_FLAGS.NIF_TIP | NOTIFY_ICON_DATA_FLAGS.NIF_SHOWTIP,
            hIcon = icon,
        };
        SetText(ref data.szTip, TipFor(state));
        if (!PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_MODIFY, in data))
        {
            Log.Warn($"tray.modify-failed {Marshal.GetLastWin32Error()}");
            if (icon != default)
            {
                PInvoke.DestroyIcon(icon);
            }

            return;
        }

        if (_icon != default)
        {
            PInvoke.DestroyIcon(_icon);
        }

        _icon = icon;
        _state = state;
        Log.Info($"tray.state {state}");
    }

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

        _state = CurrentState();
        _icon = LoadTrayIcon(_state);
        if (_icon == default)
        {
            Log.Error($"tray.icon-failed {Marshal.GetLastWin32Error()}");
        }

        // NIF_SHOWTIP：v4 下系统默认不画标准提示（留给程序自己画弹窗），悬停只剩一个空框；带上它才显示 szTip 里的名字。
        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
            uFlags = NOTIFY_ICON_DATA_FLAGS.NIF_MESSAGE | NOTIFY_ICON_DATA_FLAGS.NIF_ICON | NOTIFY_ICON_DATA_FLAGS.NIF_TIP |
                     NOTIFY_ICON_DATA_FLAGS.NIF_SHOWTIP,
            uCallbackMessage = CallbackMessage,
            hIcon = _icon,
        };
        SetText(ref data.szTip, TipFor(_state));

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
    private static HICON LoadTrayIcon(TrayState state)
    {
        var size = Math.Max(16, PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXSMICON));
        // 两种状态图标是和 exe 放在一起的 .ico（csproj 的 Content）；读不到就照旧用应用图标。
        var path = state switch
        {
            TrayState.Recording => Path.Combine(AppContext.BaseDirectory, "Resources", "AppIconRecording.ico"),
            TrayState.Paused => Path.Combine(AppContext.BaseDirectory, "Resources", "AppIconPaused.ico"),
            _ => Environment.ProcessPath,
        };
        if (state != TrayState.Normal && !File.Exists(path))
        {
            path = Environment.ProcessPath;
        }

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
            {
                // v4 的 wParam 是这次弹菜单的位置（鼠标处；键盘选中时是图标处），屏幕物理坐标。照微软
                // NotificationIcon 示例在这一点弹；以前一律取鼠标位置，键盘选中时菜单跑到鼠标那儿去了。
                var x = (short)(wParam.Value & 0xFFFF);
                var y = (short)((wParam.Value >> 16) & 0xFFFF);
                HomePanel.Hide(restoreForeground: false);
                TrayMenu.Show(x, y);
                break;
            }

            // 左键 / 键盘选中：v4 发 NIN_SELECT 和 NIN_KEYSELECT，不再发 WM_LBUTTONUP。
            case NinSelect:
            case NinKeySelect:
            {
                var x = (short)(wParam.Value & 0xFFFF);
                var y = (short)((wParam.Value >> 16) & 0xFFFF);
                HomePanel.ShowFromTray(x, y, keyboard: mouseMessage == NinKeySelect);
                break;
            }
        }
    }

    public static void ShowMenu() => TrayMenu.Show();

    /// <summary>托盘图标在屏幕上的矩形（物理像素）；图标收在「^」溢出区里、溢出区没展开时系统给的是溢出区按钮那一块，拿不到返回 false。</summary>
    public static bool TryGetIconRect(out int left, out int top, out int right, out int bottom)
    {
        left = top = right = bottom = 0;
        if (!_added)
        {
            return false;
        }

        var identifier = new NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)sizeof(NOTIFYICONIDENTIFIER),
            hWnd = HiddenWindow.Hwnd,
            uID = TrayIconId,
        };
        if (PInvoke.Shell_NotifyIconGetRect(identifier, out var rect).Failed || rect.right <= rect.left)
        {
            return false;
        }

        (left, top, right, bottom) = (rect.left, rect.top, rect.right, rect.bottom);
        return true;
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
