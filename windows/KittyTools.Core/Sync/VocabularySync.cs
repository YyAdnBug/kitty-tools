// 生词本接进同步（REVIEW R26；照 windows/reference/mac-sync/HistoryStore.swift 的 `extension HistoryStore: SyncSource`）。
// 纯函数：编出去（收藏的那几条翻译）和落回来（要对库做的几步）。
// - Values：收藏的翻译；原文或译文带 NUL 的不同步（库里存的是截断的，重启后和账本对不上）。
// - JoinKey：第一次合时同原文 + 同目标语言的只留文件夹里那条。
// - Plan：先取消收藏的、再新来的，同一类里按编号；新来的和本机另一条**收藏的**同原文 + 同目标语言撞上：编号小的留下——
//   本机那条小就不落来的这条（它的编号本机删掉，下一轮这个删除传出去），来的小就换掉本机那条（同原文 + 同目标语言的
//   普通记录也让位，一句话只留一条）。原文原样存（不 Trim：存的和同步来的不一样，编回去对不上，两台来回改）。
namespace KittyTools.Core.Sync;

/// <summary>本机一条翻译（同步只看收藏的；Created 是毫秒）。</summary>
public sealed record SyncWordRow(
    string Id, string Source, string Target, string Result, string Service, long Created, bool Favorite);

public enum SyncWordStep
{
    /// <summary>不再收藏（还在历史里）。</summary>
    Unfavorite,

    /// <summary>删掉这一行（同原文 + 目标语言已经有编号更小的收藏）。</summary>
    Delete,

    /// <summary>删掉同原文 + 目标语言的别的行，再按这个编号写成收藏。</summary>
    Replace,
}

public sealed record SyncWordOp(SyncWordStep Step, string Id, SyncWordRow? Word);

public static class VocabularySync
{
    public const string Kind = "vocabulary";

    public static Dictionary<string, string> Values(IEnumerable<SyncWordRow> rows)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var row in rows.Where(row => row.Favorite))
        {
            if ((row.Source + row.Result).Contains('\0'))
            {
                continue;
            }

            values[row.Id] = Word(row.Source, row.Target, row.Result, row.Service, row.Created);
        }

        return values;
    }

    /// <summary>mac SyncedWord：created / result / service / source / target。</summary>
    public static string Word(string source, string target, string result, string service, long created)
        => $"{{\"created\":{created},\"result\":{SyncValues.Quote(result)},\"service\":{SyncValues.Quote(service)}," +
           $"\"source\":{SyncValues.Quote(source)},\"target\":{SyncValues.Quote(target)}}}";

    public static string? JoinKey(string value)
        => SyncValues.Read(value, root =>
            SyncValues.Text(root, "source") is { } source && SyncValues.Text(root, "target") is { } target
                ? source + "\0" + target
                : null);

    private static SyncWordRow? Decode(string id, string value)
    {
        var word = SyncValues.Read(value, root =>
            SyncValues.Text(root, "source") is { } source && SyncValues.Text(root, "target") is { } target &&
            SyncValues.Text(root, "result") is { } result && SyncValues.Text(root, "service") is { } service &&
            SyncValues.Number(root, "created") is { } created
                ? new SyncWordRow(id, source, target, result, service, created, Favorite: true)
                : null);
        return word is not null && Word(word.Source, word.Target, word.Result, word.Service, word.Created) == value
            ? word
            : null;
    }

    /// <summary>favorites：本机现在收藏着的（只用来判断「撞上的那条编号小不小」）。</summary>
    public static List<SyncWordOp>? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<SyncWordRow> favorites, out string? failure)
    {
        failure = null;
        var words = new List<(string Id, SyncWordRow? Word)>();
        foreach (var (id, value) in changes)
        {
            if (value is null)
            {
                words.Add((id, null));
                continue;
            }

            if (Decode(id, value) is not { } word)
            {
                failure = ClipSync.Unreadable;
                return null;
            }

            words.Add((id, word));
        }

        words.Sort((a, b) =>
        {
            var first = a.Word is null ? 0 : 1;
            var second = b.Word is null ? 0 : 1;
            return first != second ? first.CompareTo(second) : string.CompareOrdinal(a.Id, b.Id);
        });

        // 一边出步骤一边记「落到这一步时本机收藏着哪些」：后面的判断要看到前面的步骤（mac 是在同一个事务里查库）。
        var liked = favorites.Where(row => row.Favorite).ToDictionary(row => row.Id, StringComparer.Ordinal);
        var ops = new List<SyncWordOp>();
        foreach (var (id, word) in words)
        {
            if (word is null)
            {
                liked.Remove(id);
                ops.Add(new SyncWordOp(SyncWordStep.Unfavorite, id, null));
                continue;
            }

            var kept = liked.Values.Any(row =>
                row.Source == word.Source && row.Target == word.Target && row.Id != id &&
                string.CompareOrdinal(row.Id, id) < 0);
            if (kept)
            {
                liked.Remove(id);
                ops.Add(new SyncWordOp(SyncWordStep.Delete, id, null));
                continue;
            }

            foreach (var other in liked.Values
                         .Where(row => row.Source == word.Source && row.Target == word.Target && row.Id != id)
                         .Select(row => row.Id).ToList())
            {
                liked.Remove(other);
            }

            liked[id] = word;
            ops.Add(new SyncWordOp(SyncWordStep.Replace, id, word));
        }

        return ops;
    }
}
