// 启动器的直达项（纯函数，配单测）：输入像网址就「在浏览器中打开」，像存在的路径就「打开」，都排在最前。
// 网址规则照 mac DirectItems：带 http(s):// / mailto:，或 IPv4 / localhost（可带端口），或常见后缀的域名；
// 域名后面紧跟 / 或 :端口 时最后一段是 2–13 个字母也认；「Safari.app」「install.sh」这类文件名不算网址。
// 路径（Windows）：C:\…、C:/…、\\服务器\共享、%环境变量%、~\ 开头且真实存在；不认 ./ 这类相对路径。
namespace KittyTools.Core;

public static class DirectItems
{
    private static readonly HashSet<string> TopLevelDomains = new(StringComparer.OrdinalIgnoreCase)
    {
        "com", "cn", "net", "org", "io", "dev", "me", "co", "tv", "ai", "edu", "gov", "info", "biz",
        "uk", "jp", "de", "fr", "top", "xyz", "do", "gg", "im", "ly", "to", "tech",
        "site", "online", "app",
    };

    public static List<LauncherItem> ItemsFor(string query)
    {
        if (UrlFrom(query) is { } url)
        {
            return new List<LauncherItem>
            {
                new()
                {
                    Kind = LauncherKind.Url,
                    Target = url,
                    Title = DisplayName(url),
                    Subtitle = "在浏览器中打开",
                    Completion = query.Trim(),
                },
            };
        }

        if (ExistingPathFrom(query) is { } path)
        {
            return new List<LauncherItem>
            {
                new()
                {
                    Kind = LauncherKind.Path,
                    Target = path,
                    Title = Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : path,
                    Subtitle = path,
                    Completion = path,
                },
            };
        }

        return new List<LauncherItem>();
    }

    public static string? UrlFrom(string query)
    {
        var text = query.Trim();
        if (text.Length == 0 || text.Any(char.IsWhiteSpace))
        {
            return null;
        }

        var lower = text.ToLowerInvariant();
        if (lower.StartsWith("http://", StringComparison.Ordinal) ||
            lower.StartsWith("https://", StringComparison.Ordinal) ||
            lower.StartsWith("mailto:", StringComparison.Ordinal))
        {
            return Uri.TryCreate(text, UriKind.Absolute, out _) ? text : null;
        }

        var host = new string(lower.TakeWhile(character => character is not ('/' or '?' or '#')).ToArray());
        var colon = host.IndexOf(':');
        var hostName = colon >= 0 ? host[..colon] : host;
        var isIpv4 = hostName.Split('.').Length == 4 &&
                     hostName.Split('.').All(part => byte.TryParse(part, out _));
        var isLocalhost = hostName == "localhost";
        var labels = hostName.Split('.');
        var suffix = labels[^1];
        var rest = lower[hostName.Length..];
        var followed = rest.StartsWith('/') ||
                       (rest.StartsWith(':') && rest.Length > 1 && char.IsAsciiDigit(rest[1]));
        var isDomain = labels.Length >= 2 &&
                       labels.All(label => label.Length > 0) &&
                       (TopLevelDomains.Contains(suffix) ||
                        (followed && suffix.Length is >= 2 and <= 13 &&
                         suffix.All(character => char.IsAsciiLetter(character)))) &&
                       hostName.All(character => char.IsLetterOrDigit(character) || character is '-' or '.') &&
                       // 单独的 Safari.app 不算网址；带 www. 或路径才算
                       !(suffix == "app" && labels.Length == 2 && host == lower && !lower.StartsWith("www."));

        if (!isIpv4 && !isLocalhost && !isDomain)
        {
            return null;
        }

        var scheme = isIpv4 || isLocalhost ? "http://" : "https://";
        var candidate = scheme + text;
        return Uri.TryCreate(candidate, UriKind.Absolute, out _) ? candidate : null;
    }

    public static string? ExistingPathFrom(string query)
    {
        var text = query.Trim();
        if (text.Length == 0)
        {
            return null;
        }

        string candidate;
        if (text.StartsWith("~", StringComparison.Ordinal))
        {
            if (text.Length > 1 && text[1] is not ('\\' or '/'))
            {
                return null;
            }

            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            candidate = text.Length <= 2 ? home : Path.Combine(home, text[2..]);
        }
        else if (text.StartsWith('%'))
        {
            candidate = Environment.ExpandEnvironmentVariables(text);
            if (candidate == text)
            {
                return null;
            }
        }
        else if (IsAbsoluteWindowsPath(text))
        {
            candidate = text;
        }
        else
        {
            return null;
        }

        try
        {
            candidate = Path.GetFullPath(candidate);
            return File.Exists(candidate) || Directory.Exists(candidate) ? candidate : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static string DisplayName(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            return url;
        }

        if (parsed.Scheme == "mailto")
        {
            return parsed.ToString();
        }

        var port = parsed.IsDefaultPort ? string.Empty : ":" + parsed.Port;
        var path = Uri.UnescapeDataString(parsed.AbsolutePath);
        return parsed.Host + port + (path == "/" ? string.Empty : path);
    }

    private static bool IsAbsoluteWindowsPath(string text)
    {
        if (text.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return true;
        }

        return text.Length >= 3 && char.IsAsciiLetter(text[0]) && text[1] == ':' &&
               (text[2] == '\\' || text[2] == '/');
    }
}
