// 片段粘贴 / 复制前的占位符展开（第三版 §4）：规则在 Core 的 SnippetRules；
// 这里只负责给当前时间、uid、{clipboard} 用的剪贴板里的文字（用到才读），和 {clipboard:N} 用的历史
// （文本条目，新→旧，跳过所有片段，同 mac historyText：刚粘过的片段排在最前，不跳过会取到它自己）。
using KittyTools.Core;

namespace KittyTools;

internal static class Expander
{
    /// <summary>片段里要先问的空（PLAN-v26 C1）；不是片段、没有空的是空表。</summary>
    public static IReadOnlyList<string> InputsOf(ClipEntry? entry)
        => entry is { Snippet: true, Kind: ClipKind.Text, Text: { Length: > 0 } text } ? SnippetRules.Inputs(text) : Array.Empty<string>();

    /// <param name="inputs">填空填的字；null = 没问过（多条一起粘贴、拖出去）：{input…} 原样留着。</param>
    public static SnippetExpansion? Of(ClipEntry? entry, ClipboardStore? store, IReadOnlyDictionary<string, string>? inputs = null)
    {
        if (entry is not { Snippet: true, Kind: ClipKind.Text } || string.IsNullOrEmpty(entry.Text))
        {
            return null;
        }

        var expansion = SnippetRules.Expand(
            entry.Text!,
            DateTimeOffset.Now,
            // REVIEW R61：每处 {uuid} 现生成一个，不再是整个片段共用一个 uid。
            () => Guid.NewGuid().ToString("D").ToUpperInvariant(),
            ClipboardFormats.CurrentText,
            n => store?.Items
                .Where(item => item.Kind == ClipKind.Text && !item.Snippet && !string.IsNullOrEmpty(item.Text))
                .Skip(n - 1)
                .FirstOrDefault()?.Text,
            inputs,
            askedInputs: inputs is not null);
        return expansion;
    }
}
