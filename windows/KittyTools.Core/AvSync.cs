// REVIEW R24 音画同步量测的纯逻辑：从 PCM 里找 1 kHz 提示音的起点（Goertzel，只认这一个频率，
// 系统声音里别的响动不算），再把视频闪白的起点和提示音逐个配对，给出每一秒的音画差；
// 另外判断测试图案条码读出来的帧号是不是一直在往前走。录屏本身不用它，只给 --sync-probe。
namespace KittyTools.Core;

public static class AvSync
{
    public sealed record Pair(double Flash, double Beep)
    {
        /// <summary>音画差（秒）：正数是声音比画面晚。</summary>
        public double Diff => Beep - Flash;
    }

    public sealed record Summary(
        int Pairs, int Flashes, int Beeps, double First, double Last, double? AfterGap, double MaxAbs, bool Passed);

    /// <summary>
    /// 单声道 PCM 里 <paramref name="frequency"/> 那一声的起点（秒）。10 ms 窗口、2.5 ms 一跳，每个窗口算这个频率的能量
    /// 占总能量的比例 r（Goertzel；纯正弦为 1，宽带噪声接近 0）。r 超过 0.3、而且不是静音，就算在响；别的声音只会把 r
    /// 整体压低，不会把它抬上去。窗口里提示音占的比例约等于 r / 平台值（往后一个窗长里 r 的最大值），
    /// 所以起点按「窗口起点 + 窗长 × (1 − r / 平台值)」往回推，误差在一跳以内。响过之后要隔 300 ms 才认下一声。
    /// </summary>
    public static List<double> ToneOnsets(ReadOnlySpan<float> mono, int sampleRate, double frequency = 1000)
    {
        var window = sampleRate / 100;
        var hop = Math.Max(1, window / 4);
        var count = mono.Length < window ? 0 : (mono.Length - window) / hop + 1;
        var ratios = new double[count];
        var loud = new bool[count];
        var coefficient = 2 * Math.Cos(2 * Math.PI * frequency / sampleRate);
        for (var step = 0; step < count; step++)
        {
            double previous = 0;
            double older = 0;
            double energy = 0;
            for (var index = 0; index < window; index++)
            {
                double sample = mono[step * hop + index];
                energy += sample * sample;
                var current = sample + coefficient * previous - older;
                older = previous;
                previous = current;
            }

            var power = previous * previous + older * older - coefficient * previous * older;
            ratios[step] = energy <= 1e-12 ? 0 : power / (window / 2.0 * energy);
            loud[step] = ratios[step] > 0.3 && Math.Sqrt(energy / window) > 0.003;
        }

        var onsets = new List<double>();
        var quiet = sampleRate * 3 / 10;
        int? lastLoud = null;
        for (var step = 0; step < count; step++)
        {
            if (!loud[step])
            {
                continue;
            }

            var start = step * hop;
            if (lastLoud is null || start - lastLoud.Value > quiet)
            {
                var plateau = ratios[step];
                for (var ahead = step + 1; ahead < Math.Min(count, step + window / hop + 1); ahead++)
                {
                    plateau = Math.Max(plateau, ratios[ahead]);
                }

                onsets.Add((start + window * (1 - Math.Min(1, ratios[step] / plateau))) / sampleRate);
            }

            lastLoud = start;
        }

        return onsets;
    }

    /// <summary>每个闪白配离它最近的一声；±<paramref name="maxGap"/> 里没有就跳过（那一秒丢了声音或画面）。</summary>
    public static List<Pair> PairUp(IReadOnlyList<double> flashes, IReadOnlyList<double> beeps, double maxGap = 0.5)
    {
        var pairs = new List<Pair>();
        foreach (var flash in flashes)
        {
            double? best = null;
            foreach (var beep in beeps)
            {
                var gap = Math.Abs(beep - flash);
                if (gap <= maxGap && (best is null || gap < Math.Abs(best.Value - flash)))
                {
                    best = beep;
                }
            }

            if (best is { } match)
            {
                pairs.Add(new Pair(flash, match));
            }
        }

        return pairs;
    }

    /// <summary>
    /// 第一对、最后一对、静音段之后的第一对（和上一声隔了 5 s 以上）的音画差和最大偏差。
    /// 配上的对数不少于闪白 / 提示音里少的那边的 90%，而且每一对的 |差| 都小于 <paramref name="limit"/>，才算过。
    /// </summary>
    public static Summary Summarize(IReadOnlyList<Pair> pairs, int flashes, int beeps, double limit = 0.05)
    {
        if (pairs.Count == 0)
        {
            return new Summary(0, flashes, beeps, 0, 0, null, 0, false);
        }

        double? afterGap = null;
        for (var index = 1; index < pairs.Count; index++)
        {
            if (pairs[index].Beep - pairs[index - 1].Beep > 5)
            {
                afterGap = pairs[index].Diff;
                break;
            }
        }

        var maxAbs = pairs.Max(pair => Math.Abs(pair.Diff));
        var enough = pairs.Count >= Math.Min(flashes, beeps) * 0.9;
        return new Summary(
            pairs.Count, flashes, beeps, pairs[0].Diff, pairs[^1].Diff, afterGap, maxAbs, enough && maxAbs < limit);
    }

    /// <summary>
    /// 连着抽的几帧读出来的条码（测试图案的更新计数）：每一步往前走 1–2，原地不动的不超过五分之一，
    /// 才算录下来的画面一直在更新。整段补帧（WGC 只收到 1 帧）时全是 0 步，会判不过。
    /// </summary>
    public static bool Continuous(IReadOnlyList<int> numbers)
    {
        if (numbers.Count < 2)
        {
            return false;
        }

        var stalls = 0;
        for (var index = 1; index < numbers.Count; index++)
        {
            var step = numbers[index] - numbers[index - 1];
            if (step == 0)
            {
                stalls++;
            }
            else if (step < 0 || step > 2)
            {
                return false;
            }
        }

        return stalls * 5 <= numbers.Count;
    }
}
