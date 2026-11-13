// 截图选区旁的控件放哪、选区怎么用键盘和尺寸胶囊调（纯函数，配单测；PLAN-v9-annotate §7 U5 / U7、PLAN-v9 S4）。
// 选区是物理像素（原点左上），摆放用 DIP（遮罩画布的坐标）。规则照 mac SelectionView.layoutToolbar / layoutSizeField、
// RegionSelector.pushed / sized / ratios。
namespace KittyTools.Core;

/// <summary>工具栏放在哪：选区下方、上方、选区里（后两种从栏的底边长出来，样式托盘翻到栏里侧 / 上方）。</summary>
public enum ToolbarSide
{
    Below,
    Above,
    Inside,
}

public static class SelectionChrome
{
    /// <summary>工具栏离选区、离屏幕边的距离（DIP）。</summary>
    public const double ToolbarGap = 10;

    /// <summary>尺寸胶囊离选区的距离（DIP）。</summary>
    public const double SizeGap = 8;

    /// <summary>比例预设（尺寸胶囊的菜单）：宽 / 高，null = 自由。</summary>
    public static readonly (string Title, double? Value)[] Ratios =
    {
        ("自由", null), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    };

    public static string RatioTitle(double? ratio)
        => Ratios.FirstOrDefault(item => item.Value == ratio).Title ?? "自由";

    /// <summary>
    /// 工具栏：选区下方 10，下方连栏外侧的样式托盘（tray，没有就 0）一起放不下放上方，都放不下放进选区底部（离底边 10）。
    /// 水平（夹在屏内 10）：alignRight（设置 › 截图「工具栏位置」靠右，默认；PLAN-v12 N4，mac 0f83c117）时栏的右边线对齐选区右边线，
    /// 放进选区时往里收 10（不压右边那条能拖的边和角手柄）；否则以选区为中心。坐标取整到整 DIP（图标和描边不发糊）。
    /// </summary>
    public static (double X, double Y, ToolbarSide Side) Toolbar(
        RectD selection, double width, double height, double tray, double screenWidth, double screenHeight,
        bool alignRight = false)
    {
        double Left(double x) => Math.Round(Math.Clamp(x, ToolbarGap, Math.Max(ToolbarGap, screenWidth - width - ToolbarGap)));
        var x = Left(alignRight ? selection.X + selection.Width - width : selection.MidX - width / 2);
        var below = Math.Round(selection.Bottom + ToolbarGap);
        if (below + height + tray <= screenHeight - ToolbarGap)
        {
            return (x, below, ToolbarSide.Below);
        }

        var above = Math.Round(selection.Y - ToolbarGap - height);
        if (above - tray >= ToolbarGap)
        {
            return (x, above, ToolbarSide.Above);
        }

        var inside = Math.Round(Math.Clamp(
            selection.Bottom - ToolbarGap - height, ToolbarGap, Math.Max(ToolbarGap, screenHeight - height - ToolbarGap)));
        var insideX = alignRight ? Left(selection.X + selection.Width - ToolbarGap - width) : x;
        return (insideX, inside, ToolbarSide.Inside);
    }

    /// <summary>
    /// 尺寸胶囊（mac-whisker §6，PLAN-v18 S5 / mac d5f7c388）：先放选区外面——左上角外 8 → 右侧外 8 → 左侧外 8（和上边对齐，比胶囊矮的选区
    /// 竖直居中）→ 左下角外 8；外面都放不下或压到 avoid（工具栏、顶部提示）才放进选区（离左、上各 8，选区四周都留得出 8 才放）；
    /// 再不行放进选区、只读（Interactive = false：不挡拖边和平移）。以前进选区排在左右两侧前面，上面被占着时它挡住要截的字。
    /// </summary>
    public static (double X, double Y, bool Interactive) SizeCapsule(
        RectD selection, double width, double height, double screenWidth, double screenHeight, IReadOnlyList<RectD> avoid)
    {
        bool Fits(double x, double y)
        {
            if (x < 0 || y < 0 || x + width > screenWidth || y + height > screenHeight)
            {
                return false;
            }

            var box = new RectD(x, y, width, height);
            return !avoid.Any(other => Overlaps(box, other));
        }

        var aboveY = selection.Y - SizeGap - height;
        var left = Math.Min(selection.X, Math.Max(0, screenWidth - width));
        if (Fits(left, aboveY))
        {
            return (Math.Round(left), Math.Round(aboveY), true);
        }

        var sideY = selection.Height < height ? selection.MidY - height / 2 : selection.Y;
        if (Fits(selection.Right + SizeGap, sideY))
        {
            return (Math.Round(selection.Right + SizeGap), Math.Round(sideY), true);
        }

        if (Fits(selection.X - SizeGap - width, sideY))
        {
            return (Math.Round(selection.X - SizeGap - width), Math.Round(sideY), true);
        }

        var belowY = selection.Bottom + SizeGap;
        if (Fits(left, belowY))
        {
            return (Math.Round(left), Math.Round(belowY), true);
        }

        if (selection.Width >= width + SizeGap * 2 && selection.Height >= height + SizeGap * 2 &&
            Fits(selection.X + SizeGap, selection.Y + SizeGap))
        {
            return (Math.Round(selection.X + SizeGap), Math.Round(selection.Y + SizeGap), true);
        }

        return (Math.Round(Math.Clamp(selection.X + SizeGap, 0, Math.Max(0, screenWidth - width))),
            Math.Round(Math.Clamp(selection.Y + SizeGap, 0, Math.Max(0, screenHeight - height))), false);
    }

    /// <summary>
    /// Ctrl / Alt + 方向键：把 edge 那条边往外推 delta（负数往里收）；短边不小于 minimumSide（本来就更小的不再收），夹在 bounds 里。
    /// 只认四条边，角原样返回。
    /// </summary>
    public static RectD Pushed(RectD rect, SelectionHandle edge, double delta, RectD bounds, double minimumSide)
    {
        var (left, top, right, bottom) = (rect.X, rect.Y, rect.Right, rect.Bottom);
        var minWidth = Math.Min(rect.Width, minimumSide);
        var minHeight = Math.Min(rect.Height, minimumSide);
        switch (edge)
        {
            case SelectionHandle.Left:
                left = Math.Min(Math.Max(left - delta, bounds.X), right - minWidth);
                break;
            case SelectionHandle.Right:
                right = Math.Max(Math.Min(right + delta, bounds.Right), left + minWidth);
                break;
            case SelectionHandle.Top:
                top = Math.Min(Math.Max(top - delta, bounds.Y), bottom - minHeight);
                break;
            case SelectionHandle.Bottom:
                bottom = Math.Max(Math.Min(bottom + delta, bounds.Bottom), top + minHeight);
                break;
            default:
                return rect;
        }

        return RectD.FromLtrb(left, top, right, bottom);
    }

    /// <summary>
    /// 尺寸胶囊输入的像素宽高 → 选区：左上角先对齐到整像素（左、上往下取整，和出图的 PixelRect 往外取整一样，不然一输入左上角就
    /// 挪一像素）、不动，往右下长、夹进 bounds（至少 1 像素）。
    /// </summary>
    public static RectD Sized(RectD rect, double width, double height, RectD bounds)
    {
        var left = Math.Floor(rect.X);
        var top = Math.Floor(rect.Y);
        return new RectD(
            left, top,
            Math.Clamp(Math.Round(width), 1, Math.Max(1, bounds.Right - left)),
            Math.Clamp(Math.Round(height), 1, Math.Max(1, bounds.Bottom - top)));
    }

    /// <summary>译文卡片的宽同选区、夹在这两个数之间（DIP，mac TranslationCard.minWidth / maxWidth）。</summary>
    public const double CardMinWidth = 240;

    public const double CardMaxWidth = 420;

    /// <summary>译文卡片的标题（也是读屏名，PLAN-v18 S7 S9）：没有放不下的段时就是「译文」。</summary>
    public static string CardTitle(int leftovers)
        => leftovers > 1 ? $"放不下的 {leftovers} 段译文" : leftovers == 1 ? "放不下的译文" : "译文";

    /// <summary>就地翻译完的顶部提示：到字号下限也放不下的段图上留着原文，译文在卡片里（mac translatedHint）。</summary>
    public static string TranslatedHint(int leftovers, bool drewAny)
        => leftovers == 0 ? "已替换为译文" : drewAny ? $"有 {leftovers} 段放不下，译文放在卡片里" : "选区太小，译文放在卡片里";

    /// <summary>
    /// 译文卡片放哪（mac cardPlacement，PLAN-v18 S7 / 拍板 B3；DIP、左上原点）：选区外、工具栏的另一侧（栏在下面挂上面、栏在上面挂下面），
    /// 离选区 10，左边和选区对齐、夹在屏内 10；那一侧放不下挂到工具栏外面（让出样式托盘 tray）；都放不下（选区差不多整屏）放进选区
    /// 左下角离边 8，压到栏（连托盘）就挪到它上面。没有工具栏（截图翻译模式）先挂上面、再挂下面。
    /// GrowsDown：卡片靠选区的是上边（从那里往下长出来）。
    /// </summary>
    public static (double X, double Y, bool GrowsDown) TranslationCard(
        double width, double height, RectD selection, RectD? toolbar, double tray, double screenWidth, double screenHeight)
    {
        const double margin = 10;
        var x = Math.Round(Math.Max(margin, Math.Min(selection.X, screenWidth - margin - width)));
        bool Fits(double y) => y >= margin && y + height <= screenHeight - margin;
        var barAbove = toolbar is { } above && above.Bottom <= selection.Y + 0.5;
        var barBelow = toolbar is { } below && below.Y >= selection.Bottom - 0.5;
        var candidates = new List<(double Y, bool GrowsDown)>
        {
            barAbove ? (selection.Bottom + margin, true) : (selection.Y - margin - height, false),
        };
        if (toolbar is { } outer && barBelow)
        {
            candidates.Add((outer.Bottom + tray + 6, true));
        }

        if (toolbar is { } upper && barAbove)
        {
            candidates.Add((upper.Y - tray - 6 - height, false));
        }

        if (toolbar is null)
        {
            candidates.Add((selection.Bottom + margin, true));
        }

        foreach (var (y, growsDown) in candidates)
        {
            if (Fits(Math.Round(y)))
            {
                return (x, Math.Round(y), growsDown);
            }
        }

        // 选区里左下角；压到栏（连托盘：栏在选区下面时托盘在栏下面，在上面 / 选区里时在栏上面）就挪到它上面；
        // 最后夹在屏内 10（贴着屏幕边的窄选区，卡片比选区宽，✕ 和拷贝不能跑到屏幕外）
        var inside = new RectD(selection.X + 8, selection.Bottom - 8 - height, width, height);
        if (toolbar is { } taken)
        {
            var occupied = new RectD(taken.X, barBelow ? taken.Y : taken.Y - tray, taken.Width, taken.Height + tray);
            if (Overlaps(inside, occupied))
            {
                inside = inside with { Y = occupied.Y - 6 - height };
            }
        }

        return (
            Math.Round(Math.Max(margin, Math.Min(inside.X, screenWidth - margin - width))),
            Math.Round(Math.Max(margin, Math.Min(inside.Y, screenHeight - margin - height))),
            false);
    }

    private static bool Overlaps(RectD a, RectD b)
        => a.X < b.Right && b.X < a.Right && a.Y < b.Bottom && b.Y < a.Bottom;
}
