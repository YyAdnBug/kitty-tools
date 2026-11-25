// 启动器文件搜索的说明行（PLAN-v25 F9、F15；纯函数，配单测）：
// - Pick：文件结果最后一行出哪一条（同 mac FileSearch.accessHint 的位置），只出一条，优先级 服务 > 正在建 > 暂停 > 有盘不在索引里；
//   「有盘不在索引里」只在结果少于 FewResults 条时出（用户故意不收 D 盘的，不该每次都看到）；用着 Everything 时什么都不出。
// - Status：设置 › 启动器「建了索引的位置」那张卡的说明（同一套判断）；LogLine：--file-search-status 的一行日志（不含路径）。
// - FallbackItem：普通搜索兜底那一组第一行「在文件里找「词」」（F15），Enter 把输入框换成「空格 + 词」进文件搜索。
// 状态是 App 侧读的原值（SearchIndexStatus：服务、索引目录的 CatalogStatus / CatalogPausedReason 枚举、待建项数、哪些位置不在索引里）。
namespace KittyTools.Core;

/// <summary>Windows Search 服务（WSearch）的状态。</summary>
public enum IndexService
{
    Unknown,
    Running,
    Stopped,
    Disabled,
    Missing,
}

/// <summary>这次文件结果是从哪来的。</summary>
public enum FileSearchSource
{
    /// <summary>Windows 搜索的索引（可能并上了不在索引里的常用文件夹扫出来的）。</summary>
    Index,

    /// <summary>索引用不了，只扫了常用文件夹。</summary>
    Walk,

    Everything,
}

/// <summary>
/// 读到的索引状态。CatalogStatus / PausedReason 是 searchapi.h 的 CatalogStatus / CatalogPausedReason 原值（-1 = 没读到）；
/// ItemsToIndex、ItemCount -1 = 没读到；UncoveredDrives 是「D:」这种写法；UncoveredFolders 是常用文件夹里不在索引里的完整路径。
/// </summary>
public sealed record FileIndexStatus(
    IndexService Service,
    int CatalogStatus,
    int PausedReason,
    int ItemsToIndex,
    int ItemCount,
    IReadOnlyList<string> UncoveredDrives,
    IReadOnlyList<string> UncoveredFolders);

public static class FileSearchHints
{
    public const string FallbackTarget = "file-fallback";

    /// <summary>↩ 启用 Windows 搜索（以管理员身份跑 sc.exe）。</summary>
    public const string ServiceTarget = "file-hint:service";

    /// <summary>↩ 打开 设置 › 隐私和安全性 › 搜索 Windows。</summary>
    public const string SettingsTarget = "file-hint:settings";

    /// <summary>没什么可做的（这台电脑没有搜索服务）：↩ 只响一声。</summary>
    public const string NoneTarget = "file-hint:none";

    public const string HintPrefix = "file-hint:";

    /// <summary>「有盘不在索引里」那一条在结果少于这么多条时才出。</summary>
    public const int FewResults = 5;

    /// <summary>增量建索引时还剩这么多项以上才算「还在建」（零星几项是平常的）。</summary>
    public const int BusyThreshold = 1000;

    // searchapi.h CatalogStatus
    private const int StatusPaused = 1;
    private const int StatusRecovering = 2;
    private const int StatusFullCrawl = 3;
    private const int StatusIncrementalCrawl = 4;

    public static bool IsHint(string target) => target.StartsWith(HintPrefix, StringComparison.Ordinal);

    /// <summary>文件结果最后一行；不用出时是 null。resultCount：这次的文件结果条数（不含这一行）。</summary>
    public static LauncherItem? Pick(FileIndexStatus? status, FileSearchSource source, int resultCount)
    {
        switch (source)
        {
            case FileSearchSource.Everything:
                return null;
            case FileSearchSource.Walk:
                return status?.Service switch
                {
                    IndexService.Missing => Item(NoneTarget, "这台电脑没有 Windows 搜索服务，只找了桌面、文档这几个文件夹", "结果可能不全"),
                    IndexService.Stopped or IndexService.Disabled => Item(ServiceTarget,
                        "Windows 搜索服务没开，只找了桌面、文档这几个文件夹", "↩ 启用 Windows 搜索（要管理员确认）"),
                    _ => Item(SettingsTarget, "Windows 搜索的索引现在用不了，只找了桌面、文档这几个文件夹", "↩ 打开搜索设置"),
                };
        }

        if (status is null)
        {
            return null;
        }

        if (IsIndexing(status))
        {
            return Item(SettingsTarget,
                status.ItemsToIndex > 0 ? $"Windows 还在建索引（还剩约 {Items(status.ItemsToIndex)}），结果可能不全" : "Windows 还在建索引，结果可能不全",
                "↩ 打开搜索设置看进度");
        }

        if (IsPaused(status))
        {
            return Item(SettingsTarget, $"Windows 的索引暂停了{PauseReason(status.PausedReason)}，新文件可能搜不到", "↩ 打开搜索设置");
        }

        if (resultCount < FewResults && status.UncoveredDrives.Count > 0)
        {
            return Item(SettingsTarget, $"{Quoted(status.UncoveredDrives)}不在 Windows 搜索的索引里，里面的文件搜不到",
                "↩ 打开搜索设置，选「增强」或把它们加进索引");
        }

        return null;
    }

    /// <summary>设置页那张卡的说明：文字 + 是不是配置问题（橙字）。status 是 null = 还没读到 / 读不出来。</summary>
    public static (string Text, bool Problem) Status(FileIndexStatus? status)
    {
        if (status is null)
        {
            return ("读不出 Windows 搜索的状态", false);
        }

        switch (status.Service)
        {
            case IndexService.Missing:
                return ("这台电脑没有 Windows 搜索服务：只能找桌面、文档这几个文件夹", true);
            case IndexService.Stopped:
                return ("Windows 搜索服务没开：只能找桌面、文档这几个文件夹", true);
            case IndexService.Disabled:
                return ("Windows 搜索服务被禁用了：只能找桌面、文档这几个文件夹", true);
        }

        var items = status.ItemCount >= 0 ? $" · 已编入约 {Items(status.ItemCount)}" : string.Empty;
        if (IsIndexing(status))
        {
            return (status.ItemsToIndex > 0 ? $"正在建索引，还剩约 {Items(status.ItemsToIndex)}" : "正在建索引", false);
        }

        if (IsPaused(status))
        {
            return ($"索引暂停了{PauseReason(status.PausedReason)}" + items, false);
        }

        if (status.UncoveredDrives.Count > 0)
        {
            return ($"{Quoted(status.UncoveredDrives)}不在索引里，里面的文件搜不到" + items, true);
        }

        return ("正常" + items, false);
    }

    /// <summary>日志一行（不写路径：常用文件夹只记个数，盘只记盘符）。</summary>
    public static string LogLine(FileIndexStatus? status)
        => status is null
            ? "files.status unknown"
            : $"files.status service={status.Service} catalog={status.CatalogStatus} paused={status.PausedReason} " +
              $"pending={status.ItemsToIndex} items={status.ItemCount} drives-out={string.Join(',', status.UncoveredDrives)} " +
              $"folders-out={status.UncoveredFolders.Count}";

    /// <summary>普通搜索兜底那一组的第一行（F15）：只在出兜底的时候、输入够长时加。</summary>
    public static LauncherItem FallbackItem(string query) => new()
    {
        Kind = LauncherKind.Prompt,
        Target = FallbackTarget,
        Title = $"在文件里找「{query}」",
        Subtitle = "空格开头也能直接搜文件",
        Completion = " " + query,
    };

    private static bool IsIndexing(FileIndexStatus status)
        => status.CatalogStatus is StatusRecovering or StatusFullCrawl ||
           (status.CatalogStatus == StatusIncrementalCrawl && status.ItemsToIndex >= BusyThreshold);

    /// <summary>暂停了、而且还有一堆没建（没什么要建时暂停不影响搜索，不提）。</summary>
    private static bool IsPaused(FileIndexStatus status)
        => status.CatalogStatus == StatusPaused && status.ItemsToIndex >= BusyThreshold;

    /// <summary>searchapi.h CatalogPausedReason → 括号里的原因；不认识的不写。</summary>
    private static string PauseReason(int reason) => reason switch
    {
        1 or 2 or 3 => "（电脑正忙）",
        4 => "（在用电池）",
        5 => "（内存不够）",
        6 => "（磁盘空间不够）",
        8 => "（你正在用电脑，空闲时会接着建）",
        10 => "（Windows 正在更新）",
        _ => string.Empty,
    };

    /// <summary>项数：「2000 项」，1 万以上「1.2 万项」。</summary>
    public static string Items(int value)
        => value >= 10_000
            ? (value / 10_000.0).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + " 万项"
            : value.ToString(System.Globalization.CultureInfo.InvariantCulture) + " 项";

    /// <summary>「D:」「E:」，多于 3 个写前 3 个 +「等」。</summary>
    private static string Quoted(IReadOnlyList<string> names)
        => string.Concat(names.Take(3).Select(name => $"「{name}」")) + (names.Count > 3 ? "等" : string.Empty);

    private static LauncherItem Item(string target, string title, string subtitle) => new()
    {
        Kind = LauncherKind.Prompt,
        Target = target,
        Title = title,
        Subtitle = subtitle,
    };
}
