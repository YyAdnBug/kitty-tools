// 新功能标记「新」（PLAN-v16 G3，照 mac Shell/WhatsNew.swift 的规则，纯函数配单测）：从旧版本升上来后，这一版新加的功能挂一个「新」——
// 托盘菜单（子菜单的父项跟着挂）和主界面是格子名字前的强调色小圆点、设置侧栏是行尾的小圆点（收起的组标题后也一个）、设置页里新的那一节是
// 标题后描边的「新」。
// - 标什么：Entries，每版最多 3 个，只挑有入口的。0.2.0（PLAN-v16 §3 V3）：便签、提醒、状态屏（Windows 这一轮真新加的）。
//   PLAN-v19 / v18 的同步服务器、脚本命令（用户 2026-11-14 并进 0.2.0）不标：一版只标 3 个，这三个更大。
//   id 发布后别改（「碰过」按它记）。版本号写 0.2.0：0.1.2 之后不管下一版发成几，这几样都在 (上次, 这次] 里。
// - 什么时候出：只有从旧版本升上来的（上次打开的版本之后、这一版及以前加的都算，跳着升级的中间几版一起标），新装不标；功能关着不标。
// - 什么时候没：真用过一次就各处一起没——执行了它的动作、拨过它那一节的开关（设置换页时看着的那页不闪掉，换页才没）；升到下一版时
//   上一版（和更早）的一起没；一直没碰，从这台电脑第一次打开那一版起最多挂 30 天。
// - 账是这台电脑自己的（不导出、不同步），没变化不写。时刻用 Unix 毫秒；「很久以前」写 0。
namespace KittyTools.Core;

public sealed record WhatsNewEntry(
    string Id,
    string Version,
    string? Feature,
    IReadOnlyList<string> Actions,
    string? Page,
    string? Section = null);

public sealed record WhatsNewLedger(IReadOnlyDictionary<string, long> Started, IReadOnlySet<string> Touched)
{
    public static readonly WhatsNewLedger Empty = new(new Dictionary<string, long>(), new HashSet<string>());

    public bool Same(WhatsNewLedger other)
        => Started.Count == other.Started.Count && Started.All(pair => other.Started.TryGetValue(pair.Key, out var value) && value == pair.Value) &&
           Touched.SetEquals(other.Touched);
}

public static class WhatsNew
{
    /// <summary>一版最多标几个（标多了到处都是「新」，等于没标）。</summary>
    public const int PerVersion = 3;

    /// <summary>一直没碰最多挂多久。</summary>
    public const long LifetimeMs = 30L * 24 * 60 * 60 * 1000;

    public const string Label = "新";

    public const string Spoken = "新功能";

    /// <summary>清单（新的版本往后加；功能键名同 Features.Key，动作同 HotKeyActions，页同设置侧栏的 tag）。</summary>
    public static readonly IReadOnlyList<WhatsNewEntry> Entries = new[]
    {
        new WhatsNewEntry("notes", "0.2.0", "notes", new[] { "noteCapture", "noteNew", "noteAll" }, "notes"),
        new WhatsNewEntry("reminders", "0.2.0", "reminders", new[] { "reminderNew" }, "reminders"),
        new WhatsNewEntry("status-screen", "0.2.0", "statusScreen", new[] { "statusScreen" }, "statusScreen"),
    };

    /// <summary>版本号比较（x.y.z，认不出的当 0）。</summary>
    public static bool IsNewer(string version, string than)
        => Parse(version).CompareTo(Parse(than)) > 0;

    private static Version Parse(string value) => Version.TryParse(value, out var version) ? version : new Version(0, 0);

    /// <summary>
    /// 升级上来：上次打开的是 last、这次是 current，(last, current] 里有条目的版本记下从 now 起算；记过的不动。last 是 null（新装）什么都不记。
    /// 真升了一版：上次那一版和更早的记成很久以前开始的（不删：删了退回旧版本再升上来，中间那版会重新挂一遍）。
    /// </summary>
    public static WhatsNewLedger Adopting(WhatsNewLedger ledger, string? last, string current, long now, IReadOnlyList<WhatsNewEntry>? entries = null)
    {
        if (last is null)
        {
            return ledger;
        }

        var started = new Dictionary<string, long>(ledger.Started);
        if (IsNewer(current, last))
        {
            foreach (var version in started.Keys.ToList())
            {
                if (!IsNewer(version, last))
                {
                    started[version] = 0;
                }
            }
        }

        foreach (var version in (entries ?? Entries).Select(entry => entry.Version).Distinct())
        {
            if (IsNewer(version, last) && !IsNewer(version, current) && !started.ContainsKey(version))
            {
                started[version] = now;
            }
        }

        return ledger with { Started = started };
    }

    /// <summary>此刻要标的：那一版开始标了、没过 30 天、没碰过、功能开着（钟往回拨了的照标）。</summary>
    public static List<WhatsNewEntry> Fresh(WhatsNewLedger ledger, IReadOnlySet<string> enabledFeatures, long now, IReadOnlyList<WhatsNewEntry>? entries = null)
        => (entries ?? Entries).Where(entry =>
                ledger.Started.TryGetValue(entry.Version, out var start) && now - start < LifetimeMs &&
                !ledger.Touched.Contains(entry.Id) &&
                (entry.Feature is null || enabledFeatures.Contains(entry.Feature)))
            .ToList();

    /// <summary>碰过对得上的那几个。只记已经开始标的，记过的不重复：没变化就是原样（调用方据此不写设置）。</summary>
    public static WhatsNewLedger Touching(WhatsNewLedger ledger, Func<WhatsNewEntry, bool> matches, IReadOnlyList<WhatsNewEntry>? entries = null)
    {
        var touched = new HashSet<string>(ledger.Touched);
        foreach (var entry in entries ?? Entries)
        {
            if (matches(entry) && ledger.Started.ContainsKey(entry.Version))
            {
                touched.Add(entry.Id);
            }
        }

        return touched.Count == ledger.Touched.Count ? ledger : ledger with { Touched = touched };
    }

    /// <summary>要标的里有没有只在设置里才有入口的（托盘的「设置…」、主界面底栏的「设置」前面挂标记）。</summary>
    public static bool InSettingsOnly(IEnumerable<WhatsNewEntry> fresh) => fresh.Any(entry => entry.Actions.Count == 0 && entry.Page is not null);

    /// <summary>
    /// 换到设置的一页时设置窗里该标哪几个（id）：此刻要标的，加上这一页原来就标着的——看着的时候不闪掉，换到别的页才没。
    /// </summary>
    public static HashSet<string> Shown(string page, IEnumerable<WhatsNewEntry> fresh, IReadOnlySet<string> showing, IReadOnlyList<WhatsNewEntry>? entries = null)
    {
        var result = fresh.Select(entry => entry.Id).ToHashSet();
        foreach (var entry in (entries ?? Entries).Where(entry => entry.Page == page && showing.Contains(entry.Id)))
        {
            result.Add(entry.Id);
        }

        return result;
    }

    /// <summary>设置窗里这一页要不要标（侧栏那一行、收起的组）。</summary>
    public static bool Marks(string page, IReadOnlySet<string> ids, IReadOnlyList<WhatsNewEntry>? entries = null)
        => (entries ?? Entries).Any(entry => ids.Contains(entry.Id) && entry.Page == page);

    /// <summary>设置页里这一节要不要标。</summary>
    public static bool Marks(string section, string page, IReadOnlySet<string> ids, IReadOnlyList<WhatsNewEntry>? entries = null)
        => (entries ?? Entries).Any(entry => ids.Contains(entry.Id) && entry.Page == page && entry.Section == section);

    /// <summary>这个动作要不要标（托盘菜单项、主界面的格子）。</summary>
    public static bool MarksAction(string action, IEnumerable<WhatsNewEntry> fresh) => fresh.Any(entry => entry.Actions.Contains(action));
}
