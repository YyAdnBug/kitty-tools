// 录屏声音的格式转换（R14 / PLAN-v6 第 2 批）：WASAPI 给的是设备混音格式（可能 44.1 kHz、5.1、16 位），
// 统一转成 48 kHz、双声道、float32，再交给 AudioMixBuffer。48 kHz 双声道时不做重采样。
// 多声道按 PLAN-v6 的 5.1 公式：L = FL + 0.707·C + 0.707·SL，R 对称，LFE 丢掉，再按峰值归一。
// 重采样是线性插值；`// ponytail:` 上限是提示音 / 语音够用，要更好的音质再换系统的 Resampler DSP。
using System.Runtime.InteropServices;

namespace KittyTools.Core;

public sealed class AudioConverter
{
    private readonly int _rate;
    private readonly int _channels;
    private readonly bool _isFloat;
    private readonly int _bits;
    private readonly double _step;
    private float[] _decoded = Array.Empty<float>();
    private float[] _stereo = Array.Empty<float>();
    private float[] _output = Array.Empty<float>();
    private double _next;
    private float _lastLeft;
    private float _lastRight;
    private bool _hasLast;

    public AudioConverter(int sampleRate, int channels, bool isFloat, int bitsPerSample)
    {
        if (sampleRate <= 0 || channels <= 0 || bitsPerSample <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sampleRate));
        }

        _rate = sampleRate;
        _channels = channels;
        _isFloat = isFloat;
        _bits = bitsPerSample;
        _step = (double)sampleRate / AudioRules.SampleRate;
    }

    public int SourceRate => _rate;

    public int SourceChannels => _channels;

    /// <summary>把一段设备格式的包转成 48 kHz 双声道 float32；返回值在下一次调用前有效。</summary>
    public ReadOnlySpan<float> Convert(ReadOnlySpan<byte> data, int frames)
    {
        if (frames <= 0)
        {
            return ReadOnlySpan<float>.Empty;
        }

        if (_isFloat && _bits == 32 && _rate == AudioRules.SampleRate && _channels == AudioRules.Channels)
        {
            // 这台机器上最常见的一条：设备混音格式就是 48 kHz 双声道 float32，不复制。
            var floats = MemoryMarshal.Cast<byte, float>(data);
            var wanted = frames * AudioRules.Channels;
            return floats[..Math.Min(floats.Length, wanted)];
        }

        var source = Decode(data, frames);
        if (source.IsEmpty)
        {
            return ReadOnlySpan<float>.Empty;
        }

        var stereo = _channels == AudioRules.Channels ? source : Downmix(source, frames);
        if (stereo.IsEmpty)
        {
            return ReadOnlySpan<float>.Empty;
        }

        if (_rate == AudioRules.SampleRate)
        {
            return stereo;
        }

        return Resample(stereo, frames);
    }

    private ReadOnlySpan<float> Decode(ReadOnlySpan<byte> data, int frames)
    {
        var samples = frames * _channels;
        EnsureDecoded(samples);
        if (_isFloat && _bits == 32)
        {
            var floats = MemoryMarshal.Cast<byte, float>(data);
            samples = Math.Min(samples, floats.Length);
            floats[..samples].CopyTo(_decoded);
            return _decoded.AsSpan(0, samples);
        }

        if (!_isFloat && _bits == 16)
        {
            var pcm = MemoryMarshal.Cast<byte, short>(data);
            samples = Math.Min(samples, pcm.Length);
            for (var index = 0; index < samples; index++)
            {
                _decoded[index] = pcm[index] / 32768f;
            }

            return _decoded.AsSpan(0, samples);
        }

        if (!_isFloat && _bits == 32)
        {
            var pcm = MemoryMarshal.Cast<byte, int>(data);
            samples = Math.Min(samples, pcm.Length);
            for (var index = 0; index < samples; index++)
            {
                _decoded[index] = pcm[index] / 2147483648f;
            }

            return _decoded.AsSpan(0, samples);
        }

        if (!_isFloat && _bits == 24)
        {
            // 24 位小端：每个采样 3 字节，符号扩展到 int32。
            for (var index = 0; index < samples; index++)
            {
                var offset = index * 3;
                if (offset + 3 > data.Length)
                {
                    samples = index;
                    break;
                }

                var value = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
                if ((value & 0x00800000) != 0)
                {
                    value |= unchecked((int)0xFF000000);
                }

                _decoded[index] = value / 8388608f;
            }

            return _decoded.AsSpan(0, samples);
        }

        return ReadOnlySpan<float>.Empty;
    }

    /// <summary>任意声道数 → 双声道。5.1 按 FL FR FC LFE SL SR 的常见顺序下混。</summary>
    private ReadOnlySpan<float> Downmix(ReadOnlySpan<float> source, int frames)
    {
        var available = source.Length / _channels;
        frames = Math.Min(frames, available);
        EnsureStereo(frames * 2);
        for (var frame = 0; frame < frames; frame++)
        {
            var offset = frame * _channels;
            float left;
            float right;
            if (_channels == 1)
            {
                left = right = source[offset];
            }
            else if (_channels >= 6)
            {
                var frontLeft = source[offset];
                var frontRight = source[offset + 1];
                var center = source[offset + 2];
                var sideLeft = source[offset + 4];
                var sideRight = source[offset + 5];
                left = frontLeft + 0.707f * center + 0.707f * sideLeft;
                right = frontRight + 0.707f * center + 0.707f * sideRight;
            }
            else
            {
                left = source[offset];
                right = source[offset + 1];
            }

            _stereo[frame * 2] = left;
            _stereo[frame * 2 + 1] = right;
        }

        // 相加之后可能超过 1，按这一段的最大值压回去，别让后面的 16 位 PCM 削波。
        var peak = 0f;
        var count = frames * 2;
        for (var index = 0; index < count; index++)
        {
            if (Math.Abs(_stereo[index]) > peak)
            {
                peak = Math.Abs(_stereo[index]);
            }
        }

        if (peak > 1f)
        {
            var scale = 1f / peak;
            for (var index = 0; index < count; index++)
            {
                _stereo[index] *= scale;
            }
        }

        return _stereo.AsSpan(0, count);
    }

    private ReadOnlySpan<float> Resample(ReadOnlySpan<float> source, int frames)
    {
        var available = source.Length / AudioRules.Channels;
        frames = Math.Min(frames, available);
        if (frames <= 0)
        {
            return ReadOnlySpan<float>.Empty;
        }

        // 目标帧数按比例估；输出位置 _next 是相对当前包起点的输入下标（-1 是上一包最后一帧）。
        var estimate = (int)Math.Ceiling((frames - _next) / _step) + 2;
        EnsureOutput(estimate * 2);
        var output = 0;
        while (_next < frames && output < estimate)
        {
            float left;
            float right;
            if (_next < 0)
            {
                var fraction = (float)(_next + 1);
                left = _hasLast ? _lastLeft + (source[0] - _lastLeft) * fraction : source[0];
                right = _hasLast ? _lastRight + (source[1] - _lastRight) * fraction : source[1];
            }
            else
            {
                var index = (int)_next;
                var fraction = (float)(_next - index);
                var current = index * 2;
                var next = Math.Min(index + 1, frames - 1) * 2;
                left = source[current] + (source[next] - source[current]) * fraction;
                right = source[current + 1] + (source[next + 1] - source[current + 1]) * fraction;
            }

            _output[output * 2] = left;
            _output[output * 2 + 1] = right;
            output++;
            _next += _step;
        }

        _lastLeft = source[(frames - 1) * 2];
        _lastRight = source[(frames - 1) * 2 + 1];
        _hasLast = true;
        _next -= frames;
        return _output.AsSpan(0, output * 2);
    }

    private void EnsureDecoded(int samples)
    {
        if (_decoded.Length < samples)
        {
            _decoded = new float[Math.Max(samples, _decoded.Length * 2)];
        }
    }

    private void EnsureStereo(int samples)
    {
        if (_stereo.Length < samples)
        {
            _stereo = new float[Math.Max(samples, _stereo.Length * 2)];
        }
    }

    private void EnsureOutput(int samples)
    {
        if (_output.Length < samples)
        {
            _output = new float[Math.Max(samples, _output.Length * 2)];
        }
    }
}
