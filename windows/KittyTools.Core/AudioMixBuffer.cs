// 录屏声音的混音缓冲（R14）：系统声音回环和麦克风各按自己的 QPC 时间戳写进来，按帧号相加、限幅，
// 再按视频时间线取出一段 16 位 PCM 交给 SinkWriter。只在录屏的那个线程上用，不加锁。
// 环形缓冲默认 10 秒；系统声音 / 麦克风晚到时写进已经交出去的那一段会被忽略（宁缺一声，不把整段音画拖回去）。
using System.Buffers.Binary;

namespace KittyTools.Core;

public sealed class AudioMixBuffer
{
    private readonly float[] _samples;
    private readonly int _capacity;

    public AudioMixBuffer(int capacityFrames = AudioRules.SampleRate * 10)
    {
        if (capacityFrames < AudioRules.SampleRate)
        {
            throw new ArgumentOutOfRangeException(nameof(capacityFrames));
        }

        _capacity = capacityFrames;
        _samples = new float[capacityFrames * AudioRules.Channels];
    }

    /// <summary>已经交给编码器的下一帧（绝对帧号）。</summary>
    public long Flushed { get; private set; }

    /// <summary>写进来的最远一帧（绝对帧号，不含）。</summary>
    public long Written { get; private set; }

    /// <summary>取出过的混音里最大的绝对值（0–1），给录屏探针判断到底有没有声音。</summary>
    public float Peak { get; private set; }

    public int CapacityFrames => _capacity;

    /// <summary>
    /// 把一段双声道浮点样本加到 <paramref name="frame"/> 开始的帧上。返回 false 表示这一段
    /// 比缓冲还靠后（时间戳跳了），调用方可以记一次日志再丢掉。
    /// </summary>
    public bool Add(long frame, ReadOnlySpan<float> stereo)
    {
        var frames = stereo.Length / AudioRules.Channels;
        if (frames == 0)
        {
            return true;
        }

        if (frame + frames <= Flushed)
        {
            return true;
        }

        var last = frame + frames;
        if (last - Flushed > _capacity)
        {
            return false;
        }

        for (var index = 0; index < frames; index++)
        {
            var at = frame + index;
            if (at < Flushed)
            {
                continue;
            }

            var offset = (int)(at % _capacity) * AudioRules.Channels;
            _samples[offset] += stereo[index * AudioRules.Channels];
            _samples[offset + 1] += stereo[index * AudioRules.Channels + 1];
        }

        if (last > Written)
        {
            Written = last;
        }

        return true;
    }

    /// <summary>
    /// 取出 <see cref="Flushed"/> 到 <paramref name="until"/>（不含）之间的混音，写进
    /// <paramref name="destination"/>，最多 <paramref name="maxFrames"/> 帧。没写过的帧就是静音。
    /// </summary>
    public int DrainPcm16(long until, Span<byte> destination, int maxFrames)
    {
        var wanted = until - Flushed;
        if (wanted <= 0)
        {
            return 0;
        }

        var frames = (int)Math.Min(wanted, maxFrames);
        frames = Math.Min(frames, destination.Length / AudioRules.PcmBlockAlign);
        for (var index = 0; index < frames; index++)
        {
            var offset = (int)((Flushed + index) % _capacity) * AudioRules.Channels;
            var leftSample = _samples[offset];
            var rightSample = _samples[offset + 1];
            if (float.IsFinite(leftSample) && Math.Abs(leftSample) > Peak)
            {
                Peak = Math.Abs(leftSample);
            }

            if (float.IsFinite(rightSample) && Math.Abs(rightSample) > Peak)
            {
                Peak = Math.Abs(rightSample);
            }

            var left = AudioRules.ToPcm16(leftSample);
            var right = AudioRules.ToPcm16(rightSample);
            _samples[offset] = 0;
            _samples[offset + 1] = 0;
            var target = index * AudioRules.PcmBlockAlign;
            BinaryPrimitives.WriteInt16LittleEndian(destination[target..], left);
            BinaryPrimitives.WriteInt16LittleEndian(destination[(target + 2)..], right);
        }

        Flushed += frames;
        return frames;
    }
}
