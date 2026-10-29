// 录屏的纯规则（PLAN-v6 第 3 批起）：宽高偶数、帧率范围、文件名、临时文件、剩余空间；
// 帧率只给 30 / 60、默认 30，录音的来源（PLAN-v9 V3、V5，同 mac）。
// 录屏输出 H.264 MP4；录音输出 M4A。
using System.Globalization;

namespace KittyTools.Core;

public readonly record struct RecordSize(int Width, int Height);

public static class RecorderRules
{
    /// <summary>录屏帧率默认 30（PLAN-v9 V3，同 mac；以前是 15 / 30、默认 15）。</summary>
    public const int DefaultFps = 30;

    public const int MaxFps = 60;

    public const int MinFps = 5;

    public static RecordSize Even(int width, int height)
        => new(Math.Max(2, width & ~1), Math.Max(2, height & ~1));

    public static string FileName(DateTime now, bool audio = false)
        => (audio ? "录音 " : "录屏 ")
           + now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture)
           + (audio ? ".m4a" : ".mp4");

    /// <summary>临时文件放在同一个卷上，录完再改名；扩展名必须是 .mp4。</summary>
    public static string TemporaryPath(string folder)
    {
        var full = Path.GetFullPath(folder);
        var root = Path.GetPathRoot(full) ?? folder;
        return Path.Combine(root, "." + Guid.NewGuid().ToString("N") + ".kitty.tmp.mp4");
    }

    public static bool HasRoom(long freeBytes) => freeBytes >= 1L << 30;

    /// <summary>设置里只有 30 / 60：存着的别的值（以前的 15）读成 30。</summary>
    public static int NormalizeFps(int fps) => fps >= 60 ? 60 : 30;

    /// <summary>录音录什么（PLAN-v9 V5，同 mac AudioRecorder.Source）：microphone（默认）/ system / both，认不出的按麦克风。</summary>
    public static (bool SystemAudio, bool Microphone) AudioSource(string? source) => source switch
    {
        "system" => (true, false),
        "both" => (true, true),
        _ => (false, true),
    };

    public static string Duration(long milliseconds)
    {
        var span = TimeSpan.FromMilliseconds(Math.Max(0, milliseconds));
        return $"{(int)span.TotalMinutes}:{span.Seconds:00}";
    }
}
