// 全局同步里「一条一条的数据」的合并规则和文件写法（PLAN-v5 §3；原样照 mac 的
// windows/reference/mac-sync/SyncRecords.swift，2026-10-25 的 09e17f21）。纯函数：执行层（Syncer）交进来本机现在的样子、账本、
// 文件夹里自己和别的电脑的那份，拿回要落到本机的改动、新的账本、自己那份要写成什么。便签不走这里。
// 版本钟的比法、写法和便签同一套（mac NoteSync.precedes / joined / text / clock；Windows 在 SyncClock）。
// 下面这几段是 SyncRecords.swift 文件头的规则，一条不改地留在注释里：
// - **本机改了什么靠账本比**（各个仓库不用自己记钟）：账本（Ledger）记着上一轮合完时每条的钟、内容的哈希、改于。这一轮
//   本机的内容（按字节）和账本里的哈希不一样 = 本机改了；账本里有、本机没了 = 本机删了（留墓碑）；账本里没有的 = 本机
//   新加的。改了、新加的：自己那一格取「账本、墓碑、文件夹里各版」里自己那一格的最大再 +1（账本退回去了、自己那份又读
//   不出来时也不撞号），改于取调用方给的这一条真正改的时刻（changed：设置记着每一项什么时候改的），没给的用现在，都不晚于
//   现在（退出、合盖之后才合到的改动，不该被记成「刚改的」翻掉别人后来改的）。
// - **合**（C1）：被别的版本盖过的、被墓碑压住的（钟每格都不超过它）丢掉；剩下谁都盖不住谁的，改于晚的赢（同一刻按内容的
//   哈希，几台挑出来的一样），不留旧版；合完的钟是所有版本和墓碑每格的最大（输的那台下一轮看到的是快进）。一条都不剩 = 删。
// - **删除**（C2）：墓碑只记被删那一版的钟，不过期；删了之后别处又改过的压不住，照常合回来（宁可多一条）。
// - **账本被退回去了**（时间机器）：自己那份里某条的钟**自己那一格**比账本里的大——先把账本那条的这一格追上（别的格不并：
//   并了的话退回去的旧内容会拿到和后来那版一样的钟，只剩按改于比，钟快的旧值赢遍每一台）。
// - **第一次合**（没有账本）：本机原有的、文件夹里有同一编号（或者只有它的墓碑）的不算改动——钟是空的，谁都盖得过它；
//   union 时本机新加的、内容（dedupe 键）和文件夹里别的编号还活着的那版一样的，只留文件夹那条（C4：同样的正文不重复）；
//   adopt（设置）时别的电脑已经有这一类，本机文件夹里没有活着的版本的那几项删掉（回到默认），整个跟着它们。这几种丢掉的
//   不留墓碑（从没发出去过）、不算删除、不进刹车。
// **执行层必须守住的**（不然本机没改的会被当成改了、没删的被当成删了，一路传到每一台）：账本记着的就是本机落下去的——
// 账本和数据**同一个事务**提交（片段、生词、启动器收藏的账本放进各自的库，设置的账本放在同一个偏好域），落改动没成就不存
// 账本；从备份恢复库时账本跟着一起退回去（引擎会追上）；关掉一类时不清它的账本（清了 = 重新加入，关着时本机改的会被盖回去）；
// 交进来的是本机落下的全部（另一台没装的 App 那种不显示的也交），编码稳定（编 → 落 → 再编，字节一样），值里不带只属于
// 这台电脑的东西。本机这一轮自己删了一大批（erasing，比如库被清空）先问再写出去。
// 文件（自己子文件夹里的 `<类别>.json`）：一份里是这台电脑眼里每条的最新样子 + 墓碑；内容（value）是调用方编好的 JSON 文本
// （键排好序：同样的内容同样的字节），原样存、原样比，不在这里解开。读得严：格式更新（结构对得上、版本号更大）另说，类别
// 不对、编号重复、钟写坏了或太长都算读不出来；文件多大由执行层先看。
// Windows 的差别（只记在这里，不改规则）：类别只有 clips / vocabulary / engines / services 四类；钟的计数是 int（mac 是
// Int），MaxCount 只用来提醒别写到溢出；文件读写沿用能对上 golden 的 SyncFile / CanonicalJson。
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

    // ponytail: 钟的计数是 int（mac 是 Int）；上限见 SyncClock.MaxCounter，写文件前不会溢出。
    public const int MaxCount = SyncClock.MaxCounter;

    public static string Hash(string value) => CanonicalJson.Hash(value);

    public static bool Buried(SyncClock clock, SyncClock? tombstone)
        => tombstone is not null && clock.Counters.All(pair => pair.Value <= tombstone[pair.Key]);

    /// <summary>还活着的版本：先去掉被墓碑压住的，再丢掉被别的（内容不一样的）版本盖过的（照 mac 的 standing）。</summary>
    public static List<SyncValue> Standing(IReadOnlyList<SyncValue> list, SyncClock? tombstone)
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
        // 账本按值用（mac 的 struct）：退回去追赶、并墓碑都只改这一份拷贝，不动调用方手里那本。
        var ledger = oldLedger is null ? new SyncLedgerData() : CloneLedger(oldLedger);
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

        /// 还活着的版本：没被墓碑压住、也没被别的（内容不一样的）版本盖过（照 mac 的 standing）。
        List<SyncValue> Standing(IReadOnlyList<SyncValue> list, SyncClock? tombstone)
            => SyncEngine.Standing(list, tombstone);

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
            string? winnerHash = null;
            foreach (var candidate in candidates)
            {
                var candidateHash = Hash(candidate.Value);
                if (winner is null || candidate.Modified > winner.Modified ||
                    (candidate.Modified == winner.Modified &&
                     string.CompareOrdinal(candidateHash, winnerHash) > 0))
                {
                    winner = candidate;
                    winnerHash = candidateHash;
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

            // 赢家是 all 里的一个引用（可能来自别的电脑的 File）：改钟之前先拷一份，别动调用方的。
            var merged = CloneValue(winner);
            merged.Clock = Union(null, alive.Select(value => value.Clock)
                .Concat(tombstone is null ? Array.Empty<SyncClock>() : new[] { tombstone })
                .ToArray());
            var digest = Hash(merged.Value);
            ledger.Entries[id] = new SyncEntry(merged.Clock, digest, merged.Modified);
            outcome.Own.Records[id] = merged;
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

    public static SyncValue CloneValue(SyncValue value)
        => new() { Value = value.Value, Clock = Clone(value.Clock), Modified = value.Modified };

    public static SyncLedgerData CloneLedger(SyncLedgerData ledger)
    {
        var copy = new SyncLedgerData();
        foreach (var (id, entry) in ledger.Entries)
        {
            copy.Entries[id] = new SyncEntry(Clone(entry.Clock), entry.Hash, entry.Modified);
        }

        foreach (var (id, clock) in ledger.Erased)
        {
            copy.Erased[id] = Clone(clock);
        }

        return copy;
    }

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
