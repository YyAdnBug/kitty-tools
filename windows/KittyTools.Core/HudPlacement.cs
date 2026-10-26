// 录屏控制条的位置（纯函数，配单测；REVIEW R22）：
// 尺寸按目标显示器缩放换算成物理像素，位置放在选区下方；下方放不下放上方，上方也放不下就贴选区里面下边。
// 工作区坐标是物理像素（Windows 的 GetMonitorInfo）。
namespace KittyTools.Core;

public static class HudPlacement
{
    public const int WidthDip = 268;

    public const int HeightDip = 46;

    public const int GapDip = 8;

    public readonly record struct Rect(int X, int Y, int Width, int Height);

    public static Rect Compute(
        int regionLeft, int regionTop, int regionRight, int regionBottom,
        int workLeft, int workTop, int workRight, int workBottom,
        double scale)
    {
        scale = scale <= 0 ? 1 : scale;
        var width = (int)Math.Round(WidthDip * scale);
        var height = (int)Math.Round(HeightDip * scale);
        var gap = (int)Math.Round(GapDip * scale);

        var x = regionLeft + (regionRight - regionLeft - width) / 2;
        x = Math.Clamp(x, workLeft, Math.Max(workLeft, workRight - width));

        var y = regionBottom + gap;
        if (y + height > workBottom)
        {
            y = regionTop - height - gap;
        }

        if (y < workTop)
        {
            y = regionBottom - height - gap;
        }

        y = Math.Clamp(y, workTop, Math.Max(workTop, workBottom - height));
        return new Rect(x, y, width, height);
    }
}
