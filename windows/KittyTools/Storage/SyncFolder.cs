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

internal sealed record SyncReadResult(SyncFile? File, bool Newer, bool Unreadable);

internal static class SyncSources
{
    public static (string Id, string Value, long Modified)[] ClipRecords(ClipboardStore store)
    {
        var records = new List<(string, string, long)>();
        foreach (var entry in store.Items.Where(item => item.Kind == ClipKind.Text && item.Favorite))
        {
            if (entry.Text is null || entry.Text.Contains('\0'))
            {
                continue;
            }

            store.EnsureUid(entry);
            var builder = new System.Text.StringBuilder("{");
            builder.Append("\"favorite\":").Append(entry.Favorite ? "true" : "false");
            if (entry.GroupId is { } group)
            {
                builder.Append(",\"group\":");
                CanonicalJson.WriteString("group:" + group, builder);
            }

            if (!string.IsNullOrEmpty(entry.Note) && !entry.Note.Contains('\0'))
            {
                builder.Append(",\"note\":");
                CanonicalJson.WriteString(entry.Note, builder);
            }

            builder.Append(",\"snippet\":").Append(entry.Snippet ? "true" : "false");
            builder.Append(",\"text\":");
            CanonicalJson.WriteString(entry.Text, builder);
            builder.Append('}');
            records.Add((entry.Uid!, builder.ToString(), entry.CopiedAt));
        }

        foreach (var group in store.Groups)
        {
            records.Add(("group:" + group.Id,
                $"{{\"created\":{group.CreatedAt},\"name\":{Quote(group.Name)}}}", group.CreatedAt));
        }

        records.Add(("~order", Order(store.Groups.OrderBy(item => item.Position).Select(item => "group:" + item.Id)),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        return records.ToArray();
    }

    public static (string Id, string Value, long Modified)[] VocabularyRecords()
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return Array.Empty<(string, string, long)>();
        }

        return history.Search(string.Empty, favoritesOnly: true, limit: 0)
            .Select(entry => (entry.Id,
                $"{{\"created\":{entry.CreatedAt},\"result\":{Quote(entry.Result)}," +
                $"\"service\":{Quote(entry.Service)},\"source\":{Quote(entry.Source)}," +
                $"\"target\":{Quote(entry.TargetLang)}}}",
                entry.CreatedAt))
            .ToArray();
    }

    public static (string Id, string Value, long Modified)[] EngineRecords()
    {
        var engines = SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults();
        var records = engines
            .Select(engine => (engine.Id,
                $"{{\"fallback\":{(engine.Fallback ? "true" : "false")},\"keyword\":{Quote(engine.Keyword)}," +
                $"\"name\":{Quote(engine.Name)},\"url\":{Quote(engine.UrlTemplate)}}}",
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))
            .ToList();
        records.Add(("~order", Order(engines.Select(engine => engine.Id)),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        return records.ToArray();
    }

    public static (string Id, string Value, long Modified)[] ServiceRecords()
    {
        if (TranslateServiceStore.Instance is not { } store)
        {
            return Array.Empty<(string, string, long)>();
        }

        var records = new List<(string, string, long)>();
        foreach (var service in store.Services)
        {
            // 键按字母排：aiProtocol / baseURL / id / isEnabled / kind / model / name / region / usesDeepLX。
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

            builder.Append('}');
            records.Add((service.Id, builder.ToString(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        }

        records.Add(("~order", Order(store.Services.Select(service => service.Id)),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        return records.ToArray();
    }

    private static string Quote(string value)
    {
        var builder = new System.Text.StringBuilder();
        CanonicalJson.WriteString(value, builder);
        return builder.ToString();
    }

    private static string Order(IEnumerable<string> ids)
    {
        var builder = new System.Text.StringBuilder("[");
        var first = true;
        foreach (var id in ids)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
        }

        builder.Append(']');
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

    // ponytail: R13 修完之前不跑同步；引擎和集成测试过了改成 true（R13 完成）。
    public static readonly bool Ready = true;

    public bool Enabled => Ready && SettingsService.Current.SyncEnabled && !string.IsNullOrEmpty(Folder);

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
            // ponytail: 文件都很小（每类几十 KB），直接在 UI 线程上跑；变成几千条再挪到后台 + 回 UI 线程落地。
            await Task.Yield();
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
        Status.State = "idle";
        Status.Message = string.Empty;
        Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    private async Task SyncKindAsync(SyncFolder disk, string kind, string library)
    {
        var local = Local(kind);
        var localMap = local.ToDictionary(item => item.Id, item => item.Value, StringComparer.Ordinal);
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
        if (SyncFolderRules.ShouldBrake(outcome.Trashing, outcome.Alive))
        {
            Status.State = "confirm";
            Status.PendingDeletions = outcome.Trashing;
            Status.Message = $"同步要删掉 {outcome.Trashing} 条，等你确认";
            return;
        }

        var merged = ToSyncFile(kind, outcome.Own);
        // 落地和账本同一个事务（R13 / SyncRecords 文件头「执行层必须守住的」）：片段、生词在库里，账本也在库里。
        var transactional = kind is "clips" or "vocabulary";
        if (transactional)
        {
            _ledger.Database.BeginTransaction();
        }

        try
        {
            Apply(kind, merged);
            WriteEngineLedger(kind, library, outcome.Ledger);
            if (transactional)
            {
                _ledger.Database.Commit();
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

        var ownPath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.FileName(kind));
        var encoded = merged.Encode();
        await Task.Run(() => disk.WriteText(ownPath, encoded));
        Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Status.State = "idle";
        Status.Message = string.Empty;
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
            localMap, new Dictionary<string, long>(), old, own, others, _device.Id,
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

        if (!file.Records.All(record => CanonicalJson.IsCanonical(record.Value)))
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

    private readonly Dictionary<string, int> _counters = new(StringComparer.Ordinal);

    // ponytail: 四类都没给「真正改的时刻」（剪贴板的复制时间不是改动时间，mac 也不拿它当改于），
    // 所以 changed 交空表：改于用「这一轮发现它变了」的现在（不晚于 now，SyncEngine 里取 min）。
    // 以后设置 / 服务记了每一项真正改的时刻，再从这里传进去。
    private static readonly Dictionary<string, long> NoChanged = new(StringComparer.Ordinal);

    private List<(string Id, string Value, long Modified)> Local(string kind) => kind switch
    {
        "clips" => ClipboardService.Instance?.Store is { } store
            ? SyncSources.ClipRecords(store).ToList()
            : new(),
        "vocabulary" => SyncSources.VocabularyRecords().ToList(),
        "engines" => SyncSources.EngineRecords().ToList(),
        _ => SyncSources.ServiceRecords().ToList(),
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

    private void Apply(string kind, SyncFile merged, HashSet<string> localIds)
    {
        switch (kind)
        {
            case "clips":
                ApplyClips(merged);
                break;
            case "vocabulary":
                ApplyVocabulary(merged);
                break;
            case "engines":
                ApplyEngines(merged);
                break;
            default:
                ApplyServices(merged);
                break;
        }
    }

    private static void ApplyClips(SyncFile merged)
    {
        if (ClipboardService.Instance?.Store is not { } store)
        {
            return;
        }

        var keep = new HashSet<string>(StringComparer.Ordinal);
        foreach (var record in merged.Records)
        {
            if (record.Id == "~order")
            {
                continue;
            }

            if (record.Id.StartsWith("group:", StringComparison.Ordinal))
            {
                keep.Add(record.Id);
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(record.Value);
                var root = document.RootElement;
                var text = root.TryGetProperty("text", out var textElement) ? textElement.GetString() : null;
                if (string.IsNullOrEmpty(text))
                {
                    continue;
                }

                var existing = store.EnsureClip(record.Id, text);
                keep.Add(record.Id);
                var favorite = root.TryGetProperty("favorite", out var favoriteElement) && favoriteElement.GetBoolean();
                var snippet = root.TryGetProperty("snippet", out var snippetElement) && snippetElement.GetBoolean();
                var note = root.TryGetProperty("note", out var noteElement) ? noteElement.GetString() : null;
                var groupId = root.TryGetProperty("group", out var groupElement) && groupElement.GetString() is { } g
                    ? g.StartsWith("group:", StringComparison.Ordinal) ? g[6..] : null
                    : null;
                store.ApplySynced(existing.Id, favorite, snippet, note, groupId);
            }
            catch (JsonException)
            {
                // 解不开的这一条跳过。
            }
        }

        store.UnfavoriteMissing(keep);
    }

    private static void ApplyVocabulary(SyncFile merged)
    {
        if (TranslationHistory.Instance is not { } history)
        {
            return;
        }

        var keep = new HashSet<string>(StringComparer.Ordinal);
        foreach (var record in merged.Records)
        {
            if (record.Id == "~order")
            {
                continue;
            }

            keep.Add(record.Id);
            try
            {
                using var document = JsonDocument.Parse(record.Value);
                var root = document.RootElement;
                var source = root.TryGetProperty("source", out var sourceElement) ? sourceElement.GetString() : null;
                var target = root.TryGetProperty("target", out var targetElement) ? targetElement.GetString() : null;
                var result = root.TryGetProperty("result", out var resultElement) ? resultElement.GetString() : null;
                var service = root.TryGetProperty("service", out var serviceElement) ? serviceElement.GetString() : null;
                var created = root.TryGetProperty("created", out var createdElement) ? createdElement.GetInt64() : 0;
                if (!string.IsNullOrEmpty(source) && !string.IsNullOrEmpty(target) && !string.IsNullOrEmpty(result))
                {
                    history.UpsertSynced(record.Id, source!, target!, result!, service ?? "unknown", created);
                }
            }
            catch (JsonException)
            {
                // 跳过这一条。
            }
        }

        history.UnfavoriteMissing(keep);
    }

    private static void ApplyEngines(SyncFile merged)
    {
        var settings = SettingsService.Current;
        var current = settings.LauncherSearchEngines ?? WebSearch.Defaults();
        var order = merged.Records.FirstOrDefault(record => record.Id == "~order");
        var ids = new List<string>();
        if (order is not null)
        {
            try
            {
                using var document = JsonDocument.Parse(order.Value);
                ids.AddRange(document.RootElement.EnumerateArray().Select(item => item.GetString() ?? string.Empty));
            }
            catch (JsonException)
            {
                // 顺序解不开就按 id 排。
            }
        }

        var byId = new Dictionary<string, SearchEngine>(StringComparer.Ordinal);
        foreach (var record in merged.Records.Where(record => record.Id != "~order"))
        {
            try
            {
                using var document = JsonDocument.Parse(record.Value);
                var root = document.RootElement;
                byId[record.Id] = new SearchEngine
                {
                    Id = record.Id,
                    Name = root.TryGetProperty("name", out var name) ? name.GetString() ?? record.Id : record.Id,
                    Keyword = root.TryGetProperty("keyword", out var keyword) ? keyword.GetString() ?? string.Empty : string.Empty,
                    UrlTemplate = root.TryGetProperty("url", out var url) ? url.GetString() ?? string.Empty : string.Empty,
                    Fallback = root.TryGetProperty("fallback", out var fallback) && fallback.GetBoolean(),
                };
            }
            catch (JsonException)
            {
                return; // 有一条解不出来就整类不落。
            }
        }

        var result = ids.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
        foreach (var engine in byId.Values.Where(engine => !ids.Contains(engine.Id)))
        {
            result.Add(engine);
        }

        settings.LauncherSearchEngines = result;
        SettingsService.Save();
    }

    private static void ApplyServices(SyncFile merged)
    {
        if (TranslateServiceStore.Instance is not { } store)
        {
            return;
        }

        var byId = new Dictionary<string, TranslateServiceConfig>(StringComparer.Ordinal);
        foreach (var record in merged.Records.Where(record => record.Id != "~order"))
        {
            try
            {
                using var document = JsonDocument.Parse(record.Value);
                var root = document.RootElement;
                var kind = root.TryGetProperty("kind", out var kindElement) ? kindElement.GetString() : null;
                if (string.IsNullOrEmpty(kind))
                {
                    continue;
                }

                byId[record.Id] = new TranslateServiceConfig
                {
                    Id = record.Id,
                    Kind = kind!,
                    Name = root.TryGetProperty("name", out var name) ? name.GetString() ?? record.Id : record.Id,
                    Enabled = root.TryGetProperty("isEnabled", out var enabled) && enabled.GetBoolean(),
                    Protocol = root.TryGetProperty("aiProtocol", out var protocol) ? protocol.GetString() : "openai",
                    BaseUrl = root.TryGetProperty("baseURL", out var baseUrl) ? baseUrl.GetString() : null,
                    Model = root.TryGetProperty("model", out var model) ? model.GetString() : null,
                    Region = root.TryGetProperty("region", out var region) ? region.GetString() : null,
                    UsesDeepLX = root.TryGetProperty("usesDeepLX", out var deep) && deep.GetBoolean(),
                };
            }
            catch (JsonException)
            {
                return;
            }
        }

        // 第一次合时：别处来的自建 AI 服务如果和本机「协议 + 地址 + 模型」一样，只留文件夹里那个，
        // 本机的密钥搬过去（PLAN-v5 §4.2）。
        foreach (var incoming in byId.Values)
        {
            if (incoming.Kind != "ai")
            {
                continue;
            }

            var duplicate = store.Services.FirstOrDefault(local =>
                local.Id != incoming.Id && local.Kind == "ai" &&
                string.Equals(local.Protocol ?? "openai", incoming.Protocol ?? "openai", StringComparison.Ordinal) &&
                string.Equals(local.BaseUrl ?? string.Empty, incoming.BaseUrl ?? string.Empty, StringComparison.Ordinal) &&
                string.Equals(local.Model ?? string.Empty, incoming.Model ?? string.Empty, StringComparison.Ordinal));
            if (duplicate is null)
            {
                continue;
            }

            foreach (var field in TranslateKinds.SecretFields("ai"))
            {
                var secret = store.Secret(duplicate, field);
                if (!string.IsNullOrEmpty(secret) && string.IsNullOrEmpty(store.Secret(incoming, field)))
                {
                    store.SetSecret(incoming, secret, field);
                }
            }

            Log.Info($"sync.service-dedupe keep={incoming.Id} drop={duplicate.Id}");
        }

        // 别处删了的从列表拿掉；密钥不删（凭据管理器里的键还在）。
        var ordered = new List<TranslateServiceConfig>();
        var order = merged.Records.FirstOrDefault(record => record.Id == "~order");
        if (order is not null)
        {
            try
            {
                using var document = JsonDocument.Parse(order.Value);
                foreach (var item in document.RootElement.EnumerateArray())
                {
                    if (item.GetString() is { } id && byId.Remove(id, out var service))
                    {
                        ordered.Add(service);
                    }
                }
            }
            catch (JsonException)
            {
                // 顺序坏了就按 id 排。
            }
        }

        ordered.AddRange(byId.Values.OrderBy(service => service.Id, StringComparer.Ordinal));
        store.ReplaceServices(ordered);
    }
}
