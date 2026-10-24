// 框选几何（纯函数，配单测）：Windows 用物理像素、原点左上。
// 拖出新框、拖手柄 / 边调整（保持比例、从中心）、吸附、平移、比例预设、裁图像素矩形。
namespace KittyTools.Core;

public readonly record struct PointD(double X, double Y);

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;

    public double Bottom => Y + Height;

    public double MidX => X + Width / 2;

    public double MidY => Y + Height / 2;

    public static RectD FromLtrb(double left, double top, double right, double bottom)
        => new(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));

    public bool Contains(PointD point)
        => point.X >= X && point.X <= Right && point.Y >= Y && point.Y <= Bottom;

    public RectD Offset(double dx, double dy) => this with { X = X + dx, Y = Y + dy };
}

public enum SelectionHandle
{
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    Top,
    Right,
    Bottom,
    Left,
}

public static class RegionMath
{
    public const double MinimumSide = 8;

    public static bool MovesMinX(this SelectionHandle handle)
        => handle is SelectionHandle.TopLeft or SelectionHandle.BottomLeft or SelectionHandle.Left;

    public static bool MovesMaxX(this SelectionHandle handle)
        => handle is SelectionHandle.TopRight or SelectionHandle.BottomRight or SelectionHandle.Right;

    public static bool MovesMinY(this SelectionHandle handle)
        => handle is SelectionHandle.TopLeft or SelectionHandle.TopRight or SelectionHandle.Top;

    public static bool MovesMaxY(this SelectionHandle handle)
        => handle is SelectionHandle.BottomLeft or SelectionHandle.BottomRight or SelectionHandle.Bottom;

    public static PointD PointIn(this SelectionHandle handle, RectD rect) => new(
        handle.MovesMinX() ? rect.X : handle.MovesMaxX() ? rect.Right : rect.MidX,
        handle.MovesMinY() ? rect.Y : handle.MovesMaxY() ? rect.Bottom : rect.MidY);

    /// <summary>点中的手柄：整条边都能拖（边外 tolerance、边内 inner；两个都靠近时取近的）。</summary>
    public static SelectionHandle? HandleAt(
        PointD point,
        RectD rect,
        double tolerance = 8,
        double? inner = null)
    {
        var inside = inner ?? tolerance;
        int? Side(double value, double low, double high)
        {
            if (value < low - tolerance || value > high + tolerance)
            {
                return null;
            }

            var nearLow = value <= low + inside;
            var nearHigh = value >= high - inside;
            if (nearLow && nearHigh)
            {
                return value - low <= high - value ? -1 : 1;
            }

            return nearLow ? -1 : nearHigh ? 1 : 0;
        }

        var x = Side(point.X, rect.X, rect.Right);
        var y = Side(point.Y, rect.Y, rect.Bottom);
        if (x is null || y is null)
        {
            return null;
        }

        return (x.Value, y.Value) switch
        {
            (-1, -1) => SelectionHandle.TopLeft,
            (1, -1) => SelectionHandle.TopRight,
            (-1, 1) => SelectionHandle.BottomLeft,
            (1, 1) => SelectionHandle.BottomRight,
            (0, -1) => SelectionHandle.Top,
            (0, 1) => SelectionHandle.Bottom,
            (-1, 0) => SelectionHandle.Left,
            (1, 0) => SelectionHandle.Right,
            _ => null,
        };
    }

    /// <summary>拖出新框：从锚点拉到 point；ratio 按拖得更远的那边定大小；fromCenter 时锚点是中心。</summary>
    public static RectD Drawn(
        PointD anchor,
        PointD point,
        RectD bounds,
        double? ratio = null,
        bool fromCenter = false)
    {
        var width = Math.Abs(point.X - anchor.X);
        var height = Math.Abs(point.Y - anchor.Y);
        if (ratio is { } value)
        {
            width = Math.Max(width, height * value);
            height = value == 0 ? height : width / value;
        }

        var scale = fromCenter ? 2 : 1;
        return Fitted(
            anchor,
            width * scale,
            height * scale,
            fromCenter ? 0.5 : point.X >= anchor.X ? 0 : 1,
            fromCenter ? 0.5 : point.Y >= anchor.Y ? 0 : 1,
            ratio is not null,
            bounds);
    }

    /// <summary>拖手柄：从按下时的框 original 出发，把这条边移到 point；越过对边就翻过去。</summary>
    public static RectD Resized(
        RectD original,
        SelectionHandle handle,
        PointD point,
        RectD bounds,
        double? ratio = null,
        bool fromCenter = false)
    {
        var x = Math.Clamp(point.X, bounds.X, bounds.Right);
        var y = Math.Clamp(point.Y, bounds.Y, bounds.Bottom);
        var movesX = handle.MovesMinX() || handle.MovesMaxX();
        var movesY = handle.MovesMinY() || handle.MovesMaxY();
        var centerX = fromCenter || (!movesX && ratio is not null);
        var centerY = fromCenter || (!movesY && ratio is not null);
        var fixedX = centerX ? original.MidX : handle.MovesMinX() ? original.Right : original.X;
        var fixedY = centerY ? original.MidY : handle.MovesMinY() ? original.Bottom : original.Y;
        var width = movesX ? Math.Abs(x - fixedX) * (centerX ? 2 : 1) : original.Width;
        var height = movesY ? Math.Abs(y - fixedY) * (centerY ? 2 : 1) : original.Height;
        if (ratio is { } value)
        {
            if (movesX && movesY)
            {
                if (width >= height * value)
                {
                    height = value == 0 ? height : width / value;
                }
                else
                {
                    width = height * value;
                }
            }
            else if (movesX)
            {
                height = value == 0 ? height : width / value;
            }
            else
            {
                width = height * value;
            }
        }

        double Anchor(bool moves, bool center, double pointer, double fixedValue, bool low)
        {
            if (center)
            {
                return 0.5;
            }

            if (!moves)
            {
                return 0;
            }

            return pointer > fixedValue ? 0 : pointer < fixedValue ? 1 : low ? 1 : 0;
        }

        return Fitted(
            new PointD(fixedX, fixedY),
            width,
            height,
            Anchor(movesX, centerX, x, fixedX, handle.MovesMinX()),
            Anchor(movesY, centerY, y, fixedY, handle.MovesMinY()),
            ratio is not null,
            bounds);
    }

    /// <summary>吸附：threshold 内离 value 最近的候选边；没有就原值，edge 为 null。</summary>
    public static (double Value, double? Edge) Snap(double value, IReadOnlyList<double> edges, double threshold = 6)
    {
        if (edges.Count == 0)
        {
            return (value, null);
        }

        var nearest = edges.OrderBy(edge => Math.Abs(edge - value)).First();
        return Math.Abs(nearest - value) <= threshold ? (nearest, nearest) : (value, null);
    }

    /// <summary>平移选区，整块留在 bounds 里。</summary>
    public static RectD Moved(RectD rect, double dx, double dy, RectD bounds)
    {
        var x = Math.Clamp(rect.X + dx, bounds.X, Math.Max(bounds.X, bounds.Right - rect.Width));
        var y = Math.Clamp(rect.Y + dy, bounds.Y, Math.Max(bounds.Y, bounds.Bottom - rect.Height));
        return rect with { X = x, Y = y };
    }

    /// <summary>套用比例预设：宽不变、高按比例，顶边和水平中心不动；下面放不下就按剩下的高反推宽。</summary>
    public static RectD ApplyingRatio(double ratio, RectD rect, RectD bounds)
    {
        var width = rect.Width;
        var height = ratio == 0 ? 0 : width / ratio;
        if (rect.Bottom - height < bounds.Y)
        {
            height = rect.Bottom - bounds.Y;
            width = height * ratio;
        }

        return new RectD(rect.MidX - width / 2, rect.Bottom - height, width, height);
    }

    /// <summary>选区的物理像素矩形：先乘缩放、四边向外取整，再夹进冻结帧。</summary>
    public static RectD PixelRect(RectD selection, double scale, int imageWidth, int imageHeight)
    {
        var left = Math.Clamp(Math.Floor(selection.X * scale), 0, imageWidth);
        var top = Math.Clamp(Math.Floor(selection.Y * scale), 0, imageHeight);
        var right = Math.Clamp(Math.Ceiling(selection.Right * scale), 0, imageWidth);
        var bottom = Math.Clamp(Math.Ceiling(selection.Bottom * scale), 0, imageHeight);
        return RectD.FromLtrb(left, top, right, bottom);
    }

    private static RectD Fitted(
        PointD fixedPoint,
        double width,
        double height,
        double anchorX,
        double anchorY,
        bool keepsRatio,
        RectD bounds)
    {
        double Room(double value, double anchor, double low, double high)
            => Math.Max(
                0,
                Math.Min(
                    anchor < 1 ? (high - value) / (1 - anchor) : double.PositiveInfinity,
                    anchor > 0 ? (value - low) / anchor : double.PositiveInfinity));
        var maxWidth = Room(fixedPoint.X, anchorX, bounds.X, bounds.Right);
        var maxHeight = Room(fixedPoint.Y, anchorY, bounds.Y, bounds.Bottom);
        if (keepsRatio)
        {
            var shrink = Math.Min(
                1,
                Math.Min(width > maxWidth ? maxWidth / width : 1, height > maxHeight ? maxHeight / height : 1));
            width *= shrink;
            height *= shrink;
        }
        else
        {
            width = Math.Min(width, maxWidth);
            height = Math.Min(height, maxHeight);
        }

        width = Math.Max(width, 1);
        height = Math.Max(height, 1);
        return new RectD(
            Math.Clamp(fixedPoint.X - width * anchorX, bounds.X, Math.Max(bounds.X, bounds.Right - width)),
            Math.Clamp(fixedPoint.Y - height * anchorY, bounds.Y, Math.Max(bounds.Y, bounds.Bottom - height)),
            width,
            height);
    }
}
