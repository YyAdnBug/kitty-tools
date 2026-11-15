// 截图框选时悬停识别窗口里的元素（PLAN-v20 E1，照 mac Screenshot/ElementFinder.swift 的 layers / step，纯函数配单测）：
// 指针下面一层套一层的元素（按钮在列表里、列表在侧栏里、侧栏在窗口里），从最小的到整扇窗口排好；滚轮往上大一层、往下小一层，
// 最大到整扇窗口。只留：在窗口里面（夹进窗口）、不太小（宽高都至少 MinSide 像素）、和上一层不是几乎一样大（差不到 Merge 像素的当一层）。
// 坐标是物理像素（UIA 的 BoundingRectangle 就是屏幕物理像素，本 App 是按显示器 DPI 感知的）。
namespace KittyTools.Core;

public static class ElementLayers
{
    /// <summary>元素宽高至少这么多像素（更小的是图标里的一个点、分隔线，框它没意义）。</summary>
    public const int MinSide = 8;

    /// <summary>四条边都差不到这么多像素的两层当一层（嵌套的容器常常一样大）。</summary>
    public const int Merge = 4;

    /// <summary>
    /// 指针 (x, y) 下面的各层：从最小的元素到整扇窗口（window 永远是最后一层）。elements 是这扇窗口里元素的框（不用排序、可以有窗口外的）。
    /// 指针不在窗口里时只有窗口那一层。
    /// </summary>
    public static List<(int Left, int Top, int Right, int Bottom)> At(
        int x, int y, (int Left, int Top, int Right, int Bottom) window, IEnumerable<(int Left, int Top, int Right, int Bottom)> elements)
    {
        var layers = new List<(int Left, int Top, int Right, int Bottom)>();
        if (x < window.Left || x >= window.Right || y < window.Top || y >= window.Bottom)
        {
            return new List<(int, int, int, int)> { window };
        }

        foreach (var element in elements)
        {
            var clipped = (
                Left: Math.Max(element.Left, window.Left), Top: Math.Max(element.Top, window.Top),
                Right: Math.Min(element.Right, window.Right), Bottom: Math.Min(element.Bottom, window.Bottom));
            if (clipped.Right - clipped.Left < MinSide || clipped.Bottom - clipped.Top < MinSide)
            {
                continue;
            }

            if (x >= clipped.Left && x < clipped.Right && y >= clipped.Top && y < clipped.Bottom)
            {
                layers.Add(clipped);
            }
        }

        layers.Add(window);
        layers = layers
            .OrderBy(rect => (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top))
            .ThenBy(rect => rect == window ? 1 : 0)
            .ToList();
        var merged = new List<(int Left, int Top, int Right, int Bottom)>();
        foreach (var layer in layers)
        {
            if (merged.Count > 0 && Same(merged[^1], layer))
            {
                // 一样大的两层留大的那个（窗口那层最后进来，总留下）
                merged[^1] = layer;
                continue;
            }

            merged.Add(layer);
        }

        return merged;
    }

    /// <summary>换层（滚轮往上 delta = +1 大一层、往下 -1 小一层）：夹在 0 到最外层之间。</summary>
    public static int Step(int current, int delta, int count) => Math.Clamp(current + delta, 0, Math.Max(count - 1, 0));

    private static bool Same((int Left, int Top, int Right, int Bottom) a, (int Left, int Top, int Right, int Bottom) b)
        => Math.Abs(a.Left - b.Left) < Merge && Math.Abs(a.Top - b.Top) < Merge &&
           Math.Abs(a.Right - b.Right) < Merge && Math.Abs(a.Bottom - b.Bottom) < Merge;
}
