// PLAN-v9 第 5a 批：截图标注的模型和几何（照 mac AnnotationToolTests 的几何部分搬过来，期望值不变；mac 原点左下、
// 这里原点左上，所以手柄的上下、复制的偏移方向翻过来），撤销栈（B1、B2），截图历史 JSON 的新字段和旧数据换算。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AnnotationGeometryTests
{
    private static Annotation Box(AnnotationKind kind, RectD rect, int option = 0)
        => new() { Kind = kind, Rect = rect, Style = AnnotationStyle.Default with { Option = option } };

    private static Annotation Segment(AnnotationKind kind, PointD from, PointD to, VectorD bend = default, int weight = 1)
        => new() { Kind = kind, From = from, To = to, Bend = bend, Style = AnnotationStyle.Default with { Weight = weight } };

    private static bool Near(PointD a, PointD b) => Math.Abs(a.X - b.X) < 1e-9 && Math.Abs(a.Y - b.Y) < 1e-9;

    [TestMethod]
    public void ToolMetadata()
    {
        CollectionAssert.AreEqual(
            new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
            AnnotationKinds.All.Select(AnnotationKinds.Key).ToArray());
        Assert.AreEqual(AnnotationKind.Rectangle, AnnotationKinds.All[0]);
        Assert.AreEqual(AnnotationKind.Spotlight, AnnotationKinds.All[^1]);
        CollectionAssert.AreEqual(
            new[] { AnnotationKind.Mosaic, AnnotationKind.Spotlight },
            AnnotationKinds.All.Where(kind => !AnnotationKinds.HasColor(kind)).ToArray());
        CollectionAssert.AreEqual(
            new[] { AnnotationKind.Text, AnnotationKind.Counter },
            AnnotationKinds.All.Where(kind => !AnnotationKinds.IsDragDrawn(kind)).ToArray());
        CollectionAssert.AreEqual(new[] { "无底", "描边", "底色" }, AnnotationKinds.OptionTitles(AnnotationKind.Text));
        CollectionAssert.AreEqual(new[] { "像素", "模糊" }, AnnotationKinds.OptionTitles(AnnotationKind.Mosaic));
        Assert.AreEqual(0, AnnotationKinds.OptionTitles(AnnotationKind.Arrow).Length);
        Assert.AreEqual(8, AnnotationPalette.Argb.Length);
        Assert.AreEqual(0xFFFF3B30u, AnnotationPalette.ArgbOf(AnnotationStyle.Default.Color));
        Assert.AreEqual(AnnotationPalette.Yellow, AnnotationStyle.DefaultFor(AnnotationKind.Highlighter).Color);
        // 存盘的名字往返；第一版存的五个名字照旧认得
        foreach (var kind in AnnotationKinds.All)
        {
            Assert.AreEqual(kind, AnnotationKinds.Parse(AnnotationKinds.StorageName(kind)));
        }

        foreach (var old in new[] { "rectangle", "arrow", "pen", "text", "mosaic" })
        {
            Assert.IsNotNull(AnnotationKinds.Parse(old), old);
        }

        Assert.IsNull(AnnotationKinds.Parse("select"));
        Assert.IsNull(AnnotationKinds.Parse("3"));
    }

    [TestMethod]
    public void ShapesForEveryDragTool()
    {
        var start = new PointD(10, 10);
        var end = new PointD(40, -5);
        foreach (var kind in AnnotationKinds.All)
        {
            var drawn = Annotation.Drawn(kind, start, end, false, AnnotationStyle.Default);
            Assert.AreEqual(AnnotationKinds.IsDragDrawn(kind), drawn is not null, kind.ToString());
            if (drawn is not null)
            {
                Assert.AreEqual(kind, drawn.Kind);
            }
        }

        var square = new RectD(10, -20, 30, 30);
        Assert.AreEqual(square, Annotation.Drawn(AnnotationKind.Ellipse, start, end, true, default)!.Rect);
        Assert.AreEqual(square, Annotation.Drawn(AnnotationKind.Spotlight, start, end, true, default)!.Rect);
        Assert.AreEqual(new RectD(10, -5, 30, 15), Annotation.Drawn(AnnotationKind.Mosaic, start, end, false, default)!.Rect);
        CollectionAssert.AreEqual(
            new[] { start, end }, Annotation.Drawn(AnnotationKind.Pen, start, end, true, default)!.Points.ToArray());
        // 线类 Shift 吸 45°，长度不变
        foreach (var kind in new[] { AnnotationKind.Line, AnnotationKind.Highlighter, AnnotationKind.Arrow })
        {
            var tip = Annotation.Drawn(kind, new PointD(0, 0), new PointD(100, 90), true, default)!.To;
            Assert.IsTrue(Math.Abs(tip.X - tip.Y) < 0.001, kind.ToString());
            Assert.AreEqual(Math.Sqrt(100 * 100 + 90 * 90), Math.Sqrt(tip.X * tip.X + tip.Y * tip.Y), 0.001);
        }
    }

    [TestMethod]
    public void HitTestingPerTool()
    {
        var rect = new RectD(100, 100, 200, 100);
        // 空心矩形 / 椭圆只认线，实心认整块
        var hollowRect = Box(AnnotationKind.Rectangle, rect);
        Assert.IsTrue(hollowRect.Contains(new PointD(101, 150), 1));
        Assert.IsFalse(hollowRect.Contains(new PointD(200, 150), 1));
        Assert.IsTrue(Box(AnnotationKind.Rectangle, rect, option: 1).Contains(new PointD(200, 150), 1));
        var hollowEllipse = Box(AnnotationKind.Ellipse, rect);
        Assert.IsTrue(hollowEllipse.Contains(new PointD(200, 199), 1)); // 下边的弧
        Assert.IsFalse(hollowEllipse.Contains(new PointD(200, 150), 1));
        Assert.IsFalse(hollowEllipse.Contains(new PointD(104, 196), 1)); // 外接矩形的角上不算
        Assert.IsTrue(Box(AnnotationKind.Ellipse, rect, option: 1).Contains(new PointD(200, 150), 1));
        // 聚光灯只认边（里面还要接着画别的标注），马赛克认整块
        var spotlight = Box(AnnotationKind.Spotlight, rect);
        Assert.IsTrue(spotlight.Contains(new PointD(299, 150), 1));
        Assert.IsFalse(spotlight.Contains(new PointD(200, 150), 1));
        Assert.IsTrue(Box(AnnotationKind.Mosaic, rect).Contains(new PointD(200, 150), 1));
        // 线类
        var line = Segment(AnnotationKind.Line, new PointD(0, 0), new PointD(100, 0));
        Assert.IsTrue(line.Contains(new PointD(50, 5), 1));
        Assert.IsFalse(line.Contains(new PointD(50, 8), 1));
        var highlighter = Segment(AnnotationKind.Highlighter, new PointD(0, 0), new PointD(100, 0));
        Assert.IsTrue(highlighter.Contains(new PointD(50, 12), 1));
        Assert.IsFalse(highlighter.Contains(new PointD(50, 15), 1));
        var pen = new Annotation
        {
            Kind = AnnotationKind.Pen, Points = new[] { new PointD(0, 0), new PointD(50, 0), new PointD(50, 50) },
        };
        Assert.IsTrue(pen.Contains(new PointD(53, 30), 1));
        Assert.IsFalse(pen.Contains(new PointD(20, 30), 1));
        // 序号认整个圆（中号直径 26）
        var counter = new Annotation { Kind = AnnotationKind.Counter, From = new PointD(50, 50), Number = 1 };
        Assert.IsTrue(counter.Contains(new PointD(50, 65), 1));
        Assert.IsFalse(counter.Contains(new PointD(50, 68), 1));
        Assert.IsTrue(counter.Bounds(1).Width >= 26);
        Assert.IsTrue(counter.IsMeaningful(1));
        Assert.IsFalse(new Annotation { Kind = AnnotationKind.Pen, Points = new[] { new PointD(0, 0), new PointD(1, 1) } }
            .IsMeaningful(1));
        Assert.IsFalse(Segment(AnnotationKind.Line, new PointD(0, 0), new PointD(3, 3)).IsMeaningful(1));
        // 文字认量出来的整个框（B4：以前按每个字 8 px 估）
        var text = new Annotation { Kind = AnnotationKind.Text, Rect = new RectD(10, 10, 300, 40), Text = "很长的一行中文" };
        Assert.IsTrue(text.Contains(new PointD(290, 45), 1));
        Assert.IsFalse(text.Contains(new PointD(340, 45), 1));
        Assert.IsFalse(new Annotation { Kind = AnnotationKind.Text, Text = " \n " }.IsMeaningful(1));
    }

    [TestMethod]
    public void SizesFollowTheScreenScale()
    {
        // 线宽、容差按 DIP 定：150% 的屏上同一条线点得中的范围是 1.5 倍
        var line = Segment(AnnotationKind.Line, new PointD(0, 0), new PointD(300, 0));
        Assert.IsFalse(line.Contains(new PointD(150, 8), 1));
        Assert.IsTrue(line.Contains(new PointD(150, 8), 1.5));
        Assert.IsFalse(line.Contains(new PointD(150, 10), 1.5));
        Assert.IsTrue(Segment(AnnotationKind.Line, new PointD(0, 0), new PointD(7, 0)).IsMeaningful(1));
        Assert.IsFalse(Segment(AnnotationKind.Line, new PointD(0, 0), new PointD(7, 0)).IsMeaningful(1.5));
    }

    [TestMethod]
    public void HandlesAndResize()
    {
        var box = Box(AnnotationKind.Rectangle, new RectD(10, 20, 40, 30));
        var corners = box.Handles(1).ToDictionary(grip => grip.Handle, grip => grip.Point);
        Assert.AreEqual(4, corners.Count);
        Assert.AreEqual(new PointD(10, 20), corners[AnnotationHandle.TopLeft]);
        Assert.AreEqual(new PointD(50, 50), corners[AnnotationHandle.BottomRight]);
        // 拖左上角：右下角不动；拖过头翻过去；Shift 正方形
        var grown = box.Resized(AnnotationHandle.TopLeft, new PointD(0, 10), false, 1);
        Assert.AreEqual(box.Id, grown.Id);
        Assert.AreEqual(new RectD(0, 10, 50, 40), grown.Rect);
        Assert.AreEqual(
            new RectD(50, 50, 10, 10), box.Resized(AnnotationHandle.TopLeft, new PointD(60, 60), false, 1).Rect);
        Assert.AreEqual(
            new RectD(10, 20, 60, 60), box.Resized(AnnotationHandle.BottomRight, new PointD(70, 50), true, 1).Rect);
        Assert.AreEqual(box, box.Resized(AnnotationHandle.Start, new PointD(0, 0), false, 1));
        // 线类两端：另一端不动，Shift 吸 45°；箭头、直线还有弧线中点的弯曲手柄（直的在弦中点），荧光笔没有
        var arrow = Segment(AnnotationKind.Arrow, new PointD(0, 0), new PointD(100, 0));
        CollectionAssert.AreEqual(
            new[] { AnnotationHandle.Start, AnnotationHandle.End, AnnotationHandle.Bend },
            arrow.Handles(1).Select(grip => grip.Handle).ToArray());
        CollectionAssert.AreEqual(
            new[] { new PointD(0, 0), new PointD(100, 0), new PointD(50, 0) },
            arrow.Handles(1).Select(grip => grip.Point).ToArray());
        CollectionAssert.AreEqual(
            new[] { AnnotationHandle.Start, AnnotationHandle.End },
            Segment(AnnotationKind.Highlighter, new PointD(0, 0), new PointD(100, 0)).Handles(1)
                .Select(grip => grip.Handle).ToArray());
        Assert.AreEqual(new PointD(10, 10), arrow.Resized(AnnotationHandle.Start, new PointD(10, 10), false, 1).From);
        var snapped = arrow.Resized(AnnotationHandle.End, new PointD(80, 70), true, 1);
        Assert.AreEqual(new PointD(0, 0), snapped.From);
        Assert.IsTrue(Math.Abs(snapped.To.X - snapped.To.Y) < 0.001);
        Assert.AreEqual(box, box.Resized(AnnotationHandle.Bend, new PointD(0, 0), false, 1));
        // 文字、序号、画笔只能拖动
        Assert.AreEqual(0, new Annotation { Kind = AnnotationKind.Text, Text = "字" }.Handles(1).Count);
        Assert.AreEqual(0, new Annotation { Kind = AnnotationKind.Counter }.Handles(1).Count);
        Assert.AreEqual(0, new Annotation { Kind = AnnotationKind.Pen, Points = new[] { new PointD(0, 0), new PointD(9, 9) } }
            .Handles(1).Count);
    }

    [TestMethod]
    [DataRow(AnnotationKind.Arrow)]
    [DataRow(AnnotationKind.Line)]
    public void CurveBendFollowsTheMidpointHandle(AnnotationKind kind)
    {
        var (from, to) = (new PointD(0, 0), new PointD(100, 0));
        // 弯曲手柄拖到 (50, 25)：弧线中点就在那儿，二次贝塞尔的控制点 = 2 · 中点 − 弦中点
        var bend = Annotation.CurveBend(from, to, new PointD(50, 25), false);
        Assert.AreEqual(new VectorD(0, 0.25), bend);
        Assert.AreEqual(new PointD(50, 25), Annotation.CurveMidpoint(from, to, bend));
        Assert.AreEqual(new PointD(50, 50), Annotation.CurveControl(from, to, bend));
        // 斜的弦、偏向一端地拖：中点照样落在手柄上
        var (a, b) = (new PointD(10, 20), new PointD(70, 100));
        var skewed = Annotation.CurveBend(a, b, new PointD(20, 80), false);
        Assert.AreNotEqual(0, skewed.X);
        Assert.IsTrue(Near(Annotation.CurveMidpoint(a, b, skewed), new PointD(20, 80)));
        // Shift：只留垂直弦的那份，弯成对称的弧
        Assert.AreEqual(new VectorD(0, -0.5), Annotation.CurveBend(from, to, new PointD(80, -50), true));
        // 离弦不到 4 吸回直的（弦的延长线上也是）；弦长为 0 是直的
        foreach (var point in new[] { new PointD(70, 3.9), new PointD(70, -3.9), new PointD(160, 0) })
        {
            Assert.AreEqual(VectorD.Zero, Annotation.CurveBend(from, to, point, false));
        }

        Assert.AreNotEqual(VectorD.Zero, Annotation.CurveBend(from, to, new PointD(50, 4), false));
        Assert.AreEqual(VectorD.Zero, Annotation.CurveBend(from, from, new PointD(5, 50), false));
        // 拖弯曲手柄：两端不动，弧线中点跟到手柄上；沿弦停在 ¾ 处、Shift 对称、离弦 4 内拉直
        var straight = Segment(kind, from, to);
        Assert.AreEqual(VectorD.Zero, Annotation.Drawn(kind, from, to, false, default)!.Bend);
        var bent = straight.Resized(AnnotationHandle.Bend, new PointD(30, -40), false, 1);
        Assert.AreEqual(straight.Id, bent.Id);
        Assert.AreEqual(kind, bent.Kind);
        Assert.AreEqual(from, bent.From);
        Assert.AreEqual(to, bent.To);
        Assert.IsTrue(Near(Annotation.CurveMidpoint(from, to, bent.Bend), new PointD(30, -40)));
        Assert.IsTrue(Near(bent.Handles(1)[^1].Point, new PointD(30, -40)));
        Assert.AreEqual(new VectorD(0.25, 0.2), straight.Resized(AnnotationHandle.Bend, new PointD(400, 20), false, 1).Bend);
        Assert.AreEqual(new VectorD(0, -0.5), straight.Resized(AnnotationHandle.Bend, new PointD(80, -50), true, 1).Bend);
        Assert.AreEqual(straight, bent.Resized(AnnotationHandle.Bend, new PointD(20, 3), false, 1));
        // 拉直：两端不动、弯度清零，Id 和样式不变；不能弯的原样
        Assert.AreEqual(straight, bent.Straightened);
        var box = Box(AnnotationKind.Rectangle, new RectD(0, 0, 9, 9));
        Assert.AreEqual(box, box.Straightened);
        // 弦短于 32 的不给弯曲手柄；只看弦：弧线中点被拖到离尖端不到 16 也还在
        Assert.AreEqual(2, Segment(kind, from, new PointD(30, 0)).Handles(1).Count);
        Assert.AreEqual(3, Segment(kind, from, new PointD(32, 0)).Handles(1).Count);
        var grip = Segment(kind, from, new PointD(40, 0), new VectorD(0.25, 0.1)).Handles(1)
            .First(handle => handle.Handle == AnnotationHandle.Bend).Point;
        Assert.IsTrue(Near(grip, new PointD(30, 4)));
    }

    [TestMethod]
    public void BendHandleStopsAtAQuarterOfTheChord()
    {
        // 手柄沿弦拖过尖端 / 尾端：弧线中点停在弦的 ¾ / ¼ 处，弧线在弦上的投影从头到尾单调、不出两端
        var (from, to) = (new PointD(40, 150), new PointD(200, 150));
        foreach (var (handle, along) in new[] { (new PointD(330, 156), 0.25), (new PointD(-90, 144), -0.25) })
        {
            var bend = Annotation.CurveBend(from, to, handle, false);
            Assert.AreEqual(along, bend.X);
            Assert.AreEqual((handle.Y - 150) / 160, bend.Y, 1e-12);
            var control = Annotation.CurveControl(from, to, bend);
            Assert.AreEqual(along > 0 ? to.X : from.X, control.X, 1e-9);
            var xs = Enumerable.Range(0, 1001).Select(step => Annotation.Quad(from, control, to, step / 1000.0).X).ToArray();
            Assert.IsTrue(xs.Zip(xs.Skip(1)).All(pair => pair.First <= pair.Second + 1e-9));
            Assert.IsTrue(xs.Min() >= from.X - 1e-9 && xs.Max() <= to.X + 1e-9);
        }
    }

    [TestMethod]
    [DataRow(AnnotationKind.Arrow)]
    [DataRow(AnnotationKind.Line)]
    public void EndsKeepTheBendProportional(AnnotationKind kind)
    {
        // 弦从 (0,0)→(100,0) 拖成 (0,0)→(0,200)：放大 2 倍、转 90°，弧线中点 (50, 25) 跟着变到 (−50, 100)
        var arrow = Segment(kind, new PointD(0, 0), new PointD(100, 0), new VectorD(0, 0.25));
        var resized = arrow.Resized(AnnotationHandle.End, new PointD(0, 200), false, 1);
        Assert.AreEqual(kind, resized.Kind);
        Assert.AreEqual(new PointD(0, 200), resized.To);
        Assert.AreEqual(new VectorD(0, 0.25), resized.Bend);
        Assert.IsTrue(Near(resized.Handles(1).First(grip => grip.Handle == AnnotationHandle.Bend).Point, new PointD(-50, 100)));
        // 拖起点同样；挪动、复制都带着弯度
        Assert.AreEqual(new VectorD(0, 0.25), arrow.Resized(AnnotationHandle.Start, new PointD(-30, 7), true, 1).Bend);
        var moved = arrow.Offset(5, -3);
        Assert.AreEqual(new PointD(5, -3), moved.From);
        Assert.AreEqual(new PointD(105, -3), moved.To);
        Assert.AreEqual(arrow.Bend, moved.Bend);
        var copy = arrow.Duplicated(12, 12);
        Assert.AreNotEqual(arrow.Id, copy.Id);
        Assert.AreEqual(new PointD(12, 12), copy.From);
        Assert.AreEqual(arrow.Bend, copy.Bend);
    }

    [TestMethod]
    [DataRow(AnnotationKind.Arrow)]
    [DataRow(AnnotationKind.Line)]
    public void CurvedBoundsAndHitTestingFollowTheCurve(AnnotationKind kind)
    {
        // 弦 (0,0)→(100,0)，弧线顶点 (50, 25)：外框、点中都认鼓出来的那截，弦上（离弧线 25）点不中
        var arrow = Segment(kind, new PointD(0, 0), new PointD(100, 0), new VectorD(0, 0.25));
        var straight = Segment(kind, new PointD(0, 0), new PointD(100, 0));
        var pad = straight.Bounds(1).Bottom;
        Assert.IsTrue(kind == AnnotationKind.Arrow || pad == 2);
        Assert.AreEqual(25 + pad, arrow.Bounds(1).Bottom, 1e-9);
        Assert.AreEqual(straight.Bounds(1).X, arrow.Bounds(1).X);
        Assert.AreEqual(straight.Bounds(1).Y, arrow.Bounds(1).Y);
        // 偏向一端的：控制点偏到弦的右端外面、弧线鼓出右端（逐点找最右）
        var skewed = Segment(kind, new PointD(0, 0), new PointD(100, 0), new VectorD(0.3, -0.4));
        var control = Annotation.CurveControl(new PointD(0, 0), new PointD(100, 0), new VectorD(0.3, -0.4));
        Assert.AreEqual(control.Y / 2 - pad, skewed.Bounds(1).Y, 1e-9);
        var rightmost = Enumerable.Range(0, 1001)
            .Select(step => Annotation.Quad(new PointD(0, 0), control, new PointD(100, 0), step / 1000.0).X).Max();
        Assert.IsTrue(rightmost > 100);
        Assert.AreEqual(rightmost + pad, skewed.Bounds(1).Right, 0.01);
        // 点中：弧线顶点、离顶点 5（半宽 2 + 容差 4）算，8、弦中点不算
        Assert.IsTrue(arrow.Contains(new PointD(50, 25), 1) && arrow.Contains(new PointD(50, 30), 1));
        Assert.IsFalse(arrow.Contains(new PointD(50, 33), 1));
        Assert.IsFalse(arrow.Contains(new PointD(50, 0), 1));
        Assert.AreEqual(arrow.Id, Annotation.Topmost(new[] { arrow }, new PointD(50, 24), 1)?.Id);
        Assert.IsNull(Annotation.Topmost(new[] { arrow }, new PointD(50, 2), 1));
    }

    [TestMethod]
    public void HitTestingSkipsCurvesFarFromThePointer()
    {
        // 每次鼠标移动都要问一遍所有标注：光标离弯的很远时先按外框排除
        var arrow = Segment(AnnotationKind.Arrow, new PointD(100, 100), new PointD(1500, 900), new VectorD(0.1, 0.4), 2);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var hits = Enumerable.Range(0, 2000).Count(index => arrow.Contains(new PointD(3000 + index, 50), 1));
        Assert.IsTrue(watch.ElapsedMilliseconds < 250, $"{watch.ElapsedMilliseconds} ms");
        Assert.AreEqual(0, hits);
    }

    [TestMethod]
    public void StraightArrowPolygonIsTheTaperedHeptagon()
    {
        // 尾部半宽 0.15 × 线宽、颈 0.6 × 线宽、头长 4 × 线宽、半角 28°；箭头的翼点得中、尾巴两边点不中
        var polygon = Annotation.ArrowPolygon(new PointD(0, 0), new PointD(100, 0), 4)!;
        Assert.AreEqual(7, polygon.Length);
        Assert.AreEqual(new PointD(100, 0), polygon[3]);
        var wing = 16 * Math.Tan(28 * Math.PI / 180);
        Assert.AreEqual(84, polygon[2].X, 1e-9);
        Assert.AreEqual(wing, Math.Abs(polygon[2].Y), 1e-9);
        Assert.AreEqual(0.6, Math.Abs(polygon[0].Y), 1e-9);
        Assert.IsNull(Annotation.ArrowPolygon(new PointD(1, 1), new PointD(1, 1), 4));
        var arrow = Segment(AnnotationKind.Arrow, new PointD(0, 0), new PointD(100, 0));
        Assert.IsTrue(arrow.Contains(new PointD(85, 7), 1)); // 翼里，离杆 7（只认杆的话 6 以外就不中）
        Assert.IsFalse(arrow.Contains(new PointD(20, 7), 1));
    }

    [TestMethod]
    public void DuplicateAndCounterNumbers()
    {
        var counter = new Annotation { Kind = AnnotationKind.Counter, Number = 3, From = new PointD(20, 20) };
        var copy = counter.Duplicated(12, 12);
        Assert.AreNotEqual(counter.Id, copy.Id);
        Assert.AreEqual(counter.Style, copy.Style);
        Assert.AreEqual(new PointD(32, 32), copy.From); // 往右下偏 12（原点左上）
        Assert.AreEqual(3, copy.Number);
        Assert.AreEqual(counter.From, counter.Duplicated(0, 0).From);
        Assert.AreEqual(1, Annotation.NextCounter(Array.Empty<Annotation>()));
        Assert.AreEqual(4, Annotation.NextCounter(new[]
        {
            counter, new Annotation { Kind = AnnotationKind.Counter, Number = 1 }, Box(AnnotationKind.Rectangle, default),
        }));
    }

    [TestMethod]
    public void TopmostFollowsTheDrawingLayers()
    {
        // 序号压在后画的标注上面，马赛克垫在最下面；同一层后画的在上
        var mosaic = Box(AnnotationKind.Mosaic, new RectD(0, 0, 100, 100));
        var counter = new Annotation { Kind = AnnotationKind.Counter, Number = 1, From = new PointD(50, 50) };
        var filled = Box(AnnotationKind.Rectangle, new RectD(40, 40, 30, 30), option: 1);
        var later = Box(AnnotationKind.Rectangle, new RectD(45, 45, 30, 30), option: 1);
        Assert.AreEqual(counter.Id, Annotation.Topmost(new[] { counter, mosaic, filled }, new PointD(50, 50), 1)?.Id);
        Assert.AreEqual(later.Id, Annotation.Topmost(new[] { mosaic, filled, later }, new PointD(60, 60), 1)?.Id);
        Assert.AreEqual(mosaic.Id, Annotation.Topmost(new[] { filled, mosaic }, new PointD(10, 10), 1)?.Id);
    }

    [TestMethod]
    public void EqualityComparesPointsByValue()
    {
        var pen = new Annotation { Kind = AnnotationKind.Pen, Points = new[] { new PointD(1, 2), new PointD(3, 4) } };
        var same = pen with { Points = new[] { new PointD(1, 2), new PointD(3, 4) } };
        Assert.AreEqual(pen, same);
        Assert.AreNotEqual(pen, pen.Offset(1, 0));
        Assert.AreNotEqual(pen, pen with { Id = Guid.NewGuid() });
    }

    [TestMethod]
    public void UndoRecordsOnlyRealChanges()
    {
        var document = new AnnotationDocument();
        var box = Box(AnnotationKind.Rectangle, new RectD(0, 0, 50, 50));
        Assert.IsTrue(document.Commit(new[] { box }));
        Assert.IsFalse(document.Commit(new[] { box })); // 没变不记
        // B1：单击选中、拖了 0 像素，不占一步
        var before = document.Items;
        document.SelectedId = box.Id;
        document.Replace(box.Offset(0, 0));
        Assert.IsFalse(document.RecordUndo(before));
        // 真挪了：一步，撤销回到原处
        before = document.Items;
        document.Replace(box.Offset(10, 0));
        Assert.IsTrue(document.RecordUndo(before));
        Assert.IsTrue(document.Undo());
        Assert.AreEqual(box.Rect, document.Items[0].Rect);
        Assert.IsTrue(document.Redo());
        Assert.AreEqual(10, document.Items[0].Rect.X);
        // B2：撤销以后选中的仍然是列表里的那条（按 Id），删除删得掉
        Assert.IsTrue(document.Undo());
        Assert.AreEqual(box.Id, document.Selected?.Id);
        Assert.IsTrue(document.DeleteSelected());
        Assert.AreEqual(0, document.Items.Count);
        Assert.IsNull(document.SelectedId);
        // 撤销到那条还不存在的时候：选中跟着清掉
        Assert.IsTrue(document.Undo());
        document.SelectedId = box.Id;
        Assert.IsTrue(document.Undo());
        Assert.AreEqual(0, document.Items.Count);
        Assert.IsNull(document.SelectedId);
        while (document.Undo())
        {
        }

        Assert.IsFalse(document.CanUndo);
        Assert.IsFalse(document.Undo()); // 栈空：调用方出提示音
    }

    [TestMethod]
    public void RestyleChangesTheSelectedOne()
    {
        // B6：改样式作用于选中的那条，记一步撤销
        var document = new AnnotationDocument();
        var arrow = Segment(AnnotationKind.Arrow, new PointD(0, 0), new PointD(50, 0));
        var box = Box(AnnotationKind.Rectangle, new RectD(0, 0, 9, 9));
        document.Commit(new[] { arrow, box });
        Assert.IsNull(document.RestyleSelected(style => style with { Color = 5 }));
        document.SelectedId = arrow.Id;
        Assert.AreEqual(5, document.RestyleSelected(style => style with { Color = 5 })?.Color);
        Assert.AreEqual(5, document.Items[0].Style.Color);
        Assert.AreEqual(AnnotationStyle.Default, document.Items[1].Style);
        document.Undo();
        Assert.AreEqual(AnnotationStyle.Default, document.Items[0].Style);
        document.Load(new[] { box });
        Assert.IsFalse(document.CanUndo);
        Assert.IsNull(document.SelectedId);
    }

    [TestMethod]
    public void RestyleRefitsTextInTheSameUndoStep()
    {
        // 5d：文字换了字号要重新量框（App 里量），量过的框和样式一起是一步撤销，重做回来的也是量过的
        var document = new AnnotationDocument();
        var text = new Annotation { Kind = AnnotationKind.Text, Rect = new RectD(10, 10, 40, 20), Text = "Kitty" };
        document.Commit(new[] { text });
        document.SelectedId = text.Id;
        document.RestyleSelected(
            style => style with { Weight = 2 },
            annotation => annotation with { Rect = annotation.Rect with { Width = annotation.Style.FontSize * 2 } });
        Assert.AreEqual(56, document.Items[0].Rect.Width);
        Assert.AreEqual(2, document.Items[0].Style.Weight);
        Assert.IsTrue(document.Undo());
        Assert.AreEqual(40, document.Items[0].Rect.Width);
        Assert.IsTrue(document.Redo());
        Assert.AreEqual(56, document.Items[0].Rect.Width);
    }

    [TestMethod]
    public void HistoryRoundTripKeepsEveryTool()
    {
        var annotations = new Annotation[]
        {
            Box(AnnotationKind.Ellipse, new RectD(110, 120, 30, 40), option: 1),
            Segment(AnnotationKind.Arrow, new PointD(105, 105), new PointD(180, 150), new VectorD(0.1, -0.2), 2),
            Segment(AnnotationKind.Highlighter, new PointD(100, 200), new PointD(190, 200)),
            new() { Kind = AnnotationKind.Pen, Points = new[] { new PointD(101, 102), new PointD(103.5, 104) } },
            new() { Kind = AnnotationKind.Text, Rect = new RectD(120, 130, 80, 24), Text = "你好", Style = new(7, 2, 2) },
            new() { Kind = AnnotationKind.Counter, From = new PointD(150, 160), Number = 4, Style = new(5, 0, 0) },
            Box(AnnotationKind.Spotlight, new RectD(100, 100, 50, 50)),
        };
        var data = annotations.Select(annotation => ShotHistoryRules.ToData(annotation, 100, 100)).ToList();
        Assert.AreEqual(new PointD(5, 5), data[1].Points[0]); // 坐标挪到原图里
        var decoded = ShotHistoryRules.DecodeAnnotations(ShotHistoryRules.EncodeAnnotations(data));
        var back = decoded.Select(item => ShotHistoryRules.FromData(item, 100, 100)).ToList();
        Assert.AreEqual(annotations.Length, back.Count);
        for (var index = 0; index < annotations.Length; index++)
        {
            // Id 不存盘，其余一样
            Assert.AreEqual(annotations[index], back[index]! with { Id = annotations[index].Id }, annotations[index].Kind.ToString());
        }
    }

    [TestMethod]
    public void CurvedArrowHeadMeetsTheShaftWithoutAKink()
    {
        // 5b，照 mac：手柄拖到弦的 ¾ 处、离弦 12：弧线贴着尖端拐个钩，底边中点到尖端的弦和杆在颈部差 20° 多。
        // 箭头底边垂直于杆（颈部不折），尖端还在终点上
        var (from, to) = (new PointD(0, 0), new PointD(160, 0));
        var bend = Annotation.CurveBend(from, to, new PointD(120, 12), false);
        Assert.AreEqual(0.25, bend.X);
        static double Angle(VectorD a, VectorD b)
            => Math.Abs(Math.Atan2(a.X * b.Y - a.Y * b.X, a.X * b.X + a.Y * b.Y)) * 180 / Math.PI;
        static VectorD Heading(PointD left, PointD right) => new(left.Y - right.Y, right.X - left.X);
        foreach (var width in new[] { 4.0, 6 })
        {
            var points = Annotation.CurvedArrowPolygon(from, to, width, bend)!;
            var tip = Array.IndexOf(points, to);
            Assert.IsTrue(tip >= 3);
            var shaft = Heading(points[tip - 3], points[tip + 3]);
            var across = Heading(points[tip - 1], points[tip + 1]);
            var neck = new PointD((points[tip - 2].X + points[tip + 2].X) / 2, (points[tip - 2].Y + points[tip + 2].Y) / 2);
            Assert.IsTrue(Angle(new VectorD(to.X - neck.X, to.Y - neck.Y), shaft) > 15);
            Assert.IsTrue(Angle(across, shaft) < 3);
        }
    }

    [TestMethod]
    public void CurvedArrowIsAlwaysDrawnInsideItsBounds()
    {
        // 弯过的粗箭头被拖短（弦 10、弧线鼓出 18）：箭头缩短照样沿弧线画，和外框、点中对得上
        var degenerate = Segment(AnnotationKind.Arrow, new PointD(100, 100), new PointD(110, 100), new VectorD(0, 1.8), 2);
        var polygon = Annotation.CurvedArrowPolygon(new PointD(100, 100), new PointD(110, 100), 6, new VectorD(0, 1.8))!;
        Assert.IsTrue(polygon.Max(point => point.Y) > 112);
        Assert.IsTrue(degenerate.Contains(new PointD(105, 118), 1));
        Assert.IsTrue(Annotation.PolygonContains(polygon, new PointD(104, 115)));
        Assert.AreEqual(2, degenerate.Handles(1).Count);
        // 各种弯法、粗细：画出来的都在外框里（点中先按外框排除，不能排掉画出来的部分）
        foreach (var weight in new[] { 0, 1, 2 })
        {
            foreach (var length in new[] { 10.0, 32, 80, 400 })
            {
                foreach (var bend in new[]
                         {
                             new VectorD(0, 0.03), new VectorD(0.25, 0.05), new VectorD(-0.25, -0.2),
                             new VectorD(0.1, 0.6), new VectorD(0.25, 1.5), new VectorD(0, -3),
                         })
                {
                    var (from, to) = (new PointD(20, 30), new PointD(20 + length * 0.6, 30 + length * 0.8));
                    var arrow = Segment(AnnotationKind.Arrow, from, to, bend, weight);
                    var drawn = Annotation.ArrowOutline(from, to, arrow.Style.LineWidth, bend)!;
                    var bounds = arrow.Bounds(1);
                    Assert.IsTrue(
                        drawn.All(point => point.X >= bounds.X - 1e-6 && point.X <= bounds.Right + 1e-6 &&
                                           point.Y >= bounds.Y - 1e-6 && point.Y <= bounds.Bottom + 1e-6),
                        $"{weight} {length} {bend}");
                }
            }
        }
    }

    [TestMethod]
    public void StylesAreRememberedPerTool()
    {
        // 5b（Y8）：第一次红色中号、荧光笔黄色；记过的读回来；坏的、越界的用默认
        var saved = new Dictionary<string, string>();
        Assert.AreEqual(AnnotationStyle.Default, AnnotationStyle.Remembered(saved, AnnotationKind.Arrow));
        Assert.AreEqual(AnnotationPalette.Yellow, AnnotationStyle.Remembered(null, AnnotationKind.Highlighter).Color);
        AnnotationStyle.Remember(saved, AnnotationKind.Text, new AnnotationStyle(5, 2, 2));
        AnnotationStyle.Remember(saved, AnnotationKind.Arrow, new AnnotationStyle(4, 1, 0));
        Assert.AreEqual(new AnnotationStyle(5, 2, 2), AnnotationStyle.Remembered(saved, AnnotationKind.Text));
        Assert.AreEqual(4, AnnotationStyle.Remembered(saved, AnnotationKind.Arrow).Color);
        Assert.AreEqual(AnnotationStyle.Default, AnnotationStyle.Remembered(saved, AnnotationKind.Rectangle));
        CollectionAssert.AreEquivalent(new[] { "text", "arrow" }, saved.Keys.ToArray());
        Assert.AreEqual("5,2,2", saved["text"]);
        saved["arrow"] = "9,1,0";
        saved["rectangle"] = "1,1,5"; // 矩形只有两个选项
        saved["pen"] = "乱码";
        Assert.AreEqual(AnnotationStyle.Default, AnnotationStyle.Remembered(saved, AnnotationKind.Arrow));
        Assert.AreEqual(AnnotationStyle.Default, AnnotationStyle.Remembered(saved, AnnotationKind.Rectangle));
        Assert.AreEqual(AnnotationStyle.Default, AnnotationStyle.Remembered(saved, AnnotationKind.Pen));
    }

    [TestMethod]
    public void CounterPlacedLiveRecordsOneStep()
    {
        // 5b：单击放序号先不记撤销，接着拖、松手一共一步
        var document = new AnnotationDocument();
        var before = document.Items;
        var counter = new Annotation { Kind = AnnotationKind.Counter, Number = 1, From = new PointD(10, 10) };
        document.AppendLive(counter);
        document.Replace(counter.Offset(5, 5));
        Assert.IsTrue(document.RecordUndo(before));
        Assert.IsTrue(document.Undo());
        Assert.AreEqual(0, document.Items.Count);
        Assert.IsFalse(document.CanUndo);

        // 5c：Alt 单击没拖开——副本放上去又退回，不留东西、不占撤销
        document.Commit(new[] { counter });
        before = document.Items;
        document.AppendLive(counter.Duplicated(0, 0));
        document.Restore(before);
        Assert.IsFalse(document.RecordUndo(before));
        Assert.AreEqual(1, document.Items.Count);
    }

    [TestMethod]
    public void OldHistoryDataStillReads()
    {
        // 第一版存的：没有 palette / weight，颜色是那套 9 色、线宽 2 / 3 / 5 / 8，箭头是 points 的头尾
        const string json =
            "[{\"tool\":\"arrow\",\"rect\":[0,0,0,0],\"points\":[[1,2],[30,40]],\"text\":\"\",\"color\":\"#FF3C82F0\",\"width\":8}," +
            "{\"tool\":\"rectangle\",\"rect\":[5,6,7,8],\"points\":[],\"text\":\"\",\"color\":\"#FFFF4D7E\",\"width\":3}," +
            "{\"tool\":\"text\",\"rect\":[9,9,0,0],\"points\":[],\"text\":\"旧字\",\"color\":\"#FFFFFFFF\",\"width\":2}," +
            "{\"tool\":\"select\",\"rect\":[0,0,0,0]}]";
        var back = ShotHistoryRules.DecodeAnnotations(json).Select(item => ShotHistoryRules.FromData(item, 0, 0)).ToList();
        Assert.AreEqual(4, back.Count);
        Assert.AreEqual(new PointD(1, 2), back[0]!.From);
        Assert.AreEqual(new PointD(30, 40), back[0]!.To);
        Assert.AreEqual(5, back[0]!.Style.Color); // 旧的蓝 → 蓝
        Assert.AreEqual(2, back[0]!.Style.Weight); // 8 → 粗
        Assert.AreEqual(AnnotationPalette.Pink, back[1]!.Style.Color);
        Assert.AreEqual(1, back[1]!.Style.Weight); // 3 → 中
        Assert.AreEqual(new RectD(5, 6, 7, 8), back[1]!.Rect);
        Assert.AreEqual("旧字", back[2]!.Text);
        Assert.AreEqual(AnnotationPalette.White, back[2]!.Style.Color);
        Assert.IsNull(back[3]); // 认不得的工具跳过
    }
}
