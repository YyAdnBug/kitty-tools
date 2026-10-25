// 翻译历史的导出（第三版 §3.1，纯函数 + 单测）：CSV（Excel 能打开，带 BOM 由调用方加）和 Anki 用的 TSV。
// 规则照 mac 的 HistoryStore 导出：两列（原文 / 译文）加目标语言、服务、时间、是否收藏；
// 字段里有换行、逗号、引号时 CSV 用双引号包起来、内部的引号翻倍；TSV 把换行换成空格、制表符换成空格。
using System.Globalization;
using System.Text;

namespace KittyTools.Core;

public readonly record struct HistoryRow(
    string Source,
    string Result,
    string TargetLang,
    string Service,
    long CreatedAt,
    bool Favorite);

public static class HistoryExport
{
    public static string Csv(IReadOnlyList<HistoryRow> rows)
    {
        var builder = new StringBuilder();
        builder.AppendLine("原文,译文,目标语言,服务,时间,收藏");
        foreach (var row in rows)
        {
            builder.Append(Quote(row.Source)).Append(',')
                .Append(Quote(row.Result)).Append(',')
                .Append(Quote(row.TargetLang)).Append(',')
                .Append(Quote(row.Service)).Append(',')
                .Append(Quote(Time(row.CreatedAt))).Append(',')
                .Append(row.Favorite ? "是" : string.Empty)
                .AppendLine();
        }

        return builder.ToString();
    }

    public static string AnkiTsv(IReadOnlyList<HistoryRow> rows)
    {
        var builder = new StringBuilder();
        foreach (var row in rows)
        {
            builder.Append(OneLine(row.Source)).Append('\t')
                .Append(OneLine(row.Result)).Append('\t')
                .Append(row.Favorite ? "收藏" : string.Empty)
                .AppendLine();
        }

        return builder.ToString();
    }

    public static string Time(long createdAt)
        => DateTimeOffset.FromUnixTimeMilliseconds(createdAt).ToLocalTime()
            .ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);

    private static string Quote(string? value)
    {
        var text = value ?? string.Empty;
        return text.IndexOfAny(new[] { ',', '"', '\n', '\r' }) < 0
            ? text
            : '"' + text.Replace("\"", "\"\"") + '"';
    }

    private static string OneLine(string? value)
        => (value ?? string.Empty).Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ').Trim();
}
