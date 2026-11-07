// 设置侧栏的分组和新装默认开哪些功能（PLAN-v16 G2，照 mac SettingsPage.groups / sidebar、Feature.seedNewInstall，纯函数配单测）：
// 通用 ｜ 文字与搜索（剪贴板、启动器、翻译）｜ 截图与录制 ｜ 便签与提醒（便签、提醒、状态屏）｜ 快捷键、关于；功能那三组带小标题、能收起，
// 通用和快捷键与关于两组不写标题。关着的功能不在原来的组里，照侧栏顺序挪进最底下的「已关闭（N）」组（默认收起）。
// mac 的「桌面」组（启动台、程序坞预览）Windows 没有。
namespace KittyTools.Core;

/// <summary>侧栏的一组：标题（null = 不画）、组里的页；IsOff 是最底下「已关闭」那组。</summary>
public sealed record SidebarGroup(string? Title, IReadOnlyList<string> Pages, bool IsOff = false);

public static class SettingsSidebar
{
    /// <summary>侧栏的页（顺序就是侧栏的顺序，同 mac）。</summary>
    public static readonly IReadOnlyList<IReadOnlyList<string>> Groups = new IReadOnlyList<string>[]
    {
        new[] { "general" },
        new[] { "clipboard", "launcher", "translate" },
        new[] { "screenshot", "record" },
        new[] { "notes", "reminders", "statusScreen" },
        new[] { "hotkeys", "about" },
    };

    public static IEnumerable<string> AllPages => Groups.SelectMany(group => group);

    /// <summary>组标题；通用、快捷键与关于不写。</summary>
    public static string? GroupTitle(string page) => page switch
    {
        "clipboard" or "launcher" or "translate" => "文字与搜索",
        "screenshot" or "record" => "截图与录制",
        "notes" or "reminders" or "statusScreen" => "便签与提醒",
        _ => null,
    };

    /// <summary>侧栏这一刻怎么分组：只留 pages 里有的（搜索匹配的），空了的组不画；关着的功能（off）挪进最底下的「已关闭（N）」。</summary>
    public static List<SidebarGroup> Build(IReadOnlyCollection<string> pages, IReadOnlySet<string> off)
    {
        var shown = Groups
            .Select(group => group.Where(page => pages.Contains(page) && !off.Contains(page)).ToList())
            .Where(kept => kept.Count > 0)
            .Select(kept => new SidebarGroup(GroupTitle(kept[0]), kept))
            .ToList();
        var closed = AllPages.Where(page => pages.Contains(page) && off.Contains(page)).ToList();
        if (closed.Count > 0)
        {
            shown.Add(new SidebarGroup($"已关闭（{closed.Count}）", closed, IsOff: true));
        }

        return shown;
    }

    /// <summary>一组展开没有：搜索时都展开；「已关闭」默认收起，点开过、或者当前页就在里面时展开。</summary>
    public static bool IsExpanded(SidebarGroup group, bool searching, IReadOnlySet<string> collapsed, bool showsOff, string current)
        => searching || (group.IsOff
            ? showsOff || group.Pages.Contains(current)
            : group.Title is not { } title || !collapsed.Contains(title) || group.Pages.Contains(current));

    /// <summary>新装默认开着的四个（mac Feature.core，PLAN-v16 §3 V4）：剪贴板、启动器、翻译、截图（功能键名）。</summary>
    public static readonly IReadOnlySet<string> CoreFeatures = new HashSet<string> { "clipboard", "launcher", "translate", "screenshot" };

    /// <summary>
    /// 新装第一次启动把每个功能的开关明写进设置：常用的四个开、别的关；已经写了的不动（mac seedNewInstall）。
    /// 默认值本身不变（没存过 = 开），所以导入老电脑的文件、加入同步时没动过的开关不会被悄悄换成这台的默认。
    /// </summary>
    public static Dictionary<string, bool> SeedNewInstall(IEnumerable<string> featureKeys, IReadOnlyDictionary<string, bool>? stored)
    {
        var result = stored is null ? new Dictionary<string, bool>() : new Dictionary<string, bool>(stored);
        foreach (var key in featureKeys)
        {
            result.TryAdd(key, CoreFeatures.Contains(key));
        }

        return result;
    }
}
