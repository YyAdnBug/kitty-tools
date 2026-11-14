// 功能图标的路径数据（PLAN-v20 K3，只在 Debug）：`--feature-icon-outline=<输出文件>`。FeatureIcons.cs 平时由 Mac 上的
// swift icons/build-icons.swift windows 生成（描边展开、和填充合成一条、只出 M L C Q Z）；保持唤醒那张图（icons/feature/kitty.keep.awake.svg）
// 只在 mac 的 release-0.9.0 上、windows 这边的 icons/ 不归我们改，就在这里用 Win2D 做同一件事：描边按 SVG 的线宽、圆头展开，
// 和填充并成一条（非零填充），化成直线和三次曲线，写成 "F1 M…" 一行。SVG 的命令照原文手抄成 CanvasPathBuilder 的调用。
#if DEBUG
using System.Globalization;
using System.Numerics;
using System.Text;
using KittyTools.Infrastructure;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;

namespace KittyTools;

internal static partial class IconOutlineProbe
{
    public const string ArgumentPrefix = "--feature-icon-outline=";

    public static void Run(string output)
    {
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            var round = new CanvasStrokeStyle
            {
                StartCap = CanvasCapStyle.Round,
                EndCap = CanvasCapStyle.Round,
                LineJoin = CanvasLineJoin.Round,
            };

            // <path fill="none" stroke-width="2" d="M8 2.6C7 3.9 9 4.9 8 6.4M12 2.6C11 3.9 13 4.9 12 6.4"/>（两缕热气）
            var steam = new CanvasPathBuilder(device);
            steam.BeginFigure(8f, 2.6f);
            steam.AddCubicBezier(new Vector2(7f, 3.9f), new Vector2(9f, 4.9f), new Vector2(8f, 6.4f));
            steam.EndFigure(CanvasFigureLoop.Open);
            steam.BeginFigure(12f, 2.6f);
            steam.AddCubicBezier(new Vector2(11f, 3.9f), new Vector2(13f, 4.9f), new Vector2(12f, 6.4f));
            steam.EndFigure(CanvasFigureLoop.Open);

            // <path fill="currentColor" d="M4.2 9.4H16.2V14.6A5.4 5.4 0 0 1 10.8 20H9.6A5.4 5.4 0 0 1 4.2 14.6Z"/>（杯身）
            var cup = new CanvasPathBuilder(device);
            cup.BeginFigure(4.2f, 9.4f);
            cup.AddLine(16.2f, 9.4f);
            cup.AddLine(16.2f, 14.6f);
            cup.AddArc(new Vector2(10.8f, 20f), 5.4f, 5.4f, 0, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
            cup.AddLine(9.6f, 20f);
            cup.AddArc(new Vector2(4.2f, 14.6f), 5.4f, 5.4f, 0, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
            cup.EndFigure(CanvasFigureLoop.Closed);

            // <path fill="none" stroke-width="2.2" d="M16.4 11.2H18.2A2.6 2.6 0 0 1 18.2 16.4H16.2M3.6 22.2H16.8"/>（把手、托盘）
            var rest = new CanvasPathBuilder(device);
            rest.BeginFigure(16.4f, 11.2f);
            rest.AddLine(18.2f, 11.2f);
            rest.AddArc(new Vector2(18.2f, 16.4f), 2.6f, 2.6f, 0, CanvasSweepDirection.Clockwise, CanvasArcSize.Small);
            rest.AddLine(16.2f, 16.4f);
            rest.EndFigure(CanvasFigureLoop.Open);
            rest.BeginFigure(3.6f, 22.2f);
            rest.AddLine(16.8f, 22.2f);
            rest.EndFigure(CanvasFigureLoop.Open);

            // 24 格的小图：默认的展平容差（0.25）会把热气的曲线折成几段直线，压到 0.002
            const float tolerance = 0.002f;
            using var steamGeometry = CanvasGeometry.CreatePath(steam).Stroke(2f, round, Matrix3x2.Identity, tolerance);
            using var cupGeometry = CanvasGeometry.CreatePath(cup);
            using var restGeometry = CanvasGeometry.CreatePath(rest).Stroke(2.2f, round, Matrix3x2.Identity, tolerance);
            using var merged = cupGeometry
                .CombineWith(steamGeometry, Matrix3x2.Identity, CanvasGeometryCombine.Union, tolerance)
                .CombineWith(restGeometry, Matrix3x2.Identity, CanvasGeometryCombine.Union, tolerance)
                .Simplify(CanvasGeometrySimplification.CubicsAndLines, Matrix3x2.Identity, tolerance);
            var writer = new PathWriter();
            merged.SendPathTo(writer);
            File.WriteAllText(output, "F1 " + writer.Text.ToString().Trim());
            Log.Info($"icon-outline done length={writer.Text.Length}");
        }
        catch (Exception ex)
        {
            Log.Warn($"icon-outline failed {ex.GetType().Name}: {ex.Message}");
        }

        Environment.Exit(0);
    }

    /// <summary>收 Win2D 吐出来的一段段，写成 M L C Q Z（坐标三位小数、去掉末尾的 0，同 build-icons 的 format）。</summary>
    private sealed partial class PathWriter : ICanvasPathReceiver
    {
        public StringBuilder Text { get; } = new();

        private static string F(float value)
        {
            var text = Math.Round(value, 3).ToString("0.###", CultureInfo.InvariantCulture);
            return text == "-0" ? "0" : text;
        }

        private void Point(Vector2 point) => Text.Append(F(point.X)).Append(' ').Append(F(point.Y));

        public void BeginFigure(Vector2 startPoint, CanvasFigureFill figureFill)
        {
            Text.Append('M');
            Point(startPoint);
        }

        public void AddArc(Vector2 endPoint, float radiusX, float radiusY, float rotationAngle, CanvasSweepDirection sweepDirection, CanvasArcSize arcSize)
            => throw new InvalidOperationException("化简之后不该再有圆弧");

        public void AddCubicBezier(Vector2 controlPoint1, Vector2 controlPoint2, Vector2 endPoint)
        {
            Text.Append('C');
            Point(controlPoint1);
            Text.Append(' ');
            Point(controlPoint2);
            Text.Append(' ');
            Point(endPoint);
        }

        public void AddLine(Vector2 endPoint)
        {
            Text.Append('L');
            Point(endPoint);
        }

        public void AddQuadraticBezier(Vector2 controlPoint, Vector2 endPoint)
        {
            Text.Append('Q');
            Point(controlPoint);
            Text.Append(' ');
            Point(endPoint);
        }

        public void SetFilledRegionDetermination(CanvasFilledRegionDetermination filledRegionDetermination)
        {
        }

        public void SetSegmentOptions(CanvasFigureSegmentOptions figureSegmentOptions)
        {
        }

        public void EndFigure(CanvasFigureLoop figureLoop)
        {
            if (figureLoop == CanvasFigureLoop.Closed)
            {
                Text.Append('Z');
            }
        }
    }
}
#endif
