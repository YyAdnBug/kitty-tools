// 便签同步的合并规则（PLAN-v13，照 mac Notes/NoteSync.swift 逐行移植；规矩在 mac-native §2「便签同步」）。纯函数：执行层把
// 「本机这一版 + 别的电脑的那几版 + 墓碑」交进来、把结果落下去。两边读写同一个同步文件夹，**规则和哈希、另存那条的编号都
// 必须和 mac 一字不差**（Fixtures/notes-sync-golden.json 是拿 mac 的源码真跑出来的，NoteSyncTests 逐个比）。
// 一条便签分三组各合各的：
// - **内容**（标题、正文、颜色）看版本钟（Note.Clock：每台电脑改过几次内容）。一版的钟每格都不大于另一版、内容又不一样
//   = 另一版是在它之上改的，它被盖过了：丢掉、不留旧版。剩下谁都盖不住谁的（两边各改各的）才是冲突：「改于」后的赢（一样时
//   按内容的哈希），输的那几版文字各另存一条进「最近删除」——编号由便签编号 + 输的那版内容的哈希推出来（CopyId），别的字段
//   也都由那一版定（只有放进最近删除的时刻是各台的现在）；**另存那条的钟是空的**（它是新的一条）。合完的钟取所有版本每格的
//   最大值。只看钟、不看时钟谁快谁慢。
//   **钟能用的前提**（仓库守着）：每次内容变化自己那一格 +1、计数不回退（从备份恢复换一个电脑编号）、电脑编号不撞。
// - **状态**（归档、固定、删除）后改的赢，按 StateTime；**顺序**单独按 OrderTime。一样时按值本身排，几台挑出来的一样。
// - **一边删、一边改**：几组分开合 → 最新的内容在「最近删除」里，什么都不丢。
// - **永久删除**（墓碑：被删那一版的钟和状态时刻，几台的并起来）：钟每格都不超过它、状态也不晚于它的版本都当没有。删了之后
//   又改过、放回过的压不住，照常合；留下来的那条钟里并上墓碑的钟（计数不退回去）。
// - 时间按原值比（整数毫秒；mac 内存里是对齐到毫秒的 Date，比较结果一样），不管是不是比现在还晚。
// 合出来和本机那条一样（修订号不算）就原样给回本机那条：执行层据此判断「这一轮这条没变」。
// **便签的钟和同步那几类的 SyncClock 不是一套规则**：这里读钟是宽松的（写坏的格子跳过，不整份作废）、次数上限 1 << 40（long）。
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace KittyTools.Core.Notes;

public static class NoteSync
{
    /// <summary>次数的上限（文件夹里读进来的钟夹在它以内：本机再 +1 不溢出）。</summary>
    public const long MaxCount = 1L << 40;

    private static readonly IReadOnlyList<Note> NoCopies = Array.Empty<Note>();

    /// <summary>永久删除的墓碑：被删的那一版的钟和状态时刻（整数毫秒）。几台的并起来：钟每格取最大、时刻取最晚。</summary>
    public sealed record Tombstone(IReadOnlyDictionary<string, long> Clock, long State)
    {
        /// <summary>一版是不是被它压住：钟每格都不超过、状态也不晚于。</summary>
        public bool Buries(Note note)
        {
            if (note.StateTime > State)
            {
                return false;
            }

            foreach (var (device, count) in note.Clock)
            {
                if (count > CountOf(Clock, device))
                {
                    return false;
                }
            }

            return true;
        }

        public Tombstone Merged(Tombstone other) => new(Joined([Clock, other.Clock]), Math.Max(State, other.State));

        /// <summary>按值比（同 mac 的 Equatable：钟按内容）。</summary>
        public bool Equals(Tombstone? other) => other is not null && State == other.State && Note.SameClock(Clock, other.Clock);

        public override int GetHashCode() => HashCode.Combine(State, Clock.Count);
    }

    /// <summary>合一条的结果。Note：合完的样子（null = 本机不该有这条：本机有的话真删）；Copies：冲突里输了、文字和赢的不一样的
    /// 那几版，各另存一条进「最近删除」（编号 CopyId；已经有了的、永久删过的执行层不再存）；Trashes：本机那条原来没删、合完进了
    /// 「最近删除」（一轮里要数它）；Base：合的时候本机那条的修订号（本机没有是 null）——落下去之前本机又改了就不落这一条。</summary>
    public sealed record Merge(Note? Note, IReadOnlyList<Note> Copies, bool Trashes, int? Base)
    {
        /// <summary>按值比（Copies 逐条比）。</summary>
        public bool Equals(Merge? other)
            => other is not null && Equals(Note, other.Note) && Trashes == other.Trashes && Base == other.Base &&
               Copies.SequenceEqual(other.Copies);

        public override int GetHashCode() => HashCode.Combine(Note?.Id, Copies.Count, Trashes, Base);
    }

    /// <summary>内容（标题、正文、颜色）的哈希：UTF-8 的「标题 \0 正文 \0 颜色的十进制」做 SHA-256，前 16 字节的小写十六进制。</summary>
    public static string ContentHash(Note note)
    {
        var title = Encoding.UTF8.GetBytes(note.Title);
        var body = Encoding.UTF8.GetBytes(note.Body);
        var color = Encoding.UTF8.GetBytes(note.Color.ToString(CultureInfo.InvariantCulture));
        var data = new byte[title.Length + body.Length + color.Length + 2];
        title.CopyTo(data, 0);
        body.CopyTo(data, title.Length + 1);
        color.CopyTo(data, title.Length + body.Length + 2);
        return Convert.ToHexStringLower(SHA256.HashData(data).AsSpan(0, 16));
    }

    /// <summary>a 被 b 盖过了吗：a 的每一格都不大于 b，而且两个不一样。</summary>
    public static bool Precedes(IReadOnlyDictionary<string, long> a, IReadOnlyDictionary<string, long> b)
    {
        if (Note.SameClock(a, b))
        {
            return false;
        }

        foreach (var (device, count) in a)
        {
            if (count > CountOf(b, device))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>版本钟在库里、文件头里的写法：「编号:次数」按编号排、逗号隔开（空钟是空串）。</summary>
    // ponytail: 按 UTF-16 排；mac 按 Swift 的字符串比较排。钟的编号都是字母数字和减号（读进来的过了 ClockFrom、本机的是 UUID），
    // 这种 ASCII 两种排法一样
    public static string ClockText(IReadOnlyDictionary<string, long> clock)
        => string.Join(',', clock
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => pair.Key + ":" + pair.Value.ToString(CultureInfo.InvariantCulture)));

    /// <summary>读回来：写坏的格子（编号不是 1–64 个字母数字和减号、次数不是 1…MaxCount 的整数）跳过；同一个编号写了几次取最大。
    /// 照 Swift 按字切（逗号、冒号后面跟着组合符号就不算分隔符）、丢掉空段（「A::1」读成 A:1）。</summary>
    public static IReadOnlyDictionary<string, long> ClockFrom(string text)
    {
        var clock = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var cell in NoteFileHeader.Split(text, ','))
        {
            var parts = NoteFileHeader.Split(cell, ':');
            if (parts.Count != 2 || NoteFileHeader.ParseInt64(parts[1]) is not { } count || count is < 1 or > MaxCount)
            {
                continue;
            }

            var device = parts[0];
            if (device.Length is < 1 or > 64 || !device.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-'))
            {
                continue;
            }

            clock[device] = Math.Max(CountOf(clock, device), count);
        }

        return clock;
    }

    /// <summary>几个钟合起来：每格取最大。</summary>
    public static IReadOnlyDictionary<string, long> Joined(IEnumerable<IReadOnlyDictionary<string, long>> clocks)
    {
        var result = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var clock in clocks)
        {
            foreach (var (device, count) in clock)
            {
                result[device] = result.TryGetValue(device, out var old) ? Math.Max(old, count) : count;
            }
        }

        return result;
    }

    /// <summary>输的那版另存成的那一条的编号：便签编号 + 那版内容的哈希推出来（UUID 第 5 版的写法：SHA-256 前 16 字节、改版本位），
    /// 大写带连字符（同 Swift UUID.uuidString）。同一版不管哪台电脑、存几次都是这一个。</summary>
    public static string CopyId(string id, string hash)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes("kitty-note-conflict\0" + id + "\0" + hash));
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x50);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        var hex = Convert.ToHexString(bytes.AsSpan(0, 16));
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..32]}";
    }

    /// <summary>合一条（mac merge(local:remotes:tombstone:now:hashes:)）：local 是本机的（null = 本机没有这条），remotes 是别的电脑文件夹里的
    /// （同一个编号），tombstone 是这条的墓碑（本机的和别的电脑的并起来）。now 只用来记另存那几条放进「最近删除」的时刻。
    /// hashes：remotes 各版的内容哈希（一一对应，读文件时核对过的；没给、给了 null 的现算）。</summary>
    public static Merge MergeOne(
        Note? local, IReadOnlyList<Note> remotes, Tombstone? tombstone, long now, IReadOnlyList<string?>? hashes = null)
    {
        var @base = local?.Revision;
        var kept = new List<int>();
        for (var index = 0; index < remotes.Count; index++)
        {
            if (tombstone is null || !tombstone.Buries(remotes[index]))
            {
                kept.Add(index);
            }
        }

        if (local is not null && tombstone is not null && tombstone.Buries(local) && kept.Count == 0)
        {
            return new Merge(null, NoCopies, false, @base);
        }

        var versions = new List<Note>();
        var keys = new List<string>();
        if (local is not null)
        {
            versions.Add(local);
            keys.Add(ContentHash(local));
        }

        foreach (var index in kept)
        {
            versions.Add(remotes[index]);
            keys.Add((hashes is not null && index < hashes.Count ? hashes[index] : null) ?? ContentHash(remotes[index]));
        }

        if (versions.Count == 0)
        {
            return new Merge(null, NoCopies, false, @base);
        }

        // 内容：去掉被盖过的（内容不一样、钟被别的版本盖过），剩下的里「改于」后的赢，同一刻按哈希
        var standing = new List<int>();
        for (var i = 0; i < versions.Count; i++)
        {
            var covered = false;
            for (var j = 0; j < versions.Count && !covered; j++)
            {
                covered = keys[j] != keys[i] && Precedes(versions[i].Clock, versions[j].Clock);
            }

            if (!covered)
            {
                standing.Add(i);
            }
        }

        bool Earlier(int i, int j)
            => versions[i].ModifiedAt < versions[j].ModifiedAt ||
               (versions[i].ModifiedAt == versions[j].ModifiedAt && string.CompareOrdinal(keys[i], keys[j]) < 0);

        if (standing.Count == 0)
        {
            return new Merge(local, NoCopies, false, @base);
        }

        // 同 Swift 的 max(by:)：一样大时留前面那个
        var winner = standing[0];
        foreach (var index in standing.Skip(1))
        {
            if (Earlier(winner, index))
            {
                winner = index;
            }
        }

        // 输的：每种内容留一份（同一内容几版里「改于」最晚的那版）
        var losers = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var index in standing)
        {
            if (keys[index] == keys[winner])
            {
                continue;
            }

            if (losers.TryGetValue(keys[index], out var held) && !Earlier(held, index))
            {
                continue;
            }

            losers[keys[index]] = index;
        }

        var copies = new List<Note>();
        foreach (var hash in losers.Keys.OrderBy(key => key, StringComparer.Ordinal))
        {
            var loser = versions[losers[hash]];
            copies.Add(new Note
            {
                Id = CopyId(loser.Id, hash),
                Title = loser.Title,
                Body = loser.Body,
                Color = loser.Color,
                CreatedAt = loser.CreatedAt,
                ModifiedAt = loser.ModifiedAt,
                Order = loser.Order,
                DeletedAt = now,
                StateChangedAt = loser.ModifiedAt,
                OrderChangedAt = loser.ModifiedAt,
            });
        }

        // 状态、顺序：各自后改的赢，同一刻按值本身
        var state = versions[0];
        var order = versions[0];
        foreach (var version in versions.Skip(1))
        {
            if (StateBefore(state, version))
            {
                state = version;
            }

            if (order.OrderTime < version.OrderTime || (order.OrderTime == version.OrderTime && order.Order < version.Order))
            {
                order = version;
            }
        }

        // 墓碑的钟也并进来：本机永久删过、又被别处改过的那版救回来时，本机那一格不退回去
        var clocks = versions.Select(version => version.Clock).ToList();
        if (tombstone is not null)
        {
            clocks.Add(tombstone.Clock);
        }

        var note = versions[winner] with
        {
            Clock = Joined(clocks),
            CreatedAt = versions.Min(version => version.CreatedAt),
            IsArchived = state.IsArchived,
            IsPinned = state.IsPinned,
            DeletedAt = state.DeletedAt,
            StateChangedAt = state.StateTime,
            Order = order.Order,
            OrderChangedAt = order.OrderTime,
        };
        // 修订号是本机的账：本机有就在本机的上往上走，新来的从 0 起
        if (local is null)
        {
            return new Merge(note with { Revision = 0 }, copies, false, @base);
        }

        note = note with { Revision = local.Revision };
        if (note.Equals(local))
        {
            return new Merge(local, copies, false, @base);
        }

        note = note with { Revision = Note.NextRevision(local.Revision) };
        return new Merge(note, copies, local.DeletedAt is null && note.DeletedAt is not null, @base);
    }

    /// <summary>状态那一组 a 排在 b 前面吗：(StateTime, 删除时刻（没删是 -1）, 归档, 固定) 依次比。</summary>
    private static bool StateBefore(Note a, Note b)
    {
        if (a.StateTime != b.StateTime)
        {
            return a.StateTime < b.StateTime;
        }

        var (deletedA, deletedB) = (a.DeletedAt ?? -1, b.DeletedAt ?? -1);
        if (deletedA != deletedB)
        {
            return deletedA < deletedB;
        }

        if (a.IsArchived != b.IsArchived)
        {
            return !a.IsArchived;
        }

        return !a.IsPinned && b.IsPinned;
    }

    internal static long CountOf(IReadOnlyDictionary<string, long> clock, string device)
        => clock.TryGetValue(device, out var count) ? count : 0;
}
