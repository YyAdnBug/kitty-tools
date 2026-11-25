// 文件搜索的 Windows Search SQL 生成（纯函数，配单测）：
// 用 SYSTEMINDEX 里的 System.FileName 做子串匹配，范围是整个索引里的文件（SCOPE='file:'，不含邮件这类别的协议），
// 结果按修改时间倒序；去掉系统文件夹、node_modules 这类在调用方按路径做（FileSearchFilter.IsExcluded）。
// PLAN-v6 第 4 批把 WinRT 的 StorageFile 查询换成 OLE DB，这是它的 SQL 部分；PLAN-v25 F2 起不再只查七个根目录。
// 注意：
// - 单引号要写成两个（SQL 字符串）；% _ [ 用字符类转义（REVIEW R30）；
// - System.ItemUrl 是 file:C:/Users/... 这种正斜杠形式，不是 System.ItemPathDisplay
//   （后者在本机是「C:\用户\YY\…」这种本地化显示路径，文件系统里不存在）。
namespace KittyTools.Core;

public static class FileSearchSql
{
    /// <summary>
    /// 一次最多取多少行（PLAN-v25 F4，原来 100）：按修改时间取最新的这么多条，调用方再按名字打分、截成 20 条。
    /// ponytail: 词很常见时（上万个文件名都含它）名字最像的老文件仍可能排不进来；慢了先降到 300，再慢换 CONTAINS(…"词*") OR LIKE。
    /// </summary>
    public const int DefaultLimit = 500;

    public const int MaxTokens = 4;

    public static string Build(IReadOnlyList<string> tokens, int limit = DefaultLimit)
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

        var conditions = new List<string> { "SCOPE='file:'" };
        foreach (var word in words)
        {
            conditions.Add($"System.FileName LIKE '%{EscapeLike(word)}%'");
        }

        var top = Math.Clamp(limit, 1, 1000);
        return "SELECT TOP " + top +
               " System.ItemUrl, System.FileName FROM SYSTEMINDEX WHERE " +
               string.Join(" AND ", conditions) +
               " ORDER BY System.DateModified DESC";
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

            // System.ItemUrl 不按百分号编码（实测空格就是空格），不能再 Unescape，
            // 否则文件名里本来就是「%20」的会被改成空格（REVIEW R30）。
        }

        text = text.Replace('/', '\\');
        return text.Length == 0 ? null : text;
    }

    private static string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);

    /// <summary>LIKE 里的通配符：`[` 先转义，再把 `%` / `_` 包成字符类（REVIEW R30）。</summary>
    private static string EscapeLike(string value)
        => Escape(value)
            .Replace("[", "[[]", StringComparison.Ordinal)
            .Replace("%", "[%]", StringComparison.Ordinal)
            .Replace("_", "[_]", StringComparison.Ordinal);
}
