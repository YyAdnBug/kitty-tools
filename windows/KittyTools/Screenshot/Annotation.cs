// 截图标注的画法（Win2D，照 mac Annotation.swift 的 drawAll，PLAN-v9-annotate §3）。模型和几何在 Core 的
// AnnotationGeometry.cs（KittyTools.Core.Annotation）。屏幕上（遮罩把画完的标注缓存成一张位图）和导出都只走 Draw，所见即所得。
// 坐标一律是遮罩窗口里的物理像素（相对这块屏）：target = (p − origin) × unit；线宽、字号这些按 DIP 乘 strokeScale。
// 屏幕上 unit = 1 / 缩放、strokeScale = 1（画布按 DIP）；导出 unit = 1、strokeScale = 缩放（位图按像素）。
// 顺序固定：荧光笔垫底（正片叠底要叠在冻结帧上）→ 马赛克 → 聚光灯（合成一层）→ 其余按列表顺序 → 序号永远最上。
// 除马赛克、聚光灯、荧光笔外都带 black 0.28 的阴影（白色标注在白底上也看得见）。
// 文字（PLAN-v9-annotate §6）：Segoe UI Variable Text Semibold（中文由系统回退到微软雅黑，D2），三档 14 / 20 / 28；
// 无底 = 字带阴影，描边 = 带阴影的外描边 + 不带阴影的字，底色 = 带阴影的圆角色块 + 压在上面的字。输入框也照这套（DrawTextBacking）。
using System.Numerics;
using KittyTools.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.UI;

namespace KittyTools;

internal static class AnnotationRenderer
{
    /// <summary>文字标注的字体（输入框用同一个，所见即所得）。</summary>
    public const string TextFontFamily = "Segoe UI Variable Text";

    /// <summary>阴影的模糊（标准差，DIP）：mac 是 CG 的 blur 3，约等于标准差 1.5。</summary>
    private const float ShadowBlur = 1.5f;

    private static readonly Color ShadowColor = Color.FromArgb(71, 0, 0, 0);

    private static readonly CanvasStrokeStyle RoundStroke = new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        DashCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
    };

    public static Color ColorOf(int palette) => FromArgb(AnnotationPalette.ArgbOf(palette));

    /// <summary>压在这个颜色上的字（底色文字、序号）：黄、白上黑字，其余白字。</summary>
    public static Color InkOf(int palette) => FromArgb(AnnotationPalette.InkOf(palette));

    private static Color FromArgb(uint argb)
        => Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    /// <summary>
    /// 文字框的大小（DIP），和 Draw 画字用同一个排版；空串、末尾换行也留一行高（输入框里光标要有地方，mac textFrame）。
    /// linePitch 只给正在输入的字（见 DrawTextBacking）。
    /// </summary>
    public static (double Width, double Height) MeasureText(string text, AnnotationStyle style, double? linePitch = null)
    {
        var measured = text.Length == 0 || text.EndsWith('\n') ? text + " " : text;
        using var layout = TextLayout(CanvasDevice.GetSharedDevice(), measured, style, 1, linePitch);
        var bounds = layout.LayoutBounds;
        return (Math.Ceiling(bounds.Width), Math.Ceiling(bounds.Height));
    }

    /// <summary>文字标注补上量出来的框（像素）：收下文字时、改了字号时、从截图历史读出来时。</summary>
    public static Annotation Measured(Annotation annotation, double scale, double? linePitch = null)
    {
        if (annotation.Kind != AnnotationKind.Text)
        {
            return annotation;
        }

        var (width, height) = MeasureText(annotation.Text, annotation.Style, linePitch);
        return annotation with { Rect = annotation.Rect with { Width = width * scale, Height = height * scale } };
    }

    /// <summary>
    /// 画一组标注。frozen 是这块屏的冻结帧（荧光笔正片叠底要垫它），selection 是选区（像素）：聚光灯只压暗选区里面
    /// （屏幕上选区外已经有遮罩的暗色；导出的位图本来就只有选区那么大）。
    /// frozenAt：frozen 左上角在像素坐标里的位置（长图标注一条条画，frozen 是那一条；PLAN-v9 S12），平常是 (0, 0)。
    /// </summary>
    public static void Draw(
        CanvasDrawingSession ds,
        IReadOnlyList<Annotation> annotations,
        FrozenScreen screen,
        CanvasBitmap? frozen,
        PointD origin,
        double unit,
        double strokeScale,
        RectD selection,
        PointD frozenAt = default)
    {
        var map = new Mapping(origin, unit, strokeScale);
        foreach (var annotation in annotations.Where(annotation => annotation.Kind == AnnotationKind.Highlighter))
        {
            DrawHighlighter(ds, annotation, frozen, map, frozenAt);
        }

        foreach (var annotation in annotations.Where(annotation => annotation.Layer == 0))
        {
            DrawMosaic(ds, annotation, screen, map);
        }

        DrawSpotlights(ds, annotations.Where(annotation => annotation.Layer == 1).ToList(), selection, map);
        foreach (var layer in new[] { 2, 3 })
        {
            foreach (var annotation in annotations.Where(annotation => annotation.Layer == layer))
            {
                DrawInk(ds, annotation, map);
            }
        }
    }

    /// <summary>像素坐标 → 画布坐标、DIP 尺寸 → 画布尺寸。</summary>
    private readonly record struct Mapping(PointD Origin, double Unit, double StrokeScale)
    {
        public Vector2 Point(PointD point)
            => new((float)((point.X - Origin.X) * Unit), (float)((point.Y - Origin.Y) * Unit));

        public Windows.Foundation.Rect Rect(RectD rect)
            => new((rect.X - Origin.X) * Unit, (rect.Y - Origin.Y) * Unit, Math.Max(0, rect.Width * Unit), Math.Max(0, rect.Height * Unit));

        public float Size(double dip) => (float)(dip * StrokeScale);

        /// <summary>每 DIP 几个冻结帧像素（马赛克的格子按 DIP 定）。</summary>
        public double PixelsPerDip => StrokeScale / Unit;
    }

    /// <summary>除荧光笔、马赛克、聚光灯以外的：带阴影的线条 / 色块 / 字（实心矩形、椭圆的 0.28 底不带阴影，先铺）。</summary>
    private static void DrawInk(CanvasDrawingSession ds, Annotation annotation, Mapping map)
    {
        if (annotation.Kind == AnnotationKind.Text)
        {
            DrawText(ds, annotation, map, glyphs: true);
            return;
        }

        var color = ColorOf(annotation.Style.Color);
        var width = map.Size(annotation.Style.LineWidth);
        if (annotation.Kind is AnnotationKind.Rectangle or AnnotationKind.Ellipse && annotation.Style.Option == 1 &&
            BoxGeometry(ds, annotation, map) is { } fill)
        {
            using (fill)
            {
                ds.FillGeometry(fill, Color.FromArgb(71, color.R, color.G, color.B));
            }
        }

        WithShadow(ds, map, inner =>
        {
            switch (annotation.Kind)
            {
                case AnnotationKind.Rectangle or AnnotationKind.Ellipse:
                    if (BoxGeometry(inner, annotation, map) is { } box)
                    {
                        using (box)
                        {
                            inner.DrawGeometry(box, color, width);
                        }
                    }

                    break;
                case AnnotationKind.Arrow:
                    if (Annotation.ArrowOutline(annotation.From, annotation.To, annotation.Style.LineWidth * map.PixelsPerDip, annotation.Bend) is { } outline)
                    {
                        using var arrow = Polygon(inner, outline, map);
                        inner.FillGeometry(arrow, color);
                    }

                    break;
                case AnnotationKind.Line when annotation.Bend == VectorD.Zero:
                    inner.DrawLine(map.Point(annotation.From), map.Point(annotation.To), color, width, RoundStroke);
                    break;
                case AnnotationKind.Line:
                {
                    using var builder = new CanvasPathBuilder(inner);
                    builder.BeginFigure(map.Point(annotation.From));
                    builder.AddQuadraticBezier(
                        map.Point(Annotation.CurveControl(annotation.From, annotation.To, annotation.Bend)), map.Point(annotation.To));
                    builder.EndFigure(CanvasFigureLoop.Open);
                    using var curve = CanvasGeometry.CreatePath(builder);
                    inner.DrawGeometry(curve, color, width, RoundStroke);
                    break;
                }
                case AnnotationKind.Pen:
                    if (PenGeometry(inner, annotation.Points, map) is { } pen)
                    {
                        using (pen)
                        {
                            inner.DrawGeometry(pen, color, width, RoundStroke);
                        }
                    }

                    break;
                case AnnotationKind.Counter:
                    DrawCounterDisc(inner, annotation, color, map);
                    break;
            }
        });
        if (annotation.Kind == AnnotationKind.Counter)
        {
            // 白描边和数字不带阴影
            var center = map.Point(annotation.From);
            var radius = map.Size(annotation.Style.CounterDiameter / 2);
            ds.DrawCircle(center, radius, Colors.White, map.Size(1.5));
            DrawNumber(ds, annotation, center, radius * 2);
        }
    }

    /// <summary>先把 body 画进一张命令列表，垫一层 ShadowEffect，再把本体叠上去（withBody = false 只画阴影）。</summary>
    private static void WithShadow(CanvasDrawingSession ds, Mapping map, Action<CanvasDrawingSession> body, bool withBody = true)
    {
        using var list = new CanvasCommandList(ds);
        using (var inner = list.CreateDrawingSession())
        {
            body(inner);
        }

        using var shadow = new ShadowEffect { Source = list, BlurAmount = map.Size(ShadowBlur), ShadowColor = ShadowColor };
        ds.DrawImage(shadow);
        if (withBody)
        {
            ds.DrawImage(list);
        }
    }

    /// <summary>
    /// 正在输入的文字垫在输入框下面的那层（T7，mac 的输入框也是这样）：无底只画字的阴影，描边画带阴影的外描边，底色画带阴影的色块；
    /// 字本身由输入框画。坐标同 Draw。linePitch 是输入框实际的行距（DIP）：TextBox 的行距取整到整像素（14 / 20 / 28 号是
    /// 18 / 26 / 36），DirectWrite 自己排是 18.6 / 26.6 / 37.2，多行时每行差出零点几到一个多像素，外描边就和字错开了；
    /// 垫的这层按输入框的行距排，和它上面的字对齐。
    /// ponytail: 收下后按 DirectWrite 自己的行距画，第二行起每行往下挪不到 1 px（mac 输入框和画出来是同一套排版，没有这一下）。
    /// 要完全一致得让 TextBox 用指定行距（换 RichEditBox 设段落行距 Exactly），再看值不值。
    /// </summary>
    public static void DrawTextBacking(
        CanvasDrawingSession ds, Annotation annotation, PointD origin, double unit, double strokeScale, double? linePitch)
        => DrawText(ds, annotation, new Mapping(origin, unit, strokeScale), glyphs: false, linePitch);

    /// <summary>文字的三种样式（mac Annotation.draw 的 .text）；glyphs = false 时不画字本身（输入框在上面画）。</summary>
    private static void DrawText(CanvasDrawingSession ds, Annotation annotation, Mapping map, bool glyphs, double? linePitch = null)
    {
        var style = annotation.Style;
        var color = ColorOf(style.Color);
        var origin = map.Point(new PointD(annotation.Rect.X, annotation.Rect.Y));
        using var layout = TextLayout(ds, annotation.Text, style, map.StrokeScale, linePitch);
        switch (style.Option)
        {
            case 1:
            {
                // 描边：先画带阴影的外描边（字号的 1/7，一半压在字里，随后填上的字把它盖住；白字用黑描边），再不带阴影地把字填上
                using var outline = CanvasGeometry.CreateText(layout);
                var stroke = style.Color == AnnotationPalette.White ? Colors.Black : Colors.White;
                WithShadow(ds, map, inner => inner.DrawGeometry(outline, origin, stroke, map.Size(style.FontSize / 7), RoundStroke));
                if (glyphs)
                {
                    ds.FillGeometry(outline, origin, color);
                }

                break;
            }
            case 2:
            {
                // 底色：带阴影的圆角 6 色块（文字框左右各留 6、上下各留 2）+ 压在上面的字（黄 / 白底黑字）
                var frame = map.Rect(annotation.Rect);
                var padX = map.Size(Annotation.PlatePaddingX);
                var padY = map.Size(Annotation.PlatePaddingY);
                var plate = new Windows.Foundation.Rect(frame.X - padX, frame.Y - padY, frame.Width + padX * 2, frame.Height + padY * 2);
                var radius = map.Size(6);
                WithShadow(ds, map, inner => inner.FillRoundedRectangle(plate, radius, radius, color));
                if (glyphs)
                {
                    ds.DrawTextLayout(layout, origin, InkOf(style.Color));
                }

                break;
            }
            default:
                WithShadow(ds, map, inner => inner.DrawTextLayout(layout, origin, color), withBody: glyphs);
                break;
        }
    }

    /// <summary>
    /// 文字的排版：不折行，字号按档乘 scale（屏幕上 1，导出是屏幕缩放）。给了 linePitch 就每行一样高（基线在 Segoe UI Variable
    /// 的上伸部 2210 / 2048 em，第一行和不给时一样）。
    /// </summary>
    private static CanvasTextLayout TextLayout(
        ICanvasResourceCreator creator, string text, AnnotationStyle style, double scale, double? linePitch = null)
    {
        using var format = new CanvasTextFormat
        {
            FontFamily = TextFontFamily,
            FontSize = (float)(style.FontSize * scale),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            WordWrapping = CanvasWordWrapping.NoWrap,
        };
        if (linePitch is { } pitch)
        {
            format.LineSpacingMode = CanvasLineSpacingMode.Uniform;
            format.LineSpacing = (float)(pitch * scale);
            format.LineSpacingBaseline = (float)(style.FontSize * 2210 / 2048 * scale);
        }

        // 给有限的框（同 DrawNumber）：float.MaxValue 时量出来的框是空的
        return new CanvasTextLayout(creator, text, format, 100_000, 100_000);
    }

    /// <summary>矩形（圆角 3）/ 椭圆；别的工具 null。</summary>
    private static CanvasGeometry? BoxGeometry(ICanvasResourceCreator creator, Annotation annotation, Mapping map)
    {
        var rect = map.Rect(annotation.Rect);
        if (annotation.Kind == AnnotationKind.Ellipse)
        {
            return CanvasGeometry.CreateEllipse(
                creator, (float)(rect.X + rect.Width / 2), (float)(rect.Y + rect.Height / 2),
                (float)rect.Width / 2, (float)rect.Height / 2);
        }

        if (annotation.Kind != AnnotationKind.Rectangle)
        {
            return null;
        }

        var radius = (float)Math.Min(map.Size(3), Math.Min(rect.Width, rect.Height) / 2);
        return CanvasGeometry.CreateRoundedRectangle(creator, rect, radius, radius);
    }

    /// <summary>多边形（非零环绕填充：弯箭头的轮廓自交处也填满，同 mac 的 fillPath）。</summary>
    private static CanvasGeometry Polygon(ICanvasResourceCreator creator, IReadOnlyList<PointD> points, Mapping map)
    {
        using var builder = new CanvasPathBuilder(creator);
        builder.SetFilledRegionDetermination(CanvasFilledRegionDetermination.Winding);
        builder.BeginFigure(map.Point(points[0]));
        for (var index = 1; index < points.Count; index++)
        {
            builder.AddLine(map.Point(points[index]));
        }

        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    /// <summary>画笔：相邻点的中点之间用二次曲线连（控制点是原来的点），笔迹不起棱角（mac penPath）。</summary>
    private static CanvasGeometry? PenGeometry(ICanvasResourceCreator creator, IReadOnlyList<PointD> points, Mapping map)
    {
        if (points.Count == 0)
        {
            return null;
        }

        using var builder = new CanvasPathBuilder(creator);
        builder.BeginFigure(map.Point(points[0]));
        for (var index = 1; index + 1 < points.Count; index++)
        {
            var point = points[index];
            var next = points[index + 1];
            builder.AddQuadraticBezier(map.Point(point), map.Point(new PointD((point.X + next.X) / 2, (point.Y + next.Y) / 2)));
        }

        builder.AddLine(map.Point(points[^1])); // 只有一个点时是零长度线段，圆头画成一个点
        builder.EndFigure(CanvasFigureLoop.Open);
        return CanvasGeometry.CreatePath(builder);
    }

    /// <summary>荧光笔：笔迹范围里冻结帧 × 颜色 0.45（正片叠底：底下的字不被盖浅），没有阴影。</summary>
    private static void DrawHighlighter(CanvasDrawingSession ds, Annotation annotation, CanvasBitmap? frozen, Mapping map, PointD frozenAt)
    {
        if (frozen is null)
        {
            return;
        }

        using var builder = new CanvasPathBuilder(ds);
        builder.BeginFigure(map.Point(annotation.From));
        builder.AddLine(map.Point(annotation.To));
        builder.EndFigure(CanvasFigureLoop.Open);
        using var segment = CanvasGeometry.CreatePath(builder);
        using var band = segment.Stroke(map.Size(annotation.Style.HighlighterHeight));
        var color = ColorOf(annotation.Style.Color);
        using var backdrop = new Transform2DEffect
        {
            Source = frozen,
            TransformMatrix = Matrix3x2.CreateTranslation((float)(frozenAt.X - map.Origin.X), (float)(frozenAt.Y - map.Origin.Y)) *
                              Matrix3x2.CreateScale((float)map.Unit),
        };
        using var ink = new ColorSourceEffect { Color = Color.FromArgb(115, color.R, color.G, color.B) };
        using var blend = new BlendEffect { Background = backdrop, Foreground = ink, Mode = BlendEffectMode.Multiply };
        using (ds.CreateLayer(1, band))
        {
            ds.DrawImage(blend);
        }
    }

    /// <summary>
    /// 马赛克：冻结帧这一块按格子取平均，再放大回去。格子边长按粗细档 6 / 10 / 16 DIP；像素 = 不插值放大，
    /// 模糊（选项 1）= 格子放大到 1.5 倍、再平滑插值放大（信息已经在取平均时丢掉，还原不了）。
    /// </summary>
    private static void DrawMosaic(CanvasDrawingSession ds, Annotation annotation, FrozenScreen screen, Mapping map)
    {
        var blurred = annotation.Style.Option == 1;
        var cell = Math.Max(1, (int)Math.Round(annotation.Style.MosaicBlock * (blurred ? 1.5 : 1) * map.PixelsPerDip));
        var left = (int)Math.Clamp(Math.Floor(annotation.Rect.X), 0, screen.Width);
        var top = (int)Math.Clamp(Math.Floor(annotation.Rect.Y), 0, screen.Height);
        var right = (int)Math.Clamp(Math.Ceiling(annotation.Rect.Right), 0, screen.Width);
        var bottom = (int)Math.Clamp(Math.Ceiling(annotation.Rect.Bottom), 0, screen.Height);
        var columns = (right - left + cell - 1) / cell;
        var rows = (bottom - top + cell - 1) / cell;
        if (columns <= 0 || rows <= 0)
        {
            return;
        }

        var colors = new Color[columns * rows];
        for (var row = 0; row < rows; row++)
        {
            for (var column = 0; column < columns; column++)
            {
                var x = left + column * cell;
                var y = top + row * cell;
                var (r, g, b) = Average(screen, x, y, Math.Min(x + cell, right), Math.Min(y + cell, bottom));
                colors[row * columns + column] = Color.FromArgb(255, r, g, b);
            }
        }

        using var blocks = CanvasBitmap.CreateFromColors(ds, colors, columns, rows);
        var destination = map.Rect(new RectD(left, top, columns * cell, rows * cell));
        using (ds.CreateLayer(1, map.Rect(annotation.Rect)))
        {
            ds.DrawImage(
                blocks, destination, new Windows.Foundation.Rect(0, 0, columns, rows), 1,
                blurred ? CanvasImageInterpolation.HighQualityCubic : CanvasImageInterpolation.NearestNeighbor);
        }
    }

    /// <summary>
    /// 聚光灯合成一层：选区减掉所有聚光灯的圆角 8 洞（先合并，重叠的洞不会又被压暗），压暗程度取最后一个聚光灯的档。
    /// </summary>
    private static void DrawSpotlights(CanvasDrawingSession ds, IReadOnlyList<Annotation> spotlights, RectD selection, Mapping map)
    {
        if (spotlights.Count == 0 || selection.Width <= 0 || selection.Height <= 0)
        {
            return;
        }

        CanvasGeometry? holes = null;
        foreach (var spotlight in spotlights)
        {
            var rect = map.Rect(spotlight.Rect);
            var radius = (float)Math.Min(map.Size(8), Math.Min(rect.Width, rect.Height) / 2);
            var hole = CanvasGeometry.CreateRoundedRectangle(ds, rect, radius, radius);
            if (holes is null)
            {
                holes = hole;
            }
            else
            {
                var merged = holes.CombineWith(hole, Matrix3x2.Identity, CanvasGeometryCombine.Union);
                holes.Dispose();
                hole.Dispose();
                holes = merged;
            }
        }

        using var area = CanvasGeometry.CreateRectangle(ds, map.Rect(selection));
        using var dim = area.CombineWith(holes!, Matrix3x2.Identity, CanvasGeometryCombine.Exclude);
        holes!.Dispose();
        var alpha = (byte)Math.Round(spotlights[^1].Style.SpotlightDim * 255);
        ds.FillGeometry(dim, Color.FromArgb(alpha, 0, 0, 0));
    }

    /// <summary>序号的实心圆（阴影由 WithShadow 垫）；直径 20 / 26 / 34 DIP。</summary>
    private static void DrawCounterDisc(CanvasDrawingSession ds, Annotation annotation, Color color, Mapping map)
        => ds.FillCircle(map.Point(annotation.From), map.Size(annotation.Style.CounterDiameter / 2), color);

    /// <summary>序号数字：粗体，按字形本身的外框居中（数字没有下伸部，按行框居中会偏上）；两位以上缩到圆的 0.78 宽以内。</summary>
    private static void DrawNumber(CanvasDrawingSession ds, Annotation annotation, Vector2 center, float diameter)
    {
        var text = annotation.Number.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var size = diameter * 0.575f;
        CanvasTextLayout Layout(float fontSize) => new(
            ds, text,
            new CanvasTextFormat
            {
                FontFamily = "Segoe UI Variable Display",
                FontSize = fontSize,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                WordWrapping = CanvasWordWrapping.NoWrap,
            },
            // 给有限的框：传 float.MaxValue 时 DrawBounds 量出来是空的，数字就从圆心往右下画了
            diameter * 4, diameter * 4);
        var layout = Layout(size);
        if (layout.DrawBounds.Width > diameter * 0.78)
        {
            size *= (float)(diameter * 0.78 / layout.DrawBounds.Width);
            layout.Dispose();
            layout = Layout(size);
        }

        using (layout)
        {
            var glyphs = layout.DrawBounds;
            ds.DrawTextLayout(
                layout, center.X - (float)(glyphs.X + glyphs.Width / 2), center.Y - (float)(glyphs.Y + glyphs.Height / 2),
                FromArgb(AnnotationPalette.InkOf(annotation.Style.Color)));
        }
    }

    private static (byte R, byte G, byte B) Average(FrozenScreen screen, int left, int top, int right, int bottom)
    {
        long r = 0, g = 0, b = 0;
        var count = 0;
        var step = Math.Max(1, (right - left) / 6);
        for (var y = top; y < bottom; y += step)
        {
            for (var x = left; x < right; x += step)
            {
                var index = (y * screen.Width + x) * 4;
                b += screen.Bgra[index];
                g += screen.Bgra[index + 1];
                r += screen.Bgra[index + 2];
                count++;
            }
        }

        return count == 0 ? ((byte)0, (byte)0, (byte)0) : ((byte)(r / count), (byte)(g / count), (byte)(b / count));
    }
}
