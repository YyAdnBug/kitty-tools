// 识字前放大（纯函数，配单测；2026-10-29 用户反馈「截图翻译识别的文字不准，mac 很准」）：
// Windows.Media.Ocr 对小字认得差，100% 缩放的屏幕上正文只有 12–16 像素高（mac 的 Retina 截出来是两倍像素）。
// 做法同 Text Grab：先认一遍、量平均字高，不到理想的 40 像素就按比例放大再认一遍；一个字都没认出来时放大两倍再试。
// 只放大不缩小；倍数封顶 4，放大后不超过引擎的最大边长、也不超过 1600 万像素（BGRA 64 MB）。放大用双线性。
namespace KittyTools.Core;

public static class OcrScale
{
    public const double IdealHeight = 40;

    public const double MaxFactor = 4;

    public const long MaxPixels = 16_000_000;

    /// <summary>放大倍数；1 = 不用放大（差不到 1.25 倍也不放，省一遍）。averageHeight 为 0 表示一个字都没认出来。</summary>
    public static double Factor(double averageHeight, int width, int height, int maxDimension)
    {
        if (width <= 0 || height <= 0)
        {
            return 1;
        }

        var factor = averageHeight > 0 ? IdealHeight / averageHeight : 2;
        factor = Math.Min(factor, MaxFactor);
        factor = Math.Min(factor, (double)maxDimension / Math.Max(width, height));
        factor = Math.Min(factor, Math.Sqrt((double)MaxPixels / ((long)width * height)));
        return factor < 1.25 ? 1 : factor;
    }

    /// <summary>BGRA 双线性缩放（像素中心对齐）。</summary>
    public static byte[] Resize(byte[] bgra, int width, int height, int targetWidth, int targetHeight)
    {
        var result = new byte[targetWidth * targetHeight * 4];
        var xRatio = (double)width / targetWidth;
        var yRatio = (double)height / targetHeight;
        for (var y = 0; y < targetHeight; y++)
        {
            var sourceY = Math.Max(0, (y + 0.5) * yRatio - 0.5);
            var y0 = Math.Min(height - 1, (int)sourceY);
            var y1 = Math.Min(height - 1, y0 + 1);
            var fy = sourceY - y0;
            for (var x = 0; x < targetWidth; x++)
            {
                var sourceX = Math.Max(0, (x + 0.5) * xRatio - 0.5);
                var x0 = Math.Min(width - 1, (int)sourceX);
                var x1 = Math.Min(width - 1, x0 + 1);
                var fx = sourceX - x0;
                var a = (y0 * width + x0) * 4;
                var b = (y0 * width + x1) * 4;
                var c = (y1 * width + x0) * 4;
                var d = (y1 * width + x1) * 4;
                var output = (y * targetWidth + x) * 4;
                for (var k = 0; k < 4; k++)
                {
                    var top = bgra[a + k] + (bgra[b + k] - bgra[a + k]) * fx;
                    var bottom = bgra[c + k] + (bgra[d + k] - bgra[c + k]) * fx;
                    result[output + k] = (byte)Math.Round(top + (bottom - top) * fy);
                }
            }
        }

        return result;
    }
}
