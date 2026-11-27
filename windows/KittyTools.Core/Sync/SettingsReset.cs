// 设置页的「恢复默认」（PLAN-v26 G1，D4 = A，同 mac 0.10.1 a4b161ac / 0fd885fe）：一页能恢复哪几项。按设置同步对照表的键名前缀分页；
// 会删历史的保留期、占用上限（保留几天、最多几条 / 多少 MB、开不开历史）一律不跟着恢复——恢复默认不该顺手删掉东西；
// 排除名单、启动器的命令表这类用户自己攒的列表也不动；快捷键、功能开关各有各的地方，不在这里。
// PLAN-v28 X5（mac SettingsReset.swift）：改成每个子页、每个「高级」最后一行的「恢复默认」——管哪些键看登记表（SettingsIndex.ResetKeys），
// 只动这台电脑改过的（和默认值不一样的）那几个，交回它们原来的值给「撤销」原样写回；点了不先问。KeysFor 是 PLAN-v26 页尾那张卡用的，
// 那张卡去掉了，留着给旧的单测锁住「保留期、占用、历史开关不跟着恢复」这条规矩（ResetKeys 的排除名单是它的子集）。
namespace KittyTools.Core.Sync;

public static class SettingsReset
{
    /// <summary>每一页认哪些键（键名前缀；完整键名写全）。</summary>
    private static readonly Dictionary<string, string[]> Prefixes = new(StringComparer.Ordinal)
    {
        ["clipboard"] = new[] { "clipboard" },
        ["launcher"] = new[] { "launcher" },
        ["translate"] = new[] { "translate", "autoCopy" },
        ["screenshot"] = new[] { "screenshot", "scrollCapture", "pinSelectsText", "ocrJoinLines", "ScreenshotCursor", "CaptureHideDesktopIcons" },
        ["record"] = new[] { "screenRecord", "audioRecord" },
        ["statusScreen"] = new[] { "statusScreen" },
        ["reminders"] = new[] { "reminders" },
        ["notes"] = new[] { "notes" },
    };

    /// <summary>这一页「恢复默认」会动的键（id）；这一页没有就是空的。</summary>
    public static List<string> KeysFor(string page, IEnumerable<string> ids)
        => Prefixes.TryGetValue(page, out var prefixes)
            ? ids.Where(id => prefixes.Any(prefix => id.StartsWith(prefix, StringComparison.Ordinal)) && !Kept(id)).Distinct().ToList()
            : new List<string>();

    /// <summary>不跟着恢复的：保留期、占用上限、历史开关，和用户自己攒的列表。</summary>
    public static bool Kept(string id)
        => id.Contains("Retention", StringComparison.OrdinalIgnoreCase) ||
           id.Contains("History", StringComparison.OrdinalIgnoreCase) ||
           id.Contains("MaxMb", StringComparison.OrdinalIgnoreCase) ||
           id.Contains("Megabytes", StringComparison.OrdinalIgnoreCase) ||
           id.Contains("Excluded", StringComparison.OrdinalIgnoreCase) ||
           id.StartsWith("Launcher", StringComparison.Ordinal) ||
           id.StartsWith("hotkey.", StringComparison.Ordinal) ||
           id.StartsWith("feature.", StringComparison.Ordinal);

    /// <summary>
    /// 恢复默认之前记下的那一份：keys 里此刻和默认值不一样的（read 读此刻的值，读不到的 —— 没接上读写、这台电脑自己的 —— 不算；fallback 读默认值）。
    /// 空的 = 一个都没改过（按钮灰着）。按 keys 的先后。
    /// </summary>
    public static List<(string Key, T Value)> Changed<T>(IEnumerable<string> keys, Func<string, T?> read, Func<string, T?> fallback)
        where T : class
    {
        var changed = new List<(string Key, T Value)>();
        foreach (var key in keys.Distinct(StringComparer.Ordinal))
        {
            if (read(key) is { } value && !value.Equals(fallback(key)))
            {
                changed.Add((key, value));
            }
        }

        return changed;
    }
}
