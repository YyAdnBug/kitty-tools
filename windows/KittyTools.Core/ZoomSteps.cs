// 长图标注的缩放档位（PLAN-v11 C1，照 mac ScrollCanvas 的 Ctrl+= / Ctrl+-）：按「实际大小」的百分比一档一档放大缩小。
// 1 = 实际大小（长图的 1 像素 = 屏幕 1 物理像素）；适合宽度那一档不在表里，从它出发也找得到上下一档。
namespace KittyTools.Core;

public static class ZoomSteps
{
    public static readonly double[] Levels = { 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4 };

    /// <summary>比 current 大（up）/ 小的下一档；已经到头了返回最大 / 最小那一档。差不到 1% 的算同一档。</summary>
    public static double Next(double current, bool up)
    {
        if (up)
        {
            foreach (var level in Levels)
            {
                if (level > current * 1.01)
                {
                    return level;
                }
            }

            return Levels[^1];
        }

        for (var index = Levels.Length - 1; index >= 0; index--)
        {
            if (Levels[index] < current * 0.99)
            {
                return Levels[index];
            }
        }

        return Levels[0];
    }

    /// <summary>提示里写的百分比（取整）。</summary>
    public static string Percent(double zoom) => $"{Math.Round(zoom * 100):0}%";
}
