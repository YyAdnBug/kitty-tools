// 截图一个选区跨几块屏（PLAN-v24，纯函数配单测）：全局物理像素、原点左上（虚拟桌面坐标，副屏在左 / 上边时是负数）。
// 选区归哪块屏（工具栏、尺寸胶囊放在那块，出图的缩放按它）、出图时从每块屏的冻结帧里各拷哪一段拼到哪、拖的时候夹在哪、上次区域还剩哪块。
// screens 的顺序 = ScreenCapture.CaptureAll 的顺序（先按左、再按上排）：相交一样大时取排在前面的，就是「左上那块」。
using Box = (int Left, int Top, int Right, int Bottom);

namespace KittyTools.Core;

public static class ScreenSpan
{
    /// <summary>选区和哪块屏相交最大（同 mac RegionSelector.placement）；一样大取排在前面的；一块屏都不沾是 null。</summary>
    public static int? Owner(Box rect, IReadOnlyList<Box> screens)
    {
        int? best = null;
        long bestArea = 0;
        for (var index = 0; index < screens.Count; index++)
        {
            var area = Area(Intersect(rect, screens[index]));
            if (area > bestArea)
            {
                best = index;
                bestArea = area;
            }
        }

        return best;
    }

    /// <summary>选区跨了两块以上的屏（这时只能出图，不能标注、长截图、录屏，PLAN-v24 X2）。</summary>
    public static bool Spans(Box rect, IReadOnlyList<Box> screens)
        => screens.Count(screen => Area(Intersect(rect, screen)) > 0) > 1;

    /// <summary>
    /// 拼图：每块和选区相交的屏一段——屏序号、这块屏冻结帧里的矩形（屏内坐标）、拼进图里的左上角（图内坐标，图的大小 = 选区）。
    /// 没有哪一段盖到的地方（屏幕上下错位时选区里的空角）调用方填不透明的黑。
    /// </summary>
    public static List<(int Screen, Box Source, int X, int Y)> Pieces(Box rect, IReadOnlyList<Box> screens)
    {
        var pieces = new List<(int Screen, Box Source, int X, int Y)>();
        for (var index = 0; index < screens.Count; index++)
        {
            var screen = screens[index];
            var part = Intersect(rect, screen);
            if (Area(part) == 0)
            {
                continue;
            }

            pieces.Add((index,
                (part.Left - screen.Left, part.Top - screen.Top, part.Right - screen.Left, part.Bottom - screen.Top),
                part.Left - rect.Left, part.Top - rect.Top));
        }

        return pieces;
    }

    /// <summary>所有屏的外接矩形：拖跨屏选区时夹在它里面（里面没有屏的空角光标去不了，矩形能盖到）。没有屏时全是 0。</summary>
    public static Box Bounds(IReadOnlyList<Box> screens)
        => screens.Count == 0
            ? default
            : (screens.Min(screen => screen.Left), screens.Min(screen => screen.Top),
                screens.Max(screen => screen.Right), screens.Max(screen => screen.Bottom));

    /// <summary>
    /// 上次的区域（D 键，PLAN-v24 C6）还剩哪块：一块屏都不沾是 null；超出所有屏外接矩形的夹掉（拔掉右边那块屏后只剩还在的那半）。
    /// </summary>
    public static Box? LastRegion(Box rect, IReadOnlyList<Box> screens)
        => Owner(rect, screens) is null ? null : Intersect(rect, Bounds(screens));

    private static Box Intersect(Box a, Box b)
        => (Math.Max(a.Left, b.Left), Math.Max(a.Top, b.Top), Math.Min(a.Right, b.Right), Math.Min(a.Bottom, b.Bottom));

    private static long Area(Box box)
        => (long)Math.Max(0, box.Right - box.Left) * Math.Max(0, box.Bottom - box.Top);
}
