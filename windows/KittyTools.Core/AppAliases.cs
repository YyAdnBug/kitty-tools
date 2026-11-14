// 启动器的应用别名（PLAN-v18 L5 / D10，mac 外部 PR #13 a1f6e3e8 1e3131c4 38f6325e；纯函数，配单测）：设置 › 启动器 › 应用里给一个应用起
// 别名，输完整的别名时它排第一。存的键不拿 .lnk 的路径（升级时常挪）：商店应用「aumid:AUMID」，桌面应用「exe:」+ 解析出来的 exe 路径
// （折成 %ProgramFiles% 这类写法、小写），App 更新、快捷方式挪位置照样认。只跟导出导入（mac 存 bundle id，不同步）。
namespace KittyTools.Core;

public static class AppAliases
{
    /// <summary>别名最长这么多字（同命令表）。</summary>
    public const int AliasLimit = LauncherCommandTable.AliasLimit;

    private const string StorePrefix = @"shell:AppsFolder\";

    /// <summary>
    /// 一个应用的键：Target 是 shell:AppsFolder\AUMID 的是商店应用；不然用解析出来的 exe（.lnk 解析过的目标，直接是 exe 的就是它）。
    /// folders：（%变量%，真路径）——按长的先折；拿不到 exe 的返回 null（没法起别名）。
    /// </summary>
    public static string? Key(string target, string? exe, IReadOnlyList<(string Variable, string Path)> folders)
    {
        if (target.StartsWith(StorePrefix, StringComparison.OrdinalIgnoreCase))
        {
            var aumid = target[StorePrefix.Length..].Trim();
            return aumid.Length == 0 ? null : "aumid:" + aumid.ToLowerInvariant();
        }

        if (string.IsNullOrWhiteSpace(exe) || !exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var path = exe.Trim();
        foreach (var (variable, folder) in folders.Where(entry => entry.Path.Length > 0).OrderByDescending(entry => entry.Path.Length))
        {
            var prefix = folder.TrimEnd('\\') + "\\";
            if (path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                path = variable + "\\" + path[prefix.Length..];
                break;
            }
        }

        return "exe:" + path.ToLowerInvariant();
    }

    /// <summary>别名的写法：同命令表（去空白、折叠、最多 32 个字）。</summary>
    public static string Normalized(string alias) => LauncherCommandTable.Normalized(alias);

    /// <summary>输入（整句，折叠后）正好是哪个应用的别名：返回它的键；没有是 null。同一个别名给了几个应用时取第一个（存的顺序）。</summary>
    public static string? KeyFor(string query, IEnumerable<KeyValuePair<string, string>> aliases)
    {
        var typed = Normalized(query);
        if (typed.Length == 0)
        {
            return null;
        }

        foreach (var (key, alias) in aliases)
        {
            if (Normalized(alias) == typed)
            {
                return key;
            }
        }

        return null;
    }

    /// <summary>导入：键要是 aumid: / exe: 开头、别名不空不超长；最多 500 条。</summary>
    public static Dictionary<string, string> Sanitize(IEnumerable<KeyValuePair<string, string>> values)
        => values
            .Where(pair => (pair.Key.StartsWith("aumid:", StringComparison.Ordinal) || pair.Key.StartsWith("exe:", StringComparison.Ordinal)) &&
                           pair.Key.Length < 1024 && Normalized(pair.Value).Length > 0 && pair.Value.Length <= AliasLimit)
            .Take(500)
            .GroupBy(pair => pair.Key)
            .ToDictionary(group => group.Key, group => group.First().Value);
}
