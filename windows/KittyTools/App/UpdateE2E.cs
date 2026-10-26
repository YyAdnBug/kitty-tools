// `--update-e2e=<目录>`：自动更新失败路径的端到端自检（PLAN-v6 第 7 批）。
// 在临时目录里搭一个假安装目录和真 zip，用 UpdateHttp 的 file:// 传输走完整的
// 下载 → sha256 → 解压 → 找入口 → 比版本 → 覆盖流程，把成功、sha256 错、
// 目标被目录挡住回滚、包里没有 exe 四条路都跑一遍，报告写到 <目录>\report.json。
// 在 WinUI / 单实例初始化之前执行，不需要窗口，也不碰真实安装目录和数据。
using System.IO.Compression;
using System.Text;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class UpdateE2E
{
    public const string ArgumentPrefix = "--update-e2e";

    public static bool IsRequested(string[] args)
        => args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static int Run(string[] args)
    {
        var argument = args.First(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        var root = argument.Contains('=')
            ? argument[(argument.IndexOf('=') + 1)..]
            : Path.Combine(Path.GetTempPath(), "kitty-update-e2e");
        if (string.IsNullOrWhiteSpace(root))
        {
            root = Path.Combine(Path.GetTempPath(), "kitty-update-e2e");
        }

        var results = new List<ScenarioResult>();
        try
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }

            Directory.CreateDirectory(root);
            var self = Paths.ExecutablePath;
            if (string.IsNullOrEmpty(self) || !File.Exists(self))
            {
                throw new InvalidOperationException("找不到自己的 exe");
            }

            var version = typeof(UpdateE2E).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
            var newExe = File.ReadAllBytes(self).Concat("NEW"u8.ToArray()).ToArray();
            var oldExe = File.ReadAllBytes(self).Concat("OLD"u8.ToArray()).ToArray();

            results.Add(RunScenario(root, "success", version, newExe, oldExe, hashOk: true, blockTarget: false));
            results.Add(RunScenario(root, "sha256-mismatch", version, newExe, oldExe, hashOk: false, blockTarget: false));
            results.Add(RunScenario(root, "blocked-rollback", version, newExe, oldExe, hashOk: true, blockTarget: true));
            results.Add(RunScenario(root, "missing-entry", version, newExe, oldExe, hashOk: true, blockTarget: false, includeEntry: false));
        }
        catch (Exception ex)
        {
            results.Add(new ScenarioResult("setup", false, $"{ex.GetType().Name}: {ex.Message}"));
        }

        var reportPath = Path.Combine(root, "report.json");
        try
        {
            var report = new StringBuilder();
            report.AppendLine("{");
            report.AppendLine($"  \"generatedAt\": \"{DateTimeOffset.Now:O}\",");
            report.AppendLine($"  \"version\": \"{typeof(UpdateE2E).Assembly.GetName().Version?.ToString(3)}\",");
            report.AppendLine($"  \"ok\": {(results.All(result => result.Ok) ? "true" : "false")},");
            report.AppendLine("  \"scenarios\": [");
            for (var index = 0; index < results.Count; index++)
            {
                var result = results[index];
                report.Append("    { \"name\": ");
                report.Append(Quote(result.Name));
                report.Append(", \"ok\": ");
                report.Append(result.Ok ? "true" : "false");
                report.Append(", \"detail\": ");
                report.Append(Quote(result.Detail));
                report.Append(" }");
                report.AppendLine(index == results.Count - 1 ? string.Empty : ",");
            }

            report.AppendLine("  ]");
            report.AppendLine("}");
            File.WriteAllText(reportPath, report.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (Exception ex)
        {
            Log.Warn($"update-e2e.report-failed {ex.GetType().Name}");
        }

        return results.All(result => result.Ok) ? 0 : 1;
    }

    private static string Quote(string text)
    {
        var escaped = text
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal)
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal);
        return "\"" + escaped + "\"";
    }

    private sealed record ScenarioResult(string Name, bool Ok, string Detail);

    private static ScenarioResult RunScenario(
        string root,
        string name,
        string version,
        byte[] newExe,
        byte[] oldExe,
        bool hashOk,
        bool blockTarget,
        bool includeEntry = true)
    {
        var scenario = Path.Combine(root, name);
        var install = Path.Combine(scenario, "install");
        var downloads = Path.Combine(scenario, "downloads");
        var feed = Path.Combine(scenario, "feed");
        var staging = Path.Combine(scenario, "staging");
        Directory.CreateDirectory(install);
        Directory.CreateDirectory(downloads);
        Directory.CreateDirectory(feed);

        var oldPath = Path.Combine(install, "KittyTools.exe");
        File.WriteAllBytes(oldPath, oldExe);
        var blocked = Path.Combine(install, "KittyTools.Core.dll");
        if (blockTarget)
        {
            Directory.CreateDirectory(blocked);
            File.WriteAllText(Path.Combine(blocked, "keep.txt"), "keep");
        }

        var package = Path.Combine(scenario, "package");
        var entry = Path.Combine(package, "Kitty Tools");
        Directory.CreateDirectory(entry);
        if (includeEntry)
        {
            File.WriteAllBytes(Path.Combine(entry, "KittyTools.exe"), newExe);
        }

        File.WriteAllText(Path.Combine(entry, "KittyTools.Core.dll"), "new-dll");
        var zip = Path.Combine(feed, "KittyTools-" + version + "-windows-x64.zip");
        ZipFile.CreateFromDirectory(package, zip);
        var hash = Path.Combine(feed, Path.GetFileName(zip) + ".sha256");
        File.WriteAllText(
            hash,
            hashOk
                ? $"{UpdateHash.ComputeFile(zip)}  {Path.GetFileName(zip)}\r\n"
                : new string('0', 64));

        try
        {
            var result = UpdateFlow.RunAsync(
                    new UpdatePlan(version, new Uri(zip).AbsoluteUri, new Uri(hash).AbsoluteUri, Path.GetFileName(zip)),
                    downloads,
                    staging,
                    install,
                    UpdateHttp.DownloadAsync,
                    UpdateHttp.GetTextAsync,
                    UpdateFlow.ReadVersion)
                .GetAwaiter()
                .GetResult();

            var detail = result.Ok ? $"installed={result.Installed.Count}" : $"{result.Step}: {result.Error}";
            var installedExe = File.ReadAllBytes(oldPath);
            var untouched = installedExe.AsSpan().EndsWith("OLD"u8);
            var oldSuffix = Path.Combine(install, "KittyTools.exe" + UpdateInstaller.OldSuffix);

            if (name == "success")
            {
                var ok = result.Ok
                         && installedExe.AsSpan().EndsWith("NEW"u8)
                         && File.Exists(oldSuffix)
                         && installedExe.Length > 0;
                return new ScenarioResult(name, ok, detail);
            }

            if (name == "sha256-mismatch")
            {
                var ok = !result.Ok
                         && result.Step == UpdateStep.Hash
                         && untouched
                         && !File.Exists(oldSuffix);
                return new ScenarioResult(name, ok, detail);
            }

            if (name == "blocked-rollback")
            {
                var ok = !result.Ok
                         && result.Step == UpdateStep.Install
                         && untouched
                         && !File.Exists(oldSuffix)
                         && Directory.Exists(blocked)
                         && File.Exists(Path.Combine(blocked, "keep.txt"));
                return new ScenarioResult(name, ok, detail);
            }

            // missing-entry：解压后找不到 KittyTools.exe，旧版本原样。
            var missingOk = !result.Ok && result.Step == UpdateStep.Entry && untouched;
            return new ScenarioResult(name, missingOk, detail);
        }
        catch (Exception ex)
        {
            return new ScenarioResult(name, false, $"{ex.GetType().Name}: {ex.Message}");
        }
    }
}
