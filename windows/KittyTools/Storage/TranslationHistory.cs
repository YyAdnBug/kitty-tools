// 翻译历史与生词本（第三版 §3.1）：表 translations（第三版第 2 批的迁移加），
// 「原文 + 实际目标语言」唯一；只有第一个服务的完成结果写历史（同自动复制）；收藏的不受保留条数影响。
// 时间一律 Unix 毫秒；编号是 UUID（大写、带连字符，和 mac 一致——第五版同步要用）。
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class TranslationEntry
{
    public string Id { get; init; } = string.Empty;

    public string Source { get; init; } = string.Empty;

    public string? SourceLang { get; init; }

    public string TargetLang { get; init; } = string.Empty;

    public string Result { get; init; } = string.Empty;

    public string Service { get; init; } = string.Empty;

    public long CreatedAt { get; init; }

    public bool Favorite { get; init; }
}

internal sealed class TranslationHistory
{
    private readonly Database _database;
    private readonly List<TranslationEntry> _deleted = new();

    public TranslationHistory(Database database)
    {
        _database = database;
    }

    public static TranslationHistory? Instance { get; private set; }

    public static TranslationHistory? Start(Database database)
    {
        Instance = new TranslationHistory(database);
        return Instance;
    }

    public event Action? Changed;

    public bool CanUndo => _deleted.Count > 0;

    /// <summary>记一条；同样的原文 + 目标语言覆盖成最新的一条（收藏标记保留）。</summary>
    public void Add(string source, string? sourceLang, string targetLang, string result, string service, int limit)
    {
        source = Stored(source);
        result = result.Trim();
        if (source.Length == 0 || result.Length == 0 || targetLang.Length == 0)
        {
            return;
        }

        var existing = Find(source, targetLang);
        if (existing is not null)
        {
            using var update = _database.Connection.Prepare(
                "UPDATE translations SET result = $result, service = $service, created_at = $created " +
                "WHERE id = $id;");
            update.BindText(1, result);
            update.BindText(2, service);
            update.BindInt64(3, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            update.BindText(4, existing.Id);
            update.Step();
        }
        else
        {
            Insert(Guid.NewGuid().ToString("D").ToUpperInvariant(), source, sourceLang, targetLang, result, service,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), favorite: false);
        }

        Enforce(limit);
        Log.Info($"translate.history service={service} target={targetLang}");
        Changed?.Invoke();
    }

    /// <summary>原文或译文包含关键词（不区分大小写），新→旧；0 = 不限（导出用）。offset：分页（历史列表一页 500，滚到底取下一页）。</summary>
    public List<TranslationEntry> Search(string query, bool favoritesOnly = false, int limit = 200, int offset = 0)
    {
        var conditions = new List<string>();
        var trimmed = query.Trim();
        if (trimmed.Length > 0)
        {
            conditions.Add("(source LIKE $q OR result LIKE $q)");
        }

        if (favoritesOnly)
        {
            conditions.Add("favorite = 1");
        }

        var sql = "SELECT id, source, source_lang, target_lang, result, service, created_at, favorite " +
                  "FROM translations " +
                  (conditions.Count > 0 ? "WHERE " + string.Join(" AND ", conditions) + " " : string.Empty) +
                  "ORDER BY created_at DESC" + (limit > 0 ? " LIMIT " + limit : string.Empty) +
                  (limit > 0 && offset > 0 ? " OFFSET " + offset : string.Empty) + ";";
        var entries = new List<TranslationEntry>();
        using var statement = _database.Connection.Prepare(sql);
        if (trimmed.Length > 0)
        {
            statement.BindText(1, "%" + trimmed + "%");
        }

        while (statement.Step())
        {
            entries.Add(Read(statement));
        }

        return entries;
    }

    /// <summary>
    /// 这段原文上一次的译文（不分大小写，生词本里的优先，再按时间）：启动器「fy 单词」那一行的副标题用（PLAN-v9-launcher R16）。
    /// </summary>
    public string? LatestResult(string source)
    {
        using var statement = _database.Connection.Prepare(
            "SELECT result FROM translations WHERE source = $source COLLATE NOCASE " +
            "ORDER BY favorite DESC, created_at DESC LIMIT 1;");
        statement.BindText(1, Stored(source));
        return statement.Step() ? statement.GetText(0) : null;
    }

    public (int Total, int Favorites) Counts()
    {
        using var statement = _database.Connection.Prepare(
            "SELECT count(*), coalesce(sum(favorite), 0) FROM translations;");
        return statement.Step() ? (statement.GetInt32(0), statement.GetInt32(1)) : (0, 0);
    }

    public bool IsFavorite(string source, string targetLang)
    {
        using var statement = _database.Connection.Prepare(
            "SELECT favorite FROM translations WHERE source = $source AND target_lang = $target AND favorite = 1;");
        statement.BindText(1, Stored(source));
        statement.BindText(2, targetLang);
        return statement.Step();
    }

    public void SetFavorite(string id, bool favorite)
    {
        using var statement = _database.Connection.Prepare(
            "UPDATE translations SET favorite = $favorite WHERE id = $id;");
        statement.BindInt64(1, favorite ? 1 : 0);
        statement.BindText(2, id);
        statement.Step();
        Changed?.Invoke();
    }

    /// <summary>按原文 + 目标语言收藏 / 取消收藏（浮窗顶栏和卡片上的按钮用）。</summary>
    public void SetFavorite(string source, string? sourceLang, string targetLang, string result, string service, bool favorite)
    {
        var existing = Find(source, targetLang);
        if (existing is null)
        {
            if (!favorite)
            {
                return;
            }

            Insert(Guid.NewGuid().ToString("D").ToUpperInvariant(), Stored(source), sourceLang, targetLang,
                result.Trim(), service, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), favorite: true);
        }
        else
        {
            SetFavorite(existing.Id, favorite);
            return;
        }

        Changed?.Invoke();
    }

    public void Delete(string id)
    {
        var entry = ById(id);
        if (entry is null)
        {
            return;
        }

        using (var statement = _database.Connection.Prepare("DELETE FROM translations WHERE id = $id;"))
        {
            statement.BindText(1, id);
            statement.Step();
        }

        _deleted.Add(entry);
        Changed?.Invoke();
    }

    /// <summary>关着历史时取消收藏 = 删掉这条（收藏时才记进去的，留着就成了「关了历史却有历史」；mac remove(source:target:)）。不进撤销栈。</summary>
    public void Remove(string source, string targetLang)
    {
        if (Find(source, targetLang) is not { } entry)
        {
            return;
        }

        using (var statement = _database.Connection.Prepare("DELETE FROM translations WHERE id = $id;"))
        {
            statement.BindText(1, entry.Id);
            statement.Step();
        }

        Changed?.Invoke();
    }

    /// <summary>开 / 关历史列表时清掉撤销栈（mac HistoryList.reset）：上一次打开时删的不能在这一次撤回来。</summary>
    public void ClearUndo() => _deleted.Clear();

    public TranslationEntry? Undo()
    {
        if (_deleted.Count == 0)
        {
            return null;
        }

        var entry = _deleted[^1];
        _deleted.RemoveAt(_deleted.Count - 1);
        Insert(entry.Id, entry.Source, entry.SourceLang, entry.TargetLang, entry.Result, entry.Service,
            entry.CreatedAt, entry.Favorite);
        Changed?.Invoke();
        return entry;
    }

    public void ClearNonFavorites()
    {
        using var statement = _database.Connection.Prepare("DELETE FROM translations WHERE favorite = 0;");
        statement.Step();
        _deleted.Clear();
        Changed?.Invoke();
    }

    /// <summary>导入的收藏（生词本）：同样的原文 + 目标语言只留一条，编号小的留下（几台挑出来的一样）。</summary>
    public int AdoptFavorites(IReadOnlyList<SettingsArchive.ArchiveWord> words)
    {
        var added = 0;
        foreach (var word in words)
        {
            if (word.Source is not { Length: > 0 } source || word.Target is not { Length: > 0 } target ||
                word.Result is not { Length: > 0 } result)
            {
                continue;
            }

            var stored = Stored(source);
            var existing = Find(stored, target);
            if (existing is not null)
            {
                if (!existing.Favorite)
                {
                    SetFavorite(existing.Id, true);
                }

                continue;
            }

            var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
            Insert(id, stored, null, target, result, word.Service ?? "unknown",
                word.CreatedAt?.ToUnixTimeMilliseconds() ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                favorite: true);
            added++;
        }

        if (added > 0)
        {
            Changed?.Invoke();
        }

        return added;
    }

    /// <summary>同步要的本机收藏（生词本）。</summary>
    public List<SyncWordRow> SyncRows()
        => Search(string.Empty, favoritesOnly: true, limit: 0)
            .Select(entry => new SyncWordRow(
                entry.Id, entry.Source, entry.TargetLang, entry.Result, entry.Service, entry.CreatedAt, entry.Favorite))
            .ToList();

    /// <summary>同步落地（照 mac HistoryStore.applySync）：Core 的 VocabularySync.Plan 算好的几步，和账本同一个事务
    /// （saveLedger 在事务里调）；没成回滚、抛出去。原文原样存（不 Trim）：存的和同步来的不一样，编回去对不上。</summary>
    public void ApplySyncOps(IReadOnlyList<SyncWordOp> ops, Action saveLedger)
    {
        _database.BeginTransaction();
        try
        {
            foreach (var op in ops)
            {
                switch (op.Step)
                {
                    case SyncWordStep.Unfavorite:
                        using (var statement = _database.Connection.Prepare(
                                   "UPDATE translations SET favorite = 0 WHERE id = $id;"))
                        {
                            statement.BindText(1, op.Id);
                            statement.Step();
                        }

                        break;
                    case SyncWordStep.Delete:
                        using (var statement = _database.Connection.Prepare("DELETE FROM translations WHERE id = $id;"))
                        {
                            statement.BindText(1, op.Id);
                            statement.Step();
                        }

                        break;
                    case SyncWordStep.Replace when op.Word is { } word:
                        using (var others = _database.Connection.Prepare(
                                   "DELETE FROM translations WHERE source = $source AND target_lang = $target AND id <> $id;"))
                        {
                            others.BindText(1, word.Source);
                            others.BindText(2, word.Target);
                            others.BindText(3, op.Id);
                            others.Step();
                        }

                        Insert(op.Id, word.Source, null, word.Target, word.Result, word.Service, word.Created,
                            favorite: true);
                        break;
                }
            }

            saveLedger();
            _database.Commit();
        }
        catch
        {
            _database.Rollback();
            throw;
        }

        if (ops.Count > 0)
        {
            Changed?.Invoke();
        }
    }

    private void Insert(
        string id, string source, string? sourceLang, string targetLang, string result, string service,
        long createdAt, bool favorite)
    {
        using var statement = _database.Connection.Prepare(
            """
            INSERT OR REPLACE INTO translations(id, source, source_lang, target_lang, result, service, created_at, favorite)
            VALUES ($id, $source, $sourceLang, $target, $result, $service, $created, $favorite);
            """);
        statement.BindText(1, id);
        statement.BindText(2, source);
        if (sourceLang is null)
        {
            statement.BindNull(3);
        }
        else
        {
            statement.BindText(3, sourceLang);
        }

        statement.BindText(4, targetLang);
        statement.BindText(5, result);
        statement.BindText(6, service);
        statement.BindInt64(7, createdAt);
        statement.BindInt64(8, favorite ? 1 : 0);
        statement.Step();
    }

    private void Enforce(int limit)
    {
        if (limit <= 0)
        {
            return;
        }

        using var statement = _database.Connection.Prepare(
            """
            DELETE FROM translations WHERE favorite = 0 AND id NOT IN (
              SELECT id FROM translations WHERE favorite = 0 ORDER BY created_at DESC LIMIT $limit);
            """);
        statement.BindInt64(1, limit);
        statement.Step();
    }

    private TranslationEntry? Find(string source, string targetLang)
    {
        using var statement = _database.Connection.Prepare(
            "SELECT id, source, source_lang, target_lang, result, service, created_at, favorite " +
            "FROM translations WHERE source = $source AND target_lang = $target LIMIT 1;");
        statement.BindText(1, Stored(source));
        statement.BindText(2, targetLang);
        return statement.Step() ? Read(statement) : null;
    }

    private TranslationEntry? ById(string id)
    {
        using var statement = _database.Connection.Prepare(
            "SELECT id, source, source_lang, target_lang, result, service, created_at, favorite " +
            "FROM translations WHERE id = $id;");
        statement.BindText(1, id);
        return statement.Step() ? Read(statement) : null;
    }

    private static TranslationEntry Read(SqliteStatement statement) => new()
    {
        Id = statement.GetText(0) ?? string.Empty,
        Source = statement.GetText(1) ?? string.Empty,
        SourceLang = statement.GetText(2),
        TargetLang = statement.GetText(3) ?? string.Empty,
        Result = statement.GetText(4) ?? string.Empty,
        Service = statement.GetText(5) ?? string.Empty,
        CreatedAt = statement.GetInt64(6),
        Favorite = statement.GetInt32(7) == 1,
    };

    private static string Stored(string source) => source.Trim('\r', '\n', ' ', '\t');
}
