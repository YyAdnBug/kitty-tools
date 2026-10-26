// 文件搜索的 Windows Search SQL 生成（纯函数，配单测）：
// 用 SYSTEMINDEX 里的 System.FileName 做过匹配、System.ItemUrl 限桌面 / 文档等根目录，
// 结果按修改时间倒序。PLAN-v6 第 4 批把 WinRT 的 StorageFile 查询换成 OLE DB，这是它的 SQL 部分。
// 注意：
// - 单引号要写成两个（SQL 字符串），其余字符原样（% 和 _ 会被当成 LIKE 通配符，搜索里无所谓）；
// - System.ItemUrl 是 file:C:/Users/... 这种正斜杠形式，不是 System.ItemPathDisplay
//   （后者在本机是「C:\用户\YY\…」这种本地化显示路径，文件系统里不存在）。
namespace KittyTools.Core;

public static class FileSearchSql
{
    /// <summary>一次最多取多少行；调用方再排序截断。</summary>
    public const int DefaultLimit = 100;

    public const int MaxTokens = 4;

    public static string Build(IReadOnlyList<string> tokens, IReadOnlyList<string> roots, int limit = DefaultLimit)
    {
        var words = tokens
            .Where(token => !string.IsNullOrWhiteSpace(token))
            .Select(token => token.Trim())
            .Take(MaxTokens)
            .ToList();
        if (words.Count == 0)
        {
            return string.Empty;
        }

        var conditions = new List<string>();
        foreach (var word in words)
        {
            conditions.Add($"System.FileName LIKE '%{Escape(word)}%'");
        }

        var rootFilter = RootFilter(roots);
        if (rootFilter.Length > 0)
        {
            conditions.Add(rootFilter);
        }

        var top = Math.Clamp(limit, 1, 1000);
        return "SELECT TOP " + top +
               " System.ItemUrl, System.FileName FROM SYSTEMINDEX WHERE " +
               string.Join(" AND ", conditions) +
               " ORDER BY System.DateModified DESC";
    }

    /// <summary>把资源管理器路径转成 SYSTEMINDEX 的 System.ItemUrl 前缀。空列表返回空串。</summary>
    public static string RootFilter(IReadOnlyList<string> roots)
    {
        var parts = new List<string>();
        foreach (var root in roots)
        {
            if (string.IsNullOrWhiteSpace(root))
            {
                continue;
            }

            var normalized = root.Trim().TrimEnd('\\', '/').Replace('\\', '/');
            if (normalized.Length == 0)
            {
                continue;
            }

            parts.Add($"System.ItemUrl LIKE '{Escape("file:" + normalized + "/")}%'");
        }

        return parts.Count == 0 ? string.Empty : "(" + string.Join(" OR ", parts) + ")";
    }

    /// <summary>System.ItemUrl（file:C:/a/b.txt）→ 本地路径（C:\a\b.txt）。</summary>
    public static string? LocalPathFromItemUrl(string? itemUrl)
    {
        if (string.IsNullOrWhiteSpace(itemUrl))
        {
            return null;
        }

        var text = itemUrl.Trim();
        if (text.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            text = text[5..];
            if (text.StartsWith("///", StringComparison.Ordinal))
            {
                // file:///C:/a/b.txt
                text = text[3..];
            }
            else if (text.StartsWith("//", StringComparison.Ordinal))
            {
                // file://server/share/path（UNC）
                text = @"\\" + text[2..];
            }
            else if (text.StartsWith('/'))
            {
                text = text[1..];
            }

            text = Uri.UnescapeDataString(text);
        }

        text = text.Replace('/', '\\');
        return text.Length == 0 ? null : text;
    }

    private static string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);
}
