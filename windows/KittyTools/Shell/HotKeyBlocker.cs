// 按应用停用快捷键（PLAN-v17 H2 H6 W1 W2，mac HotKeyCenter.frontChanged）：挂前台切换的系统事件（进程外回调、不轮询），
// 前台一变取它的 exe 名，按 设置 › 快捷键「在这些应用里停用」算规则交给 HotKeyManager.Apply（和上次一样就什么都不做）。
// 前台是 Kitty 自己的窗口时沿用上一个外部前台的规则（PLAN-v18 L10 ①：Windows 的面板会抢前台，不沿用的话在名单里的应用上
// 打开 Kitty 面板，快捷键又回来了）。名单一改（设置页、托盘那一项、导入）当场按此刻的前台重算（L10 ②，mac blocksChanged）。
// 全屏游戏（开关默认开）：前台一变查一次 SHQueryUserNotificationState，是 D3D 独占全屏 / 演示模式就全部停；热键按下时再查一次（HotKeyManager.OnHotKey）。
// 顺手记「最后一个不是我们、也不是任务栏 / 桌面的前台」：点托盘时前台已经是任务栏，托盘那一项用它。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static partial class HotKeyBlocker
{
    /// <summary>不算「应用」的系统窗口（任务栏、通知区溢出、桌面）：托盘那一项不认它们。</summary>
    private static readonly HashSet<string> ShellClasses = new(StringComparer.Ordinal)
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
        "Progman", "WorkerW", "XamlExplorerHostIslandWindow", "Windows.UI.Core.CoreWindow",
    };

    private static IntPtr _hook;
    /// <summary>算规则用的外部前台的 exe 名（前台是我们自己时沿用它）。</summary>
    private static string? _frontExe;
    /// <summary>最后一个外部应用（不是我们、任务栏、桌面）：exe 完整路径和窗口。</summary>
    private static (string Path, IntPtr Hwnd)? _lastApp;

    private static IReadOnlyList<string> Known => SettingsDefaults.DefaultHotKeys.Select(definition => definition.Action).ToList();

    public static unsafe void Start()
    {
        if (_hook != IntPtr.Zero)
        {
            return;
        }

        _hook = SetWinEventHook(3 /* EVENT_SYSTEM_FOREGROUND */, 3, IntPtr.Zero, &OnForeground, 0, 0, 0 /* WINEVENT_OUTOFCONTEXT */);
        Changed(PInvoke.GetForegroundWindow());
    }

    public static void Stop()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }
    }

    /// <summary>名单或全屏开关改了：按此刻的前台（是我们自己就按上一个外部前台）重算。</summary>
    public static void Refresh() => ShellRuntime.Instance?.HotKeys.Apply(RuleNow());

    /// <summary>此刻前台是不是全屏游戏 / 演示（开关关着时永远不是）。</summary>
    public static bool FullscreenGameNow()
        => SettingsService.Current.HotKeyBlockFullscreen &&
           SHQueryUserNotificationState(out var state) == 0 && HotKeyBlock.IsFullscreenGame(state);

    /// <summary>托盘那一项要用的应用：最后一个外部应用，还开着、不是资源管理器；没有就 null。</summary>
    public static (string Exe, string Name, bool Blocked)? MenuApp()
    {
        if (_lastApp is not { } app || !IsWindow(app.Hwnd))
        {
            return null;
        }

        var exe = Path.GetFileName(app.Path);
        if (string.Equals(exe, "explorer.exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var blocked = HotKeyBlock.List(SettingsService.Current.HotKeyBlockedApps)
            .Any(block => string.Equals(block.Exe, exe, StringComparison.OrdinalIgnoreCase));
        return (exe, ClipboardFormats.DisplayName(app.Path), blocked);
    }

    /// <summary>托盘那一项：没在名单里就加一条「全部快捷键」，在就把那一条整个删掉；当场重算。</summary>
    public static void Toggle(string exe)
    {
        var settings = SettingsService.Current;
        var list = HotKeyBlock.List(settings.HotKeyBlockedApps);
        var removed = list.RemoveAll(block => string.Equals(block.Exe, exe, StringComparison.OrdinalIgnoreCase)) > 0;
        if (!removed)
        {
            list.Add(new HotKeyBlock(exe));
        }

        settings.HotKeyBlockedApps = list.Select(block => block.Entry).ToList();
        SettingsService.Save();
        Refresh();
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnForeground(IntPtr hook, uint e, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        try
        {
            Changed(new HWND(hwnd));
        }
        catch (Exception ex)
        {
            Log.Warn($"hotkey.block-front-failed {ex.GetType().Name}");
        }
    }

    private static unsafe void Changed(HWND hwnd)
    {
        if (hwnd == default)
        {
            return;
        }

        if (!Foreground.IsOurs(hwnd))
        {
            PInvoke.GetWindowThreadProcessId(hwnd, out var pid);
            var path = ClipboardFormats.ProcessImage(pid);
            _frontExe = path is null ? null : Path.GetFileName(path);
            if (path is not null && !ShellClasses.Contains(ClassName(hwnd)))
            {
                _lastApp = (path, (IntPtr)hwnd.Value);
            }
        }

        ShellRuntime.Instance?.HotKeys.Apply(RuleNow());
    }

    private static HotKeyBlockRule? RuleNow()
    {
        if (FullscreenGameNow())
        {
            return HotKeyBlockRule.All;
        }

        return HotKeyBlock.RuleFor(_frontExe, SettingsService.Current.HotKeyBlockedApps, Known);
    }

    private static unsafe string ClassName(HWND hwnd)
    {
        var buffer = stackalloc char[64];
        var length = GetClassName((IntPtr)hwnd.Value, buffer, 64);
        return new string(buffer, 0, Math.Max(length, 0));
    }

#if DEBUG
    /// <summary>
    /// --hotkey-block-probe：四个动作换成 Ctrl+Alt+Shift+F13…F15 和连按两下 Ctrl（免得和装着的正式版抢键），名单放两条，
    /// 假装前台依次换成名单里 / 名单外的 exe、我们自己、截图停着期间，看注册着的动作对不对、Apply 用了多久。设置用完换回去。
    /// </summary>
    internal static (bool Ok, string Text) RunProbe()
    {
        var settings = SettingsService.Current;
        var savedBlocks = settings.HotKeyBlockedApps;
        var savedFullscreen = settings.HotKeyBlockFullscreen;
        var savedKeys = settings.HotKeys.Select(hotkey => (hotkey.Action, SettingsDefaults.BindingFor(settings, hotkey.Action))).ToList();
        var text = new System.Text.StringBuilder();
        var ok = true;
        var manager = ShellRuntime.Instance!.HotKeys;
        var probed = new[] { HotKeyActions.Clipboard, HotKeyActions.Launcher, HotKeyActions.Screenshot, HotKeyActions.Ocr };
        void Check(string step, params string[] expected)
        {
            var registered = probed.Where(manager.IsRegistered).ToArray();
            var right = registered.SequenceEqual(expected);
            ok &= right;
            text.Append(right ? "ok " : "不对 ").Append(step).Append("：注册着 ").Append(string.Join(",", registered))
                .Append($"（{manager.LastApplyMilliseconds:F3} ms）").Append('\n');
        }

        try
        {
            settings.HotKeyBlockFullscreen = false;
            settings.HotKeyBlockedApps = new List<string> { "probe-all.exe", "probe-some.exe|clipboard,screenshot" };
            SettingsDefaults.SetBinding(settings, HotKeyActions.Clipboard, new HotKeyBinding(0x7C, HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift));
            SettingsDefaults.SetBinding(settings, HotKeyActions.Launcher, new HotKeyBinding(0x11, HotKeyModifiers.None));
            SettingsDefaults.SetBinding(settings, HotKeyActions.Screenshot, new HotKeyBinding(0x7D, HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift));
            SettingsDefaults.SetBinding(settings, HotKeyActions.Ocr, new HotKeyBinding(0x7E, HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift));
            _frontExe = "other.exe";
            manager.Apply(null);
            manager.RegisterAll(settings);
            Check("名单外", probed);
            text.Append($"连按两下 Ctrl 的监听：{(manager.IsRegistered(HotKeyActions.Launcher) ? "开着" : "没开")}\n");
            _frontExe = "probe-all.exe";
            Refresh();
            Check("全部停用");
            _frontExe = "PROBE-SOME.EXE";
            Refresh();
            Check("只停剪贴板和截图", HotKeyActions.Launcher, HotKeyActions.Ocr);
            // 前台换成我们自己：沿用上一个外部前台的规则（L10 ①）
            Changed(HiddenWindow.Hwnd);
            Check("前台是我们自己", HotKeyActions.Launcher, HotKeyActions.Ocr);
            // 截图停着期间前台变了：只记规则，注册回来时按那时的前台（H4）
            manager.UnregisterAll();
            _frontExe = "probe-all.exe";
            Refresh();
            manager.RegisterAll(settings);
            Check("停着期间进了名单里的应用、注册回来");
            _frontExe = "other.exe";
            Refresh();
            Check("回到名单外", probed);
            // 名单一改当场重算（L10 ②）
            _frontExe = "probe-some.exe";
            Refresh();
            settings.HotKeyBlockedApps = new List<string>();
            Refresh();
            Check("名单删空", probed);
            // 量 20 轮切换的耗时
            var times = new List<double>();
            settings.HotKeyBlockedApps = new List<string> { "probe-all.exe" };
            for (var round = 0; round < 20; round++)
            {
                _frontExe = round % 2 == 0 ? "probe-all.exe" : "other.exe";
                Refresh();
                times.Add(manager.LastApplyMilliseconds);
            }

            text.Append($"20 次切换：注册 / 注销中位 {times.Order().ElementAt(10):F3} ms、最长 {times.Max():F3} ms\n");
        }
        finally
        {
            settings.HotKeyBlockedApps = savedBlocks;
            settings.HotKeyBlockFullscreen = savedFullscreen;
            foreach (var (action, binding) in savedKeys)
            {
                SettingsDefaults.SetBinding(settings, action, binding);
            }

            manager.UnregisterAll();
        }

        return (ok, text.Append(ok ? "全对" : "有不对的").ToString());
    }
#endif

    [LibraryImport("user32.dll")]
    private static unsafe partial IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr module, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int, int, uint, uint, void> callback,
        uint process, uint thread, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnhookWinEvent(IntPtr hook);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsWindow(IntPtr hwnd);

    [LibraryImport("user32.dll", EntryPoint = "GetClassNameW")]
    private static unsafe partial int GetClassName(IntPtr hwnd, char* name, int max);

    [LibraryImport("shell32.dll")]
    private static partial int SHQueryUserNotificationState(out int state);
}
