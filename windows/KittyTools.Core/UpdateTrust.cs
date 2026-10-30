// 自动更新的地址白名单（REVIEW R1，配单测）：正常运行的 Release 版只认 GitHub 的 https 地址。
//
// 认的：
//   发布列表 https://api.github.com/repos/YyAdnBug/kitty-tools/releases[?...]
//   zip / .sha256 https://github.com/YyAdnBug/kitty-tools/releases/download/...
//                 https://objects.githubusercontent.com/...
//                 https://release-assets.githubusercontent.com/...
// 不认：http://、file://、本地路径、带账号密码的、非 443 端口的、主机只是长得像的
// （比如 github.com.evil.com）、路径指向别的仓库的。跳转要自己逐跳走，每一跳都过这里。
//
// 测试入口（KITTY_UPDATE_FEED、file://、本地路径、http://）只在 Debug 构建或者带
// --update-test 启动时才被认（AllowTestSources）。
namespace KittyTools.Core;

public static class UpdateTrust
{
    /// <summary>Release 版的发布列表地址（GitHub API）。</summary>
    public const string FeedUrl = "https://api.github.com/repos/YyAdnBug/kitty-tools/releases";

    /// <summary>README 里写的手测开关：Release AOT 下也认本地假发布列表。</summary>
    public const string TestArgument = "--update-test";

    private const string FeedPath = "/repos/YyAdnBug/kitty-tools/releases";
    private const string DownloadPrefix = "/YyAdnBug/kitty-tools/releases/download/";

    private static readonly string[] AssetHosts =
    {
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    };

    /// <summary>发布列表只认 GitHub API 上这个仓库的 releases。</summary>
    public static bool IsAllowedFeedUrl(string? url)
    {
        if (!TryParseHttps(url, out var uri) || !IsHost(uri, "api.github.com"))
        {
            return false;
        }

        var path = uri.AbsolutePath.TrimEnd('/');
        return string.Equals(path, FeedPath, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>zip / .sha256 的下载地址：https、主机在白名单里、github.com 上只认本仓库的 release 资产。</summary>
    public static bool IsAllowedDownloadUrl(string? url)
    {
        if (!TryParseHttps(url, out var uri))
        {
            return false;
        }

        if (IsHost(uri, "github.com"))
        {
            return uri.AbsolutePath.StartsWith(DownloadPrefix, StringComparison.OrdinalIgnoreCase);
        }

        return AssetHosts.Any(host => host != "github.com" && IsHost(uri, host));
    }

    /// <summary>
    /// 测试用的发布列表（KITTY_UPDATE_FEED、file://、本地路径、http://）只在 Debug 或 --update-test 下认。
    /// </summary>
    public static bool AllowTestSources(bool debugBuild, IReadOnlyList<string> args)
        => debugBuild || args.Any(arg => string.Equals(arg, TestArgument, StringComparison.OrdinalIgnoreCase));

    /// <summary>这个地址是不是测试用的（不是正常 Release 该走的 https GitHub 地址）。</summary>
    public static bool IsTestSource(string? url) => !IsAllowedDownloadUrl(url);

    /// <summary>
    /// 跳转的下一跳地址，百分号转义原样保留（<see cref="Uri.AbsoluteUri"/>）。不能用 <see cref="Uri.ToString"/>：
    /// 它把 %20 还原成空格，GitHub 资产跳到 release-assets.githubusercontent.com 的地址里正好有
    /// （response-content-disposition=attachment%3B%20filename…），还原后过不了这里的检查、签名也对不上——
    /// 0.1.0 / 0.1.1 的 App 内更新一点就失败（2026-10-30 用户真机报的）。
    /// </summary>
    public static string NextHop(string current, Uri location)
        => (location.IsAbsoluteUri ? location : new Uri(new Uri(current), location)).AbsoluteUri;

    private static bool IsHost(Uri uri, string host)
        => string.Equals(uri.IdnHost, host, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// 只认 https、默认端口、没有账号密码、没有控制字符 / 空白 / 反斜杠的绝对地址。
    /// （Uri 会把 https://github.com.evil.com 解析成另一个主机，这里不会放行。）
    /// </summary>
    private static bool TryParseHttps(string? url, out Uri uri)
    {
        uri = null!;
        if (string.IsNullOrWhiteSpace(url))
        {
            return false;
        }

        foreach (var c in url)
        {
            if (char.IsControl(c) || char.IsWhiteSpace(c) || c == '\\')
            {
                return false;
            }
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            return false;
        }

        if (!string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!string.IsNullOrEmpty(parsed.UserInfo))
        {
            return false;
        }

        // Uri.Port 对 https 的默认端口也是 443；显式写了别的端口就拒绝。
        if (parsed.Port != 443)
        {
            return false;
        }

        // IdnHost 为空说明主机没法解析（比如 https:///a.zip），不接受。
        if (string.IsNullOrEmpty(parsed.IdnHost))
        {
            return false;
        }

        uri = parsed;
        return true;
    }

    /// <summary>给报告 / 日志用的短描述：只保留「认 / 不认」，不打印完整地址（日志里不写 URL）。</summary>
    public static string Describe(string? url) => url is null ? "none" : IsAllowedDownloadUrl(url) ? "github" : "other";
}
