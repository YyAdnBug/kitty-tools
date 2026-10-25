// 录屏的纯规则（第四版，配单测）：宽高偶数、帧率范围、文件名、临时文件、剩余空间。
// 这一版输出 MJPEG 的 AVI（Windows 自带解码器能播），不是 PLAN 里的 H.264 MP4——原因见报告。
using System.Globalization;

namespace KittyTools.Core;

public readonly record struct RecordSize(int Width, int Height);

public static class RecorderRules
{
    public const int DefaultFps = 15;

    public const int MaxFps = 60;

    public const int MinFps = 5;

    public static RecordSize Even(int width, int height)
        => new(Math.Max(2, width & ~1), Math.Max(2, height & ~1));

    public static string FileName(DateTime now, bool audio = false)
        => (audio ? "录音 " : "录屏 ")
           + now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture)
           + (audio ? ".m4a" : ".avi");

    /// <summary>临时文件放在同一个卷上，录完再改名；扩展名必须是 .avi（播放器 / 资源管理器认它）。</summary>
    public static string TemporaryPath(string folder)
    {
        var full = Path.GetFullPath(folder);
        var root = Path.GetPathRoot(full) ?? folder;
        return Path.Combine(root, "." + Guid.NewGuid().ToString("N") + ".kitty.tmp.avi");
    }

    public static bool HasRoom(long freeBytes) => freeBytes >= 1L << 30;

    public static string Duration(long milliseconds)
    {
        var span = TimeSpan.FromMilliseconds(Math.Max(0, milliseconds));
        return $"{(int)span.TotalMinutes}:{span.Seconds:00}";
    }
}
