// 录屏声音的纯函数（R14）：时间戳 → 48 kHz 帧号、浮点混音 → 16 位 PCM 的限幅与取整。
// 采集和编码都在 KittyTools 里；这里只放能单测的算术，AOT 下没有反射 / 动态。
using System.Buffers.Binary;
using System.Diagnostics;

namespace KittyTools.Core;

public static class AudioRules
{
    /// <summary>录屏音轨统一用 48 kHz、双声道、16 位 PCM（AAC 编码前的输入）。</summary>
    public const int SampleRate = 48_000;

    public const int Channels = 2;

    public const int PcmBlockAlign = Channels * 2;

    public const int PcmBytesPerSecond = SampleRate * PcmBlockAlign;

    /// <summary>10 毫秒写一包；AAC 编码器和 SinkWriter 都接受。</summary>
    public const int ChunkFrames = SampleRate / 100;

    /// <summary>WASAPI 的 QPC 位置是 100 纳秒，转成 48 kHz 的绝对帧号；早于起点的一律算第 0 帧。</summary>
    public static long FramesAt(long qpc100Ns, long start100Ns)
    {
        var delta = qpc100Ns - start100Ns;
        return delta <= 0 ? 0 : delta * SampleRate / 10_000_000;
    }

    /// <summary>当前的 QPC，换成 100 纳秒（和 WASAPI 的 pu64QPCPosition 同一个时钟）。</summary>
    public static long Now100Ns()
        => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));

    /// <summary>浮点样本 → 16 位 PCM，先限幅到 [-1, 1]，负半轴 -32768、正半轴 32767。</summary>
    public static short ToPcm16(float sample)
    {
        var value = float.IsNaN(sample) ? 0 : Math.Clamp(sample, -1f, 1f);
        if (value <= -1f)
        {
            return -32768;
        }

        if (value >= 1f)
        {
            return 32767;
        }

        var scaled = MathF.Round(value * (value < 0 ? 32768f : 32767f), MidpointRounding.AwayFromZero);
        return (short)scaled;
    }

    /// <summary>把双声道浮点样本写成小端 16 位 PCM。</summary>
    public static void WritePcm16(ReadOnlySpan<float> interleaved, Span<byte> destination)
    {
        var frames = Math.Min(interleaved.Length / Channels, destination.Length / PcmBlockAlign);
        for (var frame = 0; frame < frames; frame++)
        {
            var offset = frame * PcmBlockAlign;
            BinaryPrimitives.WriteInt16LittleEndian(
                destination[offset..], ToPcm16(interleaved[frame * Channels]));
            BinaryPrimitives.WriteInt16LittleEndian(
                destination[(offset + 2)..], ToPcm16(interleaved[frame * Channels + 1]));
        }
    }
}
