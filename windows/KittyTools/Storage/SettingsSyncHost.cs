// 设置同步在 App 里的那一半（PLAN-v21 第 2 批）：两本账（settings 和 mac 互认、windows-settings 只在 Windows 之间）跟 App 一样长，
// 设置一存（SettingsService.Changed）就在 UI 线程空下来时比一遍、记改的时刻（mac SettingsSync.noteChanges / recordChanges）；
// 每轮同步由 SyncFolder.Sources 用它们新建两个 SettingsSyncSource。读写设置走 SettingsSyncFields，
// 存过的键、透传、改的时刻都跟着 settings.json 一起存（D6）。落了同步来的设置之后照常 Save：ShellRuntime 看着 Changed
// 自己跟上（热键重注册、外观和强调色、功能起停、停用名单、自动检查更新，同导入）；两个快捷键撞了同一个组合时轻提示说一声。
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static class SettingsSyncState
{
    private static Host? _host;
    private static DispatcherQueue? _dispatcher;
    private static bool _queued;

    public static SettingsSyncBook? Settings { get; private set; }

    public static SettingsSyncBook? Windows { get; private set; }

    public static void Start(SyncLedger ledger, DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _host = new Host(ledger);
        var firstCount = SettingsService.Current.SyncStoredKeys is null;
        Settings = new SettingsSyncBook(SettingsSync.Kind, SettingsSyncMap.Shared, SettingsSyncMap.FindShared, _host);
        Windows = new SettingsSyncBook(SettingsSync.WindowsKind, SettingsSyncFields.WindowsKeys, SettingsSyncFields.FindWindows, _host);
#if DEBUG
        if (SettingsSyncFields.Missing.FirstOrDefault() is { } missing)
        {
            Log.Error("settings-sync.missing-field " + missing);
        }
#endif
        // 升级上来第一次算出的「存过的键」（D4：和本机默认不一样的）当场存下来，之后改回默认也还算存过
        if (firstCount)
        {
            _host.Save(landed: false);
        }

        SettingsService.Changed += Queue;
    }

    /// <summary>设置存了：攒到 UI 线程空下来再比（一次改好几项只比一回；比完要存时自己再存一次，那次不再引起比较）。</summary>
    private static void Queue()
    {
        if (_queued || _host is null || _host.Saving || _dispatcher is null)
        {
            return;
        }

        _queued = true;
        _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _queued = false;
            var settings = Settings?.Note() == true;
            var windows = Windows?.Note() == true;
            if (settings || windows)
            {
                _host.Save(landed: false);
            }
        });
    }

    private sealed class Host(SyncLedger ledger) : SettingsSyncHost
    {
        private HashSet<string>? _stored;

        public bool Saving { get; private set; }

        private static Settings Current => SettingsService.Current;

        public override HashSet<string> Stored
            => _stored ??= new HashSet<string>(Current.SyncStoredKeys ?? new List<string>(), StringComparer.Ordinal);

        public override long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        public override bool Busy
            => RecordingHost.IsRecording || AudioHost.IsRecording || StatusScreenHost.Active || SettingsWindow.RecordingHotKey;

        public override SettingValue? Read(SettingKey key) => SettingsSyncFields.Read(Current, key);

        public override SettingValue? Default(SettingKey key) => SettingsSyncFields.Default(key);

        public override void Write(SettingKey key, SettingValue? value) => SettingsSyncFields.Write(Current, key, value);

        public override bool Accept(SettingKey key, SettingValue value) => SettingsSyncFields.Accept(key, value);

        public override bool Tracking(string kind) => Current.SyncEnabled || ledger.Read(kind) is not null;

        public override Dictionary<string, string> Passthrough(string kind) => kind == SettingsSync.Kind
            ? Current.SyncPassthrough ??= new Dictionary<string, string>(StringComparer.Ordinal)
            : Current.SyncPassthroughWindows ??= new Dictionary<string, string>(StringComparer.Ordinal);

        public override Dictionary<string, long> Times(string kind) => kind == SettingsSync.Kind
            ? Current.SyncChangedAt ??= new Dictionary<string, long>(StringComparer.Ordinal)
            : Current.SyncChangedAtWindows ??= new Dictionary<string, long>(StringComparer.Ordinal);

        public override void Save(bool landed)
        {
            Current.SyncStoredKeys = Stored.Order(StringComparer.Ordinal).ToList();
            Saving = true;
            try
            {
                SettingsService.Save();
            }
            finally
            {
                Saving = false;
            }

            if (landed)
            {
                // 落下来的也让另一本看一眼（settings 落了主题，windows-settings 跟着记下）
                Queue();
                Log.Info("settings-sync.landed");
                var bindings = SettingsDefaults.DefaultHotKeys.Select(entry => new KeyValuePair<string, string>(
                    entry.Action, SettingsSyncFields.Read(Current, SettingsSyncMap.HotKey(entry.Action))?.Text ?? string.Empty));
                if (SettingsSync.Clash(bindings) is { } clash)
                {
                    NoticeHost.Show("同步来的两个快捷键撞了",
                        $"「{SettingsDefaults.RowTitle(clash.First)}」和「{SettingsDefaults.RowTitle(clash.Second)}」用了同一个组合，后一个注册不上",
                        NoticeTone.Warning);
                }
            }
        }
    }
}
