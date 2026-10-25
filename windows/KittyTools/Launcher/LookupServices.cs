// 启动器的四类额外查找（第三版 §6）：
// - 文件搜索：桌面 / 文档 / 下载 / 图片 / 视频 / 音乐 / OneDrive，最多跑 1.2 秒或 6000 个候选；空查询列最近文件；
// - 进程：kill 词 → 名字 / PID / 内存；结束进程带确认，失败说原因；
// - 端口：port 词 → netstat -ano 的监听行 + 占用进程（先用 netstat 的输出，报告里记为偏差）；
// - 书签：Chromium 系（Chrome / Edge / Brave / Vivaldi）的 Bookmarks JSON。
// 全是后台取、结果回 UI 线程再显示；历史（History 库）这一批没做。
using System.Diagnostics;
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

    public static Task<List<string>> SearchAsync(string query, CancellationToken cancellationToken)
        => Task.Run(() => Search(query, cancellationToken), cancellationToken);

    public static List<string> Search(string query, CancellationToken cancellationToken)
    {
        var tokens = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0)
        {
            return Recent(20);
        }

        var started = Stopwatch.GetTimestamp();
        var results = new List<(int Score, string Path)>();
        var candidates = 0;
        foreach (var root in Roots())
        {
            foreach (var file in Walk(root, ref candidates, cancellationToken))
            {
                if (cancellationToken.IsCancellationRequested || Elapsed(started) > Budget.TotalMilliseconds ||
                    candidates > MaxCandidates)
                {
                    break;
                }

                var name = Path.GetFileName(file);
                var score = LauncherCommands.ScoreFileName(name, tokens);
                if (score != int.MinValue)
                {
                    results.Add((score, file));
                }
            }

            if (cancellationToken.IsCancellationRequested || Elapsed(started) > Budget.TotalMilliseconds)
            {
                break;
            }
        }

        return results
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Path.Length)
            .Select(item => item.Path)
            .Take(20)
            .ToList();
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

    private static IEnumerable<string> Walk(string root, ref int candidates, CancellationToken cancellationToken)
    {
        var pending = new Stack<string>();
        pending.Push(root);
        var found = new List<string>();
        while (pending.Count > 0 && !cancellationToken.IsCancellationRequested)
        {
            var directory = pending.Pop();
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

                    pending.Push(child);
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
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "netstat.exe",
                Arguments = "-ano",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null)
            {
                return new List<PortEntry>();
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            var rows = NetstatOutput.Parse(output);
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
