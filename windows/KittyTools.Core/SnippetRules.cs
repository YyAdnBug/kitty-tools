// 片段占位符（第三版 §4，纯函数 + 单测）：{date} {time} {datetime} {weekday} {uuid}
// {clipboard} / {clipboard:N} {cursor}。当前时间、剪贴板文字、UUID 都由调用方给，方便单测。
// {cursor} 不产出文字，只告诉调用方粘贴后要往左挪几个字（光标之后还有多少字）。
using System.Globalization;
using System.Text;

namespace KittyTools.Core;

public readonly record struct SnippetExpansion(string Text, int CursorBackChars);

public static class SnippetRules
{
    public const int MaxCursorBackChars = 500;

    /// <summary>支持 {name} 和 {name:参数} 两种写法；不认识的占位符原样留着。</summary>
    /// <param name="uuid">每出现一处 {uuid} 调一次：每处、每次粘贴都应该是新的（REVIEW R61）。</param>
    public static SnippetExpansion Expand(
        string template,
        DateTimeOffset now,
        Func<string> uuid,
        string clipboard,
        IReadOnlyList<string> history)
    {
        var builder = new StringBuilder(template.Length + 32);
        var cursorAt = -1;
        for (var index = 0; index < template.Length; index++)
        {
            var ch = template[index];
            if (ch != '{')
            {
                builder.Append(ch);
                continue;
            }

            var close = template.IndexOf('}', index + 1);
            if (close < 0)
            {
                builder.Append(ch);
                continue;
            }

            var token = template[(index + 1)..close];
            var colon = token.IndexOf(':');
            var name = (colon < 0 ? token : token[..colon]).Trim().ToLowerInvariant();
            var argument = colon < 0 ? null : token[(colon + 1)..].Trim();
            var replaced = true;
            switch (name)
            {
                case "date":
                    builder.Append(now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
                    break;
                case "time":
                    builder.Append(now.ToString("HH:mm", CultureInfo.InvariantCulture));
                    break;
                case "datetime":
                    builder.Append(now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
                    break;
                case "weekday":
                    builder.Append(Weekday(now));
                    break;
                case "uuid":
                    builder.Append(uuid());
                    break;
                case "clipboard":
                    var depth = 0;
                    if (argument is not null && int.TryParse(argument, out var parsed) && parsed > 0)
                    {
                        depth = parsed;
                    }

                    builder.Append(ClipboardAt(depth, clipboard, history));
                    break;
                case "cursor":
                    cursorAt = builder.Length;
                    break;
                default:
                    replaced = false;
                    break;
            }

            if (replaced)
            {
                index = close;
                continue;
            }

            builder.Append(ch);
        }

        var text = builder.ToString();
        var back = cursorAt < 0 ? 0 : text.Length - cursorAt;
        return new SnippetExpansion(text, Math.Clamp(back, 0, MaxCursorBackChars));
    }

    /// <summary>{clipboard} = 现在剪贴板里的文字；{clipboard:N} = 历史里第 N 条（1 = 最近一条）。空就用最近的。</summary>
    private static string ClipboardAt(int depth, string clipboard, IReadOnlyList<string> history)
    {
        if (depth <= 1)
        {
            return string.IsNullOrEmpty(clipboard)
                ? history.FirstOrDefault() ?? string.Empty
                : clipboard;
        }

        var index = depth - 1;
        return index >= 0 && index < history.Count ? history[index] : string.Empty;
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
