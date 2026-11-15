// PLAN-v21 第 2 批：设置的两类走真的 SyncRunner 和临时同步文件夹，两台 Windows + 一台按 mac 规矩合的假 Mac
// （FakeMacSettings：一项一条、第一次合跟着已有的、不认识的原样留着——mac SettingsSync 的透传让它原样交回去，这里直接留在表里）。
// 照 mac NoteSyncerTests 的 settingsFollowTheExistingMacs / settingsLaterChangeWinsPerKey / unknownSettingsPassThroughAndBusyWaits，
// 加上 D3：只有 Windows 时不写 settings.json，Mac 后加入时自己的设置一项不少。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsSyncRunnerTests
{
    private static readonly SettingKey Theme = SettingsSyncMap.FindShared("pref:appearance")!;
    private static readonly SettingKey Accent = SettingsSyncMap.FindShared("pref:accent")!;
    private static readonly SettingKey FontSize = SettingsSyncMap.FindShared("pref:notesFontSize")!;
    private static readonly SettingKey Recent = SettingsSyncMap.FindWindows("pref:LauncherRecentPrograms")!;
    private static readonly SettingKey ClipKey = SettingsSyncMap.HotKey("clipboard");

    private static readonly SettingKey[] WindowsKeys = { Theme, Accent, FontSize, Recent, ClipKey };

    private const string MacHotKey = "{\"keyCode\":0,\"modifiers\":2048}";

    [TestMethod]
    public void WindowsWaitsForAMacAndNeverClearsItsSettings()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        long now = 1_000_000;
        var a = new WindowsNode("WIN-A");
        var b = new WindowsNode("WIN-B");
        a.Host.Set(Theme, SettingValue.Of("dark"));
        a.Host.Set(Recent, SettingValue.Of(false));
        a.Host.Set(ClipKey, SettingValue.Of("Ctrl+Alt+V"));
        a.Round(folder, ref now);
        Assert.IsFalse(File.Exists(Path.Combine(folder, SyncDisk.KindPath("WIN-A", SettingsSync.Kind))), "只有 Windows：不写 settings.json");
        var windowsFile = File.ReadAllText(Path.Combine(folder, SyncDisk.KindPath("WIN-A", SettingsSync.WindowsKind)));
        StringAssert.Contains(windowsFile, "pref:LauncherRecentPrograms");
        StringAssert.Contains(windowsFile, "hotkey:clipboard");

        // B 加入（自己改过主题和字号）：Windows 独有的、快捷键跟着 A；两边都有的跟着 A；只有 B 有的字号留着（共有的删除不落）
        b.Host.Set(Theme, SettingValue.Of("light"));
        b.Host.Set(FontSize, SettingValue.Of(13L));
        b.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(false), b.Host.Get(Recent));
        Assert.AreEqual(SettingValue.Of("Ctrl+Alt+V"), b.Host.Get(ClipKey));
        Assert.AreEqual(SettingValue.Of("dark"), b.Host.Get(Theme));
        Assert.AreEqual(SettingValue.Of(13L), b.Host.Get(FontSize));
        Assert.IsTrue(b.Host.Landed > 0);

        // 一台 Mac 加入：文件夹里没有别的 settings.json，它就是第一台，自己的设置原样留着（D3 要防的就是这里被清掉）
        var mac = new FakeMacNode("MAC-M");
        mac.Settings.Map["pref:appearance"] = "\"light\"";
        mac.Settings.Map["pref:islandHaptics"] = "false";
        mac.Settings.Map["hotkey:noteAll"] = MacHotKey;
        mac.Round(folder, ref now);
        CollectionAssert.AreEquivalent(new[] { "pref:appearance", "pref:islandHaptics", "hotkey:noteAll" }, mac.Settings.Map.Keys.ToList());

        // A 看到了 Mac 的 settings：第一次合跟着 Mac；Mac 独有的那几项原样透传、写进自己那份
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("light"), a.Host.Get(Theme));
        Assert.AreEqual(MacHotKey, a.Host.Passthrough(SettingsSync.Kind)["hotkey:noteAll"]);
        var aSettings = File.ReadAllText(Path.Combine(folder, SyncDisk.KindPath("WIN-A", SettingsSync.Kind)));
        StringAssert.Contains(aSettings, "pref:islandHaptics");
        Assert.AreEqual(SettingValue.Of("Ctrl+Alt+V"), a.Host.Get(ClipKey), "Windows 的快捷键不跟 Mac 走");

        mac.Round(folder, ref now);
        Assert.AreEqual("false", mac.Settings.Map["pref:islandHaptics"]);
        Assert.AreEqual(MacHotKey, mac.Settings.Map["hotkey:noteAll"]);
        Assert.IsFalse(mac.Settings.Map.Keys.Any(id => id.StartsWith("pref:Launcher", StringComparison.Ordinal) || id == "hotkey:clipboard"),
            "Windows 独有的不进 settings 一类");

        // 之后两边各改一项，互相跟上
        a.Host.Set(FontSize, SettingValue.Of(18L));
        a.Round(folder, ref now);
        mac.Round(folder, ref now);
        Assert.AreEqual("18", mac.Settings.Map["pref:notesFontSize"]);
        mac.Settings.Map["pref:accent"] = "\"graphite\"";
        mac.Settings.Changed["pref:accent"] = now + 1;
        mac.Round(folder, ref now);
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("graphite"), a.Host.Get(Accent));

        // B 也看到了 Mac：settings 一类第一次合跟着已有的；windows-settings 里共有的那几项不再落（以 settings 为准）
        b.Round(folder, ref now);
        b.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("light"), b.Host.Get(Theme));
        Assert.AreEqual(SettingValue.Of(18L), b.Host.Get(FontSize));
        Assert.AreEqual(SettingValue.Of("graphite"), b.Host.Get(Accent));
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("light"), a.Host.Get(Theme), "B 在 windows-settings 里那份旧的主题不翻回去");

        // 两类各合出不一样的结果时以 settings 为准：Mac 先改成深色，B 稍后改成跟随系统（后改的赢）；A 落深色时
        // windows-settings 里记成「A 此刻改的」，比 B 的晚——B 那边 windows-settings 合出来是深色，不能落
        var start = now;
        mac.Settings.Map["pref:appearance"] = "\"dark\"";
        mac.Settings.Changed["pref:appearance"] = start + 10;
        mac.Round(folder, ref now);
        b.Host.NowValue = start + 500;
        b.Host.Set(Theme, SettingValue.Of("system"));
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("dark"), a.Host.Get(Theme));
        b.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("system"), b.Host.Get(Theme), "settings 一类里 B 后改的赢");
        a.Round(folder, ref now);
        mac.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of("system"), a.Host.Get(Theme));
        Assert.AreEqual("\"system\"", mac.Settings.Map["pref:appearance"]);
    }

    [TestMethod]
    public void UnknownAndOutOfRangeValuesPassThroughUntilChangedHere()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        long now = 1_000_000;
        var mac = new FakeMacNode("MAC-M");
        mac.Settings.Map["pref:notesFontSize"] = "15";
        mac.Round(folder, ref now);
        var a = new WindowsNode("WIN-A");
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(15L), a.Host.Get(FontSize));

        // 更新版本放宽了范围：A 落不下、透传着，交出去的也是它（不拿本机的旧值翻回去）
        mac.Settings.Map["pref:notesFontSize"] = "5000000";
        mac.Settings.Changed["pref:notesFontSize"] = now + 1;
        mac.Round(folder, ref now);
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(15L), a.Host.Get(FontSize));
        Assert.AreEqual("5000000", a.Host.Passthrough(SettingsSync.Kind)["pref:notesFontSize"]);
        mac.Round(folder, ref now);
        Assert.AreEqual("5000000", mac.Settings.Map["pref:notesFontSize"]);

        // A 自己再改：换成 A 的
        now += 10_000;
        a.Host.NowValue = now;
        a.Host.Set(FontSize, SettingValue.Of(16L));
        a.Round(folder, ref now);
        mac.Round(folder, ref now);
        Assert.AreEqual("16", mac.Settings.Map["pref:notesFontSize"]);
        Assert.IsFalse(a.Host.Passthrough(SettingsSync.Kind).ContainsKey("pref:notesFontSize"));
    }

    [TestMethod]
    public void BusyWaitsAndLaterChangeWinsPerKey()
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        long now = 1_000_000;
        var mac = new FakeMacNode("MAC-M");
        mac.Settings.Map["pref:appearance"] = "\"dark\"";
        mac.Round(folder, ref now);
        var a = new WindowsNode("WIN-A");
        a.Round(folder, ref now);
        mac.Round(folder, ref now);

        // A 先改（记下了改的时刻），Mac 后改：两边都是 Mac 的
        a.Host.NowValue = now + 100;
        a.Host.Set(FontSize, SettingValue.Of(20L));
        mac.Settings.Map["pref:notesFontSize"] = "13";
        mac.Settings.Changed["pref:notesFontSize"] = now + 200;
        now += 1000;
        mac.Round(folder, ref now);
        a.Round(folder, ref now);
        mac.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(13L), a.Host.Get(FontSize));
        Assert.AreEqual("13", mac.Settings.Map["pref:notesFontSize"]);

        // 忙着（录屏之类）：设置先不合；不忙了照常合
        a.Host.IsBusy = true;
        mac.Settings.Map["pref:notesFontSize"] = "19";
        mac.Settings.Changed["pref:notesFontSize"] = now + 1;
        mac.Round(folder, ref now);
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(13L), a.Host.Get(FontSize));
        a.Host.IsBusy = false;
        a.Round(folder, ref now);
        Assert.AreEqual(SettingValue.Of(19L), a.Host.Get(FontSize));
    }

    /// <summary>一台 Windows：两本（settings、windows-settings），每轮新建两个 SettingsSyncSource（同 App）。</summary>
    private sealed class WindowsNode
    {
        private readonly Dictionary<string, (string Library, string Text)> _ledgers = new(StringComparer.Ordinal);
        private readonly MemoryDevice _device = new();
        private readonly SettingsSyncBook _settings;
        private readonly SettingsSyncBook _windows;

        public WindowsNode(string id)
        {
            _device.Id = id;
            Host = new MemoryHost(WindowsKeys);
            var shared = WindowsKeys.Where(key => key.Shared).ToList();
            _settings = new SettingsSyncBook(SettingsSync.Kind, shared, SettingsSyncMap.FindShared, Host);
            _windows = new SettingsSyncBook(SettingsSync.WindowsKind, WindowsKeys,
                id => WindowsKeys.FirstOrDefault(key => key.Id == id), Host);
            Host.Books = new[] { _settings, _windows };
        }

        public MemoryHost Host { get; }

        public void Round(string folder, ref long now)
        {
            now += 1000;
            Host.NowValue = Math.Max(Host.NowValue, now);
            var sources = new ISyncSource[] { Source(_settings), Source(_windows) };
            var result = new SyncRunner(_device, sources, _device.Id).RunAsync(folder, new Dictionary<string, int>(), now)
                .GetAwaiter().GetResult();
            Assert.AreEqual("idle", result.State, result.Message);
        }

        private SettingsSyncSource Source(SettingsSyncBook book)
            => new(book,
                library => _ledgers.TryGetValue(book.Kind, out var saved) && saved.Library == library ? SyncLedgerText.Decode(saved.Text) : null,
                (data, library) => _ledgers[book.Kind] = (library, SyncLedgerText.Encode(data)),
                () => _ledgers.ContainsKey(SettingsSync.Kind));
    }

    private sealed class MemoryHost : SettingsSyncHost
    {
        private readonly Dictionary<string, SettingValue> _values = new(StringComparer.Ordinal);
        private readonly Dictionary<string, SettingValue> _defaults = new(StringComparer.Ordinal);
        private readonly Dictionary<string, Dictionary<string, string>> _passthrough = new(StringComparer.Ordinal);
        private readonly Dictionary<string, Dictionary<string, long>> _times = new(StringComparer.Ordinal);

        public MemoryHost(IEnumerable<SettingKey> keys)
        {
            foreach (var key in keys)
            {
                _defaults[key.Field] = key.Type switch
                {
                    SettingType.Bool => SettingValue.Of(true),
                    SettingType.Int => SettingValue.Of(15L),
                    _ => key == Accent ? SettingValue.Of("brand") : key == Theme ? SettingValue.Of("system") : SettingValue.Of("Alt+C"),
                };
                _values[key.Field] = _defaults[key.Field];
            }
        }

        public SettingsSyncBook[] Books { get; set; } = Array.Empty<SettingsSyncBook>();

        public bool IsBusy { get; set; }

        public int Landed { get; private set; }

        public override long Now => NowValue;

        public long NowValue { get; set; }

        public override HashSet<string> Stored { get; } = new(StringComparer.Ordinal);

        public override bool Busy => IsBusy;

        public SettingValue Get(SettingKey key) => _values[key.Field];

        /// <summary>用户在设置里改了一项（App：Save → Changed → 两本 Note）。</summary>
        public void Set(SettingKey key, SettingValue value)
        {
            _values[key.Field] = value;
            foreach (var book in Books)
            {
                book.Note();
            }
        }

        public override SettingValue? Read(SettingKey key) => _values[key.Field];

        public override SettingValue? Default(SettingKey key) => _defaults[key.Field];

        public override void Write(SettingKey key, SettingValue? value) => _values[key.Field] = value ?? _defaults[key.Field];

        public override Dictionary<string, string> Passthrough(string kind)
            => _passthrough.TryGetValue(kind, out var map) ? map : _passthrough[kind] = new(StringComparer.Ordinal);

        public override Dictionary<string, long> Times(string kind)
            => _times.TryGetValue(kind, out var map) ? map : _times[kind] = new(StringComparer.Ordinal);

        public override void Save(bool landed)
        {
            if (landed)
            {
                Landed++;
                // App：Save 之后 SettingsService.Changed，两本都看一眼
                foreach (var book in Books)
                {
                    book.Note();
                }
            }
        }
    }

    /// <summary>假 Mac：mac SettingsSync 的样子——一项一条、第一次合跟着已有的、改的时刻自己记（Changed）。</summary>
    private sealed class FakeMacSettings : ISyncSource
    {
        public Dictionary<string, string> Map { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, long> Changed { get; } = new(StringComparer.Ordinal);

        public string? LedgerText { get; private set; }

        public string? LedgerLibrary { get; private set; }

        public string Kind => SettingsSync.Kind;

        public JoinMode Join => JoinMode.Adopt;

        public string? JoinKey(string value) => null;

        public IReadOnlyDictionary<string, string>? Values() => new Dictionary<string, string>(Map, StringComparer.Ordinal);

        IReadOnlyDictionary<string, long>? ISyncSource.Changed() => new Dictionary<string, long>(Changed, StringComparer.Ordinal);

        public SyncLedgerData? Ledger(string library)
            => LedgerText is null || LedgerLibrary != library ? null : SyncLedgerText.Decode(LedgerText);

        public string? Apply(IReadOnlyDictionary<string, string?> changes, SyncLedgerData ledger, string library)
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

                Changed.Remove(id);
            }

            LedgerText = SyncLedgerText.Encode(ledger);
            LedgerLibrary = library;
            return null;
        }
    }

    private sealed class FakeMacNode(string id)
    {
        private readonly MemoryDevice _device = new() { Id = id };

        public FakeMacSettings Settings { get; } = new();

        public void Round(string folder, ref long now)
        {
            now += 1000;
            var result = new SyncRunner(_device, new ISyncSource[] { Settings }, id)
                .RunAsync(folder, new Dictionary<string, int>(), now).GetAwaiter().GetResult();
            Assert.AreEqual("idle", result.State, result.Message);
        }
    }
}
