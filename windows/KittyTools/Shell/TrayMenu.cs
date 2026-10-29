// 托盘菜单：系统的 Win32 弹出菜单（2026-10-27，用户：「托盘图标右键弹出的窗口怎么位置不对，没有使用官方的吗」）。
// 照微软 NotificationIcon 示例：NOTIFYICON_VERSION_4 回调的 wParam 给这次的位置（鼠标处；键盘选中时是图标处），
// SetForegroundWindow(托盘的隐藏窗口) → TrackPopupMenuEx（按 SM_MENUDROPALIGNMENT 左 / 右对齐）→ PostMessage(WM_NULL)。
// 位置、翻转、多屏、DPI、键盘、读屏、Windows 11 的圆角都由系统管；快捷键用「\t」右对齐。
// 分节和 mac 菜单栏菜单一样（剪贴板与启动器 / 翻译 / 截图与录制 / 通用），菜单项前面不带图标（系统菜单是纯文字）。
// 深色：Win32 菜单没有公开的深色接口，用 uxtheme 没写进文档的 SetPreferredAppMode（序号 135）+ FlushMenuThemes（136），
// 资源管理器、记事本的深色菜单也是这一套；拿不到就是浅色菜单，功能不受影响。
// 以前（PLAN-v2 D2）是 WinUI 的菜单弹在一块自己摆位置的透明窗口里，位置是自己按鼠标算的，会偏。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal static partial class TrayMenu
{
    private const uint MfString = 0x0000;
    private const uint MfGrayed = 0x0001;
    private const uint MfChecked = 0x0008;
    private const uint MfSeparator = 0x0800;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmRightAlign = 0x0008;
    private const uint TpmReturnCmd = 0x0100;
    private const int SmMenuDropAlignment = 40;

    private static IntPtr _menu;

    public static bool IsOpen => _menu != IntPtr.Zero;

    /// <summary>没有托盘回调给的位置时（别处调）：弹在鼠标处。</summary>
    public static void Show()
    {
        PInvoke.GetCursorPos(out var cursor);
        Show(cursor.X, cursor.Y);
    }

    /// <summary>在 (x, y)（屏幕物理坐标）弹菜单；TrackPopupMenuEx 一直等到菜单收起，选中的那一项收起之后再执行。</summary>
    public static void Show(int x, int y)
    {
        if (_menu != IntPtr.Zero)
        {
            return;
        }

        var items = new List<Item>();
        Build(items);
        _menu = CreatePopupMenu();
        if (_menu == IntPtr.Zero)
        {
            Log.Warn("tray.menu-create-failed");
            return;
        }

        Action? chosen = null;
        var capture = false;
        try
        {
            for (var index = 0; index < items.Count; index++)
            {
                var item = items[index];
                if (item.Text is null)
                {
                    AppendMenu(_menu, MfSeparator, 0, null);
                    continue;
                }

                var flags = MfString | (item.Enabled ? 0 : MfGrayed) | (item.Checked ? MfChecked : 0);
                // & 在菜单里是助记符，原样显示要写成 &&。
                var text = item.Text.Replace("&", "&&") +
                           (string.IsNullOrEmpty(item.Shortcut) ? string.Empty : "\t" + item.Shortcut);
                AppendMenu(_menu, flags, (nuint)(index + 1), text);
            }

            ApplyMenuTheme();
            var hwnd = (IntPtr)HiddenWindow.Hwnd;
            // 官方示例的两步：先把托盘的窗口设成前台（不然点菜单外面菜单不收），收起后发一个 WM_NULL。
            SetForegroundWindow(hwnd);
            var align = GetSystemMetrics(SmMenuDropAlignment) != 0 ? TpmRightAlign : 0;
            var command = TrackPopupMenuEx(_menu, TpmRightButton | TpmReturnCmd | align, x, y, hwnd, IntPtr.Zero);
            PostMessage(hwnd, 0, 0, 0);
            // REVIEW R67：收起后（选了、Esc、点外面都一样）把焦点还给通知区域，不然下一次点图标可能没反应。
            Tray.ReturnFocus();
            if (command > 0 && command <= items.Count)
            {
                chosen = items[command - 1].Run;
                capture = items[command - 1].Capture;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"tray.menu-open-failed {ex.GetType().Name}");
        }
        finally
        {
            DestroyMenu(_menu);
            _menu = IntPtr.Zero;
        }

        if (chosen is null)
        {
            return;
        }

        // 选中的那一项等菜单收起、从托盘的窗口过程（WM_CONTEXTMENU 回调）里出来以后再做；截图、识字、录屏这些
        // 还要等系统菜单选中项的淡出（约 0.25 s）做完，免得拍进冻结帧。
        Action run = chosen;
        var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var queued = queue?.TryEnqueue(async () =>
        {
            if (capture)
            {
                await Task.Delay(300);
            }

            run();
        }) == true;
        if (!queued)
        {
            run();
        }
    }

    public static void Close()
    {
        if (_menu != IntPtr.Zero)
        {
            EndMenu();
        }
    }

    /// <summary>Text 为 null 是分隔线；Capture = 要拍屏幕的（截图、识字、录屏），等菜单淡完再开始。</summary>
    private sealed record Item(
        string? Text, string? Shortcut, Action Run, bool Enabled = true, bool Checked = false, bool Capture = false);

    private static void Build(List<Item> menu)
    {
        var runtime = ShellRuntime.Instance;
        var settings = SettingsService.Current;
        var clipboardReady = runtime?.Clipboard is not null && Features.IsOn(Feature.Clipboard);

        // 第一节：剪贴板与启动器。
        if (Features.IsOn(Feature.Clipboard))
        {
            Add(menu, "剪贴板历史", HotKeyActions.Clipboard,
                () => runtime?.OpenClipboard(), clipboardReady);
        }

        if (Features.IsOn(Feature.Launcher))
        {
            Add(menu, "启动器", HotKeyActions.Launcher, () => OverlayHost.Toggle(OverlayKind.Launcher));
        }

        if (Features.IsOn(Feature.Clipboard))
        {
            menu.Add(new Item(
                "暂停记录剪贴板", null, () => runtime?.TogglePauseClipboard(), clipboardReady,
                runtime?.Clipboard?.Paused == true));
        }

        AddSeparator(menu);

        // 第二节：翻译。
        if (Features.IsOn(Feature.Translate))
        {
            Add(menu, "输入翻译", HotKeyActions.InputTranslate,
                () => TranslateHost.ToggleInput());
            menu.Add(new Item(
                "复制即译", null, () => runtime?.ToggleCopyTranslate(), runtime is not null, settings.CopyTranslate));
        }

        AddSeparator(menu);

        // 第三节：截图与录制。
        if (Features.IsOn(Feature.Screenshot))
        {
            Add(menu, "截图", HotKeyActions.Screenshot,
                () => ScreenshotSession.Start(ScreenshotMode.Capture), capture: true);
            if (Features.IsOn(Feature.Translate))
            {
                Add(menu, "截图翻译", HotKeyActions.ScreenshotTranslate,
                    () => ScreenshotSession.Start(ScreenshotMode.Translate), capture: true);
            }

            Add(menu, "识字", HotKeyActions.Ocr, () => ScreenshotSession.Start(ScreenshotMode.Ocr), capture: true);
            Add(menu, "截图历史", HotKeyActions.ShotHistory, ShotHistoryWindow.ShowWindow);
        }

        if (Features.IsOn(Feature.Recording))
        {
            if (RecordingHost.IsRecording)
            {
                Add(menu, "停止录屏 " + RecordingHost.Elapsed, HotKeyActions.Record,
                    RecordingHost.Stop);
            }
            else
            {
                Add(menu, "录屏", HotKeyActions.Record, RecordingHost.Toggle, capture: true);
            }

            if (RecordingHost.LastPath is { } last && File.Exists(last) &&
                last.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase))
            {
                Add(menu,
                    CompressionService.IsRunning
                        ? $"压缩中 {(int)(CompressionService.Progress * 100)}%"
                        : "压缩最近的录屏（不超过 60%）",
                    string.Empty, () => _ = CompressionService.CompressLastAsync());
                Add(menu, "转成 GIF（10 fps，长边 800）", string.Empty,
                    () => _ = GifService.ConvertLastAsync());
            }

            // 录音（PLAN-v9 F2）：同录屏，右边写它的快捷键；待录时不算在录，仍叫「录音」，点它是开始（同 mac）。
            if (AudioHost.IsRecording)
            {
                Add(menu, "停止录音 " + AudioHost.Elapsed, HotKeyActions.Audio, AudioHost.Stop);
            }
            else
            {
                Add(menu, "录音", HotKeyActions.Audio, AudioHost.Toggle);
            }
        }

        AddSeparator(menu);
        menu.Add(new Item("设置…", null, () => runtime?.ShowSettings(welcome: false)));
        var updateText = AutoUpdater.ProgressMenuText
                         ?? (UpdateService.AvailableVersion is { } available
                             ? $"更新到 {available}"
                             : "检查更新");
        menu.Add(new Item(
            updateText,
            null,
            () =>
            {
                if (UpdateService.AvailableVersion is not null)
                {
                    _ = AutoUpdater.StartAsync();
                }
                else
                {
                    _ = UpdateService.CheckAsync(userInitiated: true);
                }
            },
            !AutoUpdater.IsBusy));
        menu.Add(new Item("退出 Kitty Tools", null, () => runtime?.Exit()));
    }

    private static void Add(
        List<Item> menu, string text, string action, Action run, bool enabled = true, bool capture = false)
        => menu.Add(new Item(text, ShellRuntime.Instance?.HotKeys.ShortcutFor(action), run, enabled, Capture: capture));

    /// <summary>某一节整个没有（功能关了）时不留连着的两条分隔线，也不在最前面放一条。</summary>
    private static void AddSeparator(List<Item> menu)
    {
        if (menu.Count > 0 && menu[^1].Text is not null)
        {
            menu.Add(new Item(null, null, static () => { }));
        }
    }

    /// <summary>
    /// 让 Win32 菜单跟着深浅色走。ponytail: 用的是 uxtheme 没写进文档的两个序号（135 SetPreferredAppMode、
    /// 136 FlushMenuThemes，Windows 10 1903 起有）；哪天系统改了拿不到，就是浅色菜单。微软出了公开接口就换过去。
    /// </summary>
    private static unsafe void ApplyMenuTheme()
    {
        try
        {
            var uxtheme = LoadLibrary("uxtheme.dll");
            if (uxtheme == IntPtr.Zero)
            {
                return;
            }

            var setMode = GetProcAddress(uxtheme, 135);
            var flush = GetProcAddress(uxtheme, 136);
            if (setMode == IntPtr.Zero || flush == IntPtr.Zero)
            {
                return;
            }

            // PreferredAppMode：1 跟随系统，2 一直深色，3 一直浅色（设置 › 外观选了和系统不一样的时候）。
            var mode = SettingsService.Current.Theme switch
            {
                "dark" => 2,
                "light" => 3,
                _ => 1,
            };
            ((delegate* unmanaged[Stdcall]<int, int>)setMode)(mode);
            ((delegate* unmanaged[Stdcall]<void>)flush)();
        }
        catch (Exception ex)
        {
            Log.Warn($"tray.menu-theme-failed {ex.GetType().Name}");
        }
    }

    [LibraryImport("user32.dll", EntryPoint = "CreatePopupMenu")]
    private static partial IntPtr CreatePopupMenu();

    [LibraryImport("user32.dll", EntryPoint = "AppendMenuW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AppendMenu(IntPtr menu, uint flags, nuint id, string? text);

    /// <summary>带 TPM_RETURNCMD 时返回选中项的 id，没选返回 0。</summary>
    [LibraryImport("user32.dll", EntryPoint = "TrackPopupMenuEx")]
    private static partial int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);

    [LibraryImport("user32.dll", EntryPoint = "DestroyMenu")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyMenu(IntPtr menu);

    [LibraryImport("user32.dll", EntryPoint = "EndMenu")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool EndMenu();

    [LibraryImport("user32.dll", EntryPoint = "SetForegroundWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hwnd);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessage(IntPtr hwnd, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "GetSystemMetrics")]
    private static partial int GetSystemMetrics(int index);

    [LibraryImport("kernel32.dll", EntryPoint = "LoadLibraryW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr LoadLibrary(string name);

    [LibraryImport("kernel32.dll", EntryPoint = "GetProcAddress")]
    private static partial IntPtr GetProcAddress(IntPtr module, nint ordinal);
}
