// 崩溃记录（PLAN-v6 第 7 批）：三个入口（Application / AppDomain / TaskScheduler）都写 logs\crash-<时间>.log；
// 只写版本、系统版本、异常类型 / 堆栈，不写剪贴板、原文、URL、请求头、密钥。
// 下次启动发现有新的崩溃记录，弹一次轻提示。
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class CrashLog
{
    private static readonly object Gate = new();
    private static DateTime _lastSeen;

    public static void Record(string stage, Exception? exception)
    {
        try
        {
            Directory.CreateDirectory(Paths.LogsDirectory);
            var path = Path.Combine(
                Paths.LogsDirectory, $"crash-{DateTime.Now:yyyyMMdd-HHmmss}.log");
            var text = $"""
                time: {DateTime.Now:O}
                stage: {stage}
                version: {typeof(CrashLog).Assembly.GetName().Version}
                os: {Environment.OSVersion.VersionString}
                exception: {exception?.GetType().FullName ?? "(null)"}
                message: {exception?.Message}
                stack:
                {exception?.StackTrace}
                """;
            lock (Gate)
            {
                File.WriteAllText(path, text, System.Text.Encoding.UTF8);
            }

            Log.Error($"crash.recorded {stage} {exception?.GetType().Name}");
        }
        catch
        {
            // 崩溃日志写不出来不能影响退出。
        }
    }

    /// <summary>启动时检查：比上次看到的新崩溃就提示一次（标记存在 logs\crash-seen 里）。</summary>
    public static void CheckOnStartup()
    {
        try
        {
            Directory.CreateDirectory(Paths.LogsDirectory);
            var seenPath = Path.Combine(Paths.LogsDirectory, "crash-seen");
            _lastSeen = File.Exists(seenPath) && DateTime.TryParse(File.ReadAllText(seenPath), out var parsed)
                ? parsed
                : DateTime.MinValue;
            var latest = Directory.EnumerateFiles(Paths.LogsDirectory, "crash-*.log")
                .Select(path => new FileInfo(path))
                .OrderByDescending(info => info.LastWriteTimeUtc)
                .FirstOrDefault();
            if (latest is null || latest.LastWriteTimeUtc <= _lastSeen)
            {
                return;
            }

            File.WriteAllText(seenPath, DateTime.Now.ToString("O"), System.Text.Encoding.UTF8);
            NoticeHost.Show(
                "上次意外退出了", "记录在 logs 文件夹（crash-*.log）", NoticeTone.Warning);
        }
        catch (Exception ex)
        {
            Log.Warn($"crash.check-failed {ex.GetType().Name}");
        }
    }

    private static void OpenFolder(string folder)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "\"" + folder + "\"",
                UseShellExecute = true,
            });
        }
        catch
        {
            // 打不开就算了。
        }
    }
}
