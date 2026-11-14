// 脚本命令的实跑自检（PLAN-v18 L1，Windows 自己加的）：`--script-probe=<目录>`（只在测试档）。不碰启动器界面、不发按键：
// 在 <目录>\scripts 写几个假脚本（.ps1、.cmd、.py），用 ScriptRunner 真跑一遍：输出、中文不乱码、退出码、参数（带空格 / &）、
// 超时、停止时连子进程一起停、工作目录、KITTY_* 环境、下载标记（写一个 :Zone.Identifier）；量 PowerShell 冷启动。结果写 report.md，跑完就退。
using System.Diagnostics;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class ScriptProbe
{
    public const string ArgumentPrefix = "--script-probe";

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
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-script-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        var report = new StringBuilder("# 脚本命令实跑自检（PLAN-v18 L1）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        try
        {
            var folder = Path.Combine(directory, "scripts dir");
            Directory.CreateDirectory(folder);
            var python = File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe"));
            ScriptCommand Write(string name, string text)
            {
                var path = Path.Combine(folder, name);
                File.WriteAllText(path, text, name.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ? new UTF8Encoding(false) : new UTF8Encoding(true));
                var parsed = ScriptCommand.Parse(text, path, python);
                return parsed?.Script ?? throw new InvalidOperationException(name + " " + parsed?.Problem);
            }

            // PowerShell：输出中文、参数、环境、工作目录；量冷启动
            var ps = Write("hello.ps1", "# @kitty.title 你好\n# @kitty.argument1 名字\nWrite-Output \"你好 $($args[0])\"\nWrite-Output (Get-Location).Path\nWrite-Output $env:KITTY_SCRIPT_DIR\nexit 3\n");
            var watch = Stopwatch.StartNew();
            var outcome = await ScriptRunner.RunAsync(ps, new[] { "张 三 & 李" }, CancellationToken.None);
            var cold = watch.ElapsedMilliseconds;
            var lines = ScriptText.Clean(outcome.Output).Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).ToList();
            Check(outcome.End == ScriptRunner.End.Finished && outcome.ExitCode == 3, $"ps1：跑完、退出码 {outcome.ExitCode}（该 3）");
            Check(lines.FirstOrDefault() == "你好 张 三 & 李", $"ps1：中文、带空格和 & 的参数原样到「{lines.FirstOrDefault()}」");
            Check(lines.Skip(1).All(line => string.Equals(line, folder, StringComparison.OrdinalIgnoreCase)), "ps1：工作目录和 KITTY_SCRIPT_DIR 是脚本所在的文件夹");
            watch.Restart();
            await ScriptRunner.RunAsync(ps, new[] { "x" }, CancellationToken.None);
            report.Append($"  PowerShell 冷启动 {cold} ms，第二次 {watch.ElapsedMilliseconds} ms\n");

            // cmd：存成 UTF-8 的（VS Code 默认）和存成 GBK 的（记事本 ANSI）都不乱码；带空格和 & 的参数原样（脚本里 %1 带着引号）
            var cmd = Write("echo.cmd", "@echo off\r\nrem @kitty.title 回显\r\necho 中文 %1\r\n");
            outcome = await ScriptRunner.RunAsync(cmd, new[] { "a & b" }, CancellationToken.None);
            Check(ScriptText.LastLine(outcome.Output) == "中文 \"a & b\"", $"cmd（UTF-8）：中文不乱码、参数原样「{ScriptText.LastLine(outcome.Output)}」");
            var ansi = Path.Combine(folder, "ansi.cmd");
            File.WriteAllBytes(ansi, Encoding.GetEncoding(936).GetBytes("@echo off\r\necho 中文\r\n"));
            outcome = await ScriptRunner.RunAsync(ScriptCommand.Parse("", ansi, python)!.Value.Script!, Array.Empty<string>(), CancellationToken.None);
            Check(ScriptText.LastLine(outcome.Output) == "中文", $"cmd（GBK）：中文不乱码「{ScriptText.LastLine(outcome.Output)}」");

            // 超时：1 秒的超时，脚本睡 30 秒
            var slow = Write("slow.ps1", "# @kitty.timeout 1\nStart-Sleep -Seconds 30\n");
            watch.Restart();
            outcome = await ScriptRunner.RunAsync(slow, Array.Empty<string>(), CancellationToken.None);
            Check(outcome.End == ScriptRunner.End.TimedOut && watch.ElapsedMilliseconds < 6000, $"超时：{outcome.End}，{watch.ElapsedMilliseconds} ms 停下");

            // 停止：cmd 起一个 ping（子进程），0.8 秒后停，ping 也要没了
            var tree = Write("tree.cmd", "@echo off\r\nping -n 30 127.0.0.1 >nul\r\n");
            using var stop = new CancellationTokenSource(800);
            var before = Process.GetProcessesByName("PING").Select(process => process.Id).ToHashSet();
            var run = ScriptRunner.RunAsync(tree, Array.Empty<string>(), stop.Token);
            await Task.Delay(500);
            var children = Process.GetProcessesByName("PING").Where(process => !before.Contains(process.Id)).Select(process => process.Id).ToList();
            outcome = await run;
            await Task.Delay(300);
            var left = children.Count(id =>
            {
                try
                {
                    return !Process.GetProcessById(id).HasExited;
                }
                catch (ArgumentException)
                {
                    return false;
                }
            });
            Check(outcome.End == ScriptRunner.End.Stopped && children.Count > 0 && left == 0,
                $"停止：{outcome.End}，子进程 ping {children.Count} 个、停后还剩 {left} 个");

            // 下载标记：写一个 :Zone.Identifier，扫描时没带标记的那份不能跑；去掉标记后能跑
            var downloaded = Write("net.ps1", "Write-Output ok\n");
            File.WriteAllText(downloaded.Path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
            Check(ScriptRunner.IsDownloaded(downloaded.Path), "下载标记：认得出 :Zone.Identifier");
            outcome = await ScriptRunner.RunAsync(downloaded, Array.Empty<string>(), CancellationToken.None);
            Check(outcome.End == ScriptRunner.End.FailedToStart, "下载标记：扫描后才带上标记的不跑");
            ScriptRunner.ClearDownloaded(downloaded.Path);
            outcome = await ScriptRunner.RunAsync(downloaded, Array.Empty<string>(), CancellationToken.None);
            Check(!ScriptRunner.IsDownloaded(downloaded.Path) && ScriptText.LastLine(outcome.Output) == "ok", "下载标记：看过、去掉标记后能跑");

            if (python)
            {
                var py = Write("p.py", "# @kitty.title 派\nimport sys\nprint('中文', sys.argv[1])\n");
                outcome = await ScriptRunner.RunAsync(py, new[] { "参数" }, CancellationToken.None);
                Check(ScriptText.LastLine(outcome.Output) == "中文 参数", $"py：UTF-8 输出「{ScriptText.LastLine(outcome.Output)}」");
            }
            else
            {
                report.Append("  这台没有 py.exe：.py 没跑（设置页列「要装 Python」）\n");
            }
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name} {ex.Message}");
        }

        report.Append(failures == 0 ? "\n**全过**\n" : $"\n**{failures} 条不对**\n");
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
        Log.Info($"script-probe done failures={failures}");
        Environment.Exit(failures == 0 ? 0 : 6);
    }
}
