// 跑一条脚本命令并把结果交出去（PLAN-v18 L1，mac LauncherModel.runScript）：下载来的先看全文（ScriptTextWindow.Review，确认后去掉
// 标记再跑）；超过 1 秒没跑完出「正在运行「…」」带「停止」；跑完按 mode：岛上一行（默认）/ 粘贴到前台应用 / 复制（记进剪贴板历史）/
// 不显示 / 全部输出（ScriptTextWindow.Output，边跑边显示）。出错写最后一行错误输出（没有就写退出码）、超时、停了、起不来的原因。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static class ScriptHost
{
    /// <summary>pasteTarget：呼出启动器之前的前台窗口（粘贴模式往那里粘）。</summary>
    public static void Run(ScriptCommand script, IReadOnlyList<string> arguments, HWND pasteTarget)
    {
        if (script.IsDownloaded)
        {
            string text;
            try
            {
                text = File.ReadAllText(script.Path);
            }
            catch (Exception ex)
            {
                NoticeHost.Show($"没能打开「{script.Title}」", ex.GetType().Name, NoticeTone.Error);
                return;
            }

            ScriptTextWindow.Review(script, text, () =>
            {
                ScriptRunner.ClearDownloaded(script.Path);
                ScriptLibrary.Refresh();
                _ = RunAsync(script with { IsDownloaded = false }, arguments, pasteTarget);
            });
            return;
        }

        _ = RunAsync(script, arguments, pasteTarget);
    }

    private static async Task RunAsync(ScriptCommand script, IReadOnlyList<string> arguments, HWND pasteTarget)
    {
        using var stop = new CancellationTokenSource();
        Action<string>? live = null;
        Action<string>? done = null;
        if (script.Mode == ScriptMode.Full)
        {
            (live, done) = ScriptTextWindow.Output(script, stop.Cancel, () => _ = RunAsync(script, arguments, pasteTarget));
        }

        var finished = false;
        if (script.Mode != ScriptMode.Full)
        {
            var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _ = Task.Delay(1000).ContinueWith(_ => queue?.TryEnqueue(() =>
            {
                if (!finished)
                {
                    NoticeHost.Show($"正在运行「{script.Title}」", string.Empty, NoticeTone.Normal, new NoticeAction("停止", stop.Cancel));
                }
            }), TaskScheduler.Default);
        }

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var outcome = await ScriptRunner.RunAsync(script, arguments, stop.Token, live);
        finished = true;
        Log.Info($"script.run end={outcome.End} code={outcome.ExitCode} ms={watch.ElapsedMilliseconds} mode={script.Mode}");
        var failure = outcome.End switch
        {
            ScriptRunner.End.Stopped => "已停止",
            ScriptRunner.End.TimedOut => $"超过 {script.Limit} 秒没跑完，停掉了",
            ScriptRunner.End.FailedToStart => outcome.Reason ?? "起不来",
            ScriptRunner.End.TooMuchOutput => "输出太多，停掉了",
            _ when outcome.ExitCode != 0 => ScriptText.LastLine(outcome.Error) ?? ScriptText.LastLine(outcome.Output) ?? $"退出码 {outcome.ExitCode}",
            _ => null,
        };
        if (done is not null)
        {
            done(failure ?? "跑完了");
            return;
        }

        if (failure is not null)
        {
            NoticeHost.Show($"「{script.Title}」{(outcome.End == ScriptRunner.End.Stopped ? "停了" : "没成")}", failure,
                outcome.End == ScriptRunner.End.Stopped ? NoticeTone.Normal : NoticeTone.Error);
            return;
        }

        var payload = ScriptText.Payload(outcome.Output);
        switch (script.Mode)
        {
            case ScriptMode.Paste when payload.Length > 0:
                Paster.PasteText(pasteTarget, payload);
                break;
            case ScriptMode.Copy when payload.Length > 0:
                if (ClipboardWriter.WriteText(payload))
                {
                    ClipboardService.Instance?.MarkOwnWrite();
                    ClipboardService.Instance?.Store.RecordOwnText(payload);
                    NoticeHost.Show("已复制", LauncherText.FirstLine(payload), NoticeTone.Normal);
                }

                break;
            case ScriptMode.None:
                break;
            default:
                NoticeHost.Show(script.Title, ScriptText.LastLine(outcome.Output) ?? "完成", NoticeTone.Normal);
                break;
        }
    }
}
