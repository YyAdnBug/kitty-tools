// 录屏管线的纯规则（PLAN-v6 第 1 批，配单测）：码率、帧率上限、没新帧时补帧的时间点、裁剪矩形。
// 只放算术，不碰 D3D / WinRT，AOT 下没有反射。
using System.Diagnostics;

namespace KittyTools.Core;

public static class RecordingPipeline
{
    /// <summary>码率 = 像素数 × 帧率 × 0.07 bit，下限 1 Mbps、上限 20 Mbps（PLAN-v6 §1 第 1 批）。</summary>
    public const uint MaxBitrate = 20_000_000;

    public const uint MinBitrate = 1_000_000;

    /// <summary>超过 1 秒没有新帧，就把上一张纹理再写一帧。</summary>
    public const long RepeatAfter100Ns = 10_000_000;

    /// <summary>当前 QPC 时刻（100 ns），和 WGC 的 SystemRelativeTime 同一个时钟。</summary>
    public static long Now100Ns()
        => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));

    public static uint BitrateFor(int width, int height, int fps)
    {
        var pixels = (double)Math.Max(2, width) * Math.Max(2, height);
        var bitrate = pixels * Math.Max(1, fps) * 0.07;
        return (uint)Math.Clamp(bitrate, MinBitrate, MaxBitrate);
    }

    /// <summary>帧率是上限：两帧间隔不到 1/fps 的丢掉。</summary>
    public static bool ShouldAccept(long frameTime, long lastAccepted, int fps)
    {
        if (lastAccepted == long.MinValue)
        {
            return true;
        }

        return frameTime - lastAccepted >= 10_000_000L / Math.Max(1, fps);
    }

    /// <summary>停止收帧后，下一帧的补帧时刻（不早于 <paramref name="time"/>）。</summary>
    public static long NextRepeat(long lastTime, int fps)
        => lastTime + 10_000_000L / Math.Max(1, fps);

    /// <summary>按「宽高取偶数、至少 2」返回输出尺寸。</summary>
    public static (int Width, int Height) EvenSize(int width, int height)
        => (Math.Max(2, width & ~1), Math.Max(2, height & ~1));

    /// <summary>把全局坐标里的选区裁到显示器内，返回相对显示器左上角的矩形；裁不出来返回 null。</summary>
    public static (int Left, int Top, int Right, int Bottom)? Crop(
        int regionLeft, int regionTop, int regionRight, int regionBottom,
        int monitorLeft, int monitorTop, int monitorRight, int monitorBottom)
    {
        var left = Math.Max(regionLeft, monitorLeft);
        var top = Math.Max(regionTop, monitorTop);
        var right = Math.Min(regionRight, monitorRight);
        var bottom = Math.Min(regionBottom, monitorBottom);
        if (right - left < 2 || bottom - top < 2)
        {
            return null;
        }

        return (left - monitorLeft, top - monitorTop, right - monitorLeft, bottom - monitorTop);
    }
}
