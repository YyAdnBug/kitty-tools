// 设置页的「恢复默认」（PLAN-v26 G1，D4 = A，同 mac 0.10.1 a4b161ac / 0fd885fe）：一页能恢复哪几项。按设置同步对照表的键名前缀分页；
// 会删历史的保留期、占用上限（保留几天、最多几条 / 多少 MB、开不开历史）一律不跟着恢复——恢复默认不该顺手删掉东西；
// 排除名单、启动器的命令表这类用户自己攒的列表也不动；快捷键、功能开关各有各的地方，不在这里。
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
}
