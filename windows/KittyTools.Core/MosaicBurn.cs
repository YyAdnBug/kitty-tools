// 把马赛克打进图（纯函数，配单测）：截图历史存的「原图」里不留马赛克下面的明文（第四轮体检 E6，PLAN-v11 M4）。
// 格子和取色同截图遮罩画马赛克那一套（Screenshot/Annotation.cs 的 DrawMosaic，它也调这里的 Average）：
// 从框的左上角取整处起、每 cell 像素一格，格内隔几个像素抽样取平均。
// 「模糊」那一档（PLAN-v18 S16，mac e378bbe6）：缩到每格「半径 / 2」取平均成小图，在小图上做 σ = 1 格的高斯（边上按最近的格子往外延），
// 再平滑放大——看着就是高斯模糊，格子比高斯能留住的最细笔画还粗，信息在缩小时已经丢了（直接对原图高斯，反锐化能认回字）。
// 屏幕上画的和打进原图的用同一张模糊过的小图（BlurredGrid），屏幕上三次插值放大、打进原图双线性放大，看着一样。
namespace KittyTools.Core;

public static class MosaicBurn
{
    /// <summary>格内平均：横竖每 step 个像素抽一个（step = 格宽 / 6，至少 1）。bgra 是 width 宽的整张图。</summary>
    public static (byte R, byte G, byte B) Average(byte[] bgra, int width, int left, int top, int right, int bottom)
    {
        long r = 0, g = 0, b = 0;
        var count = 0;
        var step = Math.Max(1, (right - left) / 6);
        for (var y = top; y < bottom; y += step)
        {
            for (var x = left; x < right; x += step)
            {
                var index = (y * width + x) * 4;
                b += bgra[index];
                g += bgra[index + 1];
                r += bgra[index + 2];
                count++;
            }
        }

        return count == 0 ? ((byte)0, (byte)0, (byte)0) : ((byte)(r / count), (byte)(g / count), (byte)(b / count));
    }

    /// <summary>高斯核（σ = 1 格，取到 ±3 格），加起来是 1。</summary>
    private static readonly double[] Kernel = BuildKernel();

    private static double[] BuildKernel()
    {
        var weights = Enumerable.Range(-3, 7).Select(offset => Math.Exp(-offset * offset / 2.0)).ToArray();
        var sum = weights.Sum();
        return weights.Select(weight => weight / sum).ToArray();
    }

    /// <summary>
    /// 打码「模糊」的小图：rect 从左上角取整处起每 cell 像素一格取平均，再在格子上做 σ = 1 格的高斯（边上按最近的格子往外延）。
    /// 返回小图在 source 里的左上角、列数、行数和每格的 RGB（行优先，每格三个数）。rect 是空的时列数、行数为 0。
    /// </summary>
    public static (int Left, int Top, int Columns, int Rows, double[] Rgb) BlurredGrid(
        byte[] source, int sourceWidth, int sourceHeight, RectD rect, int cell)
    {
        cell = Math.Max(1, cell);
        var left = (int)Math.Clamp(Math.Floor(rect.X), 0, sourceWidth);
        var top = (int)Math.Clamp(Math.Floor(rect.Y), 0, sourceHeight);
        var right = (int)Math.Clamp(Math.Ceiling(rect.Right), 0, sourceWidth);
        var bottom = (int)Math.Clamp(Math.Ceiling(rect.Bottom), 0, sourceHeight);
        var columns = Math.Max(0, (right - left + cell - 1) / cell);
        var rows = Math.Max(0, (bottom - top + cell - 1) / cell);
        var grid = new double[columns * rows * 3];
        for (var row = 0; row < rows; row++)
        {
            for (var column = 0; column < columns; column++)
            {
                var x = left + column * cell;
                var y = top + row * cell;
                var (r, g, b) = Average(source, sourceWidth, x, y, Math.Min(x + cell, right), Math.Min(y + cell, bottom));
                var index = (row * columns + column) * 3;
                grid[index] = r;
                grid[index + 1] = g;
                grid[index + 2] = b;
            }
        }

        // 先横后竖，两遍一维高斯
        var across = new double[grid.Length];
        for (var row = 0; row < rows; row++)
        {
            for (var column = 0; column < columns; column++)
            {
                for (var channel = 0; channel < 3; channel++)
                {
                    double sum = 0;
                    for (var k = -3; k <= 3; k++)
                    {
                        var c = Math.Clamp(column + k, 0, columns - 1);
                        sum += Kernel[k + 3] * grid[(row * columns + c) * 3 + channel];
                    }

                    across[(row * columns + column) * 3 + channel] = sum;
                }
            }
        }

        for (var row = 0; row < rows; row++)
        {
            for (var column = 0; column < columns; column++)
            {
                for (var channel = 0; channel < 3; channel++)
                {
                    double sum = 0;
                    for (var k = -3; k <= 3; k++)
                    {
                        var r = Math.Clamp(row + k, 0, rows - 1);
                        sum += Kernel[k + 3] * across[(r * columns + column) * 3 + channel];
                    }

                    grid[(row * columns + column) * 3 + channel] = sum;
                }
            }
        }

        return (left, top, columns, rows, grid);
    }

    /// <summary>
    /// 把 rect 这一块打成「模糊」（BlurredGrid 再双线性放大，格子中心对格子中心），写进 target——参数同 Apply。透明度不动。
    /// </summary>
    public static void ApplyBlur(
        byte[] source, int sourceWidth, int sourceHeight, RectD rect, int cell,
        byte[] target, int targetWidth, int targetHeight, int offsetX, int offsetY)
    {
        cell = Math.Max(1, cell);
        var (left, top, columns, rows, grid) = BlurredGrid(source, sourceWidth, sourceHeight, rect, cell);
        if (columns == 0 || rows == 0)
        {
            return;
        }

        var right = (int)Math.Clamp(Math.Ceiling(rect.Right), 0, sourceWidth);
        var bottom = (int)Math.Clamp(Math.Ceiling(rect.Bottom), 0, sourceHeight);
        for (var y = Math.Max(top, offsetY); y < Math.Min(bottom, offsetY + targetHeight); y++)
        {
            var gy = Math.Clamp((y - top + 0.5) / cell - 0.5, 0, rows - 1);
            var y0 = (int)Math.Floor(gy);
            var y1 = Math.Min(y0 + 1, rows - 1);
            var fy = gy - y0;
            for (var x = Math.Max(left, offsetX); x < Math.Min(right, offsetX + targetWidth); x++)
            {
                var gx = Math.Clamp((x - left + 0.5) / cell - 0.5, 0, columns - 1);
                var x0 = (int)Math.Floor(gx);
                var x1 = Math.Min(x0 + 1, columns - 1);
                var fx = gx - x0;
                var index = ((y - offsetY) * targetWidth + (x - offsetX)) * 4;
                for (var channel = 0; channel < 3; channel++)
                {
                    double At(int column, int row) => grid[(row * columns + column) * 3 + channel];
                    var value = (At(x0, y0) * (1 - fx) + At(x1, y0) * fx) * (1 - fy) + (At(x0, y1) * (1 - fx) + At(x1, y1) * fx) * fy;
                    // target 是 BGRA：channel 0 = R 写到 +2
                    target[index + 2 - channel] = (byte)Math.Clamp(Math.Round(value), 0, 255);
                }
            }
        }
    }

    /// <summary>
    /// 把 rect（source 的像素坐标）这一块打成边长 cell 的方块。颜色从 source 取（整屏冻结帧：格子跨出选区时和屏幕上画的一样），
    /// 写进 target——source 里 (offsetX, offsetY) 起、targetWidth × targetHeight 的那一块（截图历史的原图就是选区那块）。
    /// target 可以就是 source（offset 0、同宽高）；那样几块马赛克叠在一起时，后一块取的是前一块打过的颜色（照样看不出原文）。
    /// 透明度不动。
    /// </summary>
    public static void Apply(
        byte[] source, int sourceWidth, int sourceHeight, RectD rect, int cell,
        byte[] target, int targetWidth, int targetHeight, int offsetX, int offsetY)
    {
        cell = Math.Max(1, cell);
        var left = (int)Math.Clamp(Math.Floor(rect.X), 0, sourceWidth);
        var top = (int)Math.Clamp(Math.Floor(rect.Y), 0, sourceHeight);
        var right = (int)Math.Clamp(Math.Ceiling(rect.Right), 0, sourceWidth);
        var bottom = (int)Math.Clamp(Math.Ceiling(rect.Bottom), 0, sourceHeight);
        for (var cellTop = top; cellTop < bottom; cellTop += cell)
        {
            var cellBottom = Math.Min(cellTop + cell, bottom);
            for (var cellLeft = left; cellLeft < right; cellLeft += cell)
            {
                var cellRight = Math.Min(cellLeft + cell, right);
                var (r, g, b) = Average(source, sourceWidth, cellLeft, cellTop, cellRight, cellBottom);
                for (var y = Math.Max(cellTop, offsetY); y < Math.Min(cellBottom, offsetY + targetHeight); y++)
                {
                    for (var x = Math.Max(cellLeft, offsetX); x < Math.Min(cellRight, offsetX + targetWidth); x++)
                    {
                        var index = ((y - offsetY) * targetWidth + (x - offsetX)) * 4;
                        target[index] = b;
                        target[index + 1] = g;
                        target[index + 2] = r;
                    }
                }
            }
        }
    }
}
