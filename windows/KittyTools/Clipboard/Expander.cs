// 片段粘贴 / 复制前的占位符展开（第三版 §4）：规则在 Core 的 SnippetRules；
// 这里只负责给当前时间、uid 和 {clipboard:N} 用的历史（文本条目，新→旧，最多 10 条）。
using KittyTools.Core;

namespace KittyTools;

internal static class Expander
{
    public static SnippetExpansion? Of(ClipEntry? entry, ClipboardStore? store)
    {
        if (entry is not { Snippet: true, Kind: ClipKind.Text } || string.IsNullOrEmpty(entry.Text))
        {
            return null;
        }

        var history = store?.Items
            .Where(item => item.Kind == ClipKind.Text && item.Id != entry.Id &&
                           !string.IsNullOrEmpty(item.Text))
            .Take(10)
            .Select(item => item.Text!)
            .ToList() ?? new List<string>();

        var expansion = SnippetRules.Expand(
            entry.Text!,
            DateTimeOffset.Now,
            entry.Uid ?? Guid.NewGuid().ToString("D").ToUpperInvariant(),
            clipboard: history.FirstOrDefault() ?? string.Empty,
            history);
        return expansion;
    }
}
