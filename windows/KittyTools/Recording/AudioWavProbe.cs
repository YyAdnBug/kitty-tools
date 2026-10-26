// 调试用：把录好的 MP4 的音轨用 MediaTranscoder 转成 WAV，再读 PCM 算峰值和 1 kHz 提示音的间隔。
// 只验证「文件里的 AAC 真的能解出声音、间隔还是 1 秒」，不参与录屏。--media-check=<文件> 时调用。
using KittyTools.Infrastructure;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace KittyTools;

internal static class AudioWavProbe
{
    public sealed record Result(
        float Peak, int Bursts, int Frames, double MinGap, double MaxGap, string? Error);

    public static async Task<Result> CheckAsync(string path)
    {
        string? temporary = null;
        try
        {
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
            temporary = Path.Combine(
                Path.GetDirectoryName(path)!, "audio-check-" + Guid.NewGuid().ToString("N") + ".wav");
            var target = await folder.CreateFileAsync(
                Path.GetFileName(temporary), CreationCollisionOption.ReplaceExisting);
            var profile = MediaEncodingProfile.CreateWav(AudioEncodingQuality.High);
            profile.Audio = AudioEncodingProperties.CreatePcm(48_000, 2, 16);
            var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = false };
            var prepared = await transcoder.PrepareFileTranscodeAsync(
                await StorageFile.GetFileFromPathAsync(path), target, profile);
            if (!prepared.CanTranscode)
            {
                return new Result(0, 0, 0, 0, 0, "转 WAV 被拒绝：" + prepared.FailureReason);
            }

            await prepared.TranscodeAsync().AsTask();
            var bytes = await File.ReadAllBytesAsync(temporary);
            var result = ReadWav(bytes);
            Log.Info(
                $"audio.check peak={result.Peak:F3} bursts={result.Bursts} frames={result.Frames} " +
                $"gap={result.MinGap:F3}-{result.MaxGap:F3}s error={result.Error ?? "-"}");
            return result;
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.check-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return new Result(0, 0, 0, 0, 0, ex.GetType().Name);
        }
        finally
        {
            try
            {
                if (temporary is not null && File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch
            {
                // 临时文件删不掉不影响结果。
            }
        }
    }

    /// <summary>按 WAV 的位数 / 格式读一个样本，统一成 -1..1 的浮点。</summary>
    private static float ReadSample(byte[] bytes, int offset, int bits, bool isFloat)
    {
        if (bits == 16)
        {
            return BitConverter.ToInt16(bytes, offset) / 32768f;
        }

        if (bits == 24)
        {
            var value = bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
            if ((value & 0x00800000) != 0)
            {
                value |= unchecked((int)0xFF000000);
            }

            return value / 8388608f;
        }

        if (bits == 32)
        {
            return isFloat
                ? BitConverter.ToSingle(bytes, offset)
                : BitConverter.ToInt32(bytes, offset) / 2147483648f;
        }

        return 0f;
    }

    /// <summary>
    /// 读 WAV：fmt 里取声道 / 位数 / 浮点标记；按 10 ms 一段算峰值，超过 0.1 算提示音，
    /// 回落到 0.03 以下结束一段，再算相邻两段起点之间的间隔。
    /// </summary>
    private static Result ReadWav(byte[] bytes)
    {
        if (bytes.Length < 44 ||
            bytes[0] != (byte)'R' || bytes[1] != (byte)'I' ||
            bytes[2] != (byte)'F' || bytes[3] != (byte)'F')
        {
            return new Result(0, 0, 0, 0, 0, "不是 WAV");
        }

        var channels = 0;
        var bits = 0;
        var formatTag = 0;
        var isFloat = false;
        var dataOffset = -1;
        var dataLength = 0;
        var offset = 12;
        while (offset + 8 <= bytes.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(bytes, offset, 4);
            var length = BitConverter.ToInt32(bytes, offset + 4);
            var body = offset + 8;
            if (length < 0 || body + length > bytes.Length)
            {
                break;
            }

            if (id == "fmt ")
            {
                formatTag = BitConverter.ToInt16(bytes, body);
                channels = BitConverter.ToInt16(bytes, body + 2);
                bits = BitConverter.ToInt16(bytes, body + 14);
                isFloat = formatTag == 3 ||
                    (formatTag == 0xFFFE && bits == 32 &&
                     BitConverter.ToInt32(bytes, body + 24) == 3);
            }
            else if (id == "data")
            {
                dataOffset = body;
                dataLength = length;
                break;
            }

            offset = body + length + (length & 1);
        }

        if (dataOffset < 0 || channels <= 0 || bits <= 0)
        {
            return new Result(0, 0, 0, 0, 0, "没有 data / fmt");
        }

        Log.Info(
            $"audio.wav tag={formatTag} ch={channels} bits={bits} float={isFloat} " +
            $"data={dataLength} rate=48000");

        var bytesPerSample = Math.Max(1, bits / 8);
        var samples = dataLength / bytesPerSample;
        var frames = samples / channels;
        var peak = 0f;
        var starts = new List<int>();
        var inside = false;
        const int window = 480; // 10 ms
        var frame = 0;
        for (var start = 0; start + window * channels <= samples; start += window * channels, frame += window)
        {
            var windowPeak = 0f;
            for (var index = start; index < start + window * channels; index++)
            {
                var value = ReadSample(
                    bytes, dataOffset + index * bytesPerSample, bits, isFloat);
                if (Math.Abs(value) > windowPeak)
                {
                    windowPeak = Math.Abs(value);
                }
            }

            if (windowPeak > peak)
            {
                peak = windowPeak;
            }


            if (windowPeak > 0.25f && !inside)
            {
                starts.Add(frame);
                inside = true;
            }
            else if (windowPeak <= 0.08f)
            {
                inside = false;
            }
        }

        var minGap = 0.0;
        var maxGap = 0.0;
        if (starts.Count > 1)
        {
            minGap = double.MaxValue;
            for (var index = 1; index < starts.Count; index++)
            {
                var gap = (starts[index] - starts[index - 1]) / 48_000.0;
                if (gap < minGap)
                {
                    minGap = gap;
                }

                if (gap > maxGap)
                {
                    maxGap = gap;
                }
            }
        }

        Log.Info("audio.starts " + string.Join(
            ',', starts.Take(24).Select(frame => (frame / 48_000.0).ToString("F3"))));
        return new Result(peak, starts.Count, frames, minGap, maxGap, null);
    }
}
