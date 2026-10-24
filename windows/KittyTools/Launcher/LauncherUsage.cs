// 启动器使用记录：launcher_usage 表（和剪贴板共用一个库）。每行 =（查询, 类型, 目标）；
// 查询是空串的行是全局使用分（14 天常数），非空的是「这个查询选过它」（3 天常数）。
// 每用一次：分 = 衰减到现在的分 + 1。空查询的「常用」按全局分排。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal readonly record struct LauncherUsageRow(
    string Query,
    string Kind,
    string Target,
    string Title,
    double Score,
    long UsedAt);

internal sealed class LauncherUsageStore
{
    public static LauncherUsageStore? Instance { get; private set; }

    private readonly Database _database;
    private readonly Dictionary<string, LauncherUsageRow> _entries = new();
    private readonly List<LauncherUsageRow> _tops = new();

    private LauncherUsageStore(Database database)
    {
        _database = database;
        foreach (var row in database.LoadLauncherUsage())
        {
            _entries[Key(row.Query, row.Kind, row.Target)] = row;
        }
    }

    public static LauncherUsageStore Start(Database database)
    {
        Instance = new LauncherUsageStore(database);
        return Instance;
    }

    public LauncherBoost Boost(LauncherItem item, string query, long now)
    {
        var kind = KindText(item.Kind);
        var global = _entries.TryGetValue(Key(string.Empty, kind, item.Target), out var g)
            ? LauncherUsageMath.Decayed(g.Score, g.UsedAt, now, LauncherUsageMath.GlobalTimeConstantDays)
            : 0;
        var normalized = LauncherUsageMath.NormalizeQuery(query);
        var affinity = normalized.Length > 0 &&
                       _entries.TryGetValue(Key(normalized, kind, item.Target), out var q)
            ? LauncherUsageMath.Decayed(q.Score, q.UsedAt, now, LauncherUsageMath.QueryTimeConstantDays)
            : 0;
        return new LauncherBoost(global, affinity);
    }

    public void Record(LauncherItem item, string query, long now)
    {
        var normalized = LauncherUsageMath.NormalizeQuery(query);
        RecordOne(item, string.Empty, now, LauncherUsageMath.GlobalTimeConstantDays);
        if (normalized.Length > 0)
        {
            RecordOne(item, normalized, now, LauncherUsageMath.QueryTimeConstantDays);
        }

        Prune(now);
    }

    /// <summary>空查询的「常用」：全局分最高的前 N 条（由调用方按能否还原过滤）。</summary>
    public IReadOnlyList<LauncherUsageRow> Top(int limit, long now)
    {
        _tops.Clear();
        _tops.AddRange(_entries.Values
            .Where(row => row.Query.Length == 0)
            .OrderByDescending(row => LauncherUsageMath.Decayed(
                row.Score, row.UsedAt, now, LauncherUsageMath.GlobalTimeConstantDays))
            .Take(limit));
        return _tops;
    }

    public void Clear()
    {
        _entries.Clear();
        _database.ClearLauncherUsage();
    }

    private void RecordOne(LauncherItem item, string query, long now, double timeConstantDays)
    {
        var key = Key(query, KindText(item.Kind), item.Target);
        var previous = _entries.TryGetValue(key, out var old)
            ? LauncherUsageMath.Decayed(old.Score, old.UsedAt, now, timeConstantDays)
            : 0;
        var row = new LauncherUsageRow(query, KindText(item.Kind), item.Target, item.Title, previous + 1, now);
        _entries[key] = row;
        try
        {
            _database.SaveLauncherUsage(row);
        }
        catch (Exception ex)
        {
            Log.Error("launcher.usage-save-failed", ex);
        }
    }

    private void Prune(long now)
    {
        foreach (var (isGlobal, limit, timeConstant) in new[]
                 {
                     (true, LauncherUsageMath.GlobalLimit, LauncherUsageMath.GlobalTimeConstantDays),
                     (false, LauncherUsageMath.QueryLimit, LauncherUsageMath.QueryTimeConstantDays),
                 })
        {
            var group = _entries.Values.Where(row => (row.Query.Length == 0) == isGlobal).ToList();
            if (group.Count <= limit + 32)
            {
                continue;
            }

            foreach (var row in group
                         .OrderBy(item => LauncherUsageMath.Decayed(item.Score, item.UsedAt, now, timeConstant))
                         .Take(group.Count - limit))
            {
                _entries.Remove(Key(row.Query, row.Kind, row.Target));
                _database.DeleteLauncherUsage(row.Query, row.Kind, row.Target);
            }
        }
    }

    public static string KindText(LauncherKind kind) => kind switch
    {
        LauncherKind.App => "app",
        LauncherKind.Setting => "setting",
        LauncherKind.Command => "command",
        LauncherKind.Action => "action",
        LauncherKind.Url => "url",
        LauncherKind.Path => "path",
        LauncherKind.Search => "search",
        _ => "calculation",
    };

    public static LauncherKind KindFromText(string kind) => kind switch
    {
        "app" => LauncherKind.App,
        "setting" => LauncherKind.Setting,
        "command" => LauncherKind.Command,
        "action" => LauncherKind.Action,
        "url" => LauncherKind.Url,
        "path" => LauncherKind.Path,
        "search" => LauncherKind.Search,
        _ => LauncherKind.Calculation,
    };

    private static string Key(string query, string kind, string target) => query + "\n" + kind + "\n" + target;
}
