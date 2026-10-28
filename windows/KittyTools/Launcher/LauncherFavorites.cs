// 启动器收藏（第三版 §6，PLAN-v9-launcher R8 照 mac）：launcher_favorites，按 position 排；Ctrl+D 收藏 / 取消（看得见的满 8 个不让加，
// 由模型判断），Ctrl+Alt+↑↓ 和看得见的邻居换。空查询时收藏排在「常用」前面；还原不出来的只藏起来、不删。
// 目标用 Target（应用路径 / 设置页 id / 命令 target），Kind 记类型，重建时能认出。
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class LauncherFavorite
{
    public string Target { get; init; } = string.Empty;

    public string Kind { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public int Position { get; init; }
}

internal sealed class LauncherFavorites
{
    private readonly Database _database;

    public LauncherFavorites(Database database)
    {
        _database = database;
    }

    public static LauncherFavorites? Instance { get; private set; }

    public static LauncherFavorites? Start(Database database)
    {
        Instance = new LauncherFavorites(database);
        return Instance;
    }

    public List<LauncherFavorite> Load()
    {
        var favorites = new List<LauncherFavorite>();
        using var statement = _database.Connection.Prepare(
            "SELECT target, kind, title, position FROM launcher_favorites ORDER BY position ASC, added_at ASC;");
        while (statement.Step())
        {
            favorites.Add(new LauncherFavorite
            {
                Target = statement.GetText(0) ?? string.Empty,
                Kind = statement.GetText(1) ?? string.Empty,
                Title = statement.GetText(2) ?? string.Empty,
                Position = statement.GetInt32(3),
            });
        }

        return favorites;
    }

    public bool IsFavorite(string target)
    {
        using var statement = _database.Connection.Prepare(
            "SELECT 1 FROM launcher_favorites WHERE target = $target;");
        statement.BindText(1, target);
        return statement.Step();
    }

    /// <summary>收藏 / 取消；返回收藏后的状态。</summary>
    public bool Toggle(string target, string kind, string title)
    {
        if (IsFavorite(target))
        {
            using var statement = _database.Connection.Prepare(
                "DELETE FROM launcher_favorites WHERE target = $target;");
            statement.BindText(1, target);
            statement.Step();
            return false;
        }

        var position = Load().Count == 0 ? 0 : Load().Max(item => item.Position) + 1;
        using var insert = _database.Connection.Prepare(
            "INSERT OR REPLACE INTO launcher_favorites(target, kind, title, position, added_at) " +
            "VALUES ($target, $kind, $title, $position, $added);");
        insert.BindText(1, target);
        insert.BindText(2, kind);
        insert.BindText(3, title);
        insert.BindInt64(4, position);
        insert.BindInt64(5, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        insert.Step();
        return true;
    }

    /// <summary>
    /// 调顺序（Ctrl+Alt+↑↓）：和看得见的上一个 / 下一个换（藏着的收藏——这台还原不出来的——不挡着，换了看得出变化；
    /// mac swapFavorites）。visible：空查询里看得见的收藏，按顺序。换不了返回 false（调用方响一声）。
    /// </summary>
    public bool Move(string target, IReadOnlyList<string> visible, int delta)
    {
        var order = Load().Select(item => item.Target).ToList();
        if (KittyTools.Core.LauncherHome.Swap(order, visible, target, delta) is not { } swapped)
        {
            return false;
        }

        _database.BeginTransaction();
        try
        {
            for (var position = 0; position < swapped.Count; position++)
            {
                using var statement = _database.Connection.Prepare(
                    "UPDATE launcher_favorites SET position = $position WHERE target = $target;");
                statement.BindInt64(1, position);
                statement.BindText(2, swapped[position]);
                statement.Step();
            }

            _database.Commit();
        }
        catch
        {
            _database.Rollback();
            throw;
        }

        return true;
    }
}
