// 弹簧进度的纯函数（配单测）：轻提示胶囊的宽度生长、需要逐帧设值的小动效用它。
// 和 Motion 的 Composition 弹簧（DampingRatio / Period）是同一个感知参数：bounce 越大越弹。
// 只在做宽度（布局属性）这种 Composition 插不了的场景用；其它地方用 Motion。
namespace KittyTools.Core;

public static class SpringEase
{
    /// <summary>衰减系数（对应 bounce ≈ 0.22 时的观感）。</summary>
    private const double Decay = 6.5;

    /// <summary>
    /// t ∈ [0,1] 的进度，有回弹时可能超过 1。t ≤ 0 返回 0，t ≥ 1 返回 1。
    /// </summary>
    public static double Progress(double t, double bounce)
    {
        if (t <= 0)
        {
            return 0;
        }

        if (t >= 1)
        {
            return 1;
        }

        var b = Math.Clamp(bounce, 0, 0.9);
        if (b < 0.02)
        {
            // 没有回弹：普通 ease-out，严格不超过 1。
            return 1 - Math.Pow(1 - t, 3);
        }

        var damping = 1 - b;
        var value = 1 - Math.Exp(-Decay * damping * t) * Math.Cos(2 * Math.PI * t);
        // 末段收敛到 1，别让调用方在 t=0.999 时还看到 1.0001 的抖动。
        return t > 0.98 ? 1 : value;
    }

    /// <summary>按进度算当前值。</summary>
    public static double Lerp(double from, double to, double t, double bounce)
        => from + (to - from) * Progress(t, bounce);
}
