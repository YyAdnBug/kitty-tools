// 便签仓库（PLAN-v13 第 2 批，照 mac Notes/NoteStore.swift）：数据目录里单独的库 notes.sqlite3（winsqlite3，WAL，
// PRAGMA user_version 记表结构的版本），和剪贴板的库、图片、备份互不相干——剪贴板的清理、保留天数、「重新开始」都碰不到便签。
// 内存那一半（全部便签、改动的规则、视图、搜索、导入合并、同步落地）在 Core 的 NoteBook；这里是落盘和计时：
// - 正文和标题是一个字一个字改的：先改内存、记成「没落盘」，停手 250 ms 落一次、连着改满 2 s 必落一次；别的改动当场落。
//   Flush() = 现在就落：便签收起、退出、锁屏、睡眠前由调用方调。写不成的不丢：留在「没落盘」里，原因记在 SaveProblem，
//   过一会儿自己再试（5 秒起、每次翻倍、封顶 60 秒），下一次改动、下一次 Flush 也会带上；退出前还落不下去要问用户。
// - 表结构照 mac（notes / note_erased / note_meta，列名一样）。两边不互读库，照抄省得出错。
// - 电脑编号：同步的各类共用一个（kitty.sqlite3 的 SyncDevice）；剪贴板的库打不开、没有 SyncDevice 时用这个库 note_meta 里
//   自己记的那个（同 mac 记在便签库里），两边都没有就新建一个记下来。
// 线程：只在 UI 线程上用。
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal sealed class NoteStore : IDisposable
{
    /// <summary>表结构的版本：新库建好表就设成它。以后改表结构时 +1，在 Prepare 里按读到的旧版本升级。</summary>
    public const int SchemaVersion = 1;

    private const int QuietMs = 250;
    private const int MaxDelayMs = 2000;

    private const string Columns =
        "id, title, body, color, created_at, modified_at, revision, archived, pinned, sort_order, " +
        "deleted_at, tint, state_changed_at, clock, order_changed_at, written_revision";

    /// <summary>有就更新、没有就插入（不用 INSERT OR REPLACE：那是删了再插，rowid 会变）。</summary>
    private const string Upsert =
        "INSERT INTO notes(" + Columns + ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16) " +
        "ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body, color = excluded.color, " +
        "created_at = excluded.created_at, modified_at = excluded.modified_at, revision = excluded.revision, " +
        "archived = excluded.archived, pinned = excluded.pinned, sort_order = excluded.sort_order, " +
        "deleted_at = excluded.deleted_at, tint = excluded.tint, state_changed_at = excluded.state_changed_at, " +
        "clock = excluded.clock, order_changed_at = excluded.order_changed_at, written_revision = excluded.written_revision;";

    private readonly SqliteConnection _db;
    private readonly DispatcherQueueTimer _saveTimer;
    private readonly DispatcherQueueTimer _retryTimer;
    private readonly string _fallbackDevice;
    private long? _unsavedSince;
    private int _failures;

    private NoteStore(SqliteConnection db, string fallbackDevice, DispatcherQueue queue)
    {
        _db = db;
        _fallbackDevice = fallbackDevice;
        Book = new NoteBook(() => SyncDevice.Instance?.Id ?? _fallbackDevice);
        _saveTimer = queue.CreateTimer();
        _saveTimer.IsRepeating = false;
        _saveTimer.Tick += (_, _) => Flush();
        _retryTimer = queue.CreateTimer();
        _retryTimer.IsRepeating = false;
        _retryTimer.Tick += (_, _) => Flush();
    }

    public static NoteStore? Instance { get; private set; }

    /// <summary>内存那一半：视图、搜索、摘要直接读它；改动走这里的方法（带落盘）。</summary>
    public NoteBook Book { get; }

    /// <summary>图片目录（行内图片，notes-images/）。</summary>
    public NoteImageStore? Images { get; set; }

    /// <summary>上次落盘没成的原因；都落下去了是 null。</summary>
    public string? SaveProblem { get; private set; }

    /// <summary>便签变了（界面重画）。</summary>
    public event Action? Changed;

    /// <summary>这条便签现在还开在哪儿吗（那叠里开着、浮着、全部便签窗口里选着）：开着的空白便签不删。</summary>
    public Func<string, bool> IsOpen { get; set; } = _ => false;

    /// <summary>这条便签的正文框里还挂着没确认的组字：先不删，过 0.5 秒再看。</summary>
    public Func<string, bool> IsComposing { get; set; } = _ => false;

    public static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>打开便签库（建表、认版本、读表）。哪一步抛错都算打不开，由 NotesRecovery 接手。</summary>
    public static NoteStore Open(string path, DispatcherQueue queue)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var db = new SqliteConnection(path);
        try
        {
            Prepare(db);
            var store = new NoteStore(db, FallbackDevice(db), queue);
            store.Load();
            return store;
        }
        catch
        {
            db.Dispose();
            throw;
        }
    }

    public static NoteStore Start(string path, DispatcherQueue queue)
    {
        Instance = Open(path, queue);
        return Instance;
    }

    /// <summary>认版本、建表。读到的版本比认识的大就抛错（更新版本写的），什么都不写。</summary>
    public static void Prepare(SqliteConnection db)
    {
        long found;
        using (var version = db.Prepare("PRAGMA user_version;"))
        {
            found = version.Step() ? version.GetInt64(0) : 0;
        }

        if (found > SchemaVersion)
        {
            throw new NotesNewerException((int)found);
        }

        db.Execute(
            """
            CREATE TABLE IF NOT EXISTS notes(
              id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
              color INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
              modified_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
              archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
              sort_order REAL NOT NULL DEFAULT 0, deleted_at INTEGER, tint INTEGER, state_changed_at INTEGER,
              clock TEXT, order_changed_at INTEGER, written_revision INTEGER);
            """);
        db.Execute("CREATE TABLE IF NOT EXISTS note_erased(id TEXT PRIMARY KEY, clock TEXT NOT NULL, state_changed_at INTEGER NOT NULL);");
        db.Execute("CREATE TABLE IF NOT EXISTS note_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);");
        if (found < SchemaVersion)
        {
            db.Execute($"PRAGMA user_version = {SchemaVersion};");
        }
    }

    private static string FallbackDevice(SqliteConnection db)
    {
        using (var statement = db.Prepare("SELECT value FROM note_meta WHERE key = 'device';"))
        {
            if (statement.Step() && statement.GetText(0) is { } stored && Core.Sync.SyncFolderRules.IsDeviceName(stored))
            {
                return stored;
            }
        }

        var id = NoteBook.NewId();
        using var insert = db.Prepare("INSERT OR REPLACE INTO note_meta(key, value) VALUES ('device', ?1);");
        insert.BindText(1, id);
        insert.Step();
        return id;
    }

    private void Load()
    {
        using (var tombstones = _db.Prepare("SELECT id, clock, state_changed_at FROM note_erased;"))
        {
            while (tombstones.Step())
            {
                if (tombstones.GetText(0) is { } id && tombstones.GetText(1) is { } clock && !tombstones.IsNull(2))
                {
                    Book.LoadTombstone(id, new NoteSync.Tombstone(NoteSync.ClockFrom(clock), tombstones.GetInt64(2)));
                }
            }
        }

        using var rows = _db.Prepare($"SELECT {Columns} FROM notes ORDER BY rowid;");
        while (rows.Step())
        {
            if (Decode(rows) is { } note)
            {
                Book.Load(note, rows.GetNullableInt64(15), tinted: !rows.IsNull(11));
            }
        }
    }

    /// <summary>库文件也可能被别的东西改过：颜色、修订号夹进范围，不是有限数的顺序当 0。</summary>
    private static Note? Decode(SqliteStatement row)
    {
        if (row.GetText(0) is not { } id || row.IsNull(4) || row.IsNull(5))
        {
            return null;
        }

        var order = row.GetDouble(9);
        var tint = row.GetNullableInt64(11);
        return new Note
        {
            Id = id,
            Title = row.GetText(1) ?? string.Empty,
            Body = row.GetText(2) ?? string.Empty,
            Color = Note.ColorFromStored((int)Math.Clamp(row.GetInt64(3), int.MinValue, int.MaxValue),
                tint is { } value ? (int)Math.Clamp(value, int.MinValue, int.MaxValue) : null),
            CreatedAt = row.GetInt64(4),
            ModifiedAt = row.GetInt64(5),
            Revision = (int)Math.Clamp(row.GetInt64(6), 0, Note.MaxRevision),
            IsArchived = row.GetInt64(7) == 1,
            IsPinned = row.GetInt64(8) == 1,
            Order = double.IsFinite(order) ? order : 0,
            DeletedAt = row.GetNullableInt64(10),
            StateChangedAt = row.GetNullableInt64(12),
            OrderChangedAt = row.GetNullableInt64(14),
            Clock = row.GetText(13) is { } clock ? NoteSync.ClockFrom(clock) : new Dictionary<string, long>(StringComparer.Ordinal),
        };
    }

    private static void Bind(SqliteStatement statement, Note note)
    {
        statement.BindText(1, note.Id);
        statement.BindText(2, note.Title);
        statement.BindText(3, note.Body);
        statement.BindInt64(4, Note.StoredPreset(note.Color));
        statement.BindInt64(5, note.CreatedAt);
        statement.BindInt64(6, note.ModifiedAt);
        statement.BindInt64(7, note.Revision);
        statement.BindInt64(8, note.IsArchived ? 1 : 0);
        statement.BindInt64(9, note.IsPinned ? 1 : 0);
        statement.BindDouble(10, note.Order);
        Nullable(statement, 11, note.DeletedAt);
        Nullable(statement, 12, Note.StoredTint(note.Color));
        Nullable(statement, 13, note.StateChangedAt);
        statement.BindText(14, note.Clock.Count == 0 ? null : NoteSync.ClockText(note.Clock));
        Nullable(statement, 15, note.OrderChangedAt);
        statement.BindInt64(16, note.Revision);
    }

    private static void Nullable(SqliteStatement statement, int index, long? value)
    {
        if (value is { } number)
        {
            statement.BindInt64(index, number);
        }
        else
        {
            statement.BindNull(index);
        }
    }

    // ---- note_meta（同步记的「写出去的是第几轮」、图片的孤儿账等）----

    /// <summary>读不出来抛错（不当成没有：同步拿它认库被退回去了）。</summary>
    public string? Meta(string key)
    {
        using var statement = _db.Prepare("SELECT value FROM note_meta WHERE key = ?1;");
        statement.BindText(1, key);
        return statement.Step() ? statement.GetText(0) : null;
    }

    public void SetMeta(string key, string value)
    {
        using var statement = _db.Prepare("INSERT OR REPLACE INTO note_meta(key, value) VALUES (?1, ?2);");
        statement.BindText(1, key);
        statement.BindText(2, value);
        statement.Step();
    }

    // ---- 改动（规则在 NoteBook；这里管落盘和通知）----

    private void Notify() => Changed?.Invoke();

    public Note Create(string body = "", string title = "")
    {
        var note = Book.Create(Now, body, title);
        Flush();
        Notify();
        return note;
    }

    public Note BlankOrNew()
    {
        var count = Book.Generation;
        var note = Book.BlankOrNew(Now);
        if (Book.Generation != count)
        {
            Flush();
            Notify();
        }

        return note;
    }

    public void SetBody(string id, string body)
    {
        if (Book.SetBody(id, body, Now))
        {
            ScheduleSave();
            Notify();
        }
    }

    public void SetTitle(string id, string title)
    {
        if (Book.SetTitle(id, title, Now))
        {
            ScheduleSave();
            Notify();
        }
    }

    /// <summary>换纸色：当场落盘。live：取色边拖边变的那一串，同打字攒着等停手再落。</summary>
    public void SetColor(string id, int color, bool live = false)
    {
        if (!Book.SetColor(id, color, Now))
        {
            return;
        }

        if (live)
        {
            ScheduleSave();
        }
        else
        {
            Flush();
        }

        Notify();
    }

    public void SetArchived(string id, bool archived, bool toFront = true) => Commit(Book.SetArchived(id, archived, Now, toFront));

    public void SetPinned(string id, bool pinned) => Commit(Book.SetPinned(id, pinned, Now));

    public void Move(string id, int index) => Commit(Book.Move(id, index, Now));

    public void Delete(string id) => Commit(Book.Delete(id, Now));

    public void Restore(string id) => Commit(Book.Restore(id, Now));

    public void Erase(string id)
    {
        Book.Erase(new[] { id });
        Commit(true);
    }

    public int EmptyTrash()
    {
        var count = Book.EmptyTrash();
        Commit(count > 0);
        return count;
    }

    public int PurgeExpired()
    {
        var count = Book.PurgeExpired(Now);
        Commit(count > 0);
        return count;
    }

    private void Commit(bool changed)
    {
        if (changed)
        {
            Flush();
            Notify();
        }
    }

    /// <summary>一条便签从界面上下来了（关掉、换走、收回）：晚一拍看——这次运行里新建的、标题正文都空、没开在别处，就永久删掉。</summary>
    public void Left(string id)
    {
        if (!Book.WasCreatedThisRun(id))
        {
            return;
        }

        DispatcherQueue.GetForCurrentThread()?.TryEnqueue(DispatcherQueuePriority.Low, () => DropIfBlank(id));
    }

    private void DropIfBlank(string id)
    {
        switch (Book.DropIfBlank(id, Now, IsOpen(id), IsComposing(id)))
        {
            case NoteBook.Drop.Dropped:
                Commit(true);
                break;
            case NoteBook.Drop.Composing:
                _ = RecheckAsync(id);
                break;
        }
    }

    private async Task RecheckAsync(string id)
    {
        await Task.Delay(500);
        DropIfBlank(id);
    }

    /// <summary>导入（设置的导出 / 导入、Markdown 导入）。没落下去时 Saved 是 false（内容在内存里、留着重试）。</summary>
    public (int Added, int Updated, bool Saved) Adopt(IReadOnlyList<NoteEntry> entries, IReadOnlySet<string>? contentOnly = null)
    {
        var adoption = Book.Adopt(entries, Now, contentOnly);
        var saved = Flush();
        Notify();
        return (adoption.Added, adoption.Updated, saved);
    }

    /// <summary>把一轮同步合并的结果落下去。返回落没落下去（没落下去的留在内存里、照常重试）。</summary>
    public bool ApplySync(
        IReadOnlyDictionary<string, NoteSync.Merge> merges, IReadOnlyDictionary<string, NoteSync.Tombstone> tombstones)
    {
        var generation = Book.Generation;
        Book.ApplySync(merges, tombstones);
        var saved = Flush();
        if (Book.Generation != generation)
        {
            Notify();
        }

        return saved;
    }

    /// <summary>同步时认出便签库被退回去了：换一个新的电脑编号，bumping 里的每一条记一笔新编号的改动。先落这几条再记新编号；
    /// 便签没落下去返回 false（这一轮先不合）。</summary>
    public bool SwitchDevice(IReadOnlySet<string> bumping)
    {
        var old = Book.DeviceId;
        var id = NoteBook.NewId();
        Book.SwitchDevice(bumping, old, id);
        if (!Flush())
        {
            return false;
        }

        if (SyncDevice.Instance is { } device)
        {
            device.Rotate(id);
        }
        else
        {
            SetMeta("device", id);
        }

        Log.Info("notes.device-switched");
        Notify();
        return true;
    }

    // ---- 落盘 ----

    /// <summary>现在就把没落盘的都写下去（一个事务）。返回成没成：不成的留着、过一会儿自己再试。</summary>
    public bool Flush()
    {
        _saveTimer.Stop();
        _retryTimer.Stop();
        _unsavedSince = null;
        if (!Book.HasUnsaved)
        {
            return true;
        }

        var pending = Book.PendingWrites();
        try
        {
            _db.Execute("BEGIN IMMEDIATE;");
            try
            {
                using (var upsert = _db.Prepare(Upsert))
                {
                    foreach (var note in pending.Upserts)
                    {
                        Bind(upsert, note);
                        upsert.Step();
                        upsert.Reset();
                    }
                }

                using (var delete = _db.Prepare("DELETE FROM notes WHERE id = ?1;"))
                {
                    foreach (var id in pending.Deletes)
                    {
                        delete.BindText(1, id);
                        delete.Step();
                        delete.Reset();
                    }
                }

                using (var write = _db.Prepare("INSERT OR REPLACE INTO note_erased(id, clock, state_changed_at) VALUES (?1, ?2, ?3);"))
                using (var drop = _db.Prepare("DELETE FROM note_erased WHERE id = ?1;"))
                {
                    foreach (var (id, tombstone) in pending.Tombstones)
                    {
                        if (tombstone is not null)
                        {
                            write.BindText(1, id);
                            write.BindText(2, NoteSync.ClockText(tombstone.Clock));
                            write.BindInt64(3, tombstone.State);
                            write.Step();
                            write.Reset();
                        }
                        else
                        {
                            drop.BindText(1, id);
                            drop.Step();
                            drop.Reset();
                        }
                    }
                }

                _db.Execute("COMMIT;");
            }
            catch
            {
                try
                {
                    _db.Execute("ROLLBACK;");
                }
                catch
                {
                    // 回滚不成也没关系：没落下去的照样留在「没落盘」里。
                }

                throw;
            }

            Book.Saved();
            _failures = 0;
            SaveProblem = null;
            return true;
        }
        catch (Exception ex)
        {
            SaveProblem = ex.Message;
            _failures++;
            Log.Warn($"notes.save-failed {ex.GetType().Name} failures={_failures}");
            _retryTimer.Interval = TimeSpan.FromSeconds(RetryDelay(_failures));
            _retryTimer.Start();
            return false;
        }
    }

    /// <summary>打字之后还要等多久落盘（mac saveDelay）：停手 250 ms 就落；一直在改时从最早那次算起不拖过 2 秒。</summary>
    public static int SaveDelay(long elapsedMs) => (int)Math.Max(0, Math.Min(QuietMs, MaxDelayMs - elapsedMs));

    /// <summary>连着失败 count 次之后隔多久再试：5 秒起，每次翻倍，封顶 60 秒。</summary>
    public static double RetryDelay(int count) => Math.Min(5 * Math.Pow(2, Math.Clamp(count, 1, 8) - 1), 60);

    private void ScheduleSave()
    {
        var now = Now;
        var since = _unsavedSince ?? now;
        var delay = SaveDelay(now - since);
        if (delay <= 0)
        {
            Flush();
            return;
        }

        _unsavedSince = since;
        _saveTimer.Stop();
        _saveTimer.Interval = TimeSpan.FromMilliseconds(delay);
        _saveTimer.Start();
    }

    /// <summary>退出前把攒着的改动落下去。落不下去就问（ask 拿到原因，返回 0 再试一次 / 1 仍要退出 / 2 取消）。</summary>
    public async Task<bool> FlushBeforeQuitAsync(Func<string, Task<int>> ask)
    {
        while (!Flush())
        {
            switch (await ask(SaveProblem ?? "原因不明"))
            {
                case 0:
                    continue;
                case 1:
                    return true;
                default:
                    return false;
            }
        }

        return true;
    }

    public void Dispose()
    {
        _saveTimer.Stop();
        _retryTimer.Stop();
        _db.Dispose();
        if (ReferenceEquals(Instance, this))
        {
            Instance = null;
        }
    }
}

/// <summary>便签库是更新版本的 Kitty Tools 写的：不算坏，这次不可用、不问不动。</summary>
internal sealed class NotesNewerException(int version)
    : Exception($"便签的数据是更新版本的 Kitty Tools 写的（数据版本 {version}，这个版本只认到 {NoteStore.SchemaVersion}）")
{
    public int Version { get; } = version;
}
