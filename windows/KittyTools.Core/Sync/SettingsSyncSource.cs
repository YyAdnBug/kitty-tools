// 设置接进同步的执行层（PLAN-v21 第 2 批；照 mac Storage/SettingsSync.swift 的 SyncSource 那一半）。
// - SettingsSyncHost：设置存在哪（App：settings.json；单测：内存）。存过的键、透传、改的时刻都跟着设置一起存（D6）。
// - SettingsSyncBook：一类（settings / windows-settings）一本，跟 App 一样长：记着上次看到的本机那份（mac known），
//   设置一变就比、记改的时刻（App 在 SettingsService.Changed 之后空下来时叫 Note）。
// - SettingsSyncSource：接进 SyncRunner 的那一层，每轮新建。第一次合跟着已有的（Adopt，mac C4）；settings 一类要等文件夹里
//   有了别的电脑的那份才写（WaitsForPeers，D3）；windows-settings 在文件夹里有了 Mac 的 settings（或本机合过 settings）
//   之后，共有的那几项只发不落。
// 先写设置、再存账本（偏好没有事务，mac 也是挨着做）。
namespace KittyTools.Core.Sync;

public abstract class SettingsSyncHost
{
    /// <summary>本机这一项现在的值（Windows 这边的写法）；null = 没有这一项。</summary>
    public abstract SettingValue? Read(SettingKey key);

    /// <summary>本机默认值（新装时的那个）。</summary>
    public abstract SettingValue? Default(SettingKey key);

    /// <summary>写一项；null = 回到本机默认。</summary>
    public abstract void Write(SettingKey key, SettingValue? value);

    /// <summary>存过的键（SettingKey.Field）。两类共用。</summary>
    public abstract HashSet<string> Stored { get; }

    public abstract Dictionary<string, string> Passthrough(string kind);

    public abstract Dictionary<string, long> Times(string kind);

    /// <summary>把设置连同存过的键、透传、改的时刻存下来；landed = 这次落了同步来的设置。</summary>
    public abstract void Save(bool landed);

    public abstract long Now { get; }

    /// <summary>这一轮设置先不合（录屏 / 录音、正在录快捷键、状态屏开着：mac isBusy）。</summary>
    public virtual bool Busy => false;

    /// <summary>收到的值 App 再核一遍（快捷键能不能用）。</summary>
    public virtual bool Accept(SettingKey key, SettingValue value) => true;

    /// <summary>记不记改的时刻：开着同步、或者这一类合过（mac：没开同步也从没合过时不比，再开就是第一次合）。</summary>
    public virtual bool Tracking(string kind) => true;

    /// <summary>第一次合时跟着别的电脑换了几项（App 用轻提示说一声，同 mac「换了之后……刘海岛说一声」）。</summary>
    public virtual void Followed(string kind, int count)
    {
    }
}

public sealed class SettingsSyncBook
{
    private readonly IReadOnlyList<SettingKey> _keys;
    private readonly Func<string, SettingKey?> _find;
    private readonly SettingsSyncHost _host;
    private Dictionary<string, string> _known;
    private bool _landing;

    public SettingsSyncBook(string kind, IReadOnlyList<SettingKey> keys, Func<string, SettingKey?> find, SettingsSyncHost host)
    {
        Kind = kind;
        _keys = keys;
        _find = find;
        _host = host;
        _known = Own();
    }

    public string Kind { get; }

    /// <summary>本机的那份（不含透传）；顺手把「和默认不一样」的记进存过的键。</summary>
    public Dictionary<string, string> Own()
        => SettingsSync.Own(_keys.Select(key => new SettingReading(key, _host.Read(key), _host.Default(key))), _host.Stored);

    /// <summary>设置变了：和上次看到的比，变了的记成现在改的。返回要不要存（记了时刻、透传少了、存过的键多了）。</summary>
    public bool Note()
    {
        if (_landing)
        {
            return false;
        }

        var stored = _host.Stored.Count;
        var own = Own();
        var grew = _host.Stored.Count != stored;
        if (!_host.Tracking(Kind))
        {
            _known = own;
            return grew;
        }

        var changed = SettingsSync.Record(_known, own, _host.Passthrough(Kind), _host.Times(Kind), _host.Now);
        _known = own;
        return changed || grew;
    }

    /// <summary>交给引擎的那份；忙着时 null（这一轮先不合）。</summary>
    public IReadOnlyDictionary<string, string>? Values()
    {
        if (_host.Busy)
        {
            return null;
        }

        if (Note())
        {
            _host.Save(landed: false);
        }

        AdoptPassthrough();
        return SettingsSync.Values(_known, _host.Passthrough(Kind));
    }

    /// <summary>
    /// 透传里有这一版认得的编号（上一版不认识、存成了透传的，比如 R107 起 Windows 也有的 pref:emojiPackDownloads）：当成一次传进来的改动
    /// 落下（同 Land 的 Plan），落成了的从透传里拿掉，落不下的照旧透传。不然本机那项一直是默认值，交出去的却是透传的那份，引擎看不出变化、
    /// 永远不落（R107 审查：Mac 上关了「自动下载动画表情」，升级后的 Windows 照样开着、照样下载）。
    /// </summary>
    private void AdoptPassthrough()
    {
        var passthrough = _host.Passthrough(Kind);
        var known = passthrough.Where(pair => _find(pair.Key) is not null)
            .ToDictionary(pair => pair.Key, pair => (string?)pair.Value, StringComparer.Ordinal);
        if (known.Count == 0)
        {
            return;
        }

        var plan = SettingsSync.Plan(known, _find, passthrough, Kind == SettingsSync.WindowsKind, sharedFrozen: false, _host.Accept);
        if (plan.Writes.Count > 0 || plan.Passthrough.Count != passthrough.Count)
        {
            Apply(plan, known);
        }
    }

    public IReadOnlyDictionary<string, long> Changed() => new Dictionary<string, long>(_host.Times(Kind), StringComparer.Ordinal);

    /// <summary>落一轮：写设置（存过的键跟着增减）、换透传、清落了的时刻，存下来，再存账本。joining：这一类第一次合。</summary>
    public void Land(IReadOnlyDictionary<string, string?> changes, bool sharedFrozen, bool joining, Action saveLedger)
    {
        var plan = SettingsSync.Plan(
            changes, _find, _host.Passthrough(Kind), Kind == SettingsSync.WindowsKind, sharedFrozen, _host.Accept);
        Apply(plan, changes);
        saveLedger();
        if (joining && plan.Writes.Count > 0)
        {
            _host.Followed(Kind, plan.Writes.Count);
        }
    }

    /// <summary>写设置（存过的键跟着增减）、换透传、清落了的时刻，存下来（Land 和 AdoptPassthrough 共用）。</summary>
    private void Apply(SettingsPlan plan, IReadOnlyDictionary<string, string?> changes)
    {
        _landing = true;
        try
        {
            foreach (var (key, value) in plan.Writes)
            {
                _host.Write(key, value);
                if (value is null)
                {
                    _host.Stored.Remove(key.Field);
                }
                else
                {
                    _host.Stored.Add(key.Field);
                }
            }

            var passthrough = _host.Passthrough(Kind);
            passthrough.Clear();
            foreach (var (id, text) in plan.Passthrough)
            {
                passthrough[id] = text;
            }

            SettingsSync.Landed(changes, _host.Times(Kind));
            _host.Save(landed: plan.Writes.Count > 0);
            _known = Own();
        }
        finally
        {
            _landing = false;
        }
    }
}

public sealed class SettingsSyncSource(
    SettingsSyncBook book, Func<string, SyncLedgerData?> ledger, Action<SyncLedgerData, string> saveLedger,
    Func<bool> settingsMerged) : ISyncSource
{
    private bool _macPresent;
    private bool _joining;

    public string Kind => book.Kind;

    public JoinMode Join => JoinMode.Adopt;

    public bool WaitsForPeers => Kind == SettingsSync.Kind;

    public void SeePeers(Func<string, bool> othersHave) => _macPresent = othersHave(SettingsSync.Kind) || settingsMerged();

    public string? JoinKey(string value) => null;

    public IReadOnlyDictionary<string, string>? Values() => book.Values();

    public IReadOnlyDictionary<string, long>? Changed() => book.Changed();

    public SyncLedgerData? Ledger(string library)
    {
        var data = ledger(library);
        _joining = data is null;
        return data;
    }

    public string? Apply(IReadOnlyDictionary<string, string?> changes, SyncLedgerData data, string library)
    {
        book.Land(changes, sharedFrozen: _macPresent, _joining, () => saveLedger(data, library));
        return null;
    }
}
