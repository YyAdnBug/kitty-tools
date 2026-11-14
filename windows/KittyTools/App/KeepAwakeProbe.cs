// 保持唤醒的自检（PLAN-v20 第 3 批，Windows 自己加的）：`--keep-awake-probe=<目录>`（只在测试档）。不发按键、不改系统设置：
// 在测试档里添加插件、开一段 / 停、换「屏幕也不熄」、开一段 3 秒的看它自己到点、开定时（每天全天）再关，每一步读一次系统的
// 执行状态（CallNtPowerInformation(SystemExecutionState)：ES_SYSTEM_REQUIRED 1、ES_DISPLAY_REQUIRED 2），看电源请求真的挂上、
// 真的撤掉。系统状态是全机的：别的程序（视频、下载）同时要着时「撤掉」那几步会看到它们的位，报告里照写。结果写 report.md，跑完就退。
using System.Runtime.InteropServices;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static partial class KeepAwakeProbe
{
    public const string ArgumentPrefix = "--keep-awake-probe";

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
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-keep-awake-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 保持唤醒（PLAN-v20 第 3 批）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        await Task.Delay(1500);
        var settings = SettingsService.Current;
        var features = settings.Features is { } map ? new Dictionary<string, bool>(map) : null;
        var schedule = settings.KeepAwakeSchedule;
        var display = settings.KeepAwakeDisplay;
        try
        {
            var before = State();
            report.Append($"开始前系统的执行状态 0x{before:x}（别的程序要着的位会一直在）\n");
            if ((before & 3) != 0)
            {
                report.Append("**开始前别的程序已经要着这些位：挂上 / 撤掉那几步从全机状态上看不出，只说明请求建成了、没出错" +
                              "（日志 keep-awake.request，没有 create-failed / set-failed）。**\n");
            }

            report.Append('\n');
            Check(!KeepAwakeHost.IsRunning, "没添加插件时没在跑");
            Features.Set(Feature.KeepAwake, true);
            await Task.Delay(400);
            Check(KeepAwakeHost.IsRunning && !KeepAwakeHost.IsActive, "添加了插件：在跑、还没开");

            settings.KeepAwakeDisplay = true;
            SettingsService.Save();
            KeepAwakeHost.Begin(DateTime.UtcNow.AddMinutes(2), "2 分钟");
            await Task.Delay(300);
            var on = State();
            Check((on & 3) == 3, $"开一段（屏幕也不熄）：系统要求和屏幕要求都在（0x{on:x}），状态「{KeepAwakeHost.Status()}」");

            settings.KeepAwakeDisplay = false;
            SettingsService.Save();
            await Task.Delay(400);
            var systemOnly = State();
            Check((systemOnly & 1) == 1 && ((systemOnly & 2) == 0 || (before & 2) != 0),
                $"改成只防系统睡：只剩系统要求（0x{systemOnly:x}）");

            KeepAwakeHost.End();
            await Task.Delay(300);
            var off = State();
            Check(!KeepAwakeHost.IsActive && (off & 3) == (before & 3), $"停止：撤掉了（0x{off:x}）");

            KeepAwakeHost.Begin(DateTime.UtcNow.AddSeconds(3), "3 秒");
            await Task.Delay(500);
            Check(KeepAwakeHost.IsActive, "开一段 3 秒");
            await Task.Delay(3500);
            Check(!KeepAwakeHost.IsActive && (State() & 3) == (before & 3), "3 秒后自己到点、撤掉");

            settings.KeepAwakeSchedule = new KeepAwakeSchedule { IsOn = true, Weekdays = Enumerable.Range(1, 7).ToArray(), AllDay = true }.Encode();
            SettingsService.Save();
            await Task.Delay(400);
            Check(KeepAwakeHost.InSchedule && (State() & 1) == 1, $"定时（每天全天）：在时段里、系统要求在，状态「{KeepAwakeHost.Status()}」");
            settings.KeepAwakeSchedule = schedule;
            SettingsService.Save();
            await Task.Delay(400);
            Check(!KeepAwakeHost.InSchedule && (State() & 3) == (before & 3), "定时关掉：出了时段、撤掉");

            KeepAwakeHost.Begin(null, "无限期");
            await Task.Delay(300);
            Features.Set(Feature.KeepAwake, false);
            await Task.Delay(400);
            Check(!KeepAwakeHost.IsRunning && (State() & 3) == (before & 3), "开着无限期时移除插件：停掉、撤掉");
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            KeepAwakeHost.Stop();
            settings.Features = features;
            settings.KeepAwakeSchedule = schedule;
            settings.KeepAwakeDisplay = display;
            SettingsService.Save();
        }

        report.Append(failures == 0 ? "\n全部通过。\n" : $"\n{failures} 项不对。\n");
        await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
        Log.Info($"keep-awake-probe done failures={failures}");
        Environment.Exit(failures == 0 ? 0 : 1);
    }

    /// <summary>系统此刻的执行状态（ES_* 位）。</summary>
    private static unsafe uint State()
    {
        uint state = 0;
        return CallNtPowerInformation(16 /* SystemExecutionState */, null, 0, &state, sizeof(uint)) == 0 ? state : 0xFFFFFFFF;
    }

    [LibraryImport("powrprof.dll")]
    private static unsafe partial int CallNtPowerInformation(int level, void* input, uint inputLength, void* output, uint outputLength);
}
