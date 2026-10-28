// 启动器里的几样文字（纯函数，配单测；PLAN-v9-launcher）：副标题从中间截、浏览历史的「3 天前」、内存大小、
// 文件的种类名（扩展名大写 / 文件夹）、Markdown 链接、网址的主机、Tab 补全、应用的副标题。
using System.Globalization;

namespace KittyTools.Core;

public static class LauncherText
{
    /// <summary>
    /// 太长时从中间截（mac 副标题是 .middle 截断：路径截掉中段，开头和文件名都还在）。
    /// ponytail: 按字数截（中文和字母一样算一个），不按像素量；副标题一般是路径和网址，够用，真要齐再用 TextBlock 量宽度。
    /// </summary>
    public static string MiddleEllipsis(string text, int max = 64)
    {
        if (max < 5 || text.Length <= max)
        {
            return text;
        }

        var keep = max - 1;
        var head = (keep + 1) / 2;
        var tail = keep - head;
        // 别把代理对从中间劈开。
        if (char.IsHighSurrogate(text[head - 1]))
        {
            head--;
        }

        var start = text.Length - tail;
        if (char.IsLowSurrogate(text[start]))
        {
            start++;
        }

        return text[..head] + "…" + text[start..];
    }

    /// <summary>
    /// 浏览历史的「多久前」（mac 用系统的相对时间，zh-Hans named）：刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前 / N 周前 /
    /// N 个月前 / N 年前。按 now 算，将来的时间当成刚刚。
    /// </summary>
    public static string RelativeTime(long thenMs, long nowMs)
    {
        var seconds = Math.Max(0, (nowMs - thenMs) / 1000);
        var minutes = seconds / 60;
        var hours = minutes / 60;
        var days = hours / 24;
        return seconds switch
        {
            < 60 => "刚刚",
            _ when minutes < 60 => $"{minutes}分钟前",
            _ when hours < 24 => $"{hours}小时前",
            _ when days == 1 => "昨天",
            _ when days < 7 => $"{days}天前",
            _ when days < 31 => $"{days / 7}周前",
            _ when days < 365 => $"{Math.Max(1, days / 30)}个月前",
            _ => $"{days / 365}年前",
        };
    }

    /// <summary>浏览历史的副标题（mac BrowserHistory.subtitle）：「历史 · 主机」后面拼上多久前。</summary>
    public static string HistorySubtitle(string subtitle, long? visitedAt, long nowMs)
        => visitedAt is { } then ? subtitle + " · " + RelativeTime(then, nowMs) : subtitle;

    /// <summary>内存（mac byteCount .memory，1024 进位）：「312 MB」「1.2 GB」。</summary>
    public static string Memory(long bytes)
    {
        const double mb = 1024 * 1024;
        var megabytes = bytes / mb;
        return megabytes < 1024
            ? Math.Max(1, Math.Round(megabytes)).ToString("0", CultureInfo.InvariantCulture) + " MB"
            : (megabytes / 1024).ToString("0.#", CultureInfo.InvariantCulture) + " GB";
    }

    /// <summary>文件的种类名（mac FileSearch.kindTitle）：文件夹 / 扩展名大写（太长的不算）/ 文件。</summary>
    public static string FileKindTitle(string path, bool folder)
    {
        if (folder)
        {
            return "文件夹";
        }

        var extension = Path.GetExtension(path.TrimEnd('\\', '/'));
        return extension.Length is <= 1 or > 7 ? "文件" : extension[1..].ToUpperInvariant();
    }

    /// <summary>[标题](网址)：标题里的方括号、网址里的空格和右括号转义，粘进 Markdown 不断链（mac markdownLink）。</summary>
    public static string MarkdownLink(string title, string url)
        => $"[{title.Replace("[", "\\[", StringComparison.Ordinal).Replace("]", "\\]", StringComparison.Ordinal)}]" +
           $"({url.Replace(" ", "%20", StringComparison.Ordinal).Replace(")", "%29", StringComparison.Ordinal)})";

    /// <summary>http(s) 网址的主机（去掉 www.）；不是网页时 null。网站图标、历史的副标题用。</summary>
    public static string? Host(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) || uri.Host.Length == 0)
        {
            return null;
        }

        var host = uri.Host.ToLowerInvariant();
        return host.StartsWith("www.", StringComparison.Ordinal) ? host[4..] : host;
    }

    /// <summary>http(s) 网址（直达、书签、历史、用过的、搜索页）：才有「用别的浏览器打开」、Markdown 链接、复制标题。</summary>
    public static bool IsWebLink(LauncherItem item)
        => item.Kind is LauncherKind.Url or LauncherKind.Search &&
           (item.Target.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            item.Target.StartsWith("https://", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Tab 补进输入框的字（mac completion(for:)）：有 Completion 用它；应用、设置页、内置动作、网址、系统命令补标题；
    /// 文件夹补「路径\」；别的没得补（null）。
    /// </summary>
    public static string? Completion(LauncherItem item)
    {
        if (item.Completion is { } completion)
        {
            return completion;
        }

        return item.Kind switch
        {
            LauncherKind.App or LauncherKind.Setting or LauncherKind.Action or LauncherKind.Url or LauncherKind.Command
                => item.Title,
            LauncherKind.Path => item.IsFolder && !item.Target.EndsWith('\\') ? item.Target + "\\" : item.Target,
            _ => null,
        };
    }

    /// <summary>
    /// 应用的副标题（mac A25：不写和右边「应用」重复的话）：显示名里有汉字、exe 是英文名时写 exe 名（分清「微信」是 WeChat），
    /// 在开始菜单的子文件夹里时写文件夹名，其余留空。
    /// </summary>
    public static string AppSubtitle(string title, string? exeName, string? startMenuFolder)
    {
        var stem = exeName is null ? null : Path.GetFileNameWithoutExtension(exeName);
        if (stem is { Length: > 0 } && title.Any(Pinyin.IsHan) && stem.All(character => character < 128) &&
            !string.Equals(stem, title, StringComparison.OrdinalIgnoreCase))
        {
            return stem;
        }

        return string.IsNullOrEmpty(startMenuFolder) ||
               startMenuFolder.Equals("Programs", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(startMenuFolder, title, StringComparison.OrdinalIgnoreCase)
            ? string.Empty
            : startMenuFolder;
    }
}
