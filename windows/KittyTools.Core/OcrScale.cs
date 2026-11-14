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

    /// <summary>
    /// 识字认出图里的字是斜的（OcrResult.TextAngle，顺时针的度数）时，词和行的框是按「摆正之后」的图给的，不是原图的坐标
    /// （PLAN-v20 A1 实测：长图切成 4000 行一条识字，横条纹的底色让它判成斜了 1.3°，号码的框往左偏了 38 像素，打码盖歪、号码露出半截）。
    /// 这里把框的四个角绕图的中心（cx, cy）顺时针转回 angle 度，取外接矩形（只会比字大一点，不会漏）。y 朝下。
    /// </summary>
    public static RectD Unrotate(RectD box, double angle, double cx, double cy)
    {
        if (Math.Abs(angle) < 0.01)
        {
            return box;
        }

        var radians = angle * Math.PI / 180;
        var (sin, cos) = Math.SinCos(radians);
        double left = double.MaxValue, top = double.MaxValue, right = double.MinValue, bottom = double.MinValue;
        foreach (var (x, y) in new[] { (box.X, box.Y), (box.Right, box.Y), (box.X, box.Bottom), (box.Right, box.Bottom) })
        {
            var dx = x - cx;
            var dy = y - cy;
            var rx = cx + dx * cos - dy * sin;
            var ry = cy + dx * sin + dy * cos;
            left = Math.Min(left, rx);
            top = Math.Min(top, ry);
            right = Math.Max(right, rx);
            bottom = Math.Max(bottom, ry);
        }

        return RectD.FromLtrb(left, top, right, bottom);
    }
}
