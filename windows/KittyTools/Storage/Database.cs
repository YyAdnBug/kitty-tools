// 数据库：建表、迁移（PRAGMA user_version，幂等）和 clips 的增删改查。
// 图片文件由 ImageStore 管；这里只存路径要用的字段和元数据。
using KittyTools.Core;

namespace KittyTools.Infrastructure;

internal sealed class Database : IDisposable
{
    private const int SchemaVersion = 1;
    private readonly SqliteConnection _connection;

    public Database(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _connection = new SqliteConnection(path);
        Migrate();
    }

    public static Database OpenDefault() => new(Paths.DatabaseFile);

    public IReadOnlyList<ClipEntry> LoadClips()
    {
        var entries = new List<ClipEntry>();
        using var statement = _connection.Prepare(
            """
            SELECT id, kind, text, file_paths, image_hash, width, height, image_bytes,
                   source_exe, source_name, copied_at, favorite
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
            });
        }

        return entries;
    }

    public long Insert(ClipEntry entry, string? html = null, string? rtf = null)
    {
        using var statement = _connection.Prepare(
            """
            INSERT INTO clips(kind, text, file_paths, html, rtf, image_hash, width, height, image_bytes,
                              source_exe, source_name, copied_at, favorite)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
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
            .BindInt64(13, entry.Favorite ? 1 : 0);
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
        using var statement = _connection.Prepare("UPDATE clips SET favorite = ?2 WHERE id = ?1");
        statement.BindInt64(1, id).BindInt64(2, favorite ? 1 : 0);
        statement.Step();
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

    public void Dispose() => _connection.Dispose();

    private void Migrate()
    {
        using (var version = _connection.Prepare("PRAGMA user_version;"))
        {
            if (version.Step() && version.GetInt64(0) >= SchemaVersion)
            {
                return;
            }
        }

        _connection.Execute("BEGIN IMMEDIATE;");
        try
        {
            _connection.Execute(
                """
                CREATE TABLE IF NOT EXISTS clips(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind TEXT NOT NULL,
                  text TEXT,
                  file_paths TEXT,
                  html TEXT,
                  rtf TEXT,
                  image_hash TEXT,
                  width INTEGER NOT NULL DEFAULT 0,
                  height INTEGER NOT NULL DEFAULT 0,
                  image_bytes INTEGER NOT NULL DEFAULT 0,
                  source_exe TEXT,
                  source_name TEXT,
                  copied_at INTEGER NOT NULL,
                  favorite INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS clips_copied_at ON clips(copied_at DESC, id DESC);
                """);
            _connection.Execute($"PRAGMA user_version = {SchemaVersion};");
            _connection.Execute("COMMIT;");
        }
        catch
        {
            _connection.Execute("ROLLBACK;");
            throw;
        }
    }

    private static string KindText(ClipKind kind) => kind switch
    {
        ClipKind.Image => "image",
        ClipKind.Files => "files",
        _ => "text",
    };
}
