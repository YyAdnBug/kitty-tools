// 检查更新：读 GitHub releases（只认 windows-v*、非草稿、非预发布），启动后一次、之后每天一次；
// 有新版只轻提示一次（每个版本一次），托盘「检查更新」变成「下载新版本 x.y.z」打开发布页。
// 每日检查跑在线程池上，所以检查的后半段（改设置、通知、改托盘）一律回 UI 线程（第二版 §2 第 1 条）。
// 调试开关：KITTY_UPDATE_FEED 指向一个本地 JSON 文件或 URL，用它代替 GitHub 的发布列表。
// 这个开关、以及 http:// / file:// / 本地路径只在 Debug 或 --update-test 下认（REVIEW R1）；
// 正常 Release 只认 GitHub 的 https 地址（白名单在 Core 的 UpdateTrust，配单测）。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class UpdateService
{
    private const string DefaultFeed = UpdateTrust.FeedUrl + "?per_page=20";

    private static Timer? _timer;
    private static bool _started;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _dispatcher;

    public static string? AvailableVersion { get; private set; }

    public static string? AvailableUrl { get; private set; }

    /// <summary>对应架构的 zip 和它的 .sha256（App 内自动更新用，第二版 §5）。</summary>
    public static string? AvailableZipUrl { get; private set; }

    public static string? AvailableHashUrl { get; private set; }

    /// <summary>zip 的资产名（按它去 .sha256 里找哈希）。</summary>
    public static string? AvailableAssetName { get; private set; }

    public static event Action? Changed;

    /// <summary>本地假发布列表（KITTY_UPDATE_FEED）：验证每日检查会走线程池那条路。</summary>
    public static bool UsingLocalFeed { get; private set; }

    public static void Initialize(Microsoft.UI.Dispatching.DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public static void StartDaily()
    {
        if (_started)
        {
            return;
        }

        _started = true;
        _timer = new Timer(_ => _ = CheckAsync(userInitiated: false), null,
            TimeSpan.FromSeconds(12), TimeSpan.FromDays(1));
    }

    public static void Configure(bool enabled)
    {
        if (enabled)
        {
            StartDaily();
            return;
        }

        _timer?.Dispose();
        _timer = null;
        _started = false;
    }

    public static async Task CheckAsync(bool userInitiated)
    {
        try
        {
            var feed = Environment.GetEnvironmentVariable("KITTY_UPDATE_FEED");
            if (!string.IsNullOrWhiteSpace(feed) && !UpdateHttp.TestMode)
            {
                // Release 正常启动：测试用的发布列表不认（R1 的验收：日志里写一行就够）。
                Log.Warn("update.feed-ignored 忽略测试用的发布列表（只在 Debug 或 --update-test 下生效）");
                feed = null;
            }

            UsingLocalFeed = !string.IsNullOrWhiteSpace(feed);
            var json = string.IsNullOrWhiteSpace(feed)
                ? await UpdateHttp.GetFeedAsync(DefaultFeed)
                : await UpdateHttp.GetFeedAsync(feed);
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidOperationException("发布列表格式不对");
            }

            var current = typeof(UpdateService).Assembly.GetName().Version ?? new Version(0, 0, 0);
            string? bestVersion = null;
            string? bestUrl = null;
            string? bestZip = null;
            string? bestHash = null;
            string? bestAsset = null;
            Version? best = null;
            foreach (var release in document.RootElement.EnumerateArray())
            {
                if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean())
                {
                    continue;
                }

                if (release.TryGetProperty("prerelease", out var prerelease) && prerelease.GetBoolean())
                {
                    continue;
                }

                var tag = release.TryGetProperty("tag_name", out var tagValue) ? tagValue.GetString() : null;
                if (tag is null || !tag.StartsWith("windows-v", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (!Version.TryParse(tag["windows-v".Length..], out var version))
                {
                    continue;
                }

                if (best is not null && version <= best)
                {
                    continue;
                }

                best = version;
                bestVersion = version.ToString(3);
                bestUrl = release.TryGetProperty("html_url", out var url) ? url.GetString() : null;
                (bestZip, bestHash, bestAsset) = AssetsFor(release, bestVersion);
            }

            var newer = best is not null && best > current;
            Log.Info($"update.check newer={newer} version={bestVersion ?? "none"} localFeed={UsingLocalFeed}");
            ApplyResult(newer, bestVersion, bestUrl, bestZip, bestHash, bestAsset, current, userInitiated);
        }
        catch (Exception ex)
        {
            Log.Warn($"update.check-failed {ex.GetType().Name}");
            if (userInitiated)
            {
                NotifyUser("检查更新失败", "网络不通或 GitHub 暂时打不开", NoticeTone.Error);
            }
        }
    }

    /// <summary>
    /// 检查出来的结果只在 UI 线程落地：改设置、轻提示、托盘菜单文本都要 UI 线程；
    /// 这一步以前留在线程池上，第一次真的发现新版本时全部热键会失效（第二版 §2 第 1 条）。
    /// </summary>
    private static void ApplyResult(
        bool newer,
        string? bestVersion,
        string? bestUrl,
        string? bestZip,
        string? bestHash,
        string? bestAsset,
        Version current,
        bool userInitiated)
    {
        if (_dispatcher is { } dispatcher && !dispatcher.HasThreadAccess)
        {
            dispatcher.TryEnqueue(
                () => ApplyResult(newer, bestVersion, bestUrl, bestZip, bestHash, bestAsset, current, userInitiated));
            return;
        }

        AvailableVersion = newer ? bestVersion : null;
        AvailableUrl = newer ? bestUrl : null;
        AvailableZipUrl = newer ? bestZip : null;
        AvailableHashUrl = newer ? bestHash : null;
        AvailableAssetName = newer ? bestAsset : null;
        Notify();
        if (newer && bestVersion is not null &&
            SettingsService.Current.NotifiedUpdateVersion != bestVersion)
        {
            SettingsService.Current.NotifiedUpdateVersion = bestVersion;
            SettingsService.Save();
            NotifyUser("有新版本", $"Kitty Tools {bestVersion} 已发布，托盘里可打开发布页", NoticeTone.Normal);
        }
        else if (userInitiated)
        {
            NotifyUser(
                newer ? "有新版本" : "已是最新版本",
                newer ? $"Kitty Tools {bestVersion}" : current.ToString(3),
                NoticeTone.Normal);
        }

        // 手测自动更新用：KITTY_UPDATE_APPLY=1 时直接走下载 / 校验 / 替换（假发布列表配本地 zip）。
        // 和测试用的发布列表一样，只在 Debug 或 --update-test 下认（R1）。
        if (newer && UpdateHttp.TestMode && Environment.GetEnvironmentVariable("KITTY_UPDATE_APPLY") == "1")
        {
            _ = AutoUpdater.StartAsync();
        }
    }

    /// <summary>
    /// 从 release 的 assets 里找当前架构的 zip 和同名 .sha256（发布脚本两个都传）。
    /// 资产名形如 KittyTools-0.1.1-windows-x64.zip。
    /// </summary>
    private static (string? Zip, string? Hash, string? Name) AssetsFor(JsonElement release, string? version)
    {
        if (version is null ||
            !release.TryGetProperty("assets", out var assets) ||
            assets.ValueKind != JsonValueKind.Array)
        {
            return (null, null, null);
        }

        var architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture switch
        {
            System.Runtime.InteropServices.Architecture.Arm64 => "arm64",
            _ => "x64",
        };
        var wanted = $"KittyTools-{version}-windows-{architecture}.zip";
        string? zip = null;
        string? hash = null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var nameValue) ? nameValue.GetString() : null;
            var url = asset.TryGetProperty("browser_download_url", out var urlValue) ? urlValue.GetString() : null;
            if (name is null || url is null)
            {
                continue;
            }

            // 正常 Release 不认白名单以外的下载地址（R1）：宁可不自动更新，也不去别处拿 zip。
            if (!UpdateHttp.TestMode && !UpdateTrust.IsAllowedDownloadUrl(url))
            {
                Log.Warn("update.untrusted-asset");
                continue;
            }

            if (string.Equals(name, wanted, StringComparison.OrdinalIgnoreCase))
            {
                zip = url;
            }
            else if (string.Equals(name, wanted + ".sha256", StringComparison.OrdinalIgnoreCase))
            {
                hash = url;
            }
        }

        return (zip, hash, zip is null ? null : wanted);
    }

    public static void OpenAvailable()
    {
        if (AvailableUrl is null)
        {
            return;
        }

        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AvailableUrl)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"update.open-failed {ex.GetType().Name}");
        }
    }

    private static void NotifyUser(string title, string detail, NoticeTone tone)
    {
        if (_dispatcher is null || _dispatcher.HasThreadAccess)
        {
            NoticeHost.Show(title, detail, tone);
        }
        else
        {
            _dispatcher.TryEnqueue(() => NoticeHost.Show(title, detail, tone));
        }
    }

    private static void Notify()
    {
        if (_dispatcher is null)
        {
            Changed?.Invoke();
            return;
        }

        _dispatcher.TryEnqueue(() => Changed?.Invoke());
    }
}
