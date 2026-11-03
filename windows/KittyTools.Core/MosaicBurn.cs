// 把马赛克打进图（纯函数，配单测）：截图历史存的「原图」里不留马赛克下面的明文（第四轮体检 E6，PLAN-v11 M4）。
// 格子和取色同截图遮罩画马赛克那一套（Screenshot/Annotation.cs 的 DrawMosaic，它也调这里的 Average）：
// 从框的左上角取整处起、每 cell 像素一格，格内隔几个像素抽样取平均。
// ponytail: 屏幕上「模糊」那一档是把格子平滑放大，打进原图的是方块（信息在取平均时已经丢了，只是样子不同）；
// 从历史再打开改标注时那一块看着是方块，成品图照旧是模糊的。要一模一样就改成用 Win2D 画一遍再取像素。
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
