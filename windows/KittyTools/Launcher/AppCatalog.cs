// 应用目录：商店应用走 PackageManager 的 AppListEntry（中文显示名、AUMID、logo），
// 桌面应用扫开始菜单的 .lnk；都按显示名 / 文件名 / 拼音 / 首字母能搜到。
// 第二版 §4.2：启动时先读磁盘缓存（launcher-cache.json），15 秒后在后台刷新一次；
// 打开面板时距上次超过 5 分钟再扫；扫的时候先用上一次的结果。
// PLAN-v18 §6（便携软件）：另扫桌面（A1）、App Paths（A2）、运行过的程序（A3）、用户加的应用文件夹（A4）；「从启动器里隐藏」的不列（A5）。
// 每个应用带上别名的键（L5）和系统记的最后一次运行（L6）。来源在 AppSources。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.ApplicationModel;
using Windows.ApplicationModel.Core;
using Windows.Foundation;
using Windows.Management.Deployment;
using Windows.Storage.Streams;

namespace KittyTools;

internal sealed class AppCatalog
{
    public static AppCatalog? Instance { get; private set; }

    private readonly object _gate = new();
    private readonly DispatcherQueue? _dispatcher = DispatcherQueue.GetForCurrentThread();
    private List<LauncherItem> _apps = new();
    private bool _scanning;
    private long _scannedAt;

    public event Action? Changed;

    public bool IsScanning => _scanning;

    public bool HasScanned => _scannedAt != 0;

    public static AppCatalog Start()
    {
        var catalog = new AppCatalog();
        Instance = catalog;
        // 先用上次的结果，界面立刻能用；15 秒后再后台扫一遍。
        var cached = LauncherCache.Load();
        if (cached.Count > 0)
        {
            lock (catalog._gate)
            {
                catalog._apps = cached
                    .OrderBy(item => item.Title, StringComparer.CurrentCulture)
                    .ToList();
            }

            catalog._dispatcher?.TryEnqueue(() => catalog.Changed?.Invoke());
        }

        _ = Task.Run(async () =>
        {
            await Task.Delay(15_000);
            catalog.RefreshIfStale();
        });
        return catalog;
    }

    public IReadOnlyList<LauncherItem> Apps
    {
        get
        {
            lock (_gate)
            {
                return _apps;
            }
        }
    }

    public LauncherItem? Find(string target)
    {
        lock (_gate)
        {
            return _apps.FirstOrDefault(item => item.Target == target);
        }
    }

    /// <summary>应用文件夹、隐藏名单、「运行过的程序」开关改了：马上重扫（不等 5 分钟）。</summary>
    public void Rescan()
    {
        _scannedAt = 0;
        RefreshIfStale();
    }

    /// <summary>「从启动器里隐藏」：先从手上这份里拿掉，下次扫照名单不收。</summary>
    public void Remove(string target)
    {
        lock (_gate)
        {
            _apps = _apps.Where(item => !string.Equals(item.Target, target, StringComparison.OrdinalIgnoreCase)).ToList();
        }
    }

    public void RefreshIfStale()
    {
        if (_scanning || Environment.TickCount64 - _scannedAt < 5 * 60_000)
        {
            return;
        }

        _ = Task.Run(ScanAsync);
    }

    private async Task ScanAsync()
    {
        if (_scanning)
        {
            return;
        }

        _scanning = true;
        try
        {
            await Task.Yield();
            var apps = new List<LauncherItem>();
            var stats = new ScanStats();
            var seenTargets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var desktop = ScanStartMenu(stats, seenTargets).ToList();
            apps.AddRange(desktop);
            var store = await ScanStoreAppsAsync();
            apps.AddRange(store);
            var extra = ScanOtherSources(seenTargets, out var lastRun);
            apps.AddRange(extra);
            var settings = SettingsService.Current;
            var hidden = new HashSet<string>(settings.LauncherHiddenApps ?? new List<string>(), StringComparer.OrdinalIgnoreCase);
            var deduped = apps
                .Where(item => !hidden.Contains(item.Target))
                .GroupBy(item => item.Target, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .Select(item => lastRun.TryGetValue(item.Target, out var last) || (item.ResolvedExe is { } exe && lastRun.TryGetValue(exe, out last))
                    ? item with { SystemUse = last.Ticks }
                    : item)
                .OrderBy(item => item.Title, StringComparer.CurrentCulture)
                .ToList();
            lock (_gate)
            {
                _apps = deduped;
                _scannedAt = Environment.TickCount64;
            }

            LauncherCache.Save(deduped);
            Log.Info($"launcher.apps count={deduped.Count} desktop={desktop.Count} store={store.Count} extra={extra.Count} " +
                     $"hidden={hidden.Count} system-use={deduped.Count(item => item.SystemUse > 0)} " +
                     $"icons={deduped.Count(item => item.IconData is { Length: > 0 })} " +
                     $"desktop-icons={desktop.Count(item => item.IconData is { Length: > 0 })} " +
                     $"store-icons={store.Count(item => item.IconData is { Length: > 0 })} " +
                     $"skipped-name={stats.SkippedByName} skipped-target={stats.SkippedByTarget} " +
                     $"duplicates={stats.Duplicates}");
            _dispatcher?.TryEnqueue(() => Changed?.Invoke());
        }
        catch (Exception ex)
        {
            Log.Error("launcher.apps-failed", ex);
        }
        finally
        {
            _scanning = false;
        }
    }

    private static IEnumerable<LauncherItem> ScanStartMenu(ScanStats stats, HashSet<string> seenTargets)
    {
        // 开始菜单（所有用户、当前用户）整棵树的 .lnk；桌面（当前用户、公用）顶层的 .lnk 和 .exe（PLAN-v18 §6 A1，副标题「桌面」）
        var folders = new[]
        {
            (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs"), false),
            (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs"), false),
            (Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), true),
            (Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), true),
        };
        // 「所有用户」和「当前用户」下各有一个快捷方式 = 同一个程序：按解析出来的目标去重，
        // 先扫到的那份（所有用户）留下（第二版 §2 第 13 条）；桌面上的和开始菜单里已有的同一个程序，开始菜单那条留着。
        var seenFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var scale = Displays.SystemScale;
        foreach (var (folder, isDesktop) in folders)
        {
            if (folder.Length == 0 || !Directory.Exists(folder))
            {
                continue;
            }

            IEnumerable<string> files;
            try
            {
                files = isDesktop
                    ? Directory.EnumerateFiles(folder, "*.lnk", SearchOption.TopDirectoryOnly)
                        .Concat(Directory.EnumerateFiles(folder, "*.exe", SearchOption.TopDirectoryOnly))
                    : Directory.EnumerateFiles(folder, "*.lnk", SearchOption.AllDirectories);
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.startmenu-failed {ex.GetType().Name}");
                continue;
            }

            foreach (var file in files)
            {
                if (!seenFiles.Add(file))
                {
                    continue;
                }

                // 桌面上直接放的 exe（便携软件）
                if (file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                {
                    if (!StartMenuFilter.ShouldSkipTarget(file) && seenTargets.Add(file) &&
                        AppSources.ExeItem(file, "桌面", scale, filter: true) is { } exeItem)
                    {
                        yield return exeItem with { ResolvedExe = file };
                    }

                    continue;
                }

                var fileTitle = Path.GetFileNameWithoutExtension(file);
                if (string.IsNullOrWhiteSpace(fileTitle))
                {
                    continue;
                }

                // PLAN-v18 L7：标题用资源管理器显示的名字（desktop.ini 里的本地化名：中文系统上「命令提示符」「运行」这类系统工具的
                // .lnk 文件名是英文），英文文件名也留在能搜的名字里。
                var display = ShellIcons.DisplayName(file).Trim();
                var title = display.Length > 0 && !display.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) ? display : fileTitle;
                if (StartMenuFilter.ShouldSkip(title) || StartMenuFilter.ShouldSkip(fileTitle))
                {
                    stats.SkippedByName++;
                    continue;
                }

                var target = Shortcuts.ResolveTarget(file);
                if (target is not null && StartMenuFilter.ShouldSkipTarget(target))
                {
                    stats.SkippedByTarget++;
                    continue;
                }

                var key = target ?? file;
                if (!seenTargets.Add(key))
                {
                    stats.Duplicates++;
                    continue;
                }

                var names = new List<string> { LauncherMatch.Fold(title), LauncherMatch.Fold(fileTitle) };
                var initials = new List<string> { LauncherMatch.Initials(title), LauncherMatch.Initials(fileTitle) };
                if (Pinyin.For(title) is { } pinyin)
                {
                    names.Add(pinyin.Full);
                    initials.Add(pinyin.Initials);
                }

                // PLAN-v9-launcher B9（mac A25）：不写和右边「应用」重复的「桌面应用」；中文名写 exe 的英文名，子文件夹里的写文件夹名。
                // 子文件夹名同样取显示名（「System Tools」→「Windows 工具」这类，L7）；开始菜单根目录 Programs 照旧不写。
                var directory = Path.GetDirectoryName(file);
                var parent = Path.GetFileName(directory);
                if (directory is not null && !string.Equals(parent, "Programs", StringComparison.OrdinalIgnoreCase))
                {
                    parent = ShellIcons.DisplayName(directory).Trim();
                }

                var subtitle = isDesktop ? "桌面" : LauncherText.AppSubtitle(title, target is null ? null : Path.GetFileName(target), parent);
                var item = new LauncherItem
                {
                    Kind = LauncherKind.App,
                    Target = file,
                    Title = title,
                    Subtitle = subtitle,
                    Names = names.Distinct().ToList(),
                    Initials = initials.Distinct().ToList(),
                    IconPath = file,
                    IconData = ShellIcons.LoadPng(file, scale),
                    AliasKey = AppAliases.Key(file, target, AppSources.AliasFolders),
                    ResolvedExe = target,
                };
                yield return item;
            }
        }
    }

    /// <summary>
    /// 开始菜单、桌面、商店之外的（PLAN-v18 §6 A2 A3 A4）：App Paths、运行过的程序、用户加的文件夹和程序；和已有的同一个目标不重复收。
    /// A3 A4 过名单；A4 同一个文件夹里说明一样的只留一个。lastRun：exe / .lnk 路径 → 最后运行时刻（L6）。
    /// </summary>
    private static List<LauncherItem> ScanOtherSources(HashSet<string> seenTargets, out Dictionary<string, DateTime> lastRun)
    {
        var started = Environment.TickCount64;
        var items = new List<LauncherItem>();
        var scale = Displays.SystemScale;
        var settings = SettingsService.Current;
        foreach (var path in AppSources.AppPaths())
        {
            if (!StartMenuFilter.ShouldSkipTarget(path) && seenTargets.Add(path) &&
                AppSources.ExeItem(path, string.Empty, scale, filter: false) is { } item)
            {
                items.Add(item with { ResolvedExe = path });
            }
        }

        var appPaths = items.Count;
        lastRun = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        var recent = 0;
        if (settings.LauncherRecentPrograms)
        {
            var (programs, runs) = AppSources.UserAssist();
            lastRun = runs;
            foreach (var program in programs.OrderByDescending(entry => entry.LastRunUtc ?? DateTime.MinValue))
            {
                if (!StartMenuFilter.ShouldSkipTarget(program.Path) && !seenTargets.Contains(program.Path) &&
                    AppSources.ExeItem(program.Path, Path.GetFileName(Path.GetDirectoryName(program.Path)) ?? string.Empty, scale, filter: true) is { } item)
                {
                    seenTargets.Add(program.Path);
                    items.Add(item with { ResolvedExe = program.Path });
                    recent++;
                }
            }
        }

        var folders = 0;
        var chosen = AppSources.UserFolders(settings.LauncherAppFolders ?? new List<string>());
        var exes = chosen.Where(path => path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)).ToList();
        var kept = PortableApps.OnePerDescription(exes.Select(path => (path, AppSources.Description(path))))
            .Concat(chosen.Where(path => path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)));
        foreach (var path in kept)
        {
            var target = path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) ? Shortcuts.ResolveTarget(path) ?? path : path;
            if (StartMenuFilter.ShouldSkipTarget(target) || !seenTargets.Add(target))
            {
                continue;
            }

            if (AppSources.ExeItem(target, Path.GetFileName(Path.GetDirectoryName(target)) ?? string.Empty, scale, filter: true) is { } item)
            {
                items.Add(item with { Target = path, IconPath = path, ResolvedExe = target });
                folders++;
            }
        }

        Log.Info($"launcher.app-sources app-paths={appPaths} recent={recent} folders={folders} runs={lastRun.Count} " +
                 $"ms={Environment.TickCount64 - started}");
        return items;
    }

    private static async Task<List<LauncherItem>> ScanStoreAppsAsync()
    {
        var items = new List<LauncherItem>();
        try
        {
            var manager = new PackageManager();
            foreach (var package in manager.FindPackagesForUser(string.Empty))
            {
                if (package.IsFramework || package.IsResourcePackage || package.IsStub)
                {
                    continue;
                }

                IReadOnlyList<AppListEntry> entries;
                try
                {
                    entries = await package.GetAppListEntriesAsync();
                }
                catch
                {
                    continue;
                }

                foreach (var entry in entries)
                {
                    try
                    {
                        var display = entry.DisplayInfo.DisplayName?.Trim();
                        var aumid = entry.AppUserModelId;
                        if (string.IsNullOrWhiteSpace(display) || string.IsNullOrWhiteSpace(aumid))
                        {
                            continue;
                        }

                        var names = new List<string> { LauncherMatch.Fold(display) };
                        var initials = new List<string> { LauncherMatch.Initials(display) };
                        if (Pinyin.For(display) is { } pinyin)
                        {
                            names.Add(pinyin.Full);
                            initials.Add(pinyin.Initials);
                        }

                        var packageName = package.DisplayName?.Trim();
                        if (!string.IsNullOrEmpty(packageName) && packageName != display)
                        {
                            names.Add(LauncherMatch.Fold(packageName));
                        }

                        byte[]? icon = null;
                        try
                        {
                            var logo = entry.DisplayInfo.GetLogo(new Size(64, 64));
                            using var stream = await logo.OpenReadAsync();
                            icon = await ReadAllBytesAsync(stream);
                        }
                        catch
                        {
                            // 没有 logo 就用默认图标。
                        }

                        items.Add(new LauncherItem
                        {
                            Kind = LauncherKind.App,
                            Target = @"shell:AppsFolder\" + aumid,
                            AliasKey = AppAliases.Key(@"shell:AppsFolder\" + aumid, null, AppSources.AliasFolders),
                            Title = display,
                            Subtitle = string.Empty,
                            Names = names.Distinct().ToList(),
                            Initials = initials.Distinct().ToList(),
                            IconData = icon,
                        });
                    }
                    catch
                    {
                        // 单个应用的清单有问题就跳过。
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.store-apps-failed {ex.GetType().Name}");
        }

        return items;
    }

    private static async Task<byte[]> ReadAllBytesAsync(IRandomAccessStream stream)
    {
        var size = (uint)stream.Size;
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync(size);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// <summary>这一轮扫描跳过了多少、合并了多少（只进日志，用来核对过滤规则）。</summary>
    private sealed class ScanStats
    {
        public int SkippedByName;

        public int SkippedByTarget;

        public int Duplicates;
    }
}
