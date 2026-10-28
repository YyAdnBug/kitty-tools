// 启动器的文件搜索（第三版 §6）：桌面 / 文档 / 下载 / 图片 / 视频 / 音乐 / OneDrive，先走 Windows 搜索的索引，
// 最多跑 1.2 秒或 6000 个候选；只输关键词时列最近打开的文件（「最近使用」里的快捷方式解析成真文件）。
// 后台取、结果回 UI 线程再显示。进程、端口在 RunningProcesses，书签和历史在 BrowserData（PLAN-v9-launcher）。
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

    /// <summary>
    /// 最近打开的文件（mac「最近打开和下载的文件」）：%APPDATA%\Microsoft\Windows\Recent 里的快捷方式，解析成它指着的
    /// 文件 / 文件夹（还在的才要），按快捷方式的时间从新到旧。线程池里调（解析快捷方式走 COM）。
    /// </summary>
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

            var result = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var link in Directory.EnumerateFiles(folder, "*.lnk")
                         .Select(path => (Path: path, Time: File.GetLastWriteTimeUtc(path)))
                         .OrderByDescending(item => item.Time)
                         .Take(limit * 3)
                         .Select(item => item.Path))
            {
                var target = Shortcuts.ResolveTarget(link);
                if (target is null || (!File.Exists(target) && !Directory.Exists(target)) || !seen.Add(target))
                {
                    continue;
                }

                result.Add(target);
                if (result.Count >= limit)
                {
                    break;
                }
            }

            return result;
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
