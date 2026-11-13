// 更新清单 windows-update.json（PLAN-v18 L12 ②，照 mac c006ea04 的 macos-update.json；issue #12）：一个静态文件，挂在固定的预发布
// release「windows-update」上（latest 永远是 mac 版，不能照 mac 读 releases/latest）。读它不走 GitHub API，不受没登录时每个 IP
// 每小时 60 次的限制——公司、学校共用一个出口时别人就替你用完了。build-release.ps1 生成它，发版时覆盖上传。
//
// 格式（**发布后只加新键**：已装的版本会读它；要改已有键的意思就换一个文件名，旧名字的照发）：
//   { "version": "0.2.0", "page": "https://github.com/.../releases/tag/windows-v0.2.0",
//     "x64":   { "url": "https://github.com/.../releases/download/windows-v0.2.0/KittyTools-0.2.0-windows-x64.zip", "sha256": "…", "size": 123 },
//     "arm64": { … } }
// 解析（Parse）：缺字段、版本号不是数字和点、地址不是 https、这个架构的 zip 名字对不上、sha256 不是 64 位十六进制、过不了白名单，
// 都当「读不到」（null，调用方退回 API）。下载照旧另核 zip 旁边的 .sha256（AutoUpdater）。
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

/// <summary>清单里这台电脑那个架构的那一版。HashUrl 是 zip 旁边的 .sha256（下载照旧核它）。</summary>
public sealed record UpdateOffer(string Version, string Page, string ZipUrl, string HashUrl, string AssetName, string Sha256, long Size);

public static partial class UpdateManifest
{
    public const string FileName = "windows-update.json";

    /// <summary>固定的预发布 release 的 tag：只放这一个附件（网站和 mac 的检查都不认预发布）。</summary>
    public const string ReleaseTag = "windows-update";

    public const string Url = "https://github.com/YyAdnBug/kitty-tools/releases/download/" + ReleaseTag + "/" + FileName;

    /// <summary>发布页（限流时指过去）。</summary>
    public const string ReleasesPage = "https://github.com/YyAdnBug/kitty-tools/releases";

    /// <summary>GitHub 限流时关于页、轻提示里说的话（同 mac Updater.apiFailure）。</summary>
    public const string RateLimitedText = "GitHub 限流了（这个网络查得太频繁），稍后再试或到发布页下载";

    [GeneratedRegex(@"^[0-9]+(\.[0-9]+)*$")]
    private static partial Regex VersionPattern();

    [GeneratedRegex(@"^[0-9a-f]{64}$")]
    private static partial Regex HashPattern();

    /// <summary>403 / 429：没登录的 API 每个 IP 每小时 60 次用完了。</summary>
    public static bool IsRateLimited(int status) => status is 403 or 429;

    /// <summary>
    /// 清单 → 这个架构（x64 / arm64）的那一版；不认的一律 null。allowed：下载地址白名单（正常 Release 是 UpdateTrust.IsAllowedDownloadUrl，
    /// 测试源下放行）。不比版本新旧：清单读到了就以它为准（同 mac），新不新调用方比。
    /// </summary>
    public static UpdateOffer? Parse(string json, string architecture, Func<string, bool> allowed)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                Text(root, "version") is not { } version || !VersionPattern().IsMatch(version) ||
                Text(root, "page") is not { } page || !IsHttps(page) ||
                !root.TryGetProperty(architecture, out var asset) || asset.ValueKind != JsonValueKind.Object ||
                Text(asset, "url") is not { } url || !IsHttps(url) ||
                Text(asset, "sha256")?.ToLowerInvariant() is not { } sha256 || !HashPattern().IsMatch(sha256) ||
                !asset.TryGetProperty("size", out var sizeValue) || !sizeValue.TryGetInt64(out var size) || size <= 0)
            {
                return null;
            }

            var name = AssetName(version, architecture);
            if (!url.EndsWith("/" + name, StringComparison.OrdinalIgnoreCase) || !allowed(url))
            {
                return null;
            }

            return new UpdateOffer(version, page, url, url + ".sha256", name, sha256, size);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>zip 的资产名（和 build-release.ps1、发布列表里找资产用的是同一个）。</summary>
    public static string AssetName(string version, string architecture) => $"KittyTools-{version}-windows-{architecture}.zip";

    private static string? Text(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsHttps(string url)
        => Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps;
}
