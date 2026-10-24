// 启动器的一条结果（纯数据）：给匹配和排序用；界面按 Kind 决定图标和动作。
// Names / Initials 存的是 LauncherMatch.Fold 之后的小写折叠文本，构建时折一次，之后每次按键只折查询。
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
}

public sealed class LauncherItem
{
    public LauncherKind Kind { get; init; }

    public string Target { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public string Subtitle { get; init; } = string.Empty;

    public List<string> Names { get; init; } = new();

    public List<string> Initials { get; init; } = new();

    /// <summary>Tab 补全时填进搜索框的文字；null 表示不补全。</summary>
    public string? Completion { get; init; }

    /// <summary>粘贴 / 复制用的值（计算结果等）。</summary>
    public string? Payload { get; init; }

    /// <summary>同分时的先后：系统命令、退出本 App 这类不确认就执行的要排在后面。</summary>
    public int Priority { get; init; }

    /// <summary>图标路径（App 的 exe / .lnk），没有就用 Kind 的默认图标。</summary>
    public string? IconPath { get; init; }

    /// <summary>图标字节（PNG / JPEG，UWP 的 logo 原样存），界面直接解码。</summary>
    public byte[]? IconData { get; init; }
}
