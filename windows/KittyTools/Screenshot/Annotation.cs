// 截图标注的画法（Win2D）。模型和几何在 Core 的 AnnotationGeometry.cs（KittyTools.Core.Annotation）。
// 坐标一律是遮罩窗口里的物理像素（相对这块屏）；屏幕绘制时按 DPI 换成 DIP，导出时按 1:1 像素。
// ponytail: 第 5a 批只换了模型，画法还是第一版那五种（矩形、箭头、画笔、文字、马赛克）；十种工具、阴影、层次、
// 锥形箭头、文字三种样式是第 5b、5d 批（PLAN-v9-annotate §3、§6），没画法的工具这里先跳过。
using System.Numerics;
using KittyTools.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace KittyTools;

internal static class AnnotationRenderer
{
    /// <summary>文字标注的字号（DIP）。第 5d 批换成三档。</summary>
    private const float TextSize = 16;

    public static Color ColorOf(int palette)
    {
        var argb = AnnotationPalette.ArgbOf(palette);
        return Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);
    }

    /// <summary>文字框的大小（DIP），和 Draw 画字用同一个格式；空串、末尾换行也留一行高。</summary>
    public static (double Width, double Height) MeasureText(string text)
    {
        var measured = text.Length == 0 || text.EndsWith('\n') ? text + " " : text;
        using var format = TextFormat(1);
        using var layout = new CanvasTextLayout(CanvasDevice.GetSharedDevice(), measured, format, float.MaxValue, float.MaxValue);
        var bounds = layout.LayoutBounds;
        return (Math.Ceiling(bounds.Width), Math.Ceiling(bounds.Height));
    }

    /// <summary>文字标注补上量出来的框（像素）：收下文字时、从截图历史读出旧数据时。</summary>
    public static Annotation Measured(Annotation annotation, double scale)
    {
        if (annotation.Kind != AnnotationKind.Text)
        {
            return annotation;
        }

        var (width, height) = MeasureText(annotation.Text);
        return annotation with { Rect = annotation.Rect with { Width = width * scale, Height = height * scale } };
    }

    public static void Draw(
        CanvasDrawingSession ds,
        IReadOnlyList<Annotation> annotations,
        FrozenScreen screen,
        PointD origin,
        double unit,
        double strokeScale)
    {
        foreach (var annotation in annotations)
        {
            var color = ColorOf(annotation.Style.Color);
            var width = (float)(annotation.Style.LineWidth * strokeScale);
            switch (annotation.Kind)
            {
                case AnnotationKind.Rectangle:
                    ds.DrawRectangle(ToRect(annotation.Rect, origin, unit), color, width);
                    break;
                case AnnotationKind.Arrow:
                    DrawArrow(ds, annotation, color, width, origin, unit, strokeScale);
                    break;
                case AnnotationKind.Pen:
                    for (var index = 1; index < annotation.Points.Count; index++)
                    {
                        ds.DrawLine(
                            ToPoint(annotation.Points[index - 1], origin, unit),
                            ToPoint(annotation.Points[index], origin, unit), color, width);
                    }

                    break;
                case AnnotationKind.Text:
                {
                    var point = ToPoint(new PointD(annotation.Rect.X, annotation.Rect.Y), origin, unit);
                    using var format = TextFormat(strokeScale);
                    ds.DrawText(annotation.Text, point.X, point.Y, color, format);
                    break;
                }
                case AnnotationKind.Mosaic:
                    DrawMosaic(ds, annotation, screen, origin, unit);
                    break;
            }
        }
    }

    private static CanvasTextFormat TextFormat(double scale) => new()
    {
        FontFamily = "Segoe UI",
        FontSize = (float)(TextSize * scale),
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    private static void DrawArrow(
        CanvasDrawingSession ds,
        Annotation annotation,
        Color color,
        float width,
        PointD origin,
        double unit,
        double strokeScale)
    {
        var from = annotation.From;
        var to = annotation.To;
        var start = ToPoint(from, origin, unit);
        var end = ToPoint(to, origin, unit);
        ds.DrawLine(start, end, color, width);
        var angle = Math.Atan2(to.Y - from.Y, to.X - from.X);
        var length = (float)(14 * strokeScale);
        var left = new Vector2(
            (float)(end.X - length * Math.Cos(angle - 0.45)),
            (float)(end.Y - length * Math.Sin(angle - 0.45)));
        var right = new Vector2(
            (float)(end.X - length * Math.Cos(angle + 0.45)),
            (float)(end.Y - length * Math.Sin(angle + 0.45)));
        ds.DrawLine(end, left, color, width);
        ds.DrawLine(end, right, color, width);
    }

    private static void DrawMosaic(
        CanvasDrawingSession ds,
        Annotation annotation,
        FrozenScreen screen,
        PointD origin,
        double unit)
    {
        const int block = 8;
        var left = (int)Math.Clamp(annotation.Rect.X, 0, screen.Width);
        var top = (int)Math.Clamp(annotation.Rect.Y, 0, screen.Height);
        var right = (int)Math.Clamp(annotation.Rect.Right, 0, screen.Width);
        var bottom = (int)Math.Clamp(annotation.Rect.Bottom, 0, screen.Height);
        for (var y = top; y < bottom; y += block)
        {
            for (var x = left; x < right; x += block)
            {
                var endX = Math.Min(x + block, right);
                var endY = Math.Min(y + block, bottom);
                var (r, g, b) = Average(screen, x, y, endX, endY);
                var rect = ToRect(
                    new RectD(x, y, endX - x, endY - y), origin, unit);
                ds.FillRectangle((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height, Theme.Argb(255, r, g, b));
            }
        }
    }

    private static (byte R, byte G, byte B) Average(FrozenScreen screen, int left, int top, int right, int bottom)
    {
        long r = 0, g = 0, b = 0;
        var count = 0;
        for (var y = top; y < bottom; y += 2)
        {
            for (var x = left; x < right; x += 2)
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

    private static Vector2 ToPoint(PointD point, PointD origin, double unit)
        => new((float)((point.X - origin.X) * unit), (float)((point.Y - origin.Y) * unit));

    private static Windows.Foundation.Rect ToRect(RectD rect, PointD origin, double unit)
        => new(
            (rect.X - origin.X) * unit,
            (rect.Y - origin.Y) * unit,
            rect.Width * unit,
            rect.Height * unit);
}
