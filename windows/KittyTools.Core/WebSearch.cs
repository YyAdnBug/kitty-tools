// 启动器的网页搜索（纯函数，配单测）：预设同 mac，默认列表是前 8 个；
// 只有 Bing 做兜底（Windows 自带浏览器默认就是 Bing，国内也能打开），其余走关键词。
// 网址模板里的 {query} 换成编码后的搜索词。
namespace KittyTools.Core;

public sealed class SearchEngine
{
    public string Id { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    /// <summary>关键词直达；空 = 没有关键词。</summary>
    public string Keyword { get; set; } = string.Empty;

    public string UrlTemplate { get; set; } = string.Empty;

    /// <summary>没有本地结果时是否作为兜底列出来。</summary>
    public bool Fallback { get; set; }
}

public static class WebSearch
{
    public static readonly SearchEngine[] Presets =
    {
        Engine("google", "Google", "g", "https://www.google.com/search?q={query}"),
        Engine("bing", "Bing", "bing", "https://www.bing.com/search?q={query}", fallback: true),
        Engine("baidu", "百度", "bd", "https://www.baidu.com/s?wd={query}"),
        Engine("github", "GitHub", "gh", "https://github.com/search?q={query}"),
        Engine("zhihu", "知乎", "zh", "https://www.zhihu.com/search?q={query}"),
        Engine("bilibili", "哔哩哔哩", "bili", "https://search.bilibili.com/all?keyword={query}"),
        Engine("wikipedia", "维基百科", "wiki", "https://zh.wikipedia.org/w/index.php?search={query}"),
        Engine("youtube", "YouTube", "yt", "https://www.youtube.com/results?search_query={query}"),
        Engine("maps", "地图", "map", "https://www.bing.com/maps?q={query}"),
        Engine("taobao", "淘宝", "tb", "https://s.taobao.com/search?q={query}"),
        Engine("jd", "京东", "jd", "https://search.jd.com/Search?keyword={query}"),
        Engine("douban", "豆瓣", "db", "https://www.douban.com/search?q={query}"),
        Engine("mdn", "MDN", "mdn", "https://developer.mozilla.org/search?q={query}"),
    };

    /// <summary>从没存过列表时用前 8 个；只有 Bing 兜底。</summary>
    public static List<SearchEngine> Defaults()
        => Presets.Take(8).Select(engine => new SearchEngine
        {
            Id = engine.Id,
            Name = engine.Name,
            Keyword = engine.Keyword,
            UrlTemplate = engine.UrlTemplate,
            Fallback = engine.Fallback,
        }).ToList();

    /// <summary>「g swift」→ 用关键词为 g 的搜索搜 swift。关键词直达不看兜底开关。</summary>
    public static LauncherItem? KeywordItem(string query, IReadOnlyList<SearchEngine> engines)
    {
        var text = query.Trim();
        var space = text.IndexOf(' ');
        if (space <= 0 || space >= text.Length - 1)
        {
            return null;
        }

        var keyword = text[..space];
        var terms = text[(space + 1)..].Trim();
        if (terms.Length == 0)
        {
            return null;
        }

        var engine = engines.FirstOrDefault(item =>
            item.Keyword.Length > 0 && string.Equals(item.Keyword, keyword, StringComparison.OrdinalIgnoreCase));
        return engine is null ? null : Item(engine, terms);
    }

    /// <summary>没有本地结果时列在最后的网页搜索；太短的查询不列。</summary>
    public static List<LauncherItem> FallbackItems(string query, IReadOnlyList<SearchEngine> engines)
    {
        var text = query.Trim();
        return text.Length < 2
            ? new List<LauncherItem>()
            : engines.Where(engine => engine.Fallback).Select(engine => Item(engine, text)).ToList();
    }

    public static SearchEngine? Primary(IReadOnlyList<SearchEngine> engines)
        => engines.FirstOrDefault(engine => engine.Fallback) ?? engines.FirstOrDefault();

    public static string Url(SearchEngine engine, string text)
        => engine.UrlTemplate.Replace("{query}", Uri.EscapeDataString(text), StringComparison.Ordinal);

    public static LauncherItem Item(SearchEngine engine, string text) => new()
    {
        Kind = LauncherKind.Search,
        Target = Url(engine, text),
        Title = $"用 {engine.Name} 搜索「{text}」",
        Subtitle = "网页搜索",
        Completion = engine.Keyword.Length == 0 ? null : $"{engine.Keyword} {text}",
    };

    private static SearchEngine Engine(string id, string name, string keyword, string url, bool fallback = false)
        => new()
        {
            Id = id,
            Name = name,
            Keyword = keyword,
            UrlTemplate = url,
            Fallback = fallback,
        };
}
