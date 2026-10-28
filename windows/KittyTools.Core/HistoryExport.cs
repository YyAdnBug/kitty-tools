// 翻译历史的导出（纯函数 + 单测），照 mac HistoryStore.csv / tsv 逐条搬：两边导出来的文件一样（PLAN-v3 E2、PLAN-v9-translate B12）。
// CSV（表格）：RFC 4180，带表头，行尾 \r\n；目标语言写名字、时间写本地时间到秒；字段含逗号、引号、换行时加引号、引号双写；
// 以 = + - @ 开头的前面加 '（免得 Excel 当成公式：「-ing」会变成 #NAME?）。BOM 由调用方加（Bom，Excel 才认 UTF-8）。
// TSV（Anki 卡片：正面原文、背面译文）：#separator:tab、#html:true 两行头；字段按 HTML 写（& < > 转实体、各种换行写成 <br>、
// Tab 换空格）；以 " 或 # 开头、或含 " 的加引号、引号双写（Anki 把 # 开头的行当注释，不成对的引号会把后面几条吞成一张卡）。
using System.Globalization;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public readonly record struct HistoryRow(
    string Source,
    string Result,
    string TargetLang,
    string Service,
    long CreatedAt,
    bool Favorite);

public static partial class HistoryExport
{
    public const string Bom = "\uFEFF";

    /// <summary>导出菜单的四项（全部 / 只收藏 × CSV / TSV，mac HistoryMenu.exports）：浮窗「⋯」、历史 Ctrl+K、设置共用。</summary>
    public static readonly (bool FavoritesOnly, bool Anki)[] Choices =
    {
        (false, false), (false, true), (true, false), (true, true),
    };

    public static string ScopeTitle(bool favoritesOnly) => favoritesOnly ? "只导收藏（生词本）" : "全部历史";

    public static string FormatTitle(bool anki) => anki ? "TSV（Anki 卡片）…" : "CSV（表格）…";

    public static string FileName(bool favoritesOnly, bool anki)
        => (favoritesOnly ? "翻译收藏" : "翻译历史") + (anki ? ".tsv" : ".csv");

    public static string Csv(IReadOnlyList<HistoryRow> rows, TimeZoneInfo? timeZone = null)
    {
        var lines = new List<string> { "原文,译文,目标语言,服务,时间,收藏" };
        foreach (var row in rows)
        {
            var fields = new[]
            {
                row.Source, row.Result, Langs.FromCode(row.TargetLang)?.Title() ?? row.TargetLang, row.Service,
                Time(row.CreatedAt, timeZone), row.Favorite ? "是" : string.Empty,
            };
            lines.Add(string.Join(',', fields.Select(CsvField)));
        }

        return string.Join("\r\n", lines) + "\r\n";
    }

    public static string AnkiTsv(IReadOnlyList<HistoryRow> rows)
    {
        var lines = new List<string> { "#separator:tab", "#html:true" };
        lines.AddRange(rows.Select(row => AnkiField(row.Source) + "\t" + AnkiField(row.Result)));
        return string.Join("\n", lines) + "\n";
    }

    /// <summary>本地时间到秒（mac 同格式）。</summary>
    public static string Time(long createdAt, TimeZoneInfo? timeZone = null)
        => TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(createdAt), timeZone ?? TimeZoneInfo.Local)
            .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    private static string CsvField(string field)
    {
        if (field.Length > 0 && "=+-@".Contains(field[0]))
        {
            field = "'" + field;
        }

        return field.IndexOfAny(new[] { ',', '"', '\n', '\r' }) < 0
            ? field
            : "\"" + field.Replace("\"", "\"\"") + "\"";
    }

    private static string AnkiField(string text)
    {
        var html = text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('\t', ' ');
        html = LineBreak().Replace(html, "<br>");
        return html.StartsWith('"') || html.StartsWith('#') || html.Contains('"')
            ? "\"" + html.Replace("\"", "\"\"") + "\""
            : html;
    }

    [GeneratedRegex("\r\n|\r|\n|\u2028|\u2029")]
    private static partial Regex LineBreak();
}
