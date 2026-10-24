// 截图标注的数据和绘制：矩形、箭头、画笔、文字、马赛克。
// 坐标一律是遮罩窗口里的物理像素（相对这块屏）；屏幕绘制时按 DPI 换成 DIP，导出时按 1:1 像素。
using System.Numerics;
using KittyTools.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace KittyTools;

internal enum AnnotationTool
{
    Select,
    Rectangle,
    Arrow,
    Pen,
    Text,
    Mosaic,
}

internal sealed class Annotation
{
    public AnnotationTool Tool { get; set; }

    public RectD Rect { get; set; }

    public List<PointD> Points { get; set; } = new();

    public string Text { get; set; } = string.Empty;

    public Color Color { get; set; } = Color.FromArgb(255, 255, 77, 126);

    public double Width { get; set; } = 3;

    public Annotation Clone() => new()
    {
        Tool = Tool,
        Rect = Rect,
        Points = new List<PointD>(Points),
        Text = Text,
        Color = Color,
        Width = Width,
    };
}

internal static class AnnotationRenderer
{
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
            switch (annotation.Tool)
            {
                case AnnotationTool.Rectangle:
                {
                    var rect = ToRect(annotation.Rect, origin, unit);
                    ds.DrawRectangle(rect, annotation.Color, (float)(annotation.Width * strokeScale));
                    break;
                }
                case AnnotationTool.Arrow:
                    DrawArrow(ds, annotation, origin, unit, strokeScale);
                    break;
                case AnnotationTool.Pen:
                    for (var index = 1; index < annotation.Points.Count; index++)
                    {
                        var from = ToPoint(annotation.Points[index - 1], origin, unit);
                        var to = ToPoint(annotation.Points[index], origin, unit);
                        ds.DrawLine(from, to, annotation.Color, (float)(annotation.Width * strokeScale));
                    }

                    break;
                case AnnotationTool.Text:
                {
                    var point = ToPoint(new PointD(annotation.Rect.X, annotation.Rect.Y), origin, unit);
                    var format = new CanvasTextFormat
                    {
                        FontFamily = "Segoe UI",
                        FontSize = (float)(16 * strokeScale),
                        WordWrapping = CanvasWordWrapping.NoWrap,
                    };
                    ds.DrawText(annotation.Text, point.X, point.Y, annotation.Color, format);
                    break;
                }
                case AnnotationTool.Mosaic:
                    DrawMosaic(ds, annotation, screen, origin, unit);
                    break;
            }
        }
    }

    private static void DrawArrow(
        CanvasDrawingSession ds,
        Annotation annotation,
        PointD origin,
        double unit,
        double strokeScale)
    {
        if (annotation.Points.Count < 2)
        {
            return;
        }

        var from = annotation.Points[0];
        var to = annotation.Points[^1];
        var start = ToPoint(from, origin, unit);
        var end = ToPoint(to, origin, unit);
        ds.DrawLine(start, end, annotation.Color, (float)(annotation.Width * strokeScale));
        var angle = Math.Atan2(to.Y - from.Y, to.X - from.X);
        var length = (float)(14 * unit);
        var left = new Vector2(
            (float)(end.X - length * Math.Cos(angle - 0.45)),
            (float)(end.Y - length * Math.Sin(angle - 0.45)));
        var right = new Vector2(
            (float)(end.X - length * Math.Cos(angle + 0.45)),
            (float)(end.Y - length * Math.Sin(angle + 0.45)));
        ds.DrawLine(end, left, annotation.Color, (float)(annotation.Width * strokeScale));
        ds.DrawLine(end, right, annotation.Color, (float)(annotation.Width * strokeScale));
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
                ds.FillRectangle((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height, Color.FromArgb(255, r, g, b));
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
