// 合并引擎的性质测试：交换律 / 幂等 / 结合律 + 随机三台的收敛。纯 Core，跑得快。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncMergePropertyTests
{
    private static SyncFile File(params SyncRecord[] records) => new() { Kind = "clips", Records = records.ToList() };

    private static SyncFile FileWithErased(SyncRecord[] records, params SyncErased[] erased)
        => new() { Kind = "clips", Records = records.ToList(), Erased = erased.ToList() };

    private static void AssertSame(SyncFile expected, SyncFile actual)
    {
        Assert.AreEqual(expected.Records.Count, actual.Records.Count);
        foreach (var pair in expected.Records.OrderBy(item => item.Id).Zip(actual.Records.OrderBy(item => item.Id)))
        {
            Assert.AreEqual(pair.First.Id, pair.Second.Id);
            Assert.AreEqual(pair.First.Clock.Text(), pair.Second.Clock.Text());
            Assert.AreEqual(pair.First.Value, pair.Second.Value);
        }

        Assert.AreEqual(expected.Erased.Count, actual.Erased.Count);
        foreach (var pair in expected.Erased.OrderBy(item => item.Id).Zip(actual.Erased.OrderBy(item => item.Id)))
        {
            Assert.AreEqual(pair.First.Id, pair.Second.Id);
            Assert.AreEqual(pair.First.Clock.Text(), pair.Second.Clock.Text());
        }
    }

    [TestMethod]
    public void MergeIsCommutativeAndIdempotent()
    {
        var a = File(
            new SyncRecord { Id = "x", Clock = SyncClock.Parse("A:1"), Modified = 10, Value = "a" },
            new SyncRecord { Id = "y", Clock = SyncClock.Parse("A:2"), Modified = 20, Value = "old" });
        var b = File(
            new SyncRecord { Id = "y", Clock = SyncClock.Parse("B:3"), Modified = 30, Value = "new" },
            new SyncRecord { Id = "z", Clock = SyncClock.Parse("B:1"), Modified = 5, Value = "b" });
        var ab = SyncMerge.Merge("clips", new[] { a, b });
        var ba = SyncMerge.Merge("clips", new[] { b, a });
        AssertSame(ab, ba);
        AssertSame(ab, SyncMerge.Merge("clips", new[] { ab }));
    }

    [TestMethod]
    public void MergeIsAssociativeWithTombstones()
    {
        var a = File(new SyncRecord { Id = "x", Clock = SyncClock.Parse("A:1"), Modified = 10, Value = "a" });
        var b = File(new SyncRecord { Id = "x", Clock = SyncClock.Parse("B:2"), Modified = 20, Value = "b" });
        var c = FileWithErased(Array.Empty<SyncRecord>(), new SyncErased { Id = "x", Clock = SyncClock.Parse("C:3") });
        var left = SyncMerge.Merge("clips", new[] { SyncMerge.Merge("clips", new[] { a, b }), c });
        var right = SyncMerge.Merge("clips", new[] { a, SyncMerge.Merge("clips", new[] { b, c }) });
        AssertSame(left, right);
        Assert.AreEqual(0, left.Records.Count);
    }

    [TestMethod]
    public void RandomThreeDevicesConverge()
    {
        var random = new Random(20261025);
        for (var round = 0; round < 200; round++)
        {
            var files = Enumerable.Range(0, 3).Select(device => RandomFile(random, device)).ToArray();
            var first = SyncMerge.Merge("clips", files);
            var second = SyncMerge.Merge("clips", files.Reverse().ToArray());
            AssertSame(first, second);
            AssertSame(first, SyncMerge.Merge("clips", new[] { first }));

            var sequential = SyncMerge.Merge("clips", files);
            for (var index = 0; index < files.Length; index++)
            {
                var others = files.Where((_, position) => position != index).ToArray();
                var partial = SyncMerge.Merge("clips", others);
                AssertSame(sequential, SyncMerge.Merge("clips", new[] { partial, files[index] }));
            }
        }
    }

    private static SyncFile RandomFile(Random random, int device)
    {
        var records = new List<SyncRecord>();
        var erased = new List<SyncErased>();
        foreach (var id in new[] { "x", "y", "z", "w" })
        {
            switch (random.Next(4))
            {
                case 0:
                    records.Add(new SyncRecord
                    {
                        Id = id,
                        Clock = SyncClock.Parse($"D{device}:{random.Next(1, 4)}"),
                        Modified = random.Next(1, 100),
                        Value = $"v{random.Next(1, 3)}",
                    });
                    break;
                case 1:
                    erased.Add(new SyncErased
                    {
                        Id = id,
                        Clock = SyncClock.Parse($"D{device}:{random.Next(1, 4)}"),
                    });
                    break;
            }
        }

        return new SyncFile { Kind = "clips", Records = records, Erased = erased };
    }
}
