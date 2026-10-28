// 启动器补齐里能单测的纯函数（第三版 §6，PLAN-v9-launcher 照 mac 补齐）：
// 命令前缀（空格 / open / find / kill / port / quit / hide / forcequit）、只输关键词时的补全提示、
// 带对象模式的分组标题 / 空结果说法 / 过滤 / 排序 / 上膛提示（mac SystemCommands、FileSearch、Processes）、
// 文件搜索的匹配与排序、Chromium 书签 JSON、netstat 的输出（只剩单测在用，port 走 PortTable）。
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public enum LauncherMode
{
    Normal,

    /// <summary>open 词 / 空格开头：Enter 打开（Ctrl+Enter 在资源管理器中显示）。</summary>
    FileSearch,
    Kill,
    Port,

    // 2026-10-28 对齐 mac 加的。

    /// <summary>find 词：Enter 在资源管理器中显示（Ctrl+Enter 打开），和 open 反过来。</summary>
    FileFind,

    /// <summary>quit 空格：正在运行的应用，Enter 关窗口退出、Ctrl+Enter 强制退出（上膛）。</summary>
    Quit,

    /// <summary>hide 空格：正在运行的应用，Enter 最小化它的窗口。</summary>
    Hide,

    /// <summary>forcequit 空格：正在运行的应用，Enter 结束进程（上膛）。</summary>
    ForceQuit,
}

public static partial class LauncherCommands
{
    /// <summary>带对象的命令的关键词（mac Verb 的 rawValue，eject 不做：PLAN-v9-launcher D4）。</summary>
    private static readonly (string Keyword, LauncherMode Mode)[] Verbs =
    {
        ("open", LauncherMode.FileSearch),
        ("find", LauncherMode.FileFind),
        ("quit", LauncherMode.Quit),
        ("hide", LauncherMode.Hide),
        ("forcequit", LauncherMode.ForceQuit),
        ("kill", LauncherMode.Kill),
        ("port", LauncherMode.Port),
    };

    /// <summary>
    /// 「open 词」「find 词」「quit 词」…；关键词后面要有空白，只输关键词不算（出补全提示，不抢同名应用）。
    /// 空格开头 = 搜文件；只有空格 = 普通。
    /// </summary>
    public static (LauncherMode Mode, string Query) Classify(string raw)
    {
        var text = raw.TrimStart();
        if (raw.Length > 0 && char.IsWhiteSpace(raw[0]) && text.Length > 0)
        {
            return (LauncherMode.FileSearch, text.Trim());
        }

        foreach (var (keyword, mode) in Verbs)
        {
            if (text.Length > keyword.Length && char.IsWhiteSpace(text[keyword.Length]) &&
                text.StartsWith(keyword, StringComparison.OrdinalIgnoreCase))
            {
                return (mode, text[keyword.Length..].Trim());
            }
        }

        return (LauncherMode.Normal, raw);
    }

    /// <summary>quit / hide / forcequit / kill / port 的关键词（Tab 补全「关键词 名字」用）。</summary>
    public static string Keyword(LauncherMode mode) => Verbs.FirstOrDefault(verb => verb.Mode == mode).Keyword ?? string.Empty;

    /// <summary>「cb」或「cb 关键词」（不分大小写：「CB 会议」也算）；返回关键词（单输 cb 是空串），不是就 null。</summary>
    public static string? ClipQuery(string query)
    {
        var text = query.TrimStart();
        if (text.Equals("cb", StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        return text.Length > 2 && char.IsWhiteSpace(text[2]) && text.StartsWith("cb", StringComparison.OrdinalIgnoreCase)
            ? text[3..].Trim()
            : null;
    }

    /// <summary>cb 那一行（mac clipItem）：启动器里不列剪贴板条目，Enter 交给剪贴板面板去搜。</summary>
    public static LauncherItem ClipItem(string keyword) => new()
    {
        Kind = LauncherKind.Clip,
        Target = keyword,
        Title = keyword.Length == 0 ? "打开剪贴板历史" : $"在剪贴板历史里搜索「{keyword}」",
        HotKeyAction = "clipboard",
    };

    /// <summary>「fy 文本」的文本（不分大小写；只输 fy 不算，出补全提示）。</summary>
    public static string? TranslateQuery(string query)
    {
        var text = query.TrimStart();
        if (text.Length <= 3 || !char.IsWhiteSpace(text[2]) || !text.StartsWith("fy", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var rest = text[3..].Trim();
        return rest.Length == 0 ? null : rest;
    }

    /// <summary>
    /// fy 那一行（mac translateItem）：Enter 收起启动器、翻译浮窗直接翻译。definition：副标题的释义
    /// （mac 是系统词典的第一条；Windows 没有系统词典，用本机翻译历史里这个词上一次的译文，见 LauncherModel）。
    /// </summary>
    public static LauncherItem TranslateItem(string text, string definition = "") => new()
    {
        Kind = LauncherKind.Translate,
        Target = text,
        Title = $"翻译「{text}」",
        Subtitle = LauncherText.FirstLine(definition),
        HotKeyAction = "inputTranslate",
    };

    /// <summary>单输 fy：Enter / Tab 补全关键词的提示。</summary>
    public static List<LauncherItem> TranslatePrompts(string query)
        => LauncherMatch.Fold(query.Trim()) == "fy"
            ? new List<LauncherItem>
            {
                new()
                {
                    Kind = LauncherKind.Prompt,
                    Target = "translate-fy",
                    Title = "翻译…",
                    Subtitle = "输入「fy 空格 文字」，Enter 或 Tab 补全关键词",
                    Completion = "fy ",
                },
            }
            : new List<LauncherItem>();

    public static bool IsFileMode(this LauncherMode mode) => mode is LauncherMode.FileSearch or LauncherMode.FileFind;

    /// <summary>列的是进程（在后台列、异步到）。</summary>
    public static bool ListsProcesses(this LauncherMode mode) => mode is LauncherMode.Kill or LauncherMode.Port;

    /// <summary>列的是有窗口的应用（quit / hide / forcequit）。</summary>
    public static bool ListsApps(this LauncherMode mode)
        => mode is LauncherMode.Quit or LauncherMode.Hide or LauncherMode.ForceQuit;

    /// <summary>文件搜索：只有一个拉丁字母（或数字）的词先不查（mac isTooShort）；一个汉字照查。</summary>
    public static bool IsTooShort(string terms)
    {
        var words = terms.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 0 && !words.Any(word => word.Length >= 2 || word.Any(character => character > 127));
    }

    /// <summary>
    /// 单输（或拼到一半）open / find / quit / hide / forcequit / kill / port 时的补全提示：正好是关键词的放最前（Exact），
    /// ≥ 2 个字的开头放本地结果后面（Partial）。Enter / Tab 把「关键词 」补进框。
    /// </summary>
    public static (List<LauncherItem> Exact, List<LauncherItem> Partial) PromptItems(string query)
    {
        var text = LauncherMatch.Fold(query.Trim());
        var exact = new List<LauncherItem>();
        var partial = new List<LauncherItem>();
        foreach (var (keyword, mode) in Verbs)
        {
            var item = new LauncherItem
            {
                Kind = LauncherKind.Prompt,
                Target = (mode.IsFileMode() ? "file-" : "system-") + keyword,
                Title = PromptTitle(mode),
                Subtitle = $"输入「{keyword} 空格 {Noun(mode)}」，Enter 或 Tab 补全关键词",
                Completion = keyword + " ",
            };
            if (text == keyword)
            {
                exact.Add(item);
            }
            else if (text.Length >= 2 && keyword.StartsWith(text, StringComparison.Ordinal))
            {
                partial.Add(item);
            }
        }

        return (exact, partial);
    }

    /// <summary>补全提示那一行的标题（mac Verb.prompt；「App」在 Windows 上叫「应用」）。</summary>
    public static string PromptTitle(LauncherMode mode) => mode switch
    {
        LauncherMode.FileSearch => "搜索文件并打开…",
        LauncherMode.FileFind => "搜索文件并在资源管理器中显示…",
        LauncherMode.Quit => "退出正在运行的应用…",
        LauncherMode.Hide => "最小化应用…",
        LauncherMode.ForceQuit => "强制退出应用…",
        LauncherMode.Kill => "结束进程…",
        LauncherMode.Port => "查看端口占用…",
        _ => string.Empty,
    };

    private static string Noun(LauncherMode mode) => mode switch
    {
        LauncherMode.FileSearch or LauncherMode.FileFind => "文件名",
        LauncherMode.Kill => "进程名或 :端口",
        LauncherMode.Port => "端口号或进程名",
        _ => "应用名",
    };

    /// <summary>Enter 的动作名（底栏主动作、Ctrl+K 第一行）；port 的行按 RowMode 办。</summary>
    public static string VerbTitle(LauncherMode mode) => mode switch
    {
        LauncherMode.Quit => "退出",
        LauncherMode.Hide => "最小化",
        LauncherMode.ForceQuit => "强制退出",
        LauncherMode.Kill or LauncherMode.Port => "结束",
        _ => "打开",
    };

    /// <summary>只输了关键词（列全部）时的分组标题。</summary>
    public static string? GroupTitle(LauncherMode mode, string terms)
    {
        if (terms.Trim().Length > 0)
        {
            return null;
        }

        return mode switch
        {
            LauncherMode.FileSearch or LauncherMode.FileFind => "最近打开的文件",
            LauncherMode.Kill => "后台进程",
            LauncherMode.Port => "在监听的端口",
            LauncherMode.Quit or LauncherMode.Hide or LauncherMode.ForceQuit => "正在运行的应用",
            _ => null,
        };
    }

    /// <summary>
    /// port 的一行按哪个命令办（mac rowVerb）：有窗口的程序同 quit（Enter 关窗口、Ctrl+Enter 强制退出），
    /// 后台进程同 kill；别的模式就是它自己。
    /// </summary>
    public static LauncherMode RowMode(LauncherMode mode, LauncherProcess? process)
        => mode == LauncherMode.Port ? process?.HasWindow == true ? LauncherMode.Quit : LauncherMode.Kill : mode;

    /// <summary>还在列、列完了没有结果时那一行字（mac showTargets 的 emptyText；port 写「没有找到」：别的用户的进程看不到）。</summary>
    public static string EmptyText(LauncherMode mode, string terms, bool loading)
    {
        var text = terms.Trim();
        if (loading)
        {
            return mode switch
            {
                LauncherMode.Port => "正在读取端口…",
                LauncherMode.Kill => "正在读取进程…",
                LauncherMode.FileSearch or LauncherMode.FileFind => "正在找文件…",
                _ => "正在读取正在运行的应用…",
            };
        }

        if (mode.IsFileMode())
        {
            return text.Length == 0 ? "最近没有打开的文件" : IsTooShort(text) ? "再输入一个字母" : "没有匹配的文件";
        }

        return (mode, text.Length == 0) switch
        {
            (LauncherMode.Kill, true) => "没有后台进程",
            (LauncherMode.Kill, false) when text.StartsWith(':') => "没有进程在监听这个端口",
            (LauncherMode.Port, true) => "没有找到在监听端口的进程",
            (LauncherMode.Port, false) when PortDigits(text) is not null => "没有找到监听这个端口的进程",
            (LauncherMode.Kill or LauncherMode.Port, false) => "没有匹配的进程",
            (_, true) => "没有正在运行的应用",
            _ => "没有匹配的应用",
        };
    }

    /// <summary>port 只输了数字（前面带不带冒号都行）：要找的是端口；返回那串数字（可以是空串 =「port :」）。</summary>
    public static string? PortDigits(string terms)
    {
        var match = PortTermRegex().Match(terms.Trim());
        return match.Success ? match.Groups[1].Value : null;
    }

    /// <summary>
    /// 带对象模式里按输入的词过滤（mac showTargets）：kill 的「:3000」「:」只按监听的端口（开头）筛、保持原顺序；
    /// port 只输数字时按端口号的开头筛、保持端口顺序（「port 80」不带出 5180）；别的词按名字排。
    /// </summary>
    public static List<LauncherItem> FilterTargets(IReadOnlyList<LauncherItem> targets, LauncherMode mode, string terms)
    {
        var text = terms.Trim();
        if (text.Length == 0)
        {
            return targets.ToList();
        }

        if (mode == LauncherMode.Kill && text.StartsWith(':'))
        {
            return targets.Where(item => item.Process?.Ports.Any(port => (":" + port).StartsWith(text, StringComparison.Ordinal)) == true)
                .ToList();
        }

        if (mode == LauncherMode.Port && PortDigits(text) is { } digits)
        {
            return targets.Where(item => item.Title.StartsWith(":" + digits, StringComparison.Ordinal)).ToList();
        }

        return LauncherMatch.Rank(targets, text);
    }

    /// <summary>kill 的排法（mac Processes.items）：监听端口的在前 → 不在系统目录里的 → 内存大的。</summary>
    public static List<LauncherProcess> SortProcesses(IEnumerable<LauncherProcess> processes, string windowsDirectory)
        => processes
            .OrderBy(process => process.Ports.Count == 0)
            .ThenBy(process => IsSystem(process, windowsDirectory))
            .ThenByDescending(process => process.MemoryBytes)
            .ToList();

    /// <summary>系统目录（%WINDIR%）里的程序：排在后面，不藏（mac 也不藏系统服务）。</summary>
    public static bool IsSystem(LauncherProcess process, string windowsDirectory)
        => windowsDirectory.Length > 0 && process.ExePath is { } path &&
           path.StartsWith(windowsDirectory.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);

    /// <summary>kill 的一行（mac Processes.item）：标题进程名，副标题「PID 4321 · 312 MB · 监听 :3000」，PID 和 :端口 也能搜。</summary>
    public static LauncherItem ProcessItem(LauncherProcess process)
    {
        var parts = new List<string> { "PID " + process.Pid, LauncherText.Memory(process.MemoryBytes) };
        if (process.Ports.Count > 0)
        {
            parts.Add("监听 " + string.Join("、", process.Ports.Select(port => ":" + port)));
        }

        var names = new List<string> { LauncherMatch.Fold(process.Name), process.Pid.ToString() };
        if (!string.Equals(process.Label, process.Name, StringComparison.OrdinalIgnoreCase))
        {
            names.Add(LauncherMatch.Fold(process.Label));
        }

        names.AddRange(process.Ports.Select(port => ":" + port));
        return new LauncherItem
        {
            Kind = LauncherKind.Process,
            Target = process.Pid.ToString(),
            Title = process.Label,
            Subtitle = string.Join(" · ", parts),
            Names = names,
            Completion = "kill " + process.Name,
            Process = process,
        };
    }

    /// <summary>
    /// port 的行（mac Processes.portItems）：一个在监听的端口一行、按端口号排（一个进程监听几个就有几行，目标「PID:端口」）；
    /// 父进程也在监听同一个端口的只列父进程。标题「:3000」，副标题「node · PID 4321」。
    /// ponytail: mac 副标题最后还有进程的工作目录（分清几个 node）；Windows 读别的进程的工作目录要读它的 PEB，先不做。
    /// </summary>
    public static List<LauncherItem> PortItems(IReadOnlyList<LauncherProcess> processes, IReadOnlyDictionary<int, int> parents)
    {
        var byPid = processes.ToDictionary(process => process.Pid);
        var rows = new List<(int Port, LauncherProcess Process)>();
        foreach (var process in processes)
        {
            foreach (var port in process.Ports.Distinct())
            {
                if (parents.TryGetValue(process.Pid, out var parent) && byPid.TryGetValue(parent, out var owner) &&
                    owner.Ports.Contains(port))
                {
                    continue;
                }

                rows.Add((port, process));
            }
        }

        return rows
            .OrderBy(row => row.Port)
            .ThenBy(row => row.Process.Pid)
            .Select(row => new LauncherItem
            {
                Kind = LauncherKind.Process,
                Target = $"{row.Process.Pid}:{row.Port}",
                Title = ":" + row.Port,
                Subtitle = $"{row.Process.Label} · PID {row.Process.Pid}",
                Names = new List<string>
                    {
                        row.Port.ToString(),
                        LauncherMatch.Fold(row.Process.Label),
                        LauncherMatch.Fold(row.Process.Name),
                    }
                    .Distinct()
                    .ToList(),
                Completion = "port " + row.Port,
                Process = row.Process,
            })
            .ToList();
    }

    /// <summary>
    /// quit / hide / forcequit 的一行（mac SystemCommands.appItem）：前台那个排第一、其余按名字；
    /// 副标题是 exe 名（和标题一样时不写）；Tab 补成「关键词 名字」。
    /// </summary>
    public static List<LauncherItem> AppTargets(IEnumerable<LauncherProcess> apps, int foregroundPid, string keyword)
        => apps
            .OrderBy(app => app.Pid != foregroundPid)
            .ThenBy(app => app.Label, StringComparer.CurrentCultureIgnoreCase)
            .Select(app =>
            {
                var pinyin = Pinyin.For(app.Label);
                var names = new List<string> { LauncherMatch.Fold(app.Label), LauncherMatch.Fold(app.Name) };
                if (pinyin is { } value)
                {
                    names.Add(value.Full);
                }

                return new LauncherItem
                {
                    Kind = LauncherKind.Process,
                    Target = app.Pid.ToString(),
                    Title = app.Label,
                    Subtitle = string.Equals(app.Label, app.Name, StringComparison.OrdinalIgnoreCase) ? string.Empty : app.Name + ".exe",
                    Names = names.Where(name => name.Length > 0).Distinct().ToList(),
                    Initials = new[] { LauncherMatch.Initials(app.Name), pinyin?.Initials }
                        .Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
                    Completion = keyword + " " + app.Label,
                    IconPath = app.ExePath,
                    Process = app,
                };
            })
            .ToList();

    /// <summary>结束进程上膛后的副标题（Windows 没有「先礼后兵」，kill 的 Enter 就是硬结束）。name：port 的行标题是端口号，提示里写上是谁。</summary>
    public static string KillConfirmation(string? name = null)
        => $"再按 Enter 结束{(name is null ? string.Empty : $"「{name}」")}，没存的内容会丢失";

    /// <summary>强制退出上膛后的副标题（forcequit 的 Enter、quit 和 port 窗口程序的 Ctrl+Enter）。</summary>
    public static string ForceQuitConfirmation(string key, string? name = null)
        => $"再按 {key} 强制退出{(name is null ? string.Empty : $"「{name}」")}，没存的内容会丢失";

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

    [GeneratedRegex(@"^:?(\d*)$")]
    private static partial Regex PortTermRegex();
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
