// 启动器的四类额外查找（第三版 §6）：
// - 文件搜索：桌面 / 文档 / 下载 / 图片 / 视频 / 音乐 / OneDrive，最多跑 1.2 秒或 6000 个候选；空查询列最近文件；
// - 进程：kill 词 → 名字 / PID / 内存；结束进程带确认，失败说原因；
// - 端口：port 词 → GetExtendedTcpTable / GetExtendedUdpTable 的监听行 + 占用进程（REVIEW R18：不再解析 netstat）；
// - 书签：Chromium 系（Chrome / Edge / Brave / Vivaldi）的 Bookmarks JSON。
// 全是后台取、结果回 UI 线程再显示；历史（History 库）这一批没做。
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class FileSearch
{
    private const int MaxCandidates = 6000;

    private static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(1200);

    public static List<string> Roots()
    {
        var roots = new List<string>();
        void Add(string? path)
        {
            if (!string.IsNullOrEmpty(path) && Directory.Exists(path))
            {
                roots.Add(path);
            }
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Add(Path.Combine(home, "Desktop"));
        Add(Path.Combine(home, "Documents"));
        Add(Path.Combine(home, "Downloads"));
        Add(Path.Combine(home, "Pictures"));
        Add(Path.Combine(home, "Videos"));
        Add(Path.Combine(home, "Music"));
        Add(Path.Combine(home, "OneDrive"));
        return roots;
    }

    public static async Task<List<string>> SearchAsync(string query, CancellationToken cancellationToken)
    {
        var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0)
        {
            return Recent(20);
        }

        var started = Stopwatch.GetTimestamp();
        var results = new List<(int Score, string Path)>();
        var usedIndexer = false;
        var forceFallback = Environment.GetEnvironmentVariable("KITTY_FS_FORCE_FALLBACK") == "1";
        var roots = Roots();

        // PLAN-v6 第 4 批：先走 OLE DB 直查 SYSTEMINDEX（毫秒级）；索引服务不可用时才退回
        // R17 的 WinRT 查询 / 扫目录。退路保留，是为了在没装搜索服务或索引被关掉的机器上还能用。
        if (!forceFallback && !cancellationToken.IsCancellationRequested)
        {
            try
            {
                var indexed = await Task.Run(() => OleDbFileSearch.Search(tokens, roots), cancellationToken);
                if (indexed is not null)
                {
                    foreach (var path in indexed)
                    {
                        var score = LauncherCommands.ScoreFileName(Path.GetFileName(path), tokens);
                        if (score != int.MinValue)
                        {
                            results.Add((score, path));
                        }
                    }

                    Log.Info($"files.search source=oledb ms={Elapsed(started):F0} hits={results.Count}");
                    return Rank(results);
                }
            }
            catch (OperationCanceledException)
            {
                return new List<string>();
            }
        }

        foreach (var root in roots)
        {
            if (forceFallback)
            {
                break;
            }
            if (cancellationToken.IsCancellationRequested || Elapsed(started) > Budget.TotalMilliseconds)
            {
                break;
            }

            try
            {
                // R17：只走 Windows 搜索索引（非打包桌面程序也能用），不自己递归目录。
                var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(root);
                var options = new Windows.Storage.Search.QueryOptions
                {
                    FolderDepth = Windows.Storage.Search.FolderDepth.Deep,
                    IndexerOption = Windows.Storage.Search.IndexerOption.OnlyUseIndexer,
                    UserSearchFilter = BuildFilter(tokens),
                };
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromMilliseconds(900));
                var files = await folder.CreateFileQueryWithOptions(options)
                    .GetFilesAsync().AsTask(timeout.Token);
                usedIndexer = true;
                foreach (var file in files)
                {
                    var score = LauncherCommands.ScoreFileName(file.Name, tokens);
                    if (score != int.MinValue)
                    {
                        results.Add((score, file.Path));
                    }
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Log.Warn($"files.index-failed {ex.GetType().Name}");
                break;
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        if (!usedIndexer && !cancellationToken.IsCancellationRequested)
        {
            // 索引服务关着：退回扫目录，但只给 300 ms、最多 6 层。
            Log.Info("files.index-fallback");
            var candidates = 0;
            var fallbackStart = Stopwatch.GetTimestamp();
            foreach (var root in roots)
            {
                foreach (var file in Walk(root, maxDepth: 6, ref candidates, cancellationToken))
                {
                    if (cancellationToken.IsCancellationRequested ||
                        Elapsed(fallbackStart) > 300 || candidates > 2000)
                    {
                        break;
                    }

                    var score = LauncherCommands.ScoreFileName(Path.GetFileName(file), tokens);
                    if (score != int.MinValue)
                    {
                        results.Add((score, file));
                    }
                }
            }
        }

        Log.Info($"files.search indexed={usedIndexer} ms={Elapsed(started):F0} hits={results.Count}");
        return Rank(results);
    }

    private static List<string> Rank(List<(int Score, string Path)> results)
        => results
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Path.Length)
            .Select(item => item.Path)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(20)
            .ToList();

    private static string BuildFilter(IReadOnlyList<string> tokens)
    {
        static string Escape(string value) => value.Replace("\"", string.Empty, StringComparison.Ordinal);
        return string.Join(" AND ",
            tokens.Select(token => $"System.FileName:*{Escape(token)}*"));
    }

    /// <summary>最近的文件：%APPDATA%\Microsoft\Windows\Recent 里的快捷方式（打开 .lnk 本身）。</summary>
    public static List<string> Recent(int limit)
    {
        try
        {
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Microsoft", "Windows", "Recent");
            if (!Directory.Exists(folder))
            {
                return new List<string>();
            }

            return Directory.EnumerateFiles(folder, "*.lnk")
                .Select(path => (Path: path, Time: File.GetLastWriteTimeUtc(path)))
                .OrderByDescending(item => item.Time)
                .Take(limit)
                .Select(item => item.Path)
                .ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    private static IEnumerable<string> Walk(
        string root, int maxDepth, ref int candidates, CancellationToken cancellationToken)
    {
        var pending = new Stack<(string Path, int Depth)>();
        pending.Push((root, 0));
        var found = new List<string>();
        while (pending.Count > 0 && !cancellationToken.IsCancellationRequested)
        {
            var (directory, depth) = pending.Pop();
            string[] files;
            try
            {
                files = Directory.GetFiles(directory);
            }
            catch
            {
                continue;
            }

            foreach (var file in files)
            {
                found.Add(file);
                candidates++;
                if (candidates >= MaxCandidates)
                {
                    break;
                }
            }

            if (depth >= maxDepth)
            {
                continue;
            }

            try
            {
                foreach (var child in Directory.GetDirectories(directory))
                {
                    var name = Path.GetFileName(child);
                    if (name.StartsWith('.') || name.Equals("node_modules", StringComparison.OrdinalIgnoreCase) ||
                        name.Equals("$Recycle.Bin", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    pending.Push((child, depth + 1));
                }
            }
            catch
            {
                // 没权限的目录跳过。
            }
        }

        return found;
    }

    private static double Elapsed(long started)
        => (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
}

internal readonly record struct ProcessRow(int Pid, string Name, long WorkingSetBytes);

internal static class ProcessSearch
{
    public static Task<List<ProcessRow>> SearchAsync(string query, CancellationToken cancellationToken)
        => Task.Run(() =>
        {
            var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var rows = new List<ProcessRow>();
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    var name = process.ProcessName;
                    if (tokens.Length > 0 &&
                        !tokens.All(token => name.Contains(token, StringComparison.OrdinalIgnoreCase) ||
                                             process.Id.ToString().Contains(token, StringComparison.Ordinal)))
                    {
                        continue;
                    }

                    rows.Add(new ProcessRow(process.Id, name, process.WorkingSet64));
                }
                catch
                {
                    // 进程刚好退出。
                }
                finally
                {
                    process.Dispose();
                }
            }

            return rows.OrderByDescending(row => row.WorkingSetBytes).Take(30).ToList();
        }, cancellationToken);

    /// <summary>结束进程；成功返回 null，失败返回给用户看的原因。</summary>
    public static string? Kill(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            process.Kill(entireProcessTree: false);
            return null;
        }
        catch (Exception ex)
        {
            return ex switch
            {
                UnauthorizedAccessException => "没有权限（可能是管理员身份运行的系统进程）",
                InvalidOperationException => "进程已经退出",
                ArgumentException => "进程不存在",
                _ => ex.GetType().Name,
            };
        }
    }
}

internal readonly record struct PortEntry(string Protocol, string Local, int Port, int Pid, string ProcessName);

internal static class PortSearch
{
    public static async Task<List<PortEntry>> SearchAsync(string query, CancellationToken cancellationToken)
    {
        var rows = await Task.Run(() => Run(query), cancellationToken);
        return rows;
    }

    private static List<PortEntry> Run(string query)
    {
        try
        {
            var rows = PortTable.Read();
            var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var names = new Dictionary<int, string>();
            return rows
                .Where(row => tokens.Length == 0 ||
                              tokens.Any(token =>
                                  row.Port.ToString().Contains(token, StringComparison.Ordinal) ||
                                  row.Local.Contains(token, StringComparison.OrdinalIgnoreCase) ||
                                  NameOf(row.Pid, names).Contains(token, StringComparison.OrdinalIgnoreCase)))
                .Select(row => new PortEntry(row.Protocol, row.Local, row.Port, row.Pid, NameOf(row.Pid, names)))
                .Take(40)
                .ToList();
        }
        catch
        {
            return new List<PortEntry>();
        }
    }

    private static string NameOf(int pid, Dictionary<int, string> cache)
    {
        if (cache.TryGetValue(pid, out var name))
        {
            return name;
        }

        try
        {
            using var process = Process.GetProcessById(pid);
            name = process.ProcessName;
        }
        catch
        {
            name = "?";
        }

        cache[pid] = name;
        return name;
    }
}

internal static class HistoryIndex
{
    /// <summary>SQLite 正在用的库可能带 -wal / -shm，一并拷到临时文件再读。</summary>
    internal static void CopyWithWal(string source, string target)
    {
        using (var input = new FileStream(source, FileMode.Open, FileAccess.Read,
                   FileShare.ReadWrite | FileShare.Delete))
        using (var output = File.Create(target))
        {
            input.CopyTo(output);
        }

        foreach (var suffix in new[] { "-wal", "-shm" })
        {
            var extra = source + suffix;
            if (File.Exists(extra))
            {
                try
                {
                    File.Copy(extra, target + suffix, overwrite: true);
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
        foreach (var path in new[] { target, target + "-wal", target + "-shm" })
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
    private static List<BookmarkItem> _items = new();
    private static bool _loaded;

    public static void Load()
    {
        if (_loaded)
        {
            return;
        }

        _loaded = true;
        var items = new List<BookmarkItem>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var browsers = new (string Name, string Folder)[]
        {
            ("Chrome", Path.Combine(local, "Google", "Chrome", "User Data")),
            ("Edge", Path.Combine(local, "Microsoft", "Edge", "User Data")),
            ("Brave", Path.Combine(local, "BraveSoftware", "Brave-Browser", "User Data")),
            ("Vivaldi", Path.Combine(local, "Vivaldi", "User Data")),
        };
        foreach (var (name, folder) in browsers)
        {
            try
            {
                if (!Directory.Exists(folder))
                {
                    continue;
                }

                foreach (var profile in Directory.EnumerateDirectories(folder))
                {
                    var history = Path.Combine(profile, "History");
                    if (!File.Exists(history))
                    {
                        continue;
                    }

                    var copy = Path.Combine(Path.GetTempPath(), "kitty-history-" + Guid.NewGuid().ToString("N"));
                    try
                    {
                        CopyWithWal(history, copy);
                        using var connection = new SqliteConnection(copy);
                        using var statement = connection.Prepare(
                            "SELECT url, title FROM urls WHERE title <> '' ORDER BY last_visit_time DESC LIMIT 300;");
                        while (statement.Step())
                        {
                            var url = statement.GetText(0);
                            var title = statement.GetText(1);
                            if (!string.IsNullOrWhiteSpace(url))
                            {
                                items.Add(new BookmarkItem(title ?? url, url, name + " 历史"));
                            }
                        }
                    }
                    finally
                    {
                        HistoryIndex.DeleteWithWal(copy);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"history.load-failed {name} {ex.GetType().Name} {ex.Message}");
            }
        }

        _items = items;
        Log.Info($"history.ready count={_items.Count}");
    }

    public static List<BookmarkItem> Search(string query, int limit = 5)
    {
        var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0)
        {
            return new List<BookmarkItem>();
        }

        return _items
            .Where(item => tokens.All(token =>
                item.Title.Contains(token, StringComparison.OrdinalIgnoreCase) ||
                item.Url.Contains(token, StringComparison.OrdinalIgnoreCase)))
            .Take(limit)
            .ToList();
    }
}

internal static class BookmarkIndex
{
    private static List<BookmarkItem> _items = new();
    private static bool _loaded;

    public static IReadOnlyList<BookmarkItem> Items => _items;

    public static void Load()
    {
        if (_loaded)
        {
            return;
        }

        _loaded = true;
        var items = new List<BookmarkItem>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var browsers = new (string Name, string Folder)[]
        {
            ("Chrome", Path.Combine(local, "Google", "Chrome", "User Data")),
            ("Edge", Path.Combine(local, "Microsoft", "Edge", "User Data")),
            ("Brave", Path.Combine(local, "BraveSoftware", "Brave-Browser", "User Data")),
            ("Vivaldi", Path.Combine(local, "Vivaldi", "User Data")),
        };
        foreach (var (name, folder) in browsers)
        {
            try
            {
                if (!Directory.Exists(folder))
                {
                    continue;
                }

                foreach (var profile in Directory.EnumerateDirectories(folder))
                {
                    var bookmarks = Path.Combine(profile, "Bookmarks");
                    if (!File.Exists(bookmarks))
                    {
                        continue;
                    }

                    items.AddRange(ChromiumBookmarks.Parse(File.ReadAllText(bookmarks),
                        name + "/" + Path.GetFileName(profile)));
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"bookmarks.load-failed {name} {ex.GetType().Name}");
            }
        }

        // Firefox 书签（R20）：places.sqlite 里的 moz_bookmarks（type=1 才是书签）。
        try
        {
            var profiles = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Mozilla", "Firefox", "Profiles");
            if (Directory.Exists(profiles))
            {
                foreach (var profile in Directory.EnumerateDirectories(profiles))
                {
                    var places = Path.Combine(profile, "places.sqlite");
                    if (!File.Exists(places))
                    {
                        continue;
                    }

                    var copy = Path.Combine(Path.GetTempPath(), "kitty-places-" + Guid.NewGuid().ToString("N"));
                    try
                    {
                        HistoryIndex.CopyWithWal(places, copy);
                        using var connection = new SqliteConnection(copy);
                        using var statement = connection.Prepare(
                            """
                            SELECT COALESCE(b.title, p.title, p.url), p.url
                            FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
                            WHERE b.type = 1 AND p.url IS NOT NULL
                            ORDER BY b.lastModified DESC LIMIT 500;
                            """);
                        while (statement.Step())
                        {
                            var title = statement.GetText(0);
                            var url = statement.GetText(1);
                            if (!string.IsNullOrWhiteSpace(url))
                            {
                                items.Add(new BookmarkItem(title ?? url, url, "Firefox"));
                            }
                        }
                    }
                    finally
                    {
                        HistoryIndex.DeleteWithWal(copy);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"bookmarks.firefox-failed {ex.GetType().Name}");
        }

        _items = items
            .GroupBy(item => item.Url, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
        Log.Info($"bookmarks.ready count={_items.Count}");
    }

    public static List<BookmarkItem> Search(string query, int limit = 5)
    {
        var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0)
        {
            return new List<BookmarkItem>();
        }

        return _items
            .Where(item => tokens.All(token =>
                item.Title.Contains(token, StringComparison.OrdinalIgnoreCase) ||
                item.Url.Contains(token, StringComparison.OrdinalIgnoreCase)))
            .Take(limit)
            .ToList();
    }
}
