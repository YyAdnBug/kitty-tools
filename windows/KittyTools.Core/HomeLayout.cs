// 主界面（托盘左键，PLAN-v10 §5，照 mac Shell/HomePanel.swift 的 enum Home）的纯函数，配单测：
// 分节（只有一格的节不画标题、连着的并成一行）、每行哪几格、面板多高、选中怎么移动、贴着任务栏摆在哪。
// 尺寸是 DIP：mac 的数按 PLAN-v7 §2 1:1 换算，字号最小 12（mac 11），所以格子比 mac 宽一点（104，mac 92），放得下「钉住剪贴板里的图」。
namespace KittyTools.Core;

/// <summary>一格。Id 是执行时认的（全局动作名，或 extra.* 这几个开关 / 钉图项）；IsOn 只有开关有。</summary>
public sealed record HomeTile(string Id, string Title, string Glyph, string Family, string? Key = null, bool? IsOn = null);

/// <summary>一节；Title 为 null 不画标题（只有一格的节并成的那一行）。</summary>
public sealed record HomeSection(string? Title, IReadOnlyList<HomeTile> Tiles);

public enum HomeMove
{
    Left,
    Right,
    Up,
    Down,
}

/// <summary>任务栏在工作区的哪条边（主界面从那条边贴出来）。</summary>
public enum TaskbarEdge
{
    Bottom,
    Top,
    Left,
    Right,
}

public static class HomeLayout
{
    public const int Columns = 5;
    public const double TileWidth = 104;
    public const double TileHeight = 78;
    public const double Gap = 2;
    public const double Inset = 10;
    public const double Top = 4;
    public const double Bottom = 6;
    public const double TitleHeight = 24;
    public const double UntitledGap = 6;
    public const double NoteHeight = 28;
    public const double BarHeight = 36;

    /// <summary>离任务栏 12（同系统的音量 / 网络面板）。</summary>
    public const double TaskbarGap = 12;

    public static double Width => Inset * 2 + Columns * TileWidth + (Columns - 1) * Gap;

    /// <summary>
    /// 分节：空的节去掉；两格以上的节照原样带标题；只有一格的节不画标题，和前面同样不画标题的并成一行（同 mac Home.sections）。
    /// </summary>
    public static List<HomeSection> Sections(IEnumerable<HomeSection> sections)
    {
        var result = new List<HomeSection>();
        foreach (var section in sections)
        {
            if (section.Tiles.Count == 0)
            {
                continue;
            }

            if (section.Tiles.Count > 1)
            {
                result.Add(section);
            }
            else if (result.Count > 0 && result[^1].Title is null)
            {
                result[^1] = new HomeSection(null, result[^1].Tiles.Concat(section.Tiles).ToList());
            }
            else
            {
                result.Add(new HomeSection(null, section.Tiles));
            }
        }

        return result;
    }

    /// <summary>每一行有哪几格（全部格子按顺序从 0 编号；每节自己折行，一行最多 Columns 格）。</summary>
    public static List<int[]> Rows(IReadOnlyList<HomeSection> sections)
    {
        var rows = new List<int[]>();
        var next = 0;
        foreach (var section in sections)
        {
            for (var start = 0; start < section.Tiles.Count; start += Columns)
            {
                var count = Math.Min(Columns, section.Tiles.Count - start);
                rows.Add(Enumerable.Range(next + start, count).ToArray());
            }

            next += section.Tiles.Count;
        }

        return rows;
    }

    /// <summary>面板的高：格子那一块 +「N 个功能关着」那一行（有才有）+ 底栏。</summary>
    public static double Height(IReadOnlyList<HomeSection> sections, int offCount)
    {
        var height = Top + Bottom;
        for (var index = 0; index < sections.Count; index++)
        {
            height += sections[index].Title is not null ? TitleHeight : index == 0 ? 0 : UntitledGap;
            var rows = (sections[index].Tiles.Count + Columns - 1) / Columns;
            height += rows * TileHeight + (rows - 1) * Gap;
        }

        return height + (offCount > 0 ? NoteHeight : 0) + BarHeight;
    }

    /// <summary>
    /// 选中怎么移动：←→ 按顺序挨个走、到头回绕（Tab / Shift+Tab 同）；↑↓ 换行，列不变，那一行短就落在它最后一格，
    /// 第一行 / 最后一行不动。还没选中时按什么都是第一格；一格都没有时 null。
    /// </summary>
    public static int? Moved(int? selection, HomeMove move, IReadOnlyList<int[]> rows)
    {
        var count = rows.Sum(row => row.Length);
        if (count == 0)
        {
            return null;
        }

        if (selection is not { } current)
        {
            return 0;
        }

        var row = -1;
        var column = -1;
        for (var index = 0; index < rows.Count && row < 0; index++)
        {
            column = Array.IndexOf(rows[index], current);
            if (column >= 0)
            {
                row = index;
            }
        }

        if (row < 0)
        {
            return 0;
        }

        return move switch
        {
            HomeMove.Left => (current - 1 + count) % count,
            HomeMove.Right => (current + 1) % count,
            HomeMove.Up when row > 0 => rows[row - 1][Math.Min(column, rows[row - 1].Length - 1)],
            HomeMove.Down when row < rows.Count - 1 => rows[row + 1][Math.Min(column, rows[row + 1].Length - 1)],
            _ => current,
        };
    }

    /// <summary>任务栏在哪条边：显示器和工作区比，差出来的那条边（没差出来 = 自动隐藏的任务栏，按托盘图标离哪条边近）。</summary>
    public static TaskbarEdge Edge(WorkArea monitor, WorkArea work, int iconX, int iconY)
    {
        if (work.Bottom < monitor.Bottom)
        {
            return TaskbarEdge.Bottom;
        }

        if (work.Top > monitor.Top)
        {
            return TaskbarEdge.Top;
        }

        if (work.Left > monitor.Left)
        {
            return TaskbarEdge.Left;
        }

        if (work.Right < monitor.Right)
        {
            return TaskbarEdge.Right;
        }

        var distances = new[]
        {
            (TaskbarEdge.Bottom, monitor.Bottom - iconY),
            (TaskbarEdge.Top, iconY - monitor.Top),
            (TaskbarEdge.Left, iconX - monitor.Left),
            (TaskbarEdge.Right, monitor.Right - iconX),
        };
        return distances.MinBy(item => item.Item2).Item1;
    }

    /// <summary>
    /// 从托盘打开时面板的左上角（物理像素）：贴着任务栏那条边、离它 gap，另一个方向对着托盘图标（靠通知区那一侧），夹进工作区。
    /// </summary>
    public static (int X, int Y) NearTray(
        WorkArea work, TaskbarEdge edge, int iconLeft, int iconTop, int iconRight, int iconBottom, int width, int height, int gap)
    {
        var (x, y) = edge switch
        {
            // 底 / 顶：右边对着图标右边（通知区在右，面板往左展开）。
            TaskbarEdge.Bottom => (iconRight - width, work.Bottom - gap - height),
            TaskbarEdge.Top => (iconRight - width, work.Top + gap),
            // 左 / 右：底边对着图标底边（通知区在下，面板往上展开）。
            TaskbarEdge.Left => (work.Left + gap, iconBottom - height),
            _ => (work.Right - gap - width, iconBottom - height),
        };
        x = Math.Clamp(x, work.Left + gap, Math.Max(work.Left + gap, work.Right - gap - width));
        y = Math.Clamp(y, work.Top + gap, Math.Max(work.Top + gap, work.Bottom - gap - height));
        return (x, y);
    }
}
