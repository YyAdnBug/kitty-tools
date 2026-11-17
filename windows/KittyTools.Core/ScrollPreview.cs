// 长截图拍的时候旁边那块预览（PLAN-v9 S11，照 mac ScrollCapture.swift 的 previewRange / browse / scrubberFrame）的纯函数，配单测：
// 预览取长图的哪一段、滚轮往回看后看哪一段、右边的位置指示条画在哪、面板摆在选区哪边；
// R106 起还有预览的动效（照 mac updatePreview / HeightReadingView）：纸带滑多远、滑到哪了（easeOut），接缝闪光的不透明度，
// 上下渐隐多高，高度数字每一位怎么滚。时长、颜色、曲线都照 mac，面板（ScrollPreviewPanel）只管按这些画。
// 行号是 ScrollCanvas 的行号（0 = 长图最上面）；往上滚时新内容接在最上面，「最新那头」是第 0 行。位移是 DIP，往下为正。
using System.Globalization;

namespace KittyTools.Core;

/// <summary>
/// 高度读数的一位（从高位往低位排，按位值右对齐）：原来是哪个字、现在是哪个字；null = 那时还没有这一位 / 这一位没了
/// （位数变了时多出来的高位）。
/// </summary>
public readonly record struct DigitPlace(char? From, char? To)
{
    /// <summary>这一位变了（要滚）。</summary>
    public bool Changed => From != To;
}

public static class ScrollPreview
{
    /// <summary>纸带滑动的时长（秒）：新拼上的一截从长的那头推进来，mac 0.2 s easeOut。</summary>
    public const double TapeSeconds = 0.2;

    /// <summary>接缝闪光的时长（秒）：不透明度从 SeamPeak 线性淡到 0（mac 0.25 → 0、0.4 s）。</summary>
    public const double SeamSeconds = 0.4;

    public const double SeamPeak = 0.25;

    /// <summary>接缝闪光多高（DIP）：从长的那头那条边往里由品牌粉渐隐到透明（mac 24 pt）。</summary>
    public const double SeamHeight = 24;

    /// <summary>预览上下各渐隐多高（DIP，mac fade 18 pt）。</summary>
    public const double FadeHeightMax = 18;

    /// <summary>预览上下各渐隐多高：18 DIP，预览很矮时最多占它高的 0.3（mac layoutFade）。</summary>
    public static double FadeHeight(double box) => Math.Max(0, Math.Min(FadeHeightMax, box * 0.3));

    /// <summary>
    /// 新拼上 grown 行以后纸带从哪儿滑回 0（DIP，往下为正）：长图 canvasWidth 宽、预览 previewWidth 宽，新拼上的那截在预览里多高就推多远；
    /// 往下长从下面推上来（正）、往上长从上面推下来（负）。current 是上一段还没滑完的位移：接着它算（新图里旧内容的位置不跳），
    /// 夹在 ±box（预览高）以内（mac 是 min(shift, box)）。
    /// </summary>
    public static double TapeStart(int grown, double previewWidth, int canvasWidth, double box, bool growingUp, double current)
    {
        var shift = Math.Max(grown, 0) * previewWidth / Math.Max(canvasWidth, 1);
        var limit = Math.Max(box, 0);
        return Math.Clamp(current + (growingUp ? -shift : shift), -limit, limit);
    }

    /// <summary>纸带滑了 elapsed 秒时的位移：from → 0，easeOut（mac CAMediaTimingFunction.easeOut），滑完是 0。</summary>
    public static double TapeOffset(double from, double elapsed) => from * (1 - EaseOut(elapsed / TapeSeconds));

    /// <summary>接缝闪光过了 elapsed 秒时的不透明度：SeamPeak → 0 线性（mac CABasicAnimation 默认线性），闪完是 0。</summary>
    public static double SeamOpacity(double elapsed) => SeamPeak * Math.Clamp(1 - elapsed / SeamSeconds, 0, 1);

    /// <summary>Core Animation 的 easeOut：三次贝塞尔 (0, 0, 0.58, 1)。</summary>
    public static double EaseOut(double t) => CubicBezier(0, 0, 0.58, 1, t);

    /// <summary>
    /// 三次贝塞尔缓动（同 CSS cubic-bezier / CAMediaTimingFunction）：两个控制点 (x1, y1)、(x2, y2)，t 是时间进度，返回值的进度。
    /// x1、x2 在 [0, 1] 里时 x(s) 单调，二分找到 x(s) = t 的 s 再算 y(s)。t ≤ 0 是 0，t ≥ 1 是 1。
    /// </summary>
    public static double CubicBezier(double x1, double y1, double x2, double y2, double t)
    {
        if (t <= 0)
        {
            return 0;
        }

        if (t >= 1)
        {
            return 1;
        }

        double low = 0, high = 1;
        for (var step = 0; step < 32; step++)
        {
            var middle = (low + high) / 2;
            if (Bezier(x1, x2, middle) < t)
            {
                low = middle;
            }
            else
            {
                high = middle;
            }
        }

        return Bezier(y1, y2, (low + high) / 2);

        // 起点 0、终点 1 的一维三次贝塞尔。
        static double Bezier(double first, double second, double s)
            => 3 * first * s * (1 - s) * (1 - s) + 3 * second * s * s * (1 - s) + s * s * s;
    }

    /// <summary>
    /// 高度数字从 from 变到 to 时每一位怎么滚（mac numericText）：按位值右对齐（个位对个位），从高位往低位排；
    /// 位数变多时新长出来的高位 From 是 null（从下面滚进来），变少时没了的高位 To 是 null。不分组（mac grouping never），负数当 0。
    /// </summary>
    public static DigitPlace[] Places(int from, int to)
    {
        var before = Math.Max(from, 0).ToString(CultureInfo.InvariantCulture);
        var after = Math.Max(to, 0).ToString(CultureInfo.InvariantCulture);
        var length = Math.Max(before.Length, after.Length);
        var places = new DigitPlace[length];
        for (var index = 0; index < length; index++)
        {
            var old = index - (length - before.Length);
            var fresh = index - (length - after.Length);
            places[index] = new DigitPlace(old >= 0 ? before[old] : (char?)null, fresh >= 0 ? after[fresh] : (char?)null);
        }

        return places;
    }

    /// <summary>数字往哪边滚：变大 1（新的从下面上来、旧的往上走），变小 −1（反过来），没变 0。</summary>
    public static int RollDirection(int from, int to) => Math.Sign((long)to - from);

    /// <summary>
    /// 预览显示哪一段：visible 是预览里放得下多少行，from 是起始行（null = 跟着最新那头），夹进长图里。
    /// 长图整张放得下时就是整张。
    /// </summary>
    public static (int Start, int Count) Range(int height, int visible, int? from, bool growingUp)
    {
        var count = Math.Min(height, Math.Max(visible, 0));
        if (count <= 0)
        {
            return (0, 0);
        }

        if (from is not { } start)
        {
            return growingUp ? (0, count) : (height - count, count);
        }

        return (Math.Clamp(start, 0, height - count), count);
    }

    /// <summary>
    /// 滚轮往回看：往上挪了 rows 行（正的 = 看长图上面的内容，同滚轮往上）后从哪行看起；
    /// 滚回最新那头、或长图整张都在预览里时返回 null（回到跟随）。
    /// </summary>
    public static int? Browse(int? from, double rows, int height, int visible, bool growingUp)
    {
        var (start, count) = Range(height, visible, from, growingUp);
        var limit = height - count;
        if (limit <= 0)
        {
            return null;
        }

        var row = Math.Clamp((int)Math.Round(start - rows), 0, limit);
        return (growingUp ? row <= 0 : row >= limit) ? null : row;
    }

    /// <summary>
    /// 位置指示条在轨道（预览框的高，DIP）里的上边和高：高按看得见的那段占长图多少（最矮 20），从上往下走。
    /// 长图整张都在预览里时返回 null（不画）。
    /// </summary>
    public static (double Top, double Height)? Scrubber(double track, int start, int count, int height)
    {
        if (count <= 0 || height <= count || track <= 0)
        {
            return null;
        }

        var size = Math.Min(Math.Max(track * count / height, 20), track);
        return ((track - size) * Math.Clamp(start, 0, height - count) / (height - count), size);
    }

    /// <summary>
    /// 面板左上角（物理像素）：选区右边放得下放右边，不然放左边，两边都放不下（选区差不多整屏）就贴在选区里面右边；
    /// 上边和选区上边对齐，夹进工作区。
    /// </summary>
    public static (int X, int Y) PanelOrigin(
        int regionLeft, int regionTop, int regionRight,
        int workLeft, int workTop, int workRight, int workBottom,
        int width, int height, int gap)
    {
        var x = regionRight + gap + width <= workRight
            ? regionRight + gap
            : regionLeft - gap - width >= workLeft
                ? regionLeft - gap - width
                : regionRight - gap - width;
        x = Math.Clamp(x, workLeft, Math.Max(workLeft, workRight - width));
        var y = Math.Clamp(regionTop, workTop, Math.Max(workTop, workBottom - height));
        return (x, y);
    }
}
