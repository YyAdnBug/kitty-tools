// 网页搜索与快捷链接接进同步（REVIEW R26；照 windows/reference/mac-sync/WebSearchSync.swift）：一条一个记录（编号 =
// SearchEngine.Id；内置的几个每台都是同一个编号），内容是名字、关键词、网址、兜底；顺序单独一条（~order）。
// 第一次合时同网址、同关键词的只留文件夹里那条。落地：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排；
// 有一条解不出来（或者是更新版本写的）整个不落。
namespace KittyTools.Core.Sync;

public static class EngineSync
{
    public const string Kind = "engines";

    public static Dictionary<string, string> Values(IReadOnlyList<SearchEngine> engines)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var engine in engines)
        {
            values.TryAdd(engine.Id, Engine(engine));
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(engines.Select(engine => engine.Id));
        return values;
    }

    /// <summary>mac WebSearchSync.Synced：fallback / keyword / name / url。</summary>
    public static string Engine(SearchEngine engine)
        => $"{{\"fallback\":{(engine.Fallback ? "true" : "false")},\"keyword\":{SyncValues.Quote(engine.Keyword)}," +
           $"\"name\":{SyncValues.Quote(engine.Name)},\"url\":{SyncValues.Quote(engine.UrlTemplate)}}}";

    public static string? JoinKey(string value)
        => SyncValues.Read(value, root =>
            SyncValues.Text(root, "url") is { } url && SyncValues.Text(root, "keyword") is { } keyword
                ? url + "\0" + keyword
                : null);

    private static SearchEngine? Decode(string id, string value)
    {
        var engine = SyncValues.Read(value, root =>
            SyncValues.Text(root, "name") is { } name && SyncValues.Text(root, "keyword") is { } keyword &&
            SyncValues.Text(root, "url") is { } url
                ? new SearchEngine
                {
                    Id = id, Name = name, Keyword = keyword, UrlTemplate = url,
                    Fallback = SyncValues.Flag(root, "fallback"),
                }
                : null);
        return engine is not null && Engine(engine) == value ? engine : null;
    }

    /// <summary>当前列表 + 改动 → 落地后的列表；解不开返回 null。</summary>
    public static List<SearchEngine>? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<SearchEngine> current, out string? failure)
    {
        failure = null;
        var engines = new Dictionary<string, SearchEngine>(StringComparer.Ordinal);
        foreach (var engine in current)
        {
            engines.TryAdd(engine.Id, engine);
        }

        IReadOnlyList<string> order = current.Select(engine => engine.Id).ToList();
        foreach (var (id, value) in changes)
        {
            if (id == SyncEngine.OrderID)
            {
                if (value is null)
                {
                    continue;
                }

                if (SyncValues.DecodeOrder(value) is not { } ids)
                {
                    failure = ClipSync.Unreadable;
                    return null;
                }

                order = ids;
                continue;
            }

            if (value is null)
            {
                engines.Remove(id);
                continue;
            }

            if (Decode(id, value) is not { } engine)
            {
                failure = ClipSync.Unreadable;
                return null;
            }

            engines[id] = engine;
        }

        return SyncEngine.Arranged(engines.Keys, order).Select(id => engines[id]).ToList();
    }
}
