// 同步合并的随机测试（照 reference/mac-sync/SyncRecordsFuzzTests.swift）：三台电脑随机加 / 改 / 删 / 合，
// 读到旧文件、自己那份偶尔读不出来、钟差、退回旧库、丢账本；最后查三台一样、值都是写过的、再合不变，
// 以及钟最慢的那台最后改的 / 删的都能传遍。默认 20 个种子 × 300 步随全量跑；
// KITTY_SYNC_FUZZ=2000 跑 2000 个（REVIEW R13 的验收；mac 原来的 KITTY_SYNC_RECORDS_FUZZ 也认）。
using System.Diagnostics;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncEngineFuzzTests
{
    private sealed class Rng
    {
        private ulong _state;

        public Rng(ulong seed) => _state = seed;

        public ulong Next()
        {
            _state += 0x9E3779B97F4A7C15;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }

        public int Below(int n) => (int)(Next() % (ulong)n);

        public bool Chance(int percent) => Below(100) < percent;
    }

    private sealed class Mac
    {
        public string Id = string.Empty;

        public Dictionary<string, string> Local = new(StringComparer.Ordinal);

        public SyncLedgerData? Ledger;

        public List<SyncFileData> History = new();

        public bool Joined;

        public long Skew;

        public (Dictionary<string, string> Local, SyncLedgerData? Ledger)? Snapshot;

        public Dictionary<string, long> Changed = new(StringComparer.Ordinal);
    }

    [TestMethod]
    public void RandomOperationsConverge()
    {
        var countText = Environment.GetEnvironmentVariable("KITTY_SYNC_FUZZ") ??
                        Environment.GetEnvironmentVariable("KITTY_SYNC_RECORDS_FUZZ");
        var count = int.TryParse(countText, out var parsed) ? parsed : 20;
        var firstText = Environment.GetEnvironmentVariable("KITTY_SYNC_FUZZ_SEED") ??
                        Environment.GetEnvironmentVariable("KITTY_SYNC_RECORDS_FUZZ_SEED");
        var first = ulong.TryParse(firstText, out var seed) ? seed : 1;
        var watch = Stopwatch.StartNew();
        for (var currentSeed = first; currentSeed < first + (ulong)count; currentSeed++)
        {
            var failure = Simulate(currentSeed, 300);
            if (failure is not null)
            {
                Assert.Fail($"种子 {currentSeed}：{failure}");
            }
        }

        watch.Stop();
        Console.WriteLine($"sync fuzz {count} seeds in {watch.ElapsedMilliseconds} ms");
    }

    private static string? Simulate(ulong seed, int steps)
    {
        var rng = new Rng(seed);
        var macs = new[] { "A", "B", "C" }.Select(id => new Mac { Id = id }).ToList();
        for (var index = 0; index < macs.Count; index++)
        {
            macs[index].Skew = rng.Below(101) - 50;
            macs[index].Ledger = index < 2 ? new SyncLedgerData() : null;
            macs[index].Joined = index < 2;
        }

        var serial = 0;
        var join = seed % 2 == 0 ? JoinMode.Adopt : JoinMode.Union;
        var used = new List<string>();
        var written = new HashSet<string>(StringComparer.Ordinal);

        string? Round(int index, int step, bool stale, bool behind = false, bool ownUnreadable = false)
        {
            var others = new List<SyncFileData>();
            for (var other = 0; other < macs.Count; other++)
            {
                if (other == index || macs[other].History.Count == 0)
                {
                    continue;
                }

                others.Add(stale && rng.Chance(30)
                    ? macs[other].History[rng.Below(macs[other].History.Count)]
                    : macs[other].History[^1]);
            }

            var now = behind ? 0 : step * 100 + macs[index].Skew;
            var outcome = SyncEngine.Round(
                macs[index].Local, behind ? new Dictionary<string, long>() : macs[index].Changed,
                macs[index].Ledger, ownUnreadable ? null : macs[index].History.LastOrDefault(),
                others, macs[index].Id, now, join, value => value);
            foreach (var (key, value) in outcome.Changes)
            {
                if (value is null)
                {
                    macs[index].Local.Remove(key);
                }
                else
                {
                    macs[index].Local[key] = value;
                }
            }

            macs[index].Ledger = outcome.Ledger;
            macs[index].History.Add(outcome.Own);
            macs[index].Joined = true;
            var entries = outcome.Ledger.Entries;
            if (entries.Count != macs[index].Local.Count ||
                macs[index].Local.Any(pair =>
                    !entries.TryGetValue(pair.Key, out var entry) || entry.Hash != SyncEngine.Hash(pair.Value)))
            {
                return $"{macs[index].Id} 第 {step} 步合完账本和本机对不上";
            }

            return null;
        }

        for (var step = 0; step < steps; step++)
        {
            var index = rng.Below(macs.Count);
            if (!macs[index].Joined && !rng.Chance(50))
            {
                continue;
            }

            switch (rng.Below(100))
            {
                case < 20:
                {
                    serial++;
                    var donor = macs[rng.Below(macs.Count)].Local.Values.OrderBy(value => value, StringComparer.Ordinal).FirstOrDefault();
                    var value = rng.Chance(10) ? donor ?? $"v{serial}" : $"v{serial}";
                    var id = used.Count > 0 && rng.Chance(25) ? used[rng.Below(used.Count)] : $"i{serial}";
                    if (!used.Contains(id))
                    {
                        used.Add(id);
                    }

                    macs[index].Local[id] = value;
                    macs[index].Changed[id] = step * 100 + macs[index].Skew;
                    written.Add(value);
                    break;
                }

                case < 40:
                {
                    var keys = macs[index].Local.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
                    if (keys.Count > 0)
                    {
                        serial++;
                        var key = keys[rng.Below(keys.Count)];
                        macs[index].Local[key] = $"m{serial}";
                        macs[index].Changed[key] = step * 100 + macs[index].Skew;
                        written.Add($"m{serial}");
                    }

                    break;
                }

                case < 50:
                {
                    var keys = macs[index].Local.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
                    if (keys.Count > 0)
                    {
                        macs[index].Local.Remove(keys[rng.Below(keys.Count)]);
                    }

                    break;
                }

                case < 93:
                {
                    var failure = Round(index, step, stale: true, ownUnreadable: rng.Chance(10));
                    if (failure is not null)
                    {
                        return failure;
                    }

                    break;
                }

                case < 96:
                    macs[index].Snapshot = (
                        new Dictionary<string, string>(macs[index].Local, StringComparer.Ordinal),
                        Clone(macs[index].Ledger));
                    break;

                case < 98:
                    if (macs[index].Snapshot is { } snapshot)
                    {
                        macs[index].Local = new Dictionary<string, string>(snapshot.Local, StringComparer.Ordinal);
                        macs[index].Ledger = Clone(snapshot.Ledger);
                    }

                    break;

                default:
                    if (macs[index].Joined)
                    {
                        macs[index].Ledger = null;
                    }

                    break;
            }
        }

        var current = steps;
        for (var settle = 0; settle < 3; settle++)
        {
            for (var index = 0; index < macs.Count; index++)
            {
                current++;
                var failure = Round(index, current, stale: false);
                if (failure is not null)
                {
                    return failure;
                }
            }
        }

        if (!SameLocal(macs[0], macs[1]) || !SameLocal(macs[1], macs[2]))
        {
            return $"安静下来之后三台不一样：{string.Join('/', macs.Select(mac => mac.Local.Count))}";
        }

        if (!macs[0].Local.Values.All(written.Contains))
        {
            return "合出了谁都没写过的值";
        }

        foreach (var mac in macs)
        {
            current++;
            var before = new Dictionary<string, string>(mac.Local, StringComparer.Ordinal);
            var failure = Round(macs.IndexOf(mac), current, stale: false);
            if (failure is not null)
            {
                return failure;
            }

            if (!SameLocal(mac.Local, before))
            {
                return $"{mac.Id} 再合一轮又变了";
            }
        }

        var firstKey = macs[0].Local.Keys.OrderBy(key => key, StringComparer.Ordinal).FirstOrDefault();
        if (firstKey is null)
        {
            return null;
        }

        var slowest = Enumerable.Range(0, macs.Count).MinBy(index => macs[index].Skew);
        macs[slowest].Local[firstKey] = "最后改的";
        macs[slowest].Changed.Remove(firstKey);
        for (var offset = 0; offset < macs.Count; offset++)
        {
            current++;
            var failure = Round((slowest + offset) % macs.Count, current, stale: false, behind: offset == 0);
            if (failure is not null)
            {
                return failure;
            }
        }

        if (!macs.All(mac => mac.Local.TryGetValue(firstKey, out var value) && value == "最后改的"))
        {
            return "钟最慢的那台最后改的没传到每一台";
        }

        var deleter = (slowest + 1) % macs.Count;
        macs[deleter].Local.Remove(firstKey);
        for (var offset = 0; offset < macs.Count; offset++)
        {
            current++;
            var failure = Round((deleter + offset) % macs.Count, current, stale: false);
            if (failure is not null)
            {
                return failure;
            }
        }

        if (macs.Any(mac => mac.Local.ContainsKey(firstKey)))
        {
            return "删掉的那条没在每一台删掉";
        }

        return null;
    }

    private static bool SameLocal(Mac first, Mac second)
        => first.Local.Count == second.Local.Count &&
           first.Local.All(pair => second.Local.TryGetValue(pair.Key, out var value) && value == pair.Value);

    private static bool SameLocal(Dictionary<string, string> first, Dictionary<string, string> second)
        => first.Count == second.Count &&
           first.All(pair => second.TryGetValue(pair.Key, out var value) && value == pair.Value);

    private static SyncLedgerData? Clone(SyncLedgerData? ledger)
    {
        if (ledger is null)
        {
            return null;
        }

        var copy = new SyncLedgerData();
        foreach (var (id, entry) in ledger.Entries)
        {
            copy.Entries[id] = new SyncEntry(SyncEngine.Clone(entry.Clock), entry.Hash, entry.Modified);
        }

        foreach (var (id, clock) in ledger.Erased)
        {
            copy.Erased[id] = SyncEngine.Clone(clock);
        }

        return copy;
    }
}
