// 设置窗交互的自检（PLAN-v23，只在测试档）：`--settings-probe=<目录>`，KITTY_SETTINGS_PROBE_ROLE 定这一份做什么。不发按键、不点鼠标，
// 走和用户操作同一条路（SettingsWindow.Probe.cs 的几个口子）：
// - a：换页记进 settings.json；挪窗口、拉大小、关窗后记下位置，再打开不挪回正中；最小尺寸；搜索停在哪页（W4–W6）；从别处跳页清掉搜索词（W7）；
//   跳到收起的组里的页那组展开并记住（W8）；子页回上一层（W3）；开着对话框时不换页（W9）。最后停在录制页、关窗。
// - b：同一个测试档再起一次，打开设置窗：停在 a 最后的那页、窗口在 a 记下的位置和大小（W1 W2）。
// - h：快捷键录制（第 2 批 H1–H9）：用 UIA 的 Invoke 点录制框和 ⓧ，「按下的键」走 RecordKey（算好修饰键之后那条路），不发真的按键；
//   录着时全局热键全停、结束注册回来；撞键的三种话；ⓧ 录着时取消；录完焦点回到录制框；Delete 清除；占位字；窗口失活就停。
// - l：列表和跟着开关变的行（第 3 批 L1 L3–L5）：状态、翻译服务的列表按 Alt + ↑ / Delete / Enter（走 ListViewItem 收到键以后那条路），
//   挪完焦点还在列表里；快门声关着时「试听」灰；截图历史关着时两行不显示；便签边缘两对互斥的开关。
// 每份把结果写进 <目录>\report-<角色>.md，跑完就退（有不对的退出码 1）。
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal static class SettingsProbe
{
    public const string ArgumentPrefix = "--settings-probe";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-settings-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var role = Environment.GetEnvironmentVariable("KITTY_SETTINGS_PROBE_ROLE") is { Length: > 0 } value ? value : "a";
        var report = new StringBuilder($"# 设置窗交互（PLAN-v23，角色 {role}）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        await Task.Delay(1500);
        try
        {
            if (ShellRuntime.Instance is not { } shell)
            {
                Check(false, "ShellRuntime 没起来");
            }
            else if (role == "b")
            {
                await RunSecondAsync(shell, Check);
            }
            else if (role == "h")
            {
                await RunHotKeysAsync(shell, Check);
            }
            else if (role == "l")
            {
                await RunListsAsync(shell, Check);
            }
            else
            {
                await RunFirstAsync(shell, Check, report);
            }
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name}: {ex.Message}");
        }

        report.Append(failures == 0 ? "\n全部通过。\n" : $"\n{failures} 项不对。\n");
        await File.WriteAllTextAsync(Path.Combine(directory, $"report-{role}.md"), report.ToString());
        Log.Info($"settings-probe done role={role} failures={failures}");
        Environment.Exit(failures == 0 ? 0 : 1);
    }

    private static async Task<SettingsWindow> ShowAsync(ShellRuntime shell, string? page)
    {
        shell.ShowSettings(welcome: false, page);
        await Task.Delay(400);
        return shell.SettingsWindowForProbe ?? throw new InvalidOperationException("设置窗没建出来");
    }

    private static string SavedText() => File.Exists(Paths.SettingsFile) ? File.ReadAllText(Paths.SettingsFile) : string.Empty;

    private static async Task RunFirstAsync(ShellRuntime shell, Action<bool, string> check, StringBuilder report)
    {
        var settings = SettingsService.Current;
        var window = await ShowAsync(shell, "record");
        check(window.CurrentPageForProbe == "record" && settings.SettingsLastPage == "record" &&
              SavedText().Contains("\"settingsLastPage\": \"record\"", StringComparison.Ordinal),
            "W1 换到录制页：settings.json 记下 settingsLastPage = record");

        // W2：挪、拉大小，关窗时记下；再打开留在原处
        var scale = Windows.Win32.PInvoke.GetDpiForWindow((Windows.Win32.Foundation.HWND)WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var wanted = new Windows.Graphics.RectInt32(area.X + 37, area.Y + 23, (int)(860 * scale), (int)(620 * scale));
        window.AppWindow.MoveAndResize(wanted);
        await Task.Delay(300);
        window.CloseForProbe();
        await Task.Delay(300);
        var bounds = settings.SettingsWindowBounds;
        check(bounds is [var x, var y, var w, var h] && x == wanted.X && y == wanted.Y && w == wanted.Width && h == wanted.Height &&
              SavedText().Contains("settingsWindowBounds", StringComparison.Ordinal),
            $"W2 挪到 ({wanted.X}, {wanted.Y})、拉成 {wanted.Width} × {wanted.Height} 后关窗：记下了 {(bounds is null ? "null" : string.Join(",", bounds))}");
        window = await ShowAsync(shell, null);
        check(window.AppWindow.Position.X == wanted.X && window.AppWindow.Position.Y == wanted.Y,
            $"W2 再打开留在原处（{window.AppWindow.Position.X}, {window.AppWindow.Position.Y}），没挪回正中");
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(200, 150));
        await Task.Delay(300);
        var small = window.AppWindow.Size;
        check(small.Width >= (int)(700 * scale) - 2 && small.Height >= (int)(460 * scale) - 2,
            $"W2 拉到 200 × 150：停在最小 {small.Width} × {small.Height}（缩放 {scale:0.##}，最小 700 × 460）");
        window.AppWindow.MoveAndResize(wanted);
        await Task.Delay(300);

        // W4–W6：搜索停在哪页
        foreach (var (query, expected, why) in new[]
                 {
                     ("录", "record", "页名里有「录」的录制（通用、快捷键也对上）"),
                     ("唤醒", "general", "没添加的插件的词算通用页"),
                     ("打开主界面", "hotkeys", "快捷键页带全部动作名"),
                     ("引导", "about", "关于页有「欢迎」「引导」"),
                     ("快捷键", "hotkeys", "页名等于搜的字"),
                 })
        {
            window.SearchForProbe(query);
            await Task.Delay(150);
            check(window.CurrentPageForProbe == expected, $"W4–W6 搜「{query}」停在 {window.CurrentPageForProbe}（要 {expected}：{why}）");
        }

        // W7：从别处跳到一页，旧搜索词把它筛掉了：清掉
        window.SearchForProbe("剪贴板");
        await Task.Delay(150);
        window = await ShowAsync(shell, "about");
        check(window.CurrentPageForProbe == "about" && window.SearchTextForProbe.Length == 0,
            $"W7 搜着「剪贴板」从托盘打开关于页：停在 {window.CurrentPageForProbe}，搜索框「{window.SearchTextForProbe}」");

        // W8：跳到收起的组里的页
        settings.SettingsCollapsedGroups = new List<string> { "截图与录制" };
        SettingsService.Save();
        window = await ShowAsync(shell, "screenshot");
        check(settings.SettingsCollapsedGroups?.Contains("截图与录制") != true,
            "W8 收起「截图与录制」后跳到截图页：那组展开并记住");

        // W3：子页回上一层
        window = await ShowAsync(shell, "general");
        window.OpenFeaturesPageForProbe();
        await Task.Delay(150);
        var inFeatures = window.SubpageForProbe == "features";
        var back = window.GoBackForProbe();
        check(inFeatures && back && window.SubpageForProbe is null && window.CurrentPageForProbe == "general",
            "W3 通用 › 功能 回上一层：回到通用");
        check(!window.GoBackForProbe(), "W3 不在子页时回上一层什么都不做");
        if (TranslateServiceStore.Instance?.Services.FirstOrDefault() is { } service)
        {
            window = await ShowAsync(shell, "translate");
            window.OpenServiceDetailForProbe(service.Id);
            await Task.Delay(150);
            var inDetail = window.SubpageForProbe == "service:" + service.Id;
            check(inDetail && window.GoBackForProbe() && window.SubpageForProbe is null && window.CurrentPageForProbe == "translate",
                "W3 翻译服务详情回上一层：回到翻译");
        }
        else
        {
            report.Append("- 没有翻译服务，详情回上一层没测\n");
        }

        window = await ShowAsync(shell, "launcher");
        window.OpenLauncherSubpageForProbe("script-guide");
        await Task.Delay(150);
        var guide = window.SubpageForProbe == "launcher:script-guide";
        window.GoBackForProbe();
        var scripts = window.SubpageForProbe == "launcher:scripts";
        window.GoBackForProbe();
        check(guide && scripts && window.SubpageForProbe is null && window.CurrentPageForProbe == "launcher",
            "W3 怎么写脚本 → 脚本命令 → 启动器，一层一层退");

        // W9：开着对话框时不换页
        window = await ShowAsync(shell, "general");
        var dialog = window.OpenDialogForProbe();
        await Task.Delay(400);
        window = await ShowAsync(shell, "about");
        check(window.CurrentPageForProbe == "general", $"W9 开着对话框时从托盘打开关于页：留在 {window.CurrentPageForProbe}");
        dialog.Hide();
        await Task.Delay(300);

        // 给 b：停在录制页、关窗记下位置
        window = await ShowAsync(shell, "record");
        window.CloseForProbe();
        await Task.Delay(300);
        report.Append($"\n给角色 b：最后的页 {settings.SettingsLastPage}，位置 {string.Join(",", settings.SettingsWindowBounds ?? new List<int>())}\n");
    }

    private static void Invoke(Button? button)
    {
        if (button is null)
        {
            return;
        }

        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(button)
                   ?? Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(button);
        if (peer?.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke) is Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider invoke)
        {
            invoke.Invoke();
        }
    }

    private static string BoxText(Button? box) => box?.Content switch
    {
        TextBlock text => text.Text,
        Microsoft.UI.Xaml.Controls.Panel panel => "键帽:" + panel.Children.Count,
        _ => string.Empty,
    };

    private static async Task RunHotKeysAsync(ShellRuntime shell, Action<bool, string> check)
    {
        var settings = SettingsService.Current;
        var launcher = HotKeyActions.Launcher;
        // 默认键多半被这台电脑上正在用的那份 Kitty Tools 占着（注册不上）：给「截图历史」一个没人用的组合，保证停 / 恢复看得出来
        SettingsDefaults.SetBinding(settings, HotKeyActions.ShotHistory, new HotKeyBinding(0x7A, HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Shift));
        SettingsService.Save();
        shell.HotKeys.RegisterAll(settings);
        var window = await ShowAsync(shell, "hotkeys");
        var before = shell.HotKeys.RegisteredCountForProbe;
        var original = SettingsDefaults.BindingFor(settings, launcher);
        check(before > 0, $"开始前注册着 {before} 个全局热键");

        // H1 H5 H6：点录制框开始录
        Invoke(window.RecorderForProbe(launcher));
        await Task.Delay(200);
        check(window.RecordingForProbe == launcher && shell.HotKeys.HeldForProbe && shell.HotKeys.RegisteredCountForProbe == 0,
            $"H1 点了启动器的录制框：在录、全局热键全停（注册着 {shell.HotKeys.RegisteredCountForProbe} 个）");
        check(BoxText(window.RecorderForProbe(launcher)) == "按下快捷键…", $"H5 录着时框里「{BoxText(window.RecorderForProbe(launcher))}」");
        check(window.ClearButtonForProbe(launcher)?.Visibility == Microsoft.UI.Xaml.Visibility.Visible, "H6 录着时 ⓧ 在");

        // H3：撞键
        window.RecordKeyForProbe(launcher, 'C', HotKeyModifiers.Alt);
        await Task.Delay(150);
        check(window.RecordingForProbe == launcher && window.RowMessageForProbe(launcher) == "和「剪贴板历史」重复" &&
              SettingsDefaults.BindingFor(settings, launcher) == original,
            $"H3 录 Alt+C：「{window.RowMessageForProbe(launcher)}」，接着录、键没变");
        var recordWasOn = Features.IsOn(Feature.Recording);
        Features.Set(Feature.Recording, false);
        window.RecordKeyForProbe(launcher, 'R', HotKeyModifiers.Alt);
        await Task.Delay(150);
        check(window.RowMessageForProbe(launcher) == $"和「录屏（再按一次停止）」重复（{Features.Title(Feature.Recording)}已关闭）",
            $"H3 录制关着时录 Alt+R：「{window.RowMessageForProbe(launcher)}」");
        Features.Set(Feature.Recording, recordWasOn);
        var commands = settings.LauncherCommandHotKeys;
        var kill = LauncherCommandKeys.Rows.FirstOrDefault()?.Id;
        if (kill is not null)
        {
            settings.LauncherCommandHotKeys = new Dictionary<string, string> { [kill] = "Ctrl+Alt+J" };
            window.RecordKeyForProbe(launcher, 'J', HotKeyModifiers.Control | HotKeyModifiers.Alt);
            await Task.Delay(150);
            check(window.RowMessageForProbe(launcher).StartsWith("和启动器命令「", StringComparison.Ordinal),
                $"H3 和启动器命令撞：「{window.RowMessageForProbe(launcher)}」");
            settings.LauncherCommandHotKeys = commands;
        }

        // H6：录着时点 ⓧ = 取消
        Invoke(window.ClearButtonForProbe(launcher));
        await Task.Delay(300);
        check(window.RecordingForProbe is null && SettingsDefaults.BindingFor(settings, launcher) == original &&
              !shell.HotKeys.HeldForProbe && shell.HotKeys.RegisteredCountForProbe == before,
            $"H6 录着时点 ⓧ：取消了、键没变，热键注册回来 {shell.HotKeys.RegisteredCountForProbe} 个");

        // H1 H9：录上一个新组合
        Invoke(window.RecorderForProbe(launcher));
        await Task.Delay(200);
        window.RecordKeyForProbe(launcher, 'K', HotKeyModifiers.Control | HotKeyModifiers.Alt);
        await Task.Delay(400);
        var saved = SettingsDefaults.BindingFor(settings, launcher);
        var box = window.RecorderForProbe(launcher);
        check(window.RecordingForProbe is null && saved == new HotKeyBinding('K', HotKeyModifiers.Control | HotKeyModifiers.Alt) &&
              !shell.HotKeys.HeldForProbe && shell.HotKeys.RegisteredCountForProbe > 0,
            $"H1 录上 Ctrl+Alt+K：存了、停录、热键注册回来 {shell.HotKeys.RegisteredCountForProbe} 个");
        check(box is not null && box.FocusState != Microsoft.UI.Xaml.FocusState.Unfocused,
            $"H9 录完整页重建后焦点在启动器的录制框上（{box?.FocusState}）");
        check(box?.ContextFlyout is MenuFlyout menu && menu.Items.OfType<MenuFlyoutItem>().Select(item => item.Text).SequenceEqual(new[] { "恢复默认", "清除" }),
            "H7 右键菜单：恢复默认、清除");
        window.RestoreHotKeyForProbe(launcher);
        await Task.Delay(300);
        check(SettingsDefaults.BindingFor(settings, launcher) == original, "右键「恢复默认」换回默认键");

        // H8：Delete 清除；H5 没键时的占位
        Invoke(window.RecorderForProbe(launcher));
        await Task.Delay(200);
        window.RecordKeyForProbe(launcher, HotKeyRules.VkDelete, HotKeyModifiers.None);
        await Task.Delay(400);
        check(SettingsDefaults.BindingFor(settings, launcher).VirtualKey == 0 && window.RecordingForProbe is null,
            "H8 录着时按 Delete：清除了、停录");
        check(BoxText(window.RecorderForProbe(launcher)) == "按下快捷键" &&
              window.ClearButtonForProbe(launcher)?.Visibility == Microsoft.UI.Xaml.Visibility.Collapsed,
            $"H5 H6 没键时框里「{BoxText(window.RecorderForProbe(launcher))}」、ⓧ 不出");
        window.RestoreHotKeyForProbe(launcher);
        await Task.Delay(300);

        // H2：设置窗失去前台就停
        Invoke(window.RecorderForProbe(launcher));
        await Task.Delay(200);
        var other = new Microsoft.UI.Xaml.Window { Title = "settings-probe" };
        other.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(40, 40, 320, 200));
        other.Activate();
        await Task.Delay(600);
        check(window.RecordingForProbe is null && !shell.HotKeys.HeldForProbe && shell.HotKeys.RegisteredCountForProbe == before,
            $"H2 录着时别的窗口到前台：停录，热键注册回来 {shell.HotKeys.RegisteredCountForProbe} 个");
        other.Close();
        await Task.Delay(200);
        check(SettingsDefaults.BindingFor(settings, launcher) == original, "最后启动器的键还是默认");
    }

    /// <summary>页里读屏名字是 title（或「title，说明」）的那个元素（卡、按钮）。</summary>
    private static T? Find<T>(Microsoft.UI.Xaml.DependencyObject root, string title) where T : Microsoft.UI.Xaml.FrameworkElement
    {
        if (root is T element && Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(element) is var name &&
            (name == title || name.StartsWith(title + "，", StringComparison.Ordinal)))
        {
            return element;
        }

        for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); index++)
        {
            if (Find<T>(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, index), title) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    private static async Task RunListsAsync(ShellRuntime shell, Action<bool, string> check)
    {
        var settings = SettingsService.Current;
        Features.Set(Feature.StatusScreen, true);
        Features.Set(Feature.Notes, true);
        var window = await ShowAsync(shell, "statusScreen");
        const string statuses = "状态（拖动排序）";
        var before = StatusScreenHost.Presets.Select(preset => preset.Id).ToList();
        check(window.ListForProbe(statuses) is { } list && list.Items.Count == before.Count && before.Count >= 3,
            $"L1 状态是一个能拖的列表（{before.Count} 行）");
        var moved = window.ListKeyForProbe(statuses, 1, Windows.System.VirtualKey.Up, alt: true);
        await Task.Delay(500);
        var after = StatusScreenHost.Presets.Select(preset => preset.Id).ToList();
        var first = window.ListForProbe(statuses)?.Items[0] as ListViewItem;
        check(moved && after.Count == before.Count && after[0] == before[1] && after[1] == before[0],
            "L1 第二行按 Alt + ↑：挪到第一行");
        check(first?.FocusState is not (null or Microsoft.UI.Xaml.FocusState.Unfocused), $"L1 挪完焦点在新的第一行上（{first?.FocusState}）");
        var deleted = window.ListKeyForProbe(statuses, 2, Windows.System.VirtualKey.Delete, alt: false);
        await Task.Delay(400);
        check(deleted && StatusScreenHost.Presets.Count == before.Count - 1 && StatusScreenHost.Presets.All(preset => preset.Id != after[2]),
            "L1 自带的、没改过的状态按 Delete：直接删了（不问）");
        var opened = window.ListKeyForProbe(statuses, 0, Windows.System.VirtualKey.Enter, alt: false);
        await Task.Delay(500);
        var root = window.ContentForProbe.XamlRoot;
        check(opened && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Any(popup => popup.Child is ContentDialog),
            "L1 第一行按 Enter：打开编辑");
        window.CloseDialogsForProbe();
        await Task.Delay(300);
        check(!window.ListKeyForProbe(statuses, 0, Windows.System.VirtualKey.Up, alt: true), "L1 第一行按 Alt + ↑：什么都不做（上移是灰的）");

        if (TranslateServiceStore.Instance is { Services.Count: >= 2 } store)
        {
            window = await ShowAsync(shell, "translate");
            var services = store.Services.Select(service => service.Id).ToList();
            window.ListKeyForProbe("翻译服务（拖动排序）", 0, Windows.System.VirtualKey.Down, alt: true);
            await Task.Delay(400);
            check(store.Services[0].Id == services[1] && store.Services[1].Id == services[0], "L1 翻译服务第一行按 Alt + ↓：挪到第二");
            window.ListKeyForProbe("翻译服务（拖动排序）", 1, Windows.System.VirtualKey.Up, alt: true);
            await Task.Delay(400);
            check(store.Services[0].Id == services[0], "L1 再按 Alt + ↑ 挪回去");
        }

        // L3 快门声
        settings.ScreenshotShutterSound = false;
        SettingsService.Save();
        window = await ShowAsync(shell, "screenshot");
        window.RebuildPageForProbe();
        await Task.Delay(300);
        check(Find<Button>(window.ContentForProbe, "试听快门声") is { IsEnabled: false }, "L3 快门声关着：「试听」是灰的");
        settings.ScreenshotShutterSound = true;
        // L4 截图历史
        settings.ShotHistory = false;
        SettingsService.Save();
        window.RebuildPageForProbe();
        await Task.Delay(300);
        check(Find<Border>(window.ContentForProbe, "保留") is null or { Visibility: Microsoft.UI.Xaml.Visibility.Collapsed } &&
              Find<Border>(window.ContentForProbe, "最多占用") is null or { Visibility: Microsoft.UI.Xaml.Visibility.Collapsed },
            "L4 截图历史关着：「保留」「最多占用」不显示");
        check(Find<Button>(window.ContentForProbe, "试听快门声") is { IsEnabled: true }, "L3 快门声开着：「试听」能点");
        settings.ShotHistory = true;
        SettingsService.Save();
        window.RebuildPageForProbe();
        await Task.Delay(300);
        check(Find<Border>(window.ContentForProbe, "保留") is { Visibility: Microsoft.UI.Xaml.Visibility.Visible }, "L4 截图历史开着：两行回来");

        // L5 便签边缘
        settings.NotesDeckEnabled = true;
        settings.NotesDeckAlwaysFanned = true;
        settings.NotesDeckOpensOnHover = false;
        SettingsService.Save();
        window = await ShowAsync(shell, "notes");
        window.RebuildPageForProbe();
        await Task.Delay(300);
        check(Find<Border>(window.ContentForProbe, "不显示药丸") is { IsHitTestVisible: false } &&
              Find<Border>(window.ContentForProbe, "悬停预览") is { IsHitTestVisible: true },
            "L5 「一直展开」开着：「不显示药丸」灰、「悬停预览」能拨");
        settings.NotesDeckAlwaysFanned = false;
        settings.NotesDeckOpensOnHover = true;
        SettingsService.Save();
        window.RebuildPageForProbe();
        await Task.Delay(300);
        check(Find<Border>(window.ContentForProbe, "不显示药丸") is { IsHitTestVisible: true } &&
              Find<Border>(window.ContentForProbe, "悬停预览") is { IsHitTestVisible: false },
            "L5 「悬停即打开」开着：「悬停预览」灰、「不显示药丸」能拨");
    }

    private static async Task RunSecondAsync(ShellRuntime shell, Action<bool, string> check)
    {
        var settings = SettingsService.Current;
        var bounds = settings.SettingsWindowBounds;
        var window = await ShowAsync(shell, null);
        check(window.CurrentPageForProbe == "record", $"W1 重启后打开设置：停在 {window.CurrentPageForProbe}（要 record）");
        var position = window.AppWindow.Position;
        var size = window.AppWindow.Size;
        check(bounds is [var x, var y, var w, var h] && position.X == x && position.Y == y && size.Width == w && size.Height == h,
            $"W2 重启后打开：({position.X}, {position.Y}) {size.Width} × {size.Height}，记的是 {(bounds is null ? "null" : string.Join(",", bounds))}");
    }
}
