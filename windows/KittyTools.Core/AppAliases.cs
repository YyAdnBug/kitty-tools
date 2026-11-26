// 启动器的应用别名（PLAN-v18 L5 / D10，mac 外部 PR #13 a1f6e3e8 1e3131c4 38f6325e；纯函数，配单测）：设置 › 启动器 › 应用里给一个应用起
// 别名，输完整的别名时它排第一。存的键不拿 .lnk 的路径（升级时常挪）：商店应用「aumid:AUMID」，桌面应用「exe:」+ 解析出来的 exe 路径
// （折成 %ProgramFiles% 这类写法、小写），App 更新、快捷方式挪位置照样认。只跟导出导入（mac 存 bundle id，不同步）。
// PLAN-v27 B5（同 mac AppAliases）：一个应用能起几个别名（中英文逗号、分号、换行隔开），每个别名也当名字搜（打开头几个字、拼音也行），
// 原名照样能搜；存的还是一个应用一段原文，旧的一个别名就是只有一个词的那段。
namespace KittyTools.Core;

public static class AppAliases
{
    /// <summary>一个别名最长这么多字（同命令表）。</summary>
    public const int AliasLimit = LauncherCommandTable.AliasLimit;

    /// <summary>一个应用的别名那段原文最长这么多字（mac entryLimit）。</summary>
    public const int EntryLimit = 256;

    private static readonly char[] Separators = { ',', '，', ';', '；', '、', '\n', '\r' };

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

    /// <summary>一段原文里的别名（折叠、去空白、去重）；超过 32 个字的那个不算（不截断：截出来的不是用户打的那个词）。</summary>
    public static List<string> Words(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return new List<string>();
        }

        return text.Split(Separators, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => LauncherMatch.Fold(new string(part.Where(ch => !char.IsWhiteSpace(ch)).ToArray())))
            .Where(word => word.Length is > 0 and <= AliasLimit)
            .Distinct()
            .ToList();
    }

    /// <summary>输入（整句，折叠后）正好是哪个应用的别名之一：返回它的键；没有是 null。同一个别名给了几个应用时取第一个（存的顺序）。</summary>
    public static string? KeyFor(string query, IEnumerable<KeyValuePair<string, string>> aliases)
    {
        var typed = Normalized(query);
        if (typed.Length == 0)
        {
            return null;
        }

        foreach (var (key, text) in aliases)
        {
            if (Words(text).Contains(typed))
            {
                return key;
            }
        }

        return null;
    }

    /// <summary>
    /// 把这个应用的别名加进它能搜的名字（别名、中文别名的拼音全拼和首字母）；没有别名的原样返回（同一个对象）。
    /// 只扩名字，不改标题、Target（使用记录、收藏、打开照旧认原来那个应用）。
    /// </summary>
    public static LauncherItem Apply(LauncherItem item, IReadOnlyDictionary<string, string>? aliases)
    {
        if (aliases is null || item.AliasKey is not { } key || !aliases.TryGetValue(key, out var text) || Words(text) is not { Count: > 0 } words)
        {
            return item;
        }

        var names = new List<string>(item.Names);
        var initials = new List<string>(item.Initials);
        foreach (var word in words)
        {
            names.Add(word);
            if (Pinyin.For(word) is { } pinyin)
            {
                names.Add(pinyin.Full);
                initials.Add(pinyin.Initials);
            }
        }

        return item with { Names = names.Distinct().ToList(), Initials = initials.Distinct().ToList() };
    }

    /// <summary>导入：键要是 aumid: / exe: 开头、原文不超过 256 字、至少有一个认得的别名；最多 500 条。</summary>
    public static Dictionary<string, string> Sanitize(IEnumerable<KeyValuePair<string, string>> values)
        => values
            .Where(pair => (pair.Key.StartsWith("aumid:", StringComparison.Ordinal) || pair.Key.StartsWith("exe:", StringComparison.Ordinal)) &&
                           pair.Key.Length < 1024 && pair.Value.Length <= EntryLimit && Words(pair.Value).Count > 0)
            .Take(500)
            .GroupBy(pair => pair.Key)
            .ToDictionary(group => group.Key, group => group.First().Value);
}
