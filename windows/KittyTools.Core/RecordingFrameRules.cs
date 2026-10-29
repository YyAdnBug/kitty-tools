// 录屏 / 长截图选区边框的四条边（纯函数，配单测）：照 mac 的 ScrollBorderView，线画在选区外面、不进画面；
// 只画在选区所在的那块屏里。外面放不下的那一侧（贴着屏幕边）：默认不画，整屏录制四条都是空的（mac「整屏不画」）；
// insideAtEdges 时收进选区里面画（录屏用：线设了不进截图 / 录屏，录最大化的窗口、整屏时也看得出在录哪，
// 2026-10-29 用户反馈「还是没有边框」）。坐标都是物理像素。
namespace KittyTools.Core;

public static class RecordingFrameRules
{
    /// <summary>线宽 2（mac lineWidth 2 pt），按屏幕缩放换成物理像素。</summary>
    public const double ThicknessDip = 2;

    public readonly record struct Strip(int X, int Y, int Width, int Height)
    {
        public bool IsEmpty => Width <= 0 || Height <= 0;
    }

    /// <summary>上、下、左、右四条（固定四个，用不上的是空的）；上下两条横跨两个角。</summary>
    public static Strip[] Strips(
        int left, int top, int right, int bottom,
        int screenLeft, int screenTop, int screenRight, int screenBottom,
        double scale, bool insideAtEdges = false)
    {
        var thickness = Math.Max(1, (int)Math.Round(ThicknessDip * (scale <= 0 ? 1 : scale)));
        var topIn = insideAtEdges && top - thickness < screenTop;
        var bottomIn = insideAtEdges && bottom + thickness > screenBottom;
        var leftIn = insideAtEdges && left - thickness < screenLeft;
        var rightIn = insideAtEdges && right + thickness > screenRight;

        // 每条边占的那一段：外面是 [边 − 线宽, 边)，里面是 [边, 边 + 线宽)（右、下反过来）。
        var topStart = topIn ? top : top - thickness;
        var topEnd = topIn ? top + thickness : top;
        var bottomStart = bottomIn ? bottom - thickness : bottom;
        var bottomEnd = bottomIn ? bottom : bottom + thickness;
        var leftStart = leftIn ? left : left - thickness;
        var leftEnd = leftIn ? left + thickness : left;
        var rightStart = rightIn ? right - thickness : right;
        var rightEnd = rightIn ? right : right + thickness;

        Strip Make(int l, int t, int r, int b)
        {
            l = Math.Max(screenLeft, l);
            t = Math.Max(screenTop, t);
            r = Math.Min(screenRight, r);
            b = Math.Min(screenBottom, b);
            return r > l && b > t ? new Strip(l, t, r - l, b - t) : default;
        }

        return new[]
        {
            Make(leftStart, topStart, rightEnd, topEnd),
            Make(leftStart, bottomStart, rightEnd, bottomEnd),
            Make(leftStart, topEnd, leftEnd, bottomStart),
            Make(rightStart, topEnd, rightEnd, bottomStart),
        };
    }
}
