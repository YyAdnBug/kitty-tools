// 启动器的一条结果（纯数据）：给匹配和排序用；界面按 Kind 决定图标和动作。
// Names / Initials 存的是 LauncherMatch.Fold 之后的小写折叠文本，构建时折一次，之后每次按键只折查询。
// 照 mac LauncherItem（PLAN-v9-launcher）：应用、设置页、系统命令、内置动作、网址、文件这几类记使用、能收藏；
// 网页搜索、计算、cb 那一行、fy 那一行、补全提示、kill / port / quit 列出来的进程、「ip」列的地址不记。
// 是 record：浏览历史的副标题按搜的那一刻拼「3 天前」，用 with 换一份。
namespace KittyTools.Core;

public enum LauncherKind
{
    App,
    Setting,
    Command,
    Action,
    Url,
    Path,
    Search,
    Calculation,

    // 2026-10-28 对齐 mac 加的四种。只加在最后：收藏表按名字存 Kind、使用记录按 KindText 存。

    /// <summary>「cb [关键词]」那一行（Target = 关键词）：Enter 呼出剪贴板面板、把关键词填进它的搜索框。</summary>
    Clip,

    /// <summary>「fy 文本」那一行（Target = 文本）：Enter 收起启动器、翻译浮窗直接翻译。</summary>
    Translate,

    /// <summary>补全提示（有关键词的搜索、open / find、quit / kill / port、fy）：Enter / Tab 把「关键词 」补进输入框。</summary>
    Prompt,

    /// <summary>kill / port / quit / hide / forcequit 列出来的进程或应用（进程本身在 Process 里）。</summary>
    Process,

    /// <summary>「ip」列的本机 / 外网地址（LauncherIp）：Enter 粘贴 Payload、Ctrl+Enter 只复制；没有 Payload 的（还在查、没查到）不能粘贴。</summary>
    Ip,
}

public static class LauncherKinds
{
    /// <summary>只有这几类记使用、能出现在「常用」里、能收藏（mac Kind.isRecorded）。</summary>
    public static bool IsRecorded(this LauncherKind kind)
        => kind is LauncherKind.App or LauncherKind.Setting or LauncherKind.Command or LauncherKind.Action
            or LauncherKind.Url or LauncherKind.Path;
}

/// <summary>
/// kill / port / quit 列出来的一个进程：PID、进程名（不带 .exe）、给人看的名字（有窗口的程序用文件说明里的名字）、
/// 专用工作集、在监听的 TCP 端口、有没有看得见的顶层窗口、exe 路径（取图标、判断是不是系统目录里的）。
/// </summary>
public sealed record LauncherProcess(
    int Pid,
    string Name,
    string Label,
    long MemoryBytes,
    IReadOnlyList<int> Ports,
    bool HasWindow,
    string? ExePath);

public sealed record LauncherItem
{
    public LauncherKind Kind { get; init; }

    public string Target { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public string Subtitle { get; init; } = string.Empty;

    public List<string> Names { get; init; } = new();

    public List<string> Initials { get; init; } = new();

    /// <summary>Tab 补全时填进搜索框的文字；null 时按种类补（LauncherText.Completion）。</summary>
    public string? Completion { get; init; }

    /// <summary>粘贴 / 复制用的值（计算结果等）。</summary>
    public string? Payload { get; init; }

    /// <summary>同分时的先后：系统命令、退出本 App 这类不确认就执行的要排在后面。</summary>
    public int Priority { get; init; }

    /// <summary>图标路径（App 的 exe / .lnk），没有就用 Kind 的默认图标。</summary>
    public string? IconPath { get; init; }

    /// <summary>图标字节（PNG / JPEG，UWP 的 logo 原样存），界面直接解码。</summary>
    public byte[]? IconData { get; init; }

    /// <summary>
    /// 文件搜索（open / find）搜到的文件 / 文件夹：才有「打开方式…」「移到回收站」，find 里 Enter 是在资源管理器中显示
    /// （mac：有 contentType 的才算文件搜索结果）。
    /// </summary>
    public bool IsFileResult { get; init; }

    /// <summary>是文件夹：右边的种类写「文件夹」，Tab 补全在后面加 \。</summary>
    public bool IsFolder { get; init; }

    /// <summary>浏览历史：最后访问的时间（Unix 毫秒）。副标题的「3 天前」按搜的那一刻算。</summary>
    public long? VisitedAt { get; init; }

    /// <summary>kill / port / quit 列出来的进程；别的结果是 null。</summary>
    public LauncherProcess? Process { get; init; }

    /// <summary>对得上的全局快捷动作（HotKeyActions 的名字）：选中时右边显示它的键帽；没有是 null。</summary>
    public string? HotKeyAction { get; init; }

    /// <summary>身份：类型 + 目标（使用记录、收藏、选中项保持都按它认）。</summary>
    public string Id => Kind + "\n" + Target;
}
