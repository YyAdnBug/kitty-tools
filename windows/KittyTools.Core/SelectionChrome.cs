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
    /// 工具栏：选区下方 10、水平以选区为中心（夹在屏内 10），下方连栏外侧的样式托盘（tray，没有就 0）一起放不下放上方，
    /// 都放不下放进选区底部（离底边 10）。坐标取整到整 DIP（图标和描边不发糊）。
    /// </summary>
    public static (double X, double Y, ToolbarSide Side) Toolbar(
        RectD selection, double width, double height, double tray, double screenWidth, double screenHeight)
    {
        var x = Math.Round(Math.Clamp(
            selection.MidX - width / 2, ToolbarGap, Math.Max(ToolbarGap, screenWidth - width - ToolbarGap)));
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
        return (x, inside, ToolbarSide.Inside);
    }

    /// <summary>
    /// 尺寸胶囊（mac-whisker §6）：选区左上角外 8；放不下或压到 avoid（工具栏、顶部提示）就放进选区（离左、上各 8，选区四周都留得出
    /// 8 才放）；再不行放选区右侧 / 左侧外 8（比胶囊矮的选区竖直居中）；都不行放进选区、只读（Interactive = false：不挡拖边和平移）。
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

        if (selection.Width >= width + SizeGap * 2 && selection.Height >= height + SizeGap * 2 &&
            Fits(selection.X + SizeGap, selection.Y + SizeGap))
        {
            return (Math.Round(selection.X + SizeGap), Math.Round(selection.Y + SizeGap), true);
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

    private static bool Overlaps(RectD a, RectD b)
        => a.X < b.Right && b.X < a.Right && a.Y < b.Bottom && b.Y < a.Bottom;
}
