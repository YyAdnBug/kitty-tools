// 数据库：逐版本迁移（USER_VERSION 1 → 2 → …，每步幂等，见 Core 的 Schema）和 clips 的增删改查。
// 图片文件由 ImageStore 管；这里只存路径要用的字段和元数据。
using KittyTools.Core;
using KittyTools.Core.Sync;

namespace KittyTools.Infrastructure;

internal sealed class ClipGroup
{
    public string Id { get; init; } = string.Empty;

    public string Name { get; init; } = string.Empty;

    public int Position { get; init; }

    public long CreatedAt { get; init; }
}

internal sealed class Database : IDisposable
{
    private readonly SqliteConnection _connection;

    public Database(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _connection = new SqliteConnection(path);
        Schema.Migrate(new MigrationExecutor(_connection));
    }

    public static Database OpenDefault() => new(Paths.DatabaseFile);

    /// <summary>同一条连接（翻译历史 / 生词本 / 同步账本用）；只许在 UI 线程上用。</summary>
    public SqliteConnection Connection => _connection;

    /// <summary>同步落地：合并出来的改动和账本在同一个事务里提交（R13；SyncRecords 文件头「执行层必须守住的」）。</summary>
    public void BeginTransaction() => _connection.Execute("BEGIN IMMEDIATE;");

    public void Commit() => _connection.Execute("COMMIT;");

    public void Rollback() => _connection.Execute("ROLLBACK;");

    public IReadOnlyList<ClipEntry> LoadClips()
    {
        var entries = new List<ClipEntry>();
        using var statement = _connection.Prepare(
            """
            SELECT id, kind, text, file_paths, image_hash, width, height, image_bytes,
                   source_exe, source_name, copied_at, favorite,
                   uid, snippet, note, group_id, ocr_text
            FROM clips ORDER BY copied_at DESC, id DESC
            """);
        while (statement.Step())
        {
            var kind = statement.GetText(1) switch
            {
                "image" => ClipKind.Image,
                "files" => ClipKind.Files,
                _ => ClipKind.Text,
            };
            entries.Add(new ClipEntry
            {
                Id = statement.GetInt64(0),
                Kind = kind,
                Text = statement.GetText(2),
                FilePaths = statement.GetText(3),
                ImageHash = statement.GetText(4),
                Width = statement.GetInt32(5),
                Height = statement.GetInt32(6),
                ImageBytes = statement.GetInt32(7),
                SourceExe = statement.GetText(8),
                SourceName = statement.GetText(9),
                CopiedAt = statement.GetInt64(10),
                Favorite = statement.GetInt64(11) != 0,
                Uid = statement.GetText(12),
                Snippet = statement.GetInt64(13) != 0,
                Note = statement.GetText(14),
                GroupId = statement.GetText(15),
                OcrText = statement.GetText(16),
            });
        }

        return entries;
    }

    public long Insert(ClipEntry entry, string? html = null, string? rtf = null)
    {
        using var statement = _connection.Prepare(
            """
            INSERT INTO clips(kind, text, file_paths, html, rtf, image_hash, width, height, image_bytes,
                              source_exe, source_name, copied_at, favorite,
                              uid, snippet, note, group_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
            """);
        statement.BindText(1, KindText(entry.Kind))
            .BindText(2, entry.Text)
            .BindText(3, entry.FilePaths)
            .BindText(4, html)
            .BindText(5, rtf)
            .BindText(6, entry.ImageHash)
            .BindInt64(7, entry.Width)
            .BindInt64(8, entry.Height)
            .BindInt64(9, entry.ImageBytes)
            .BindText(10, entry.SourceExe)
            .BindText(11, entry.SourceName)
            .BindInt64(12, entry.CopiedAt)
            .BindInt64(13, entry.Favorite ? 1 : 0)
            .BindText(14, entry.Uid)
            .BindInt64(15, entry.Snippet ? 1 : 0)
            .BindText(16, entry.Note)
            .BindText(17, entry.GroupId);
        statement.Step();
        return _connection.LastInsertRowId;
    }

    /// <summary>同样内容再复制一次：时间、来源和格式以最近这次为准，id / 收藏不动。</summary>
    public void UpdateForRerecord(ClipEntry entry, string? html, string? rtf)
    {
        using var statement = _connection.Prepare(
            """
            UPDATE clips SET copied_at = ?2, source_exe = ?3, source_name = ?4, html = ?5, rtf = ?6
            WHERE id = ?1
            """);
        statement.BindInt64(1, entry.Id)
            .BindInt64(2, entry.CopiedAt)
            .BindText(3, entry.SourceExe)
            .BindText(4, entry.SourceName)
            .BindText(5, html)
            .BindText(6, rtf);
        statement.Step();
    }

    public void Touch(long id, long copiedAt)
    {
        using var statement = _connection.Prepare("UPDATE clips SET copied_at = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindInt64(2, copiedAt);
        statement.Step();
    }

    public void SetFavorite(long id, bool favorite)
    {
        using var statement = _connection.Prepare(
            "UPDATE clips SET favorite = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindInt64(2, favorite ? 1 : 0);
        statement.Step();
        if (!favorite)
        {
            // 不变式：有收藏夹的条目一定是收藏；取消收藏就解除归属。
            using var clear = _connection.Prepare("UPDATE clips SET group_id = NULL WHERE id = ?1");
            clear.BindInt64(1, id);
            clear.Step();
        }
    }

    public void SetSnippet(long id, bool snippet)
    {
        using var statement = _connection.Prepare("UPDATE clips SET snippet = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindInt64(2, snippet ? 1 : 0);
        statement.Step();
    }

    public void SetNote(long id, string? note)
    {
        using var statement = _connection.Prepare("UPDATE clips SET note = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindText(2, note);
        statement.Step();
    }

    public void SetText(long id, string text)
    {
        using var statement = _connection.Prepare("UPDATE clips SET text = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindText(2, text);
        statement.Step();
    }

    public void SetGroup(long id, string? groupId)
    {
        using (var statement = _connection.Prepare(
                   "UPDATE clips SET group_id = ?2, favorite = CASE WHEN ?2 IS NULL THEN favorite ELSE 1 END " +
                   "WHERE id = ?1"))
        {
            statement.BindInt64(1, id).BindText(2, groupId);
            statement.Step();
        }
    }

    /// <summary>同步落地一条（调用方开着事务）：正文变了时带格式的原始数据跟着清掉（不然粘出来的还是旧格式）。</summary>
    public void SetSynced(long id, SyncClipWrite write)
    {
        using var statement = _connection.Prepare(
            """
            UPDATE clips SET uid = COALESCE(?2, uid), text = ?3, favorite = ?4, snippet = ?5, note = ?6, group_id = ?7,
                             copied_at = ?8,
                             html = CASE WHEN ?9 = 1 THEN NULL ELSE html END,
                             rtf = CASE WHEN ?9 = 1 THEN NULL ELSE rtf END
            WHERE id = ?1
            """);
        statement.BindInt64(1, id)
            .BindText(2, write.Uid)
            .BindText(3, write.Text)
            .BindInt64(4, write.Favorite ? 1 : 0)
            .BindInt64(5, write.Snippet ? 1 : 0)
            .BindText(6, write.Note)
            .BindText(7, write.Group)
            .BindInt64(8, write.CopiedAt)
            .BindInt64(9, write.TextChanged ? 1 : 0);
        statement.Step();
    }

    /// <summary>删行，不开自己的事务（同步落地时调用方已经开着）。</summary>
    public void DeleteRows(IReadOnlyCollection<long> ids)
    {
        using var statement = _connection.Prepare("DELETE FROM clips WHERE id = ?1");
        foreach (var id in ids)
        {
            statement.Reset();
            statement.BindInt64(1, id);
            statement.Step();
        }
    }

    public void SetOcr(long id, string? text)
    {
        using var statement = _connection.Prepare("UPDATE clips SET ocr_text = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindText(2, text);
        statement.Step();
    }

    public void SetUid(long id, string uid)
    {
        using var statement = _connection.Prepare("UPDATE clips SET uid = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindText(2, uid);
        statement.Step();
    }

    public List<ClipGroup> LoadGroups()
    {
        var groups = new List<ClipGroup>();
        using var statement = _connection.Prepare(
            "SELECT id, name, position, created_at FROM clip_groups ORDER BY position ASC, name ASC;");
        while (statement.Step())
        {
            groups.Add(new ClipGroup
            {
                Id = statement.GetText(0) ?? string.Empty,
                Name = statement.GetText(1) ?? string.Empty,
                Position = statement.GetInt32(2),
                CreatedAt = statement.GetInt64(3),
            });
        }

        return groups;
    }

    public void InsertGroup(string id, string name, int position, long createdAt)
    {
        using var statement = _connection.Prepare(
            "INSERT INTO clip_groups(id, name, position, created_at) VALUES (?1, ?2, ?3, ?4);");
        statement.BindText(1, id).BindText(2, name).BindInt64(3, position).BindInt64(4, createdAt);
        statement.Step();
    }

    /// <summary>同步落地：整张收藏夹表换成这些（名字唯一，先清后插免得改名互换时撞上）。调用方在事务里。</summary>
    public void ReplaceGroups(IReadOnlyList<ClipGroup> groups)
    {
        _connection.Execute("DELETE FROM clip_groups;");
        foreach (var group in groups)
        {
            InsertGroup(group.Id, group.Name, group.Position, group.CreatedAt);
        }
    }

    public void RenameGroup(string id, string name)
    {
        using var statement = _connection.Prepare("UPDATE clip_groups SET name = ?2 WHERE id = ?1;");
        statement.BindText(1, id).BindText(2, name);
        statement.Step();
    }

    public void MoveGroup(string id, int position)
    {
        using var statement = _connection.Prepare("UPDATE clip_groups SET position = ?2 WHERE id = ?1;");
        statement.BindText(1, id).BindInt64(2, position);
        statement.Step();
    }

    /// <summary>删除收藏夹：只解除归属（条目回到默认收藏），不删条目。</summary>
    public void DeleteGroup(string id)
    {
        _connection.Execute("BEGIN IMMEDIATE;");
        try
        {
            using (var clear = _connection.Prepare("UPDATE clips SET group_id = NULL WHERE group_id = ?1;"))
            {
                clear.BindText(1, id);
                clear.Step();
            }

            using (var delete = _connection.Prepare("DELETE FROM clip_groups WHERE id = ?1;"))
            {
                delete.BindText(1, id);
                delete.Step();
            }

            _connection.Execute("COMMIT;");
        }
        catch
        {
            _connection.Execute("ROLLBACK;");
            throw;
        }
    }

    public string? GroupName(string? id)
    {
        if (id is null)
        {
            return null;
        }

        using var statement = _connection.Prepare("SELECT name FROM clip_groups WHERE id = ?1;");
        statement.BindText(1, id);
        return statement.Step() ? statement.GetText(0) : null;
    }

    public void Delete(IReadOnlyCollection<long> ids)
    {
        if (ids.Count == 0)
        {
            return;
        }

        _connection.Execute("BEGIN IMMEDIATE;");
        try
        {
            using var statement = _connection.Prepare("DELETE FROM clips WHERE id = ?1");
            foreach (var id in ids)
            {
                statement.Reset();
                statement.BindInt64(1, id);
                statement.Step();
            }

            _connection.Execute("COMMIT;");
        }
        catch
        {
            _connection.Execute("ROLLBACK;");
            throw;
        }
    }

    /// <summary>粘贴时用：带格式的原始数据只在需要时读。</summary>
    public (string? Html, string? Rtf) LoadRich(long id)
    {
        using var statement = _connection.Prepare("SELECT html, rtf FROM clips WHERE id = ?1");
        statement.BindInt64(1, id);
        if (!statement.Step())
        {
            return (null, null);
        }

        return (statement.GetText(0), statement.GetText(1));
    }

    public void Clear()
    {
        _connection.Execute("DELETE FROM clips;");
    }

    // 启动器使用记录：每行 =（查询, 类型, 目标）；查询空串是全局使用分。
    public IReadOnlyList<LauncherUsageRow> LoadLauncherUsage()
    {
        var rows = new List<LauncherUsageRow>();
        using var statement = _connection.Prepare(
            "SELECT query, kind, target, title, score, used_at FROM launcher_usage");
        while (statement.Step())
        {
            rows.Add(new LauncherUsageRow(
                statement.GetText(0) ?? string.Empty,
                statement.GetText(1) ?? string.Empty,
                statement.GetText(2) ?? string.Empty,
                statement.GetText(3) ?? string.Empty,
                statement.GetInt64(4) == 0 ? 0 : BitConverter.Int64BitsToDouble(statement.GetInt64(4)),
                statement.GetInt64(5)));
        }

        return rows;
    }

    public void SaveLauncherUsage(LauncherUsageRow row)
    {
        using var statement = _connection.Prepare(
            """
            INSERT OR REPLACE INTO launcher_usage(query, kind, target, title, score, used_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """);
        statement.BindText(1, row.Query)
            .BindText(2, row.Kind)
            .BindText(3, row.Target)
            .BindText(4, row.Title)
            .BindInt64(5, BitConverter.DoubleToInt64Bits(row.Score))
            .BindInt64(6, row.UsedAt);
        statement.Step();
    }

    public void DeleteLauncherUsage(string query, string kind, string target)
    {
        using var statement = _connection.Prepare(
            "DELETE FROM launcher_usage WHERE query = ?1 AND kind = ?2 AND target = ?3");
        statement.BindText(1, query).BindText(2, kind).BindText(3, target);
        statement.Step();
    }

    public void ClearLauncherUsage() => _connection.Execute("DELETE FROM launcher_usage;");

    public void Dispose() => _connection.Dispose();

    /// <summary>把 SqliteConnection 包成 Schema 的逐版本迁移执行者。</summary>
    private sealed class MigrationExecutor : ISchemaExecutor
    {
        private readonly SqliteConnection _connection;

        public MigrationExecutor(SqliteConnection connection)
        {
            _connection = connection;
        }

        public int Version
        {
            get
            {
                using var version = _connection.Prepare("PRAGMA user_version;");
                return version.Step() ? (int)version.GetInt64(0) : 0;
            }
        }

        public void Execute(string sql) => _connection.Execute(sql);

        public void SetVersion(int version) => _connection.Execute($"PRAGMA user_version = {version};");
    }

    private static string KindText(ClipKind kind) => kind switch
    {
        ClipKind.Image => "image",
        ClipKind.Files => "files",
        _ => "text",
    };
}
