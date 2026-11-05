// 便签仓库的内存那一半（PLAN-v13 第 2 批，照 mac Notes/NoteStore.swift 的「改动」「视图」「导出文件」「同步」几节）：全部便签——
// 连归档的和「最近删除」里的——都在这里，改动都走这里：先改内存、记成「没落盘」，落盘由 App 的 NoteStore 做（winsqlite3、
// 停手 250 ms / 连着改满 2 s、失败重试）。这里不碰库、不起计时器，所以整套规则能单测。
// - 写进来的文字先收拾（Note.SanitizedText / SanitizedTitle）；修订号每次改动 +1（到顶为止），「改于」只在标题 / 正文 / 颜色变时更新。
//   要用到「现在」的改动都带一个 now（整数毫秒）。
// - 删除是软删（DeletedAt），进「最近删除」留 TrashDays 天，到期由 PurgeExpired 真删。
// - 空白便签不越攒越多：这次运行里新建的、关掉 / 换走 / 收回时标题正文都空的，直接永久删掉（DropIfBlank，走 Erase 留墓碑）；
//   「新建」先复用本机建的空白便签（BlankOrNew）。
// - 同步要的账（合并规则在 NoteSync）：本机改内容时版本钟自己那一格 +1、改状态 / 顺序时记 StateChangedAt / OrderChangedAt（只往前走：
//   至少比这条上一次晚 1 毫秒）；永久删除留墓碑（被删那一版的钟和状态时刻，不过期）。电脑编号由调用方给（Windows 只有一个编号，
//   在 kitty.sqlite3 的 sync_device 里，同步的各类共用）。
// - 导出文件的第七类「便签」：Exportable 是没删的全部，Adopt 按编号合并——本机被换掉的那一版不丢，另存一条进「最近删除」。
// 线程：只在 UI 线程上用（同 mac 的 MainActor）。
namespace KittyTools.Core.Notes;

public sealed class NoteBook
{
    public const int TrashDays = 30;

    private const long Day = 86_400_000;

    private readonly List<Note> _notes = new();
    private readonly Dictionary<string, NoteSync.Tombstone> _erased = new(StringComparer.Ordinal);
    private readonly HashSet<string> _unsaved = new(StringComparer.Ordinal);
    private readonly HashSet<string> _unsavedTombstones = new(StringComparer.Ordinal);
    private readonly HashSet<string> _createdThisRun = new(StringComparer.Ordinal);
    private readonly HashSet<string> _publishedThisRun = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (string Title, string Body, Summary Summary)> _summaries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (string Title, string Body, byte[] Key)> _folded = new(StringComparer.Ordinal);
    private readonly Func<string> _device;
    private int _viewsGeneration = -1;
    private List<Note>? _active;
    private List<Note>? _archived;
    private List<Note>? _trashed;

    /// <summary>device：这台电脑的编号（同步时内容版本钟的格子），每次改动现取（换了编号马上跟上）。</summary>
    public NoteBook(Func<string> device)
    {
        _device = device;
    }

    /// <summary>内容变一次加一（界面拿它判断缓存的东西还能不能接着用）。</summary>
    public int Generation { get; private set; }

    /// <summary>全部便签（顺序不作数，要顺序用 Active / Archived / Trashed）。</summary>
    public IReadOnlyList<Note> All => _notes;

    public IReadOnlyDictionary<string, NoteSync.Tombstone> Erased => _erased;

    public string DeviceId => _device();

    public bool HasUnsaved => _unsaved.Count > 0 || _unsavedTombstones.Count > 0;

    public Note? Find(string id)
    {
        foreach (var note in _notes)
        {
            if (note.Id == id)
            {
                return note;
            }
        }

        return null;
    }

    private int IndexOf(string id)
    {
        for (var index = 0; index < _notes.Count; index++)
        {
            if (_notes[index].Id == id)
            {
                return index;
            }
        }

        return -1;
    }

    private void Changed() => Generation++;

    // ---- 载入（库里读出来的）----

    /// <summary>库里读出来的一行。writtenRevision 是写库时记下的修订号：对不上（或者没有）= 被别的东西改过，算本机的一次改动
    /// （钟补一格、状态 / 顺序时刻往前走一毫秒，记成没落盘；同 mac 认 0.5.0 动过的行）。tinted：tint 列里有值但这条不是自定义色
    /// （旧版本换过颜色），记成没落盘、下次落盘把它清掉。</summary>
    public void Load(Note note, long? writtenRevision, bool tinted)
    {
        var touched = writtenRevision != note.Revision;
        if (touched)
        {
            note = note with
            {
                Clock = Bumped(note.Clock, _device()),
                StateChangedAt = note.StateTime + 1,
                OrderChangedAt = note.OrderTime + 1,
                Revision = Note.NextRevision(note.Revision),
            };
        }

        _notes.Add(note);
        if (touched || (tinted && Note.CustomRgb(note.Color) is null))
        {
            _unsaved.Add(note.Id);
        }

        Changed();
    }

    public void LoadTombstone(string id, NoteSync.Tombstone tombstone) => _erased[id] = tombstone;

    // ---- 视图 ----

    private void EnsureViews()
    {
        if (_viewsGeneration == Generation)
        {
            return;
        }

        _viewsGeneration = Generation;
        _active = _archived = _trashed = null;
    }

    /// <summary>没归档、没删的，按顺序。</summary>
    public IReadOnlyList<Note> Active
    {
        get
        {
            EnsureViews();
            return _active ??= ActiveIn(_notes);
        }
    }

    /// <summary>归档的，最近改过的在前。</summary>
    public IReadOnlyList<Note> Archived
    {
        get
        {
            EnsureViews();
            return _archived ??= ArchivedIn(_notes);
        }
    }

    /// <summary>「最近删除」里的，刚删的在前。</summary>
    public IReadOnlyList<Note> Trashed
    {
        get
        {
            EnsureViews();
            return _trashed ??= TrashedIn(_notes);
        }
    }

    public static List<Note> ActiveIn(IEnumerable<Note> notes)
    {
        var list = notes.Where(note => note.IsActive).ToList();
        list.Sort(Compare);
        return list;
    }

    public static List<Note> ArchivedIn(IEnumerable<Note> notes)
        => notes.Where(note => note.IsArchived && note.DeletedAt is null)
            .OrderByDescending(note => note.ModifiedAt).ThenByDescending(note => note.Id, StringComparer.Ordinal)
            .ToList();

    public static List<Note> TrashedIn(IEnumerable<Note> notes)
        => notes.Where(note => note.DeletedAt is not null)
            .OrderByDescending(note => note.DeletedAt).ThenByDescending(note => note.Id, StringComparer.Ordinal)
            .ToList();

    /// <summary>导出文件里带的：没删的全部（含归档），按顺序。</summary>
    public List<Note> Exportable
    {
        get
        {
            var list = _notes.Where(note => note.DeletedAt is null).ToList();
            list.Sort(Compare);
            return list;
        }
    }

    /// <summary>正文里引用到的图片编号（含归档的、「最近删除」里的）。清理孤儿时用。</summary>
    public HashSet<Guid> ReferencedImages
    {
        get
        {
            var ids = new HashSet<Guid>();
            foreach (var note in _notes)
            {
                if (NoteImages.ContainsToken(note.Body))
                {
                    ids.UnionWith(NoteImages.Ids(note.Body));
                }
            }

            return ids;
        }
    }

    /// <summary>谁排在前面：order 小的；一样时新建的在前，再一样按编号。</summary>
    public static int Compare(Note a, Note b)
    {
        if (!a.Order.Equals(b.Order))
        {
            return a.Order.CompareTo(b.Order);
        }

        if (a.CreatedAt != b.CreatedAt)
        {
            return b.CreatedAt.CompareTo(a.CreatedAt);
        }

        return string.CompareOrdinal(a.Id, b.Id);
    }

    /// <summary>显示用的推导结果（标题、摘要、任务进度），按便签缓存：标题和正文没变就不重算。</summary>
    public readonly record struct Summary(string Title, string Preview, (int Done, int Total)? Progress);

    // ponytail: mac 正文超过 64 KB 时打字中先用上次算的、停手 0.3 s 再算；这里每次都现算（标题、摘要只读开头几行，
    // 任务进度整篇一遍，1 MB 约 1–2 ms）。真卡了再加推迟。
    public Summary SummaryOf(Note note)
    {
        if (_summaries.TryGetValue(note.Id, out var cached) && cached.Title == note.Title && cached.Body == note.Body)
        {
            return cached.Summary;
        }

        var summary = new Summary(note.DisplayTitle, note.Preview, note.TaskProgress);
        _summaries[note.Id] = (note.Title, note.Body, summary);
        return summary;
    }

    // ---- 改动 ----

    /// <summary>排到最前用的 order：比现有的都小 1。</summary>
    private double Top => (_notes.Count == 0 ? 0 : _notes.Min(note => note.Order)) - 1;

    private static IReadOnlyDictionary<string, long> Bumped(IReadOnlyDictionary<string, long> clock, string device)
    {
        var copy = new Dictionary<string, long>(clock, StringComparer.Ordinal);
        copy[device] = (copy.TryGetValue(device, out var count) ? count : 0) + 1;
        return copy;
    }

    public static string NewId() => Guid.NewGuid().ToString("D").ToUpperInvariant();

    /// <summary>新建一条，排在最前；颜色接着上一条新建的往下轮。调用方随后 Flush（mac 当场落盘）。</summary>
    public Note Create(long now, string body = "", string title = "")
    {
        Note? latest = null;
        foreach (var note in _notes)
        {
            if (latest is null || note.CreatedAt >= latest.CreatedAt)
            {
                latest = note;
            }
        }

        var created = new Note
        {
            Id = NewId(),
            Title = Note.SanitizedTitle(title),
            Body = Note.SanitizedText(body),
            Color = latest is null ? 0 : Note.NextPreset(latest.Color),
            CreatedAt = now,
            ModifiedAt = now,
            Order = Top,
            StateChangedAt = now,
            OrderChangedAt = now,
            Clock = new Dictionary<string, long>(StringComparer.Ordinal) { [_device()] = 1 },
        };
        _notes.Add(created);
        _unsaved.Add(created.Id);
        _createdThisRun.Add(created.Id);
        Changed();
        return created;
    }

    private static bool IsBlank(Note note) => note.Title.Length == 0 && note.Body.Length == 0;

    /// <summary>「新建便签」用的那一条：没归档没删的里有本机建的空白便签就用它（不在最前面就挪到最前面），不然新建一条。</summary>
    public Note BlankOrNew(long now)
    {
        var list = Active;
        var device = _device();
        foreach (var note in list)
        {
            if (!IsBlank(note) || !(_createdThisRun.Contains(note.Id) || note.Clock.Keys.All(key => key == device)))
            {
                continue;
            }

            if (note.Id != list[0].Id)
            {
                Move(note.Id, 0, now);
            }

            return Find(note.Id) ?? note;
        }

        return Create(now);
    }

    public void Published(IEnumerable<string> ids) => _publishedThisRun.UnionWith(ids);

    public bool WasCreatedThisRun(string id) => _createdThisRun.Contains(id);

    public enum Drop
    {
        Dropped,
        Kept,
        /// <summary>正文框里还挂着组字：过一会儿再看。</summary>
        Composing,
    }

    /// <summary>这次运行里新建的空白便签（没归档没删、没开在别处）永久删掉；写进过同步文件夹的留墓碑。</summary>
    public Drop DropIfBlank(string id, long now, bool isOpen, bool isComposing)
    {
        if (!_createdThisRun.Contains(id) || Find(id) is not { } note || !note.IsActive || !IsBlank(note) || isOpen)
        {
            return Drop.Kept;
        }

        if (isComposing)
        {
            return Drop.Composing;
        }

        _createdThisRun.Remove(id);
        Erase(new[] { id }, tombstones: _publishedThisRun.Contains(id));
        return Drop.Dropped;
    }

    /// <summary>改正文 / 标题：打字时每个字调一次（调用方攒着等停手再落盘）。返回变没变。</summary>
    public bool SetBody(string id, string body, long now)
    {
        var clean = Note.SanitizedText(body);
        return Mutate(id, now, note => note with { Body = clean });
    }

    public bool SetTitle(string id, string title, long now)
    {
        var clean = Note.SanitizedTitle(title);
        return Mutate(id, now, note => note with { Title = clean });
    }

    public bool SetColor(string id, int color, long now) => Mutate(id, now, note => note with { Color = Note.Clamped(color) });

    /// <summary>归档 / 取消归档；取消归档的排回最前（toFront false：回到原来的位置，撤销刚做的归档）。</summary>
    public bool SetArchived(string id, bool archived, long now, bool toFront = true)
    {
        var front = Top;
        return Mutate(id, now, note => note.IsArchived == archived
            ? note
            : note with { IsArchived = archived, Order = !archived && toFront ? front : note.Order });
    }

    public bool SetPinned(string id, bool pinned, long now) => Mutate(id, now, note => note with { IsPinned = pinned });

    /// <summary>挪顺序：挪成 Active 里的第 index 个。只改它自己的 order（取两边中间的值）；中间取不出值时整列重排成 0、1、2…</summary>
    public bool Move(string id, int index, long now)
    {
        var list = Active.ToList();
        var from = list.FindIndex(note => note.Id == id);
        if (from < 0)
        {
            return false;
        }

        var moving = list[from];
        list.RemoveAt(from);
        var target = Math.Clamp(index, 0, list.Count);
        if (target == from)
        {
            return false;
        }

        double? before = target > 0 ? list[target - 1].Order : null;
        double? after = target < list.Count ? list[target].Order : null;
        double order;
        switch (before, after)
        {
            case (null, null):
                return false;
            case (null, { } next):
                order = next - 1;
                break;
            case ({ } previous, null):
                order = previous + 1;
                break;
            default:
                order = (before.Value + after.Value) / 2;
                break;
        }

        if (before is { } low && after is { } high && !(low < order && order < high))
        {
            list.Insert(target, moving);
            for (var position = 0; position < list.Count; position++)
            {
                var value = (double)position;
                Mutate(list[position].Id, now, note => note with { Order = value });
            }

            return true;
        }

        return Mutate(id, now, note => note with { Order = order });
    }

    /// <summary>删除：进「最近删除」（留 TrashDays 天，Restore 放回）。</summary>
    public bool Delete(string id, long now) => Mutate(id, now, note => note.DeletedAt is null ? note with { DeletedAt = now } : note);

    public bool Restore(string id, long now) => Mutate(id, now, note => note with { DeletedAt = null });

    /// <summary>永久删除：不进「最近删除」，留一块墓碑。</summary>
    public void Erase(IEnumerable<string> ids) => Erase(ids, tombstones: true);

    /// <summary>清空「最近删除」。返回删了几条。</summary>
    public int EmptyTrash()
    {
        var ids = _notes.Where(note => note.DeletedAt is not null).Select(note => note.Id).ToList();
        Erase(ids);
        return ids.Count;
    }

    /// <summary>「最近删除」里放了超过 TrashDays 天的真删（启动后、换日时调）。返回删了几条。</summary>
    public int PurgeExpired(long now)
    {
        var cutoff = now - TrashDays * Day;
        var expired = _notes.Where(note => note.DeletedAt is { } deleted && deleted < cutoff).Select(note => note.Id).ToList();
        Erase(expired);
        return expired.Count;
    }

    private void Erase(IEnumerable<string> ids, bool tombstones)
    {
        var set = ids.ToHashSet(StringComparer.Ordinal);
        var doomed = _notes.Where(note => set.Contains(note.Id)).ToList();
        if (doomed.Count > 0)
        {
            Remove(doomed, new Dictionary<string, NoteSync.Tombstone>(StringComparer.Ordinal), tombstones);
        }
    }

    /// <summary>从内存里拿掉这几条（落盘时从库里删），各留一块墓碑：被删那一版的钟和状态时刻，再并上传进来的和本机原来就有的。</summary>
    private void Remove(List<Note> doomed, IReadOnlyDictionary<string, NoteSync.Tombstone> tombstones, bool leavesTombstones = true)
    {
        var ids = doomed.Select(note => note.Id).ToHashSet(StringComparer.Ordinal);
        _notes.RemoveAll(note => ids.Contains(note.Id));
        foreach (var note in doomed)
        {
            _summaries.Remove(note.Id);
            _folded.Remove(note.Id);
            if (!leavesTombstones)
            {
                continue;
            }

            var tombstone = new NoteSync.Tombstone(note.Clock, note.StateTime);
            if (tombstones.TryGetValue(note.Id, out var incoming))
            {
                tombstone = tombstone.Merged(incoming);
            }

            if (_erased.TryGetValue(note.Id, out var existing))
            {
                tombstone = tombstone.Merged(existing);
            }

            _erased[note.Id] = tombstone;
            _unsavedTombstones.Add(note.Id);
        }

        _unsaved.UnionWith(ids);
        Changed();
    }

    /// <summary>这条又有了（导入、同步加回来的）：墓碑拿掉。</summary>
    private void Revive(string id)
    {
        if (_erased.Remove(id))
        {
            _unsavedTombstones.Add(id);
        }
    }

    /// <summary>改一条，只改内存、记成没落盘：真的变了才算——修订号 +1；标题 / 正文 / 颜色变了就把「改于」记成 now、版本钟自己那一格 +1；
    /// 归档 / 固定 / 删除变了记 StateChangedAt、顺序变了记 OrderChangedAt（都只往前走：至少比这条上一次晚 1 毫秒）。返回变没变。</summary>
    private bool Mutate(string id, long now, Func<Note, Note> change)
    {
        var index = IndexOf(id);
        if (index < 0)
        {
            return false;
        }

        var old = _notes[index];
        var note = change(old);
        if (note.Equals(old))
        {
            return false;
        }

        if (note.Title != old.Title || note.Body != old.Body || note.Color != old.Color)
        {
            note = note with { ModifiedAt = now, Clock = Bumped(note.Clock, _device()) };
        }

        if (note.IsArchived != old.IsArchived || note.IsPinned != old.IsPinned || note.DeletedAt != old.DeletedAt)
        {
            note = note with { StateChangedAt = Math.Max(now, old.StateTime + 1) };
        }

        if (!note.Order.Equals(old.Order))
        {
            note = note with { OrderChangedAt = Math.Max(now, old.OrderTime + 1) };
        }

        _notes[index] = note with { Revision = Note.NextRevision(note.Revision) };
        _unsaved.Add(id);
        Changed();
        return true;
    }

    // ---- 落盘（App 的 NoteStore 拿走、写库、成了再 Saved）----

    /// <summary>要写进库的：内存里还有的（upsert）、已经没有的（delete）、墓碑（null = 删那一行）。</summary>
    public sealed record Pending(
        IReadOnlyList<Note> Upserts, IReadOnlyList<string> Deletes,
        IReadOnlyList<(string Id, NoteSync.Tombstone? Tombstone)> Tombstones);

    public Pending PendingWrites()
    {
        var upserts = new List<Note>();
        var gone = new HashSet<string>(_unsaved, StringComparer.Ordinal);
        foreach (var note in _notes)
        {
            if (_unsaved.Contains(note.Id))
            {
                upserts.Add(note);
                gone.Remove(note.Id);
            }
        }

        var tombstones = _unsavedTombstones
            .Select(id => (Id: id, Tombstone: _erased.TryGetValue(id, out var tombstone) ? tombstone : null))
            .ToList();
        return new Pending(upserts, gone.ToList(), tombstones);
    }

    /// <summary>这一份写进库了（同一次 UI 线程调用里拿的 PendingWrites）。</summary>
    public void Saved()
    {
        _unsaved.Clear();
        _unsavedTombstones.Clear();
    }

    // ---- 搜索 ----

    /// <summary>在给的这些里搜：标题和正文，空白分词、每个词都要命中，不分大小写、全半角、变音符号；顺序不变，空查询原样返回。
    /// 正文里的图片令牌、颜色标记先去掉。折叠的结果按编号缓存，标题正文没变就接着用。</summary>
    public List<Note> Search(string query, IReadOnlyList<Note> notes)
    {
        var tokens = Core.Search.Tokens(query);
        if (tokens.Length == 0)
        {
            return notes.ToList();
        }

        var folded = Core.Search.FoldTokens(tokens);
        return notes.Where(note => Core.Search.Matches(FoldedKey(note), folded)).ToList();
    }

    /// <summary>搜索的折叠缓存整个放掉（空闲回收）。</summary>
    public void DropSearchCache() => _folded.Clear();

    public static string SearchText(Note note)
        => note.Title + "\n" + NoteMarkdown.StrippingColors(NoteImages.Stripping(note.Body));

    private byte[] FoldedKey(Note note)
    {
        if (_folded.TryGetValue(note.Id, out var cached) && cached.Title == note.Title && cached.Body == note.Body)
        {
            return cached.Key;
        }

        var key = Core.Search.FoldBytes(SearchText(note));
        _folded[note.Id] = (note.Title, note.Body, key);
        return key;
    }

    // ---- 导出文件 ----

    public readonly record struct Adoption(int Added, int Updated);

    /// <summary>导入（设置的导出 / 导入里「便签」那一类；entries 是读文件时查过的）。按编号合并，规则同 mac NoteStore.adopt：
    /// 本机没有的加进来（时间不晚于现在，钟接着墓碑往上数）；本机有的，文件里那条改得更晚才整条换（修订号取两边大的再 +1），
    /// 被换掉的那一版有文字、和文件里的不一样就另存一条进「最近删除」；文件里「改于」比现在还晚的只在本机没有时加；
    /// 本机那条在「最近删除」里的不动。contentOnly：这几条只取内容。调用方随后 Flush。</summary>
    public Adoption Adopt(IReadOnlyList<NoteEntry> entries, long now, IReadOnlySet<string>? contentOnly = null)
    {
        var (added, updated) = (0, 0);
        var offsets = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < _notes.Count; index++)
        {
            offsets[_notes[index].Id] = index;
        }

        var device = _device();
        foreach (var entry in NewestEntries(entries))
        {
            var isAhead = entry.ModifiedAt > now;
            var modified = Math.Min(entry.ModifiedAt, now);
            var title = Note.SanitizedTitle(entry.Title);
            var body = Note.SanitizedText(entry.Body);
            var color = entry.NoteColor;
            var order = double.IsFinite(entry.Order) ? entry.Order : 0;
            if (!offsets.TryGetValue(entry.Id, out var offset))
            {
                offsets[entry.Id] = _notes.Count;
                var clock = Bumped(_erased.TryGetValue(entry.Id, out var tombstone)
                    ? tombstone.Clock
                    : new Dictionary<string, long>(StringComparer.Ordinal), device);
                _notes.Add(new Note
                {
                    Id = entry.Id,
                    Title = title,
                    Body = body,
                    Color = color,
                    CreatedAt = Math.Min(entry.CreatedAt, now),
                    ModifiedAt = modified,
                    Revision = Math.Clamp(entry.Revision, 0, Note.MaxRevision),
                    IsArchived = entry.Archived,
                    IsPinned = entry.Pinned,
                    Order = order,
                    StateChangedAt = now,
                    OrderChangedAt = now,
                    Clock = clock,
                });
                Revive(entry.Id);
                _unsaved.Add(entry.Id);
                added++;
                continue;
            }

            var old = _notes[offset];
            if (old.DeletedAt is not null || isAhead || modified <= old.ModifiedAt)
            {
                continue;
            }

            if (title == old.Title && body == old.Body && color == old.Color)
            {
                continue;
            }

            var keepState = contentOnly?.Contains(entry.Id) == true;
            var note = old with
            {
                Title = title,
                Body = body,
                Color = color,
                ModifiedAt = modified,
                Revision = Note.NextRevision(Math.Max(old.Revision, entry.Revision)),
                IsArchived = keepState ? old.IsArchived : entry.Archived,
                IsPinned = keepState ? old.IsPinned : entry.Pinned,
                Order = keepState ? old.Order : order,
                Clock = Bumped(old.Clock, device),
            };
            if (note.IsArchived != old.IsArchived || note.IsPinned != old.IsPinned)
            {
                note = note with { StateChangedAt = Math.Max(now, old.StateTime + 1) };
            }

            if (!note.Order.Equals(old.Order))
            {
                note = note with { OrderChangedAt = Math.Max(now, old.OrderTime + 1) };
            }

            _notes[offset] = note;
            _unsaved.Add(entry.Id);
            updated++;
            if ((old.Title != title || old.Body != body) && !(old.Title.Length == 0 && old.Body.Length == 0))
            {
                var copy = new Note
                {
                    Id = NewId(),
                    Title = old.Title,
                    Body = old.Body,
                    Color = old.Color,
                    CreatedAt = old.CreatedAt,
                    ModifiedAt = old.ModifiedAt,
                    IsArchived = old.IsArchived,
                    IsPinned = old.IsPinned,
                    Order = old.Order,
                    DeletedAt = now,
                    StateChangedAt = now,
                    OrderChangedAt = now,
                    Clock = new Dictionary<string, long>(StringComparer.Ordinal) { [device] = 1 },
                };
                _notes.Add(copy);
                _unsaved.Add(copy.Id);
            }
        }

        if (added + updated > 0)
        {
            Changed();
        }

        return new Adoption(added, updated);
    }

    /// <summary>同一个编号来了几条：只留「改于」最晚的那条，一样晚留前面那条；顺序照留下的那几条在原来的位置。</summary>
    public static List<NoteEntry> NewestEntries(IReadOnlyList<NoteEntry> entries)
    {
        var best = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < entries.Count; index++)
        {
            if (best.TryGetValue(entries[index].Id, out var kept) && entries[kept].ModifiedAt >= entries[index].ModifiedAt)
            {
                continue;
            }

            best[entries[index].Id] = index;
        }

        return entries.Where((entry, index) => best[entry.Id] == index).ToList();
    }

    // ---- 同步 ----

    /// <summary>把一轮合并的结果落进内存（调用方随后 Flush）。合的时候本机那条是哪个修订号（Merge.Base）对不上就跳过：合完到落下去之间
    /// 本机又改了，下一轮再合。合出来是 null、本机有：真删（留墓碑）；和本机不一样：换上（不另 +1）；本机没有：加上，墓碑拿掉；
    /// 冲突里输了的那几版：本机还没有、本机和这一轮都没有它的墓碑的才加。</summary>
    public void ApplySync(IReadOnlyDictionary<string, NoteSync.Merge> merges, IReadOnlyDictionary<string, NoteSync.Tombstone> tombstones)
    {
        var offsets = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < _notes.Count; index++)
        {
            offsets[_notes[index].Id] = index;
        }

        var doomed = new List<Note>();
        var copies = new List<Note>();
        var changed = false;
        foreach (var (id, merge) in merges.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            int? current = offsets.TryGetValue(id, out var at) ? _notes[at].Revision : null;
            if (current != merge.Base)
            {
                continue;
            }

            copies.AddRange(merge.Copies);
            if (merge.Note is not { } note)
            {
                if (offsets.TryGetValue(id, out var gone))
                {
                    doomed.Add(_notes[gone]);
                }

                continue;
            }

            if (offsets.TryGetValue(id, out var offset))
            {
                if (_notes[offset].Equals(note))
                {
                    continue;
                }

                _notes[offset] = note;
            }
            else
            {
                offsets[id] = _notes.Count;
                _notes.Add(note);
                Revive(id);
            }

            _unsaved.Add(id);
            changed = true;
        }

        foreach (var copy in copies)
        {
            if (offsets.ContainsKey(copy.Id) || _erased.ContainsKey(copy.Id) || tombstones.ContainsKey(copy.Id))
            {
                continue;
            }

            offsets[copy.Id] = _notes.Count;
            _notes.Add(copy);
            _unsaved.Add(copy.Id);
            changed = true;
        }

        if (doomed.Count > 0)
        {
            Remove(doomed, tombstones);
        }
        else if (changed)
        {
            Changed();
        }
    }

    /// <summary>同步时认出库被退回去了（NoteSyncFolder 的 regressed）：bumping 里的每一条钟里去掉旧编号那一格、记一笔新编号的改动
    /// （新编号那一格 +1、修订号 +1）。调用方先 Flush 这几条、成了再把新编号记下来（反过来的话没落下去就退出会丢字）。</summary>
    public void SwitchDevice(IReadOnlySet<string> bumping, string oldId, string newId)
    {
        for (var index = 0; index < _notes.Count; index++)
        {
            var note = _notes[index];
            if (!bumping.Contains(note.Id))
            {
                continue;
            }

            var clock = new Dictionary<string, long>(note.Clock, StringComparer.Ordinal);
            clock.Remove(oldId);
            clock[newId] = (clock.TryGetValue(newId, out var count) ? count : 0) + 1;
            _notes[index] = note with { Clock = clock, Revision = Note.NextRevision(note.Revision) };
            _unsaved.Add(note.Id);
        }

        Changed();
    }
}
