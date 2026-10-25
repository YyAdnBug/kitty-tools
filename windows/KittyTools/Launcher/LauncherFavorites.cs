// 启动器收藏（第三版 §6）：launcher_favorites，按 position 排；Ctrl+D 收藏 / 取消，Ctrl+Alt+↑↓ 调顺序。
// 空查询时收藏排在「常用」前面。目标用 Target（应用路径 / 设置页 id / 命令 target），Kind 记类型，重建时能认出。
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

    /// <summary>调顺序：把 target 往 delta 方向移（-1 上、+1 下），重排后写回 position。</summary>
    public void Move(string target, int delta)
    {
        var ordered = Load();
        var index = ordered.FindIndex(item => item.Target == target);
        if (index < 0)
        {
            return;
        }

        var next = Math.Clamp(index + delta, 0, ordered.Count - 1);
        if (next == index)
        {
            return;
        }

        var moved = ordered[index];
        ordered.RemoveAt(index);
        ordered.Insert(next, moved);
        for (var position = 0; position < ordered.Count; position++)
        {
            using var statement = _database.Connection.Prepare(
                "UPDATE launcher_favorites SET position = $position WHERE target = $target;");
            statement.BindInt64(1, position);
            statement.BindText(2, ordered[position].Target);
            statement.Step();
        }
    }
}
