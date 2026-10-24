// 强调色的深浅档：在 HSL 里调亮度（纯函数，配单测）。
// 以前是每个通道加减同一个常数，粉色的 Light3 直接冲到接近白色；改成按剩余空间比例调，色相和饱和度不变。
namespace KittyTools.Core;

public static class AccentRamp
{
    public readonly record struct Rgb(byte R, byte G, byte B);

    /// <summary>
    /// 调亮度：amount &gt; 0 往白走（l + (1-l)×amount），&lt; 0 往黑走（l × (1+amount)）。
    /// RGB 先换成 HSL 再换回来；灰阶（s = 0）和极端值都保持原样。
    /// </summary>
    public static Rgb Scale(Rgb color, double amount)
    {
        if (amount == 0)
        {
            return color;
        }

        var (h, s, l) = ToHsl(color);
        l = amount > 0
            ? l + (1 - l) * Math.Clamp(amount, 0, 1)
            : l * Math.Clamp(1 + amount, 0, 1);
        return FromHsl(h, s, l);
    }

    /// <summary>加亮的比例：Light1–3 / Dark1–3 六档（同 WinUI 的资源名）。</summary>
    public static readonly double[] Steps = { 0.15, 0.30, 0.45, -0.15, -0.30, -0.45 };

    internal static (double H, double S, double L) ToHsl(Rgb color)
    {
        var r = color.R / 255.0;
        var g = color.G / 255.0;
        var b = color.B / 255.0;
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var l = (max + min) / 2;
        if (Math.Abs(max - min) < 1e-9)
        {
            return (0, 0, l);
        }

        var d = max - min;
        var s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        double h;
        if (Math.Abs(max - r) < 1e-9)
        {
            h = (g - b) / d + (g < b ? 6 : 0);
        }
        else if (Math.Abs(max - g) < 1e-9)
        {
            h = (b - r) / d + 2;
        }
        else
        {
            h = (r - g) / d + 4;
        }

        return (h / 6, s, l);
    }

    internal static Rgb FromHsl(double h, double s, double l)
    {
        if (s <= 0)
        {
            var value = ToByte(l);
            return new Rgb(value, value, value);
        }

        var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        var p = 2 * l - q;
        return new Rgb(
            ToByte(Hue(p, q, h + 1.0 / 3)),
            ToByte(Hue(p, q, h)),
            ToByte(Hue(p, q, h - 1.0 / 3)));
    }

    private static double Hue(double p, double q, double t)
    {
        if (t < 0)
        {
            t += 1;
        }

        if (t > 1)
        {
            t -= 1;
        }

        if (t < 1.0 / 6)
        {
            return p + (q - p) * 6 * t;
        }

        if (t < 1.0 / 2)
        {
            return q;
        }

        if (t < 2.0 / 3)
        {
            return p + (q - p) * (2.0 / 3 - t) * 6;
        }

        return p;
    }

    private static byte ToByte(double value) => (byte)Math.Clamp((int)Math.Round(value * 255), 0, 255);
}
