// 启动器的浏览器书签与浏览历史（PLAN-v9-launcher B1 B2 = PLAN-v9 V1 + REVIEW R42，照 mac Browsers / Bookmarks / BrowserHistory）：
// 只认本机装了的浏览器（用户数据目录在不在）；每家两个开关（书签、也搜浏览历史），默认书签开 Edge 和 Chrome、历史全关。
// 读都在线程池里：Chromium 的 Bookmarks 是 JSON 直接读；History、Firefox 的 places.sqlite 拷到临时目录再只读打开，读完删。
// 读完换上一份不可变的快照，回 UI 线程通知；之后按「开关 + 各文件的修改时间」判断要不要重读，没变就不读。
// 浏览历史只要「去过两次以上或手输过的」（同 mac），各家合起来按网址去重留最近的。
// 网站图标（D8）：Chromium 系的 Favicons 库也拷一份，按主机查一张 ≤ 64 的图，查过的按主机缓存（SiteIcons）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed record BrowserInfo(string Id, string Name, string Root, bool IsFirefox);

internal enum BrowserReadState
{
    Reading,
    Read,
    NoFile,
}

internal readonly record struct BrowserStatus(BrowserReadState State, int Count);

internal static class Browsers
{
    /// <summary>从没设过时书签开着的（PLAN-v9 V1：Edge 是系统自带的，Chrome 用的人最多）。</summary>
    public static readonly string[] DefaultBookmarkIds = { "edge", "chrome" };

    public static IReadOnlyList<BrowserInfo> All { get; } = Build();

    private static BrowserInfo[] Build()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return new[]
        {
            new BrowserInfo("edge", "Edge", Path.Combine(local, "Microsoft", "Edge", "User Data"), false),
            new BrowserInfo("chrome", "Chrome", Path.Combine(local, "Google", "Chrome", "User Data"), false),
            new BrowserInfo("firefox", "Firefox", Path.Combine(roaming, "Mozilla", "Firefox", "Profiles"), true),
            new BrowserInfo("brave", "Brave", Path.Combine(local, "BraveSoftware", "Brave-Browser", "User Data"), false),
            new BrowserInfo("vivaldi", "Vivaldi", Path.Combine(local, "Vivaldi", "User Data"), false),
            new BrowserInfo("opera", "Opera", Path.Combine(roaming, "Opera Software", "Opera Stable"), false),
        };
    }

    /// <summary>本机装了的（用户数据目录在）。卸载后留下的目录也会算进来——和 mac 按包名问系统不一样，ponytail：要更准再查注册表的 StartMenuInternet。</summary>
    public static List<BrowserInfo> Installed() => All.Where(browser => Directory.Exists(browser.Root)).ToList();

    public static IReadOnlyList<string> BookmarkIds(Settings settings)
        => settings.LauncherBookmarkBrowsers ?? (IReadOnlyList<string>)DefaultBookmarkIds;

    /// <summary>浏览历史开着的：书签也得开着（mac 书签关了历史那一行整个收起）。</summary>
    public static IReadOnlyList<string> HistoryIds(Settings settings)
        => (settings.LauncherHistoryBrowsers ?? new List<string>()).Where(id => BookmarkIds(settings).Contains(id)).ToList();

    /// <summary>一家的各个配置目录：Chromium 是 Default、Profile 1…（Opera 就是根目录本身），Firefox 是 Profiles 下的每一个。</summary>
    public static IEnumerable<string> Profiles(BrowserInfo browser)
    {
        if (!Directory.Exists(browser.Root))
        {
            yield break;
        }

        if (!browser.IsFirefox && File.Exists(Path.Combine(browser.Root, "Bookmarks")))
        {
            yield return browser.Root;
        }

        string[] children;
        try
        {
            children = Directory.GetDirectories(browser.Root);
        }
        catch
        {
            yield break;
        }

        foreach (var child in children)
        {
            yield return child;
        }
    }
}

internal static class BrowserIndex
{
    private sealed record Snapshot(
        IReadOnlyList<LauncherItem> Bookmarks,
        IReadOnlyList<LauncherItem> History,
        IReadOnlyDictionary<string, BrowserStatus> Status);

    private static volatile Snapshot _current = new(
        Array.Empty<LauncherItem>(), Array.Empty<LauncherItem>(), new Dictionary<string, BrowserStatus>());

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static string _signature = string.Empty;

    /// <summary>上次看文件变没变的时刻和那时的开关：开关没变时 10 分钟内不再看（Chrome 每开一个网页就改一次 History，
    /// 不拦的话每次呼出都要整个拷一遍；REVIEW R42「隔 10 分钟看一次就够」）。</summary>
    private static long _checkedAt;
    private static string _checkedIds = string.Empty;

    private const long RecheckMs = 10 * 60_000;

    /// <summary>读完换上了新的一份（在 UI 线程上发）。</summary>
    public static event Action? Changed;

    public static IReadOnlyList<LauncherItem> Bookmarks => _current.Bookmarks;

    public static IReadOnlyList<LauncherItem> History => _current.History;

    /// <summary>某家书签 / 历史读到了几条（设置页那一行说明）；没读过是 null。</summary>
    public static BrowserStatus? Status(string browserId, bool history)
        => _current.Status.TryGetValue(Key(browserId, history), out var status) ? status : null;

    /// <summary>
    /// 该重读就在线程池里读（开关变了、文件改过了）；读完换上、回 UI 线程发 Changed。返回换没换。
    /// 开关从 UI 线程取好传进来。开关没变、离上次看不到 10 分钟时直接返回（force：设置页要马上看到条数）。
    /// </summary>
    public static async Task<bool> RefreshAsync(IReadOnlyList<string> bookmarkIds, IReadOnlyList<string> historyIds, bool force = false)
    {
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var bookmarks = bookmarkIds.ToList();
        var history = historyIds.ToList();
        var ids = string.Join(',', bookmarks) + "|" + string.Join(',', history);
        var now = Environment.TickCount64;
        if (!force && ids == _checkedIds && _checkedAt != 0 && now - _checkedAt < RecheckMs)
        {
            return false;
        }

        _checkedIds = ids;
        _checkedAt = now;
        var changed = await Task.Run(async () =>
        {
            await Gate.WaitAsync().ConfigureAwait(false);
            try
            {
                var installed = Browsers.Installed();
                var signature = Signature(installed, bookmarks, history);
                if (signature == _signature)
                {
                    return false;
                }

                var started = Environment.TickCount64;
                _current = Read(installed, bookmarks, history);
                _signature = signature;
                SiteIcons.Reset(installed.Where(browser => !browser.IsFirefox && bookmarks.Contains(browser.Id)).ToList());
                Log.Info($"launcher.browsers-loaded ms={Environment.TickCount64 - started} bookmarks={_current.Bookmarks.Count} " +
                         $"history={_current.History.Count} thread={Environment.CurrentManagedThreadId}");
                return true;
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.browsers-failed {ex.GetType().Name}");
                return false;
            }
            finally
            {
                Gate.Release();
            }
        }).ConfigureAwait(false);

        if (changed)
        {
            if (dispatcher is null)
            {
                Changed?.Invoke();
            }
            else
            {
                dispatcher.TryEnqueue(() => Changed?.Invoke());
            }
        }

        return changed;
    }

    private static string Key(string browserId, bool history) => browserId + (history ? ":history" : ":bookmarks");

    /// <summary>开关 + 要读的每个文件的修改时间：都没变就不重读。</summary>
    private static string Signature(List<BrowserInfo> installed, List<string> bookmarks, List<string> history)
    {
        var builder = new System.Text.StringBuilder();
        builder.Append(string.Join(',', bookmarks)).Append('|').Append(string.Join(',', history));
        foreach (var browser in installed.Where(browser => bookmarks.Contains(browser.Id)))
        {
            foreach (var profile in Browsers.Profiles(browser))
            {
                foreach (var file in Files(browser, profile, history.Contains(browser.Id)))
                {
                    if (File.Exists(file))
                    {
                        builder.Append('|').Append(file).Append('@').Append(File.GetLastWriteTimeUtc(file).Ticks);
                    }
                }
            }
        }

        return builder.ToString();
    }

    private static IEnumerable<string> Files(BrowserInfo browser, string profile, bool history)
    {
        if (browser.IsFirefox)
        {
            yield return Path.Combine(profile, "places.sqlite");
            yield break;
        }

        yield return Path.Combine(profile, "Bookmarks");
        if (history)
        {
            yield return Path.Combine(profile, "History");
        }
    }

    private static Snapshot Read(List<BrowserInfo> installed, List<string> bookmarkIds, List<string> historyIds)
    {
        var bookmarks = new List<LauncherItem>();
        var history = new List<LauncherItem>();
        var status = new Dictionary<string, BrowserStatus>();
        foreach (var browser in installed.Where(browser => bookmarkIds.Contains(browser.Id)))
        {
            var wantsHistory = historyIds.Contains(browser.Id);
            var foundBookmarks = false;
            var foundHistory = false;
            var bookmarkCount = 0;
            var historyCount = 0;
            foreach (var profile in Browsers.Profiles(browser))
            {
                try
                {
                    if (browser.IsFirefox)
                    {
                        var places = Path.Combine(profile, "places.sqlite");
                        if (!File.Exists(places))
                        {
                            continue;
                        }

                        foundBookmarks = true;
                        foundHistory |= wantsHistory;
                        WithCopy(places, connection =>
                        {
                            bookmarkCount += ReadFirefoxBookmarks(connection, browser, bookmarks);
                            if (wantsHistory)
                            {
                                historyCount += ReadHistory(connection, browser, history, firefox: true);
                            }
                        });
                        continue;
                    }

                    var file = Path.Combine(profile, "Bookmarks");
                    if (File.Exists(file))
                    {
                        foundBookmarks = true;
                        foreach (var bookmark in ChromiumBookmarks.Parse(File.ReadAllText(file), browser.Name))
                        {
                            bookmarks.Add(Bookmark(bookmark.Title, bookmark.Url, browser));
                            bookmarkCount++;
                        }
                    }

                    var historyFile = Path.Combine(profile, "History");
                    if (wantsHistory && File.Exists(historyFile))
                    {
                        foundHistory = true;
                        WithCopy(historyFile, connection =>
                            historyCount += ReadHistory(connection, browser, history, firefox: false));
                    }
                }
                catch (Exception ex)
                {
                    Log.Warn($"launcher.browser-read-failed {browser.Id} {ex.GetType().Name}");
                }
            }

            status[Key(browser.Id, false)] = new BrowserStatus(
                foundBookmarks ? BrowserReadState.Read : BrowserReadState.NoFile, bookmarkCount);
            if (wantsHistory)
            {
                status[Key(browser.Id, true)] = new BrowserStatus(
                    foundHistory ? BrowserReadState.Read : BrowserReadState.NoFile, historyCount);
            }
        }

        var uniqueBookmarks = bookmarks
            .GroupBy(item => item.Target, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
        var uniqueHistory = history
            .GroupBy(item => item.Target, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.OrderByDescending(item => item.VisitedAt ?? 0).First())
            .OrderByDescending(item => item.VisitedAt ?? 0)
            .ToList();
        return new Snapshot(uniqueBookmarks, uniqueHistory, status);
    }

    private static LauncherItem Bookmark(string title, string url, BrowserInfo browser)
    {
        var shown = string.IsNullOrWhiteSpace(title) ? url : title;
        var pinyin = shown.Any(Pinyin.IsHan) ? Pinyin.For(shown) : null;
        return new LauncherItem
        {
            Kind = LauncherKind.Url,
            Target = url,
            Title = shown,
            Subtitle = "书签 · " + browser.Name,
            Names = new[] { LauncherMatch.Fold(shown), LauncherMatch.Fold(StripScheme(url)), pinyin?.Full }
                .Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
            Initials = new[] { LauncherMatch.Initials(shown), pinyin?.Initials }
                .Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
        };
    }

    private static int ReadFirefoxBookmarks(SqliteConnection connection, BrowserInfo browser, List<LauncherItem> into)
    {
        var count = 0;
        using var statement = connection.Prepare(
            """
            SELECT COALESCE(b.title, p.title, p.url), p.url
            FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
            WHERE b.type = 1 AND p.url IS NOT NULL
            ORDER BY b.lastModified DESC LIMIT 5000;
            """);
        while (statement.Step())
        {
            var url = statement.GetText(1);
            if (url is not null && (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                                    url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
            {
                into.Add(Bookmark(statement.GetText(0) ?? url, url, browser));
                count++;
            }
        }

        return count;
    }

    /// <summary>去过两次以上或手输过的网页（mac 同口径），最近的 3000 条；时间换成 Unix 毫秒。</summary>
    private static int ReadHistory(SqliteConnection connection, BrowserInfo browser, List<LauncherItem> into, bool firefox)
    {
        var count = 0;
        using var statement = connection.Prepare(firefox
            ? """
              SELECT url, title, last_visit_date FROM moz_places
              WHERE hidden = 0 AND (visit_count >= 2 OR typed = 1) AND last_visit_date IS NOT NULL
              ORDER BY last_visit_date DESC LIMIT 3000;
              """
            : """
              SELECT url, title, last_visit_time FROM urls
              WHERE hidden = 0 AND (visit_count >= 2 OR typed_count >= 1)
              ORDER BY last_visit_time DESC LIMIT 3000;
              """);
        while (statement.Step())
        {
            var url = statement.GetText(0);
            if (url is null || LauncherText.Host(url) is not { } host)
            {
                continue;
            }

            var title = statement.GetText(1);
            var shown = string.IsNullOrWhiteSpace(title) ? url : title;
            var raw = statement.GetInt64(2);
            // Firefox：1970 起的微秒；Chromium：1601 起的微秒。
            var visited = firefox ? raw / 1000 : raw / 1000 - 11_644_473_600_000;
            into.Add(new LauncherItem
            {
                Kind = LauncherKind.Url,
                Target = url,
                Title = shown,
                Subtitle = "历史 · " + host,
                Names = new List<string> { LauncherMatch.Fold(shown), LauncherMatch.Fold(StripScheme(url)) }.Distinct().ToList(),
                VisitedAt = visited,
            });
            count++;
        }

        return count;
    }

    /// <summary>
    /// 浏览器开着时库是锁着的、带 -wal 或 -journal：拷到临时目录再打开，读完删掉。带着回滚日志（Chromium 的 History、
    /// Favicons 用的是它）时副本要读写打开，SQLite 先按日志把写到一半的事务滚回去；只读打开会报「malformed」或不让读。
    /// </summary>
    internal static void WithCopy(string source, Action<SqliteConnection> read)
    {
        var copy = Path.Combine(Path.GetTempPath(), "kitty-browser-" + Guid.NewGuid().ToString("N"));
        try
        {
            CopyWithWal(source, copy);
            using var connection = new SqliteConnection(copy, readOnly: !File.Exists(copy + "-journal"));
            read(connection);
        }
        finally
        {
            DeleteWithWal(copy);
        }
    }

    /// <summary>SQLite 正在用的库可能带 -wal / -shm / -journal，一并拷到临时文件再读。</summary>
    internal static void CopyWithWal(string source, string target)
    {
        using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var output = File.Create(target))
        {
            input.CopyTo(output);
        }

        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
        {
            var extra = source + suffix;
            if (File.Exists(extra))
            {
                try
                {
                    using var input = new FileStream(extra, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var output = File.Create(target + suffix);
                    input.CopyTo(output);
                }
                catch
                {
                    // 拷不到就只读主库。
                }
            }
        }
    }

    internal static void DeleteWithWal(string target)
    {
        foreach (var path in new[] { target, target + "-wal", target + "-shm", target + "-journal" })
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch
            {
                // 临时文件留给系统清理。
            }
        }
    }

    private static string StripScheme(string url)
    {
        var index = url.IndexOf("://", StringComparison.Ordinal);
        var rest = index >= 0 ? url[(index + 3)..] : url;
        return rest.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? rest[4..] : rest;
    }
}

/// <summary>
/// 网站图标（D8，照 mac SiteIcons，不联网）：书签开关开着的 Chromium 系浏览器的 Favicons 库，按主机查一张最接近 32 的图；
/// 没有再退到剪贴板链接预览取到的（LinkPreviewService.IconFor）。查过的（含没找到的）按主机缓存，浏览器数据重读时清掉。
/// </summary>
internal static class SiteIcons
{
    private static readonly object Lock = new();
    private static readonly Dictionary<string, byte[]?> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static List<string> _databases = new();

    /// <summary>浏览器数据重读了：换一批要查的 Favicons 库、清掉缓存。</summary>
    public static void Reset(List<BrowserInfo> chromium)
    {
        var files = chromium
            .SelectMany(Browsers.Profiles)
            .Select(profile => Path.Combine(profile, "Favicons"))
            .Where(File.Exists)
            .ToList();
        lock (Lock)
        {
            _databases = files;
            Cache.Clear();
        }
    }

    /// <summary>
    /// 已经查过的（UI 线程上调，不碰磁盘）：浏览器图标库里有就是它；没有（或还没查过，found = false）先用剪贴板链接预览取到的
    /// （mac 的第二个来源），都没有是 null（行里用种类色块）。
    /// </summary>
    public static byte[]? Peek(string host, out bool found)
    {
        byte[]? bytes;
        lock (Lock)
        {
            found = Cache.TryGetValue(host, out bytes);
        }

        return bytes ?? LinkPreviewService.IconFor(host);
    }

    /// <summary>在线程池里查一批主机（同一轮布局报上来的攒成一批），查完回调。</summary>
    public static void Load(IReadOnlyCollection<string> hosts, Action done)
    {
        List<string> databases;
        List<string> pending;
        lock (Lock)
        {
            databases = _databases.ToList();
            pending = hosts.Where(host => !Cache.ContainsKey(host)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            foreach (var host in pending)
            {
                Cache[host] = null;
            }
        }

        if (pending.Count == 0)
        {
            return;
        }

        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _ = Task.Run(() =>
        {
            var found = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            foreach (var database in databases)
            {
                if (found.Count == pending.Count)
                {
                    break;
                }

                try
                {
                    BrowserIndex.WithCopy(database, connection =>
                    {
                        using var statement = connection.Prepare(
                            """
                            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                            WHERE m.page_url LIKE ?1 OR m.page_url LIKE ?2 OR m.page_url LIKE ?3 OR m.page_url LIKE ?4
                            ORDER BY ABS(b.width - 32) LIMIT 1;
                            """);
                        foreach (var host in pending.Where(host => !found.ContainsKey(host)))
                        {
                            statement.Reset();
                            statement.BindText(1, $"https://{host}/%").BindText(2, $"https://www.{host}/%")
                                .BindText(3, $"http://{host}/%").BindText(4, $"http://www.{host}/%");
                            if (statement.Step() && statement.GetBlob(0) is { Length: > 0 } bytes)
                            {
                                found[host] = bytes;
                            }
                        }
                    });
                }
                catch (Exception ex)
                {
                    Log.Warn($"launcher.favicons-failed {ex.GetType().Name}");
                }
            }

            lock (Lock)
            {
                foreach (var (host, bytes) in found)
                {
                    Cache[host] = bytes;
                }
            }

            if (found.Count > 0)
            {
                dispatcher?.TryEnqueue(() => done());
            }
        });
    }
}
