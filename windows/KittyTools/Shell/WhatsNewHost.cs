// 新功能标记的账（PLAN-v16 G3，mac WhatsNew 的偏好包装）：规则在 Core 的 WhatsNew，这里只读写设置里的账（这台电脑自己的，不导出不同步）。
// 启动时 Adopt（新装 = 没有设置文件，不标；老设置里没记过上次运行的版本，按 0.0.0 算——升级上来的），执行动作时 Touch（这一版的条目都有动作、没有设置里的一节），
// 界面按 Current() 画。没变化不写设置。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class WhatsNewHost
{
    /// <summary>当前版本（x.y.z）。测试档能用 KITTY_FAKE_VERSION 换一个（截图自检看升级后的样子），正式版不认。</summary>
    public static string Version
        => Paths.IsTestProfile && Environment.GetEnvironmentVariable("KITTY_FAKE_VERSION") is { Length: > 0 } fake
            ? fake
            : typeof(WhatsNewHost).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    public static WhatsNewLedger Ledger()
    {
        var settings = SettingsService.Current;
        return new WhatsNewLedger(
            settings.WhatsNewStarted ?? new Dictionary<string, long>(),
            (settings.WhatsNewTouched ?? new List<string>()).ToHashSet());
    }

    /// <summary>启动时（记「上次运行的版本」之前）：从上次运行的版本升到这一版。</summary>
    public static void Adopt()
    {
        var settings = SettingsService.Current;
        var last = SettingsService.IsNew ? null : settings.LastRunVersion ?? "0.0.0";
        // 测试档：KITTY_WHATS_NEW_LAST 当成上次运行的版本（新档也算升级上来的）
        if (Paths.IsTestProfile && Environment.GetEnvironmentVariable("KITTY_WHATS_NEW_LAST") is { Length: > 0 } simulated)
        {
            last = simulated;
        }

        var current = Version;
        var changed = Update(ledger => WhatsNew.Adopting(ledger, last, current, Now), save: false);
        if (settings.LastRunVersion != current || changed)
        {
            settings.LastRunVersion = current;
            SettingsService.Save();
        }
    }

    /// <summary>此刻要标的（功能开没开现读）。</summary>
    public static List<WhatsNewEntry> Current() => WhatsNew.Fresh(Ledger(), Features.EnabledKeys, Now);

    /// <summary>执行了一个动作（快捷键、主界面、托盘、启动器）。</summary>
    public static void Touch(string action) => Update(ledger => WhatsNew.Touching(ledger, entry => entry.Actions.Contains(action)));

    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private static bool Update(Func<WhatsNewLedger, WhatsNewLedger> change, bool save = true)
    {
        var old = Ledger();
        var updated = change(old);
        if (updated.Same(old))
        {
            return false;
        }

        var settings = SettingsService.Current;
        settings.WhatsNewStarted = updated.Started.ToDictionary(pair => pair.Key, pair => pair.Value);
        settings.WhatsNewTouched = updated.Touched.OrderBy(id => id, StringComparer.Ordinal).ToList();
        if (save)
        {
            SettingsService.Save();
        }

        Log.Info($"whats-new.updated started={updated.Started.Count} touched={updated.Touched.Count}");
        return true;
    }
}
