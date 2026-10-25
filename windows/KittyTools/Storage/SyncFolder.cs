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
            // ponytail: 文件都很小（每类几十 KB），直接在 UI 线程上跑；变成几千条再挪到后台 + 回 UI 线程落地。
            await Task.Yield();
            RunRound(folder);
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

    private void RunRound(string folder)
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
                SyncKind(disk, kind, library);
            }
            catch (Exception ex)
            {
                Log.Warn($"sync.kind-failed {kind} {ex.GetType().Name}");
            }
        }

        // device.json 最后写：epoch 每轮 +1。
        var devicePath = Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.DeviceFile);
        var existing = disk.ReadText(devicePath);
        var epoch = existing is not null && SyncFolderRules.ParseDevice(existing) is { } parsed ? parsed.Epoch : 0;
        disk.WriteText(devicePath, SyncFolderRules.DeviceJson(epoch + 1, Environment.MachineName));
        Status.State = "idle";
        Status.Message = string.Empty;
        Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    private void SyncKind(SyncFolder disk, string kind, string library)
    {
        var local = Local(kind);
        var ledger = ReadLedger(kind, library);
        var entries = ledger
            .Where(pair => pair.Key != "~clock")
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);

        // 这一格的次数从上一次账本里接着数，不能从 0 开始（会把旧的改动盖回去）。
        var highest = 0;
        foreach (var value in entries.Values)
        {
            try
            {
                highest = Math.Max(highest, SyncClock.Parse(value.Split('|')[0])[_device.Id]);
            }
            catch (FormatException)
            {
                // 坏账本当没有。
            }
        }

        _counters[kind] = highest;

        // 本机改动：和账本里的哈希不一样就 +1 格。
        var records = new List<SyncRecord>();
        var localIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (id, value, modified) in local)
        {
            localIds.Add(id);
            SyncClock clock;
            var hash = CanonicalJson.Hash(value);
            if (entries.TryGetValue(id, out var previous))
            {
                clock = SyncClock.Parse(previous.Split('|')[0]);
                if (previous.Split('|')[0] != hash)
                {
                    clock[_device.Id] = ++_counters[kind];
                }
            }
            else
            {
                clock = new SyncClock();
                clock[_device.Id] = ++_counters[kind];
            }

            records.Add(new SyncRecord { Id = id, Clock = clock, Modified = modified, Value = value });
        }

        // 本机删掉的条目 → 墓碑。
        var erased = new List<SyncErased>();
        foreach (var id in entries.Keys.Where(id => !localIds.Contains(id)))
        {
            var clock = SyncClock.Parse(entries[id].Split('|')[0]);
            clock[_device.Id] = ++_counters[kind];
            erased.Add(new SyncErased { Id = id, Clock = clock });
        }

        var localFile = new SyncFile { Kind = kind, Records = records, Erased = erased };

        // 读别人的文件。
        var files = new List<SyncFile> { localFile };
        Status.Message = string.Empty;
        foreach (var id in disk.DeviceIds().Where(id => id != _device.Id))
        {
            var text = disk.ReadText(Path.Combine(SyncFolderRules.DevicesFolder, id, SyncFolderRules.FileName(kind)));
            if (text is null)
            {
                continue;
            }

            var remote = SyncFile.Decode(text, kind);
            if (remote is null)
            {
                // 只扔这一版，这一类照合。
                continue;
            }

            if (remote.IsNewer)
            {
                Status.State = "stopped";
                Status.Message = "同步文件夹是新版本写的，请更新 Kitty Tools";
                return;
            }

            // decodeExact：内容再编回去必须和原文一样，否则这一类先不落地（PLAN-v5 §2.4）。
            if (!remote.Records.All(record => CanonicalJson.IsCanonical(record.Value)))
            {
                Status.State = "stopped";
                Status.Message = "同步文件里有解不开的内容，这一类先不合";
                Log.Warn($"sync.decode-exact-failed kind={kind}");
                return;
            }

            files.Add(remote);
        }

        var merged = SyncMerge.Merge(kind, files);
        var deletions = merged.Erased.Select(item => item.Id).Count(id => localIds.Contains(id));
        if (SyncFolderRules.ShouldBrake(deletions, localIds.Count))
        {
            Status.State = "confirm";
            Status.PendingDeletions = deletions;
            Status.Message = $"同步要删掉 {deletions} 条，等你确认";
            return;
        }

        Apply(kind, merged, localIds);
        WriteLedger(kind, library, merged, local);
        disk.WriteText(
            Path.Combine(SyncFolderRules.DevicesFolder, _device.Id, SyncFolderRules.FileName(kind)),
            merged.Encode());
        Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Status.State = "idle";
        Status.Message = string.Empty;
    }

    private readonly Dictionary<string, int> _counters = new(StringComparer.Ordinal);

    private List<(string Id, string Value, long Modified)> Local(string kind) => kind switch
    {
        "clips" => ClipboardService.Instance?.Store is { } store
            ? SyncSources.ClipRecords(store).ToList()
            : new(),
        "vocabulary" => SyncSources.VocabularyRecords().ToList(),
        "engines" => SyncSources.EngineRecords().ToList(),
        _ => SyncSources.ServiceRecords().ToList(),
    };

    private Dictionary<string, string> ReadLedger(string kind, string library)
    {
        var text = _ledger.Read(kind);
        var storedLibrary = _ledger.ReadLibrary(kind);
        if (text is null || storedLibrary != library)
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            return document.RootElement.EnumerateObject()
                .Where(property => property.Value.ValueKind == JsonValueKind.String)
                .ToDictionary(property => property.Name, property => property.Value.GetString() ?? string.Empty,
                    StringComparer.Ordinal);
        }
        catch
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }
    }

    private void WriteLedger(
        string kind, string library, SyncFile merged,
        List<(string Id, string Value, long Modified)> local)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var record in merged.Records)
        {
            map[record.Id] = record.Clock.Text() + "|" + CanonicalJson.Hash(record.Value);
        }

        map["~clock"] = _counters.GetValueOrDefault(kind).ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        var builder = new System.Text.StringBuilder("{");
        var first = true;
        foreach (var (key, value) in map)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(key, builder);
            builder.Append(':');
            CanonicalJson.WriteString(value, builder);
        }

        builder.Append('}');
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
