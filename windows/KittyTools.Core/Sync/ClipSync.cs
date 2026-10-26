// 片段与收藏接进同步（REVIEW R26；照 windows/reference/mac-sync/ClipboardStore.swift 末尾的 `extension ClipboardStore:
// SyncSource`）。纯函数：执行层只管读写文件夹、事务和状态，这里只管「编出去」和「落回来」。
// - Values：本机留着的文字条目（收藏、片段、在收藏夹里的：mac isRetained）和收藏夹 → 编号 → 内容。带 NUL 的整条不同步
//   （库里存的是截断的，重启后和账本对不上）；收藏夹是空表时也交 ~order。
// - JoinKey：第一次合时同样正文的条目、同名的收藏夹只留文件夹里那个。
// - Plan：合出来的改动（编号 → 新内容，null = 不再留着）+ 本机现在的样子 → 要落的样子；有一条解不开（或者是更新版本写的、
//   编回去不一样）返回失败原因，整类不落（当成删了的话会一路删到每一台）。落地规则逐条照 mac applySync：
//   - 收藏夹先（条目要归进去）。和本机另一个同名的撞上：编号小的留下，另一个的条目归进留下的那个；被删的收藏夹还有同名的，
//     条目也归过去；按 ~order 排（不在里面的排在后面、按编号）。
//   - 别处删了 / 不再留着的：取消收藏、移出片段和收藏夹（还在历史里，按保留天数清理，不直接删行）。先落这些，再落新来的；
//     同一类里按编号（几台的先后一样）。
//   - 新来的 / 改了的：和本机同样正文的另一条撞上时，那条留着、编号又比来的小就留它，否则留来的这条；收藏、片段取并集，
//     备注、收藏夹缺的补上。输的那条本机删掉（下一轮它的删除和留下那条的改动传出去，几台合到同一条）。
// Windows 的差别：条目在库里有自己的行号，同步的编号是另存的 uid（mac 的条目编号）。新来的这条接过一条没有 uid 的普通条目时，
// 直接用那一行（mac 是删掉再插一条，结果一样）；备注、正文原样存（不 Trim、不把空白改成 null：编回去要一字不差）。
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

/// <summary>本机的一条文字条目（同步只看这些字段）。Row 是库里的行号；Uid 是同步的编号，没留着过的普通条目可以没有。</summary>
public sealed record SyncClipRow(
    long Row, string? Uid, string Text, bool Favorite, bool Snippet, string? Note, string? Group, long CopiedAt)
{
    public bool IsRetained => Favorite || Snippet || Group is not null;
}

/// <summary>本机的一个收藏夹；Created 是毫秒。</summary>
public sealed record SyncClipGroup(string Id, string Name, long Created);

/// <summary>要写的一条：Row 为 null 是新加的；TextChanged 时带格式的原始数据（HTML / RTF）要清掉。</summary>
public sealed record SyncClipWrite(
    long? Row, string? Uid, string Text, bool Favorite, bool Snippet, string? Note, string? Group, long CopiedAt,
    bool TextChanged);

public sealed class ClipSyncPlan
{
    /// <summary>落地后的整张收藏夹表（已按顺序排好）。</summary>
    public List<SyncClipGroup> Groups { get; } = new();

    public List<SyncClipWrite> Writes { get; } = new();

    /// <summary>要删掉的行（同正文撞上时输的那条）。</summary>
    public List<long> Deletes { get; } = new();
}

public static class ClipSync
{
    public const string Kind = "clips";

    public const string GroupPrefix = "group:";

    public const string Unreadable = "有内容这一版读不懂，先没存上（可能要更新 Kitty Tools）";

    public static Dictionary<string, string> Values(IEnumerable<SyncClipRow> rows, IReadOnlyList<SyncClipGroup> groups)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (!row.IsRetained || row.Uid is null || row.Text.Contains('\0') || row.Note?.Contains('\0') == true)
            {
                continue;
            }

            values[row.Uid] = Clip(row.Text, row.Favorite, row.Snippet, row.Note, row.Group);
        }

        var synced = groups.Where(group => !group.Name.Contains('\0')).ToList();
        foreach (var group in synced)
        {
            values[GroupPrefix + group.Id] = Group(group.Name, group.Created);
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(synced.Select(group => GroupPrefix + group.Id));
        return values;
    }

    /// <summary>mac SyncedClip：favorite / group? / note? / snippet / text；group 是收藏夹编号本身（不带 group: 前缀）。</summary>
    public static string Clip(string text, bool favorite, bool snippet, string? note, string? group)
    {
        var builder = new StringBuilder("{");
        builder.Append("\"favorite\":").Append(favorite ? "true" : "false");
        if (group is not null)
        {
            builder.Append(",\"group\":");
            CanonicalJson.WriteString(group, builder);
        }

        if (note is not null)
        {
            builder.Append(",\"note\":");
            CanonicalJson.WriteString(note, builder);
        }

        builder.Append(",\"snippet\":").Append(snippet ? "true" : "false");
        builder.Append(",\"text\":");
        CanonicalJson.WriteString(text, builder);
        return builder.Append('}').ToString();
    }

    /// <summary>mac SyncedGroup：created（毫秒）/ name。</summary>
    public static string Group(string name, long created)
        => $"{{\"created\":{created},\"name\":{SyncValues.Quote(name)}}}";

    /// <summary>第一次合：同样正文的片段 / 收藏、同名的收藏夹只留文件夹里那个。</summary>
    public static string? JoinKey(string value)
        => SyncValues.Read(value, root =>
            SyncValues.Text(root, "text") is { } text
                ? "clip:" + text
                : SyncValues.Text(root, "name") is { } name ? "group:" + name : null);

    private sealed record SyncedClip(string Text, bool Favorite, bool Snippet, string? Note, string? Group);

    private sealed record SyncedGroup(string Name, long Created);

    private static SyncedClip? DecodeClip(string value)
    {
        var clip = SyncValues.Read(value, root =>
            SyncValues.Text(root, "text") is { } text
                ? new SyncedClip(text, SyncValues.Flag(root, "favorite"), SyncValues.Flag(root, "snippet"),
                    SyncValues.Text(root, "note"), SyncValues.Text(root, "group"))
                : null);
        // 解得开还不够：编回去要一字不差（mac decodeExact），多了不认识的字段、类型不对的都在这里挡住。
        return clip is not null && Clip(clip.Text, clip.Favorite, clip.Snippet, clip.Note, clip.Group) == value
            ? clip
            : null;
    }

    private static SyncedGroup? DecodeGroup(string value)
    {
        var group = SyncValues.Read(value, root =>
            SyncValues.Text(root, "name") is { } name && SyncValues.Number(root, "created") is { } created
                ? new SyncedGroup(name, created)
                : null);
        return group is not null && Group(group.Name, group.Created) == value ? group : null;
    }

    /// <summary>工作副本里的一条（Plan 里一边改一边算，最后变成 Writes）。</summary>
    private sealed class Item
    {
        public long? Row { get; set; }

        public string? Uid { get; set; }

        public string Text { get; set; } = string.Empty;

        public bool Favorite { get; set; }

        public bool Snippet { get; set; }

        public string? Note { get; set; }

        public string? Group { get; set; }

        public long CopiedAt { get; set; }

        public bool TextChanged { get; set; }

        public bool IsRetained => Favorite || Snippet || Group is not null;

        public static Item From(SyncClipRow row) => new()
        {
            Row = row.Row, Uid = row.Uid, Text = row.Text, Favorite = row.Favorite, Snippet = row.Snippet,
            Note = row.Note, Group = row.Group, CopiedAt = row.CopiedAt,
        };

        public SyncClipWrite ToWrite() => new(Row, Uid, Text, Favorite, Snippet, Note, Group, CopiedAt, TextChanged);
    }

    /// <summary>把合出来的改动算成要落的样子（rows：本机全部文字条目；groups：本机收藏夹，按顺序；now：新条目的复制时间）。</summary>
    public static ClipSyncPlan? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<SyncClipRow> rows,
        IReadOnlyList<SyncClipGroup> groups, long now, out string? failure)
    {
        failure = null;
        var groupChanges = new List<(string Id, SyncedGroup? Group)>();
        var clipChanges = new List<(string Id, SyncedClip? Clip)>();
        IReadOnlyList<string> groupOrder = groups.Select(group => GroupPrefix + group.Id).ToList();
        foreach (var (key, value) in changes)
        {
            if (key == SyncEngine.OrderID)
            {
                if (value is null)
                {
                    continue;
                }

                if (SyncValues.DecodeOrder(value) is not { } ids)
                {
                    failure = Unreadable;
                    return null;
                }

                groupOrder = ids;
                continue;
            }

            var isGroup = key.StartsWith(GroupPrefix, StringComparison.Ordinal);
            var id = isGroup ? key[GroupPrefix.Length..] : key;
            if (!Guid.TryParse(id, out _))
            {
                failure = Unreadable;
                return null;
            }

            if (value is null)
            {
                if (isGroup)
                {
                    groupChanges.Add((id, null));
                }
                else
                {
                    clipChanges.Add((id, null));
                }

                continue;
            }

            if (isGroup)
            {
                if (DecodeGroup(value) is not { } group)
                {
                    failure = Unreadable;
                    return null;
                }

                groupChanges.Add((id, group));
            }
            else
            {
                if (DecodeClip(value) is not { } clip)
                {
                    failure = Unreadable;
                    return null;
                }

                clipChanges.Add((id, clip));
            }
        }

        // 先「不再留着」的、再新来的；同一类里按编号（几台的先后一样）。
        groupChanges.Sort((a, b) => Compare(a.Group is null, a.Id, b.Group is null, b.Id));
        clipChanges.Sort((a, b) => Compare(a.Clip is null, a.Id, b.Clip is null, b.Id));

        // 收藏夹
        var newGroups = groups.ToList();
        var removedGroups = new HashSet<string>(StringComparer.Ordinal);
        // 收藏夹编号 → 它的条目该归进的那个（同名撞上、被删了但还有同名的）
        var remap = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (id, synced) in groupChanges)
        {
            if (synced is null)
            {
                newGroups.RemoveAll(group => group.Id == id);
                removedGroups.Add(id);
                continue;
            }

            if (newGroups.FirstOrDefault(group => group.Id != id && group.Name == synced.Name) is { } other)
            {
                if (string.CompareOrdinal(other.Id, id) < 0)
                {
                    remap[id] = other.Id;
                    newGroups.RemoveAll(group => group.Id == id);
                    removedGroups.Add(id);
                    continue;
                }

                remap[other.Id] = id;
                newGroups.RemoveAll(group => group.Id == other.Id);
                removedGroups.Add(other.Id);
            }

            var updated = new SyncClipGroup(id, synced.Name, synced.Created);
            var index = newGroups.FindIndex(group => group.Id == id);
            if (index >= 0)
            {
                newGroups[index] = updated;
            }
            else
            {
                newGroups.Add(updated);
            }
        }

        foreach (var id in removedGroups.Where(id => !remap.ContainsKey(id)))
        {
            if (groups.FirstOrDefault(group => group.Id == id)?.Name is { } name &&
                newGroups.FirstOrDefault(group => group.Name == name) is { } same)
            {
                remap[id] = same.Id;
            }
        }

        var byKey = new Dictionary<string, SyncClipGroup>(StringComparer.Ordinal);
        foreach (var group in newGroups)
        {
            byKey.TryAdd(GroupPrefix + group.Id, group);
        }

        var plan = new ClipSyncPlan();
        plan.Groups.AddRange(SyncEngine.Arranged(byKey.Keys, groupOrder).Select(key => byKey[key]));
        var groupIds = plan.Groups.Select(group => group.Id).ToHashSet(StringComparer.Ordinal);
        string? Resolved(string? id)
        {
            if (id is null)
            {
                return null;
            }

            var target = remap.TryGetValue(id, out var mapped) ? mapped : id;
            return groupIds.Contains(target) ? target : null;
        }

        // 条目
        var items = rows.Select(Item.From).ToList();
        var touched = new List<Item>();
        foreach (var item in items.Where(item => item.Group is not null && !groupIds.Contains(item.Group)))
        {
            item.Group = Resolved(item.Group);
            Touch(touched, item);
        }

        foreach (var (id, synced) in clipChanges)
        {
            var existing = items.FirstOrDefault(item => item.Uid == id);
            if (synced is null)
            {
                // 别处删了 / 不再留着：本机取消收藏、移出片段和收藏夹（不删行）。
                if (existing is not null)
                {
                    existing.Favorite = false;
                    existing.Snippet = false;
                    existing.Group = null;
                    Touch(touched, existing);
                }

                continue;
            }

            Item item;
            if (existing is not null)
            {
                items.Remove(existing);
                item = existing;
            }
            else
            {
                item = new Item { Uid = id, CopiedAt = now };
            }

            if (item.Row is not null && item.Text != synced.Text)
            {
                item.TextChanged = true;
            }

            item.Text = synced.Text;
            item.Snippet = synced.Snippet;
            item.Note = synced.Note;
            item.Group = Resolved(synced.Group);
            item.Favorite = synced.Favorite || item.Group is not null;
            if (items.FirstOrDefault(other => other.Text == synced.Text && other.Uid != id) is { } other)
            {
                items.Remove(other);
                // 留着的、编号又比来的小：留本机那条；否则留来的（没有编号的普通条目永远让位）。
                var keeper = other.IsRetained && other.Uid is not null && string.CompareOrdinal(other.Uid, id) < 0
                    ? other
                    : item;
                var loser = ReferenceEquals(keeper, other) ? item : other;
                touched.Remove(loser);
                keeper.Favorite = keeper.Favorite || loser.Favorite;
                keeper.Snippet = keeper.Snippet || loser.Snippet;
                keeper.Note ??= loser.Note;
                keeper.Group ??= loser.Group;
                keeper.Favorite = keeper.Favorite || keeper.Group is not null;
                keeper.CopiedAt = Math.Max(keeper.CopiedAt, loser.CopiedAt);
                if (ReferenceEquals(keeper, item) && item.Row is null && loser.Row is not null)
                {
                    // 新来的接过那一行（同样的正文），不删了再插。
                    item.Row = loser.Row;
                }
                else if (loser.Row is { } row)
                {
                    plan.Deletes.Add(row);
                }

                item = keeper;
            }

            items.Add(item);
            Touch(touched, item);
        }

        plan.Writes.AddRange(touched.Select(item => item.ToWrite()));
        return plan;
    }

    private static void Touch(List<Item> touched, Item item)
    {
        if (!touched.Contains(item))
        {
            touched.Add(item);
        }
    }

    private static int Compare(bool firstRemoved, string firstId, bool secondRemoved, string secondId)
    {
        var first = firstRemoved ? 0 : 1;
        var second = secondRemoved ? 0 : 1;
        return first != second ? first.CompareTo(second) : string.CompareOrdinal(firstId, secondId);
    }
}

/// <summary>四类共用的小工具：读一条内容的字段、顺序那条的严格解码、字符串的规范写法。</summary>
public static class SyncValues
{
    public static string Quote(string value)
    {
        var builder = new StringBuilder();
        CanonicalJson.WriteString(value, builder);
        return builder.ToString();
    }

    /// <summary>解开一条；不是对象、不是 JSON = null。</summary>
    public static T? Read<T>(string value, Func<JsonElement, T?> read)
        where T : class
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            return document.RootElement.ValueKind == JsonValueKind.Object ? read(document.RootElement) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string? Text(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static bool Flag(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    /// <summary>三态布尔：没写 = null，false / true 原样。R32 的 usesDeepLX 要用。</summary>
    public static bool? FlagOrNull(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) &&
           value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    public static long? Number(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number &&
           value.TryGetInt64(out var number)
            ? number
            : null;

    /// <summary>顺序那条（编号数组）；解不出来、或编回去不一样 = null。</summary>
    public static List<string>? DecodeOrder(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var ids = new List<string>();
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                ids.Add(item.GetString()!);
            }

            return SyncEngine.OrderValue(ids) == value ? ids : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
