// 应用目录：商店应用走 PackageManager 的 AppListEntry（中文显示名、AUMID、logo），
// 桌面应用扫开始菜单的 .lnk；都按显示名 / 文件名 / 拼音 / 首字母能搜到。
// 第二版 §4.2：启动时先读磁盘缓存（launcher-cache.json），15 秒后在后台刷新一次；
// 打开面板时距上次超过 5 分钟再扫；扫的时候先用上一次的结果。
// PLAN-v18 §6（便携软件）：另扫桌面（A1）、App Paths（A2）、运行过的程序（A3）、用户加的应用文件夹（A4）；「从启动器里隐藏」的不列（A5）。
// 每个应用带上别名的键（L5）和系统记的最后一次运行（L6）。来源在 AppSources。
// PLAN-v27 B1–B4（启动器搜不到 cmd）：能搜的名字统一走 Core AppNames（快捷方式目标 exe 的名字也算：「命令提示符」打 cmd 能搜到）；
// 「像文档」的名字只在目标不是程序时才拦（「腾讯文档」照收）；同一个 exe 参数不同的快捷方式（网页应用、浏览器的几个用户资料）各算一个；
// 商店应用另加包名（中文系统上「终端」打 wt / terminal 能搜到）。
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
        // 带参数的快捷方式指向的 exe：扫完再记进 seenTargets（App Paths、运行过的程序别再把同一个 exe 收一遍；
        // 扫的过程中不记，免得「Chrome - 工作」先占了位、不带参数的「Google Chrome」被当成重复）
        var exesWithArguments = new List<string>();
        // 别名的键：同一个 exe 的第一个快捷方式照旧是「exe:路径」（以前去重留下的就是它，已经起的别名不变）；
        // 后面参数不一样的那几个（以前被当成重复丢了）键后面带上参数，各起各的别名
        var aliasKeys = new HashSet<string>(StringComparer.Ordinal);
        // 同一个 exe、同一个名字的只留一条：桌面上的「Google Chrome」「WPS Office」带个只做标记的参数（--source-shortcut-location=desktop 这类），
        // 参数不同却是同一个应用，按参数去重会出两行一模一样的
        var seenTitles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
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
                // 先解析目标再按名字拦：名字像文档、目标却是程序的照收（PLAN-v27 B2）。
                // 目标是原样的（%windir%\system32\cmd.exe）：别名的键照旧用它（不让已经起的别名失效）；去重、对运行记录用展开的。
                var (target, arguments) = Shortcuts.Read(file);
                if (StartMenuFilter.ShouldSkip(title, target) || StartMenuFilter.ShouldSkip(fileTitle, target))
                {
                    stats.SkippedByName++;
                    continue;
                }

                if (target is not null && StartMenuFilter.ShouldSkipTarget(target))
                {
                    stats.SkippedByTarget++;
                    continue;
                }

                var expanded = target is null ? null : Environment.ExpandEnvironmentVariables(target);
                // 同一个程序在「所有用户」「当前用户」下各一个快捷方式：目标和参数都一样，合成一条；参数不一样的是不同的应用（PLAN-v27 B3）
                var key = expanded is null ? file : arguments.Length == 0 ? expanded : expanded + "\n" + arguments;
                if (!seenTargets.Add(key) || (expanded is not null && !seenTitles.Add(expanded + "\n" + title)))
                {
                    stats.Duplicates++;
                    continue;
                }

                if (expanded is not null && arguments.Length > 0)
                {
                    exesWithArguments.Add(expanded);
                }

                var (names, initials) = AppNames.Build(new[] { title, fileTitle }, target);

                // PLAN-v9-launcher B9（mac A25）：不写和右边「应用」重复的「桌面应用」；中文名写 exe 的英文名，子文件夹里的写文件夹名。
                // 子文件夹名同样取显示名（「System Tools」→「Windows 工具」这类，L7）；开始菜单根目录 Programs 照旧不写。
                var directory = Path.GetDirectoryName(file);
                var parent = Path.GetFileName(directory);
                if (directory is not null && !string.Equals(parent, "Programs", StringComparison.OrdinalIgnoreCase))
                {
                    parent = ShellIcons.DisplayName(directory).Trim();
                }

                var subtitle = isDesktop ? "桌面" : LauncherText.AppSubtitle(title, target is null ? null : Path.GetFileName(target), parent);
                var aliasKey = AppAliases.Key(file, target, AppSources.AliasFolders);
                if (aliasKey is not null && !aliasKeys.Add(aliasKey))
                {
                    aliasKey += "|" + (arguments.Length > 200 ? arguments[..200] : arguments).ToLowerInvariant();
                    aliasKeys.Add(aliasKey);
                }

                var item = new LauncherItem
                {
                    Kind = LauncherKind.App,
                    Target = file,
                    Title = title,
                    Subtitle = subtitle,
                    Names = names,
                    Initials = initials,
                    IconPath = file,
                    IconData = ShellIcons.LoadPng(file, scale),
                    AliasKey = aliasKey,
                    ResolvedExe = expanded,
                };
                yield return item;
            }
        }

        seenTargets.UnionWith(exesWithArguments);
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

                        // 显示名、包的显示名、包名去掉发布者那一截（Microsoft.WindowsTerminal → WindowsTerminal：wt、terminal；PLAN-v27 B4）
                        string? shortName = null;
                        try
                        {
                            shortName = AppNames.PackageShortName(package.Id.Name);
                        }
                        catch
                        {
                            // 读不到包名就只用显示名
                        }

                        var (names, initials) = AppNames.Build(new[] { display, package.DisplayName?.Trim(), shortName });

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
                            Names = names,
                            Initials = initials,
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
