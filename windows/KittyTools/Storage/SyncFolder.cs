// 同步在 App 这边的一半（PLAN-v5 §4.3）。REVIEW R26 起一轮怎么走在 Core 的 SyncRunner，四类的编码 / 落地规则在 Core 的
// ClipSync / VocabularySync / EngineSync / ServiceSync（都有单测）；这里只剩：
// - Syncer：20 秒一轮的定时器（开着同步才转）、睡眠唤醒和「立即同步」，一轮没完时再要的排在它后面；状态给设置页；
//   刹车的「继续」只放行不超过当时那么多条的删除（照 mac NoteSyncer.confirmTrashing）。
// - 四个薄适配（ISyncSource）：问仓库要本机的那份；把 Core 算好的规划落进库，和账本同一个事务（片段、生词在 kitty.sqlite3；
//   网页搜索、翻译服务在 settings.json，账本紧跟着写进 sync-ledger.json）。
// 每一类跟着各自的设置和功能开关：clips 跟剪贴板，vocabulary 和 services 跟翻译，engines 跟启动器（PLAN-v5 §4.3）。
// REVIEW R49：上一轮什么都没剩下之后，要读的那几个文件（SyncDisk.Fingerprint）和本机这几类（改一次 _revision 加一）都没动，
// 这一轮就不读、不合，只把「上次同步」记成现在。
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

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
    private readonly DeviceState _device;
    private readonly SyncLedger _ledger;
    private readonly DispatcherQueue _dispatcher;
    private DispatcherQueueTimer? _timer;
    private bool _busy;
    private bool _again;
    private bool _shutDown;
    private int _braked;
    private Dictionary<string, int> _pending = new(StringComparer.Ordinal);
    private Dictionary<string, int> _confirmed = new(StringComparer.Ordinal);

    /// <summary>本机要同步的数据（剪贴板库、生词本、settings.json 里的网页搜索和翻译服务）改了几次：只增不减，UI 线程上加。</summary>
    private long _revision;
    private ClipboardStore? _watchedClips;
    private TranslationHistory? _watchedHistory;

    /// <summary>上一轮什么都没剩下（合完、没等确认、没出错）时这一轮开始那一刻的样子；下一轮还是这样就跳过。</summary>
    private string? _quiet;

    private Syncer(SyncDevice device, SyncLedger ledger, DispatcherQueue dispatcher)
    {
        _device = new DeviceState(device, ledger);
        _ledger = ledger;
        _dispatcher = dispatcher;
        SettingsService.Changed += () => _revision++;
    }

    public static Syncer? Instance => _instance;

    public static Syncer Start(SyncDevice device, SyncLedger ledger, DispatcherQueue dispatcher)
    {
        _instance = new Syncer(device, ledger, dispatcher);
        Log.Info($"sync.start enabled={_instance.Enabled}");
        return _instance;
    }

    /// <summary>卸载前停掉定时器（REVIEW R25），不再往数据目录里写。</summary>
    public static void StopAll()
    {
        if (_instance is null)
        {
            return;
        }

        _instance._shutDown = true;
        _instance.StopTimer();
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

    /// <summary>合一轮（开同步、定时器、唤醒、「立即同步」都走这里）；关着时停掉定时器，开着时确保它在转。</summary>
    public async Task RoundAsync()
    {
        if (_shutDown)
        {
            return;
        }

        if (!Enabled || Folder is not { } folder)
        {
            StopTimer();
            if (Status.State != "off")
            {
                Status.State = "off";
                Status.Message = string.Empty;
                Changed?.Invoke();
            }

            return;
        }

        EnsureTimer();
        if (_busy)
        {
            _again = true;
            return;
        }

        _busy = true;
        Status.State = "syncing";
        Changed?.Invoke();
        try
        {
            do
            {
                _again = false;
                await RunOnceAsync(folder);
            }
            while (_again && Enabled && !_shutDown && Folder == folder);
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

    /// <summary>刹车之后用户点了「照样同步」：下一轮放过不超过当时那么多条的删除。</summary>
    public void ConfirmDeletions()
    {
        if (Status.State == "confirm")
        {
            _confirmed = new Dictionary<string, int>(_pending, StringComparer.Ordinal);
        }

        _ = RoundAsync();
    }

    private async Task RunOnceAsync(string folder)
    {
        WatchLocalChanges();
        var sources = Sources();
        var kinds = sources.Select(source => source.Kind).ToList();
        var revision = _revision;
        var fingerprint = await Task.Run(() => Fingerprint(folder, kinds));
        var signature = fingerprint is null ? null : $"{folder}|{revision}|{string.Join(',', kinds)}|{fingerprint}";
        if (signature is not null && signature == _quiet && _confirmed.Count == 0)
        {
            Status.State = "idle";
            Status.Message = string.Empty;
            Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            return;
        }

        var allowance = _confirmed;
        var runner = new SyncRunner(_device, sources, Environment.MachineName, message => Log.Warn(message));
        var started = Environment.TickCount64;
        var result = await runner.RunAsync(folder, allowance, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        Log.Info($"sync.round state={result.State} kinds={kinds.Count} written={result.Written.Count} ms={Environment.TickCount64 - started}");
        // 用这一轮开始前取的样子：合的这一会儿别处写了、本机改了，下一轮看到的就不一样，照样整轮跑。
        _quiet = result.State == "idle" && result.Waiting.Count == 0 ? signature : null;
        Status.State = result.State;
        Status.Message = result.Message;
        Status.Devices = result.Devices;
        Status.PendingDeletions = result.Waiting.Values.Sum();
        if (result.State != "stopped")
        {
            Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }

        if (result.Waiting.Count > 0)
        {
            _pending = new Dictionary<string, int>(result.Waiting, StringComparer.Ordinal);
            _confirmed = new Dictionary<string, int>(StringComparer.Ordinal);
            // 条数变了才再提示一次（照 mac：每 20 秒弹一次太吵）。
            if (_braked != Status.PendingDeletions)
            {
                NoticeHost.Show("同步先停下了", result.Message + "（设置 › 通用 › 同步）", NoticeTone.Warning);
            }

            _braked = Status.PendingDeletions;
            return;
        }

        _pending = new Dictionary<string, int>(StringComparer.Ordinal);
        _confirmed = new Dictionary<string, int>(StringComparer.Ordinal);
        _braked = 0;
    }

    /// <summary>本机这几类改了就让 _revision 加一（剪贴板库、生词本起得比同步晚：每轮看一眼，换了实例再挂一次）。</summary>
    private void WatchLocalChanges()
    {
        if (ClipboardService.Instance?.Store is { } clips && !ReferenceEquals(clips, _watchedClips))
        {
            _watchedClips = clips;
            clips.Changed += () => _revision++;
        }

        if (TranslationHistory.Instance is { } history && !ReferenceEquals(history, _watchedHistory))
        {
            _watchedHistory = history;
            history.Changed += () => _revision++;
        }
    }

    private static string? Fingerprint(string folder, IReadOnlyList<string> kinds)
    {
        try
        {
            return new SyncDisk(folder).Fingerprint(kinds);
        }
        catch (Exception ex)
        {
            // 读不到就当变了，照常整轮跑。
            Log.Warn($"sync.fingerprint-failed {ex.GetType().Name}");
            return null;
        }
    }

    private List<ISyncSource> Sources()
    {
        var settings = SettingsService.Current;
        var sources = new List<ISyncSource>();
        if (settings.SyncClips && Features.IsOn(Feature.Clipboard))
        {
            sources.Add(new ClipSource(_ledger));
        }

        if (settings.SyncVocabulary && Features.IsOn(Feature.Translate))
        {
            sources.Add(new VocabularySource(_ledger));
        }

        if (settings.SyncEngines && Features.IsOn(Feature.Launcher))
        {
            sources.Add(new EngineSource(_ledger));
        }

        if (settings.SyncServices && Features.IsOn(Feature.Translate))
        {
            sources.Add(new ServiceSource(_ledger));
        }

        return sources;
    }

    private void EnsureTimer()
    {
        if (_timer is not null)
        {
            return;
        }

        _timer = _dispatcher.CreateTimer();
        _timer.Interval = Interval;
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => _ = RoundAsync();
        _timer.Start();
    }

    private void StopTimer()
    {
        _timer?.Stop();
        _timer = null;
    }

    /// <summary>本机编号（sync_device 表）+ 上一次写出去的 epoch（sync_ledger 的 ~epoch，和数据同一个库）。</summary>
    private sealed class DeviceState(SyncDevice device, SyncLedger ledger) : ISyncDevice
    {
        public string Id => device.Id;

        public string? Library => device.Library;

        public void SetLibrary(string library) => device.SetLibrary(library);

        public void Rotate() => device.Rotate();

        public int Epoch => ledger.ReadEpoch();

        public void SetEpoch(int epoch) => ledger.WriteEpoch(epoch);
    }

    /// <summary>四类共用：账本读写（是别的库的 = 第一次合；写坏了抛 FormatException，这一类先不合）。</summary>
    private abstract class Source(SyncLedger ledger, string kind) : ISyncSource
    {
        public string Kind { get; } = kind;

        public abstract string? JoinKey(string value);

        public abstract IReadOnlyDictionary<string, string>? Values();

        public abstract string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData ledger, string library);

        public SyncLedgerData? Ledger(string library)
        {
            var text = ledger.Read(Kind);
            var stored = ledger.ReadLibrary(Kind);
            return text is null || (stored is not null && stored != library) ? null : SyncLedgerText.Decode(text);
        }

        protected void SaveLedger(SyncLedgerData data, string library)
            => ledger.Write(Kind, library, SyncLedgerText.Encode(data));
    }

    private sealed class ClipSource(SyncLedger ledger) : Source(ledger, ClipSync.Kind)
    {
        public override string? JoinKey(string value) => ClipSync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values()
        {
            // 面板里有还能撤销的删除：还没落库，这一轮先不合（mac syncBusy）。
            if (ClipboardService.Instance?.Store is not { } store || store.SyncBusy)
            {
                return null;
            }

            return ClipSync.Values(store.SyncRows(retainedOnly: true), store.SyncGroups());
        }

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            if (ClipboardService.Instance?.Store is not { } store)
            {
                return "剪贴板历史还没准备好";
            }

            // 按落地这一刻的样子算（合在线程池上的那一会儿用户可能又改了）。
            var plan = ClipSync.Plan(
                changes, store.SyncRows(), store.SyncGroups(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                out var failure);
            if (plan is null)
            {
                return failure;
            }

            store.ApplySyncPlan(plan, () => SaveLedger(data, library));
            return null;
        }
    }

    private sealed class VocabularySource(SyncLedger ledger) : Source(ledger, VocabularySync.Kind)
    {
        public override string? JoinKey(string value) => VocabularySync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values()
            => TranslationHistory.Instance is { } history ? VocabularySync.Values(history.SyncRows()) : null;

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            if (TranslationHistory.Instance is not { } history)
            {
                return "生词本还没准备好";
            }

            var ops = VocabularySync.Plan(changes, history.SyncRows(), out var failure);
            if (ops is null)
            {
                return failure;
            }

            history.ApplySyncOps(ops, () => SaveLedger(data, library));
            return null;
        }
    }

    private sealed class EngineSource(SyncLedger ledger) : Source(ledger, EngineSync.Kind)
    {
        private static List<SearchEngine> Current
            => SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults();

        public override string? JoinKey(string value) => EngineSync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values() => EngineSync.Values(Current);

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            var engines = EngineSync.Plan(changes, Current, out var failure);
            if (engines is null)
            {
                return failure;
            }

            // 先写设置、紧接着写账本（偏好没有事务，PLAN-v5 §4.1）。
            SettingsService.Current.LauncherSearchEngines = engines;
            SettingsService.Save();
            SaveLedger(data, library);
            return null;
        }
    }

    private sealed class ServiceSource(SyncLedger ledger) : Source(ledger, ServiceSync.Kind)
    {
        public override string? JoinKey(string value) => ServiceSync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values()
            => TranslateServiceStore.Instance is { } store
                ? ServiceSync.Values(store.Services.Select(ToSync).ToList())
                : null;

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            if (TranslateServiceStore.Instance is not { } store)
            {
                return "翻译服务还没准备好";
            }

            var plan = ServiceSync.Plan(changes, store.Services.Select(ToSync).ToList(), out var failure);
            if (plan is null)
            {
                return failure;
            }

            var services = plan.Services.Select(FromSync).ToList();
            // 第一次合时被去重掉的本机自建 AI 服务：密钥搬给留下的那个（它在本机还没有密钥时，PLAN-v5 §4.2）。
            // 别处删了的只拿出列表，凭据管理器里的密钥不删。
            foreach (var move in plan.SecretMoves)
            {
                var from = store.Find(move.From);
                var to = services.FirstOrDefault(service => service.Id == move.To);
                if (from is null || to is null)
                {
                    continue;
                }

                foreach (var field in TranslateKinds.SecretFields(from.Kind))
                {
                    if (store.Secret(from, field) is { } secret && store.Secret(to, field) is null)
                    {
                        store.SetSecret(to, secret, field);
                    }
                }

                Log.Info("sync.service-dedupe");
            }

            store.ReplaceServices(services);
            SaveLedger(data, library);
            return null;
        }

        private static SyncService ToSync(TranslateServiceConfig service)
            => new(service.Id, service.Kind, service.Name, service.Enabled, service.Model, service.BaseUrl,
                service.Protocol, service.Region, service.UsesDeepLX);

        private static TranslateServiceConfig FromSync(SyncService service) => new()
        {
            Id = service.Id,
            Kind = service.Kind,
            Name = service.Name,
            Enabled = service.Enabled,
            Model = service.Model,
            BaseUrl = service.BaseUrl,
            // 没写协议就是没有（不补 openai）：补了编回去就多一个字段，两台来回改。
            Protocol = service.Protocol,
            Region = service.Region,
            UsesDeepLX = service.UsesDeepLX,
        };
    }
}
