// 0.1.1 功能图标：路径数据解析（PathData）。FeatureIcons.cs 链接进来，26 个图标全要解析得了、坐标都在 24 格里。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PathDataTests
{
    private static readonly string[] Icons =
    {
        FeatureIcons.About, FeatureIcons.Clipboard, FeatureIcons.Clothesline, FeatureIcons.DockPreview,
        FeatureIcons.General, FeatureIcons.Home, FeatureIcons.Hotkeys, FeatureIcons.Island, FeatureIcons.Launcher,
        FeatureIcons.Launchpad, FeatureIcons.NotesCapture, FeatureIcons.NotesNew, FeatureIcons.Notes, FeatureIcons.Pin,
        FeatureIcons.RecordAudio, FeatureIcons.Record, FeatureIcons.ScreenshotHistory, FeatureIcons.ScreenshotLast,
        FeatureIcons.Screenshot, FeatureIcons.ScreenshotText, FeatureIcons.StatusScreen, FeatureIcons.TranslateInput,
        FeatureIcons.TranslateReplace, FeatureIcons.TranslateScreenshot, FeatureIcons.TranslateSelection,
        FeatureIcons.Translate,
    };

    [TestMethod]
    public void ParsesEveryFeatureIconInsideTheGrid()
    {
        Assert.AreEqual(26, Icons.Distinct().Count());
        foreach (var icon in Icons)
        {
            var parsed = PathData.Parse(icon);
            Assert.IsTrue(parsed.NonZero);
            Assert.IsTrue(parsed.Figures.Count > 0);
            foreach (var figure in parsed.Figures)
            {
                Assert.IsTrue(figure.Segments.Count > 0);
                InGrid(figure.StartX, figure.StartY);
                foreach (var segment in figure.Segments)
                {
                    InGrid(segment.X1, segment.Y1);
                    if (segment.Command != PathCommand.Line)
                    {
                        InGrid(segment.X2, segment.Y2);
                    }

                    if (segment.Command == PathCommand.Cubic)
                    {
                        InGrid(segment.X3, segment.Y3);
                    }
                }
            }
        }
    }

    [TestMethod]
    public void ReadsEveryCommandAndFillRule()
    {
        var parsed = PathData.Parse("F1 M1 2L3 4Q5 6 7 8C9 10 11 12 13 14ZM0.5,-1.5 2e1 3Z");
        Assert.IsTrue(parsed.NonZero);
        Assert.AreEqual(2, parsed.Figures.Count);
        var first = parsed.Figures[0];
        Assert.AreEqual((1d, 2d), (first.StartX, first.StartY));
        Assert.IsTrue(first.Closed);
        CollectionAssert.AreEqual(
            new[]
            {
                new PathSegmentData(PathCommand.Line, 3, 4),
                new PathSegmentData(PathCommand.Quadratic, 5, 6, 7, 8),
                new PathSegmentData(PathCommand.Cubic, 9, 10, 11, 12, 13, 14),
            },
            first.Segments.ToArray());
        // M 后面连写的坐标续成直线；逗号、负数、指数都认。
        var second = parsed.Figures[1];
        Assert.AreEqual((0.5, -1.5), (second.StartX, second.StartY));
        CollectionAssert.AreEqual(new[] { new PathSegmentData(PathCommand.Line, 20, 3) }, second.Segments.ToArray());
        Assert.IsFalse(PathData.Parse("M0 0L1 1").NonZero);
    }

    [TestMethod]
    public void AfterCloseWithoutMoveStartsAtTheSameStart()
    {
        var parsed = PathData.Parse("F1 M2 3L4 5ZL6 7");
        Assert.AreEqual(2, parsed.Figures.Count);
        Assert.AreEqual((2d, 3d), (parsed.Figures[1].StartX, parsed.Figures[1].StartY));
        Assert.IsFalse(parsed.Figures[1].Closed);
    }

    [TestMethod]
    public void RejectsCommandsTheGeneratorNeverWrites()
    {
        foreach (var data in new[] { "F1 m1 2l3 4", "F1 M1 2H5", "F1 M1 2A1 1 0 0 1 3 4", "F1 1 2", "F1 M1 x" })
        {
            Assert.ThrowsExactly<FormatException>(() => PathData.Parse(data), data);
        }
    }

    private static void InGrid(double x, double y)
        => Assert.IsTrue(x is >= 0 and <= 24 && y is >= 0 and <= 24, $"({x}, {y}) 出了 24 格");
}
