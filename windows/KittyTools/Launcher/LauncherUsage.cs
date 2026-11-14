// 启动器使用记录：launcher_usage 表（和剪贴板共用一个库）。每行 =（查询, 类型, 目标）；
// 查询是空串的行是全局使用分（14 天常数），非空的是「这个查询选过它」（28 天常数，PLAN-v18 L6）。
// 输入的开头也算（mac ea0c2813，对标 Raycast）：在「sha」下选过的，输「s」「sh」时按一半算；提到固定行前面仍只认一字不差（Chose）。
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
    long UsedAt,
    bool Listed = false);

internal sealed class LauncherUsageStore
{
    public static LauncherUsageStore? Instance { get; private set; }

    private readonly Database _database;
    private readonly Dictionary<string, LauncherUsageRow> _entries = new();
    private readonly List<LauncherUsageRow> _tops = new();
    /// <summary>这次输入是哪些记录的查询的开头（不含一字不差的那条），按「类型 + 目标」分组；每敲一个字给几百个应用各算一次，先挑出来，记录一变就作废。</summary>
    private (string Query, Dictionary<string, List<LauncherUsageRow>> Rows)? _longer;

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
        if (normalized.Length == 0)
        {
            return new LauncherBoost(global, 0);
        }

        var exact = _entries.TryGetValue(Key(normalized, kind, item.Target), out var q)
            ? LauncherUsageMath.Decayed(q.Score, q.UsedAt, now, LauncherUsageMath.QueryTimeConstantDays)
            : 0;
        var longer = Longer(normalized).TryGetValue(Key(string.Empty, kind, item.Target), out var rows)
            ? rows.Sum(row => LauncherUsageMath.Decayed(row.Score, row.UsedAt, now, LauncherUsageMath.QueryTimeConstantDays))
            : 0;
        return new LauncherBoost(global, exact + LauncherUsageMath.PrefixWeight * longer);
    }

    /// <summary>在一字不差的这个输入下选过它（第四轮体检 E8：这种才排到固定行前面；开头对上的不算）。</summary>
    public bool Chose(LauncherItem item, string query)
    {
        var normalized = LauncherUsageMath.NormalizeQuery(query);
        return normalized.Length > 0 && _entries.ContainsKey(Key(normalized, KindText(item.Kind), item.Target));
    }

    private Dictionary<string, List<LauncherUsageRow>> Longer(string normalized)
    {
        if (_longer is { } cached && cached.Query == normalized)
        {
            return cached.Rows;
        }

        var found = new Dictionary<string, List<LauncherUsageRow>>();
        foreach (var row in _entries.Values)
        {
            if (row.Query.Length > normalized.Length && row.Query.StartsWith(normalized, StringComparison.Ordinal))
            {
                var key = Key(string.Empty, row.Kind, row.Target);
                if (!found.TryGetValue(key, out var list))
                {
                    found[key] = list = new List<LauncherUsageRow>();
                }

                list.Add(row);
            }
        }

        _longer = (normalized, found);
        return found;
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

    /// <summary>
    /// 「常用」里 Ctrl+Delete（mac forget）：忘掉这一项的全部使用记录（全局的和各个查询的），返回删掉的那几行，Ctrl+Z 原样放回。
    /// </summary>
    public List<LauncherUsageRow> Forget(LauncherItem item)
    {
        var kind = KindText(item.Kind);
        var removed = _entries.Values.Where(row => row.Kind == kind && row.Target == item.Target).ToList();
        _longer = null;
        foreach (var row in removed)
        {
            _entries.Remove(Key(row.Query, row.Kind, row.Target));
            _database.DeleteLauncherUsage(row.Query, row.Kind, row.Target);
        }

        return removed;
    }

    /// <summary>撤销移除：把 Forget 删掉的几行原样写回。</summary>
    public void Restore(IEnumerable<LauncherUsageRow> rows)
    {
        _longer = null;
        foreach (var row in rows)
        {
            _entries[Key(row.Query, row.Kind, row.Target)] = row;
            try
            {
                _database.SaveLauncherUsage(row);
            }
            catch (Exception ex)
            {
                Log.Error("launcher.usage-restore-failed", ex);
            }
        }
    }

    /// <summary>用过的网址 / 文件（mac usedLocations）：不在任何目录里，靠全局使用记录找回来，和应用一起参与排序。</summary>
    public IEnumerable<LauncherUsageRow> UsedLocations()
        => _entries.Values.Where(row => row.Query.Length == 0 && row.Kind is "url" or "path");

    public void Clear()
    {
        _entries.Clear();
        _longer = null;
        _database.ClearLauncherUsage();
    }

    private void RecordOne(LauncherItem item, string query, long now, double timeConstantDays)
    {
        var key = Key(query, KindText(item.Kind), item.Target);
        var previous = _entries.TryGetValue(key, out var old)
            ? LauncherUsageMath.Decayed(old.Score, old.UsedAt, now, timeConstantDays)
            : 0;
        // 最后一次是从书签 / 快捷链接打开的：只在它还在那份列表里时列出来（PLAN-v16 L2）
        var row = new LauncherUsageRow(query, KindText(item.Kind), item.Target, item.Title, previous + 1, now, item.Listed);
        _entries[key] = row;
        _longer = null;
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
        _longer = null;
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
        LauncherKind.Clip => "clip",
        LauncherKind.Translate => "translate",
        LauncherKind.Prompt => "prompt",
        LauncherKind.Process => "process",
        LauncherKind.Ip => "ip",
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
