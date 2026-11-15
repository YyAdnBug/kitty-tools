// 启动器收藏接进同步（PLAN-v21 第 3 批，D5：只在 Windows 之间，类别 windows-launcher；mac 的 launcher.json 不读不写——mac 收到
// 不认识的类型（设置页、系统命令）会整类停下，Windows 的应用路径在 mac 上也打不开）。规则照 mac Launcher/LauncherUsage.swift 的
// `extension LauncherUsage: SyncSource`：一个收藏一条，编号 = 类型 + 目标的哈希（同一个应用 / 网址每台都是同一个编号，不用另外去重），
// 内容是 {"kind","target","title"}（键排好序）；顺序单独一条（~order）。第一次合并在一起。落的时候按顺序那条排，不卡 8 个
// （两台同时各加一个都留着；看得见的满 8 个不让加是在 Ctrl+D 那里）；还原不出来的照旧藏着、不删（LauncherFavorites）。
// 有一条解不出来、或者编号和内容对不上（更新版本写的）整个不落。
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Sync;

/// <summary>同步里的一个收藏（Kind 是 LauncherKind 的名字，Target 是应用路径 / 设置页 id / 命令 target / 网址）。</summary>
public sealed record SyncFavorite(string Kind, string Target, string Title);

public static class LauncherFavoriteSync
{
    public const string Kind = "windows-launcher";

    /// <summary>一个收藏的编号（mac syncID：hash(kind + "\0" + target)）。</summary>
    public static string Id(string kind, string target) => CanonicalJson.Hash(kind + "\0" + target);

    public static string Encode(SyncFavorite favorite)
    {
        var builder = new StringBuilder(96);
        builder.Append("{\"kind\":");
        CanonicalJson.WriteString(favorite.Kind, builder);
        builder.Append(",\"target\":");
        CanonicalJson.WriteString(favorite.Target, builder);
        builder.Append(",\"title\":");
        CanonicalJson.WriteString(favorite.Title, builder);
        builder.Append('}');
        return builder.ToString();
    }

    /// <summary>本机那份：每个收藏一条 + 顺序（同一个编号出现两次的只留第一个）。</summary>
    public static Dictionary<string, string> Values(IEnumerable<SyncFavorite> favorites)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var favorite in favorites)
        {
            var id = Id(favorite.Kind, favorite.Target);
            if (values.TryAdd(id, Encode(favorite)))
            {
                order.Add(id);
            }
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(order);
        return values;
    }

    /// <summary>解一条（编回去一字不差、编号对得上才认）。</summary>
    public static SyncFavorite? Decode(string id, string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("target", out var target) || target.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("title", out var title) || title.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            var favorite = new SyncFavorite(kind.GetString()!, target.GetString()!, title.GetString()!);
            return favorite.Target.Length > 0 && Encode(favorite) == value && Id(favorite.Kind, favorite.Target) == id ? favorite : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>当前的收藏 + 改动 → 落下去的整张表（按顺序那条排）；解不开返回 null。</summary>
    public static List<SyncFavorite>? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<SyncFavorite> current, out string? failure)
    {
        failure = null;
        var list = new Dictionary<string, SyncFavorite>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var favorite in current)
        {
            var id = Id(favorite.Kind, favorite.Target);
            if (list.TryAdd(id, favorite))
            {
                order.Add(id);
            }
        }

        foreach (var (id, value) in changes)
        {
            if (id == SyncEngine.OrderID)
            {
                if (value is null)
                {
                    continue;
                }

                if (SyncValues.DecodeOrder(value) is not { } ids)
                {
                    failure = "启动器收藏是更新版本写的，先更新";
                    return null;
                }

                order = ids;
                continue;
            }

            if (value is null)
            {
                list.Remove(id);
                continue;
            }

            if (Decode(id, value) is not { } favorite)
            {
                failure = "启动器收藏是更新版本写的，先更新";
                return null;
            }

            list[id] = favorite;
        }

        return SyncEngine.Arranged(list.Keys, order).Select(id => list[id]).ToList();
    }
}
