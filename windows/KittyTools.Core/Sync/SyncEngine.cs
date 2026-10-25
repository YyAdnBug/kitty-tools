// 全局同步「一条一条的数据」的合并规则（PLAN-v5 §3，逐行照 mac 的 reference/mac-sync/SyncRecords.swift）。
// 纯函数：交进来本机现在的样子、账本、文件夹里自己和别的电脑的那份，拿回要落到本机的改动、新账本、自己那份要写成什么。
// 文件头那几段规则原样留在下面：
// - 本机改了什么靠账本比（内容哈希），账本里有、本机没了 = 删了（留墓碑），账本里没有 = 新加的；
//   改了 / 新加的那条自己那一格取「账本、墓碑、文件夹各版」里自己那一格的最大再 +1；改于不晚于 now。
// - 合（C1）：被别的版本盖过的、被墓碑压住的丢掉；剩下谁也盖不住谁的，改于晚的赢（同一刻按内容哈希）；合完的钟取所有版本和墓碑的最大。
// - 删除（C2）：墓碑只记被删那一版的钟，不过期；删了之后别处又改过的压不住，照常合回来。
// - 账本被退回去了：自己那份里某条的钟自己那一格比账本大，先把账本那一格追上（别的格不并）。
// - 第一次合（没有账本）：同一编号不算改动、同样内容只留文件夹那条、adopt 整个跟着别的电脑；丢的不留墓碑、不进刹车。
using KittyTools.Core;

namespace KittyTools.Core.Sync;

public sealed class SyncValue
{
    public string Value { get; set; } = string.Empty;

    public SyncClock Clock { get; set; } = new();

    public long Modified { get; set; }
}

public sealed record SyncEntry(SyncClock Clock, string Hash, long Modified);

public sealed class SyncLedgerData
{
    public Dictionary<string, SyncEntry> Entries { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, SyncClock> Erased { get; } = new(StringComparer.Ordinal);
}

public sealed class SyncFileData
{
    public Dictionary<string, SyncValue> Records { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, SyncClock> Erased { get; } = new(StringComparer.Ordinal);
}

public enum JoinMode
{
    Union,
    Adopt,
}

public sealed class SyncOutcome
{
    public Dictionary<string, string?> Changes { get; } = new(StringComparer.Ordinal);

    public SyncLedgerData Ledger { get; set; } = new();

    public SyncFileData Own { get; set; } = new();

    public int Trashing { get; set; }

    public int Alive { get; set; }

    public int Erasing { get; set; }
}

public static class SyncEngine
{
    public const string OrderID = "~order";

    public const int MaxIDLength = 256;

    public const int MaxClockCells = 1024;

    public const int MaxClockText = 64 * 1024;

    public const long MaxMilliseconds = 1L << 53;

    public const int MaxCount = 1 << 20;

    public static string Hash(string value) => CanonicalJson.Hash(value);

    public static bool Buried(SyncClock clock, SyncClock? tombstone)
        => tombstone is not null && clock.Counters.All(pair => pair.Value <= tombstone[pair.Key]);

    public static string OrderValue(IEnumerable<string> ids)
        => "[" + string.Join(',', ids.Select(JsonString)) + "]";

    public static List<string> Arranged(IEnumerable<string> ids, IReadOnlyList<string> order)
    {
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var position = 0; position < order.Count; position++)
        {
            index.TryAdd(order[position], position);
        }

        return ids
            .OrderBy(id => index.TryGetValue(id, out var value) ? value : int.MaxValue)
            .ThenBy(id => id, StringComparer.Ordinal)
            .ToList();
    }

    public static SyncOutcome Round(
        IReadOnlyDictionary<string, string> local,
        IReadOnlyDictionary<string, long> changed,
        SyncLedgerData? oldLedger,
        SyncFileData? own,
        IReadOnlyList<SyncFileData> others,
        string me,
        long now,
        JoinMode join,
        Func<string, string?>? dedupe = null)
    {
        var ledger = oldLedger ?? new SyncLedgerData();
        var joining = oldLedger is null;
        var remotes = new List<SyncFileData>();
        if (own is not null)
        {
            remotes.Add(own);
        }

        remotes.AddRange(others);
        foreach (var file in remotes)
        {
            foreach (var (id, clock) in file.Erased)
            {
                ledger.Erased[id] = Union(
                    ledger.Erased.TryGetValue(id, out var existing) ? existing : null, clock);
            }
        }

        // 账本被退回去了：自己那份里本机那一格追上（内容和哈希不动）。
        if (own is not null)
        {
            foreach (var (id, record) in own.Records)
            {
                if (ledger.Entries.TryGetValue(id, out var entry) &&
                    record.Clock[me] > entry.Clock[me])
                {
                    entry.Clock[me] = record.Clock[me];
                }
            }
        }

        var outcome = new SyncOutcome { Alive = local.Count };
        var versions = new Dictionary<string, List<SyncValue>>(StringComparer.Ordinal);
        foreach (var file in remotes)
        {
            foreach (var (id, record) in file.Records)
            {
                versions.TryAdd(id, new List<SyncValue>());
                versions[id].Add(record);
            }
        }

        List<SyncValue> Standing(IReadOnlyList<SyncValue> list, SyncClock? tombstone)
        {
            var alive = list.Where(value => !Buried(value.Clock, tombstone)).ToList();
            var hashes = alive.Select(value => Hash(value.Value)).ToList();
            var result = new List<SyncValue>();
            for (var index = 0; index < alive.Count; index++)
            {
                var covered = false;
                for (var other = 0; other < alive.Count; other++)
                {
                    if (other != index && hashes[other] != hashes[index] &&
                        alive[index].Clock.Precedes(alive[other].Clock))
                    {
                        covered = true;
                        break;
                    }
                }

                if (!covered)
                {
                    result.Add(alive[index]);
                }
            }

            return result;
        }

        List<SyncValue> LiveVersions(string id)
            => Standing(versions.TryGetValue(id, out var list) ? list : new List<SyncValue>(),
                ledger.Erased.TryGetValue(id, out var tomb) ? tomb : null);

        var dropped = new HashSet<string>(StringComparer.Ordinal);
        if (joining)
        {
            if (join == JoinMode.Adopt)
            {
                if (others.Any(file => file.Records.Count > 0 || file.Erased.Count > 0))
                {
                    dropped = local.Keys.Where(id => LiveVersions(id).Count == 0)
                        .ToHashSet(StringComparer.Ordinal);
                }
            }
            else if (dedupe is not null)
            {
                var keys = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var id in versions.Keys.OrderBy(id => id, StringComparer.Ordinal))
                {
                    foreach (var record in LiveVersions(id))
                    {
                        if (dedupe(record.Value) is { } key)
                        {
                            keys[key] = id;
                        }
                    }
                }

                foreach (var (id, value) in local)
                {
                    if (!versions.ContainsKey(id) && !ledger.Erased.ContainsKey(id) &&
                        dedupe(value) is { } key && keys.TryGetValue(key, out var kept) && kept != id)
                    {
                        dropped.Add(id);
                    }
                }
            }
        }

        var mine = new Dictionary<string, SyncValue>(StringComparer.Ordinal);
        foreach (var (id, value) in local)
        {
            if (dropped.Contains(id))
            {
                continue;
            }

            var digest = Hash(value);
            if (ledger.Entries.TryGetValue(id, out var entry) && entry.Hash == digest)
            {
                mine[id] = new SyncValue
                {
                    Value = value,
                    Clock = Clone(entry.Clock),
                    Modified = entry.Modified,
                };
            }
            else if (!ledger.Entries.ContainsKey(id) && joining &&
                     (versions.ContainsKey(id) || ledger.Erased.ContainsKey(id)))
            {
                mine[id] = new SyncValue { Value = value, Clock = new SyncClock(), Modified = 0 };
            }
            else
            {
                var clock = ledger.Entries.TryGetValue(id, out var current)
                    ? Clone(current.Clock)
                    : ledger.Erased.TryGetValue(id, out var tomb) ? Clone(tomb) : new SyncClock();
                var seen = new List<int>
                {
                    clock[me],
                    ledger.Erased.TryGetValue(id, out var erasedClock) ? erasedClock[me] : 0,
                };
                if (versions.TryGetValue(id, out var list))
                {
                    seen.AddRange(list.Select(record => record.Clock[me]));
                }

                clock[me] = seen.Max() + 1;
                mine[id] = new SyncValue
                {
                    Value = value,
                    Clock = clock,
                    Modified = Math.Min(changed.TryGetValue(id, out var time) ? time : now, now),
                };
            }
        }

        // 账本里有、本机没了：本机删了。
        foreach (var (id, entry) in ledger.Entries.Where(pair => !local.ContainsKey(pair.Key)).ToList())
        {
            ledger.Erased[id] = Union(
                ledger.Erased.TryGetValue(id, out var existing) ? existing : null, entry.Clock);
            outcome.Erasing++;
        }

        foreach (var id in dropped)
        {
            outcome.Changes[id] = null;
            ledger.Entries.Remove(id);
        }

        var ids = new HashSet<string>(mine.Keys, StringComparer.Ordinal);
        ids.UnionWith(versions.Keys);
        ids.UnionWith(ledger.Entries.Keys);
        ids.ExceptWith(dropped);

        foreach (var id in ids)
        {
            var tombstone = ledger.Erased.TryGetValue(id, out var value) ? value : null;
            var all = new List<SyncValue>();
            if (mine.TryGetValue(id, out var mineValue))
            {
                all.Add(mineValue);
            }

            if (versions.TryGetValue(id, out var list))
            {
                all.AddRange(list);
            }

            var alive = all.Where(value => !Buried(value.Clock, tombstone)).ToList();
            var candidates = Standing(alive, null);
            SyncValue? winner = null;
            foreach (var candidate in candidates)
            {
                if (winner is null)
                {
                    winner = candidate;
                    continue;
                }

                var candidateKey = (candidate.Modified, Hash(candidate.Value));
                var winnerKey = (winner.Modified, Hash(winner.Value));
                if (candidateKey.CompareTo(winnerKey) > 0)
                {
                    winner = candidate;
                }
            }

            if (winner is null)
            {
                ledger.Entries.Remove(id);
                if (local.ContainsKey(id))
                {
                    outcome.Changes[id] = null;
                    outcome.Trashing++;
                }

                continue;
            }

            winner.Clock = Union(null, alive.Select(value => value.Clock)
                .Concat(tombstone is null ? Array.Empty<SyncClock>() : new[] { tombstone })
                .ToArray());
            var digest = Hash(winner.Value);
            ledger.Entries[id] = new SyncEntry(winner.Clock, digest, winner.Modified);
            outcome.Own.Records[id] = winner;
            if (!local.TryGetValue(id, out var currentValue) || Hash(currentValue) != digest)
            {
                outcome.Changes[id] = winner.Value;
            }
        }

        outcome.Ledger = ledger;
        foreach (var (id, clock) in ledger.Erased)
        {
            outcome.Own.Erased[id] = Clone(clock);
        }

        return outcome;
    }

    public static SyncClock Clone(SyncClock clock) => new(clock.Counters);

    public static SyncClock Union(SyncClock? first, params SyncClock[] rest)
    {
        var result = first is null ? new SyncClock() : Clone(first);
        foreach (var clock in rest)
        {
            result = result.Union(clock);
        }

        return result;
    }

    private static string JsonString(string value)
    {
        var builder = new System.Text.StringBuilder();
        CanonicalJson.WriteString(value, builder);
        return builder.ToString();
    }
}
