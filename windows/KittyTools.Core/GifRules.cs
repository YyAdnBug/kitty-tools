// 转 GIF 的规则（第四版第 3 批）：长边缩到 800、最多 10 fps、时长上限 60 秒（超出只转前 60 秒）。
// 纯函数，配单测。
namespace KittyTools.Core;

public static class GifRules
{
    public const int MaxEdge = 800;

    public const int TargetFps = 10;

    public const int MaxSeconds = 60;

    public static (int Width, int Height) TargetSize(int width, int height)
    {
        if (width <= 0 || height <= 0)
        {
            return (1, 1);
        }

        var edge = Math.Max(width, height);
        if (edge <= MaxEdge)
        {
            return (width, height);
        }

        var scale = (double)MaxEdge / edge;
        return (Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    /// <summary>源帧率 → 10 fps 时每隔几帧取一帧（最少 1）。</summary>
    public static int SampleStep(int sourceFps) => Math.Max(1, (int)Math.Round(sourceFps / (double)TargetFps));

    public static int MaxFrames(int fps) => Math.Max(1, TargetFps * MaxSeconds) + 1;

    /// <summary>最近邻缩放（GIF 只有 256 色，插值没有意义）。</summary>
    public static byte[] NearestScale(byte[] source, int sourceWidth, int sourceHeight, int width, int height)
    {
        var result = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            var sourceY = Math.Min(sourceHeight - 1, y * sourceHeight / height);
            for (var x = 0; x < width; x++)
            {
                var sourceX = Math.Min(sourceWidth - 1, x * sourceWidth / width);
                var from = (sourceY * sourceWidth + sourceX) * 4;
                var to = (y * width + x) * 4;
                result[to] = source[from];
                result[to + 1] = source[from + 1];
                result[to + 2] = source[from + 2];
                result[to + 3] = 255;
            }
        }

        return result;
    }
}
