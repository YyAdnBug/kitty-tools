// 跑一条脚本命令（PLAN-v18 L1 / D7，mac ScriptRunner + Subprocess）：按扩展名调解释器（ScriptCommand.Interpreter；.cmd / .bat 走
// ScriptLaunch.CmdArguments），不开窗口、标准输入是空的、工作目录是脚本所在的文件夹，默认 60 秒超时；超时、停止、输出写太多（4 MB）
// 都是 Kill(entireProcessTree)——脚本起的子进程（ping、curl）一起停。输出只留前 1 MB；.py 按 UTF-8 读，别的按 OEM 代码页读。
// 环境见 ScriptLaunch.Environment（PATH 每次从注册表重读）。下载来的（带 :Zone.Identifier）扫描之后才换上的不跑，先回去看全文。
using System.Diagnostics;
using System.Globalization;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.Win32;

namespace KittyTools;

internal static class ScriptRunner
{
    public enum End
    {
        Finished,
        TimedOut,
        Stopped,
        FailedToStart,
        TooMuchOutput,
    }

    public sealed record Outcome(End End, int ExitCode = 0, string Output = "", string Error = "", string? Reason = null)
    {
        public bool Succeeded => End == End.Finished && ExitCode == 0;
    }

    /// <summary>输出最多留这么多；写到它的 4 倍就停掉。</summary>
    public const int OutputLimit = 1 << 20;

    static ScriptRunner() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    /// <summary>注册表里此刻的 PATH（系统 + 用户，%变量% 展开）；读不到返回 null（用继承的）。</summary>
    public static string? RegistryPath()
    {
        try
        {
            using var machine = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment");
            using var user = Registry.CurrentUser.OpenSubKey("Environment");
            var joined = ScriptLaunch.JoinPath(machine?.GetValue("Path") as string, user?.GetValue("Path") as string);
            return joined.Length == 0 ? null : Environment.ExpandEnvironmentVariables(joined);
        }
        catch (Exception ex)
        {
            Log.Warn($"script.path-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>带着「从网上下载的」标记（NTFS 的 :Zone.Identifier 流）。</summary>
    public static bool IsDownloaded(string path)
    {
        try
        {
            return File.Exists(path + ":Zone.Identifier");
        }
        catch
        {
            return false;
        }
    }

    /// <summary>看过全文、确认了：去掉下载标记（以后不再问）。</summary>
    public static void ClearDownloaded(string path)
    {
        try
        {
            File.Delete(path + ":Zone.Identifier");
        }
        catch (Exception ex)
        {
            Log.Warn($"script.unblock-failed {ex.GetType().Name}");
        }
    }

    /// <summary>live：边跑边拿输出（全文那一页；错误输出并进来，同终端）。</summary>
    public static async Task<Outcome> RunAsync(
        ScriptCommand script, IReadOnlyList<string> arguments, CancellationToken cancellation, Action<string>? live = null)
    {
        // 自带的命令（PLAN-v18 D8）：C# 里算，不起进程；json / regt 不带文字时读剪贴板（标了隐私的不读）
        if (BuiltinTools.IsBuiltin(script))
        {
            var given = script.Passed(arguments);
            var clipboard = script.Path switch
            {
                "kitty-builtin:json" when given.All(string.IsNullOrWhiteSpace) => ClipboardFormats.ReadTextForPin(),
                "kitty-builtin:regt" when given.Count < 2 || given[1].Length == 0 => ClipboardFormats.ReadTextForPin(),
                _ => null,
            };
            var (code, text) = BuiltinTools.Run(script.Path, given, clipboard, DateTimeOffset.Now, TimeZoneInfo.Local);
            live?.Invoke(text);
            return code == 0 ? new Outcome(End.Finished, 0, text) : new Outcome(End.Finished, code, string.Empty, text);
        }

        if (!script.IsDownloaded && !script.IsBundled && IsDownloaded(script.Path))
        {
            return new Outcome(End.FailedToStart, Reason: "这个脚本刚换成了从网上下载的：重新打开启动器，先看一眼全文再运行");
        }

        var info = new ProcessStartInfo(script.Interpreter[0])
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = script.Folder,
        };
        var utf8File = ScriptLaunch.IsBatch(script.Path) && FileLooksUtf8(script.Path);
        var encoding = ScriptLaunch.OutputIsUtf8(script, utf8File)
            ? new UTF8Encoding(false)
            : Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage);
        info.StandardOutputEncoding = encoding;
        info.StandardErrorEncoding = encoding;
        var passed = script.Passed(arguments);
        if (script.Interpreter[0].Equals("cmd.exe", StringComparison.OrdinalIgnoreCase))
        {
            info.Arguments = ScriptLaunch.CmdArguments(script.Path, passed, utf8File);
        }
        else
        {
            foreach (var part in script.Interpreter.Skip(1).Append(script.Path).Concat(passed))
            {
                info.ArgumentList.Add(part);
            }
        }

        var inherited = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(entry => (string)entry.Key, entry => entry.Value as string ?? string.Empty, StringComparer.OrdinalIgnoreCase);
        info.Environment.Clear();
        foreach (var (key, value) in ScriptLaunch.Environment(inherited, RegistryPath(), script, Paths.DataDirectory, WhatsNewHost.Version))
        {
            info.Environment[key] = value;
        }

        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Log.Warn($"script.start-failed {ex.GetType().Name}");
            return new Outcome(End.FailedToStart, Reason: script.Interpreter[0] == "py.exe" ? "没找到 Python（py.exe）" : "起不来：" + ex.Message);
        }

        using (process)
        {
            process.StandardInput.Close();
            var output = new StringBuilder();
            var error = new StringBuilder();
            var total = 0L;
            var tooMuch = false;
            async Task Pump(StreamReader reader, StringBuilder target, bool liveToo)
            {
                var buffer = new char[4096];
                int read;
                while ((read = await reader.ReadAsync(buffer, CancellationToken.None)) > 0)
                {
                    if (Interlocked.Add(ref total, read) > 4L * OutputLimit)
                    {
                        tooMuch = true;
                        Kill(process);
                        return;
                    }

                    lock (target)
                    {
                        if (target.Length < OutputLimit)
                        {
                            target.Append(buffer, 0, Math.Min(read, OutputLimit - target.Length));
                        }
                    }

                    if (live is not null && liveToo)
                    {
                        live(new string(buffer, 0, read));
                    }
                }
            }

            var pumps = Task.WhenAll(Pump(process.StandardOutput, output, true), Pump(process.StandardError, error, true));
            var limit = script.Limit > 0 ? TimeSpan.FromSeconds(script.Limit) : Timeout.InfiniteTimeSpan;
            using var timeout = new CancellationTokenSource(limit);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, timeout.Token);
            try
            {
                await process.WaitForExitAsync(linked.Token);
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                await Task.WhenAny(pumps, Task.Delay(2000));
                return new Outcome(cancellation.IsCancellationRequested ? End.Stopped : End.TimedOut, Output: output.ToString(),
                    Error: error.ToString());
            }

            await Task.WhenAny(pumps, Task.Delay(2000));
            if (tooMuch)
            {
                return new Outcome(End.TooMuchOutput, Output: output.ToString(), Error: error.ToString());
            }

            return new Outcome(End.Finished, process.ExitCode, output.ToString(), error.ToString());
        }
    }

    private static bool FileLooksUtf8(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var buffer = new byte[ScriptCommand.HeaderBytes];
            var read = stream.Read(buffer, 0, buffer.Length);
            return ScriptLaunch.LooksUtf8(buffer.AsSpan(0, read));
        }
        catch
        {
            return false;
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"script.kill-failed {ex.GetType().Name}");
        }
    }
}
