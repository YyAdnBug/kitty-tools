// 启动器的网页搜索与快捷链接（纯函数，配单测）：预设同 mac，默认列表是前 8 个；
// 只有 Bing 做兜底（Windows 自带浏览器默认就是 Bing，国内也能打开），其余走关键词。
// 网址模板里的 {query} 换成编码后的搜索词。没有 {query} 的是快捷链接（mac Quicklinks）：按名字 / 关键词 / 拼音搜到，
// Enter 打开固定网址（也可以是路径），和书签一样记使用。兜底可以开好几个（每条一个开关，PLAN-v9-launcher B6）；
// 单输关键词或名字的开头时出「Enter 补全关键词」的提示（mac WebSearch.promptItems）。
namespace KittyTools.Core;

public sealed class SearchEngine
{
    public string Id { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    /// <summary>关键词直达；空 = 没有关键词。</summary>
    public string Keyword { get; set; } = string.Empty;

    public string UrlTemplate { get; set; } = string.Empty;

    /// <summary>没有本地结果时是否作为兜底列出来（mac 的 enabled）；快捷链接不看它。</summary>
    public bool Fallback { get; set; }

    /// <summary>网址里没有 {query}：快捷链接。</summary>
    public bool IsQuicklink => !UrlTemplate.Contains("{query}", StringComparison.Ordinal);
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
        Engine("maps", "地图", "map", "maps://?q={query}"),
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
            !item.IsQuicklink && item.Keyword.Length > 0 &&
            string.Equals(item.Keyword, keyword, StringComparison.OrdinalIgnoreCase));
        return engine is null ? null : Item(engine, terms);
    }

    /// <summary>没有本地结果时列在最后的网页搜索；太短的查询不列。</summary>
    public static List<LauncherItem> FallbackItems(string query, IReadOnlyList<SearchEngine> engines)
    {
        var text = query.Trim();
        return text.Length < 2
            ? new List<LauncherItem>()
            : engines.Where(engine => engine.Fallback && !engine.IsQuicklink).Select(engine => Item(engine, text)).ToList();
    }

    /// <summary>Shift+Enter 用的：第一个兜底搜索，没有就第一个搜索（快捷链接不算）。</summary>
    public static SearchEngine? Primary(IReadOnlyList<SearchEngine> engines)
        => engines.FirstOrDefault(engine => engine.Fallback && !engine.IsQuicklink) ??
           engines.FirstOrDefault(engine => !engine.IsQuicklink);

    /// <summary>
    /// 快捷链接：和应用、书签一起参与匹配排序（Enter 打开、记使用）。网址是 C:\ 这类路径、\\ 共享、%变量% 开头的算路径。
    /// </summary>
    public static List<LauncherItem> QuicklinkItems(IReadOnlyList<SearchEngine> engines)
    {
        var items = new List<LauncherItem>();
        foreach (var engine in engines.Where(engine => engine.IsQuicklink))
        {
            var target = engine.UrlTemplate.Trim();
            var isPath = IsPathLink(target);
            if (isPath)
            {
                target = Environment.ExpandEnvironmentVariables(target);
            }

            var pinyin = Pinyin.For(engine.Name);
            items.Add(new LauncherItem
            {
                Kind = isPath ? LauncherKind.Path : LauncherKind.Url,
                Target = target,
                Title = engine.Name,
                Subtitle = engine.Keyword.Length == 0 ? engine.UrlTemplate.Trim() : $"{engine.Keyword} · {engine.UrlTemplate.Trim()}",
                Names = new[] { engine.Name, engine.Keyword, pinyin?.Full }
                    .Where(name => !string.IsNullOrEmpty(name)).Select(name => LauncherMatch.Fold(name!)).Distinct().ToList(),
                Initials = new[] { LauncherMatch.Initials(engine.Name), pinyin?.Initials }
                    .Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            });
        }

        return items;
    }

    /// <summary>快捷链接的网址其实是路径：C:\…、C:/…、\\服务器\共享、%环境变量%…（不含 ://）。</summary>
    public static bool IsPathLink(string target)
        => !target.Contains("://", StringComparison.Ordinal) &&
           (target.StartsWith(@"\\", StringComparison.Ordinal) || target.StartsWith('%') ||
            (target.Length >= 3 && char.IsAsciiLetter(target[0]) && target[1] == ':' && target[2] is '\\' or '/'));

    /// <summary>
    /// 有关键词的搜索的补全提示（Enter / Tab 补「关键词 」）：查询正好是关键词（Exact，放最前），
    /// 或是名字 / 拼音的开头（≥ 2 个字，Partial，放本地结果后面，免得「goo」「git」抢了 Chrome、GitHub Desktop）。
    /// </summary>
    public static (List<LauncherItem> Exact, List<LauncherItem> Partial) PromptItems(
        string query, IReadOnlyList<SearchEngine> engines)
    {
        var folded = LauncherMatch.Fold(query.Trim());
        var exact = new List<LauncherItem>();
        var partial = new List<LauncherItem>();
        foreach (var engine in engines.Where(engine => !engine.IsQuicklink && engine.Keyword.Length > 0))
        {
            var item = new LauncherItem
            {
                Kind = LauncherKind.Prompt,
                Target = engine.Id,
                Title = $"用 {engine.Name} 搜索…",
                Subtitle = $"输入「{engine.Keyword} 空格 内容」，Enter 或 Tab 补全关键词",
                Completion = engine.Keyword + " ",
            };
            var names = new[] { engine.Name, Pinyin.For(engine.Name)?.Full }
                .Where(name => !string.IsNullOrEmpty(name)).Select(name => LauncherMatch.Fold(name!));
            if (folded == LauncherMatch.Fold(engine.Keyword))
            {
                exact.Add(item);
            }
            else if (folded.Length >= 2 && names.Any(name => name.StartsWith(folded, StringComparison.Ordinal)))
            {
                partial.Add(item);
            }
        }

        return (exact, partial);
    }

    /// <summary>关键词不能用的（值是设置里提示的占用者）：cb 剪贴板、fy 翻译、open / find 文件搜索、quit 这些系统命令。</summary>
    public static readonly IReadOnlyDictionary<string, string> ReservedKeywords = new Dictionary<string, string>
    {
        ["cb"] = "剪贴板指令",
        ["fy"] = "翻译",
        ["open"] = "文件搜索",
        ["find"] = "文件搜索",
        ["quit"] = "系统命令",
        ["hide"] = "系统命令",
        ["forcequit"] = "系统命令",
        ["kill"] = "系统命令",
        ["port"] = "系统命令",
    };

    /// <summary>设置里一行的名字（没填名称写「未命名」）。</summary>
    public static string Title(SearchEngine engine) => engine.Name.Trim() is { Length: > 0 } name ? name : "未命名";

    /// <summary>没问题时那一行的说明（mac kindTitle）：行上开关的含义也靠它。</summary>
    public static string KindTitle(SearchEngine engine)
        => engine.IsQuicklink ? "快捷链接" : engine.Fallback ? "搜索 · 没有本地结果时兜底" : "搜索 · 只用关键词";

    /// <summary>预置的（「+」里能加回来，删除不用确认）。</summary>
    public static bool IsPreset(string id) => Presets.Any(preset => preset.Id == id);

    /// <summary>
    /// 一条有什么问题（mac SearchEngineDetail.problem，设置里橙字写出来）：没名称、网址不完整、关键词留给别的指令、
    /// 关键词和前面的重复（用的是靠前的那个）、没关键词又不兜底（用不上）；没问题是 null。
    /// </summary>
    public static string? Problem(SearchEngine engine, IReadOnlyList<SearchEngine> list)
    {
        if (engine.Name.Trim().Length == 0)
        {
            return "还没填名称";
        }

        var url = engine.UrlTemplate.Trim();
        var hasScheme = Uri.TryCreate(url.Replace("{query}", "q", StringComparison.Ordinal), UriKind.Absolute, out var parsed) &&
                        parsed.Scheme.Length > 1 &&
                        (parsed.Scheme is not ("http" or "https") || parsed.Host.Length > 0);
        if (!hasScheme && !(engine.IsQuicklink && IsPathLink(url)))
        {
            return "网址不完整";
        }

        var keyword = engine.Keyword.Trim().ToLowerInvariant();
        if (ReservedKeywords.TryGetValue(keyword, out var owner))
        {
            return $"关键词「{keyword}」留给{owner}";
        }

        if (!engine.IsQuicklink && keyword.Length > 0)
        {
            var index = list.ToList().FindIndex(item => item.Id == engine.Id);
            var earlier = index < 0
                ? null
                : list.Take(index).FirstOrDefault(item => !item.IsQuicklink && item.Keyword.Trim().ToLowerInvariant() == keyword);
            if (earlier is not null)
            {
                return $"关键词和「{Title(earlier)}」重复，用的是靠前的那个";
            }
        }

        return !engine.IsQuicklink && keyword.Length == 0 && !engine.Fallback ? "没有关键词也不兜底，用不上" : null;
    }

    public static string Url(SearchEngine engine, string text)
        => engine.UrlTemplate.Replace("{query}", Uri.EscapeDataString(text), StringComparison.Ordinal);

    /// <summary>
    /// 打开时把 mac 的 <c>maps://?q=…</c> 换成 Windows 的地图协议（PLAN-v3 §1.5：存的地址两边一字不差，
    /// 打开时各用各的）。其它网址原样返回。
    /// </summary>
    public static string OpenUrl(string url)
        => url.StartsWith("maps://?", StringComparison.OrdinalIgnoreCase)
            ? "bingmaps:?" + url["maps://?".Length..]
            : url;

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
