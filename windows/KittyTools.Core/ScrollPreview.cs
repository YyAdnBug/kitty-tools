// 长截图拍的时候旁边那块预览（PLAN-v9 S11，照 mac ScrollCapture.swift 的 previewRange / browse / scrubberFrame）的纯函数，配单测：
// 预览取长图的哪一段、滚轮往回看后看哪一段、右边的位置指示条画在哪、面板摆在选区哪边。
// 行号是 ScrollCanvas 的行号（0 = 长图最上面）；往上滚时新内容接在最上面，「最新那头」是第 0 行。
namespace KittyTools.Core;

public static class ScrollPreview
{
    /// <summary>
    /// 预览显示哪一段：visible 是预览里放得下多少行，from 是起始行（null = 跟着最新那头），夹进长图里。
    /// 长图整张放得下时就是整张。
    /// </summary>
    public static (int Start, int Count) Range(int height, int visible, int? from, bool growingUp)
    {
        var count = Math.Min(height, Math.Max(visible, 0));
        if (count <= 0)
        {
            return (0, 0);
        }

        if (from is not { } start)
        {
            return growingUp ? (0, count) : (height - count, count);
        }

        return (Math.Clamp(start, 0, height - count), count);
    }

    /// <summary>
    /// 滚轮往回看：往上挪了 rows 行（正的 = 看长图上面的内容，同滚轮往上）后从哪行看起；
    /// 滚回最新那头、或长图整张都在预览里时返回 null（回到跟随）。
    /// </summary>
    public static int? Browse(int? from, double rows, int height, int visible, bool growingUp)
    {
        var (start, count) = Range(height, visible, from, growingUp);
        var limit = height - count;
        if (limit <= 0)
        {
            return null;
        }

        var row = Math.Clamp((int)Math.Round(start - rows), 0, limit);
        return (growingUp ? row <= 0 : row >= limit) ? null : row;
    }

    /// <summary>
    /// 位置指示条在轨道（预览框的高，DIP）里的上边和高：高按看得见的那段占长图多少（最矮 20），从上往下走。
    /// 长图整张都在预览里时返回 null（不画）。
    /// </summary>
    public static (double Top, double Height)? Scrubber(double track, int start, int count, int height)
    {
        if (count <= 0 || height <= count || track <= 0)
        {
            return null;
        }

        var size = Math.Min(Math.Max(track * count / height, 20), track);
        return ((track - size) * Math.Clamp(start, 0, height - count) / (height - count), size);
    }

    /// <summary>
    /// 面板左上角（物理像素）：选区右边放得下放右边，不然放左边，两边都放不下（选区差不多整屏）就贴在选区里面右边；
    /// 上边和选区上边对齐，夹进工作区。
    /// </summary>
    public static (int X, int Y) PanelOrigin(
        int regionLeft, int regionTop, int regionRight,
        int workLeft, int workTop, int workRight, int workBottom,
        int width, int height, int gap)
    {
        var x = regionRight + gap + width <= workRight
            ? regionRight + gap
            : regionLeft - gap - width >= workLeft
                ? regionLeft - gap - width
                : regionRight - gap - width;
        x = Math.Clamp(x, workLeft, Math.Max(workLeft, workRight - width));
        var y = Math.Clamp(regionTop, workTop, Math.Max(workTop, workBottom - height));
        return (x, y);
    }
}
