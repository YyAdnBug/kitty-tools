// 启动器空查询的那一屏（纯函数，配单测；照 mac LauncherModel.home / groups、LauncherUsage.toggleFavorite）：
// 先「收藏」（按加入顺序，最多 8 个；还原不出来的——应用卸了、文件删了——藏起来、不删、不占名额），
// 再按全局使用分用「常用」补足到 8 行（和收藏重复的跳过）。两组各有一个 28 的分组标题。
namespace KittyTools.Core;

public readonly record struct LauncherGroup(int Row, string Title);

public static class LauncherHome
{
    public const int FavoriteLimit = 8;

    public const int RecentLimit = 8;

    /// <summary>
    /// favorites：按顺序还原过的收藏（还原不出来的是 null，藏起来）；frequent：按分排好的常用（同样 null = 跳过）。
    /// 返回列表和其中前几条是收藏。
    /// </summary>
    public static (List<LauncherItem> Items, int FavoriteCount) Merge(
        IEnumerable<LauncherItem?> favorites, IEnumerable<LauncherItem?> frequent)
    {
        var items = new List<LauncherItem>();
        var seen = new HashSet<string>();
        foreach (var item in favorites)
        {
            if (item is not null && seen.Add(item.Id))
            {
                items.Add(item);
            }
        }

        var favoriteCount = items.Count;
        foreach (var item in frequent)
        {
            if (items.Count >= RecentLimit)
            {
                break;
            }

            if (item is not null && seen.Add(item.Id))
            {
                items.Add(item);
            }
        }

        return (items, favoriteCount);
    }

    /// <summary>分组标题：有收藏时「收藏」在第 0 行前；没有收藏、或收藏后面还有常用时「常用」排在收藏后面（mac groups）。</summary>
    public static List<LauncherGroup> Groups(int count, int favoriteCount)
    {
        var groups = new List<LauncherGroup>();
        if (count == 0)
        {
            return groups;
        }

        if (favoriteCount > 0)
        {
            groups.Add(new LauncherGroup(0, "收藏"));
        }

        if (favoriteCount == 0 || count > favoriteCount)
        {
            groups.Add(new LauncherGroup(favoriteCount, "常用"));
        }

        return groups;
    }

    /// <summary>Ctrl+D 加收藏：看得见的收藏已经满 8 个时不让加（藏起来的不占名额）。</summary>
    public static bool CanAddFavorite(int visibleFavorites) => visibleFavorites < FavoriteLimit;

    /// <summary>
    /// Ctrl+Alt+↑↓：和看得见的上一个 / 下一个换（mac swapFavorites：藏着的不挡着，换了看得出变化）。
    /// order 是全部收藏的目标（含藏着的），visible 是看得见的那几个；返回换好的顺序，换不了（到头了、不是收藏）返回 null。
    /// </summary>
    public static List<string>? Swap(IReadOnlyList<string> order, IReadOnlyList<string> visible, string target, int delta)
    {
        var at = visible.ToList().IndexOf(target);
        var neighbor = at + delta;
        if (at < 0 || neighbor < 0 || neighbor >= visible.Count)
        {
            return null;
        }

        var result = order.ToList();
        var from = result.IndexOf(target);
        var to = result.IndexOf(visible[neighbor]);
        if (from < 0 || to < 0)
        {
            return null;
        }

        (result[from], result[to]) = (result[to], result[from]);
        return result;
    }
}
