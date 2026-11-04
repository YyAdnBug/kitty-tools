// 标注里的「裁剪」（PLAN-v11 F11，mac X17）用的纯函数：从截图历史打开的那张，选区缩在原图里面算不算裁剪；
// 裁剪框换成整数像素、夹在图里；按像素裁 BGRA。截图遮罩和长图标注两边共用。
namespace KittyTools.Core;

public readonly record struct CropRect(int Left, int Top, int Width, int Height)
{
    public int Right => Left + Width;

    public int Bottom => Top + Height;
}

public static class ImageCrop
{
    /// <summary>
    /// candidate 整个落在 original 里面、又比它小（差半个像素以上）：从历史打开的那张被裁小了，回写同一条。
    /// 一样大、或者有一边伸到原图外面（框了别的范围）都不算。
    /// </summary>
    public static bool IsCropOf(RectD candidate, RectD original, double tolerance = 0.5)
    {
        var inside = candidate.X >= original.X - tolerance && candidate.Y >= original.Y - tolerance &&
                     candidate.Right <= original.Right + tolerance && candidate.Bottom <= original.Bottom + tolerance;
        var smaller = candidate.Width < original.Width - tolerance || candidate.Height < original.Height - tolerance;
        return inside && smaller && candidate.Width >= 1 && candidate.Height >= 1;
    }

    /// <summary>裁剪框换成整数像素（四舍五入）并夹进 width × height 的图里；至少 1 × 1。</summary>
    public static CropRect Clamp(RectD rect, int width, int height)
    {
        var left = Math.Clamp((int)Math.Round(rect.X), 0, Math.Max(0, width - 1));
        var top = Math.Clamp((int)Math.Round(rect.Y), 0, Math.Max(0, height - 1));
        var right = Math.Clamp((int)Math.Round(rect.Right), left + 1, Math.Max(left + 1, width));
        var bottom = Math.Clamp((int)Math.Round(rect.Bottom), top + 1, Math.Max(top + 1, height));
        return new CropRect(left, top, right - left, bottom - top);
    }

    /// <summary>从 width × height 的 BGRA 里裁出 rect 那一块（rect 先 Clamp 过）。</summary>
    public static byte[] Crop(byte[] bgra, int width, int height, CropRect rect)
    {
        if (bgra.Length < width * height * 4 || rect.Right > width || rect.Bottom > height || rect.Left < 0 || rect.Top < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(rect));
        }

        var result = new byte[rect.Width * rect.Height * 4];
        for (var row = 0; row < rect.Height; row++)
        {
            Buffer.BlockCopy(bgra, ((rect.Top + row) * width + rect.Left) * 4, result, row * rect.Width * 4, rect.Width * 4);
        }

        return result;
    }
}
