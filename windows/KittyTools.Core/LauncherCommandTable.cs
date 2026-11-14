// 启动器的「命令」表（PLAN-v18 L2，mac LauncherCommands.swift bda29731 4b022ad1 15bcac45；纯函数，配单测）：内置的关键词命令
// （open / find / quit / hide / forcequit / kill / port / ip / cb / fy / remind / currency）、系统命令（锁定、睡眠…）、以后的脚本命令，
// 每条一个别名、一个开关。别名就是要打的那个词：改了以后旧词不再认（名字和拼音照样搜得到），清空 = 只能按名字搜；
// 关掉 = 不出现在搜索、常用、收藏里，关键词也不认（收藏不删，打开就回来）。只存改过的（设置 LauncherCommandAliases / LauncherCommandsOff，
// 跟着导出导入）：没改过的跟着新版的默认走。提醒、汇率的默认别名是英文 remind、currency（中文「提醒」「汇率」、tx、huilv 照旧认）。
// 内置命令的解析各有各的（LauncherCommands.Classify、ReminderPhrase、ExchangeRates…），不为别名改它们：搜索一开头把「别名 …」换回
// 「原关键词 …」交给原来那一套（Canonical），原关键词已经改掉 / 关掉的那几条记在 Blocked 里，各解析处按它挡掉。
namespace KittyTools.Core;

public sealed record LauncherBuiltIn(string Id, string Title, string Keyword, string Glyph);

public sealed record LauncherCommandSettings
{
    /// <summary>改过的别名（存打的原样；空串 = 不要别名）。</summary>
    public IReadOnlyDictionary<string, string> Aliases { get; init; } = new Dictionary<string, string>();

    /// <summary>关掉的命令编号。</summary>
    public IReadOnlySet<string> Off { get; init; } = new HashSet<string>();

    public static readonly LauncherCommandSettings Empty = new();

    /// <summary>这一条此刻的别名（折叠过、去掉空白）：改过的用改过的（空的是 null），没改过的是原来的。</summary>
    public string? Alias(string id, string? fallback)
    {
        if (!Aliases.TryGetValue(id, out var custom))
        {
            return fallback;
        }

        var alias = LauncherCommandTable.Normalized(custom);
        return alias.Length == 0 ? null : alias;
    }

    public bool IsOn(string id) => !Off.Contains(id);

    /// <summary>改一条的别名：存打的原样，和原来的一样就不存（跟着新版的默认走）。</summary>
    public LauncherCommandSettings WithAlias(string id, string text, string? fallback)
    {
        var raw = text.Length > LauncherCommandTable.AliasLimit ? text[..LauncherCommandTable.AliasLimit] : text;
        var aliases = new Dictionary<string, string>(Aliases);
        if (LauncherCommandTable.Normalized(raw) == (fallback ?? string.Empty))
        {
            aliases.Remove(id);
        }
        else
        {
            aliases[id] = raw;
        }

        return this with { Aliases = aliases };
    }

    public LauncherCommandSettings WithOn(string id, bool on)
    {
        var off = new HashSet<string>(Off);
        if (on)
        {
            off.Remove(id);
        }
        else
        {
            off.Add(id);
        }

        return this with { Off = off };
    }

    public bool Equals(LauncherCommandSettings? other)
        => other is not null && Off.SetEquals(other.Off) && Aliases.Count == other.Aliases.Count &&
           Aliases.All(pair => other.Aliases.TryGetValue(pair.Key, out var value) && value == pair.Value);

    public override int GetHashCode() => Aliases.Count * 31 + Off.Count;
}

public static class LauncherCommandTable
{
    /// <summary>别名最长这么多字。</summary>
    public const int AliasLimit = 32;

    /// <summary>表里「内置」那一组（mac builtIns；eject 不做，Windows 的 hide 是最小化）。</summary>
    public static readonly LauncherBuiltIn[] BuiltIns =
    {
        new("builtin:open", "搜索文件并打开", "open", ""),
        new("builtin:find", "搜索文件并在资源管理器中显示", "find", ""),
        new("builtin:quit", "退出应用", "quit", ""),
        new("builtin:hide", "最小化应用", "hide", ""),
        new("builtin:forcequit", "强制退出应用", "forcequit", ""),
        new("builtin:kill", "结束进程", "kill", ""),
        new("builtin:port", "查看端口占用", "port", ""),
        new("builtin:ip", "IP 地址", "ip", ""),
        new("builtin:cb", "在剪贴板历史里搜索", "cb", ""),
        new("builtin:fy", "翻译", "fy", ""),
        // 默认别名一律英文（不用切输入法，mac 15bcac45）。中文的「提醒」「汇率」和 tx、huilv 这些照旧认
        new("builtin:reminder", "新建提醒", "remind", ""),
        new("builtin:currency", "汇率换算", "currency", ""),
    };

    public static string SystemId(string keyword) => "system:" + keyword;

    /// <summary>别名的写法：去掉空白、折叠大小写，最多 AliasLimit 个字。</summary>
    public static string Normalized(string text)
    {
        var folded = LauncherMatch.Fold(new string(text.Where(ch => !char.IsWhiteSpace(ch)).ToArray()));
        return folded.Length > AliasLimit ? folded[..AliasLimit] : folded;
    }

    /// <summary>
    /// 输入开头是改过的别名：换成原来的关键词（交给原来那一套解析）；原来的关键词已经改掉、或者这条关掉了：记进 Blocked，
    /// 这一句不当那条命令认。打的正好是另一条开着、没改名的命令自己的关键词：它优先。
    /// </summary>
    public static (string Query, IReadOnlySet<string> Blocked) Canonical(string query, LauncherCommandSettings settings)
    {
        var blocked = new HashSet<string>();
        if (settings.Aliases.Count == 0 && settings.Off.Count == 0)
        {
            return (query, blocked);
        }

        var tokenLength = query.TakeWhile(ch => !char.IsWhiteSpace(ch)).Count();
        var folded = LauncherMatch.Fold(query[..tokenLength]);
        var rest = query[tokenLength..];
        string? rewritten = null;
        var own = BuiltIns.Where(command => settings.IsOn(command.Id) && settings.Alias(command.Id, command.Keyword) == command.Keyword)
            .Select(command => command.Keyword);
        if (own.Contains(folded))
        {
            rewritten = query;
        }

        foreach (var command in BuiltIns)
        {
            if (!settings.IsOn(command.Id))
            {
                blocked.Add(command.Id);
                continue;
            }

            var alias = settings.Alias(command.Id, command.Keyword);
            if (alias == command.Keyword)
            {
                continue;
            }

            if (folded == command.Keyword)
            {
                blocked.Add(command.Id);
            }

            if (alias is not null && folded == alias && folded.Length > 0 && rewritten is null)
            {
                rewritten = command.Keyword + rest;
            }
        }

        return (rewritten ?? query, blocked);
    }

    /// <summary>提示行是哪条内置命令的（Target：system-kill、file-open、translate-fy、reminder-new、currency）。</summary>
    public static LauncherBuiltIn? BuiltInForPrompt(string target)
    {
        var keyword = target switch
        {
            _ when target.StartsWith("system-", StringComparison.Ordinal) => target["system-".Length..],
            _ when target.StartsWith("file-", StringComparison.Ordinal) => target["file-".Length..],
            "translate-fy" => "fy",
            ReminderLauncher.KeywordTarget => "remind",
            ExchangeRates.PromptTarget => "currency",
            _ => string.Empty,
        };
        return BuiltIns.FirstOrDefault(command => command.Keyword == keyword);
    }

    /// <summary>
    /// 提示行（「输入「kill 空格 进程名」」）里的关键词换成别名；那条关掉了、或者别名清空了返回 null（不出这一行）。
    /// 补全的是「关键词 空格」的才换（汇率补的是一句示例，不动）。
    /// </summary>
    public static LauncherItem? Relabel(LauncherItem item, LauncherCommandSettings settings)
    {
        if (BuiltInForPrompt(item.Target) is not { } command)
        {
            return item;
        }

        if (!settings.IsOn(command.Id))
        {
            return null;
        }

        var alias = settings.Alias(command.Id, command.Keyword);
        if (alias == command.Keyword)
        {
            return item;
        }

        if (alias is null)
        {
            return null;
        }

        return item with
        {
            Subtitle = item.Subtitle.Replace($"「{command.Keyword} ", $"「{alias} "),
            Completion = item.Completion?.StartsWith(command.Keyword + " ", StringComparison.Ordinal) == true ? alias + " " : item.Completion,
        };
    }

    /// <summary>一个别名被几条用了（连网页搜索的关键词一起算）：重复的那几条的编号。entries 是（编号，此刻的别名）。</summary>
    public static IReadOnlySet<string> Conflicts(IEnumerable<(string Id, string? Alias)> entries, IEnumerable<string> engineKeywords)
    {
        var owners = new Dictionary<string, List<string>>();
        foreach (var (id, alias) in entries)
        {
            if (string.IsNullOrEmpty(alias))
            {
                continue;
            }

            if (!owners.TryGetValue(alias, out var list))
            {
                owners[alias] = list = new List<string>();
            }

            list.Add(id);
        }

        var engines = engineKeywords.Select(LauncherMatch.Fold).ToHashSet();
        return owners.Where(pair => pair.Value.Count > 1 || engines.Contains(pair.Key)).SelectMany(pair => pair.Value).ToHashSet();
    }

    /// <summary>设置里的两份：别名（id → 原样）只存改过的、关掉的一份列表；导入时扔掉太长的。</summary>
    public static LauncherCommandSettings FromStored(IReadOnlyDictionary<string, string>? aliases, IEnumerable<string>? off)
        => new()
        {
            Aliases = (aliases ?? new Dictionary<string, string>())
                .Where(pair => pair.Value.Length <= AliasLimit)
                .ToDictionary(pair => pair.Key, pair => pair.Value),
            Off = (off ?? Array.Empty<string>()).Where(id => id.Length > 0).ToHashSet(),
        };
}
