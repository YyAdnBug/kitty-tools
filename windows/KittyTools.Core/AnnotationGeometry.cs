// 截图标注的模型和几何（纯函数，配单测 AnnotationGeometryTests；照 mac Annotation.swift，PLAN-v9-annotate §1–§5）：
// 10 种工具的元数据、样式（调色板下标 / 粗细档 / 选项）、拖出来的形状和 Shift 约束、外框、点中、手柄、改大小、
// 箭头 / 直线的弯曲、挪动、复制、序号编号、画的层次。画法（Win2D）在 App 的 Screenshot/Annotation.cs。
// 坐标是遮罩里这块屏的物理像素、原点左上（mac 是点、原点左下：手柄的上下、复制的偏移方向跟着翻过来）；
// 线宽、字号、容差这些尺寸按 DIP 定（同 mac 的点），用的时候乘 unit（每 DIP 几像素，就是这块屏的缩放）。
namespace KittyTools.Core;

public readonly record struct VectorD(double X, double Y)
{
    public static readonly VectorD Zero = new(0, 0);
}

/// <summary>顺序就是工具栏顺序和数字键（1–9、0）。名字小写后进了截图历史的 JSON，以后别改。</summary>
public enum AnnotationKind
{
    Rectangle,
    Ellipse,
    Arrow,
    Line,
    Pen,
    Highlighter,
    Text,
    Counter,
    Mosaic,
    Spotlight,
}

/// <summary>选中标注的调整手柄：矩形类四角，线类两端，箭头、直线还有弧线中点（Bend，拖它弯曲）。</summary>
public enum AnnotationHandle
{
    Start,
    End,
    Bend,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

/// <summary>标注的颜色（内容色，不随深浅色、强调色变；mac Annotation.Palette）。</summary>
public static class AnnotationPalette
{
    public const int Pink = 0;
    public const int Red = 1;
    public const int Yellow = 3;
    public const int White = 7;

    /// <summary>品牌粉、红、橙、黄、绿、蓝、黑、白（ARGB）。</summary>
    public static readonly uint[] Argb =
    {
        0xFFFF4D7E, 0xFFFF3B30, 0xFFFF9500, 0xFFFFCC00, 0xFF34C759, 0xFF007AFF, 0xFF000000, 0xFFFFFFFF,
    };

    public static readonly string[] Titles = { "粉", "红", "橙", "黄", "绿", "蓝", "黑", "白" };

    public static uint ArgbOf(int index) => Argb[Math.Clamp(index, 0, Argb.Length - 1)];

    /// <summary>压在这个颜色上的字（底色文字、序号）：黄、白上用黑字，其余白字。</summary>
    public static uint InkOf(int index) => index is Yellow or White ? 0xFF000000 : 0xFFFFFFFF;

    /// <summary>旧数据只存了 ARGB：找最近的那个颜色。</summary>
    public static int Nearest(uint argb)
    {
        var best = Red;
        var bestDistance = long.MaxValue;
        for (var index = 0; index < Argb.Length; index++)
        {
            long dr = (int)((argb >> 16) & 0xFF) - (int)((Argb[index] >> 16) & 0xFF);
            long dg = (int)((argb >> 8) & 0xFF) - (int)((Argb[index] >> 8) & 0xFF);
            long db = (int)(argb & 0xFF) - (int)(Argb[index] & 0xFF);
            var distance = dr * dr + dg * dg + db * db;
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = index;
            }
        }

        return best;
    }
}

/// <summary>Color 是 AnnotationPalette 的下标，Weight 是 0–2 的档（细 / 中 / 粗），Option 是 OptionTitles 的下标。</summary>
public readonly record struct AnnotationStyle(int Color, int Weight, int Option)
{
    /// <summary>第一次用：红色中号。</summary>
    public static readonly AnnotationStyle Default = new(AnnotationPalette.Red, 1, 0);

    /// <summary>这个工具第一次用的样式：荧光笔黄色，其余红色中号。</summary>
    public static AnnotationStyle DefaultFor(AnnotationKind kind)
        => kind == AnnotationKind.Highlighter ? Default with { Color = AnnotationPalette.Yellow } : Default;

    private int Index => Math.Clamp(Weight, 0, 2);

    public double LineWidth => Index switch { 0 => 2, 1 => 4, _ => 6 };

    public double FontSize => Index switch { 0 => 14, 1 => 20, _ => 28 };

    /// <summary>马赛克每格的边长。</summary>
    public double MosaicBlock => Index switch { 0 => 6, 1 => 10, _ => 16 };

    public double CounterDiameter => Index switch { 0 => 20, 1 => 26, _ => 34 };

    public double HighlighterHeight => Index switch { 0 => 12, 1 => 18, _ => 26 };

    /// <summary>聚光灯外面压暗的程度。</summary>
    public double SpotlightDim => Index switch { 0 => 0.35, 1 => 0.5, _ => 0.65 };

    /// <summary>旧数据只存了线宽（2 / 3 / 5 / 8 那四档）：换成最近的档。</summary>
    public static int WeightFromWidth(double width) => width < 2.5 ? 0 : width <= 5 ? 1 : 2;
}

public static class AnnotationKinds
{
    public static readonly AnnotationKind[] All = Enum.GetValues<AnnotationKind>();

    public static string Title(AnnotationKind kind) => kind switch
    {
        AnnotationKind.Rectangle => "矩形",
        AnnotationKind.Ellipse => "椭圆",
        AnnotationKind.Arrow => "箭头",
        AnnotationKind.Line => "直线",
        AnnotationKind.Pen => "画笔",
        AnnotationKind.Highlighter => "荧光笔",
        AnnotationKind.Text => "文字",
        AnnotationKind.Counter => "序号",
        AnnotationKind.Mosaic => "马赛克",
        _ => "聚光灯",
    };

    /// <summary>数字键：第 10 个是 0。</summary>
    public static string Key(AnnotationKind kind)
        => (((int)kind + 1) % 10).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>存盘的名字（截图历史 JSON 的 tool）。</summary>
    public static string StorageName(AnnotationKind kind) => kind.ToString().ToLowerInvariant();

    /// <summary>认不得的名字（以后加的工具、数字）返回 null。</summary>
    public static AnnotationKind? Parse(string? name)
    {
        foreach (var kind in All)
        {
            if (string.Equals(StorageName(kind), name, StringComparison.OrdinalIgnoreCase))
            {
                return kind;
            }
        }

        return null;
    }

    /// <summary>马赛克、聚光灯没有颜色（托盘不出色点）。</summary>
    public static bool HasColor(AnnotationKind kind) => kind is not (AnnotationKind.Mosaic or AnnotationKind.Spotlight);

    /// <summary>拖出来的；文字、序号是单击放置。</summary>
    public static bool IsDragDrawn(AnnotationKind kind) => kind is not (AnnotationKind.Text or AnnotationKind.Counter);

    /// <summary>样式托盘的选项分段（Style.Option 是下标）；空 = 没有选项。</summary>
    public static string[] OptionTitles(AnnotationKind kind) => kind switch
    {
        AnnotationKind.Rectangle or AnnotationKind.Ellipse => new[] { "空心", "实心" },
        AnnotationKind.Text => new[] { "无底", "描边", "底色" },
        AnnotationKind.Mosaic => new[] { "像素", "模糊" },
        _ => Array.Empty<string>(),
    };

    public static string[] WeightTitles(AnnotationKind kind) => kind switch
    {
        AnnotationKind.Text => new[] { "小", "中", "大" },
        AnnotationKind.Spotlight => new[] { "浅", "中", "深" },
        _ => new[] { "细", "中", "粗" },
    };
}

/// <summary>
/// 一条标注（不可变：改一下就是一条新的、Id 不变，撤销栈存的是列表的浅拷贝）。哪几个字段有用看 Kind：
/// 矩形 / 椭圆 / 马赛克 / 聚光灯用 Rect；箭头 / 直线用 From、To、Bend，荧光笔用 From、To；画笔用 Points；
/// 文字用 Rect（左上角 + App 量出来的文字框大小）和 Text；序号用 From（圆心）和 Number。
/// </summary>
public sealed record Annotation
{
    /// <summary>阴影最远能画到的地方（DIP，mac shadowReach）。</summary>
    public const double ShadowReach = 8;

    /// <summary>「底色」文字的色块在文字框左右各留 6、上下各留 2。</summary>
    public const double PlatePaddingX = 6;

    public const double PlatePaddingY = 2;

    /// <summary>弯曲手柄离弦不到这么远（DIP）就拉直。</summary>
    public const double StraightSnap = 4;

    /// <summary>弧线中点沿弦最多偏离弦中点多少（弦长为单位）：¼ 时弧线在弦上的投影从头到尾单调，不会拐过端点再折回来。</summary>
    public const double MaxAlong = 0.25;

    public Guid Id { get; init; } = Guid.NewGuid();

    public AnnotationKind Kind { get; init; }

    public AnnotationStyle Style { get; init; } = AnnotationStyle.Default;

    public RectD Rect { get; init; }

    public PointD From { get; init; }

    public PointD To { get; init; }

    /// <summary>弯箭头 / 弯直线的弧线中点离弦中点的偏移，按弦记：X 沿弦（From → To）、Y 在弦的法向，单位是弦长；Zero = 直的。</summary>
    public VectorD Bend { get; init; }

    public IReadOnlyList<PointD> Points { get; init; } = Array.Empty<PointD>();

    public string Text { get; init; } = string.Empty;

    public int Number { get; init; }

    public bool Equals(Annotation? other)
        => other is not null && Id == other.Id && Kind == other.Kind && Style == other.Style && Rect == other.Rect &&
           From == other.From && To == other.To && Bend == other.Bend && Text == other.Text &&
           Number == other.Number && Points.SequenceEqual(other.Points);

    public override int GetHashCode() => HashCode.Combine(Id, Kind, Rect, From, To);

    private bool IsBox => Kind is AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Mosaic or
        AnnotationKind.Spotlight;

    private bool IsSegment => Kind is AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter;

    private bool Filled => Style.Option == 1;

    // MARK: 几何

    /// <summary>画出来占的范围（含线宽、箭头，不含阴影），用来画选中框、点中文字和马赛克。</summary>
    public RectD Bounds(double unit)
    {
        var width = Style.LineWidth * unit;
        switch (Kind)
        {
            case AnnotationKind.Rectangle or AnnotationKind.Ellipse:
                return Inflate(Rect, width / 2);
            case AnnotationKind.Arrow:
                return Inflate(CurveBox(From, To, Bend), Math.Max(ArrowWing(From, To, width, Bend), width));
            case AnnotationKind.Line:
                return Inflate(CurveBox(From, To, Bend), width / 2);
            case AnnotationKind.Highlighter:
                return Inflate(Box(From, To), Style.HighlighterHeight * unit / 2);
            case AnnotationKind.Pen:
                if (Points.Count == 0)
                {
                    return default;
                }

                return Inflate(
                    RectD.FromLtrb(
                        Points.Min(point => point.X), Points.Min(point => point.Y),
                        Points.Max(point => point.X), Points.Max(point => point.Y)),
                    width / 2);
            case AnnotationKind.Text:
                // 有的字形会画出文字框：按字号留边（至少盖住底色块），局部重画不留残影
                return Inflate(Rect, Math.Max(Style.FontSize / 3, PlatePaddingX) * unit);
            case AnnotationKind.Counter:
            {
                var radius = (Style.CounterDiameter / 2 + 1) * unit; // 白描边一半在圆外
                return new RectD(From.X - radius, From.Y - radius, radius * 2, radius * 2);
            }
            default:
                return Rect;
        }
    }

    /// <summary>连阴影一起占的范围（马赛克、荧光笔、聚光灯没有阴影）。</summary>
    public RectD DrawBounds(double unit)
        => Kind is AnnotationKind.Mosaic or AnnotationKind.Highlighter or AnnotationKind.Spotlight
            ? Bounds(unit)
            : Inflate(Bounds(unit), ShadowReach * unit);

    /// <summary>
    /// 点中它没有：空心矩形 / 椭圆和聚光灯只认边线（里面点不中，免得挡住下面的标注、聚光灯里还要接着画），
    /// 线类认线（箭头连箭头），实心形状、文字、序号、马赛克认整块。tolerance 是 DIP。
    /// </summary>
    public bool Contains(PointD point, double unit, double tolerance = 4)
    {
        var width = Style.LineWidth * unit;
        var slack = tolerance * unit;
        switch (Kind)
        {
            case AnnotationKind.Rectangle when Filled:
                return Inflate(Rect, width / 2 + slack).Contains(point);
            case AnnotationKind.Rectangle:
                return OnEdge(point, Rect, width / 2 + slack);
            case AnnotationKind.Spotlight:
                return OnEdge(point, Rect, slack + 2 * unit);
            case AnnotationKind.Ellipse:
            {
                var rx = Math.Max(Rect.Width / 2, 0.5);
                var ry = Math.Max(Rect.Height / 2, 0.5);
                var k = Math.Sqrt(Square((point.X - Rect.MidX) / rx) + Square((point.Y - Rect.MidY) / ry));
                // 到椭圆线的距离按短半轴近似（长轴两端偏宽容）
                var distance = (k - 1) * Math.Min(rx, ry);
                return Filled ? distance <= width / 2 + slack : Math.Abs(distance) <= width / 2 + slack;
            }
            case AnnotationKind.Arrow or AnnotationKind.Line:
            {
                // 先按外框排除：每次鼠标移动都要问一遍所有标注，弯的逐段量距离很慢
                if (!Inflate(Bounds(unit), slack).Contains(point))
                {
                    return false;
                }

                var line = CurvePoints(From, To, Bend);
                for (var index = 1; index < line.Count; index++)
                {
                    if (RegionMath.DistanceToSegment(point, line[index - 1], line[index]) <= width / 2 + slack)
                    {
                        return true;
                    }
                }

                return Kind == AnnotationKind.Arrow && ArrowOutline(From, To, width, Bend) is { } outline &&
                       PolygonContains(outline, point);
            }
            case AnnotationKind.Highlighter:
                return RegionMath.DistanceToSegment(point, From, To) <= Style.HighlighterHeight * unit / 2 + slack;
            case AnnotationKind.Pen:
            {
                var reach = width / 2 + slack;
                if (Points.Count == 0)
                {
                    return false;
                }

                if (Distance(point, Points[0]) <= reach)
                {
                    return true;
                }

                for (var index = 1; index < Points.Count; index++)
                {
                    if (RegionMath.DistanceToSegment(point, Points[index - 1], Points[index]) <= reach)
                    {
                        return true;
                    }
                }

                return false;
            }
            case AnnotationKind.Counter:
                return Distance(point, From) <= (Style.CounterDiameter / 2 + tolerance) * unit;
            default:
                return Inflate(Bounds(unit), slack).Contains(point);
        }
    }

    /// <summary>小到看不出来的（误点）不留。</summary>
    public bool IsMeaningful(double unit) => Kind switch
    {
        AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Mosaic or AnnotationKind.Spotlight
            => Rect.Width >= 3 * unit && Rect.Height >= 3 * unit,
        AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter => Distance(From, To) >= 6 * unit,
        AnnotationKind.Pen => Points.Count >= 2 &&
                              Math.Max(Bounds(unit).Width, Bounds(unit).Height) - Style.LineWidth * unit >= 3 * unit,
        AnnotationKind.Text => !string.IsNullOrWhiteSpace(Text),
        _ => true,
    };

    public Annotation Offset(double dx, double dy) => this with
    {
        Rect = Rect.Offset(dx, dy),
        From = Shift(From, dx, dy),
        To = Shift(To, dx, dy),
        Points = Points.Select(point => Shift(point, dx, dy)).ToArray(),
    };

    /// <summary>复制一份（新 Id）。Ctrl+D 往右下偏 12 DIP，Alt 拖动传 0。序号的编号不变，要不要换由调用方决定。</summary>
    public Annotation Duplicated(double dx, double dy) => Offset(dx, dy) with { Id = Guid.NewGuid() };

    /// <summary>
    /// 选中时的调整手柄：矩形类四角，线类两端；箭头、直线还有弧线中点（直的在弦中点），弦短于 32 DIP 的不给；
    /// 荧光笔不弯；文字、序号、画笔只能拖动（空）。
    /// </summary>
    public IReadOnlyList<(AnnotationHandle Handle, PointD Point)> Handles(double unit)
    {
        if (IsBox)
        {
            return new[]
            {
                (AnnotationHandle.TopLeft, new PointD(Rect.X, Rect.Y)),
                (AnnotationHandle.TopRight, new PointD(Rect.Right, Rect.Y)),
                (AnnotationHandle.BottomLeft, new PointD(Rect.X, Rect.Bottom)),
                (AnnotationHandle.BottomRight, new PointD(Rect.Right, Rect.Bottom)),
            };
        }

        if (Kind is AnnotationKind.Arrow or AnnotationKind.Line)
        {
            var list = new List<(AnnotationHandle, PointD)> { (AnnotationHandle.Start, From), (AnnotationHandle.End, To) };
            if (Distance(From, To) >= 32 * unit)
            {
                list.Add((AnnotationHandle.Bend, CurveMidpoint(From, To, Bend)));
            }

            return list;
        }

        return Kind == AnnotationKind.Highlighter
            ? new[] { (AnnotationHandle.Start, From), (AnnotationHandle.End, To) }
            : Array.Empty<(AnnotationHandle, PointD)>();
    }

    /// <summary>
    /// 拖手柄改大小：矩形类对角不动（拖过头会翻过去）、Shift 正方形；线类另一端不动、Shift 吸 45°（弯度跟着弦等比变）；
    /// 弯曲手柄见 CurveBend（Shift 对称的弧）。不认的手柄原样返回。
    /// </summary>
    public Annotation Resized(AnnotationHandle handle, PointD point, bool constrained, double unit)
    {
        if (IsBox)
        {
            PointD? fixedCorner = handle switch
            {
                AnnotationHandle.TopLeft => new PointD(Rect.Right, Rect.Bottom),
                AnnotationHandle.TopRight => new PointD(Rect.X, Rect.Bottom),
                AnnotationHandle.BottomLeft => new PointD(Rect.Right, Rect.Y),
                AnnotationHandle.BottomRight => new PointD(Rect.X, Rect.Y),
                _ => null,
            };
            return fixedCorner is { } corner ? this with { Rect = DrawnRect(corner, point, constrained) } : this;
        }

        if (!IsSegment)
        {
            return this;
        }

        return handle switch
        {
            AnnotationHandle.Bend when Kind != AnnotationKind.Highlighter
                => this with { Bend = CurveBend(From, To, point, constrained, unit) },
            AnnotationHandle.Start => this with { From = constrained ? Snapped(To, point) : point },
            AnnotationHandle.End => this with { To = constrained ? Snapped(From, point) : point },
            _ => this,
        };
    }

    /// <summary>拉直（双击弯曲手柄）：两端不动；别的工具原样返回。</summary>
    public Annotation Straightened
        => Kind is AnnotationKind.Arrow or AnnotationKind.Line ? this with { Bend = VectorD.Zero } : this;

    /// <summary>
    /// 拖动画出的标注（文字、序号是单击放置，返回 null；画笔先给起止两点，由调用方累点）。
    /// constrained（按住 Shift）：矩形类变正方形 / 正圆，线类吸附到 45° 的倍数。
    /// </summary>
    public static Annotation? Drawn(
        AnnotationKind kind, PointD start, PointD end, bool constrained, AnnotationStyle style)
    {
        var annotation = new Annotation { Kind = kind, Style = style };
        return kind switch
        {
            AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Mosaic or AnnotationKind.Spotlight
                => annotation with { Rect = DrawnRect(start, end, constrained) },
            AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter
                => annotation with { From = start, To = constrained ? Snapped(start, end) : end },
            AnnotationKind.Pen => annotation with { Points = new[] { start, end } },
            _ => null,
        };
    }

    /// <summary>下一个序号：现有最大的 + 1。</summary>
    public static int NextCounter(IEnumerable<Annotation> annotations)
        => annotations.Where(annotation => annotation.Kind == AnnotationKind.Counter)
            .Select(annotation => annotation.Number).DefaultIfEmpty(0).Max() + 1;

    /// <summary>画的层次：马赛克 → 聚光灯 → 其余 → 序号。</summary>
    public int Layer => Kind switch
    {
        AnnotationKind.Mosaic => 0,
        AnnotationKind.Spotlight => 1,
        AnnotationKind.Counter => 3,
        _ => 2,
    };

    /// <summary>点中的最上面那条：按画的层次倒着找（序号压在后画的标注上面，马赛克、聚光灯垫在最下面），同一层后画的在上。</summary>
    public static Annotation? Topmost(IReadOnlyList<Annotation> annotations, PointD point, double unit)
    {
        Annotation? best = null;
        for (var index = annotations.Count - 1; index >= 0; index--)
        {
            var annotation = annotations[index];
            if ((best is null || annotation.Layer > best.Layer) && annotation.Contains(point, unit))
            {
                best = annotation;
            }
        }

        return best;
    }

    // MARK: 箭头

    /// <summary>
    /// 直箭头的锥形实心多边形（7 个点）：杆从尾部半宽 0.15 × 线宽渐粗到颈 0.6 × 线宽；箭头长 4 × 线宽、半角 28°
    /// （比这还短的箭头只剩箭头）。零长度返回 null。
    /// </summary>
    public static PointD[]? ArrowPolygon(PointD from, PointD to, double width)
    {
        var length = Distance(from, to);
        if (length <= 0)
        {
            return null;
        }

        var head = Math.Min(length, width * 4);
        var wing = ArrowWing(from, to, width);
        var ux = (to.X - from.X) / length;
        var uy = (to.Y - from.Y) / length;
        var baseX = to.X - ux * head;
        var baseY = to.Y - uy * head;
        // 沿法向偏出 side（正数在箭头方向的左边，原点左上时看着是右边）
        PointD Beside(double x, double y, double side) => new(x - uy * side, y + ux * side);
        var tail = width * 0.15;
        var neck = Math.Min(width * 0.6, wing);
        return new[]
        {
            Beside(from.X, from.Y, tail), Beside(baseX, baseY, neck), Beside(baseX, baseY, wing), to,
            Beside(baseX, baseY, -wing), Beside(baseX, baseY, -neck), Beside(from.X, from.Y, -tail),
        };
    }

    /// <summary>
    /// 点中用的箭头轮廓：直的是 ArrowPolygon；弯的取弧线上离尖端一个头长的点当底边中点，按它到尖端的走向摆三角。
    /// ponytail: 弯箭头画出来的轮廓（底边垂直于杆的走向）第 5b 批照 mac curvedArrowPath 移植，点中暂用这个三角，
    /// 差的只是两翼边缘一两个像素。
    /// </summary>
    public static PointD[]? ArrowOutline(PointD from, PointD to, double width, VectorD bend)
    {
        if (bend == VectorD.Zero)
        {
            return ArrowPolygon(from, to, width);
        }

        var curve = CurvePoints(from, to, bend);
        var neck = curve[0];
        for (var index = curve.Count - 1; index >= 0; index--)
        {
            neck = curve[index];
            if (Distance(neck, to) >= width * 4)
            {
                break;
            }
        }

        if (ArrowPolygon(neck, to, width) is not { } head)
        {
            return null;
        }

        return new[] { head[2], head[3], head[4] };
    }

    /// <summary>箭头底边的半宽：头长 × tan 28°（弯的头长按 4 × 线宽算，外框宁大勿小）。</summary>
    public static double ArrowWing(PointD from, PointD to, double width, VectorD bend = default)
    {
        var head = bend == VectorD.Zero ? Math.Min(Distance(from, to), width * 4) : width * 4;
        return head * Math.Tan(28 * Math.PI / 180);
    }

    // MARK: 弯曲（箭头、直线）

    /// <summary>弧线中点（弯曲手柄）：弦中点 + bend.X · d + bend.Y · d⊥（d = to − from，d⊥ = (−d.Y, d.X)）。</summary>
    public static PointD CurveMidpoint(PointD from, PointD to, VectorD bend)
    {
        var dx = to.X - from.X;
        var dy = to.Y - from.Y;
        return new PointD(
            (from.X + to.X) / 2 + bend.X * dx - bend.Y * dy,
            (from.Y + to.Y) / 2 + bend.X * dy + bend.Y * dx);
    }

    /// <summary>二次贝塞尔的控制点：t = 0.5 处要落在弧线中点上，控制点 = 2 · 中点 − 弦中点。</summary>
    public static PointD CurveControl(PointD from, PointD to, VectorD bend)
    {
        var mid = CurveMidpoint(from, to, bend);
        return new PointD(2 * mid.X - (from.X + to.X) / 2, 2 * mid.Y - (from.Y + to.Y) / 2);
    }

    /// <summary>
    /// 弯曲手柄拖到 point 时的弯度（弧线中点就在 point 上）：离弦不到 StraightSnap 拉直；constrained（Shift）只留垂直弦的
    /// 那份，弯成左右对称的弧。沿弦的那份夹在 ±MaxAlong。弦长为 0 时是直的。
    /// </summary>
    public static VectorD CurveBend(PointD from, PointD to, PointD point, bool constrained, double unit = 1)
    {
        var dx = to.X - from.X;
        var dy = to.Y - from.Y;
        var lengthSquared = dx * dx + dy * dy;
        var vx = point.X - (from.X + to.X) / 2;
        var vy = point.Y - (from.Y + to.Y) / 2;
        var side = vy * dx - vx * dy; // v · d⊥ = 离弦的距离 × 弦长
        if (lengthSquared <= 0 || Math.Abs(side) < StraightSnap * unit * Math.Sqrt(lengthSquared))
        {
            return VectorD.Zero;
        }

        var along = constrained ? 0 : (vx * dx + vy * dy) / lengthSquared;
        return new VectorD(Math.Clamp(along, -MaxAlong, MaxAlong), side / lengthSquared);
    }

    /// <summary>箭头、直线的骨架折线：直的是两端，弯的是弧线上的采样点（按控制折线长每 3 个单位一段、16–400 段）。</summary>
    public static IReadOnlyList<PointD> CurvePoints(PointD from, PointD to, VectorD bend)
    {
        if (bend == VectorD.Zero)
        {
            return new[] { from, to };
        }

        var control = CurveControl(from, to, bend);
        var length = Distance(control, from) + Distance(to, control);
        var segments = Math.Min(400, Math.Max(16, (int)(length / 3)));
        var points = new PointD[segments + 1];
        for (var step = 0; step <= segments; step++)
        {
            points[step] = Quad(from, control, to, (double)step / segments);
        }

        return points;
    }

    /// <summary>弧线的外框：两端 + 每个轴上的极值点。直的就是两端围成的框。</summary>
    public static RectD CurveBox(PointD from, PointD to, VectorD bend)
    {
        var box = Box(from, to);
        if (bend == VectorD.Zero)
        {
            return box;
        }

        var control = CurveControl(from, to, bend);
        foreach (var t in new[] { Extremum(from.X, control.X, to.X), Extremum(from.Y, control.Y, to.Y) })
        {
            if (t is { } value)
            {
                var turn = Quad(from, control, to, value);
                box = RectD.FromLtrb(
                    Math.Min(box.X, turn.X), Math.Min(box.Y, turn.Y),
                    Math.Max(box.Right, turn.X), Math.Max(box.Bottom, turn.Y));
            }
        }

        return box;
    }

    public static PointD Quad(PointD start, PointD control, PointD end, double t)
    {
        var u = 1 - t;
        return new PointD(
            u * u * start.X + 2 * u * t * control.X + t * t * end.X,
            u * u * start.Y + 2 * u * t * control.Y + t * t * end.Y);
    }

    // MARK: 小工具

    /// <summary>end 绕 start 吸到 45° 的倍数，长度不变。</summary>
    public static PointD Snapped(PointD start, PointD end)
    {
        var angle = Math.Round(Math.Atan2(end.Y - start.Y, end.X - start.X) / (Math.PI / 4)) * (Math.PI / 4);
        var length = Distance(start, end);
        return new PointD(start.X + Math.Cos(angle) * length, start.Y + Math.Sin(angle) * length);
    }

    /// <summary>从 start 拖到 end 围成的框；constrained 时取长的那边成正方形，方向跟着拖的方向。</summary>
    public static RectD DrawnRect(PointD start, PointD end, bool constrained)
    {
        if (constrained)
        {
            var dx = end.X - start.X;
            var dy = end.Y - start.Y;
            var side = Math.Max(Math.Abs(dx), Math.Abs(dy));
            end = new PointD(start.X + (dx < 0 ? -side : side), start.Y + (dy < 0 ? -side : side));
        }

        return Box(start, end);
    }

    public static bool PolygonContains(IReadOnlyList<PointD> polygon, PointD point)
    {
        var inside = false;
        for (int i = 0, j = polygon.Count - 1; i < polygon.Count; j = i++)
        {
            var a = polygon[i];
            var b = polygon[j];
            if ((a.Y > point.Y) != (b.Y > point.Y) &&
                point.X < (b.X - a.X) * (point.Y - a.Y) / (b.Y - a.Y) + a.X)
            {
                inside = !inside;
            }
        }

        return inside;
    }

    /// <summary>这一轴上 (1−t)²a + 2t(1−t)b + t²c 的极值点（在 0–1 之间才算）。</summary>
    private static double? Extremum(double a, double b, double c)
    {
        var denominator = a - 2 * b + c;
        if (denominator == 0)
        {
            return null;
        }

        var t = (a - b) / denominator;
        return t > 0 && t < 1 ? t : null;
    }

    private static RectD Box(PointD a, PointD b)
        => RectD.FromLtrb(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    private static RectD Inflate(RectD rect, double by)
        => new(rect.X - by, rect.Y - by, rect.Width + by * 2, rect.Height + by * 2);

    /// <summary>落在边线 ± reach 里：外扩 reach 的框里、内缩 reach 的框外（内缩没了就是整块）。</summary>
    private static bool OnEdge(PointD point, RectD rect, double reach)
    {
        if (!Inflate(rect, reach).Contains(point))
        {
            return false;
        }

        var inner = new RectD(rect.X + reach, rect.Y + reach, rect.Width - reach * 2, rect.Height - reach * 2);
        return inner.Width <= 0 || inner.Height <= 0 ||
               !(point.X > inner.X && point.X < inner.Right && point.Y > inner.Y && point.Y < inner.Bottom);
    }

    private static PointD Shift(PointD point, double dx, double dy) => new(point.X + dx, point.Y + dy);

    private static double Distance(PointD a, PointD b) => Math.Sqrt(Square(a.X - b.X) + Square(a.Y - b.Y));

    private static double Square(double value) => value * value;
}
