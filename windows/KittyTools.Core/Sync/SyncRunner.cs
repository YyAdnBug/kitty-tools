// 同步的执行层（REVIEW R26：原来在 App 的 SyncFolder.cs 里，挪进 Core 才能拿临时文件夹整轮地测）。一轮怎么走（PLAN-v5 §4.3，
// 照 NoteSyncer.swift 去掉便签那部分）：
// 1. 线程池上读文件夹：标记、各台的 device.json 和这几类的文件（云盘里还没下载的占位文件不读，当没有）；
// 2. 认文件夹：不在了、标记还没下载下来、里面有别的东西 → 停；没有标记（空文件夹）就新建一个库；
// 3. 文件夹里本机那份 device.json 的 epoch 比本机记着的大：库被退回去了（从备份恢复过）→ 换编号；
// 4. 一类一类：仓库给 null（没起来、面板里有能撤销的删除）跳过 → 线程池上合（SyncEngine.Round）→ 刹车 → 落地（仓库在同一个
//    事务里存账本；改动是空的、账本也没变就不落）→ 自己那份和文件夹里的字节不一样才记下要写。某一类出了问题只跳过它；
// 5. 有要写的：先在库里记 epoch +1，线程池上写各类文件，device.json 最后写（文件夹里的比库里的大才是被退回去了；没写成的话
//    文件夹里的小，不会认错）。没东西要写、device.json 也没变就一个文件都不写（云盘不用每 20 秒传一遍）。
// 刹车（照 mac NoteSyncer.merge）：别处要删掉本机的（trashing）加上本机自己一下删掉的（erasing），按删之前有几条算，超过 20 条
// 或（至少 5 条时）超过三成，这一类停下来等确认；「继续」只放行不超过当时那么多条的删除（allowance）。
// 别的电脑的文件读不出来（写坏了、别的类别）：只扔那一版，这一类照合（Windows 一直这样；那台的墓碑这一轮看不到，
// 下一轮读到了照样压得住）。更新版本写的：这一类停在「请更新」。
// 线程：调用方在 UI 线程上 await；Values / Ledger / Apply 回到调用方的线程（仓库只在 UI 线程上用），读写文件和合在线程池。
// 便签（PLAN-v13 第 3 批，notes 不为 null 时）：一轮里多一步，先后照 Core/Notes/NoteSyncPart.cs 文件头那张清单——认清文件夹之后、
// 别的几类合之前先认「便签库被退回去了」（要换编号就在写任何东西之前换）；别的几类合完再合便签、落下去、写自己的 notes/ 和 erased.json；
// 便签文件要动的那一轮同样算「写了东西」（epoch +1、device.json 最后写）。便签这部分出了问题只停它自己（同别的一类）。
using System.Text;
using KittyTools.Core.Notes;

namespace KittyTools.Core.Sync;

public sealed class SyncRoundResult
{
    /// <summary>idle / confirm（刹车，等确认）/ stopped。</summary>
    public string State { get; set; } = "idle";

    public string Message { get; set; } = string.Empty;

    /// <summary>刹车停下的几类：类别 → 这一轮要删几条（点「继续」时记成额度）。</summary>
    public Dictionary<string, int> Waiting { get; } = new(StringComparer.Ordinal);

    /// <summary>别的电脑（device.json 里的名字，读不到名字就是编号）。</summary>
    public List<string> Devices { get; set; } = new();

    /// <summary>这一轮认出库被退回去了、换了编号。</summary>
    public bool Rotated { get; set; }

    /// <summary>这一轮重写了自己那份的几类。</summary>
    public List<string> Written { get; } = new();

    public SyncRoundResult Stop(string message)
    {
        State = "stopped";
        Message = message;
        return this;
    }
}

public sealed class SyncRunner(
    ISyncDevice device, IReadOnlyList<ISyncSource> sources, string deviceName, Action<string>? log = null,
    NoteSyncPart? notes = null)
{
    public const string NewerFormat = "同步文件夹是新版本写的，请更新 Kitty Tools";

    // ponytail: 四类都没给「真正改的时刻」（剪贴板的复制时间不是改动时间，mac 也不拿它当改于），所以 changed 交空表：
    // 改于用「这一轮发现它变了」的现在（不晚于 now，SyncEngine 里取 min）。以后仓库记了每一项真正改的时刻，再从这里传进去。
    private static readonly Dictionary<string, long> NoChanged = new(StringComparer.Ordinal);

    public static string Title(string kind) => kind switch
    {
        ClipSync.Kind => "片段与收藏",
        VocabularySync.Kind => "生词本",
        EngineSync.Kind => "网页搜索",
        ServiceSync.Kind => "翻译服务",
        NoteSyncFolder.NotesPart => "便签",
        StatusPresetSync.Kind => "状态屏的状态",
        ReminderSync.Kind => "提醒",
        _ => kind,
    };

    public async Task<SyncRoundResult> RunAsync(string folder, IReadOnlyDictionary<string, int> allowance, long now)
    {
        var result = new SyncRoundResult();
        var disk = new SyncDisk(folder);
        var kinds = sources.Select(source => source.Kind).ToList();
        // 便签：写进文件夹的必须是落下去了的
        var notesSaved = notes?.Flush() ?? true;
        var snapshot = await Task.Run(() => Snapshot.Read(disk, kinds, notes is not null));
        if (!snapshot.Usable)
        {
            return result.Stop("文件夹不在了");
        }

        var library = snapshot.Library;
        if (library is null)
        {
            // 标记是更新的格式写的（SyncFolderRules.ParseMarker 只认格式 1，便签的读法分得出来）：整轮不动
            if (snapshot.Notes?.Folder.Marker is { Format: > NoteSyncFolder.Format })
            {
                return result.Stop(NewerFormat);
            }

            if (snapshot.MarkerPending)
            {
                return result.Stop("同步文件夹还没下载完");
            }

            if (snapshot.Foreign)
            {
                return result.Stop("这个文件夹里已经有别的东西了");
            }

            library = Guid.NewGuid().ToString("D").ToUpperInvariant();
            var marker = SyncFolderRules.Marker(library);
            if (!await Task.Run(() => disk.WriteText(SyncFolderRules.MarkerFile, marker)))
            {
                return result.Stop("同步文件夹写不进去");
            }

            if (snapshot.Notes is { } fresh)
            {
                // 刚新建的标记：便签那部分读的时候还没有它
                fresh.Folder.Marker = new NoteSyncFolder.Marker(library);
                fresh.MarkerUnreadable = false;
            }
        }

        if (device.Library != library)
        {
            device.SetLibrary(library);
        }

        // 认出库被退回去了（从旧备份恢复过）：文件夹里本机的 epoch 比本机记着的大，就换一个新编号。
        // 便签另外按钟认（便签库可能单独被恢复过）：要换编号就连那几条便签一起换（先落盘再换），都在写任何东西之前。
        var folderEpoch = snapshot.Epoch(device.Id);
        var rolledBack = device.Epoch > 0 && folderEpoch > device.Epoch;
        string? notesProblem = notes is null ? null : NotesBlocked(snapshot, notesSaved);
        var oldId = device.Id;
        var bump = notes is not null && notesProblem is null
            ? Bumped(notes, snapshot.Notes!.Folder, oldId, rolledBack)
            : new HashSet<string>(StringComparer.Ordinal);
        if (bump.Count > 0)
        {
            log?.Invoke($"sync.notes-regressed count={bump.Count}");
            var newId = Guid.NewGuid().ToString("D").ToUpperInvariant();
            if (!notes!.SwitchDevice(bump, oldId, newId))
            {
                // 那几条没落下去：这一轮便签先不合（留在内存里照常重试），下一轮再认一遍
                notesProblem = "便签没存上";
                if (rolledBack)
                {
                    device.Rotate();
                }
            }
        }
        else if (rolledBack)
        {
            device.Rotate();
        }

        if (rolledBack || device.Id != oldId)
        {
            log?.Invoke($"sync.epoch-rollback folder={folderEpoch} local={device.Epoch}");
            device.SetLibrary(library);
            folderEpoch = snapshot.Epoch(device.Id);
            result.Rotated = true;
        }

        result.Devices = snapshot.Peers
            .Where(peer => peer.Key != device.Id)
            .Select(peer => peer.Value.Name ?? peer.Key)
            .OrderBy(name => name, StringComparer.CurrentCulture)
            .ToList();

        var writes = new Dictionary<string, string>(StringComparer.Ordinal);
        string? trouble = null;
        foreach (var source in sources)
        {
            var step = await MergeAsync(
                source, snapshot, library, allowance.TryGetValue(source.Kind, out var allowed) ? allowed : 0, now);
            if (step.Braked > 0)
            {
                result.Waiting[source.Kind] = step.Braked;
            }
            else if (step.Problem is not null)
            {
                log?.Invoke($"sync.kind-stopped {source.Kind}");
                trouble ??= step.Problem;
            }
            else if (step.Write is not null)
            {
                writes[source.Kind] = step.Write;
            }
        }

        // 便签：别的几类合完再合（合、刹车、落下去、算出要写的）
        NoteSyncFolder.PublishPlan? notePlan = null;
        if (notes is not null)
        {
            if (notesProblem is null)
            {
                var step = await MergeNotes(notes, snapshot.Notes!, library,
                    allowance.TryGetValue(NoteSyncFolder.NotesPart, out var allowed) ? allowed : 0, now);
                if (step.Braked > 0)
                {
                    result.Waiting[NoteSyncFolder.NotesPart] = step.Braked;
                }
                else
                {
                    notesProblem = step.Problem;
                    notePlan = step.Plan;
                }
            }

            if (notesProblem is not null)
            {
                log?.Invoke("sync.kind-stopped notes");
                trouble ??= notesProblem;
            }
        }

        var touchesNotes = notePlan is { TouchesNotes: true };
        var imagesOnly = notePlan is { IsEmpty: false, TouchesNotes: false };

        // 第几轮：只在真的写了东西时 +1；不往小里写（文件夹里的大说明上面已经换过编号了）。
        var next = Math.Max(device.Epoch, folderEpoch) + (writes.Count > 0 || touchesNotes ? 1 : 0);
        var deviceText = SyncFolderRules.DeviceJson(next, deviceName);
        var me = device.Id;
        if (writes.Count > 0 || touchesNotes || imagesOnly || snapshot.DeviceText(me) != deviceText)
        {
            if (device.Epoch != next)
            {
                device.SetEpoch(next);
            }

            var zone = notes?.Zone ?? TimeZoneInfo.Local;
            var imagesDirectory = notes?.ImagesDirectory;
            var written = await Task.Run(() =>
            {
                foreach (var (kind, text) in writes)
                {
                    if (!disk.WriteText(SyncDisk.KindPath(me, kind), text))
                    {
                        return (false, (List<string>?)null, (HashSet<Guid>?)null, (List<string>?)null);
                    }
                }

                List<string>? notesWritten = null;
                HashSet<Guid>? downloaded = null;
                List<string>? purged = null;
                if (notePlan is { IsEmpty: false } plan)
                {
                    var (ok, done, arrived, deleted) = NoteSyncDisk.Write(disk, me, plan, imagesDirectory, zone);
                    (notesWritten, downloaded, purged) = (done, arrived, deleted);
                    if (!ok)
                    {
                        return (false, notesWritten, downloaded, purged);
                    }
                }

                // device.json 最后写（前面都写成了、内容变了才写）
                var deviceOk = snapshot.DeviceText(me) == deviceText || disk.WriteText(SyncDisk.DevicePath(me), deviceText);
                return (deviceOk, notesWritten, downloaded, purged);
            });
            if (notes is not null)
            {
                NotesWritten(notes, written.Item2, written.Item3, written.Item4);
            }

            if (!written.Item1)
            {
                return result.Stop("同步文件夹写不进去");
            }

            result.Written.AddRange(writes.Keys.OrderBy(kind => kind, StringComparer.Ordinal));
            if (touchesNotes)
            {
                result.Written.Add(NoteSyncFolder.NotesPart);
            }
        }

        if (result.Waiting.Count > 0)
        {
            result.State = "confirm";
            result.Message = $"同步要删掉 {result.Waiting.Values.Sum()} 条，等你确认";
            return result;
        }

        return trouble is null ? result : result.Stop(trouble);
    }

    /// <summary>一类合到哪了：Braked &gt; 0 = 刹车；Problem = 这一类停了；Write = 自己那份要重写成什么（null = 不用写）。</summary>
    private readonly record struct KindStep(int Braked, string? Problem, string? Write);

    private sealed record Merged(SyncOutcome? Outcome, string? Problem, string OwnText, string LedgerText);

    private async Task<KindStep> MergeAsync(
        ISyncSource source, Snapshot snapshot, string library, int allowance, long now)
    {
        var kind = source.Kind;
        // 仓库还没起来（或这一轮先别合）：这一类这一轮不合，当成空表交进去会把账本里的全当成删了。
        if (source.Values() is not { } values)
        {
            log?.Invoke($"sync.kind-skipped {kind}");
            return default;
        }

        SyncLedgerData? ledger;
        try
        {
            ledger = source.Ledger(library);
        }
        catch (Exception ex)
        {
            log?.Invoke($"sync.ledger-unreadable {kind} {ex.GetType().Name}");
            return new KindStep(0, $"{Title(kind)}的同步记录读不出来", null);
        }

        var me = device.Id;
        var merged = await Task.Run(() => Merge(kind, values, ledger, snapshot, me, now, source.JoinKey));
        if (merged.Outcome is not { } outcome)
        {
            return new KindStep(0, merged.Problem, null);
        }

        var deleting = outcome.Trashing + outcome.Erasing;
        if (SyncFolderRules.ShouldBrake(deleting, outcome.Alive + outcome.Erasing) && deleting > allowance)
        {
            log?.Invoke($"sync.brake {kind} deleting={deleting} allowance={allowance}");
            return new KindStep(deleting, null, null);
        }

        // 编出来的自己那份太大（别的电脑读不进来）：这一类不合、不写，说清楚。
        if (Encoding.UTF8.GetByteCount(merged.OwnText) > SyncFile.MaxBytes)
        {
            return new KindStep(0, $"{Title(kind)}超过 {SyncFile.MaxBytes >> 20} MB，同步不了", null);
        }

        var ledgerChanged = ledger is null || SyncLedgerText.Encode(ledger) != merged.LedgerText;
        if (outcome.Changes.Count > 0 || ledgerChanged)
        {
            string? failure;
            try
            {
                failure = source.Apply(outcome.Changes, outcome.Ledger, library);
            }
            catch (Exception ex)
            {
                log?.Invoke($"sync.apply-failed {kind} {ex.GetType().Name}");
                failure = $"{Title(kind)}没存上";
            }

            if (failure is not null)
            {
                log?.Invoke($"sync.apply-refused {kind}");
                return new KindStep(0, failure, null);
            }
        }

        // 按字节比（只换了写法的改动也要写）。
        return new KindStep(0, null, snapshot.File(me, kind) == merged.OwnText ? null : merged.OwnText);
    }

    private Merged Merge(
        string kind, IReadOnlyDictionary<string, string> values, SyncLedgerData? ledger, Snapshot snapshot,
        string me, long now, Func<string, string?> joinKey)
    {
        // 自己那份读不出来照常合（引擎接着见过的最大往上数）；更新版本写的整类不合。
        SyncFileData? own = null;
        if (snapshot.File(me, kind) is { } ownText)
        {
            var file = SyncFile.Decode(ownText, kind);
            if (file is { IsNewer: true })
            {
                return new Merged(null, NewerFormat, string.Empty, string.Empty);
            }

            own = ToData(file, kind);
        }

        var others = new List<SyncFileData>();
        foreach (var (id, peer) in snapshot.Peers.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (id == me || !peer.Files.TryGetValue(kind, out var text) || text is null)
            {
                continue;
            }

            var file = SyncFile.Decode(text, kind);
            if (file is { IsNewer: true })
            {
                return new Merged(null, NewerFormat, string.Empty, string.Empty);
            }

            if (ToData(file, kind) is { } data)
            {
                others.Add(data);
            }
            else
            {
                // 只扔这一版，这一类照合。
                log?.Invoke($"sync.peer-unreadable kind={kind}");
            }
        }

        var outcome = SyncEngine.Round(values, NoChanged, ledger, own, others, me, now, JoinMode.Union, joinKey);
        return new Merged(outcome, null, ToFile(kind, outcome.Own).Encode(), SyncLedgerText.Encode(outcome.Ledger));
    }

    // ---- 便签（PLAN-v13 第 3 批）----

    /// <summary>便签这部分这一轮能不能合：没落下去、标记读不出来（还在下载）、自己的 device.json 读不出来 → 停（认清文件夹之前不换编号、不合）。</summary>
    private string? NotesBlocked(Snapshot snapshot, bool saved)
    {
        if (!saved)
        {
            return "便签没存上";
        }

        if (snapshot.Notes is not { } part || part.MarkerUnreadable || snapshot.BrokenDevices.Contains(device.Id))
        {
            return "同步文件夹还没下载完";
        }

        return null;
    }

    /// <summary>要换编号的几条：钟认出来的（Regressed），整个库的 epoch 被退回去时再加上和自己那份不一样的。</summary>
    private static HashSet<string> Bumped(NoteSyncPart part, NoteSyncFolder.Folder folder, string me, bool rolledBack)
    {
        var local = part.Notes();
        var bump = NoteSyncFolder.Regressed(local, folder, me);
        if (rolledBack && folder.Devices.TryGetValue(me, out var own))
        {
            foreach (var note in local)
            {
                if (own.Notes.TryGetValue(note.Id, out var written) && written != note)
                {
                    bump.Add(note.Id);
                }
            }
        }

        return bump;
    }

    private readonly record struct NoteStep(int Braked, string? Problem, NoteSyncFolder.PublishPlan? Plan);

    /// <summary>合便签：Round → 刹车 → 正在编辑的先不换 → 落下去 → 写的计划（正在编辑的也先不写）+ 共用图片的清理。</summary>
    private async Task<NoteStep> MergeNotes(NoteSyncPart part, NoteSyncSnapshot snapshot, string library, int allowance, long now)
    {
        var local = part.Notes();
        var erased = part.Erased();
        var folder = snapshot.Folder;
        var round = await Task.Run(() => NoteSyncFolder.Round(local, erased, folder, library, now));
        if (round.Stop is { } stop)
        {
            return new NoteStep(0, stop.Kind switch
            {
                NoteSyncFolder.StopKind.NewerFormat => NewerFormat,
                NoteSyncFolder.StopKind.UnreadableTombstones => "同步文件夹还没下载完",
                _ => "这个文件夹不是这一组同步用的",
            }, null);
        }

        if (round.Brakes && round.Trashing > allowance)
        {
            log?.Invoke($"sync.brake notes deleting={round.Trashing} allowance={allowance}");
            return new NoteStep(round.Trashing, null, null);
        }

        var editing = part.Editing();
        foreach (var id in editing)
        {
            round.Merges.Remove(id);
        }

        if (round.Merges.Count > 0 && !part.Apply(round.Merges, round.Tombstones))
        {
            return new NoteStep(0, "便签没存上", null);
        }

        var after = part.Notes();
        var afterErased = part.Erased();
        var me = device.Id;
        folder.Devices.TryGetValue(me, out var own);
        var localImages = NoteSyncDisk.LocalImages(part.ImagesDirectory);
        var plan = await Task.Run(() => NoteSyncFolder.Publish(after, afterErased, own, localImages, folder.Images));
        plan.Writes.RemoveAll(note => editing.Contains(note.Id));
        if (part.ImagesDirectory is not null && part.ReadLedger is { } read && part.WriteLedger is { } write)
        {
            try
            {
                var referenced = new HashSet<Guid>();
                foreach (var note in after)
                {
                    if (NoteImages.ContainsToken(note.Body))
                    {
                        referenced.UnionWith(NoteImages.Ids(note.Body));
                    }
                }

                referenced.UnionWith(NoteSyncFolder.ReferencedImages(folder));
                var localIds = localImages.Select(NoteImageRules.Identifier).OfType<Guid>().ToHashSet();
                var purge = NoteSyncFolder.ImagePurge(folder.Images, referenced, localIds,
                    NoteSyncFolder.LedgerFrom(read()), NoteSyncFolder.IsReadable(folder) && !snapshot.Pending, now);
                plan.ImageDeletes = purge.Deletes.ToList();
                write(NoteSyncFolder.LedgerText(purge.Ledger));
            }
            catch (Exception ex)
            {
                // 账读不出来：这一轮一张不删
                log?.Invoke($"sync.notes-ledger-unreadable {ex.GetType().Name}");
            }
        }

        return new NoteStep(0, null, plan);
    }

    /// <summary>写完：写成了的便签告诉仓库，拿下来的图告诉编辑器，删成了的共用图从账上去掉。</summary>
    private void NotesWritten(NoteSyncPart part, List<string>? written, HashSet<Guid>? downloaded, List<string>? purged)
    {
        if (written is { Count: > 0 })
        {
            part.Published?.Invoke(written);
        }

        if (downloaded is { Count: > 0 })
        {
            part.ImagesArrived?.Invoke(downloaded);
        }

        if (purged is { Count: > 0 } && part.ReadLedger is { } read && part.WriteLedger is { } write)
        {
            try
            {
                var ledger = NoteSyncFolder.LedgerFrom(read());
                foreach (var name in purged)
                {
                    ledger.Remove(name);
                }

                write(NoteSyncFolder.LedgerText(ledger));
            }
            catch (Exception ex)
            {
                log?.Invoke($"sync.notes-ledger-failed {ex.GetType().Name}");
            }
        }
    }

    /// <summary>读出来的一份 → 引擎要的样子；结构不对、有一条不是规范写法（decodeExact）= null。</summary>
    private static SyncFileData? ToData(SyncFile? file, string kind)
    {
        if (file is null || file.IsNewer || !file.Records.All(record => SyncEngine.DecodeExact(record.Value)))
        {
            return null;
        }

        var data = new SyncFileData();
        foreach (var record in file.Records)
        {
            data.Records[record.Id] = new SyncValue { Value = record.Value, Clock = record.Clock, Modified = record.Modified };
        }

        foreach (var erased in file.Erased)
        {
            data.Erased[erased.Id] = erased.Clock;
        }

        return data;
    }

    public static SyncFile ToFile(string kind, SyncFileData data)
    {
        var file = new SyncFile { Kind = kind };
        foreach (var (id, value) in data.Records)
        {
            file.Records.Add(new SyncRecord { Id = id, Clock = value.Clock, Modified = value.Modified, Value = value.Value });
        }

        foreach (var (id, clock) in data.Erased)
        {
            file.Erased.Add(new SyncErased { Id = id, Clock = clock });
        }

        return file;
    }

    /// <summary>一轮开始时读到的文件夹（线程池上读，之后只读不改）。</summary>
    private sealed class Snapshot
    {
        /// <summary>便签那部分（notes 不为 null 时读）。</summary>
        public NoteSyncSnapshot? Notes { get; private init; }

        /// <summary>每台的 device.json 有、却读不出来（便签那部分要看自己的）。</summary>
        public HashSet<string> BrokenDevices { get; } = new(StringComparer.Ordinal);

        public bool Usable { get; private init; }

        public string? Library { get; private init; }

        public bool MarkerPending { get; private init; }

        public bool Foreign { get; private init; }

        public Dictionary<string, Peer> Peers { get; } = new(StringComparer.Ordinal);

        public sealed class Peer
        {
            public string? DeviceText { get; init; }

            public string? Name { get; init; }

            public int Epoch { get; init; }

            public Dictionary<string, string?> Files { get; } = new(StringComparer.Ordinal);
        }

        public int Epoch(string device) => Peers.TryGetValue(device, out var peer) ? peer.Epoch : 0;

        public string? DeviceText(string device) => Peers.TryGetValue(device, out var peer) ? peer.DeviceText : null;

        public string? File(string device, string kind)
            => Peers.TryGetValue(device, out var peer) && peer.Files.TryGetValue(kind, out var text) ? text : null;

        public static Snapshot Read(SyncDisk disk, IReadOnlyList<string> kinds, bool notes = false)
        {
            if (!disk.IsUsable)
            {
                return new Snapshot();
            }

            var library = disk.Marker();
            var ids = disk.DeviceIds();
            var snapshot = new Snapshot
            {
                Usable = true,
                Library = library,
                MarkerPending = library is null && disk.Exists(SyncFolderRules.MarkerFile) &&
                                disk.ReadText(SyncFolderRules.MarkerFile) is null,
                Foreign = library is null && disk.LooksForeign(),
                Notes = notes ? NoteSyncDisk.Read(disk, ids) : null,
            };
            foreach (var id in ids)
            {
                var text = disk.ReadText(SyncDisk.DevicePath(id));
                var parsed = text is null ? null : SyncFolderRules.ParseDevice(text);
                if (parsed is null && disk.Exists(SyncDisk.DevicePath(id)))
                {
                    snapshot.BrokenDevices.Add(id);
                }

                if (snapshot.Notes?.Folder.Devices.TryGetValue(id, out var noteDevice) == true)
                {
                    noteDevice.Name = parsed?.Name;
                    noteDevice.Epoch = parsed?.Epoch;
                }

                var peer = new Peer { DeviceText = text, Name = parsed?.Name, Epoch = parsed?.Epoch ?? 0 };
                foreach (var kind in kinds)
                {
                    peer.Files[kind] = disk.ReadText(SyncDisk.KindPath(id, kind));
                }

                snapshot.Peers[id] = peer;
            }

            return snapshot;
        }
    }
}
