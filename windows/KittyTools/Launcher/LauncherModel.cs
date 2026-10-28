// 启动器的状态和动作（PLAN-v9-launcher，照 mac LauncherModel）：查询 → 结果 → 执行。
// 空查询先列「收藏」（Ctrl+D 加，按加入顺序、Ctrl+Alt+↑↓ 调，最多 8 个），再用「常用」（全局使用分）补足到 8 行；
// 「常用」里 Ctrl+Delete 移除一项、Ctrl+Z 撤销。
// 结果顺序：cb / fy 那一行 → 直达网址 / 路径 → 计算 → 关键词搜索 → 正好是关键词的补全提示 → 本地结果（应用 + 设置页 + 内置动作
// + 系统命令 + 快捷链接 + 书签 + 用过的网址 / 文件，一起按匹配分排；同分系统命令最后）→ 浏览历史（至少 2 个字、最多 5 行、
// 和书签 / 用过的不重复）→ 拼到一半的补全提示 → 兜底搜索（只在没有本地结果时，设置里可改成总是；有直达项不兜底）。
// 「open / find 词」、空格开头搜文件，「quit / hide / forcequit / kill / port 空格」列正在运行的应用 / 后台进程 / 在监听的端口
// （都在后台列、异步到）。不可撤销的（清空回收站、注销、重启、关机、结束进程、强制退出）第一下只上膛（选中行的副标题换成
// 确认提示），同一个键再按一次才执行；打字、移动选中、Esc、收起都撤掉。打开应用 / 文件 / 网址先收起面板、再交给系统，
// 打开成功才记使用。没执行就收起的，60 秒内再呼出保留查询和选中项。Ctrl+K 的动作表在 ActionsFor（右键同一份）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

/// <summary>按住的修饰键：选中行的副标题换成它对应的替代动作。</summary>
internal enum LauncherAlternate
{
    None,
    Control,
    Alt,
    Shift,
}

internal sealed partial class LauncherModel
{
    public static LauncherModel? Instance { get; private set; }

    /// <summary>浏览历史最多列几行：排在书签后面，别把兜底搜索、补全提示挤出可见区。</summary>
    private const int HistoryLimit = 5;

    /// <summary>没执行就收起后，多久内再呼出保留查询。</summary>
    private const long KeepQueryMs = 60_000;

    private sealed record Armed(string Id, bool CommandKey, string Text);

    private readonly List<LauncherItem> _settings = SettingsPages.Items();
    private Armed? _armed;
    private (LauncherItem Item, List<LauncherUsageRow> Rows)? _forgotten;
    private bool _shown;
    private long _keptAt;
    private string _keptQuery = string.Empty;

    // 带对象模式列出来的（进模式时列一次，之后打字只过滤）；文件搜索的这一批。
    private LauncherMode _targetsMode = LauncherMode.Normal;
    private List<LauncherItem>? _targets;
    private CancellationTokenSource? _targetsCts;
    private CancellationTokenSource? _filesCts;
    private string? _filesQuery;

    // 「ip」这次呼出里的结果（收起、再呼出时全清：这期间可能换了网络）：本机那几行、两家查询服务各自查到没有、还在查的。
    private List<LauncherItem>? _ipLocal;
    private readonly Dictionary<IpService, IpLookup> _ipLookups = new();
    private readonly Dictionary<IpService, CancellationTokenSource> _ipTasks = new();

    public static LauncherModel Start()
    {
        Instance = new LauncherModel();
        return Instance;
    }

    private LauncherModel()
    {
        BrowserIndex.Changed += () => RefreshIfIdle(minLength: 2);
        if (AppCatalog.Instance is { } catalog)
        {
            catalog.Changed += () => RefreshIfIdle(minLength: 1);
        }
    }

    // ---- 面板接上的

    /// <summary>执行了东西、面板跟着收起。</summary>
    public Action HidePanel { get; set; } = () => { };

    /// <summary>Tab / 补全提示：把字填进搜索框（面板会接着调 Search）。</summary>
    public Action<string> ReplaceQuery { get; set; } = _ => { };

    /// <summary>底栏左边的就地提示（文字、按钮字、按钮动作、是不是成功的绿勾）。</summary>
    public Action<string, string?, Action?, bool> ShowBarNotice { get; set; } = (_, _, _, _) => { };

    /// <summary>读屏播报（上膛的确认提示）。</summary>
    public Action<string> Announce { get; set; } = _ => { };

    /// <summary>结果换了（异步到的进程 / 文件 / 浏览器数据，或收藏、移除之后）：面板重画，选中留在 keepId 那一项上。</summary>
    public Action<string?> ResultsChanged { get; set; } = _ => { };

    // ---- 状态

    public string Query { get; private set; } = string.Empty;

    public LauncherMode Mode { get; private set; } = LauncherMode.Normal;

    /// <summary>带对象模式 / 文件搜索里关键词后面的那段。</summary>
    public string Terms { get; private set; } = string.Empty;

    public List<LauncherItem> Results { get; private set; } = new();

    public List<LauncherGroup> Groups { get; private set; } = new();

    /// <summary>空查询时前几行是收藏（其余是常用）。</summary>
    public int FavoriteCount { get; private set; }

    /// <summary>没有结果时那一行字。</summary>
    public string EmptyText { get; private set; } = "没有匹配的结果";

    /// <summary>空查询：「收藏」+「常用」。</summary>
    public bool IsShowingHome => Mode == LauncherMode.Normal && Query.Trim().Length == 0;

    /// <summary>有查询却没有结果：显示那一行字（空查询什么都没有时连这行字都没有，同 mac）。</summary>
    public bool ShowsEmptyText => !IsShowingHome && Results.Count == 0;

    /// <summary>这次呼出里执行过会收起面板的动作：收起时不留查询。</summary>
    public bool Executed { get; private set; }

    /// <summary>用户按过 ↑↓ / 点选过：异步到的新结果按 id 保持选中项，否则回到第一行。面板设。</summary>
    public bool UserMovedSelection { get; set; }

    /// <summary>这次呼出接着上次的查询（面板把字全选：直接打字就替换）。</summary>
    public bool ResumesQuery { get; private set; }

    /// <summary>接着上次的查询时要选回的那一项。</summary>
    public string? KeptSelection { get; private set; }

    /// <summary>这一下按键是自动连发（按住不放）：确认必须是新的一下。面板在调 Execute 前设。</summary>
    public bool KeyRepeat { get; set; }

    public IReadOnlyList<SearchEngine> Engines
        => SettingsService.Current.LauncherSearchEngines ?? WebSearch.Defaults();

    // ---- 呼出 / 收起

    /// <summary>呼出前：60 秒内没执行就收起的，接着上次的查询和选中项；浏览器数据该重读就在后台读。</summary>
    public void PrepareForShow()
    {
        _shown = true;
        Executed = false;
        UserMovedSelection = false;
        LauncherOpeners.ForgetBrowsers();
        ResetIp();
        var keeps = _keptAt != 0 && Environment.TickCount64 - _keptAt <= KeepQueryMs && _keptQuery.Trim().Length > 0;
        _keptAt = 0;
        ResumesQuery = keeps;
        if (!keeps)
        {
            KeptSelection = null;
        }

        Search(keeps ? _keptQuery : string.Empty);
        var settings = SettingsService.Current;
        _ = BrowserIndex.RefreshAsync(Browsers.BookmarkIds(settings), Browsers.HistoryIds(settings));
        AppCatalog.Instance?.RefreshIfStale();
    }

    /// <summary>收起：执行过、或者查询是空的，清空；没执行就收起的留着查询和选中项。带对象模式的列表再呼出时重列。</summary>
    public void DidHide(string? selectedId)
    {
        _shown = false;
        _armed = null;
        _forgotten = null;
        _targetsCts?.Cancel();
        _filesCts?.Cancel();
        _targets = null;
        _targetsMode = LauncherMode.Normal;
        _filesQuery = null;
        ResetIp();
        if (Executed || Query.Trim().Length == 0)
        {
            _keptAt = 0;
            _keptQuery = string.Empty;
            KeptSelection = null;
        }
        else
        {
            _keptAt = Environment.TickCount64;
            _keptQuery = Query;
            KeptSelection = selectedId;
        }

        Executed = false;
    }

    /// <summary>后台换上了新的应用目录 / 浏览器数据：开着、在搜、用户还没挑过、没上膛时按新的重搜。</summary>
    private void RefreshIfIdle(int minLength)
    {
        if (_shown && !UserMovedSelection && _armed is null && Mode == LauncherMode.Normal && Query.Trim().Length >= minLength)
        {
            Search(Query);
            ResultsChanged(null);
        }
    }

    // ---- 搜索

    public void Search(string query)
    {
        Query = query;
        _armed = null;
        _forgotten = null;
        FavoriteCount = 0;
        Groups = new List<LauncherGroup>();
        var (mode, terms) = LauncherCommands.Classify(query);
        Mode = mode;
        Terms = terms;
        if (!mode.ListsProcesses() && !mode.ListsApps())
        {
            _targets = null;
            _targetsMode = LauncherMode.Normal;
            _targetsCts?.Cancel();
        }

        if (!mode.IsFileMode())
        {
            _filesCts?.Cancel();
            _filesQuery = null;
        }

        // 打字路过 ip（「iphone」）时还没查完的不要了。
        if (!LauncherIp.Matches(query))
        {
            CancelIpLookups();
        }

        if (mode.IsFileMode())
        {
            SearchFiles();
            return;
        }

        if (mode.ListsProcesses() || mode.ListsApps())
        {
            ShowTargets();
            return;
        }

        EmptyText = "没有匹配的结果";
        Results = Assemble(query);
        if (IsShowingHome)
        {
            Groups = LauncherHome.Groups(Results.Count, FavoriteCount);
        }
    }

    private List<LauncherItem> Assemble(string query)
    {
        var clipboardOn = Features.IsOn(Feature.Clipboard);
        var translateOn = Features.IsOn(Feature.Translate);
        if (translateOn && LauncherCommands.TranslateQuery(query) is { } text)
        {
            return new List<LauncherItem> { LauncherCommands.TranslateItem(text, Definition(text)) };
        }

        // 「cb 词」（带空格）只有这一行；单输 cb 时它排第一，后面照常接本地结果（mac 体检 B33）。
        if (clipboardOn && LauncherCommands.ClipQuery(query) is { } keyword && query.Trim().Length > 2)
        {
            return new List<LauncherItem> { LauncherCommands.ClipItem(keyword) };
        }

        var trimmed = query.Trim();
        if (trimmed.Length == 0)
        {
            return Home();
        }

        var engines = Engines;
        var direct = DirectItems.ItemsFor(trimmed);
        var keywordItem = WebSearch.KeywordItem(trimmed, engines);
        var prompts = WebSearch.PromptItems(trimmed, engines);
        var commandPrompts = LauncherCommands.PromptItems(trimmed);
        var top = new List<LauncherItem>();
        if (clipboardOn && LauncherCommands.ClipQuery(trimmed) is not null)
        {
            top.Add(LauncherCommands.ClipItem(string.Empty));
        }

        if (translateOn)
        {
            top.AddRange(LauncherCommands.TranslatePrompts(trimmed));
        }

        // 「ip」排在 cb / fy 后面、直达前面（mac）。
        if (LauncherIp.Matches(trimmed))
        {
            top.AddRange(IpItems());
        }

        top.AddRange(direct);
        if (Calculator.ItemFor(trimmed) is { } calculation)
        {
            top.Add(calculation);
        }

        if (keywordItem is not null)
        {
            top.Add(keywordItem);
        }

        top.AddRange(prompts.Exact);
        top.AddRange(commandPrompts.Exact);

        // 书签、浏览历史至少 2 个字才搜（1 个字母命中太多）；书签先粗筛（几千个每敲一个字都完整打分太慢）。
        var bookmarks = trimmed.Length >= 2 ? BrowserIndex.Bookmarks : (IReadOnlyList<LauncherItem>)Array.Empty<LauncherItem>();
        var tokens = LauncherMatch.Tokens(trimmed);
        var used = UsedLocations(bookmarks);
        var candidates = new List<LauncherItem>();
        if (AppCatalog.Instance is { } catalog)
        {
            candidates.AddRange(catalog.Apps);
        }

        candidates.AddRange(_settings);
        candidates.AddRange(LauncherActions.Items());
        candidates.AddRange(SystemCommands.Items());
        candidates.AddRange(WebSearch.QuicklinkItems(engines));
        candidates.AddRange(bookmarks.Where(item => LauncherMatch.MayMatch(tokens, item)));
        candidates.AddRange(used);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var local = LauncherMatch.Rank(candidates, trimmed, item =>
            LauncherUsageStore.Instance?.Boost(item, trimmed, now) ?? default);
        var history = trimmed.Length >= 2 ? Visited(trimmed, tokens, bookmarks, used, now) : new List<LauncherItem>();

        // 兜底只在没有本地结果时出现（设置里可改成总是附在最后）；已经有网址 / 路径直达项、或明写了 http(s):// 的不兜底。
        var lower = trimmed.ToLowerInvariant();
        var isExplicit = direct.Any(item => item.Kind is LauncherKind.Url or LauncherKind.Path) ||
                         lower.StartsWith("http://", StringComparison.Ordinal) ||
                         lower.StartsWith("https://", StringComparison.Ordinal);
        var wantsFallback = local.Count == 0 || SettingsService.Current.LauncherFallbackAlways;
        var fallback = keywordItem is null && wantsFallback && !isExplicit
            ? WebSearch.FallbackItems(trimmed, engines)
            : new List<LauncherItem>();

        // 直达项和书签 / 用过的网址可能是同一项：按 id 去重，留靠前的。
        var seen = new HashSet<string>();
        return top.Concat(local).Concat(history).Concat(prompts.Partial).Concat(commandPrompts.Partial).Concat(fallback)
            .Where(item => seen.Add(item.Id))
            .ToList();
    }

    /// <summary>
    /// 「ip」那几行（mac ipItems）：本机地址，再是外网地址。外网这次呼出里没查过、上次没查到的，等 0.3 s 再问（还在打字就撤掉）；
    /// 查到一家换一次那几行（可能多出一行：两家看到的不一样），选中留在原来那一项上（第一行外网的 id 不变）。
    /// </summary>
    private List<LauncherItem> IpItems()
    {
        var local = _ipLocal ??= IpAddresses.LocalItems();
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        foreach (var service in new[] { IpService.Domestic, IpService.Overseas })
        {
            if (_ipTasks.ContainsKey(service) ||
                (_ipLookups.TryGetValue(service, out var known) && known.State == IpLookupState.Found))
            {
                continue;
            }

            _ipLookups[service] = new IpLookup(IpLookupState.Pending);
            var cts = new CancellationTokenSource();
            _ipTasks[service] = cts;
            _ = Task.Run(async () =>
            {
                string? address;
                try
                {
                    await Task.Delay(LauncherIp.LookupDelayMs, cts.Token).ConfigureAwait(false);
                    address = await IpAddresses.LookUpAsync(service, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }

                dispatcher?.TryEnqueue(() =>
                {
                    if (cts.IsCancellationRequested || !_ipTasks.TryGetValue(service, out var current) || current != cts)
                    {
                        return;
                    }

                    _ipTasks.Remove(service);
                    _ipLookups[service] = address is null ? new IpLookup(IpLookupState.Failed) : new IpLookup(IpLookupState.Found, address);
                    var start = Results.FindIndex(item => item.Kind == LauncherKind.Ip);
                    if (start < 0)
                    {
                        return;
                    }

                    var rest = Results.Where(item => item.Kind != LauncherKind.Ip).ToList();
                    rest.InsertRange(Math.Min(start, rest.Count), local.Concat(LauncherIp.PublicItems(_ipLookups)));
                    Results = rest;
                    ResultsChanged(null);
                });
            });
        }

        return local.Concat(LauncherIp.PublicItems(_ipLookups)).ToList();
    }

    /// <summary>撤掉还在等 / 在查的外网查询（查到的、没查到的留着）。</summary>
    private void CancelIpLookups()
    {
        foreach (var (service, cts) in _ipTasks)
        {
            cts.Cancel();
            _ipLookups.Remove(service);
        }

        _ipTasks.Clear();
    }

    /// <summary>呼出、收起时全清：这期间可能换了网络，再输 ip 重读重查。</summary>
    private void ResetIp()
    {
        CancelIpLookups();
        _ipLookups.Clear();
        _ipLocal = null;
    }

    /// <summary>
    /// 「fy 单词」的释义（mac 体检 D10 用系统词典的第一条）：Windows 没有系统词典，取本机翻译历史 / 生词本里这个词上一次的译文
    /// （生词本里的优先）；只给「一个词」（WordLookup.IsWord，同查词模式）查，没翻过的不显示。查本机的库，几条记录，不联网。
    /// </summary>
    private static string Definition(string text)
        => WordLookup.IsWord(text) ? TranslationHistory.Instance?.LatestResult(text) ?? string.Empty : string.Empty;

    /// <summary>浏览历史里匹配上的（mac visited）：去掉已经是书签 / 用过的网址，只按名字排、不加使用分，最多 5 行；副标题拼上多久前。</summary>
    private static List<LauncherItem> Visited(
        string query, string[] tokens, IReadOnlyList<LauncherItem> bookmarks, List<LauncherItem> used, long now)
    {
        var pages = BrowserIndex.History;
        if (pages.Count == 0)
        {
            return new List<LauncherItem>();
        }

        var known = new HashSet<string>(bookmarks.Concat(used).Select(item => item.Target), StringComparer.OrdinalIgnoreCase);
        var candidates = pages.Where(page => LauncherMatch.MayMatch(tokens, page) && !known.Contains(page.Target)).ToList();
        return LauncherMatch.Rank(candidates, query)
            .Take(HistoryLimit)
            .Select(item => item with { Subtitle = LauncherText.HistorySubtitle(item.Subtitle, item.VisitedAt, now) })
            .ToList();
    }

    /// <summary>用过的网址 / 文件（mac usedLocations）：靠使用记录找回来；和书签同一网址时只留书签。</summary>
    private static List<LauncherItem> UsedLocations(IReadOnlyList<LauncherItem> bookmarks)
    {
        if (LauncherUsageStore.Instance is not { } store)
        {
            return new List<LauncherItem>();
        }

        var bookmarked = new HashSet<string>(bookmarks.Select(item => item.Target), StringComparer.OrdinalIgnoreCase);
        return store.UsedLocations()
            .Where(row => !bookmarked.Contains(row.Target))
            .Select(row => Location(LauncherUsageStore.KindFromText(row.Kind), row.Target, row.Title))
            .ToList();
    }

    /// <summary>网址 / 文件：不在任何目录里，按记下的标题还原。</summary>
    private static LauncherItem Location(LauncherKind kind, string target, string title) => new()
    {
        Kind = kind,
        Target = target,
        Title = title,
        Subtitle = LauncherText.MiddleEllipsis(target),
        Names = new List<string> { LauncherMatch.Fold(title), LauncherMatch.Fold(target) }.Distinct().ToList(),
        IsFolder = kind == LauncherKind.Path && Directory.Exists(target),
    };

    /// <summary>空查询：先收藏（藏起还原不出来的），再按全局使用分用常用补足 8 行。</summary>
    private List<LauncherItem> Home()
    {
        var store = LauncherUsageStore.Instance;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var frequent = store is null
            ? Enumerable.Empty<LauncherItem?>()
            : store.Top(64, now).Select(row => Restore(LauncherUsageStore.KindFromText(row.Kind), row.Target, row.Title));
        var (items, favoriteCount) = LauncherHome.Merge(VisibleFavorites(), frequent);
        FavoriteCount = favoriteCount;
        return items;
    }

    /// <summary>还原得出来的收藏（按顺序；还原不出来的是 null = 藏起来、不删）。</summary>
    private IEnumerable<LauncherItem?> VisibleFavorites()
    {
        if (LauncherFavorites.Instance is not { } favorites)
        {
            yield break;
        }

        foreach (var favorite in favorites.Load())
        {
            yield return Enum.TryParse<LauncherKind>(favorite.Kind, out var kind)
                ? Restore(kind, favorite.Target, favorite.Title)
                : null;
        }
    }

    private LauncherItem? Restore(LauncherKind kind, string target, string title) => kind switch
    {
        LauncherKind.App => AppCatalog.Instance?.Find(target),
        LauncherKind.Setting => SettingsPages.Find(target),
        LauncherKind.Command => SystemCommands.Find(target),
        LauncherKind.Action => LauncherActions.Find(target),
        LauncherKind.Url => Location(kind, target, title),
        LauncherKind.Path => File.Exists(target) || Directory.Exists(target) ? Location(kind, target, title) : null,
        _ => null,
    };

    // ---- 文件搜索、带对象模式（异步）

    private void SearchFiles()
    {
        var terms = Terms;
        if (LauncherCommands.IsTooShort(terms))
        {
            _filesCts?.Cancel();
            _filesQuery = null;
            Results = new List<LauncherItem>();
            EmptyText = LauncherCommands.EmptyText(Mode, terms, loading: false);
            return;
        }

        if (LauncherCommands.GroupTitle(Mode, terms) is { } title)
        {
            Groups = new List<LauncherGroup> { new(0, title) };
        }

        var key = Mode + "\n" + terms;
        if (_filesQuery == key)
        {
            return;
        }

        // 查询还在跑时留着上一次的文件结果（免得列表先空再长）。
        _filesQuery = key;
        if (Results.All(item => !item.IsFileResult))
        {
            Results = new List<LauncherItem>();
        }

        EmptyText = LauncherCommands.EmptyText(Mode, terms, loading: true);
        _filesCts?.Cancel();
        var cts = new CancellationTokenSource();
        _filesCts = cts;
        var mode = Mode;
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _ = Task.Run(async () =>
        {
            List<LauncherItem> items;
            try
            {
                // 打字时别每个字都查一遍。
                await Task.Delay(180, cts.Token);
                var paths = terms.Length == 0 ? FileSearch.Recent(20) : await FileSearch.SearchAsync(terms, cts.Token);
                items = paths.Select(FileItem).ToList();
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.files-failed {ex.GetType().Name}");
                items = new List<LauncherItem>();
            }

            dispatcher?.TryEnqueue(() =>
            {
                if (cts.IsCancellationRequested || _filesQuery != key)
                {
                    return;
                }

                ShowFiles(mode, terms, items);
                ResultsChanged(null);
            });
        });
    }

    /// <summary>文件结果到了：前面放整句（连关键词）匹配到的应用 / 内置动作（「find my」照样能打开同名的应用）；空格开头的不放。</summary>
    private void ShowFiles(LauncherMode mode, string terms, List<LauncherItem> files)
    {
        var whole = Query.Trim();
        var named = new List<LauncherItem>();
        if (terms.Length > 0 && Query.Length > 0 && !char.IsWhiteSpace(Query[0]))
        {
            var apps = new List<LauncherItem>();
            if (AppCatalog.Instance is { } catalog)
            {
                apps.AddRange(catalog.Apps);
            }

            apps.AddRange(LauncherActions.Items());
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            named = LauncherMatch.Rank(apps, whole, item => LauncherUsageStore.Instance?.Boost(item, whole, now) ?? default);
        }

        var seen = new HashSet<string>();
        Results = named.Concat(files).Where(item => seen.Add(item.Id)).ToList();
        EmptyText = LauncherCommands.EmptyText(mode, terms, loading: false);
        Groups = LauncherCommands.GroupTitle(mode, terms) is { } title && Results.Count > 0
            ? new List<LauncherGroup> { new(0, title) }
            : new List<LauncherGroup>();
    }

    /// <summary>文件搜索的一行：标题是文件名，副标题是所在文件夹（从中间截），右边写扩展名或「文件夹」。线程池里调。</summary>
    private static LauncherItem FileItem(string path)
    {
        var folder = Directory.Exists(path);
        var name = Path.GetFileName(path.TrimEnd('\\'));
        var stem = folder ? name : Path.GetFileNameWithoutExtension(name);
        var pinyin = stem.Any(Pinyin.IsHan) ? Pinyin.For(stem) : null;
        return new LauncherItem
        {
            Kind = LauncherKind.Path,
            Target = path,
            Title = name.Length > 0 ? name : path,
            Subtitle = LauncherText.MiddleEllipsis(Path.GetDirectoryName(path) ?? string.Empty),
            Names = new[] { LauncherMatch.Fold(name), pinyin?.Full }
                .Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            IsFileResult = true,
            IsFolder = folder,
        };
    }

    /// <summary>quit / hide / forcequit / kill / port：进模式时在后台列一次，之后按输入的词过滤（不加使用分）。</summary>
    private void ShowTargets()
    {
        var mode = Mode;
        if (_targets is null || _targetsMode != mode)
        {
            Results = new List<LauncherItem>();
            EmptyText = LauncherCommands.EmptyText(mode, Terms, loading: true);
            if (_targetsMode == mode && _targetsCts is { IsCancellationRequested: false })
            {
                return; // 同一个关键词还在列，等它（打字不重列）。
            }

            _targetsCts?.Cancel();
            var cts = new CancellationTokenSource();
            _targetsCts = cts;
            _targetsMode = mode;
            _targets = null;
            var foreground = (int)Foreground.PidOf(OverlayHost.PasteTarget);
            var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _ = Task.Run(() =>
            {
                List<LauncherItem> items;
                try
                {
                    var snapshot = RunningProcesses.Take(foreground);
                    items = mode switch
                    {
                        LauncherMode.Kill => RunningProcesses.KillTargets(snapshot),
                        LauncherMode.Port => RunningProcesses.PortTargets(snapshot),
                        _ => RunningProcesses.AppTargets(snapshot, mode, LauncherCommands.Keyword(mode)),
                    };
                }
                catch (Exception ex)
                {
                    Log.Warn($"launcher.targets-failed {ex.GetType().Name}");
                    items = new List<LauncherItem>();
                }

                dispatcher?.TryEnqueue(() =>
                {
                    if (cts.IsCancellationRequested || _targetsMode != mode || Mode != mode)
                    {
                        return;
                    }

                    _targets = items;
                    ShowTargets();
                    ResultsChanged(null);
                });
            });
            return;
        }

        Results = LauncherCommands.FilterTargets(_targets, mode, Terms);
        EmptyText = LauncherCommands.EmptyText(mode, Terms, loading: false);
        Groups = LauncherCommands.GroupTitle(mode, Terms) is { } title && Results.Count > 0
            ? new List<LauncherGroup> { new(0, title) }
            : new List<LauncherGroup>();
    }

    // ---- 上膛

    public bool IsArmed(LauncherItem item) => _armed?.Id == item.Id;

    /// <summary>上膛后选中行的副标题；没上膛是 null。</summary>
    public string? ArmedText(LauncherItem item) => _armed is { } armed && armed.Id == item.Id ? armed.Text : null;

    /// <summary>上膛的那一项（Ctrl+1–9 执行的不一定是选中行：面板据此先选中它，提示才看得见）。</summary>
    public string? ArmedId => _armed?.Id;

    /// <summary>移动选中、点别的行、Esc：撤掉上膛。返回刚才有没有上膛。</summary>
    public bool Disarm()
    {
        var was = _armed is not null;
        _armed = null;
        return was;
    }

    /// <summary>移动、Esc 之后不能再撤销移除常用（mac）。</summary>
    public void DropUndo() => _forgotten = null;

    /// <summary>不可撤销的：第一下只上膛（副标题换成确认提示、播报），同一行同一个键再按一次才放行；按住不放的连发不算。</summary>
    private bool Confirm(LauncherItem item, bool commandKey, string text)
    {
        var armed = new Armed(item.Id, commandKey, text);
        if (_armed == armed)
        {
            if (KeyRepeat)
            {
                return false;
            }

            _armed = null;
            return true;
        }

        _armed = armed;
        Announce(text);
        return false;
    }

    // ---- 执行

    /// <summary>执行了东西、面板跟着收起：这次的查询不留。</summary>
    private void Close()
    {
        Executed = true;
        HidePanel();
    }

    private bool InTargetMode(LauncherItem item)
        => item.Kind == LauncherKind.Process && (Mode.ListsProcesses() || Mode.ListsApps());

    /// <summary>find 搜到的文件：Enter 在资源管理器中显示、Ctrl+Enter 打开（和 open 反过来）。</summary>
    public bool RevealsOnReturn(LauncherItem item) => Mode == LauncherMode.FileFind && item.IsFileResult;

    private static bool IsStoreApp(LauncherItem item)
        => item.Target.StartsWith(@"shell:AppsFolder\", StringComparison.Ordinal);

    /// <summary>Enter。</summary>
    public void Execute(LauncherItem item)
    {
        if (InTargetMode(item))
        {
            RunTarget(item, LauncherCommands.RowMode(Mode, item.Process), commandKey: false);
            return;
        }

        switch (item.Kind)
        {
            case LauncherKind.Calculation:
                Paste(item.Payload ?? item.Title);
                break;
            case LauncherKind.Ip:
                // 外网还在查、没查到、没连上网络的那一行没有地址：只响一声。
                if (item.Payload is { } address)
                {
                    Paste(address);
                }
                else
                {
                    Beep();
                }

                break;
            case LauncherKind.Clip:
                // 先收起（还前台），再呼出剪贴板面板：它粘贴的目标才是原来那个程序，不是启动器（REVIEW R56 那一条）。
                Close();
                OverlayHost.Show(OverlayKind.Clipboard);
                OverlayHost.SetClipboardQuery(item.Target);
                break;
            case LauncherKind.Translate:
                Close();
                TranslateHost.ShowText(item.Target);
                break;
            case LauncherKind.Prompt:
                if (item.Completion is { } completion)
                {
                    ReplaceQuery(completion);
                }

                break;
            case LauncherKind.Search:
                Open(item.Target, null);
                break;
            case LauncherKind.Action:
                // 退出本 App 不记使用：不进「常用」，也不会越用越排到别的前缀查询前面（Enter 不确认）。
                if (item.Target != LauncherActions.Quit)
                {
                    Record(item);
                }

                Close();
                LauncherActions.Execute(item.Target);
                break;
            case LauncherKind.Command:
                if (SystemCommands.Confirmation(item.Target) is { } text && !Confirm(item, commandKey: false, text))
                {
                    return;
                }

                Record(item);
                Close();
                if (!SystemCommands.Execute(item.Target, out var error))
                {
                    NoticeHost.Show($"没能{item.Title}", error.Length == 0 ? "系统没有接受这个命令" : error, NoticeTone.Warning);
                }

                break;
            case LauncherKind.App:
            case LauncherKind.Path:
                if (RevealsOnReturn(item))
                {
                    Record(item);
                    Close();
                    LauncherOpeners.Reveal(item.Target);
                }
                else
                {
                    Open(item.Target, item);
                }

                break;
            case LauncherKind.Setting:
            case LauncherKind.Url:
                Open(item.Target, item);
                break;
        }
    }

    /// <summary>Ctrl+Enter（mac ⌘↩）：应用 / 文件在资源管理器中显示（find 反过来是打开）、计算只复制、网址用第二个浏览器打开；
    /// quit / hide / port 里有窗口的程序强制退出（上膛）。没有这个动作时响一声。</summary>
    public void CommandReturn(LauncherItem item)
    {
        if (InTargetMode(item))
        {
            if (CanForceQuit(item))
            {
                RunTarget(item, LauncherMode.ForceQuit, commandKey: true);
            }
            else
            {
                Beep();
            }

            return;
        }

        if (LauncherText.IsWebLink(item))
        {
            if (LauncherOpeners.OtherBrowsers().FirstOrDefault() is { } browser)
            {
                OpenWithBrowser(item, browser);
            }
            else
            {
                Beep();
            }

            return;
        }

        switch (item.Kind)
        {
            case LauncherKind.App when !IsStoreApp(item):
            case LauncherKind.Path:
                if (RevealsOnReturn(item))
                {
                    Open(item.Target, item);
                    return;
                }

                Close();
                LauncherOpeners.Reveal(item.Target);
                break;
            case LauncherKind.Calculation:
            case LauncherKind.Ip when item.Payload is not null:
                Copy(item);
                break;
            default:
                Beep();
                break;
        }
    }

    /// <summary>Ctrl+Shift+Enter：以管理员身份运行（Windows 独有，商店应用不行）。</summary>
    public void RunAsAdmin(LauncherItem item)
    {
        if (item.Kind != LauncherKind.App || IsStoreApp(item))
        {
            Beep();
            return;
        }

        var query = Query;
        Close();
        if (LauncherOpeners.Start(item.Target, "runas") is { } error)
        {
            if (error != "已取消")
            {
                NoticeHost.Show($"打不开「{item.Title}」", error, NoticeTone.Error);
            }

            return;
        }

        Record(item, query);
    }

    /// <summary>quit / hide / port 里有窗口的程序能强制退出（资源管理器不行：同 mac 的访达）。</summary>
    private bool CanForceQuit(LauncherItem item)
        => LauncherCommands.RowMode(Mode, item.Process) is LauncherMode.Quit or LauncherMode.Hide &&
           !string.Equals(item.Process?.Name, "explorer", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// 带对象模式的一行（mac runTarget）：退出（关窗口）/ 最小化 / 强制退出 / 结束进程。结束、强制退出不可撤销，先上膛
    /// （Windows 的结束进程就是硬结束，所以 kill 的 Enter 也要上膛：PLAN-v9-launcher D5）。不记使用。
    /// </summary>
    private void RunTarget(LauncherItem item, LauncherMode mode, bool commandKey)
    {
        if (item.Process is not { } process)
        {
            return;
        }

        var name = Mode == LauncherMode.Port ? process.Label : null;
        var force = mode == LauncherMode.ForceQuit || commandKey;
        if (mode == LauncherMode.Kill)
        {
            if (!Confirm(item, commandKey: false, LauncherCommands.KillConfirmation(name)))
            {
                return;
            }
        }
        else if (force)
        {
            if (!Confirm(item, commandKey, LauncherCommands.ForceQuitConfirmation(commandKey ? "Ctrl+Enter" : "Enter", name)))
            {
                return;
            }
        }

        Close();
        var error = mode == LauncherMode.Kill || force
            ? RunningProcesses.Kill(process.Pid)
            : mode == LauncherMode.Hide
                ? RunningProcesses.Minimize(process.Pid)
                : RunningProcesses.Quit(process.Pid);
        if (error is not null)
        {
            NoticeHost.Show($"没能{(mode == LauncherMode.Hide ? "最小化" : "结束")}「{process.Label}」", error, NoticeTone.Warning);
        }
        else if (mode == LauncherMode.Kill || force)
        {
            NoticeHost.Show($"已结束 {process.Label}", $"PID {process.Pid}", NoticeTone.Normal);
        }
    }

    /// <summary>打开应用 / 文件 / 网址 / 搜索页：先收起，再交给系统；打开成功才记使用（item 为 null 的搜索页不记）。</summary>
    private void Open(string target, LauncherItem? item)
    {
        var query = Query;
        Close();
        // 地图预设存的是 mac 的 maps://…，打开时换成 Windows 的地图协议（PLAN-v3 §1.5）。
        if (LauncherOpeners.Start(WebSearch.OpenUrl(target)) is { } error)
        {
            NoticeHost.Show($"打不开「{item?.Title ?? target}」", error, NoticeTone.Error);
            return;
        }

        if (item is not null)
        {
            Record(item, query);
        }
    }

    private void OpenWithBrowser(LauncherItem item, BrowserApp browser)
    {
        var query = Query;
        Close();
        if (LauncherOpeners.OpenWith(browser, item.Target) is { } error)
        {
            NoticeHost.Show($"打不开「{item.Title}」", error, NoticeTone.Error);
            return;
        }

        if (item.Kind == LauncherKind.Url)
        {
            Record(item, query);
        }
    }

    /// <summary>计算结果：收起后粘贴回原来的程序（Paster 自己收起浮层、还前台）。</summary>
    private void Paste(string text)
    {
        var target = OverlayHost.PasteTarget;
        Executed = true;
        Paster.PasteText(target, text);
        HidePanel();
    }

    private void Record(LauncherItem item, string? query = null)
        => LauncherUsageStore.Instance?.Record(item, query ?? Query, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    private static void Beep() => MessageBeep(0xFFFFFFFF);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool MessageBeep(uint type);

    /// <summary>Alt+Enter / Shift+Enter 搜的字：文件搜索去掉关键词、fy 是要翻译的那段；cb、带对象模式没有。</summary>
    private string SearchText
    {
        get
        {
            if (Features.IsOn(Feature.Translate) && LauncherCommands.TranslateQuery(Query) is { } text)
            {
                return text;
            }

            var trimmed = Query.Trim();
            if ((Features.IsOn(Feature.Clipboard) && LauncherCommands.ClipQuery(trimmed) is not null) ||
                Mode.ListsProcesses() || Mode.ListsApps())
            {
                return string.Empty;
            }

            return Mode.IsFileMode() ? Terms : trimmed;
        }
    }

    /// <summary>Alt+Enter（mac ⌥↩）：在资源管理器里搜当前的词。</summary>
    public void SearchInExplorer()
    {
        var text = SearchText;
        if (text.Length == 0)
        {
            Beep();
            return;
        }

        Close();
        LauncherOpeners.SearchInExplorer(text);
    }

    /// <summary>Shift+Enter（mac ⌃↩）：不管有没有本地结果，用第一个兜底搜索搜当前的词。</summary>
    public void SearchWeb()
    {
        var text = SearchText;
        if (text.Length == 0 || WebSearch.Primary(Engines) is not { } engine)
        {
            Beep();
            return;
        }

        Open(WebSearch.Url(engine, text), null);
    }

    private string? FinderSearchTitle => SearchText is { Length: > 0 } text ? $"在资源管理器里搜索「{text}」" : null;

    private string? WebSearchTitle
        => SearchText is { Length: > 0 } text && WebSearch.Primary(Engines) is { } engine ? $"用 {engine.Name} 搜索「{text}」" : null;

    /// <summary>Tab：把选中项（右键里是被点的那一项）补进输入框。</summary>
    public void Complete(LauncherItem item)
    {
        if (LauncherText.Completion(item) is { } text)
        {
            ReplaceQuery(text);
        }
    }

    // ---- 复制

    public enum CopyFormat
    {
        Value,
        Markdown,
        Title,
    }

    /// <summary>Ctrl+C 复制什么；内置动作、提示、cb / fy、进程、设置页没有（Ctrl+C 交给输入框）。</summary>
    public string? CopyTitle(LauncherItem item) => item.Kind switch
    {
        LauncherKind.App when !IsStoreApp(item) => "复制路径",
        LauncherKind.Path => "复制路径",
        LauncherKind.Url or LauncherKind.Search => "复制网址",
        LauncherKind.Calculation => "复制结果",
        LauncherKind.Ip when item.Payload is not null => "复制地址",
        _ => null,
    };

    /// <summary>复制路径 / 网址 / 结果（Ctrl+Enter 的计算也走这里）；网址另有 Markdown 链接、标题。面板收起，轻提示说复制了什么。</summary>
    public void Copy(LauncherItem item, CopyFormat format = CopyFormat.Value, CalcCopy? calculation = null)
    {
        var (text, title) = calculation is { } extra
            ? (extra.Text, extra.Title)
            : format switch
            {
                CopyFormat.Markdown => (LauncherText.MarkdownLink(item.Title, item.Target), "复制为 Markdown 链接"),
                CopyFormat.Title => (item.Title, "复制标题"),
                _ => (item.Payload ?? item.Target, CopyTitle(item) ?? "复制"),
            };
        if (!ClipboardWriter.WriteText(text))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着，稍后再试", NoticeTone.Error);
            return;
        }

        // 本 App 给出的新文字，同时记进剪贴板历史（mac-native §5）。
        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        Close();
        NoticeHost.Show("已" + title, LauncherText.MiddleEllipsis(text, 80), NoticeTone.Normal);
    }

    // ---- 收藏和常用

    /// <summary>能收藏的：记使用的那几类，带对象模式里的不算。</summary>
    public bool CanFavorite(LauncherItem item) => item.Kind.IsRecorded() && !Mode.ListsProcesses() && !Mode.ListsApps();

    public bool IsFavorite(LauncherItem item) => LauncherFavorites.Instance?.IsFavorite(item.Target) == true;

    /// <summary>空查询里「常用」那一组的（收藏的不算）：Ctrl+Delete 能移除。</summary>
    public bool IsCommon(LauncherItem item)
    {
        if (!IsShowingHome || !item.Kind.IsRecorded())
        {
            return false;
        }

        var index = Results.FindIndex(result => result.Id == item.Id);
        return index >= FavoriteCount;
    }

    /// <summary>Ctrl+D：加入 / 取消收藏；看得见的满 8 个时响一声 + 底栏说一声。空查询时列表跟着变，选中留在这一项上。</summary>
    public void ToggleFavorite(LauncherItem item)
    {
        if (!CanFavorite(item) || LauncherFavorites.Instance is not { } favorites)
        {
            Beep();
            return;
        }

        var adding = !favorites.IsFavorite(item.Target);
        if (adding && !LauncherHome.CanAddFavorite(VisibleFavorites().Count(favorite => favorite is not null)))
        {
            Beep();
            ShowBarNotice($"收藏最多 {LauncherHome.FavoriteLimit} 个，先取消一个", null, null, false);
            return;
        }

        favorites.Toggle(item.Target, item.Kind.ToString(), item.Title);
        ShowBarNotice(adding ? "已加入收藏" : "已取消收藏", null, null, true);
        if (IsShowingHome)
        {
            Search(Query);
            ResultsChanged(item.Id);
        }
    }

    /// <summary>Ctrl+Alt+↑↓：空查询里选中的收藏和看得见的上一个 / 下一个换位置。不是收藏时返回 false（不接这个键）。</summary>
    public bool MoveFavorite(LauncherItem item, int delta)
    {
        var index = Results.FindIndex(result => result.Id == item.Id);
        if (!IsShowingHome || index < 0 || index >= FavoriteCount || LauncherFavorites.Instance is not { } favorites)
        {
            return false;
        }

        var visible = Results.Take(FavoriteCount).Select(result => result.Target).ToList();
        if (favorites.Move(item.Target, visible, delta))
        {
            Search(Query);
            ResultsChanged(item.Id);
        }
        else
        {
            Beep();
        }

        return true;
    }

    /// <summary>「常用」里 Ctrl+Delete：忘掉这一项的使用记录，底栏「已从常用中移除 · 撤销 Ctrl+Z」。</summary>
    public void Forget(LauncherItem item)
    {
        if (!IsCommon(item) || LauncherUsageStore.Instance is not { } store)
        {
            Beep();
            return;
        }

        var rows = store.Forget(item);
        Search(Query);
        _forgotten = (item, rows);
        ResultsChanged(null);
        ShowBarNotice("已从常用中移除", "撤销 Ctrl+Z", UndoForget, false);
    }

    public bool CanUndoForget => _forgotten is not null && Query.Length == 0;

    public void UndoForget()
    {
        if (_forgotten is not { } forgotten)
        {
            return;
        }

        LauncherUsageStore.Instance?.Restore(forgotten.Rows);
        Search(Query);
        ResultsChanged(forgotten.Item.Id);
        Announce("已撤销移除");
    }

    // ---- 底栏、副标题、Ctrl+K

    /// <summary>Enter 做什么（底栏右边的主动作、Ctrl+K 第一行）：名字、图标、要不要危险色。</summary>
    public (string Title, string Glyph, bool Danger) PrimaryAction(LauncherItem item)
    {
        var confirming = _armed is { CommandKey: false } armed && armed.Id == item.Id;
        if (InTargetMode(item))
        {
            var mode = LauncherCommands.RowMode(Mode, item.Process);
            var title = LauncherCommands.VerbTitle(mode);
            var glyph = mode switch
            {
                LauncherMode.Hide => Glyphs.Minimize,
                LauncherMode.Quit => Glyphs.Close,
                _ => Glyphs.Stop,
            };
            return ((confirming ? "确认" : string.Empty) + title, glyph,
                confirming || mode is LauncherMode.Kill or LauncherMode.ForceQuit);
        }

        if (RevealsOnReturn(item))
        {
            return ("在资源管理器中显示", Glyphs.Folder, false);
        }

        var verb = PanelFooterText.LauncherVerb(item.Kind, item.Target, confirming, item.Title);
        return (verb.Text, Ui.KindTile.GlyphOf(item.Kind, item.Target), verb.Danger);
    }

    /// <summary>Ctrl+Enter 做什么；没有就是 null（网址没有第二个浏览器时也是 null：副标题不写，按了只响一声）。</summary>
    public (string Title, string Glyph, bool Danger)? CommandReturnAction(LauncherItem item)
    {
        var confirming = _armed is { CommandKey: true } armed && armed.Id == item.Id;
        if (InTargetMode(item))
        {
            return CanForceQuit(item) ? ((confirming ? "确认" : string.Empty) + "强制退出", Glyphs.Error, true) : null;
        }

        if (LauncherText.IsWebLink(item))
        {
            return LauncherOpeners.OtherBrowsers().FirstOrDefault() is { } browser
                ? ($"用「{browser.Name}」打开", Glyphs.Globe, false)
                : null;
        }

        return item.Kind switch
        {
            LauncherKind.App when !IsStoreApp(item) => ("打开文件所在位置", Glyphs.Folder, false),
            LauncherKind.Path => RevealsOnReturn(item)
                ? ("打开", Glyphs.OpenInNewWindow, false)
                : ("在资源管理器中显示", Glyphs.Folder, false),
            LauncherKind.Calculation => ("只复制，不粘贴", Glyphs.Copy, false),
            LauncherKind.Ip when item.Payload is not null => ("只复制，不粘贴", Glyphs.Copy, false),
            _ => null,
        };
    }

    /// <summary>按住修饰键时选中行的副标题：说明松手前按 Enter 会做什么；上了膛的换成确认提示。</summary>
    public string? AlternateSubtitle(LauncherItem item, LauncherAlternate alternate)
    {
        if (ArmedText(item) is { } armed)
        {
            return armed;
        }

        return alternate switch
        {
            LauncherAlternate.Control => CommandReturnAction(item) is { } action ? "Ctrl+Enter " + action.Title : null,
            LauncherAlternate.Alt => FinderSearchTitle is { } finder ? "Alt+Enter " + finder : null,
            LauncherAlternate.Shift => WebSearchTitle is { } web ? "Shift+Enter " + web : null,
            _ => null,
        };
    }

    /// <summary>
    /// 一项能做的全部动作（mac actions(for:)；右键同一份）：主动作在最前，每行写上键位，执行的和按键是同一段代码。
    /// 分节：0 打开 ｜ 1 用别的程序打开 ｜ 2 复制 ｜ 3 搜索框（补全、Alt+Enter、Shift+Enter）｜ 4 收藏、移除、回收站。
    /// </summary>
    public List<PaletteItem> ActionsFor(LauncherItem item)
    {
        var actions = new List<PaletteItem>();
        var primary = PrimaryAction(item);
        actions.Add(new PaletteItem(primary.Title, primary.Glyph, 0, () => Execute(item), "Enter", Danger: primary.Danger));
        var web = LauncherText.IsWebLink(item);
        if (!web && CommandReturnAction(item) is { } secondary)
        {
            actions.Add(new PaletteItem(secondary.Title, secondary.Glyph, 0, () => CommandReturn(item), "Ctrl+Enter",
                Danger: secondary.Danger));
        }

        if (item.Kind == LauncherKind.App && !IsStoreApp(item))
        {
            actions.Add(new PaletteItem("以管理员身份运行", Glyphs.App, 0, () => RunAsAdmin(item), "Ctrl+Shift+Enter"));
        }

        // 1 用别的程序打开：网址是默认浏览器以外的浏览器（第一个是 Ctrl+Enter），文件是系统的「打开方式」。
        if (web)
        {
            var first = true;
            foreach (var browser in LauncherOpeners.OtherBrowsers())
            {
                actions.Add(new PaletteItem($"用「{browser.Name}」打开", Glyphs.Globe, 1, () => OpenWithBrowser(item, browser),
                    first ? "Ctrl+Enter" : null));
                first = false;
            }
        }
        else if (item.Kind == LauncherKind.Path && File.Exists(item.Target))
        {
            actions.Add(new PaletteItem("打开方式…", Glyphs.OpenInNewWindow, 1, () =>
            {
                Close();
                LauncherOpeners.ShowOpenWith(item.Target);
            }));
        }

        // 2 复制（计算结果的 Ctrl+C 和 Ctrl+Enter 一样，不重复列）。
        // 计算结果、ip 的 Ctrl+C 和 Ctrl+Enter 一样，不重复列。
        if (item.Kind is not (LauncherKind.Calculation or LauncherKind.Ip) && CopyTitle(item) is { } copyTitle)
        {
            actions.Add(new PaletteItem(copyTitle, item.Kind is LauncherKind.App or LauncherKind.Path ? Glyphs.Link : Glyphs.Copy, 2,
                () => Copy(item), "Ctrl+C"));
        }

        if (web)
        {
            actions.Add(new PaletteItem("复制为 Markdown 链接", Glyphs.Code, 2, () => Copy(item, CopyFormat.Markdown), "Ctrl+Shift+C"));
            actions.Add(new PaletteItem("复制标题", Glyphs.Text, 2, () => Copy(item, CopyFormat.Title)));
        }

        if (item.Kind == LauncherKind.Calculation && Calculator.ResultFor(item.Target) is { } result)
        {
            foreach (var extra in result.Copies)
            {
                actions.Add(new PaletteItem(extra.Title, Glyphs.Copy, 2, () => Copy(item, calculation: extra), Detail: extra.Text));
            }
        }

        // 3 搜索框：提示行的主动作就是补全。
        if (item.Kind != LauncherKind.Prompt && LauncherText.Completion(item) is not null)
        {
            actions.Add(new PaletteItem("补全到搜索框", Glyphs.ChevronRight, 3, () => Complete(item), "Tab"));
        }

        if (FinderSearchTitle is { } finder)
        {
            actions.Add(new PaletteItem(finder, Glyphs.Search, 3, SearchInExplorer, "Alt+Enter"));
        }

        if (WebSearchTitle is { } webSearch)
        {
            actions.Add(new PaletteItem(webSearch, Glyphs.Globe, 3, SearchWeb, "Shift+Enter"));
        }

        // 4 收藏、移除、回收站。
        if (CanFavorite(item))
        {
            var favorite = IsFavorite(item);
            actions.Add(new PaletteItem(favorite ? "取消收藏" : "加入收藏", favorite ? Glyphs.FavoriteFilled : Glyphs.Favorite, 4,
                () => ToggleFavorite(item), "Ctrl+D"));
        }

        if (IsCommon(item))
        {
            actions.Add(new PaletteItem("从常用中移除", Glyphs.Remove, 4, () => Forget(item), "Ctrl+Delete"));
        }

        if (item.IsFileResult)
        {
            actions.Add(new PaletteItem("移到回收站", Glyphs.Delete, 4, () => MoveToRecycleBin(item), Danger: true));
        }

        return actions;
    }

    /// <summary>移到回收站（能放回，不二次确认）：轻提示说一声，结果行原地删掉。</summary>
    private void MoveToRecycleBin(LauncherItem item)
    {
        if (LauncherOpeners.Recycle(item.Target) is { } error)
        {
            NoticeHost.Show("没能移到回收站", error, NoticeTone.Error);
            return;
        }

        NoticeHost.Show($"已移到回收站「{item.Title}」", "在回收站里能还原", NoticeTone.Normal);
        Results = Results.Where(result => result.Id != item.Id).ToList();
        ResultsChanged(null);
    }
}
