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
using System.Text;

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
    ISyncDevice device, IReadOnlyList<ISyncSource> sources, string deviceName, Action<string>? log = null)
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
        _ => kind,
    };

    public async Task<SyncRoundResult> RunAsync(string folder, IReadOnlyDictionary<string, int> allowance, long now)
    {
        var result = new SyncRoundResult();
        var disk = new SyncDisk(folder);
        var kinds = sources.Select(source => source.Kind).ToList();
        var snapshot = await Task.Run(() => Snapshot.Read(disk, kinds));
        if (!snapshot.Usable)
        {
            return result.Stop("文件夹不在了");
        }

        var library = snapshot.Library;
        if (library is null)
        {
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
        }

        if (device.Library != library)
        {
            device.SetLibrary(library);
        }

        // 认出库被退回去了（从旧备份恢复过）：文件夹里本机的 epoch 比本机记着的大，就换一个新编号。
        var folderEpoch = snapshot.Epoch(device.Id);
        if (device.Epoch > 0 && folderEpoch > device.Epoch)
        {
            log?.Invoke($"sync.epoch-rollback folder={folderEpoch} local={device.Epoch}");
            device.Rotate();
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

        // 第几轮：只在真的写了东西时 +1；不往小里写（文件夹里的大说明上面已经换过编号了）。
        var next = Math.Max(device.Epoch, folderEpoch) + (writes.Count > 0 ? 1 : 0);
        var deviceText = SyncFolderRules.DeviceJson(next, deviceName);
        var me = device.Id;
        if (writes.Count > 0 || snapshot.DeviceText(me) != deviceText)
        {
            if (device.Epoch != next)
            {
                device.SetEpoch(next);
            }

            var written = await Task.Run(() =>
            {
                foreach (var (kind, text) in writes)
                {
                    if (!disk.WriteText(SyncDisk.KindPath(me, kind), text))
                    {
                        return false;
                    }
                }

                return disk.WriteText(SyncDisk.DevicePath(me), deviceText);
            });
            if (!written)
            {
                return result.Stop("同步文件夹写不进去");
            }

            result.Written.AddRange(writes.Keys.OrderBy(kind => kind, StringComparer.Ordinal));
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

        public static Snapshot Read(SyncDisk disk, IReadOnlyList<string> kinds)
        {
            if (!disk.IsUsable)
            {
                return new Snapshot();
            }

            var library = disk.Marker();
            var snapshot = new Snapshot
            {
                Usable = true,
                Library = library,
                MarkerPending = library is null && disk.Exists(SyncFolderRules.MarkerFile) &&
                                disk.ReadText(SyncFolderRules.MarkerFile) is null,
                Foreign = library is null && disk.LooksForeign(),
            };
            foreach (var id in disk.DeviceIds())
            {
                var text = disk.ReadText(SyncDisk.DevicePath(id));
                var parsed = text is null ? null : SyncFolderRules.ParseDevice(text);
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
