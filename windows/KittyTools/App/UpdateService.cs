// 检查更新：读 GitHub releases（只认 windows-v*、非草稿、非预发布），启动后一次、之后每天一次；
// 有新版只轻提示一次（每个版本一次），托盘「检查更新」变成「下载新版本 x.y.z」打开发布页。
// ponytail: 第一版不自动替换 exe；要自动更新时用「改名正在运行的 exe → 解压新文件 → 重启」。
using System.Net.Http;
using System.Text.Json;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class UpdateService
{
    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(12),
    };

    private static Timer? _timer;
    private static bool _started;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _dispatcher;

    public static string? AvailableVersion { get; private set; }

    public static string? AvailableUrl { get; private set; }

    public static event Action? Changed;

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
            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                "https://api.github.com/repos/YyAdnBug/kitty-tools/releases?per_page=20");
            request.Headers.UserAgent.ParseAdd("KittyTools-Windows");
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await Http.SendAsync(request);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync();
            using var document = await JsonDocument.ParseAsync(stream);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidOperationException("发布列表格式不对");
            }

            var current = typeof(UpdateService).Assembly.GetName().Version ?? new Version(0, 0, 0);
            string? bestVersion = null;
            string? bestUrl = null;
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
            }

            var newer = best is not null && best > current;
            Log.Info($"update.check newer={newer} version={bestVersion ?? "none"}");
            AvailableVersion = newer ? bestVersion : null;
            AvailableUrl = newer ? bestUrl : null;
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
