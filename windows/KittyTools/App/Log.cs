// 日志：logs\kitty-YYYYMMDD.log，留 7 天。只写事件和错误码，
// 不写剪贴板内容、原文、译文、URL、请求头、密钥。
using System.Globalization;
using System.Text;

namespace KittyTools.Infrastructure;

internal static class Log
{
    private static readonly object Gate = new();
    private static string? _path;

    public static void Initialize()
    {
        try
        {
            Directory.CreateDirectory(Paths.LogsDirectory);
            _path = Path.Combine(Paths.LogsDirectory, $"kitty-{DateTime.Now:yyyyMMdd}.log");
            Cleanup();
            Info("app.start");
        }
        catch
        {
            // 日志写不出来不能影响启动；后面所有写入也会被忽略。
        }
    }

    public static void Info(string message) => Write("INFO", message);

    public static void Warn(string message) => Write("WARN", message);

    public static void Error(string message) => Write("ERROR", message);

    public static void Error(string message, Exception ex)
        => Write("ERROR", $"{message} {ex.GetType().Name} 0x{ex.HResult:X8}");

    private static void Write(string level, string message)
    {
        if (_path is null)
        {
            return;
        }

        try
        {
            var line = $"{DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture)} [{level}] {message}{Environment.NewLine}";
            lock (Gate)
            {
                File.AppendAllText(_path, line, Encoding.UTF8);
            }
        }
        catch
        {
            // 同上，不影响功能。
        }
    }

    private static void Cleanup()
    {
        var cutoff = DateTime.Now.Date.AddDays(-7);
        foreach (var file in Directory.EnumerateFiles(Paths.LogsDirectory, "kitty-*.log"))
        {
            try
            {
                if (Path.GetFileNameWithoutExtension(file) is { } name &&
                    name.Length == "kitty-yyyyMMdd".Length &&
                    DateTime.TryParseExact(name[6..], "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) &&
                    date < cutoff)
                {
                    File.Delete(file);
                }
            }
            catch
            {
                // 某个旧日志删不掉就算了。
            }
        }
    }
}
