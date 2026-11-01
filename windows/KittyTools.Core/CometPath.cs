// 翻译卡彗星边框的几何（照 mac CometBorder；纯函数，配单测 CometPathTests）。
// mac：卡片中心一道角向渐变（0.62 透明 → 0.78 强调色 0.35 → 0.92 强调色 → 1.0 透明）匀速转，2.4 s 一圈，边框当遮罩。
// WinUI 的合成层没有角向渐变，TranslateCardView 用同一条描边上的几段虚线叠出来：
// - Layers：把这条亮度曲线拆成 N 层嵌套的段，第 k 层盖住亮度 ≥ k/N 的那一截，叠起来（源在上）正好是 k/N，段和段之间没有接缝。
// - HeadTrack：mac 是角度匀速，落到描边上并不匀速——扁卡片上光在长边中间走得慢、绕短边时一闪而过。这里把匀速转的
//   角度换成描边上的位置，合成器照这些关键帧走。描边的起点按「左上圆角之后的上边、顺时针」算（D2D 圆角矩形的走法）。
namespace KittyTools.Core;

public static class CometPath
{
    /// <summary>一层：从光头往回（负）/ 往前多少起、多长（都按一圈 = 1），这一层的不透明度。</summary>
    public readonly record struct Layer(double Start, double Length, double Alpha);

    // mac 的亮度曲线，以光头为 0、一圈为 1：尾巴 0.30（前 0.16 从 0 升到 0.35，后 0.14 升到 1），光头前 0.08 淡到 0。
    private const double Tail = 0.30;
    private const double Knee = 0.14;
    private const double KneeLevel = 0.35;
    private const double Front = 0.08;

    /// <summary>离光头 s（一圈为 1，往回为负）处的亮度 0–1。</summary>
    public static double Brightness(double s) => s switch
    {
        < -Tail or > Front => 0,
        < -Knee => KneeLevel * (s + Tail) / (Tail - Knee),
        <= 0 => KneeLevel + (1 - KneeLevel) * (s + Knee) / Knee,
        _ => 1 - s / Front,
    };

    /// <summary>拆成 count 层：第一层最长最淡，最后一层贴着光头、不透明。</summary>
    public static Layer[] Layers(int count)
    {
        var layers = new Layer[count];
        for (var k = 1; k <= count; k++)
        {
            // 取这一档的中间：取到 1 时最后一层就缩成一个点了。
            var level = (k - 0.5) / count;
            var back = level <= KneeLevel
                ? Tail - (Tail - Knee) * level / KneeLevel
                : Knee * (1 - (level - KneeLevel) / (1 - KneeLevel));
            var ahead = Front * (1 - level);
            // 叠到第 k 层合起来是 k/N：1 - (1 - k/N) / (1 - (k-1)/N) = 1 / (N - k + 1)。
            layers[k - 1] = new Layer(-back, back + ahead, 1.0 / (count - k + 1));
        }

        return layers;
    }

    /// <summary>
    /// 光头从 startTurn（0 = 正上方，顺时针一圈为 1）起匀速转一圈，每 1/count 圈一个点、共 count + 1 个：
    /// 光头在描边上的位置（一圈为 1，从描边起点算，往后一直加，不回绕；最后一个正好比第一个多 1）。
    /// </summary>
    public static double[] HeadTrack(double width, double height, double radius, double startTurn, int count)
    {
        var track = new double[count + 1];
        if (width <= 0 || height <= 0)
        {
            for (var i = 0; i <= count; i++)
            {
                track[i] = Frac(startTurn) + (double)i / count;
            }

            return track;
        }

        radius = Math.Clamp(radius, 0, Math.Min(width, height) / 2);
        var origin = TurnOf(PointAt(width, height, radius, 0));
        for (var i = 0; i <= count; i++)
        {
            track[i] = PathAt(width, height, radius, origin, Frac(startTurn + (double)i / count - origin));
            while (i > 0 && track[i] < track[i - 1])
            {
                track[i] += 1;
            }
        }

        track[count] = track[0] + 1;
        return track;
    }

    /// <summary>描边上 s 处（一圈为 1）那一点，以卡片中心为原点、y 向下。</summary>
    public static (double X, double Y) PointAt(double width, double height, double radius, double s)
    {
        var straightX = width - 2 * radius;
        var straightY = height - 2 * radius;
        var arc = Math.PI * radius / 2;
        var d = Frac(s) * (2 * (straightX + straightY) + 4 * arc);
        var (hx, hy) = (width / 2, height / 2);
        var (cx, cy) = (hx - radius, hy - radius);

        // 上边往右 → 右上角 → 右边往下 → 右下角 → 下边往左 → 左下角 → 左边往上 → 左上角。
        if (d < straightX)
        {
            return (-cx + d, -hy);
        }

        d -= straightX;
        if (d < arc)
        {
            return Round(cx, -cy, -Math.PI / 2, d, radius);
        }

        d -= arc;
        if (d < straightY)
        {
            return (hx, -cy + d);
        }

        d -= straightY;
        if (d < arc)
        {
            return Round(cx, cy, 0, d, radius);
        }

        d -= arc;
        if (d < straightX)
        {
            return (cx - d, hy);
        }

        d -= straightX;
        if (d < arc)
        {
            return Round(-cx, cy, Math.PI / 2, d, radius);
        }

        d -= arc;
        if (d < straightY)
        {
            return (-hx, cy - d);
        }

        d -= straightY;
        return Round(-cx, -cy, Math.PI, Math.Min(d, arc), radius);
    }

    /// <summary>圆角上的点：圆心 (x, y)，从 start 弧度起顺时针走了 d。</summary>
    private static (double X, double Y) Round(double x, double y, double start, double d, double radius)
    {
        if (radius <= 0)
        {
            return (x, y);
        }

        var angle = start + d / radius;
        return (x + radius * Math.Cos(angle), y + radius * Math.Sin(angle));
    }

    /// <summary>点在哪个方向：0 = 正上方，顺时针一圈为 1。</summary>
    private static double TurnOf((double X, double Y) point) => Frac(Math.Atan2(point.X, -point.Y) / (2 * Math.PI));

    /// <summary>描边上哪一处的方向（相对起点）是 target：凸的、中心在里面，方向沿描边单调增，二分就行。</summary>
    private static double PathAt(double width, double height, double radius, double origin, double target)
    {
        double low = 0, high = 1;
        for (var step = 0; step < 48; step++)
        {
            var middle = (low + high) / 2;
            if (Frac(TurnOf(PointAt(width, height, radius, middle)) - origin) < target)
            {
                low = middle;
            }
            else
            {
                high = middle;
            }
        }

        return (low + high) / 2;
    }

    private static double Frac(double value) => value - Math.Floor(value);
}
