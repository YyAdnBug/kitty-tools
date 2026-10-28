// 自检档（Debug，或 Release 带 KITTY_PROBE_PROFILE）：`--launcher-script=<步骤>` 照脚本操作启动器，量每一步里 UI 线程最多卡了多久。
// 不合成按键：改搜索框的字走 TextChanged（和打字同一条路），挪选中、Enter 直接调面板里键盘处理用的那几个方法。
// 步骤用「;」隔开：show、hide、type:<字>（一个字一个字地加，120 ms 一个）、back:<个数>（一个一个删）、
// down、up、enter、wait:<毫秒>、shot:<名字>（抓浮层窗口存到数据目录的 probe-<名字>.png）。每步一行日志 launcher.probe，跑完一行 launcher.probe-done（带全程最长的一次卡顿）。
// 卡顿的量法：后台每 20 ms 往 UI 线程排一个空操作，记从排进去到它跑起来的时间。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static class LauncherProbe
{
    public const string ArgumentPrefix = "--launcher-script=";

    private static long _stallMs;

    public static async Task RunAsync(string script)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        using var stop = new CancellationTokenSource();
        var watcher = Task.Run(() => WatchAsync(dispatcher, stop.Token));
        var worst = 0L;
        var steps = script.Split(';', StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < steps.Length; index++)
        {
            var step = steps[index];
            var colon = step.IndexOf(':');
            var kind = colon < 0 ? step : step[..colon];
            var argument = colon < 0 ? string.Empty : step[(colon + 1)..];
            Interlocked.Exchange(ref _stallMs, 0);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            await RunStepAsync(kind, argument);
            await Task.Delay(50); // 让这一步排出去的活跑完，卡顿算进这一步
            var stall = Interlocked.Read(ref _stallMs);
            worst = Math.Max(worst, stall);
            var model = LauncherModel.Instance;
            Log.Info($"launcher.probe step={index} kind={kind} ms={watch.ElapsedMilliseconds} stall={stall} " +
                     $"open={OverlayHost.VisibleLauncher is not null} mode={model?.Mode} rows={model?.Results.Count}");
        }

        stop.Cancel();
        await watcher;
        Log.Info($"launcher.probe-done steps={steps.Length} worst-stall={worst}");
    }

    private static async Task RunStepAsync(string kind, string argument)
    {
        switch (kind)
        {
            case "show":
                OverlayHost.Show(OverlayKind.Launcher);
                break;
            case "hide":
                OverlayHost.Hide(restoreForeground: false);
                break;
            case "type":
                foreach (var character in argument)
                {
                    if (OverlayHost.VisibleLauncher is { } panel)
                    {
                        panel.ProbeType(panel.ProbeText + character);
                    }

                    await Task.Delay(120);
                }

                break;
            case "back":
                for (var count = int.TryParse(argument, out var value) ? value : 1; count > 0; count--)
                {
                    if (OverlayHost.VisibleLauncher is { ProbeText.Length: > 0 } panel)
                    {
                        panel.ProbeType(panel.ProbeText[..^1]);
                    }

                    await Task.Delay(120);
                }

                break;
            case "down":
                OverlayHost.VisibleLauncher?.ProbeMove(1);
                break;
            case "up":
                OverlayHost.VisibleLauncher?.ProbeMove(-1);
                break;
            case "enter":
                OverlayHost.VisibleLauncher?.ProbeEnter();
                break;
            case "wait":
                await Task.Delay(int.TryParse(argument, out var ms) ? ms : 500);
                break;
            case "shot":
                // 只抓自己的浮层窗口（WGC），存到数据目录下 probe-<名字>.png。
                await WindowShot.SaveAsync(OverlayHost.HandleForProbe, Path.Combine(Paths.DataDirectory, $"probe-{argument}.png"));
                break;
            default:
                Log.Warn($"launcher.probe-unknown {kind}");
                break;
        }
    }

    /// <summary>后台每 20 ms 往 UI 线程排一个空操作，记最长的一次排队时间（卡死时这里会一直等，日志就停在那一步之前）。</summary>
    private static async Task WatchAsync(DispatcherQueue dispatcher, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var queued = System.Diagnostics.Stopwatch.StartNew();
            var ran = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!dispatcher.TryEnqueue(() => ran.TrySetResult()))
            {
                return;
            }

            await ran.Task.ConfigureAwait(false);
            var elapsed = queued.ElapsedMilliseconds;
            long current;
            do
            {
                current = Interlocked.Read(ref _stallMs);
            }
            while (elapsed > current && Interlocked.CompareExchange(ref _stallMs, elapsed, current) != current);

            try
            {
                await Task.Delay(20, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }
}
