// 启动器的文件搜索（第三版 §6；PLAN-v25 改了范围、退路，加了 Everything 和最后一行的说明）：
// - 装了 Everything 并且它在运行（设置里能关）：用它搜（EverythingSearch，所有本地硬盘）；
// - 否则查 Windows 搜索的整个索引（OleDbFileSearch，按修改时间最多 500 条），去掉系统文件夹这些（FileSearchFilter），
//   常用文件夹里不在索引里的（比如桌面挪到了 D 盘、没加进索引）另外限时扫一遍并进来；
// - 索引用不了（服务没开）：限时扫常用文件夹（桌面、文档、下载、图片、视频、音乐、OneDrive 的真实位置），边扫边比；
// - 只输关键词时列最近打开的文件（「最近使用」里的快捷方式解析成真文件）。
// 最后一行的说明（FileSearchHints.Pick）跟着结果一起回去。都在线程池里跑，结果回 UI 线程再显示。
// 进程、端口在 RunningProcesses，书签和历史在 BrowserData（PLAN-v9-launcher）。
using System.Diagnostics;
using System.IO.Enumeration;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

/// <summary>一次文件搜索的结果：路径（排好了，最多 20 条）、从哪来的、最后一行的说明（不用出是 null）。</summary>
internal sealed record FileSearchOutcome(List<string> Paths, FileSearchSource Source, LauncherItem? Hint);

internal static partial class FileSearch
{
    /// <summary>扫目录最多看这么多个条目、找到这么多条就停、最多扫这么久（PLAN-v25 F6）。</summary>
    private const int MaxWalkEntries = 50_000;

    private const int MaxWalkMatches = 200;

    private static readonly TimeSpan WalkBudget = TimeSpan.FromSeconds(1);

    // KnownFolders.h 的 FOLDERID_Desktop、Documents、Downloads、Pictures、Videos、Music
    private static readonly Guid[] KnownFolderIds =
    {
        new("B4BFCC3A-DB2C-424C-B029-7FE99A87C641"),
        new("FDD39AD0-238F-46AF-ADB4-6C85480369C7"),
        new("374DE290-123F-4565-9164-39C4925E467B"),
        new("33E28130-4E1E-4676-835A-98395C3BC3BB"),
        new("18989B1D-99B5-455B-841C-AB7C74E4DDFC"),
        new("4BD8D571-6D19-48D3-BE97-422220080E43"),
    };

    /// <summary>
    /// 常用文件夹的真实位置（PLAN-v25 F5）：已知文件夹（挪到 D 盘、OneDrive 备份了的都按挪过去的位置）+ OneDrive 的根
    /// （个人版、工作 / 学校版）。去掉被别的包含的、不存在的。线程池里调。
    /// </summary>
    public static List<string> KnownFolders()
    {
        var folders = new List<string>();
        foreach (var id in KnownFolderIds)
        {
            var copy = id;
            if (SHGetKnownFolderPath(ref copy, 0, IntPtr.Zero, out var pointer) != 0 || pointer == IntPtr.Zero)
            {
                continue;
            }

            try
            {
                if (Marshal.PtrToStringUni(pointer) is { Length: > 0 } path)
                {
                    folders.Add(path);
                }
            }
            finally
            {
                Marshal.FreeCoTaskMem(pointer);
            }
        }

        foreach (var name in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
        {
            if (Environment.GetEnvironmentVariable(name) is { Length: > 0 } path)
            {
                folders.Add(path);
            }
        }

        return FileSearchFilter.TopmostFolders(folders).Where(Directory.Exists).ToList();
    }

    /// <summary>
    /// 搜一次。useEverything：设置里的「装了 Everything 并且它在运行时用它搜」（调用方在 UI 线程读好传进来）。
    /// 查询词全是文件名里不可能有的字符时返回空。
    /// </summary>
    public static async Task<FileSearchOutcome> SearchAsync(string query, bool useEverything, CancellationToken cancellationToken)
    {
        var tokens = FileSearchFilter.Tokens(query);
        if (tokens.Count == 0)
        {
            return new FileSearchOutcome(new List<string>(), FileSearchSource.Index, null);
        }

        var started = Stopwatch.GetTimestamp();
        var forceFallback = Environment.GetEnvironmentVariable("KITTY_FS_FORCE_FALLBACK") == "1";
        var systemDrive = Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\";
        var results = new List<(int Score, string Path)>();
        var excluded = 0;
        void Add(string path)
        {
            if (FileSearchFilter.IsExcluded(path, systemDrive))
            {
                excluded++;
                return;
            }

            var score = LauncherCommands.ScoreFileName(Path.GetFileName(path.TrimEnd('\\')), tokens);
            if (score != int.MinValue)
            {
                results.Add((score, path));
            }
        }

        if (useEverything && !forceFallback)
        {
            var hits = await EverythingSearch.SearchAsync(tokens, cancellationToken);
            if (hits is not null)
            {
                foreach (var hit in hits)
                {
                    if (hit.Folder.Length > 0)
                    {
                        Add(hit.Path);
                    }
                }

                var found = Rank(results);
                Log.Info($"files.search source=everything ms={Elapsed(started):F0} hits={found.Count} excluded={excluded}");
                return new FileSearchOutcome(found, FileSearchSource.Everything, null);
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        return await Task.Run(() =>
        {
            // 状态缓存 60 秒（第一次要几十毫秒：服务、索引目录、哪些位置在索引里）
            var status = SearchIndexStatus.Get();
            var indexed = forceFallback ? null : OleDbFileSearch.Search(tokens);
            if (indexed is not null)
            {
                foreach (var path in indexed)
                {
                    Add(path);
                }

                // F7：常用文件夹里不在索引里的，限时扫一遍并进来
                var walked = status is { UncoveredFolders.Count: > 0 } ? Walk(status.UncoveredFolders, tokens, Add, cancellationToken) : 0;
                var ranked = Rank(results);
                Log.Info($"files.search source=oledb ms={Elapsed(started):F0} hits={ranked.Count} excluded={excluded} walked={walked}");
                return new FileSearchOutcome(ranked, FileSearchSource.Index, FileSearchHints.Pick(status, FileSearchSource.Index, ranked.Count));
            }

            // F6：索引用不了，扫常用文件夹
            var visited = Walk(KnownFolders(), tokens, Add, cancellationToken);
            var fallback = Rank(results);
            Log.Info($"files.search source=walk ms={Elapsed(started):F0} hits={fallback.Count} visited={visited}");
            return new FileSearchOutcome(fallback, FileSearchSource.Walk, FileSearchHints.Pick(status, FileSearchSource.Walk, fallback.Count));
        }, cancellationToken);
    }

    private static List<string> Rank(List<(int Score, string Path)> results)
        => results
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Path.Length)
            .Select(item => item.Path)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(20)
            .ToList();

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

    /// <summary>
    /// 扫目录、边扫边比（PLAN-v25 F6）：最多 8 层，跳过隐藏 / 系统的（默认的 AttributesToSkip）、点开头的和 node_modules 这类文件夹，
    /// 没权限的跳过；总共 WalkBudget、MaxWalkEntries 个条目、MaxWalkMatches 条，先到哪个算哪个。返回看了多少个条目。
    /// ponytail: 每打一个字（停 180 ms 后）都重扫；要更快就在一次呼出里缓存扫过的名字。
    /// </summary>
    private static int Walk(IReadOnlyList<string> roots, IReadOnlyList<string> tokens, Action<string> add, CancellationToken cancellationToken)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        budget.CancelAfter(WalkBudget);
        var token = budget.Token;
        var visited = 0;
        var matches = 0;
        var options = new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 8, IgnoreInaccessible = true };
        foreach (var root in roots)
        {
            var entries = new FileSystemEnumerable<string>(root, static (ref FileSystemEntry entry) => entry.ToFullPath(), options)
            {
                ShouldIncludePredicate = (ref FileSystemEntry entry) =>
                {
                    if (++visited > MaxWalkEntries)
                    {
                        throw new OperationCanceledException();
                    }

                    token.ThrowIfCancellationRequested();
                    return LauncherCommands.ScoreFileName(entry.FileName.ToString(), tokens) != int.MinValue;
                },
                ShouldRecursePredicate = static (ref FileSystemEntry entry) => !FileSearchFilter.SkipsFolder(entry.FileName.ToString()),
            };
            try
            {
                foreach (var path in entries)
                {
                    add(path);
                    if (++matches >= MaxWalkMatches)
                    {
                        return visited;
                    }
                }
            }
            catch (OperationCanceledException)
            {
                return visited;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Log.Warn($"files.walk-failed {ex.GetType().Name}");
            }
        }

        return visited;
    }

    private static double Elapsed(long started)
        => (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;

    [LibraryImport("shell32.dll", EntryPoint = "SHGetKnownFolderPath")]
    private static partial int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
}
