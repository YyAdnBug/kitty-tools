// 设置窗交互的自检（PLAN-v23，只在测试档）：`--settings-probe=<目录>`，KITTY_SETTINGS_PROBE_ROLE 定这一份做什么。不发按键、不点鼠标，
// 走和用户操作同一条路（SettingsWindow.Probe.cs 的几个口子）：
// - a：换页记进 settings.json；挪窗口、拉大小、关窗后记下位置，再打开不挪回正中；最小尺寸；搜索停在哪页（W4–W6）；从别处跳页清掉搜索词（W7）；
//   跳到收起的组里的页那组展开并记住（W8）；子页回上一层（W3）；开着对话框时不换页（W9）。最后停在录制页、关窗。
// - b：同一个测试档再起一次，打开设置窗：停在 a 最后的那页、窗口在 a 记下的位置和大小（W1 W2）。
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
