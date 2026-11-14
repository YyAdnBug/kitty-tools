// 在哪些应用里停用快捷键（PLAN-v17，同 mac HotKeyBlock.swift）：RegisterHotKey 注册的组合按下时系统把 WM_HOTKEY 投给我们、
// 前台窗口收不到，所以名单里的应用在前台时干脆不注册对应的键，按键原样到那个应用；离开时再注册回来（HotKeyBlocker）。
// 这里只放名单的存法和「此刻停哪些」的纯函数（单测喂字符串，不读设置）。
// 设置里是一组字符串（Settings.HotKeyBlockedApps，默认空，跟着导出导入走，键名 hotKeyBlockedExes）：一条一个应用，
// 「exe 名」= 全部快捷键（以后的启动器命令快捷键、连按两下修饰键也归它），「exe 名|动作,动作」= 只停这几个全局动作；
// 不认识的动作 id（以后加的）原样留着、写回去。exe 名按文件名、不分大小写匹配（同剪贴板「排除的应用」）；同一个 exe 只认第一条。
namespace KittyTools.Core;

public sealed record HotKeyBlock(string Exe, IReadOnlyList<string>? Actions = null)
{
    /// <summary>名单最多这么多条、每条这么长（导入时照这个截）。</summary>
    public const int MaxEntries = 200;

    public const int MaxEntryLength = 512;

    /// <summary>设置里的一条；空的、带路径分隔符或换行的不认。</summary>
    public static HotKeyBlock? Parse(string? entry)
    {
        if (string.IsNullOrEmpty(entry) || entry.Length > MaxEntryLength)
        {
            return null;
        }

        var bar = entry.IndexOf('|');
        var exe = bar < 0 ? entry : entry[..bar];
        if (exe.Trim().Length == 0 || exe != exe.Trim() || exe.IndexOfAny(new[] { '\\', '/', '\r', '\n', ',' }) >= 0)
        {
            return null;
        }

        return new HotKeyBlock(exe, bar < 0 ? null : entry[(bar + 1)..].Split(',', StringSplitOptions.RemoveEmptyEntries));
    }

    public string Entry => Actions is null ? Exe : Exe + "|" + string.Join(",", Actions);

    /// <summary>认得的那几个动作（只停几个时；known 是全部动作 id）。</summary>
    public IReadOnlyList<string> KnownActions(IReadOnlyList<string> known)
        => known.Where(action => Actions?.Contains(action) == true).ToList();

    /// <summary>这个应用停不停这个动作（设置页里那一行的勾）。</summary>
    public bool Blocks(string action) => Actions is null || Actions.Contains(action);

    /// <summary>
    /// 勾上 / 取消一个动作：从「全部」取消一个 = 只停 shown（页面上列出来的）里除它以外的那些；按 known 的顺序存，不认识的动作 id 留在后面。
    /// </summary>
    public HotKeyBlock Setting(string action, bool blocked, IReadOnlyList<string> shown, IReadOnlyList<string> known)
    {
        var chosen = new HashSet<string>(Actions is null ? shown : KnownActions(known));
        if (blocked)
        {
            chosen.Add(action);
        }
        else
        {
            chosen.Remove(action);
        }

        var unknown = (Actions ?? Array.Empty<string>()).Where(id => !known.Contains(id));
        return this with { Actions = known.Where(chosen.Contains).Concat(unknown).ToList() };
    }

    /// <summary>整张名单（读不出来的条目扔掉、同一个 exe 只留第一条，最多 MaxEntries 条）。</summary>
    public static List<HotKeyBlock> List(IEnumerable<string>? entries)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return (entries ?? Array.Empty<string>())
            .Select(Parse)
            .OfType<HotKeyBlock>()
            .Where(block => seen.Add(block.Exe))
            .Take(MaxEntries)
            .ToList();
    }

    /// <summary>前台是这个 exe 时停哪些；null = 不停（不在名单里、或只停的几个都不认识 / 是空的）。</summary>
    public static HotKeyBlockRule? RuleFor(string? exe, IEnumerable<string>? entries, IReadOnlyList<string> known)
    {
        if (string.IsNullOrEmpty(exe) ||
            List(entries).FirstOrDefault(block => string.Equals(block.Exe, exe, StringComparison.OrdinalIgnoreCase)) is not { } block)
        {
            return null;
        }

        if (block.Actions is null)
        {
            return HotKeyBlockRule.All;
        }

        var actions = block.KnownActions(known);
        return actions.Count == 0 ? null : new HotKeyBlockRule(false, actions.ToHashSet());
    }

    /// <summary>设置页那一行下拉的字（mac HotKeyBlockSection.scope）。</summary>
    public static string Scope(HotKeyBlock block)
        => block.Actions is null ? "全部快捷键" : block.Actions.Count == 0 ? "没有停用的" : $"{block.Actions.Count} 个快捷键";

    /// <summary>
    /// 「全屏游戏时停用快捷键」认哪几种（PLAN-v17 W1）：SHQueryUserNotificationState 是 QUNS_RUNNING_D3D_FULL_SCREEN（3）或
    /// QUNS_PRESENTATION_MODE（4）。不认 QUNS_BUSY（2）：全屏看视频、F11 的网页也是它，那时截图、识字是正当用法。
    /// </summary>
    public static bool IsFullscreenGame(int notificationState) => notificationState is 3 or 4;
}

/// <summary>此刻对前台应用生效的停用规则：All = 全部（各动作、以后的命令快捷键和连按两下都不注册）；否则只停 Only 里的。</summary>
public sealed record HotKeyBlockRule(bool AllActions, IReadOnlySet<string> Only)
{
    public static readonly HotKeyBlockRule All = new(true, new HashSet<string>());

    public bool Blocks(string action) => AllActions || Only.Contains(action);

    /// <summary>启动器命令的快捷键、连按两下修饰键只跟着「全部」。</summary>
    public bool BlocksCommands => AllActions;

    public bool Equals(HotKeyBlockRule? other)
        => other is not null && AllActions == other.AllActions && Only.SetEquals(other.Only);

    public override int GetHashCode() => AllActions ? 1 : Only.Count;
}
