// 链接预览的拦截规则与解析（第三版 §5，纯函数 + 单测，照 mac 的 Clipboard/LinkPreview.swift）：
// - 只有「整条文本就是一个网址」才预览；
// - 本机 / 内网 / 私有地址 / IPv6 字面量 / 带账号密码的、像一次性令牌的不访问；
// - 解析 HTML 的 <title>、description、og:image、favicon（读到 </head> 或 512 KB 就停）。
using System.Net;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class LinkPreviewRules
{
    public const int MaxHtmlBytes = 512 * 1024;

    public const int MaxImageBytes = 4 * 1024 * 1024;

    public const int MaxCachedPreviews = 12;

    public const int MaxImageEdge = 1200;

    /// <summary>整条文本只有一个网址（没有别的字）时返回它。</summary>
    public static Uri? SingleUrl(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var trimmed = text.Trim();
        if (trimmed.Length is 0 or > 4000 || trimmed.Any(char.IsWhiteSpace))
        {
            return null;
        }

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return null;
        }

        return uri;
    }

    /// <summary>能不能去访问：本机 / 内网 / 私有地址 / IPv6 字面量 / 带账号密码 / 一次性令牌都不行。</summary>
    public static bool CanFetch(Uri uri)
    {
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
        {
            return false;
        }

        if (!string.IsNullOrEmpty(uri.UserInfo))
        {
            return false;
        }

        if (uri.IsLoopback || uri.HostNameType == UriHostNameType.IPv6)
        {
            return false;
        }

        if (uri.HostNameType == UriHostNameType.IPv4)
        {
            return !IsPrivate(uri.Host);
        }

        var host = uri.Host.ToLowerInvariant();
        if (host is "localhost" or "localhost.localdomain" || host.EndsWith(".local", StringComparison.Ordinal) ||
            host.EndsWith(".internal", StringComparison.Ordinal) || host.EndsWith(".lan", StringComparison.Ordinal) ||
            !host.Contains('.', StringComparison.Ordinal))
        {
            return false;
        }

        return !LooksLikeToken(uri.AbsolutePath) && !LooksLikeToken(uri.Query);
    }

    /// <summary>像一次性令牌（很长的一串字母数字、带 signature / token 参数）的链接不访问。</summary>
    public static bool LooksLikeToken(string value)
    {
        if (value.Length < 24)
        {
            return false;
        }

        var lower = value.ToLowerInvariant();
        foreach (var marker in new[] { "token", "signature", "sig=", "expires", "x-amz-", "auth=", "key=" })
        {
            if (lower.Contains(marker, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return TokenRun().IsMatch(value) && value.Count(char.IsDigit) >= 8;
    }

    public static bool IsPrivate(string host)
    {
        if (!IPAddress.TryParse(host, out var address))
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
        {
            return bytes[0] switch
            {
                10 => true,
                127 => true,
                0 => true,
                169 when bytes[1] == 254 => true,
                172 when bytes[1] is >= 16 and <= 31 => true,
                192 when bytes[1] == 168 => true,
                _ => false,
            };
        }

        return address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || IPAddress.IPv6Loopback.Equals(address) ||
               (bytes[0] & 0xFE) == 0xFC; // fc00::/7
    }

    /// <summary>从 HTML 里取标题、描述、头图、站点图标（找不到就是 null）。</summary>
    public static LinkPreview? Parse(Uri page, string html)
    {
        if (string.IsNullOrWhiteSpace(html))
        {
            return null;
        }

        // 只看到 </head> 或 512 KB（调用方负责截断，这里再兜一次）。
        var head = html;
        var end = html.IndexOf("</head", StringComparison.OrdinalIgnoreCase);
        if (end >= 0)
        {
            head = html[..end];
        }

        var title = Tag(head, "title") ?? Meta(head, "og:title") ?? Meta(head, "twitter:title");
        var description = Meta(head, "description") ?? Meta(head, "og:description") ??
                          Meta(head, "twitter:description");
        var image = Meta(head, "og:image") ?? Meta(head, "twitter:image") ?? Icon(head);
        var name = WebUtility.HtmlDecode(title ?? string.Empty).Trim();
        var site = Meta(head, "og:site_name") ?? page.Host;
        if (name.Length == 0 && description is null && image is null)
        {
            return null;
        }

        return new LinkPreview(
            page.ToString(),
            Trim(name, 200) ?? page.Host,
            Trim(WebUtility.HtmlDecode(description ?? string.Empty).Trim(), 300),
            Absolute(page, image),
            Absolute(page, Icon(head)),
            site);
    }

    public static int ImageBudget => MaxImageBytes;

    private static string? Absolute(Uri page, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return Uri.TryCreate(page, value.Trim(), out var absolute) &&
               (absolute.Scheme == Uri.UriSchemeHttp || absolute.Scheme == Uri.UriSchemeHttps)
            ? absolute.ToString()
            : null;
    }

    private static string? Trim(string? value, int max)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max];
    }

    private static string? Tag(string html, string name)
    {
        var match = Regex.Match(
            html, $"<{name}[^>]*>(.*?)</{name}>",
            RegexOptions.IgnoreCase | RegexOptions.Singleline, TimeSpan.FromSeconds(1));
        return match.Success ? match.Groups[1].Value : null;
    }

    private static string? Meta(string html, string property)
    {
        foreach (var match in Regex.Matches(
                     html, "<meta\\s[^>]*>", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)).Cast<Match>())
        {
            var tag = match.Value;
            var key = Attribute(tag, "property") ?? Attribute(tag, "name");
            if (key is null || !string.Equals(key, property, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            return Attribute(tag, "content");
        }

        return null;
    }

    private static string? Icon(string html)
    {
        foreach (var match in Regex.Matches(
                     html, "<link\\s[^>]*>", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)).Cast<Match>())
        {
            var tag = match.Value;
            if (Attribute(tag, "rel")?.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                    .Any(part => part.Equals("icon", StringComparison.OrdinalIgnoreCase)) == true)
            {
                return Attribute(tag, "href");
            }
        }

        return null;
    }

    private static string? Attribute(string tag, string name)
    {
        var match = Regex.Match(
            tag, $"{name}\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
        if (!match.Success)
        {
            return null;
        }

        return match.Groups[2].Success ? match.Groups[2].Value
            : match.Groups[3].Success ? match.Groups[3].Value
            : match.Groups[4].Value;
    }

    [GeneratedRegex("[A-Za-z0-9_-]{32,}")]
    private static partial Regex TokenRun();
}

public sealed record LinkPreview(
    string Url,
    string Title,
    string? Description,
    string? ImageUrl,
    string? IconUrl,
    string Site);
