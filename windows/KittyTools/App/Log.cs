// 日志：logs\kitty-YYYYMMDD.log，留 7 天。只写事件和错误码，
// 不写剪贴板内容、原文、译文、URL、请求头、密钥。
using System.Globalization;
using System.Text;

namespace KittyTools.Infrastructure;

internal static class Log
{
    private static readonly object Gate = new();

    /// <summary>
    /// 常驻的那个文件（REVIEW R50：以前每行都 File.AppendAllText，在调用方的线程上开、写、关一次，装了杀毒软件的机器上每次几毫秒）。
    /// AutoFlush：每行都交给系统，闪退也不丢；文件共享读写删，开着时照样能看、能清。
    /// ponytail: 还是在调用方的线程上写（一行几微秒）；量出来还卡再换成后台队列。
    /// </summary>
    private static StreamWriter? _writer;

    /// <summary>_writer 是哪一天的文件：写之前看一眼，跨天就换新文件、顺手清 7 天前的（常驻托盘几周不重启也会换）。</summary>
    private static DateTime _day;

    private static bool _enabled;

    public static void Initialize()
    {
        try
        {
            Directory.CreateDirectory(Paths.LogsDirectory);
            lock (Gate)
            {
                _enabled = true;
                Open(DateTime.Now.Date);
            }

            Info("app.start");
        }
        catch
        {
            // 日志写不出来不能影响启动；后面的写入会再试着打开。
        }
    }

    public static void Info(string message) => Write("INFO", message);

    /// <summary>卸载前不再写日志、关掉文件，免得数据目录被挪走时日志还开着（REVIEW R25）。</summary>
    public static void Shutdown()
    {
        lock (Gate)
        {
            _enabled = false;
            _writer?.Dispose();
            _writer = null;
        }
    }

    public static void Warn(string message) => Write("WARN", message);

    public static void Error(string message) => Write("ERROR", message);

    public static void Error(string message, Exception ex)
        => Write("ERROR", $"{message} {ex.GetType().Name} 0x{ex.HResult:X8}");

    private static void Write(string level, string message)
    {
        try
        {
            var now = DateTime.Now;
            var line = $"{now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture)} [{level}] {message}{Environment.NewLine}";
            lock (Gate)
            {
                if (!_enabled)
                {
                    return;
                }

                if (_writer is null || now.Date != _day)
                {
                    Open(now.Date);
                }

                _writer!.Write(line);
            }
        }
        catch
        {
            // 同上，不影响功能。
        }
    }

    /// <summary>换到 day 那一天的文件（在 Gate 里调）。</summary>
    private static void Open(DateTime day)
    {
        _writer?.Dispose();
        _writer = null;
        var path = Path.Combine(Paths.LogsDirectory, $"kitty-{day:yyyyMMdd}.log");
        var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        _writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
        _day = day;
        Cleanup();
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
