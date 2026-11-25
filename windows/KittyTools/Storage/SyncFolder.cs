// 同步在 App 这边的一半（PLAN-v5 §4.3）。REVIEW R26 起一轮怎么走在 Core 的 SyncRunner，四类的编码 / 落地规则在 Core 的
// ClipSync / VocabularySync / EngineSync / ServiceSync（都有单测）；这里只剩：
// - Syncer：20 秒一轮的定时器（开着同步才转）、睡眠唤醒和「立即同步」，一轮没完时再要的排在它后面；状态给设置页；
//   刹车的「继续」只放行不超过当时那么多条的删除（照 mac NoteSyncer.confirmTrashing）。
// - 四个薄适配（ISyncSource）：问仓库要本机的那份；把 Core 算好的规划落进库，和账本同一个事务（片段、生词在 kitty.sqlite3；
//   网页搜索、翻译服务在 settings.json，账本紧跟着写进 sync-ledger.json）。
// 每一类跟着各自的设置和功能开关：clips 跟剪贴板，vocabulary 和 services 跟翻译，engines 跟启动器（PLAN-v5 §4.3）。
// REVIEW R49：上一轮什么都没剩下之后，要读的那几个文件（SyncDisk.Fingerprint）和本机这几类（改一次 _revision 加一）都没动，
// 这一轮就不读、不合，只把「上次同步」记成现在。
// **连 WebDAV 服务器**（PLAN-v19，issue #18）：同步的「文件夹」是数据目录里的一份镜像（sync-server/<编号>/，SyncFolder 指着它），
// 服务器网址、用户名在设置里（SyncServer / SyncServerUser），密码在凭据管理器（PasswordName）。一轮交给 Core 的 SyncServer.RoundAsync：
// pull → 照上面那样合（MergeAsync，指纹没变照样跳过）→ push。一分钟一轮（ServerInterval：按次数限流的服务器，空闲一轮也要列
// 3 + 2 × 电脑数次目录）。服务器说请求太多就退避（5、10、20、30 分钟，服务器说了等多久至少等它说的），这期间的一轮直接停在 busy；
// 连不上照常停在那一轮、下一轮再试。**服务器不认密码（401）、不让读写（403）就不再自动重试**（PLAN-v26 I4，照 mac 0.10.1
// f722e397：每一轮都是一两次登录失败，NAS 数够了会封这台电脑的 IP）：定时、唤醒这些自动的轮不发请求、停在原来那句，设置里
// 「立即同步」、「更新密码…」（用户主动的一轮）照发；「更新密码…」只换凭据管理器里的密码，镜像和它的账留着。
// ponytail: 拒过的记号只在内存里（_rejected），每次重新打开 App 会再试一次（一次失败的登录）——要更省就存进设置、换密码时清。
// 停了要让人知道（SyncAttention）：要你处理的马上底部轻提示带「打开同步设置」，别的停满 30 分钟（不含睡眠）才说；主界面「设置」
// 挂小橙点。日志里不记地址、用户名。
using KittyTools.Core;
using KittyTools.Core.Notes;
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

    /// <summary>连服务器时：服务器上变了、还没拿下来的 / 还没传上去的文件有几个（PLAN-v19）。</summary>
    public int Downloading { get; set; }

    public int Uploading { get; set; }

    public List<string> Devices { get; set; } = new();

    /// <summary>服务器拒了这组用户名密码（401 / 403）、凭据管理器里没有密码：同步那一行给「更新密码…」。</summary>
    public bool NeedsPassword { get; set; }

    /// <summary>停了、该让人知道了：主界面底栏「设置」挂小橙点（SyncAttention）。</summary>
    public bool NeedsAttention { get; set; }
}

internal sealed partial class Syncer
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(20);

    /// <summary>连服务器时一分钟一轮（文件头）。</summary>
    private static readonly TimeSpan ServerInterval = TimeSpan.FromSeconds(60);

    /// <summary>服务器的密码在凭据管理器里的名字（Credentials.Target 前面再拼 KittyTools/ 或 KittyTools.Dev/）。</summary>
    public const string PasswordName = "sync-server.password";
    private static Syncer? _instance;
    private readonly DeviceState _device;
    private readonly SyncLedger _ledger;
    private readonly DispatcherQueue _dispatcher;
    private DispatcherQueueTimer? _timer;
    private bool _busy;
    private bool _again;

    /// <summary>排在后面的那一轮里有用户主动要的（拒过密码之后只有它发请求）。</summary>
    private bool _againManual;

    /// <summary>服务器拒了这组用户名密码（401 / 403）：自动的轮不再发请求，等「立即同步」「更新密码…」；连上了、换了服务器清掉。</summary>
    private bool _rejected;

    /// <summary>这一轮停下来的是哪一种要你处理的（SyncAttention 的常量；多半自己会好的是 null）。</summary>
    private string? _problem;
    private readonly SyncAttention _attention = new();
    private bool _shutDown;
    private int _braked;
    private Dictionary<string, int> _pending = new(StringComparer.Ordinal);
    private Dictionary<string, int> _confirmed = new(StringComparer.Ordinal);

    /// <summary>本机要同步的数据（剪贴板库、生词本、settings.json 里的网页搜索和翻译服务）改了几次：只增不减，UI 线程上加。</summary>
    private long _revision;
    private ClipboardStore? _watchedClips;
    private TranslationHistory? _watchedHistory;
    private NoteStore? _watchedNotes;
    private LauncherFavorites? _watchedFavorites;

    /// <summary>上一轮什么都没剩下（合完、没等确认、没出错）时这一轮开始那一刻的样子；下一轮还是这样就跳过。</summary>
    private string? _quiet;

    /// <summary>连服务器用的：共用的 client + Digest 的退路（WebDavTransport）。</summary>
    private readonly WebDavTransport _transport = WebDavTransport.CreateDefault();

    /// <summary>服务器的密码：第一次用时从凭据管理器取，之后记在内存里。</summary>
    private string? _password;

    /// <summary>服务器说请求太多：这个时刻之前不合；连着第几回了（退避加倍）。</summary>
    private DateTimeOffset? _pausedUntil;
    private int _backoffs;

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

    /// <summary>连着 WebDAV 服务器（不是同步文件夹）。</summary>
    public static bool IsServer => !string.IsNullOrEmpty(SettingsService.Current.SyncServer);

    /// <summary>镜像都放在这下面（每连一次服务器一个子文件夹，账在它旁边的 .json）。</summary>
    private static string MirrorsRoot => Path.Combine(Paths.DataDirectory, "sync-server");

    /// <summary>对这个账号发请求的那个（设置里「测试连接」「连接」也用它）。</summary>
    public WebDav Dav(WebDavAccount account) => new(account, _transport);

    /// <summary>
    /// 连这个服务器上的文件夹同步（照 mac NoteSyncer.enable(server:)；有别的电脑在用要不要合在一起，由设置页先问）：服务器那边
    /// 交给 SyncServer.ConnectAsync（没有就建、拿不来同步的说为什么、没有标记的写一个），再建新的镜像目录、存密码和设置，旧镜像在后台删掉。
    /// 返回没开成的原因。
    /// </summary>
    public async Task<string?> EnableServerAsync(WebDavAccount account, Func<bool>? cancelled = null)
    {
        var dav = Dav(account);
        var device = _device.Id;
        if (await Task.Run(() => SyncServer.ConnectAsync(dav, device)) is { } problem)
        {
            return problem;
        }

        // 表单收起了（「取消」、Esc）：什么都不记（这之后没有 await，过了这里就是开成了）
        if (cancelled?.Invoke() == true)
        {
            return "已取消";
        }

        var mirror = Path.Combine(MirrorsRoot, Guid.NewGuid().ToString("D").ToUpperInvariant());
        try
        {
            Directory.CreateDirectory(mirror);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Warn($"sync.server-mirror-failed {ex.GetType().Name}");
            return "数据目录写不进去";
        }

        if (!Credentials.Set(Credentials.Target(PasswordName), account.Password))
        {
            return "密码存不进凭据管理器";
        }

        _password = account.Password;
        var settings = SettingsService.Current;
        settings.SyncServer = account.Folder.AbsoluteUri;
        settings.SyncServerUser = account.User;
        settings.SyncFolder = mirror;
        settings.SyncEnabled = true;
        settings.SyncSettings ??= true;
        settings.SyncLauncher ??= true;
        SettingsService.Save();
        _pausedUntil = null;
        _backoffs = 0;
        _quiet = null;
        _rejected = false;
        Status.NeedsPassword = false;
        Status.Downloading = 0;
        Status.Uploading = 0;
        Log.Info("sync.server-connected");
        _ = Task.Run(() => SyncServer.RemoveMirrors(MirrorsRoot, mirror));
        return null;
    }

    /// <summary>不再连服务器（「停止同步」时调，之后调用方关掉同步、存设置）：设置里的地址、用户名和镜像路径清掉，凭据管理器里的
    /// 密码删掉，镜像在后台删掉；服务器上的东西都留着。没连过服务器时什么都不做。</summary>
    public void ForgetServer()
    {
        var settings = SettingsService.Current;
        if (string.IsNullOrEmpty(settings.SyncServer) && string.IsNullOrEmpty(settings.SyncServerUser))
        {
            return;
        }

        settings.SyncServer = null;
        settings.SyncServerUser = null;
        settings.SyncFolder = null;
        _password = null;
        _pausedUntil = null;
        _backoffs = 0;
        _quiet = null;
        _rejected = false;
        Status.NeedsPassword = false;
        Recovered();
        Status.Downloading = 0;
        Status.Uploading = 0;
        Credentials.Delete(Credentials.Target(PasswordName));
        _ = Task.Run(() => SyncServer.RemoveMirrors(MirrorsRoot, null));
        Log.Info("sync.server-forgotten");
    }

    /// <summary>这一类勾上会是它第一次和文件夹里的合（账本里还没有它）：设置页先问「合在一起？」（同 mac NoteSyncer.joins）。</summary>
    public bool Joins(string kind) => Enabled && _ledger.Read(kind) is null;

    /// <summary>
    /// 「更新密码…」：只换凭据管理器里的密码，镜像和它的账都留着（不用整份重新下载）；换完马上接着同步（用户主动的一轮）。
    /// 返回没换成的原因。
    /// </summary>
    public string? UpdatePassword(string password)
    {
        if (!IsServer)
        {
            return null;
        }

        if (!Credentials.Set(Credentials.Target(PasswordName), password))
        {
            return "密码存不进凭据管理器";
        }

        _password = password;
        _rejected = false;
        Status.NeedsPassword = false;
        Log.Info("sync.server-password-updated");
        _ = RoundAsync(manual: true);
        return null;
    }

    /// <summary>
    /// 合一轮（开同步、定时器、唤醒、「立即同步」都走这里）；关着时停掉定时器，开着时确保它在转。
    /// manual：用户主动要的（设置里「立即同步」、更新了密码）——服务器拒过这组密码之后只有这种还发请求。
    /// </summary>
    public async Task RoundAsync(bool manual = false)
    {
        if (_shutDown)
        {
            return;
        }

        if (!Enabled || Folder is not { } folder)
        {
            StopTimer();
            _againManual = false;
            if (Status.State != "off")
            {
                Status.State = "off";
                Status.Message = string.Empty;
                Recovered();
                Changed?.Invoke();
            }

            return;
        }

        EnsureTimer();
        if (_busy)
        {
            _again = true;
            _againManual |= manual;
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
                _problem = null;
                await RunOnceAsync(folder, manual);
                manual = _againManual;
                _againManual = false;
                Attend();
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

    /// <summary>设过「始终保留在此设备上」的同步文件夹（R77）。</summary>
    private string? _pinnedFolder;

    /// <summary>这一轮走完：停着的照 SyncAttention 说一声、挂橙点；好好走完、等确认的这一段停着就算完了。</summary>
    private void Attend()
    {
        if (!Enabled)
        {
            return;
        }

        if (Status.State is "stopped" or "busy")
        {
            var problem = _problem ?? SyncAttention.Classify(Status.Message);
            if (_attention.Stopped(problem, Uptime()))
            {
                NoticeHost.Show("同步停了", SyncAttention.Notice(problem, Status.Message), NoticeTone.Warning,
                    NoticeActions.AppSettings("general", "打开同步设置"));
            }
        }
        else
        {
            _attention.Recovered();
        }

        Status.NeedsAttention = _attention.NeedsAttention;
    }

    private void Recovered()
    {
        _attention.Recovered();
        Status.NeedsAttention = false;
    }

    /// <summary>不含睡眠的时钟（合盖的那段不算「一直停着」）。</summary>
    private static TimeSpan Uptime()
    {
        QueryUnbiasedInterruptTime(out var ticks);
        return TimeSpan.FromTicks((long)ticks);
    }

    [System.Runtime.InteropServices.LibraryImport("kernel32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool QueryUnbiasedInterruptTime(out ulong unbiasedTime);

    private async Task RunOnceAsync(string folder, bool manual)
    {
        if (!IsServer)
        {
            // 同步文件夹在云盘里：设上「始终保留在此设备上」（REVIEW R77），别的电脑写的才不会一直只在线。同一个文件夹只设一次
            if (_pinnedFolder != folder)
            {
                _pinnedFolder = folder;
                var pinned = await Task.Run(() => SyncDisk.KeepLocal(folder));
                Log.Info($"sync.keep-local pinned={pinned}");
            }

            await MergeAsync(folder);
            return;
        }

        if (Account() is not { } account)
        {
            _problem = SyncAttention.NoPassword;
            Status.NeedsPassword = true;
            Halt("stopped", "凭据管理器里没有服务器的密码，点「更新密码…」重新填");
            return;
        }

        // 服务器拒过这组用户名密码：自动的轮不再带着它去试（每一次都是一次登录失败），停在原来那句
        if (_rejected && !manual)
        {
            _problem = Status.NeedsPassword ? SyncAttention.Unauthorized : SyncAttention.Forbidden;
            Status.State = "stopped";
            return;
        }

        if (_pausedUntil is { } until && DateTimeOffset.Now < until)
        {
            Halt("busy", BusyMessage(until));
            return;
        }

        var settings = SettingsService.Current;
        var server = settings.SyncServer;
        var images = settings.SyncNotes && Features.IsOn(Feature.Notes) ? NoteStore.Instance?.Images?.Directory : null;
        var round = await SyncServer.RoundAsync(
            Dav(account), folder, _device, images,
            incomplete => MergeAsync(folder, incomplete),
            () => Enabled && Folder == folder && SettingsService.Current.SyncServer == server);
        Status.Downloading = round.Downloading;
        Status.Uploading = round.Uploading;
        if (round.Unsettled)
        {
            // 还有没拿下来 / 没传上去的：下一轮不能当成没变跳过
            _quiet = null;
        }

        Log.Info($"sync.server-round down={round.Downloading} up={round.Uploading} failure={round.Failure?.Error.ToString() ?? "-"}");
        if (round.Failure is { } failure)
        {
            Fail(failure);
            return;
        }

        _pausedUntil = null;
        _backoffs = 0;
        _rejected = false;
        Status.NeedsPassword = false;
        if (round.Missing)
        {
            Halt("stopped", "服务器上找不到同步的那个文件夹：被挪走或删了，找到了自己接着同步");
        }
        else if (round.MarkerGone)
        {
            _problem = SyncAttention.NotTheFolder;
            Halt("stopped", "服务器上那个文件夹里的同步记录被换掉或删了：先停止同步，再连一个新的空文件夹（每台电脑都换过去）");
        }
    }

    /// <summary>连服务器的账号（密码第一次用时从凭据管理器取）：取不到是 null。</summary>
    private WebDavAccount? Account()
    {
        var settings = SettingsService.Current;
        if (settings.SyncServer is not { } server || settings.SyncServerUser is not { } user ||
            !Uri.TryCreate(server, UriKind.Absolute, out var folder))
        {
            return null;
        }

        _password ??= Credentials.Get(Credentials.Target(PasswordName));
        return _password is null ? null : new WebDavAccount(folder, user, _password);
    }

    /// <summary>连服务器这一轮没成：请求太多就退避；不认密码、不让读写就不再自动重试；别的停在这一轮、下一轮再试。</summary>
    private void Fail(WebDavFailure failure)
    {
        if (failure.Error is WebDavError.Unauthorized or WebDavError.Forbidden)
        {
            _rejected = true;
            var unauthorized = failure.Error == WebDavError.Unauthorized;
            Status.NeedsPassword = unauthorized;
            _problem = unauthorized ? SyncAttention.Unauthorized : SyncAttention.Forbidden;
            Halt("stopped", failure.Message + "；先不再自动重试，" + (unauthorized ? "点「更新密码…」或「立即同步」" : "改好权限后点「立即同步」"));
            Log.Info($"sync.server-rejected status={(unauthorized ? 401 : 403)}");
            return;
        }

        if (failure.Error != WebDavError.Busy)
        {
            Halt("stopped", failure.Message);
            return;
        }

        var until = DateTimeOffset.Now + SyncServer.Backoff(failure.RetryAfter, _backoffs++);
        _pausedUntil = until;
        Halt("busy", BusyMessage(until));
    }

    internal static string BusyMessage(DateTimeOffset until) => $"服务器说请求太多，{until.ToLocalTime():HH:mm} 后接着同步";

    private void Halt(string state, string message)
    {
        Status.State = state;
        Status.Message = message;
    }

    /// <summary>照文件夹合一轮（连服务器时文件夹是镜像，incomplete = 这一轮有没从服务器拿下来的）。指纹没变跳过时返回 null。</summary>
    private async Task<SyncRoundResult?> MergeAsync(string folder, bool incomplete = false)
    {
        WatchLocalChanges();
        var sources = Sources();
        var kinds = sources.Select(source => source.Kind).ToList();
        var revision = _revision;
        var notes = NotesPart();
        var fingerprint = await Task.Run(() => Fingerprint(folder, kinds, notes is not null));
        var signature = fingerprint is null ? null : $"{folder}|{revision}|{string.Join(',', kinds)}|{notes is not null}|{fingerprint}";
        if (signature is not null && signature == _quiet && _confirmed.Count == 0)
        {
            Status.State = "idle";
            Status.Message = string.Empty;
            Status.LastSync = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            return null;
        }

        var allowance = _confirmed;
        var runner = new SyncRunner(_device, sources, Environment.MachineName, message => Log.Warn(message), notes);
        var started = Environment.TickCount64;
        var result = await runner.RunAsync(folder, allowance, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), incomplete);
        Log.Info($"sync.round state={result.State} kinds={kinds.Count} written={result.Written.Count} ms={Environment.TickCount64 - started}");
        // 用这一轮开始前取的样子：合的这一会儿别处写了、本机改了，下一轮看到的就不一样，照样整轮跑。
        _quiet = result.State == "idle" && result.Waiting.Count == 0 && !result.Unsettled ? signature : null;
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
            return result;
        }

        _pending = new Dictionary<string, int>(StringComparer.Ordinal);
        _confirmed = new Dictionary<string, int>(StringComparer.Ordinal);
        _braked = 0;
        return result;
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

        if (NoteStore.Instance is { } notes && !ReferenceEquals(notes, _watchedNotes))
        {
            _watchedNotes = notes;
            notes.Changed += () => _revision++;
        }

        if (LauncherFavorites.Instance is { } favorites && !ReferenceEquals(favorites, _watchedFavorites))
        {
            _watchedFavorites = favorites;
            favorites.Changed += () => _revision++;
        }
    }

    private static string? Fingerprint(string folder, IReadOnlyList<string> kinds, bool notes)
    {
        try
        {
            return new SyncDisk(folder).Fingerprint(kinds, notes);
        }
        catch (Exception ex)
        {
            // 读不到就当变了，照常整轮跑。
            Log.Warn($"sync.fingerprint-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>便签那部分（PLAN-v13 第 3 批）：勾着「便签」、便签功能开着、便签库开着才有。</summary>
    private static NoteSyncPart? NotesPart()
    {
        if (!SettingsService.Current.SyncNotes || !Features.IsOn(Feature.Notes) || NoteStore.Instance is not { } store)
        {
            return null;
        }

        return new NoteSyncPart
        {
            Flush = store.Flush,
            Notes = () => store.Book.All.ToList(),
            Erased = () => new Dictionary<string, NoteSync.Tombstone>(store.Book.Erased, StringComparer.Ordinal),
            Editing = NoteEditing.Ids,
            SwitchDevice = store.SwitchDevice,
            Apply = store.ApplySync,
            Published = ids => store.Book.Published(ids),
            ImagesArrived = NoteEditing.ImagesArrived,
            ImagesDirectory = store.Images?.Directory,
            ReadLedger = () => store.Meta(NoteSyncFolder.ImageLedgerKey),
            WriteLedger = text => store.SetMeta(NoteSyncFolder.ImageLedgerKey, text),
        };
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

        if (settings.SyncStatuses && Features.IsOn(Feature.StatusScreen))
        {
            sources.Add(new StatusSource(_ledger));
        }

        if (settings.SyncReminders && Features.IsOn(Feature.Reminders))
        {
            sources.Add(new ReminderSource(_ledger));
        }

        // 启动器收藏（PLAN-v21 第 3 批，只在 Windows 之间）
        if (settings.SyncLauncher == true && Features.IsOn(Feature.Launcher))
        {
            sources.Add(new FavoriteSource(_ledger));
        }

        // 设置与快捷键（PLAN-v21）：两类一行开关；settings 一类等文件夹里有了别的电脑的那份才写（D3）
        if (settings.SyncSettings == true && SettingsSyncState.Settings is { } shared && SettingsSyncState.Windows is { } windows)
        {
            sources.Add(SettingsSource(shared));
            sources.Add(SettingsSource(windows));
        }

        return sources;
    }

    private SettingsSyncSource SettingsSource(SettingsSyncBook book)
        => new(book,
            library =>
            {
                var text = _ledger.Read(book.Kind);
                var stored = _ledger.ReadLibrary(book.Kind);
                return text is null || (stored is not null && stored != library) ? null : SyncLedgerText.Decode(text);
            },
            (data, library) => _ledger.Write(book.Kind, library, SyncLedgerText.Encode(data)),
            () => _ledger.Read(SettingsSync.Kind) is not null);

    private void EnsureTimer()
    {
        var interval = IsServer ? ServerInterval : Interval;
        if (_timer is not null)
        {
            if (_timer.Interval != interval)
            {
                // 换了同步方式（文件夹 ↔ 服务器）
                _timer.Stop();
                _timer.Interval = interval;
                _timer.Start();
            }

            return;
        }

        _timer = _dispatcher.CreateTimer();
        _timer.Interval = interval;
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

        public string? NotesSwitchFrom => ledger.ReadNotesSwitch();

        public void SetNotesSwitchFrom(string? oldId) => ledger.WriteNotesSwitch(oldId);
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
            // 新来的排在本机最旧那条之前（第四轮体检 E10）。
            var plan = ClipSync.Plan(
                changes, store.SyncRows(), store.SyncGroups(),
                store.OldestCopiedAt ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
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

    /// <summary>启动器收藏（PLAN-v21 第 3 批）：一张表按顺序重写，账本在同一个库、同一个事务里。</summary>
    private sealed class FavoriteSource(SyncLedger ledger) : Source(ledger, LauncherFavoriteSync.Kind)
    {
        public override string? JoinKey(string value) => null;

        public override IReadOnlyDictionary<string, string>? Values()
            => LauncherFavorites.Instance is { } favorites ? LauncherFavoriteSync.Values(favorites.SyncRows()) : null;

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            if (LauncherFavorites.Instance is not { } favorites)
            {
                return "启动器收藏还没准备好";
            }

            var list = LauncherFavoriteSync.Plan(changes, favorites.SyncRows(), out var failure);
            if (list is null)
            {
                return failure;
            }

            favorites.ApplySync(list, () => SaveLedger(data, library));
            return null;
        }
    }

    /// <summary>状态屏的状态列表（PLAN-v12 第 7 批，照 mac StatusPresetSync）：落下去之后托盘、启动器、设置页下次打开时跟上。</summary>
    private sealed class StatusSource(SyncLedger ledger) : Source(ledger, StatusPresetSync.Kind)
    {
        public override string? JoinKey(string value) => StatusPresetSync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values() => StatusPresetSync.Values(SettingsService.Current.StatusScreenPresets);

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            var presets = StatusPresetSync.Plan(changes, SettingsService.Current.StatusScreenPresets, out var failure);
            if (presets is null)
            {
                return failure;
            }

            SettingsService.Current.StatusScreenPresets = presets;
            SettingsService.Save();
            SaveLedger(data, library);
            return null;
        }
    }

    /// <summary>提醒列表（PLAN-v12 N6，照 mac ReminderSync）：只同步列表；处理到哪一刻、暂停这些是这台电脑自己的。
    /// 落下去之后 ReminderCenter 看着设置变化自己跟上（同设置页改了一条）。</summary>
    private sealed class ReminderSource(SyncLedger ledger) : Source(ledger, ReminderSync.Kind)
    {
        public override string? JoinKey(string value) => ReminderSync.JoinKey(value);

        public override IReadOnlyDictionary<string, string>? Values() => ReminderSync.Values(SettingsService.Current.Reminders);

        public override string? Apply(
            IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
        {
            var reminders = ReminderSync.Plan(changes, SettingsService.Current.Reminders, out var failure);
            if (reminders is null)
            {
                return failure;
            }

            SettingsService.Current.Reminders = reminders;
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
                service.Protocol, service.Region, service.UsesDeepLX, service.ExplainsSentences, service.ExtraPrompt);

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
            ExplainsSentences = service.ExplainsSentences,
            ExtraPrompt = service.ExtraPrompt,
        };
    }
}
