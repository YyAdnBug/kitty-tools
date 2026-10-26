// 同步的文件夹读写与执行层（PLAN-v5 §2.1–§2.3、§4）：只写自己的子文件夹；占位文件不读；临时文件 + 替换。
// 一轮：本地改动先算钟 → 读文件夹里各台的文件 → 合并 → 刹车 → 落地 → 写自己的文件 → 写 device.json。
// 账本放在关键数据旁边的 SyncLedger；库编号变化当第一次合。
using System.Text.Json;
using System.Text.Json.Nodes;
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class SyncFolder(string root)
{
    public string Root { get; } = root;

    public bool IsUsable => Directory.Exists(Root);

    public static bool IsPlaceholder(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return (attributes & (FileAttributes)0x400000) != 0 || // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                   (attributes & FileAttributes.Offline) != 0;
        }
        catch
        {
            return true;
        }
    }

    public string? ReadText(string relative)
    {
        var path = Path.Combine(Root, relative);
        try
        {
            if (!File.Exists(path) || IsPlaceholder(path) || new FileInfo(path).Length > SyncFile.MaxBytes)
            {
                return null;
            }

            return File.ReadAllText(path);
        }
        catch
        {
            return null;
        }
    }

    public bool WriteText(string relative, string text)
    {
        var path = Path.Combine(Root, relative);
        var temporary = path + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(temporary, text);
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"sync.write-failed {relative} {ex.GetType().Name}");
            return false;
        }
    }

    public string? Marker() => ReadText(SyncFolderRules.MarkerFile) is { } text
        ? SyncFolderRules.ParseMarker(text)
        : null;

    public List<string> DeviceIds()
    {
        var folder = Path.Combine(Root, SyncFolderRules.DevicesFolder);
        try
        {
            return Directory.Exists(folder)
                ? Directory.EnumerateDirectories(folder)
                    .Select(Path.GetFileName)
                    .Where(name => name is not null && SyncFolderRules.IsDeviceName(name))
                    .Select(name => name!)
                    .ToList()
                : new List<string>();
        }
        catch
        {
            return new List<string>();
        }
    }

    /// <summary>每个子文件夹里都有东西却连标记都没有：不是我们的文件夹，不碰。</summary>
    public bool LooksForeign()
    {
        if (Marker() is not null)
        {
            return false;
        }

        try
        {
            return Directory.Exists(Root) && Directory.EnumerateFileSystemEntries(Root).Any();
        }
        catch
        {
            return true;
        }
    }
}

internal static class SyncSources
{
    /// <summary>本机交给引擎的一条：编号 → 编好的内容（键排好序，和 mac 各自的 Synced 结构一字不差）。</summary>
    // 片段 / 收藏：留下来的文字条目（收藏、片段、在收藏夹里的；mac isRetained）。带 NUL 的整条不同步（同 mac syncValues）。
    // 收藏夹是空表时也交 ~order（同 mac）。拿不到仓库时返回 null：这一类这一轮不合（当成空的会把账本里的全当成删了）。
    public static Dictionary<string, string>? ClipRecords(ClipboardStore? store)
    {
        if (store is null)
        {
            return null;
        }

        var records = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in store.Items.Where(item => item.Kind == ClipKind.Text && IsRetained(item)))
        {
            if (entry.Text is null || entry.Text.Contains('\0') || entry.Note?.Contains('\0') == true)
            {
                continue;
            }

            store.EnsureUid(entry);
            records[entry.Uid!] = Clip(entry.Text, entry.Favorite, entry.Snippet, entry.Note, entry.GroupId);
        }

        var groups = store.Groups.Where(group => !group.Name.Contains('\0')).OrderBy(group => group.Position).ToList();
        foreach (var group in groups)
        {
            records[GroupPrefix + group.Id] = Group(group.Name, group.CreatedAt);
        }

        records[SyncEngine.OrderID] = SyncEngine.OrderValue(groups.Select(group => GroupPrefix + group.Id));
        return records;
    }

    public const string GroupPrefix = "group:";

    public static bool IsRetained(ClipEntry entry) => entry.Favorite || entry.Snippet || entry.GroupId is not null;

    /// <summary>mac SyncedClip：favorite / group? / note? / snippet / text；group 是收藏夹编号本身（不带 group: 前缀）。</summary>
    public static string Clip(string text, bool favorite, bool snippet, string? note, string? group)
    {
        var builder = new System.Text.StringBuilder("{");
        builder.Append("\"favorite\":").Append(favorite ? "true" : "false");
        if (group is not null)
        {
            builder.Append(",\"group\":");
            CanonicalJson.WriteString(group, builder);
        }

        if (note is not null)
        {
            builder.Append(",\"note\":");
            CanonicalJson.WriteString(note, builder);
        }

        builder.Append(",\"snippet\":").Append(snippet ? "true" : "false");
        builder.Append(",\"text\":");
        CanonicalJson.WriteString(text, builder);
        return builder.Append('}').ToString();
    }

    /// <summary>mac SyncedGroup：created（毫秒）/ name。</summary>
    public static string Group(string name, long created)
        => $"{{\"created\":{created},\"name\":{Quote(name)}}}";

    public static Dictionary<string, string>? VocabularyRecords(TranslationHistory? history)
        => history?.Search(string.Empty, favoritesOnly: true, limit: 0)
            .ToDictionary(
                entry => entry.Id,
                entry => Vocabulary(entry.Source, entry.TargetLang, entry.Result, entry.Service, entry.CreatedAt),
                StringComparer.Ordinal);

    /// <summary>mac SyncedWord：created / result / service / source / target。</summary>
    public static string Vocabulary(string source, string target, string result, string service, long created)
        => $"{{\"created\":{created},\"result\":{Quote(result)},\"service\":{Quote(service)}," +
           $"\"source\":{Quote(source)},\"target\":{Quote(target)}}}";

    public static Dictionary<string, string> EngineRecords(IReadOnlyList<SearchEngine> engines)
    {
        var records = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var engine in engines)
        {
            records.TryAdd(engine.Id, Engine(engine));
        }

        records[SyncEngine.OrderID] = SyncEngine.OrderValue(engines.Select(engine => engine.Id));
        return records;
    }

    /// <summary>mac WebSearchSync.Synced：fallback / keyword / name / url。</summary>
    public static string Engine(SearchEngine engine)
        => $"{{\"fallback\":{(engine.Fallback ? "true" : "false")},\"keyword\":{Quote(engine.Keyword)}," +
           $"\"name\":{Quote(engine.Name)},\"url\":{Quote(engine.UrlTemplate)}}}";

    public static Dictionary<string, string>? ServiceRecords(TranslateServiceStore? store)
    {
        if (store is null)
        {
            return null;
        }

        var records = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var service in store.Services)
        {
            records.TryAdd(service.Id, Service(service));
        }

        records[SyncEngine.OrderID] = SyncEngine.OrderValue(store.Services.Select(service => service.Id));
        return records;
    }

    /// <summary>键按字母排：aiProtocol / baseURL / id / isEnabled / kind / model / name / region / usesDeepLX。</summary>
    public static string Service(TranslateServiceConfig service)
    {
        var builder = new System.Text.StringBuilder("{");
        var first = true;
        void Field(string name, string value)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(name, builder);
            builder.Append(':').Append(value);
        }

        if (!string.IsNullOrEmpty(service.Protocol))
        {
            Field("aiProtocol", Quote(service.Protocol));
        }

        if (!string.IsNullOrEmpty(service.BaseUrl))
        {
            Field("baseURL", Quote(service.BaseUrl));
        }

        Field("id", Quote(service.Id));
        Field("isEnabled", service.Enabled ? "true" : "false");
        Field("kind", Quote(service.Kind));
        if (!string.IsNullOrEmpty(service.Model))
        {
            Field("model", Quote(service.Model));
        }

        Field("name", Quote(service.Name));
        if (!string.IsNullOrEmpty(service.Region))
        {
            Field("region", Quote(service.Region));
        }

        if (service.UsesDeepLX)
        {
            Field("usesDeepLX", "true");
        }

        return builder.Append('}').ToString();
    }

    /// <summary>顺序那条（编号数组）；解不出来、或编回去不一样 = null。</summary>
    public static List<string>? DecodeOrder(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var ids = new List<string>();
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                ids.Add(item.GetString()!);
            }

            return SyncEngine.OrderValue(ids) == value ? ids : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Quote(string value)
    {
        var builder = new System.Text.StringBuilder();
        CanonicalJson.WriteString(value, builder);
        return builder.ToString();
    }
}

internal sealed class SyncStatus
{
    public string State { get; set; } = "off";

    public string Message { get; set; } = string.Empty;

    public long LastSync { get; set; }

    public int PendingDeletions { get; set; }

    public List<string> Devices { get; set; } = new();
}

internal sealed class Syncer
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(20);
    private static Syncer? _instance;
    private readonly SyncDevice _device;
    private readonly SyncLedger _ledger;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;
    private bool _busy;
    private bool _confirmed;

    private Syncer(SyncDevice device, SyncLedger ledger)
    {
        _device = device;
        _ledger = ledger;
    }

    public static Syncer? Instance => _instance;

    public static Syncer Start(SyncDevice device, SyncLedger ledger)
    {
        _instance = new Syncer(device, ledger);
        Log.Info($"sync.start enabled={_instance.Enabled} folder={SettingsService.Current.SyncFolder}");
        return _instance;
    }

    /// <summary>卸载前停掉定时器（REVIEW R25），不再往数据目录里写。</summary>
    public static void StopAll()
    {
        _instance?._timer?.Stop();
        _instance?._timer = null;
    }

    public SyncStatus Status { get; } = new();

    public event Action? Changed;

    public string? Folder
    {
        get => SettingsService.Current.SyncFolder;
        set
        {
            SettingsService.Current.SyncFolder = value;
            SettingsService.Save();
        }
    }

    public bool Enabled => SettingsService.Current.SyncEnabled && !string.IsNullOrEmpty(Folder);

    public void StartTimer(Microsoft.UI.Dispatching.DispatcherQueue dispatcher)
    {
        _timer ??= dispatcher.CreateTimer();
        _timer.Interval = Interval;
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => _ = RoundAsync();
        _timer.Start();
    }

    public async Task RoundAsync()
    {
        if (_busy || !Enabled || Folder is not { } folder)
        {
            return;
        }

        _busy = true;
        Status.State = "syncing";
        Changed?.Invoke();
        try
        {
            // 读文件夹 / 合在线程池上跑（云盘里读一个还没下载的文件会卡几秒），回 UI 线程落地。
            await RunRoundAsync(folder);
        }
        catch (Exception ex)
        {
            Log.Warn($"sync.round-failed {ex.GetType().Name}");
            Status.State = "stopped";
            Status.Message = "同步出错";
        }
        finally
        {
            _busy = false;
            _confirmed = false;
            Changed?.Invoke();
        }
    }

    private async Task RunRoundAsync(string folder)
    {
        var disk = new SyncFolder(folder);
        if (!disk.IsUsable)
        {
            Status.State = "stopped";
            Status.Message = "文件夹不在了";
            return;
        }

        var library = disk.Marker();
        if (library is null)
        {
            if (disk.LooksForeign())
            {
                Status.State = "stopped";
                Status.Message = "这个文件夹里已经有别的东西了";
                return;
            }

            library = Guid.NewGuid().ToString("D").ToUpperInvariant();
            disk.WriteText(SyncFolderRules.MarkerFile, SyncFolderRules.Marker(library));
        }

        if (_device.Library != library)
        {
            _device.SetLibrary(library);
        }

        // 认出库被退回去了（从旧备份恢复过）：文件夹里本机的 epoch 比上次写出去的大，就换一个新编号。
        var devicePath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.DeviceFile);
        var existing = disk.ReadText(devicePath);
        var epoch = existing is not null && SyncFolderRules.ParseDevice(existing) is { } parsed ? parsed.Epoch : 0;
        var localEpoch = _ledger.ReadEpoch();
        if (localEpoch > 0 && epoch > localEpoch)
        {
            Log.Warn($"sync.epoch-rollback folder={epoch} local={localEpoch}");
            _device.Rotate();
            _device.SetLibrary(library);
            devicePath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.DeviceFile);
            existing = null;
            epoch = 0;
        }

        var kinds = new List<string>();
        if (SettingsService.Current.SyncClips) kinds.Add("clips");
        if (SettingsService.Current.SyncVocabulary) kinds.Add("vocabulary");
        if (SettingsService.Current.SyncEngines) kinds.Add("engines");
        if (SettingsService.Current.SyncServices) kinds.Add("services");

        var otherDevices = disk.DeviceIds().Where(id => id != _device.Id).ToList();
        Status.Devices = otherDevices;
        Status.PendingDeletions = 0;
        Status.Message = string.Empty;
        foreach (var kind in kinds)
        {
            try
            {
                await SyncKindAsync(disk, kind, library);
            }
            catch (Exception ex)
            {
                Log.Warn($"sync.kind-failed {kind} {ex.GetType().Name}");
            }
        }

        // device.json 最后写：epoch 每轮 +1。
        disk.WriteText(devicePath, SyncFolderRules.DeviceJson(epoch + 1, Environment.MachineName));
        _ledger.WriteEpoch(epoch + 1);
        // 某一类停在「等你确认」「停了」时不盖掉它（之前每轮最后都改回「好了」，刹车的提示永远看不到）。
        if (Status.State == "syncing")
        {
            Status.State = "idle";
            Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }
    }

    /// <summary>刹车之后用户点了「照样同步」：下一轮放过删除。</summary>
    public void ConfirmDeletions()
    {
        _confirmed = true;
        _ = RoundAsync();
    }

    private async Task SyncKindAsync(SyncFolder disk, string kind, string library)
    {
        // 仓库还没起来（或读不出来）：这一类这一轮不合。当成空表交进去的话，账本里的每一条都成了「本机删了」，删到每一台。
        if (Local(kind) is not { } localMap)
        {
            Log.Warn($"sync.kind-unavailable {kind}");
            return;
        }

        var old = ReadEngineLedger(kind, library);

        Func<string, string?> dedupe = kind switch
        {
            // 第一次合的去重键（照 mac 各自的 syncJoin）：同样的正文 / 收藏夹名、同原文和目标语言、
            // 同网址和关键词、同协议 + 地址 + 模型的自建 AI 服务，只留文件夹里那条。
            "clips" => ExtractClipKey,
            "vocabulary" => ExtractVocabularyKey,
            "engines" => ExtractEngineKey,
            _ => ExtractServiceKey,
        };

        // 云盘里读一个还没下载的文件会卡几秒：读文件和合都放到线程池，回 UI 线程落地。
        var plan = await Task.Run(() => BuildPlan(disk, kind, localMap, old, dedupe));
        if (plan.Error is not null)
        {
            Status.State = "stopped";
            Status.Message = plan.Error;
            return;
        }

        var outcome = plan.Outcome!;
        // 刹车两样（mac NoteSyncFolder.brakes + SyncRecords 文件头）：别处来的删掉本机一大批（trashing）、本机自己这一轮
        // 删了一大批（erasing，比如库被清空）——都先问，用户点了「照样同步」的那一轮才放过去。
        var erasingTotal = old?.Entries.Count ?? 0;
        var braking = SyncFolderRules.ShouldBrake(outcome.Trashing, outcome.Alive) ||
                      SyncFolderRules.ShouldBrake(outcome.Erasing, erasingTotal);
        if (braking && !_confirmed)
        {
            var count = Math.Max(outcome.Trashing, outcome.Erasing);
            Status.State = "confirm";
            Status.PendingDeletions += count;
            Status.Message = $"同步要删掉 {Status.PendingDeletions} 条，等你确认";
            return;
        }

        var merged = ToSyncFile(kind, outcome.Own);
        // 落地和账本同一个事务（R13 / SyncRecords 文件头「执行层必须守住的」）：片段、生词在库里，账本也在库里。
        var transactional = kind is "clips" or "vocabulary";
        if (transactional)
        {
            _ledger.Database.BeginTransaction();
        }

        bool applied;
        try
        {
            // 有一条解不出来（或者是更新版本写的、编回去不一样）：整个不落、也不存账本（照 mac applySync 返回 false）。
            // 落了一半的话，没落下的那几条下一轮成了「本机删了」，删到每一台。
            applied = Apply(kind, merged);
            if (applied)
            {
                WriteEngineLedger(kind, library, outcome.Ledger);
            }

            if (transactional)
            {
                if (applied)
                {
                    _ledger.Database.Commit();
                }
                else
                {
                    _ledger.Database.Rollback();
                }
            }
        }
        catch
        {
            if (transactional)
            {
                _ledger.Database.Rollback();
            }

            throw;
        }

        if (!applied)
        {
            Log.Warn($"sync.apply-refused {kind}");
            Status.State = "stopped";
            Status.Message = "有内容这一版读不懂，先没存上（可能要更新 Kitty Tools）";
            return;
        }

        var ownPath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.FileName(kind));
        var encoded = merged.Encode();
        await Task.Run(() => disk.WriteText(ownPath, encoded));
    }

    private (SyncOutcome? Outcome, string? Error) BuildPlan(
        SyncFolder disk, string kind, Dictionary<string, string> localMap,
        SyncLedgerData? old, Func<string, string?> dedupe)
    {
        // 自己那份（账本退回时要用它的钟追上）。
        var ownPath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.FileName(kind));
        var own = ReadEngineFile(disk.ReadText(ownPath), kind, out var ownNewer);
        if (ownNewer)
        {
            return (null, "同步文件夹是新版本写的，请更新 Kitty Tools");
        }

        var others = new List<SyncFileData>();
        foreach (var id in disk.DeviceIds().Where(id => id != _device.Id))
        {
            var text = disk.ReadText(Path.Combine(SyncFolderRules.DevicesFolder, id, SyncFolderRules.FileName(kind)));
            if (text is null)
            {
                continue;
            }

            var remote = ReadEngineFile(text, kind, out var newer);
            if (remote is null)
            {
                // 只扔这一版，这一类照合。
                continue;
            }

            if (newer)
            {
                return (null, "同步文件夹是新版本写的，请更新 Kitty Tools");
            }

            others.Add(remote);
        }

        var outcome = SyncEngine.Round(
            localMap, NoChanged, old, own, others, _device.Id,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), JoinMode.Union, dedupe);
        return (outcome, null);
    }

    private static string? ExtractClipKey(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            if (root.TryGetProperty("text", out var text))
            {
                return "clip:" + (text.GetString() ?? string.Empty);
            }

            // 收藏夹：同样的名字只留文件夹里的那条。
            return root.TryGetProperty("name", out var name) ? "group:" + (name.GetString() ?? string.Empty) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? ExtractEngineKey(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            var url = root.TryGetProperty("url", out var urlElement) ? urlElement.GetString() : null;
            var keyword = root.TryGetProperty("keyword", out var keywordElement) ? keywordElement.GetString() : null;
            return url is null || keyword is null ? null : url + "\0" + keyword;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? ExtractServiceKey(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            var kind = root.TryGetProperty("kind", out var kindElement) ? kindElement.GetString() : null;
            if (kind != "ai")
            {
                return null;
            }

            var protocol = root.TryGetProperty("aiProtocol", out var protocolElement) ? protocolElement.GetString() : null;
            var baseUrl = root.TryGetProperty("baseURL", out var baseElement) ? baseElement.GetString() : null;
            var model = root.TryGetProperty("model", out var modelElement) ? modelElement.GetString() : null;
            return (protocol ?? string.Empty) + "\0" + (baseUrl ?? string.Empty) + "\0" + (model ?? string.Empty);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? ExtractVocabularyKey(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            var source = root.TryGetProperty("source", out var sourceElement) ? sourceElement.GetString() : null;
            var target = root.TryGetProperty("target", out var targetElement) ? targetElement.GetString() : null;
            return source is null || target is null ? null : source + "\0" + target;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static SyncFileData? ReadEngineFile(string? text, string kind, out bool newer)
    {
        newer = false;
        if (text is null)
        {
            return null;
        }

        var file = SyncFile.Decode(text, kind);
        if (file is null)
        {
            return null;
        }

        if (file.IsNewer)
        {
            newer = true;
            return null;
        }

        if (!file.Records.All(record => SyncEngine.DecodeExact(record.Value)))
        {
            Log.Warn($"sync.decode-exact-failed kind={kind}");
            return null;
        }

        var data = new SyncFileData();
        foreach (var record in file.Records)
        {
            data.Records[record.Id] = new SyncValue
            {
                Value = record.Value,
                Clock = record.Clock,
                Modified = record.Modified,
            };
        }

        foreach (var erased in file.Erased)
        {
            data.Erased[erased.Id] = erased.Clock;
        }

        return data;
    }

    private static SyncFile ToSyncFile(string kind, SyncFileData data)
    {
        var file = new SyncFile { Kind = kind };
        foreach (var (id, value) in data.Records)
        {
            file.Records.Add(new SyncRecord
            {
                Id = id,
                Clock = value.Clock,
                Modified = value.Modified,
                Value = value.Value,
            });
        }

        foreach (var (id, clock) in data.Erased)
        {
            file.Erased.Add(new SyncErased { Id = id, Clock = clock });
        }

        return file;
    }

    // ponytail: 四类都没给「真正改的时刻」（剪贴板的复制时间不是改动时间，mac 也不拿它当改于），
    // 所以 changed 交空表：改于用「这一轮发现它变了」的现在（不晚于 now，SyncEngine 里取 min）。
    // 以后设置 / 服务记了每一项真正改的时刻，再从这里传进去。
    private static readonly Dictionary<string, long> NoChanged = new(StringComparer.Ordinal);

    private static Dictionary<string, string>? Local(string kind) => kind switch
    {
        "clips" => SyncSources.ClipRecords(ClipboardService.Instance?.Store),
        "vocabulary" => SyncSources.VocabularyRecords(TranslationHistory.Instance),
        "engines" => SyncSources.EngineRecords(SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults()),
        _ => SyncSources.ServiceRecords(TranslateServiceStore.Instance),
    };

    /// <summary>账本：每条的钟、内容哈希、改于 + 墓碑；旧格式（clock|hash）当 modified=0 迁过来。</summary>
    private SyncLedgerData? ReadEngineLedger(string kind, string library)
    {
        var text = _ledger.Read(kind);
        var storedLibrary = _ledger.ReadLibrary(kind);
        if (text is null || (kind is "clips" or "vocabulary" && storedLibrary != library))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var ledger = new SyncLedgerData();
            if (root.TryGetProperty("entries", out var entries) && entries.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in entries.EnumerateObject())
                {
                    if (property.Value.ValueKind != JsonValueKind.Object ||
                        !property.Value.TryGetProperty("clock", out var clock) ||
                        !property.Value.TryGetProperty("hash", out var hash) ||
                        !property.Value.TryGetProperty("modified", out var modified))
                    {
                        continue;
                    }

                    ledger.Entries[property.Name] = new SyncEntry(
                        SyncClock.Parse(clock.GetString() ?? string.Empty),
                        hash.GetString() ?? string.Empty,
                        modified.TryGetInt64(out var value) ? value : 0);
                }

                if (root.TryGetProperty("erased", out var erased) && erased.ValueKind == JsonValueKind.Object)
                {
                    foreach (var property in erased.EnumerateObject())
                    {
                        ledger.Erased[property.Name] = SyncClock.Parse(property.Value.GetString() ?? string.Empty);
                    }
                }

                return ledger;
            }

            // 旧格式：{id: "clock|hash"}；没有墓碑（旧引擎把墓碑写进 records 的 erased 字段？没有，就丢了）。
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name == "~clock" || property.Value.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var parts = (property.Value.GetString() ?? string.Empty).Split('|');
                if (parts.Length != 2)
                {
                    continue;
                }

                ledger.Entries[property.Name] = new SyncEntry(SyncClock.Parse(parts[0]), parts[1], 0);
            }

            return ledger.Entries.Count > 0 ? ledger : null;
        }
        catch (Exception ex) when (ex is JsonException or FormatException)
        {
            return null;
        }
    }

    private void WriteEngineLedger(string kind, string library, SyncLedgerData ledger)
    {
        var builder = new System.Text.StringBuilder("{\"entries\":{");
        var first = true;
        foreach (var (id, entry) in ledger.Entries.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(":{\"clock\":");
            CanonicalJson.WriteString(entry.Clock.Text(), builder);
            builder.Append(",\"hash\":");
            CanonicalJson.WriteString(entry.Hash, builder);
            builder.Append(",\"modified\":").Append(entry.Modified).Append('}');
        }

        builder.Append("},\"erased\":{");
        first = true;
        foreach (var (id, clock) in ledger.Erased.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(':');
            CanonicalJson.WriteString(clock.Text(), builder);
        }

        builder.Append("}}");
        _ledger.Write(kind, library, builder.ToString());
    }

    /// <summary>落合并结果。先把每一条按 mac 的结构解开、再用本机的编码编回去，必须一字不差（mac decodeExact）：
    /// 多了这一版不认识的字段、类型不对的，整类不落（返回 false），免得落下去再发出去把别人的字段删了。
    /// 全部解得开才动本机。</summary>
    private static bool Apply(string kind, SyncFile merged) => kind switch
    {
        "clips" => ApplyClips(merged),
        "vocabulary" => ApplyVocabulary(merged),
        "engines" => ApplyEngines(merged),
        _ => ApplyServices(merged),
    };

    private static string? Text(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool Flag(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static long? Number(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number &&
           value.TryGetInt64(out var number)
            ? number
            : null;

    /// <summary>解开一条；不是对象 = null。</summary>
    private static T? Decode<T>(string value, Func<JsonElement, T?> read)
        where T : class
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            return document.RootElement.ValueKind == JsonValueKind.Object ? read(document.RootElement) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private sealed record SyncedClip(string Text, bool Favorite, bool Snippet, string? Note, string? Group);

    private sealed record SyncedGroup(string Name, long Created);

    private static bool ApplyClips(SyncFile merged)
    {
        if (ClipboardService.Instance?.Store is not { } store)
        {
            return false;
        }

        var order = new List<string>();
        var groups = new List<ClipGroup>();
        var clips = new List<(string Uid, SyncedClip Clip)>();
        foreach (var record in merged.Records.OrderBy(record => record.Id, StringComparer.Ordinal))
        {
            if (record.Id == SyncEngine.OrderID)
            {
                if (SyncSources.DecodeOrder(record.Value) is not { } ids)
                {
                    return false;
                }

                order = ids;
            }
            else if (record.Id.StartsWith(SyncSources.GroupPrefix, StringComparison.Ordinal))
            {
                var group = Decode(record.Value, root =>
                    Text(root, "name") is { } name && Number(root, "created") is { } created
                        ? new SyncedGroup(name, created)
                        : null);
                var id = record.Id[SyncSources.GroupPrefix.Length..];
                if (group is null || SyncSources.Group(group.Name, group.Created) != record.Value ||
                    !Guid.TryParse(id, out _))
                {
                    return false;
                }

                groups.Add(new ClipGroup { Id = id, Name = group.Name, CreatedAt = group.Created });
            }
            else
            {
                var clip = Decode(record.Value, root =>
                    Text(root, "text") is { } text
                        ? new SyncedClip(text, Flag(root, "favorite"), Flag(root, "snippet"),
                            Text(root, "note"), Text(root, "group"))
                        : null);
                if (clip is null ||
                    SyncSources.Clip(clip.Text, clip.Favorite, clip.Snippet, clip.Note, clip.Group) != record.Value ||
                    !Guid.TryParse(record.Id, out _))
                {
                    return false;
                }

                clips.Add((record.Id, clip));
            }
        }

        // 收藏夹先（条目要归进去），再条目；别处不再留着的取消收藏、移出片段和收藏夹（不删行）。
        var arranged = SyncEngine.Arranged(groups.Select(group => SyncSources.GroupPrefix + group.Id), order);
        var resolve = store.ReplaceSyncedGroups(arranged
            .Select(key => groups.First(group => SyncSources.GroupPrefix + group.Id == key))
            .ToList());
        // 先「不再留着」的、再新来的（照 mac：先放掉的那条才能被同样正文的新来的接过去）。
        store.UnfavoriteMissing(clips.Select(item => item.Uid).ToHashSet(StringComparer.Ordinal));
        foreach (var (uid, clip) in clips)
        {
            var entry = store.EnsureClip(uid, clip.Text);
            store.ApplySynced(entry.Id, clip.Favorite, clip.Snippet, clip.Note, resolve(clip.Group));
        }

        return true;
    }

    private static bool ApplyVocabulary(SyncFile merged)
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return false;
        }

        var words = new List<(string Id, TranslationEntry Word)>();
        foreach (var record in merged.Records.OrderBy(record => record.Id, StringComparer.Ordinal))
        {
            var word = Decode(record.Value, root =>
                Text(root, "source") is { } source && Text(root, "target") is { } target &&
                Text(root, "result") is { } result && Text(root, "service") is { } service &&
                Number(root, "created") is { } created
                    ? new TranslationEntry
                    {
                        Id = record.Id, Source = source, TargetLang = target, Result = result, Service = service,
                        CreatedAt = created,
                    }
                    : null);
            if (word is null ||
                SyncSources.Vocabulary(word.Source, word.TargetLang, word.Result, word.Service, word.CreatedAt) !=
                record.Value)
            {
                return false;
            }

            words.Add((record.Id, word));
        }

        // 先取消收藏的、再新来的（照 mac）：不然别处删了的那条还占着「同原文 + 目标语言」，新来的会被它挤掉。
        history.UnfavoriteMissing(words.Select(item => item.Id).ToHashSet(StringComparer.Ordinal));
        foreach (var (id, word) in words)
        {
            history.UpsertSynced(id, word.Source, word.TargetLang, word.Result, word.Service, word.CreatedAt);
        }

        return true;
    }

    private static bool ApplyEngines(SyncFile merged)
    {
        var order = new List<string>();
        var byId = new Dictionary<string, SearchEngine>(StringComparer.Ordinal);
        foreach (var record in merged.Records)
        {
            if (record.Id == SyncEngine.OrderID)
            {
                if (SyncSources.DecodeOrder(record.Value) is not { } ids)
                {
                    return false;
                }

                order = ids;
                continue;
            }

            var engine = Decode(record.Value, root =>
                Text(root, "name") is { } name && Text(root, "keyword") is { } keyword &&
                Text(root, "url") is { } url
                    ? new SearchEngine
                    {
                        Id = record.Id, Name = name, Keyword = keyword, UrlTemplate = url,
                        Fallback = Flag(root, "fallback"),
                    }
                    : null);
            if (engine is null || SyncSources.Engine(engine) != record.Value)
            {
                return false;
            }

            byId[record.Id] = engine;
        }

        SettingsService.Current.LauncherSearchEngines =
            SyncEngine.Arranged(byId.Keys, order).Select(id => byId[id]).ToList();
        SettingsService.Save();
        return true;
    }

    private static bool ApplyServices(SyncFile merged)
    {
        if (TranslateServiceStore.Instance is not { } store)
        {
            return false;
        }

        var order = new List<string>();
        var byId = new Dictionary<string, TranslateServiceConfig>(StringComparer.Ordinal);
        foreach (var record in merged.Records)
        {
            if (record.Id == SyncEngine.OrderID)
            {
                if (SyncSources.DecodeOrder(record.Value) is not { } ids)
                {
                    return false;
                }

                order = ids;
                continue;
            }

            var service = Decode(record.Value, root =>
                Text(root, "kind") is { Length: > 0 } kind && Text(root, "name") is { } name &&
                Text(root, "id") == record.Id
                    ? new TranslateServiceConfig
                    {
                        Id = record.Id,
                        Kind = kind,
                        Name = name,
                        Enabled = Flag(root, "isEnabled"),
                        // 没写协议就是没有（不补 openai）：补了编回去就多一个字段，对不上。
                        Protocol = Text(root, "aiProtocol"),
                        BaseUrl = Text(root, "baseURL"),
                        Model = Text(root, "model"),
                        Region = Text(root, "region"),
                        UsesDeepLX = Flag(root, "usesDeepLX"),
                    }
                    : null);
            if (service is null || SyncSources.Service(service) != record.Value)
            {
                return false;
            }

            byId[record.Id] = service;
        }

        // 第一次合时被去重掉的本机自建 AI 服务（协议 + 地址 + 模型一样）：密钥搬给留下的那个（它在本机还没有密钥时，
        // PLAN-v5 §4.2）。别处删了的只拿出列表，密钥不删（凭据管理器里的键还在）。
        foreach (var old in store.Services.Where(service => !byId.ContainsKey(service.Id) && service.Kind == "ai"))
        {
            var kept = byId.Values.FirstOrDefault(incoming => incoming.Kind == "ai" &&
                string.Equals(incoming.Protocol ?? string.Empty, old.Protocol ?? string.Empty, StringComparison.Ordinal) &&
                string.Equals(incoming.BaseUrl ?? string.Empty, old.BaseUrl ?? string.Empty, StringComparison.Ordinal) &&
                string.Equals(incoming.Model ?? string.Empty, old.Model ?? string.Empty, StringComparison.Ordinal));
            if (kept is null)
            {
                continue;
            }

            foreach (var field in TranslateKinds.SecretFields("ai"))
            {
                var secret = store.Secret(old, field);
                if (!string.IsNullOrEmpty(secret) && string.IsNullOrEmpty(store.Secret(kept, field)))
                {
                    store.SetSecret(kept, secret, field);
                }
            }

            Log.Info($"sync.service-dedupe keep={kept.Id} drop={old.Id}");
        }

        store.ReplaceServices(SyncEngine.Arranged(byId.Keys, order).Select(id => byId[id]).ToList());
        return true;
    }
}
