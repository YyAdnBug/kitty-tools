// 片段占位符（第三版 §4，纯函数 + 单测）：{date} {time} {datetime} {weekday} {uuid}
// {clipboard} / {clipboard:N} {cursor}。当前时间、剪贴板文字、UUID 都由调用方给，方便单测。
// {cursor} 不产出文字，只告诉调用方粘贴后要往左挪几个字（光标之后还有多少字）。
// 边界上的意思照 mac Clipboard/Snippet.swift（REVIEW R86，2026-11-16；片段正文是同步的，两边展开结果要一样）：
// - 只认 \{(date|time|datetime|weekday|uuid|clipboard(:\d)?|cursor)\}，不分大小写；{ date }、{clipboard:12}、{clipboard:abc} 原样留着；
// - {clipboard} / {clipboard:0} = 粘贴时剪贴板里的文字；{clipboard:N}（1…9）= 历史第 N 条文字（历史跳过所有片段，取不到是空）；
// - 只认第一个 {cursor}，其余的去掉；它后面的字数按字形簇数（和 ← 一次挪一个字对应，后面有表情时不挪过头）。
using System.Globalization;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public readonly record struct SnippetExpansion(string Text, int CursorBackChars);

public static partial class SnippetRules
{
    public const int MaxCursorBackChars = 500;

    [GeneratedRegex(@"\{(date|time|datetime|weekday|uuid|clipboard(?::(\d))?|cursor)\}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();

    [GeneratedRegex(@"\{cursor\}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Cursor();

    /// <param name="clipboard">粘贴时剪贴板里的文字。</param>
    /// <param name="history">历史里的文字（新→旧、不含片段）：{clipboard:N} 取第 N 条。</param>
    public static SnippetExpansion Expand(
        string template, DateTimeOffset now, Func<string> uuid, string clipboard, IReadOnlyList<string> history)
        => Expand(template, now, uuid, () => clipboard, n => n <= history.Count ? history[n - 1] : null);

    /// <summary>不认识的写法原样留着；剪贴板、历史只在用到时才读（同 mac）。</summary>
    /// <param name="uuid">每出现一处 {uuid} 调一次：每处、每次粘贴都应该是新的（REVIEW R61）。</param>
    public static SnippetExpansion Expand(
        string template, DateTimeOffset now, Func<string> uuid, Func<string?> clipboard, Func<int, string?> history)
    {
        if (!Placeholder().IsMatch(template))
        {
            return new SnippetExpansion(template, 0);
        }

        string? cached = null;
        string Clipboard() => cached ??= clipboard() ?? string.Empty;

        string Fill(string part) => Placeholder().Replace(part, match => match.Groups[1].Value.ToLowerInvariant() switch
        {
            "date" => now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            "time" => now.ToString("HH:mm", CultureInfo.InvariantCulture),
            "datetime" => now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
            "weekday" => Weekday(now),
            "uuid" => uuid(),
            "cursor" => string.Empty,
            _ => match.Groups[2].Success && match.Groups[2].Value != "0"
                ? history(match.Groups[2].Value[0] - '0') ?? string.Empty
                : Clipboard(),
        });

        var cursor = Cursor().Match(template);
        if (!cursor.Success)
        {
            return new SnippetExpansion(Fill(template), 0);
        }

        var after = Fill(template[(cursor.Index + cursor.Length)..]);
        var back = new StringInfo(after).LengthInTextElements;
        return new SnippetExpansion(Fill(template[..cursor.Index]) + after, Math.Clamp(back, 0, MaxCursorBackChars));
    }

    private static string Weekday(DateTimeOffset now) => now.DayOfWeek switch
    {
        DayOfWeek.Monday => "星期一",
        DayOfWeek.Tuesday => "星期二",
        DayOfWeek.Wednesday => "星期三",
        DayOfWeek.Thursday => "星期四",
        DayOfWeek.Friday => "星期五",
        DayOfWeek.Saturday => "星期六",
        _ => "星期日",
    };
}

/// <summary>收藏夹的规则（纯函数 + 单测）：名字去空白、最多 24 字、不重名（不区分大小写）。</summary>
public static class ClipGroups
{
    public const int MaxNameLength = 24;

    public const int MaxCount = 200;

    public static string? Normalize(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        var trimmed = name.Trim();
        return trimmed.Length > MaxNameLength ? trimmed[..MaxNameLength] : trimmed;
    }

    public static bool IsUnique(string name, IEnumerable<string> existing, string? ignore = null)
        => !existing.Any(other =>
            !string.Equals(other, ignore, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(other, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>有收藏夹的条目一定是收藏（第三版 §4 的不变式）。</summary>
    public static bool GroupImpliesFavorite(string? groupId, bool favorite) => groupId is null || favorite;
}
