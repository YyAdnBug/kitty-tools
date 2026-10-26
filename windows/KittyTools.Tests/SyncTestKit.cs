// 同步测试用的内存设备和仓库（REVIEW R26）：编出去 / 落回来走 Core 的 ClipSync / VocabularySync / EngineSync / ServiceSync，
// 落规划的那几步和 App 的 ClipboardStore.ApplySyncPlan、TranslationHistory.ApplySyncOps 一一对应；账本和数据一起改
// （= 同一个事务）。整台电脑的数据目录能存成一个 JSON 文件、再读回来（模拟从备份恢复）。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Sync;

namespace KittyTools.Tests;

internal sealed class MemoryDevice : ISyncDevice
{
    public string Id { get; set; } = "WIN-A";

    public string? Library { get; set; }

    public int Epoch { get; set; }

    public int Rotations { get; set; }

    public void SetLibrary(string library) => Library = library;

    public void Rotate()
    {
        Id = "W" + Guid.NewGuid().ToString("N")[..12].ToUpperInvariant();
        Library = null;
        Rotations++;
    }

    public void SetEpoch(int epoch) => Epoch = epoch;
}

/// <summary>四类共用：账本存在仓库自己身上（和数据一起改 = 同一个事务）。</summary>
internal abstract class MemorySource : ISyncSource
{
    public string? LedgerText { get; set; }

    public string? LedgerLibrary { get; set; }

    /// <summary>仓库没起来（ClipboardService / TranslationHistory 是 null 的样子）。</summary>
    public bool Unavailable { get; set; }

    public int Applied { get; private set; }

    public abstract string Kind { get; }

    public abstract string? JoinKey(string value);

    public IReadOnlyDictionary<string, string>? Values() => Unavailable ? null : Encode();

    protected abstract Dictionary<string, string> Encode();

    public SyncLedgerData? Ledger(string library)
        => LedgerText is null || LedgerLibrary != library ? null : SyncLedgerText.Decode(LedgerText);

    public string? Apply(IReadOnlyDictionary<string, string?> changes, SyncLedgerData ledger, string library)
    {
        if (Unavailable)
        {
            return "没准备好";
        }

        var failure = Land(changes);
        if (failure is not null)
        {
            return failure;
        }

        LedgerText = SyncLedgerText.Encode(ledger);
        LedgerLibrary = library;
        Applied++;
        return null;
    }

    /// <summary>落改动；没成返回原因，什么都不改。</summary>
    protected abstract string? Land(IReadOnlyDictionary<string, string?> changes);
}

internal sealed class MemoryClipSource : MemorySource
{
    private long _nextRow = 1;

    public List<SyncClipRow> Rows { get; set; } = new();

    public List<SyncClipGroup> Groups { get; set; } = new();

    public long Now { get; set; } = 1_761_300_000_000;

    public override string Kind => ClipSync.Kind;

    public override string? JoinKey(string value) => ClipSync.JoinKey(value);

    public SyncClipRow Add(string text, bool favorite = true, bool snippet = false, string? note = null,
        string? group = null, string? uid = null)
    {
        // 读回备份之后行号接着最大的往上数。
        _nextRow = Rows.Count == 0 ? _nextRow : Math.Max(_nextRow, Rows.Max(row => row.Row) + 1);
        var row = new SyncClipRow(
            _nextRow++, uid ?? NewUid(), text, favorite, snippet, note, group, Now++);
        Rows.Insert(0, row);
        return row;
    }

    public void Replace(SyncClipRow row) => Rows[Rows.FindIndex(item => item.Row == row.Row)] = row;

    public static string NewUid() => Guid.NewGuid().ToString("D").ToUpperInvariant();

    protected override Dictionary<string, string> Encode() => ClipSync.Values(Rows, Groups);

    protected override string? Land(IReadOnlyDictionary<string, string?> changes)
    {
        var plan = ClipSync.Plan(changes, Rows, Groups, Now++, out var failure);
        if (plan is null)
        {
            return failure;
        }

        Execute(plan);
        return null;
    }

    /// <summary>和 ClipboardStore.ApplySyncPlan 一样的几步。</summary>
    public void Execute(ClipSyncPlan plan)
    {
        Groups = plan.Groups.ToList();
        Rows.RemoveAll(row => plan.Deletes.Contains(row.Row));
        foreach (var write in plan.Writes)
        {
            var index = write.Row is { } existing ? Rows.FindIndex(row => row.Row == existing) : -1;
            var uid = write.Uid ?? (index >= 0 ? Rows[index].Uid : null);
            var row = new SyncClipRow(
                write.Row ?? _nextRow++, uid, write.Text, write.Favorite, write.Snippet, write.Note, write.Group,
                write.CopiedAt);
            if (index >= 0)
            {
                Rows[index] = row;
            }
            else
            {
                Rows.Add(row);
            }
        }

        Rows = Rows.OrderByDescending(row => row.CopiedAt).ThenByDescending(row => row.Row).ToList();
        _nextRow = Rows.Count == 0 ? _nextRow : Math.Max(_nextRow, Rows.Max(row => row.Row) + 1);
    }
}

internal sealed class MemoryWordSource : MemorySource
{
    public List<SyncWordRow> Rows { get; set; } = new();

    public override string Kind => VocabularySync.Kind;

    public override string? JoinKey(string value) => VocabularySync.JoinKey(value);

    public SyncWordRow Add(string source, string target, string result, bool favorite = true, string? id = null)
    {
        var row = new SyncWordRow(
            id ?? MemoryClipSource.NewUid(), source, target, result, "zhipu", 1_761_300_000_000 + Rows.Count, favorite);
        Rows.RemoveAll(item => item.Source == source && item.Target == target);
        Rows.Add(row);
        return row;
    }

    protected override Dictionary<string, string> Encode() => VocabularySync.Values(Rows);

    protected override string? Land(IReadOnlyDictionary<string, string?> changes)
    {
        var ops = VocabularySync.Plan(changes, Rows.Where(row => row.Favorite).ToList(), out var failure);
        if (ops is null)
        {
            return failure;
        }

        // 和 TranslationHistory.ApplySyncOps 一样的几步。
        foreach (var op in ops)
        {
            switch (op.Step)
            {
                case SyncWordStep.Unfavorite:
                    Rows = Rows.Select(row => row.Id == op.Id ? row with { Favorite = false } : row).ToList();
                    break;
                case SyncWordStep.Delete:
                    Rows.RemoveAll(row => row.Id == op.Id);
                    break;
                case SyncWordStep.Replace when op.Word is { } word:
                    Rows.RemoveAll(row => row.Source == word.Source && row.Target == word.Target && row.Id != op.Id);
                    Rows.RemoveAll(row => row.Id == op.Id);
                    Rows.Add(word);
                    break;
            }
        }

        return null;
    }
}

internal sealed class MemoryEngineSource : MemorySource
{
    public List<SearchEngine> Engines { get; set; } = WebSearch.Defaults();

    public override string Kind => EngineSync.Kind;

    public override string? JoinKey(string value) => EngineSync.JoinKey(value);

    protected override Dictionary<string, string> Encode() => EngineSync.Values(Engines);

    protected override string? Land(IReadOnlyDictionary<string, string?> changes)
    {
        var engines = EngineSync.Plan(changes, Engines, out var failure);
        if (engines is null)
        {
            return failure;
        }

        Engines = engines;
        return null;
    }
}

internal sealed class MemoryServiceSource : MemorySource
{
    public List<SyncService> Services { get; set; } = new();

    public List<SyncSecretMove> Moves { get; } = new();

    public override string Kind => ServiceSync.Kind;

    public override string? JoinKey(string value) => ServiceSync.JoinKey(value);

    protected override Dictionary<string, string> Encode() => ServiceSync.Values(Services);

    protected override string? Land(IReadOnlyDictionary<string, string?> changes)
    {
        var plan = ServiceSync.Plan(changes, Services, out var failure);
        if (plan is null)
        {
            return failure;
        }

        Services = plan.Services;
        Moves.AddRange(plan.SecretMoves);
        return null;
    }
}

/// <summary>假 Mac：只认内容本身（编号 → JSON），落什么存什么——一台照规矩写文件、什么都不改写的电脑。</summary>
internal sealed class MemoryValueSource(string kind, Func<string, string?> joinKey) : MemorySource
{
    public Dictionary<string, string> Map { get; set; } = new(StringComparer.Ordinal);

    public override string Kind => kind;

    public override string? JoinKey(string value) => joinKey(value);

    protected override Dictionary<string, string> Encode() => new(Map, StringComparer.Ordinal);

    protected override string? Land(IReadOnlyDictionary<string, string?> changes)
    {
        foreach (var (id, value) in changes)
        {
            if (value is null)
            {
                Map.Remove(id);
            }
            else
            {
                Map[id] = value;
            }
        }

        return null;
    }
}

/// <summary>一台电脑：设备 + 几类仓库，能把数据目录存成一个文件、再读回来。</summary>
internal sealed class SyncNode
{
    public SyncNode(string name, string data, params MemorySource[] sources)
    {
        Name = name;
        Data = data;
        Sources = sources.ToList();
        Device.Id = name;
    }

    public string Name { get; }

    public string Data { get; }

    public MemoryDevice Device { get; } = new();

    public List<MemorySource> Sources { get; }

    public T Source<T>()
        where T : MemorySource
        => Sources.OfType<T>().Single();

    /// <summary>跑一轮；刹车了就照用户点了「继续」再跑一轮（随机测试里不想卡在刹车上）。</summary>
    public SyncRoundResult Round(string folder, ref long now, bool confirmBrakes = true)
    {
        now += 1000;
        var result = new SyncRunner(Device, Sources, Name).RunAsync(
            folder, new Dictionary<string, int>(), now).GetAwaiter().GetResult();
        if (confirmBrakes && result.State == "confirm")
        {
            now += 1000;
            result = new SyncRunner(Device, Sources, Name).RunAsync(folder, result.Waiting, now)
                .GetAwaiter().GetResult();
        }

        return result;
    }

    private sealed record Saved(
        string Id, string? Library, int Epoch, List<string?> Ledgers, List<string?> Libraries,
        List<SyncClipRow>? Clips, List<SyncClipGroup>? Groups, List<SyncWordRow>? Words,
        Dictionary<string, string>[] Maps);

    public string Save()
    {
        var saved = new Saved(
            Device.Id, Device.Library, Device.Epoch,
            Sources.Select(source => source.LedgerText).ToList(),
            Sources.Select(source => source.LedgerLibrary).ToList(),
            Sources.OfType<MemoryClipSource>().FirstOrDefault()?.Rows,
            Sources.OfType<MemoryClipSource>().FirstOrDefault()?.Groups,
            Sources.OfType<MemoryWordSource>().FirstOrDefault()?.Rows,
            Sources.OfType<MemoryValueSource>().Select(source => source.Map).ToArray());
        Directory.CreateDirectory(Data);
        var path = Path.Combine(Data, Name + "-" + Guid.NewGuid().ToString("N")[..6] + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(saved));
        return path;
    }

    public void Load(string path)
    {
        var saved = JsonSerializer.Deserialize<Saved>(File.ReadAllText(path))!;
        Device.Id = saved.Id;
        Device.Library = saved.Library;
        Device.Epoch = saved.Epoch;
        for (var index = 0; index < Sources.Count; index++)
        {
            Sources[index].LedgerText = saved.Ledgers[index];
            Sources[index].LedgerLibrary = saved.Libraries[index];
        }

        if (Sources.OfType<MemoryClipSource>().FirstOrDefault() is { } clips)
        {
            clips.Rows = saved.Clips!;
            clips.Groups = saved.Groups!;
        }

        if (Sources.OfType<MemoryWordSource>().FirstOrDefault() is { } words)
        {
            words.Rows = saved.Words!;
        }

        var maps = Sources.OfType<MemoryValueSource>().ToList();
        for (var index = 0; index < maps.Count; index++)
        {
            maps[index].Map = new Dictionary<string, string>(saved.Maps[index], StringComparer.Ordinal);
        }
    }
}

internal sealed class TempFolder : IDisposable
{
    public TempFolder()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-sync-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string Sub(string name)
    {
        var path = System.IO.Path.Combine(Path, name);
        Directory.CreateDirectory(path);
        return path;
    }

    public void Dispose()
    {
        if (Environment.GetEnvironmentVariable("KITTY_IT_KEEP") == "1")
        {
            return;
        }

        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch
        {
            // 临时目录留给系统清理。
        }
    }
}
