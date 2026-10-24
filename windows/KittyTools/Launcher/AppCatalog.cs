// 应用目录：商店应用走 PackageManager 的 AppListEntry（中文显示名、AUMID、logo），
// 桌面应用扫开始菜单的 .lnk；都按显示名 / 文件名 / 拼音 / 首字母能搜到。
// 后台线程扫：启动时一次，打开面板时距上次超过 5 分钟再扫；扫的时候先用上一次的结果。
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
        catalog.RefreshIfStale();
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
            var desktop = ScanStartMenu().ToList();
            apps.AddRange(desktop);
            var store = await ScanStoreAppsAsync();
            apps.AddRange(store);
            var deduped = apps
                .GroupBy(item => item.Target, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .OrderBy(item => item.Title, StringComparer.CurrentCulture)
                .ToList();
            lock (_gate)
            {
                _apps = deduped;
                _scannedAt = Environment.TickCount64;
            }

            Log.Info($"launcher.apps count={deduped.Count} desktop={desktop.Count} store={store.Count} " +
                     $"icons={deduped.Count(item => item.IconData is { Length: > 0 })} " +
                     $"desktop-icons={desktop.Count(item => item.IconData is { Length: > 0 })} " +
                     $"store-icons={store.Count(item => item.IconData is { Length: > 0 })}");
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

    private static IEnumerable<LauncherItem> ScanStartMenu()
    {
        var folders = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs"),
        };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in folders)
        {
            if (!Directory.Exists(folder))
            {
                continue;
            }

            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(folder, "*.lnk", SearchOption.AllDirectories);
            }
            catch (Exception ex)
            {
                Log.Warn($"launcher.startmenu-failed {ex.GetType().Name}");
                continue;
            }

            foreach (var file in files)
            {
                if (!seen.Add(file))
                {
                    continue;
                }

                var title = Path.GetFileNameWithoutExtension(file);
                if (string.IsNullOrWhiteSpace(title))
                {
                    continue;
                }

                var names = new List<string> { LauncherMatch.Fold(title) };
                var initials = new List<string> { LauncherMatch.Initials(title) };
                if (Pinyin.For(title) is { } pinyin)
                {
                    names.Add(pinyin.Full);
                    initials.Add(pinyin.Initials);
                }

                var parent = Path.GetFileName(Path.GetDirectoryName(file));
                var subtitle = string.IsNullOrEmpty(parent) || parent.Equals("Programs", StringComparison.OrdinalIgnoreCase)
                    ? "桌面应用"
                    : parent;
                var item = new LauncherItem
                {
                    Kind = LauncherKind.App,
                    Target = file,
                    Title = title,
                    Subtitle = subtitle,
                    Names = names.Distinct().ToList(),
                    Initials = initials.Distinct().ToList(),
                    IconPath = file,
                    IconData = ShellIcons.LoadPng(file),
                };
                yield return item;
            }
        }
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
                            Title = display,
                            Subtitle = "商店应用",
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
}
