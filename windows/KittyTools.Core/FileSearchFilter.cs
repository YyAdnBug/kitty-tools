// 启动器文件搜索的路径过滤和查询词清洗（PLAN-v25 F3、§5 第 1 批第 2 条；纯函数，配单测）。
// 索引（SYSTEMINDEX）和 Everything 两条路、服务关着时的扫目录共用这一份：
// - IsExcluded：系统文件夹、开始菜单的快捷方式、点开头的文件夹、依赖 / 构建目录里的东西不要（照 mac FileSearch.excludedFolders，
//   mac 另外靠 Spotlight 不收隐藏文件和 ~/Library；Windows 的索引和 Everything 都收，所以按路径挡）；
// - Tokens：按空白切、去掉文件名里不可能有的字符（\ / : * ? " < > |）——它们在 Everything 里是语法、在 SQL 里要转义，
//   而且任何文件名都不含它们，去掉不会少结果；
// - TopmostFolders：扫目录前去掉被别的根包含的根（OneDrive 备份了桌面时，桌面就在 OneDrive 里面，不用扫两遍）；
// - CrawlUrl：问 Windows 搜索「这个位置在不在索引里」用的写法（file:///D:\）。
namespace KittyTools.Core;

public static class FileSearchFilter
{
    /// <summary>路径上有这些目录的不要（不分大小写，任何一层）。最后一段（文件 / 文件夹本身）不算：叫 build 的文件夹本身照样搜得到。</summary>
    public static readonly IReadOnlySet<string> ExcludedFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        // Windows 的
        "AppData", "$Recycle.Bin", "System Volume Information",
        // 同 mac FileSearch.excludedFolders：常见的依赖和构建产物目录
        "node_modules", "bower_components", "DerivedData", "build", "dist", "target", "out", "Pods",
        "Carthage", "vendor", "venv", "__pycache__", "coverage",
    };

    /// <summary>直接在盘根下时不要的（任何盘）。</summary>
    private static readonly IReadOnlySet<string> RootFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "Program Files", "Program Files (x86)",
    };

    /// <summary>直接在系统盘根下时不要的。</summary>
    private static readonly IReadOnlySet<string> SystemRootFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "Windows", "ProgramData",
    };

    private static readonly char[] Forbidden = { '\\', '/', ':', '*', '?', '"', '<', '>', '|' };

    /// <summary>
    /// 这条结果要不要去掉。path：本地路径（C:\a\b.txt，UNC 也行）；systemDrive：系统盘（「C:」或「C:\」，大小写随意）。
    /// </summary>
    public static bool IsExcluded(string path, string systemDrive)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return true;
        }

        var parts = path.Replace('/', '\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            return false; // 盘根本身（C:）不算排除；Everything 会把盘当一条结果，调用方另外丢
        }

        var drive = parts[0];
        var system = systemDrive.TrimEnd('\\', '/');
        var folders = parts.AsSpan(1, parts.Length - 2); // 去掉盘和最后一段
        var top = parts.Length > 2 ? parts[1] : null;     // 盘根下那一层（本身就是最后一段时不算）
        if (top is not null && drive.EndsWith(':') &&
            (RootFolders.Contains(top) || (drive.Equals(system, StringComparison.OrdinalIgnoreCase) && SystemRootFolders.Contains(top))))
        {
            return true;
        }

        foreach (var folder in folders)
        {
            if (folder.StartsWith('.') || ExcludedFolders.Contains(folder))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>扫目录时这个文件夹进不进（只看名字：点开头的、ExcludedFolders 里的不进）。</summary>
    public static bool SkipsFolder(string name) => name.StartsWith('.') || ExcludedFolders.Contains(name);

    /// <summary>查询词：按空白切、去掉文件名里不可能有的字符、去空，最多 FileSearchSql.MaxTokens 个。</summary>
    public static List<string> Tokens(string query)
    {
        var tokens = new List<string>();
        foreach (var raw in query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var token = raw.IndexOfAny(Forbidden) < 0 ? raw : string.Concat(raw.Split(Forbidden));
            if (token.Length > 0)
            {
                tokens.Add(token);
                if (tokens.Count == FileSearchSql.MaxTokens)
                {
                    break;
                }
            }
        }

        return tokens;
    }

    /// <summary>去掉被列表里别的路径包含的（和重复的），保持原来的先后。</summary>
    public static List<string> TopmostFolders(IEnumerable<string> folders)
    {
        var list = folders
            .Where(folder => !string.IsNullOrWhiteSpace(folder))
            .Select(folder => folder.TrimEnd('\\', '/'))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        return list
            .Where(folder => !list.Any(other => !ReferenceEquals(other, folder) &&
                                                folder.StartsWith(other + "\\", StringComparison.OrdinalIgnoreCase)))
            .ToList();
    }

    /// <summary>ISearchCrawlScopeManager 认的 URL：file:///D:\Work\（结尾带反斜杠）。</summary>
    public static string CrawlUrl(string folder) => "file:///" + folder.TrimEnd('\\', '/').Replace('/', '\\') + "\\";
}
