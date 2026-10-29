// 录屏选区边框的四条边（纯函数，配单测）：照 mac 的 ScrollBorderView，线画在选区外面、不进画面；
// 只画在选区所在的那块屏里，贴着屏幕边的那一侧没有线，整屏录制四条都是空的（mac「整屏不画」）。
// 坐标都是物理像素。
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
        double scale)
    {
        var thickness = Math.Max(1, (int)Math.Round(ThicknessDip * (scale <= 0 ? 1 : scale)));
        var outerLeft = Math.Max(screenLeft, left - thickness);
        var outerTop = Math.Max(screenTop, top - thickness);
        var outerRight = Math.Min(screenRight, right + thickness);
        var outerBottom = Math.Min(screenBottom, bottom + thickness);
        return new[]
        {
            Make(outerLeft, outerTop, outerRight, top),
            Make(outerLeft, bottom, outerRight, outerBottom),
            Make(outerLeft, top, left, bottom),
            Make(right, top, outerRight, bottom),
        };
    }

    private static Strip Make(int left, int top, int right, int bottom)
        => right > left && bottom > top ? new Strip(left, top, right - left, bottom - top) : default;
}
