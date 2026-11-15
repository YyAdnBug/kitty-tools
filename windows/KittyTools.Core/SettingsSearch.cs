// 设置侧栏「搜索设置」筛哪几页、停在哪一页（PLAN-v23 W4 W5，照 mac SettingsPage.matches / matching / page(for:current:)，纯函数配单测）：
// 页名或关键词包含搜的字就算对上；没添加的插件不进侧栏，但对上了它的词就算通用页对上（「功能 ›」里有它的卡）。
// 停在哪：页名包含搜的字的优先（「录」停在录制、「唤醒」停在保持唤醒），否则当前页还在结果里就不动，不在就去第一个，一页都没有也不动。
namespace KittyTools.Core;

/// <summary>侧栏的一页：标签、页名、关键词（顺序就是侧栏的顺序）。</summary>
public sealed record SettingsSearchPage(string Tag, string Title, IReadOnlyList<string> Keywords);

public static class SettingsSearch
{
    /// <summary>这一页对不对得上（空的、只有空白的算全对上）。</summary>
    public static bool Matches(SettingsSearchPage page, string query)
    {
        var text = query.Trim();
        return text.Length == 0 || page.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase) ||
               page.Keywords.Any(word => word.Contains(text, StringComparison.CurrentCultureIgnoreCase));
    }

    /// <summary>对上的页（侧栏列它们）：hidden（没添加的插件）不列，但对上了它就算通用页对上。</summary>
    public static List<string> Matching(IReadOnlyList<SettingsSearchPage> pages, string query, IReadOnlySet<string> hidden)
    {
        var wantsGeneral = pages.Any(page => hidden.Contains(page.Tag) && Matches(page, query));
        return pages
            .Where(page => !hidden.Contains(page.Tag) && (Matches(page, query) || page.Tag == "general" && wantsGeneral))
            .Select(page => page.Tag)
            .ToList();
    }

    /// <summary>搜了 query 之后停在哪一页。</summary>
    public static string PageFor(IReadOnlyList<SettingsSearchPage> pages, string query, string current, IReadOnlySet<string> hidden)
    {
        var text = query.Trim();
        var matches = Matching(pages, text, hidden);
        if (text.Length > 0 && pages.FirstOrDefault(page => matches.Contains(page.Tag) &&
                page.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase)) is { } named)
        {
            return named.Tag;
        }

        return matches.Contains(current) ? current : matches.FirstOrDefault() ?? current;
    }
}
