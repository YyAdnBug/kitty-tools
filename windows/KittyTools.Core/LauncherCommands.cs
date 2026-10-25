// 启动器补齐里能单测的纯函数（第三版 §6）：
// 命令前缀（空格 / open / find / kill / port）、文件搜索的匹配与排序、Chromium 书签 JSON、
// netstat 的输出（port 命令用；方案原写 GetExtendedTcpTable，这里先用 netstat 的输出，报告里说明）。
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum LauncherMode
{
    Normal,
    FileSearch,
    Kill,
    Port,
}

public static partial class LauncherCommands
{
    public static (LauncherMode Mode, string Query) Classify(string raw)
    {
        var text = raw.TrimStart();
        if (raw.StartsWith(' ') && text.Length > 0)
        {
            return (LauncherMode.FileSearch, text);
        }

        if (text.StartsWith("open ", StringComparison.OrdinalIgnoreCase))
        {
            return (LauncherMode.FileSearch, text[5..].Trim());
        }

        if (text.StartsWith("find ", StringComparison.OrdinalIgnoreCase))
        {
            return (LauncherMode.FileSearch, text[5..].Trim());
        }

        if (text.StartsWith("kill ", StringComparison.OrdinalIgnoreCase))
        {
            return (LauncherMode.Kill, text[5..].Trim());
        }

        if (text.StartsWith("port ", StringComparison.OrdinalIgnoreCase))
        {
            return (LauncherMode.Port, text[5..].Trim());
        }

        return (LauncherMode.Normal, raw);
    }

    /// <summary>文件搜索：文件名里含查询的每个词（不区分大小写）；按「开头命中 → 越短越前」排。</summary>
    public static int ScoreFileName(string fileName, IReadOnlyList<string> tokens)
    {
        if (tokens.Count == 0)
        {
            return 0;
        }

        var name = fileName.ToLowerInvariant();
        var score = 0;
        foreach (var token in tokens)
        {
            var lower = token.ToLowerInvariant();
            if (!name.Contains(lower, StringComparison.Ordinal))
            {
                return int.MinValue;
            }

            score += name.StartsWith(lower, StringComparison.Ordinal) ? 100 : 40;
        }

        return score - Math.Min(name.Length, 40);
    }
}

public readonly record struct BookmarkItem(string Title, string Url, string Source);

public static class ChromiumBookmarks
{
    /// <summary>Chromium 系（Chrome / Edge / Brave / Vivaldi）的 Bookmarks JSON：递归 url 节点。</summary>
    public static List<BookmarkItem> Parse(string json, string source)
    {
        var items = new List<BookmarkItem>();
        try
        {
            using var document = JsonDocument.Parse(json);
            if (!document.RootElement.TryGetProperty("roots", out var roots) ||
                roots.ValueKind != JsonValueKind.Object)
            {
                return items;
            }

            foreach (var root in roots.EnumerateObject())
            {
                Walk(root.Value, source, items, depth: 0);
            }
        }
        catch (JsonException)
        {
            // 文件坏了就当没有。
        }

        return items;
    }

    private static void Walk(JsonElement element, string source, List<BookmarkItem> items, int depth)
    {
        if (depth > 12 || element.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        if (element.TryGetProperty("type", out var type) && type.GetString() == "url" &&
            element.TryGetProperty("url", out var url) && url.GetString() is { Length: > 0 } href &&
            (href.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
             href.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
        {
            var title = element.TryGetProperty("name", out var name) ? name.GetString() ?? href : href;
            items.Add(new BookmarkItem(title, href, source));
        }

        if (element.TryGetProperty("children", out var children) && children.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in children.EnumerateArray())
            {
                Walk(child, source, items, depth + 1);
            }
        }
    }
}

public readonly record struct PortRow(string Protocol, string Local, int Port, int Pid);

public static partial class NetstatOutput
{
    /// <summary>解析 `netstat -ano` 的监听行（TCP LISTENING + UDP）。</summary>
    public static List<PortRow> Parse(string output)
    {
        var rows = new List<PortRow>();
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("活动连接", StringComparison.Ordinal) ||
                line.StartsWith("Active Connections", StringComparison.Ordinal) ||
                line.StartsWith("协议", StringComparison.Ordinal) || line.StartsWith("Proto", StringComparison.Ordinal))
            {
                continue;
            }

            var parts = Whitespace().Split(line);
            if (parts.Length < 4)
            {
                continue;
            }

            var protocol = parts[0].ToUpperInvariant();
            if (protocol is not ("TCP" or "UDP"))
            {
                continue;
            }

            // TCP：Proto Local Foreign State PID；UDP：Proto Local Foreign PID
            var listening = protocol == "UDP" ||
                            (parts.Length >= 5 && parts[3].Equals("LISTENING", StringComparison.OrdinalIgnoreCase));
            if (!listening)
            {
                continue;
            }

            var local = parts[1];
            var colon = local.LastIndexOf(':');
            if (colon <= 0 || !int.TryParse(local[(colon + 1)..], out var port))
            {
                continue;
            }

            var pidText = protocol == "UDP" ? parts[^1] : parts[^1];
            if (!int.TryParse(pidText, out var pid))
            {
                continue;
            }

            rows.Add(new PortRow(protocol, local[..colon], port, pid));
        }

        return rows
            .GroupBy(row => (row.Protocol, row.Local, row.Port, row.Pid))
            .Select(group => group.First())
            .OrderBy(row => row.Port)
            .ToList();
    }

    [GeneratedRegex("\\s+")]
    private static partial Regex Whitespace();
}
