// REVIEW R24：提示音只认 1 kHz（别的声音不算）、起点误差在几毫秒以内；配对和条码连续性的判断。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AvSyncTests
{
    private const int Rate = 48_000;

    [TestMethod]
    public void FindsOnlyTheOneKilohertzBeeps()
    {
        var samples = new float[Rate * 3];
        var random = new Random(1);
        for (var index = 0; index < samples.Length; index++)
        {
            samples[index] = (float)((random.NextDouble() - 0.5) * 0.01);
        }

        // 0.2–0.4 s 一段很响的 440 Hz（系统声音里别的响动），不能当成提示音。
        AddTone(samples, 0.2, 0.2, 440, 0.6);
        var expected = new[] { 0.5137, 1.5, 2.5021 };
        foreach (var start in expected)
        {
            AddTone(samples, start, 0.1, 1000, 0.45);
        }

        var onsets = AvSync.ToneOnsets(samples, Rate);
        Assert.AreEqual(expected.Length, onsets.Count, string.Join(",", onsets));
        for (var index = 0; index < expected.Length; index++)
        {
            Assert.IsTrue(
                Math.Abs(onsets[index] - expected[index]) < 0.004,
                $"{index}: {onsets[index]:F4} vs {expected[index]:F4}");
        }
    }

    [TestMethod]
    public void PairsAndSummarizesWithSilenceGap()
    {
        // 0–19 s 每秒一对，声音晚 12 ms；20–39 s 静音没有提示音也不闪；40–59 s 声音晚 30 ms。
        var flashes = new List<double>();
        var beeps = new List<double>();
        for (var second = 0; second < 60; second++)
        {
            if (second is >= 20 and < 40)
            {
                continue;
            }

            flashes.Add(second + 0.1);
            beeps.Add(second + 0.1 + (second < 20 ? 0.012 : 0.030));
        }

        var pairs = AvSync.PairUp(flashes, beeps);
        var summary = AvSync.Summarize(pairs, flashes.Count, beeps.Count);
        Assert.AreEqual(40, summary.Pairs);
        Assert.AreEqual(0.012, summary.First, 1e-9);
        Assert.AreEqual(0.030, summary.Last, 1e-9);
        Assert.AreEqual(0.030, summary.AfterGap ?? double.NaN, 1e-9);
        Assert.IsTrue(summary.Passed);

        // 有一对差 80 ms 就不过；少一大半提示音也不过。
        beeps[5] += 0.068;
        Assert.IsFalse(AvSync.Summarize(AvSync.PairUp(flashes, beeps), flashes.Count, beeps.Count).Passed);
        var fewBeeps = beeps.Take(10).ToList();
        Assert.IsFalse(AvSync.Summarize(AvSync.PairUp(flashes, fewBeeps), flashes.Count, 40).Passed);
    }

    [TestMethod]
    public void BarcodeMustKeepMoving()
    {
        Assert.IsTrue(AvSync.Continuous(new[] { 30, 31, 32, 33, 35, 36, 36, 37, 38, 39 }));
        Assert.IsFalse(AvSync.Continuous(new[] { 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }));
        Assert.IsFalse(AvSync.Continuous(new[] { 30, 31, 40, 41 }));
        Assert.IsFalse(AvSync.Continuous(new[] { 30, 29 }));
        Assert.IsFalse(AvSync.Continuous(new[] { 30 }));
    }

    private static void AddTone(float[] samples, double start, double length, double frequency, double amplitude)
    {
        var first = (int)Math.Round(start * Rate);
        var count = (int)Math.Round(length * Rate);
        for (var index = 0; index < count && first + index < samples.Length; index++)
        {
            samples[first + index] += (float)(amplitude * Math.Sin(2 * Math.PI * frequency * index / Rate));
        }
    }
}
