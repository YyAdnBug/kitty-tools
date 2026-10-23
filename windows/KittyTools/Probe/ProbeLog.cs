// 第 0 批的测量日志：一行一个 JSON 对象，带 QPC 绝对时间戳（Stopwatch 刻度，
// 跨进程可比），供外部脚本算「按键到窗口出现」之类的耗时。只记事件和数字，
// 不记剪贴板内容、原文、译文、URL。
using System.Diagnostics;
using System.Text;

namespace KittyTools;

internal static class ProbeLog
{
    private static readonly object Gate = new();
    private static string? _path;

    public static string? Path => _path;

    public static void Init(string? directory = null)
    {
        directory ??= Environment.GetEnvironmentVariable("KITTY_PROBE_DIR");
        if (string.IsNullOrWhiteSpace(directory))
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            directory = System.IO.Path.Combine(local, "KittyTools.Dev", "logs");
        }

        Directory.CreateDirectory(directory);
        _path = System.IO.Path.Combine(directory, $"probe-{DateTime.Now:yyyyMMdd-HHmmss}.jsonl");
    }

    public static void Write(string evt, params (string Key, object? Value)[] fields)
    {
        if (_path is null)
        {
            return;
        }

        var sb = new StringBuilder(160);
        sb.Append('{');
        AppendPair(sb, "t", Stopwatch.GetTimestamp());
        sb.Append(',');
        AppendPair(sb, "evt", evt);
        foreach (var (key, value) in fields)
        {
            sb.Append(',');
            AppendPair(sb, key, value);
        }
        sb.Append('}');

        lock (Gate)
        {
            File.AppendAllText(_path, sb.ToString() + Environment.NewLine);
        }
    }

    private static void AppendPair(StringBuilder sb, string key, object? value)
    {
        sb.Append('"').Append(Escape(key)).Append("\":");
        switch (value)
        {
            case null:
                sb.Append("null");
                break;
            case bool b:
                sb.Append(b ? "true" : "false");
                break;
            case int or long or uint or ulong or short or ushort or double or float or decimal:
                sb.Append(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture));
                break;
            default:
                sb.Append('"').Append(Escape(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty)).Append('"');
                break;
        }
    }

    private static string Escape(string s)
    {
        if (s.AsSpan().IndexOfAny("\"\\\n\r") < 0)
        {
            return s;
        }

        var sb = new StringBuilder(s.Length + 8);
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }
}
