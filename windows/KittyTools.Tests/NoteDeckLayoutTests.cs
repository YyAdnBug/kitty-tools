// 屏幕边缘那叠的纯函数（Core/Notes/NoteDeckLayout.cs）的单测，照 mac NoteDeckTests.swift 里测设置、几何、竖排标题、状态机的用例：
// optionsDefaultToTheRegisteredValues、optionsReadStoredAndRejectUnknownValues、tiltGeometry、metricsScaleTogetherOnWholePoints、
// stripFollowsTheLongestTitle、heightBudgetSqueezesThenScrolls、chipsAreFixedSize、pillGrowsWithTheNotes、singleScreenTakesThePreferredEdge、
// joinedEdgeMovesToTheOtherSide、stackedScreensKeepBothEdges、middleOfThreeScreensGetsNothing、chosenDisplayFallsBackToMain、pillFrameHugsTheEdge、
// panelFrameFitsTheNoteAndTheColumn、columnAndNoteStayInsideThePanel、hotZoneReachesTwentyPointsOut、dragNeedsSixtyPercentOfASlot、
// draggingThePillPicksEdgeAndHeight、uprightCharacters、labelRuns、labelsTruncateWithAnEllipsis、pillEntryFansOut、fanCollapses、
// tabsOpenSwitchAndClose、openNoteClosesOnlyWhenAsked、restIgnoresEverythingElse、creatingOpensFromAnywhere、suspendAndYield、showAllWorksWhileOpen、
// alwaysFannedHasNoRest、effectsOfEachTransition、displayNamesAndCrossingScreens。（tabTintKeepsInkReadable 在 NotePaperTests。）
// **坐标换算**：mac 的屏幕坐标原点在主屏左下、y 向上，Windows 在主屏左上、y 向下。下面的屏、矩形、点都照 mac 测试里的数写，
// 经 Mac()/MacPoint() 换过来：主屏高 900，矩形 y_win = 900 − y_mac − 高，点 y_win = 900 − y_mac（x 不变）。mac 只比某一条边的地方
// （maxY、minY）在旁边注释里写了 mac 的数和换算。mac 测试里的屏是「菜单栏 25」，工作区（visibleFrame）在屏的顶上让出 25；
// 「离面板顶多远」的那些（ColumnTop、NoteTop、TabCenter）mac 本来就是从顶往下量的，原样。
// 跳过的：machineStateIsNotRegistered（注册默认值、导出类别是设置层的事）；optionsDefaultToTheRegisteredValues 里和注册默认值比的那一半；
// metricsScaleTogetherOnWholePoints 里的 glyphAdvance 和 labelsTruncateWithAnEllipsis 里拿真字体量的那一段（量字在窗口代码里）；
// shownOnlyWithNotesAndTheSwitch、hintIsTakenOnce、suspensionKinds（NoteEdge）、previewCardTitleOnly（预览卡）；
// 其余的（tabsShowFiveThenAll 起，那叠的模型、面板、按键、焦点、截图里算什么）都要真的仓库或窗口。
using System.Globalization;
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteDeckLayoutTests
{
    private const double MainHeight = 900;

    /// <summary>mac 的矩形（y 向上，主屏高 900）→ Windows 的（y 向下）。</summary>
    private static RectD Mac(double x, double y, double width, double height) => new(x, MainHeight - y - height, width, height);

    private static PointD MacPoint(double x, double y) => new(x, MainHeight - y);

    /// <summary>一块 1440 × 900 的屏（菜单栏 25），mac 的左下角在 (x, y)。</summary>
    private static NoteDeckScreen Screen(string name = "主屏", double x = 0, double y = 0, double width = 1440, double height = 900)
        => new(name, Mac(x, y, width, height), Mac(x, y, width, height - 25));

    private static NoteDeckLayout Layout(int count, int hidden, double longest, double height, NoteDeckOptions? options = null)
        => new(count, hidden, longest, height, options ?? new NoteDeckOptions());

    // ---- 设置 ----

    /// <summary>没存过的都是默认值。</summary>
    [TestMethod]
    public void OptionsDefaultToTheRegisteredValues()
    {
        var options = NoteDeckOptions.Read();
        Assert.AreEqual(new NoteDeckOptions(), options);
        Assert.IsTrue(options.IsEnabled);
        Assert.AreEqual(NoteDeckEdge.Right, options.Edge);
        Assert.AreEqual(NoteDeckDisplay.Main, options.Display);
        Assert.AreEqual(NoteDeckTabStyle.Tabs, options.Style);
        Assert.AreEqual(NoteDeckSize.Standard, options.Size);
        Assert.AreEqual(14, options.Sense);
        Assert.IsFalse(options.AlwaysFanned || options.HidesPill || options.OpensOnHover || options.OverFullScreen);
        Assert.IsTrue(options.ShowsPreview);
        Assert.AreEqual(NoteDeckNoteSize.Medium, options.NoteSize);
        Assert.AreEqual(0.5, options.Position);
        // 存的字和 mac 的偏好一样
        Assert.AreEqual("right", options.Edge.Raw());
        Assert.AreEqual("main", options.Display.Mode.Raw());
        Assert.AreEqual("tabs", options.Style.Raw());
        Assert.AreEqual("standard", options.Size.Raw());
        Assert.AreEqual("medium", options.NoteSize.Raw());
    }

    /// <summary>存了的照读；不在档位里的按默认算（导入的文件、手改的设置）。</summary>
    [TestMethod]
    public void OptionsReadStoredAndRejectUnknownValues()
    {
        var options = NoteDeckOptions.Read(
            enabled: false, edge: "left", display: "all", style: "chips", size: "large", sense: 44, alwaysFanned: true, hidesPill: true,
            preview: false, opensOnHover: true, overFullScreen: true, noteSize: "extraLarge", position: 0.25);
        Assert.IsFalse(options.IsEnabled);
        Assert.AreEqual(NoteDeckEdge.Left, options.Edge);
        Assert.AreEqual(NoteDeckDisplay.All, options.Display);
        Assert.AreEqual(NoteDeckTabStyle.Chips, options.Style);
        Assert.AreEqual(NoteDeckSize.Large, options.Size);
        Assert.AreEqual(44, options.Sense);
        Assert.IsTrue(options.AlwaysFanned && options.HidesPill && !options.ShowsPreview && options.OpensOnHover && options.OverFullScreen);
        Assert.AreEqual(NoteDeckNoteSize.ExtraLarge, options.NoteSize);
        Assert.AreEqual(0.25, options.Position);
        Assert.AreEqual(1.25, options.Size.Scale());
        Assert.AreEqual(0.85, NoteDeckSize.Small.Scale());
        CollectionAssert.AreEqual(
            new[] { (400.0, 320.0), (460.0, 380.0), (560.0, 470.0), (680.0, 560.0) },
            new[] { NoteDeckNoteSize.Small, NoteDeckNoteSize.Medium, NoteDeckNoteSize.Large, NoteDeckNoteSize.ExtraLarge }
                .Select(size => size.Dimensions()).ToList());

        options = NoteDeckOptions.Read(edge: "top", size: "huge", sense: 13, noteSize: "poster", position: 7.5);
        Assert.AreEqual(NoteDeckEdge.Right, options.Edge);
        Assert.AreEqual(NoteDeckSize.Standard, options.Size);
        Assert.AreEqual(14, options.Sense);
        Assert.AreEqual(NoteDeckNoteSize.Medium, options.NoteSize);
        Assert.AreEqual(1, options.Position);
        Assert.AreEqual(0, NoteDeckOptions.Read(position: -3).Position);
        Assert.AreEqual(0.5, NoteDeckOptions.Read(position: double.NaN).Position);
        // 便签这个功能关着：那叠也不出现
        Assert.IsFalse(NoteDeckOptions.Read(featureOn: false).IsEnabled);

        // 指定某一块：要两个键都在；只说「指定」没说是哪块 = 主显示器
        Assert.AreEqual(NoteDeckDisplay.Main, NoteDeckOptions.Read(display: "chosen").Display);
        Assert.AreEqual(NoteDeckDisplay.Named("DELL U2720Q"), NoteDeckOptions.Read(display: "chosen", chosenDisplay: "DELL U2720Q").Display);
        Assert.AreEqual(NoteDeckDisplay.Main, NoteDeckOptions.Read(display: "everywhere", chosenDisplay: "DELL U2720Q").Display);
    }

    /// <summary>标签倾斜：右边缘逆时针、左边缘顺时针，列里打开的那张立正；朝屏幕边多画出去的一截随大小档缩放、够盖住斜出来的缝。</summary>
    [TestMethod]
    public void TiltGeometry()
    {
        Assert.AreEqual(-3, NoteDeckLayout.Tilt(NoteDeckEdge.Right, true));
        Assert.AreEqual(3, NoteDeckLayout.Tilt(NoteDeckEdge.Left, true));
        Assert.AreEqual(0, NoteDeckLayout.Tilt(NoteDeckEdge.Right, false));
        Assert.AreEqual(0, NoteDeckLayout.Tilt(NoteDeckEdge.Left, false));
        Assert.AreEqual(14, new NoteDeckMetrics(1).TiltBleed);
        Assert.AreEqual(12, new NoteDeckMetrics(0.85).TiltBleed);
        Assert.AreEqual(18, new NoteDeckMetrics(1.25).TiltBleed);
        foreach (var size in new[] { NoteDeckSize.Small, NoteDeckSize.Standard, NoteDeckSize.Large })
        {
            var metrics = new NoteDeckMetrics(size.Scale());
            var gap = (metrics.StripMax + metrics.Lap) / 2 * Math.Sin(NoteDeckLayout.Tilt(NoteDeckEdge.Left, true) * Math.PI / 180);
            Assert.IsTrue(metrics.TiltBleed > gap + 2, size.ToString());
        }
    }

    // ---- 尺寸和排法 ----

    /// <summary>三档大小：所有尺寸一起按比例，都是整点；字最小 10。</summary>
    [TestMethod]
    public void MetricsScaleTogetherOnWholePoints()
    {
        var standard = new NoteDeckMetrics(1);
        Assert.AreEqual(12, standard.PillWidth);
        Assert.AreEqual(30, standard.TabWidth);
        Assert.AreEqual(40, standard.Lap);
        Assert.AreEqual(56, standard.StripMin);
        Assert.AreEqual(106, standard.StripMax);
        Assert.AreEqual(36, standard.StripFloor);
        Assert.AreEqual(24, standard.ChipHeight);
        Assert.AreEqual(12, standard.FontSize);
        foreach (var size in new[] { NoteDeckSize.Small, NoteDeckSize.Standard, NoteDeckSize.Large })
        {
            var metrics = new NoteDeckMetrics(size.Scale());
            var values = new[]
            {
                metrics.PillWidth, metrics.PillMinHeight, metrics.PillPadding, metrics.DashWidth, metrics.DashHeight, metrics.DashGap,
                metrics.TabWidth, metrics.Lap, metrics.StripMin, metrics.StripMax, metrics.StripFloor, metrics.LabelPadding,
                metrics.LabelInset, metrics.ChipHeight, metrics.ChipGap, metrics.MoreHeight, metrics.MoreGap, metrics.PlusSize,
                metrics.PlusGap, metrics.FontSize,
            };
            Assert.IsTrue(values.All(value => value == Math.Round(value) && value > 0), size.ToString());
            Assert.IsTrue(metrics.FontSize >= 10);
            Assert.AreEqual(Math.Round(30 * size.Scale(), MidpointRounding.AwayFromZero), metrics.TabWidth);
            Assert.IsTrue(metrics.DashWidth < metrics.PillWidth && metrics.PlusSize <= metrics.TabWidth);
        }

        Assert.AreEqual(26, new NoteDeckMetrics(0.85).TabWidth);
        Assert.AreEqual(50, new NoteDeckMetrics(1.25).Lap);
    }

    /// <summary>带标题的标签：露出的一截 = 最长的标题 + 20，夹在 56–106；每张高 = 那一截 + 压住的 40，相邻两张顶边差一截。</summary>
    [TestMethod]
    public void StripFollowsTheLongestTitle()
    {
        Assert.AreEqual(56, Layout(3, 0, 10, 900).Step);
        Assert.AreEqual(96, Layout(3, 0, 10, 900).ItemHeight);
        Assert.AreEqual(70, Layout(3, 0, 50, 900).Step);
        Assert.AreEqual(110, Layout(3, 0, 50, 900).ItemHeight);
        Assert.AreEqual(106, Layout(3, 0, 300, 900).Step);
        Assert.AreEqual(146, Layout(3, 0, 300, 900).ItemHeight);
        var three = Layout(3, 0, 50, 900);
        Assert.AreEqual(-40, three.Spacing);
        Assert.AreEqual(2 * 70 + 110, three.StackHeight);
        Assert.IsNull(three.Viewport);
        Assert.AreEqual(70, three.Strip(0));
        Assert.AreEqual(110, three.Strip(2)); // 最后一张没人压，整张露着
        Assert.AreEqual(35, three.TabCenter(0));
        Assert.AreEqual(105, three.TabCenter(1));
        Assert.AreEqual(175, three.TabCenter(2));
        // 整列 = 标签 + 最下面的「+」（间隔 10、26 见方）；有「+N」再加间隔 7、高 30
        Assert.AreEqual(286, three.ColumnHeight); // 250 + 10 + 26
        var more = Layout(5, 2, 50, 900);
        Assert.AreEqual(2, more.Hidden);
        Assert.AreEqual(390 + 37 + 36, more.ColumnHeight); // 4 × 70 + 110，「+N」37，「+」36
        Assert.AreEqual(0, Layout(0, 0, 50, 900).StackHeight);
        Assert.IsNull(Layout(0, 0, 50, 900).Viewport);
    }

    /// <summary>一共占的高度不超过屏高的 68%：超了把露出的一截压短，最短 36；还放不下就给一个视口在里面滚。</summary>
    [TestMethod]
    public void HeightBudgetSqueezesThenScrolls()
    {
        // 屏高 600：预算 = 600 × 0.68 − (10 + 26) = 372。5 张、每张想露 106：5 × 106 + 40 = 570 超了
        var squeezed = Layout(5, 0, 300, 600);
        Assert.AreEqual(66, squeezed.Step); // (372 − 40) / 5 向下取整
        Assert.AreEqual(4 * 66 + 106, squeezed.StackHeight);
        Assert.IsTrue(squeezed.StackHeight <= 372);
        Assert.IsNull(squeezed.Viewport);
        // 有「+N」时预算再让出它的 37
        var withMore = Layout(5, 9, 300, 600);
        Assert.AreEqual(59, withMore.Step);
        Assert.IsTrue(withMore.ColumnHeight <= 600 * 0.68);
        // 30 张：压到 36 也放不下——就不压了（按最小的 56 排），标签那一段在视口里滚，整列正好是预算
        var all = Layout(30, 0, 300, 600);
        Assert.AreEqual(56, all.Step);
        Assert.AreEqual(96, all.ItemHeight);
        Assert.AreEqual(29 * 56 + 96, all.StackHeight);
        Assert.AreEqual(372, all.Viewport);
        Assert.AreEqual(372, all.TabsHeight);
        Assert.AreEqual(408, all.ColumnHeight);
        // 大一号：各个数跟着乘 1.25
        var big = Layout(30, 0, 300, 600, new NoteDeckOptions { Size = NoteDeckSize.Large });
        Assert.AreEqual(70, big.Step);
        Assert.AreEqual(120, big.ItemHeight);
        Assert.AreEqual(38, big.TabWidth);
        // 要不要量最长的标题：压到最短也放不下的、只有色块的不用量
        Assert.IsTrue(NoteDeckLayout.MeasuresLongest(5, 0, 600, new NoteDeckOptions()));
        Assert.IsFalse(NoteDeckLayout.MeasuresLongest(30, 0, 600, new NoteDeckOptions()));
        Assert.IsFalse(NoteDeckLayout.MeasuresLongest(5, 0, 600, new NoteDeckOptions { Style = NoteDeckTabStyle.Chips }));
    }

    /// <summary>只有色块：每条 30 × 24、间隔 6，不看标题。</summary>
    [TestMethod]
    public void ChipsAreFixedSize()
    {
        var options = new NoteDeckOptions { Style = NoteDeckTabStyle.Chips };
        var layout = Layout(5, 3, 999, 900, options);
        Assert.AreEqual(24, layout.ItemHeight);
        Assert.AreEqual(30, layout.Step);
        Assert.AreEqual(6, layout.Spacing);
        Assert.AreEqual(4 * 30 + 24, layout.StackHeight);
        Assert.AreEqual(30, layout.Strip(0));
        Assert.AreEqual(217, layout.ColumnHeight); // 144 + 37 + 36
        var small = Layout(2, 0, 0, 900, options with { Size = NoteDeckSize.Small });
        Assert.AreEqual(20, small.ItemHeight);
        Assert.AreEqual(25, small.Step);
        Assert.AreEqual(26, small.TabWidth);
    }

    /// <summary>药丸：一条便签一道色条，最多 14 道，再多的合成一道；条数少时不矮于 28。</summary>
    [TestMethod]
    public void PillGrowsWithTheNotes()
    {
        var metrics = new NoteDeckMetrics(1);
        double Height(int count) => NoteDeckLayout.PillHeight(count, metrics);
        Assert.AreEqual(28, Height(1)); // 12 + 10 = 22 不到 28
        Assert.AreEqual(36, Height(2)); // 12 + 20 + 4
        Assert.AreEqual(92, Height(6)); // 12 + 60 + 20
        Assert.AreEqual(12 + 140 + 52, Height(14));
        Assert.AreEqual(12 + 150 + 56, Height(15));
        Assert.AreEqual(Height(15), Height(20));
        Assert.AreEqual(Height(15), Height(500));
        Assert.AreEqual(119, NoteDeckLayout.PillHeight(6, new NoteDeckMetrics(1.25))); // 16 + 78 + 25
    }

    // ---- 放哪块屏、哪条边 ----

    [TestMethod]
    public void SingleScreenTakesThePreferredEdge()
    {
        var screens = new[] { Screen() };
        CollectionAssert.AreEqual(new[] { new NoteDeckPlacement(0, NoteDeckEdge.Right) }, NoteDeckLayout.Placements(screens, new NoteDeckOptions()));
        var left = new NoteDeckOptions { Edge = NoteDeckEdge.Left };
        CollectionAssert.AreEqual(new[] { new NoteDeckPlacement(0, NoteDeckEdge.Left) }, NoteDeckLayout.Placements(screens, left));
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(0, NoteDeckEdge.Left) }, NoteDeckLayout.Placements(screens, left with { Display = NoteDeckDisplay.All }));
        Assert.AreEqual(0, NoteDeckLayout.Placements(Array.Empty<NoteDeckScreen>(), left).Count);
    }

    /// <summary>左右相接：相接的那条边不放、换到另一侧。</summary>
    [TestMethod]
    public void JoinedEdgeMovesToTheOtherSide()
    {
        var screens = new[] { Screen(), Screen("副屏", x: 1440) };
        Assert.IsTrue(NoteDeckLayout.IsJoined(NoteDeckEdge.Right, 0, screens));
        Assert.IsFalse(NoteDeckLayout.IsJoined(NoteDeckEdge.Left, 0, screens));
        Assert.IsTrue(NoteDeckLayout.IsJoined(NoteDeckEdge.Left, 1, screens));
        Assert.IsFalse(NoteDeckLayout.IsJoined(NoteDeckEdge.Right, 1, screens));
        var options = new NoteDeckOptions();
        CollectionAssert.AreEqual(new[] { new NoteDeckPlacement(0, NoteDeckEdge.Left) }, NoteDeckLayout.Placements(screens, options));
        options = options with { Display = NoteDeckDisplay.All };
        var both = new[] { new NoteDeckPlacement(0, NoteDeckEdge.Left), new NoteDeckPlacement(1, NoteDeckEdge.Right) };
        CollectionAssert.AreEqual(both, NoteDeckLayout.Placements(screens, options));
        CollectionAssert.AreEqual(both, NoteDeckLayout.Placements(screens, options with { Edge = NoteDeckEdge.Left }));
        // 副屏在左边
        var mirrored = new[] { Screen(), Screen("副屏", x: -1440) };
        CollectionAssert.AreEqual(new[] { new NoteDeckPlacement(0, NoteDeckEdge.Right) }, NoteDeckLayout.Placements(mirrored, new NoteDeckOptions()));
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(0, NoteDeckEdge.Right) }, NoteDeckLayout.Placements(mirrored, new NoteDeckOptions { Edge = NoteDeckEdge.Left }));
    }

    /// <summary>上下相接不碍左右两条边；斜着摆（纵向没有重叠）也不算相接；只错开一部分算。</summary>
    [TestMethod]
    public void StackedScreensKeepBothEdges()
    {
        var stacked = new[] { Screen(), Screen("上面", y: 900) };
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(0, NoteDeckEdge.Right), new NoteDeckPlacement(1, NoteDeckEdge.Right) },
            NoteDeckLayout.Placements(stacked, new NoteDeckOptions { Display = NoteDeckDisplay.All }));
        var diagonal = new[] { Screen(), Screen("右上", x: 1440, y: 900) };
        Assert.IsFalse(NoteDeckLayout.IsJoined(NoteDeckEdge.Right, 0, diagonal));
        var offset = new[] { Screen(), Screen("错开", x: 1440, y: 600) };
        Assert.IsTrue(NoteDeckLayout.IsJoined(NoteDeckEdge.Right, 0, offset));
        Assert.IsTrue(NoteDeckLayout.IsJoined(NoteDeckEdge.Left, 1, offset));
    }

    /// <summary>三块屏一排：中间那块两侧都相接，不放。</summary>
    [TestMethod]
    public void MiddleOfThreeScreensGetsNothing()
    {
        var screens = new[] { Screen(), Screen("左", x: -1440), Screen("右", x: 1440) };
        Assert.IsNull(NoteDeckLayout.FreeEdge(0, screens, NoteDeckEdge.Right));
        Assert.AreEqual(0, NoteDeckLayout.Placements(screens, new NoteDeckOptions()).Count);
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(1, NoteDeckEdge.Left), new NoteDeckPlacement(2, NoteDeckEdge.Right) },
            NoteDeckLayout.Placements(screens, new NoteDeckOptions { Display = NoteDeckDisplay.All }));
    }

    /// <summary>指定某一块：按名字认；它没接着时退回主显示器。</summary>
    [TestMethod]
    public void ChosenDisplayFallsBackToMain()
    {
        var screens = new[] { Screen(), Screen("DELL", y: 900) };
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(1, NoteDeckEdge.Right) },
            NoteDeckLayout.Placements(screens, new NoteDeckOptions { Display = NoteDeckDisplay.Named("DELL") }));
        CollectionAssert.AreEqual(
            new[] { new NoteDeckPlacement(0, NoteDeckEdge.Right) },
            NoteDeckLayout.Placements(screens, new NoteDeckOptions { Display = NoteDeckDisplay.Named("拔掉的那块") }));
    }

    // ---- 位置 ----

    /// <summary>药丸本身（PLAN-v16 V1，mac NoteDeckPill.draw）：感应范围那块里贴边隔 1、12 宽，高同那块；大一号的 15 宽。</summary>
    [TestMethod]
    public void PillBodySitsOnePointInFromTheEdge()
    {
        var screen = Screen();
        var options = new NoteDeckOptions();
        var metrics = new NoteDeckMetrics(1);
        var right = NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 6, options);
        Assert.AreEqual(new RectD(1440 - 1 - 12, right.Y, 12, right.Height), NoteDeckLayout.PillBody(right, NoteDeckEdge.Right, metrics));
        var left = NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Left, 6, options with { Sense = 44 });
        Assert.AreEqual(new RectD(1, left.Y, 12, left.Height), NoteDeckLayout.PillBody(left, NoteDeckEdge.Left, metrics));
        // 感应范围 8（窗口 13 宽）照样画得下整条药丸
        var narrow = NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 1, options with { Sense = 8 });
        Assert.AreEqual(12, NoteDeckLayout.PillBody(narrow, NoteDeckEdge.Right, metrics).Width);
        Assert.AreEqual(15, NoteDeckLayout.PillBody(left, NoteDeckEdge.Left, new NoteDeckMetrics(1.25)).Width);
    }

    /// <summary>药丸那块窗口：贴着工作区的边，宽 = 感应范围，高 = 药丸高；纵向 0 = 最上、1 = 最下（各留 8）。</summary>
    [TestMethod]
    public void PillFrameHugsTheEdge()
    {
        var screen = Screen(); // 工作区 y 25…900（mac 0…875）
        var options = new NoteDeckOptions();
        var frame = NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 6, options);
        Assert.AreEqual(14, frame.Width);
        Assert.AreEqual(92, frame.Height);
        Assert.AreEqual(1440, frame.Right);
        // mac：顶 = 875 − 8 − 92 = 775，底 = 8，正中 775 − 767 / 2 = 391.5 取整 392（minY）→ y_win = 900 − 392 − 92 = 416
        Assert.AreEqual(Mac(1426, 392, 14, 92), frame);
        frame = NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Left, 6, options);
        Assert.AreEqual(0, frame.X);
        Assert.AreEqual(14, frame.Width);
        // mac maxY == 867 → 顶边 y_win = 900 − 867 = 33
        Assert.AreEqual(900 - 867, NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 6, options with { Position = 0 }).Y);
        // mac minY == 8 → 底边 y_win = 900 − 8 = 892
        Assert.AreEqual(900 - 8, NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 6, options with { Position = 1 }).Bottom);
        // 感应范围 44：窗口就那么宽；8 比药丸（12）还窄：窗口至少装得下药丸
        Assert.AreEqual(44, NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 1, options with { Sense = 44 }).Width);
        Assert.AreEqual(13, NoteDeckLayout.PillFrame(screen, NoteDeckEdge.Right, 1, options with { Sense = 8 }).Width);
        // 工作区右边让出一截（任务栏在右边）时贴的是工作区的边
        var docked = screen with { WorkArea = screen.WorkArea with { Width = 1380 } };
        Assert.AreEqual(1380, NoteDeckLayout.PillFrame(docked, NoteDeckEdge.Right, 1, new NoteDeckOptions()).Right);
    }

    /// <summary>那叠的面板：贴边，宽 = 便签宽 + 间隔 8 + 标签列 30 + 余量 40，高 = 工作区高。</summary>
    [TestMethod]
    public void PanelFrameFitsTheNoteAndTheColumn()
    {
        var screen = Screen();
        var options = new NoteDeckOptions();
        Assert.AreEqual(Mac(1440 - 538, 0, 538, 875), NoteDeckLayout.PanelFrame(screen, NoteDeckEdge.Right, options));
        var left = NoteDeckLayout.PanelFrame(screen, NoteDeckEdge.Left, options);
        Assert.AreEqual(0, left.X);
        Assert.AreEqual(538, left.Width);
        var large = options with { NoteSize = NoteDeckNoteSize.ExtraLarge, Size = NoteDeckSize.Large };
        Assert.AreEqual(766, NoteDeckLayout.PanelFrame(screen, NoteDeckEdge.Right, large).Width); // 680 + 8 + 38 + 40
        // 屏幕比它还窄：不超出工作区
        Assert.AreEqual(600, NoteDeckLayout.PanelFrame(Screen(width: 600), NoteDeckEdge.Right, large).Width);
    }

    /// <summary>标签列对着药丸的中线居中、夹在面板里；打开的便签对着它那张标签居中、夹在面板里（都是离面板顶的距离，和 mac 一样）。</summary>
    [TestMethod]
    public void ColumnAndNoteStayInsideThePanel()
    {
        Assert.AreEqual(287, NoteDeckLayout.ColumnTop(437, 300, 875));
        Assert.AreEqual(12, NoteDeckLayout.ColumnTop(30, 300, 875));
        Assert.AreEqual(563, NoteDeckLayout.ColumnTop(860, 300, 875));
        Assert.AreEqual(12, NoteDeckLayout.ColumnTop(100, 900, 875));
        Assert.AreEqual(210, NoteDeckLayout.NoteTop(400, 380, 875));
        Assert.AreEqual(10, NoteDeckLayout.NoteTop(50, 380, 875));
        Assert.AreEqual(485, NoteDeckLayout.NoteTop(860, 380, 875));
        Assert.AreEqual((460.0, 380.0), NoteDeckLayout.NoteSize((460, 380), (538, 875), 30));
        // 小屏幕：便签夹进面板（上下各留 10，旁边让出标签列和间隔）
        Assert.AreEqual((462.0, 380.0), NoteDeckLayout.NoteSize((680, 560), (500, 400), 30));
        // 打开的便签、标签列落在屏幕上的哪：顶离面板顶 top（y 向下直接加）
        var panel = Mac(902, 0, 538, 875);
        Assert.AreEqual(new RectD(902 + 538 - 38 - 460, panel.Y + 210, 460, 380), NoteDeckLayout.NoteFrame(panel, NoteDeckEdge.Right, 210, (460, 380), 30));
        Assert.AreEqual(new RectD(902 + 38, panel.Y + 210, 460, 380), NoteDeckLayout.NoteFrame(panel, NoteDeckEdge.Left, 210, (460, 380), 30));
        Assert.AreEqual(new RectD(1440 - 30, panel.Y + 287, 30, 300), NoteDeckLayout.ColumnFrame(panel, NoteDeckEdge.Right, 287, 300, 30));
    }

    /// <summary>热区：标签列四周再往外 20；预览卡出着时连它一起算。</summary>
    [TestMethod]
    public void HotZoneReachesTwentyPointsOut()
    {
        var panel = Mac(902, 0, 538, 875);
        var zone = NoteDeckLayout.HotZone(panel, NoteDeckEdge.Right, 200, 300, 30, false);
        Assert.AreEqual(Mac(1390, 355, 70, 340), zone); // = (1390, 205, 70, 340)
        Assert.IsTrue(zone.Contains(MacPoint(1395, 500)));
        Assert.IsFalse(zone.Contains(MacPoint(1385, 500)));
        Assert.IsTrue(zone.Contains(MacPoint(1430, 360)));
        Assert.IsFalse(zone.Contains(MacPoint(1430, 350)));
        zone = NoteDeckLayout.HotZone(panel, NoteDeckEdge.Right, 200, 300, 30, true);
        Assert.AreEqual(1440 - 30 - 10 - 220 - 20, zone.X);
        Assert.IsTrue(zone.Contains(MacPoint(1200, 500)));
        zone = NoteDeckLayout.HotZone(Mac(0, 0, 538, 875), NoteDeckEdge.Left, 200, 300, 30, false);
        Assert.AreEqual(Mac(-20, 355, 70, 340), zone);
    }

    /// <summary>拖动排序：要拖过一格的 60% 才换位，两头夹住（offset 往下为正，mac 也是）。</summary>
    [TestMethod]
    public void DragNeedsSixtyPercentOfASlot()
    {
        int Target(double offset, int from = 2) => NoteDeckLayout.DragTarget(from, offset, 70, 5);
        Assert.AreEqual(2, Target(0));
        Assert.AreEqual(2, Target(35));
        Assert.AreEqual(2, Target(41));
        Assert.AreEqual(3, Target(42));
        Assert.AreEqual(3, Target(69));
        Assert.AreEqual(3, Target(111));
        Assert.AreEqual(4, Target(112));
        Assert.AreEqual(4, Target(1000));
        Assert.AreEqual(2, Target(-41));
        Assert.AreEqual(1, Target(-42));
        Assert.AreEqual(0, Target(-112));
        Assert.AreEqual(0, Target(-1000));
        Assert.AreEqual(4, Target(1000, 0));
        Assert.AreEqual(0, Target(-10, 0));
        Assert.AreEqual(1, NoteDeckLayout.DragTarget(1, 50, 0, 5));
        Assert.AreEqual(0, NoteDeckLayout.DragTarget(0, 50, 70, 0));
    }

    /// <summary>按住修饰键拖药丸：贴鼠标所在那一半的边，高度跟着鼠标；相接的边换另一侧；只有「指定某一块」时能拖到别的屏。</summary>
    [TestMethod]
    public void DraggingThePillPicksEdgeAndHeight()
    {
        var screens = new[] { Screen(), Screen("副屏", x: 1440) };
        (NoteDeckPlacement Placement, double Position)? Drag(double x, double y, int from = 0, bool crosses = false)
            => NoteDeckLayout.Dragged(MacPoint(x, y), screens, from, crosses, 92);

        // 主屏左半边：左边
        var result = Drag(200, 400)!.Value;
        Assert.AreEqual(new NoteDeckPlacement(0, NoteDeckEdge.Left), result.Placement);
        // mac：工作区 0…875，药丸高 92：顶 = 775、底 = 8；鼠标对着药丸的中线。比例（0 = 最上）两边一样
        Assert.AreEqual((775 - (400 - 46)) / 767.0, result.Position, 0.0001);
        // 主屏右半边：右边贴着副屏，换回左边
        Assert.AreEqual(new NoteDeckPlacement(0, NoteDeckEdge.Left), Drag(1300, 400)!.Value.Placement);
        // 拖到最上、最下：夹在 0…1
        Assert.AreEqual(0, Drag(200, 2000)!.Value.Position);
        Assert.AreEqual(1, Drag(200, -500)!.Value.Position);
        // 不许换屏时鼠标到了副屏也还在主屏；许换屏时跟过去
        Assert.AreEqual(new NoteDeckPlacement(0, NoteDeckEdge.Left), Drag(2600, 400)!.Value.Placement);
        Assert.AreEqual(new NoteDeckPlacement(1, NoteDeckEdge.Right), Drag(2600, 400, crosses: true)!.Value.Placement);
        Assert.AreEqual(new NoteDeckPlacement(1, NoteDeckEdge.Right), Drag(1500, 400, crosses: true)!.Value.Placement);
        Assert.IsNull(Drag(100, 100, from: 9));
        // 三块屏一排，从右边那块拖进中间那块（两侧都相接）：留在原来那块
        var row = new[] { Screen(), Screen("左", x: -1440), Screen("右", x: 1440) };
        var stuck = NoteDeckLayout.Dragged(MacPoint(700, 400), row, 2, true, 92)!.Value;
        Assert.AreEqual(new NoteDeckPlacement(2, NoteDeckEdge.Right), stuck.Placement);
        Assert.IsNull(NoteDeckLayout.Dragged(MacPoint(700, 400), row, 0, false, 92));
    }

    // ---- 竖排标题 ----

    private static IEnumerable<string> Characters(string text)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            yield return enumerator.GetTextElement();
        }
    }

    /// <summary>中日韩文字、全角符号、表情正着放；拉丁字母、数字、半角符号转着放。</summary>
    [TestMethod]
    public void UprightCharacters()
    {
        foreach (var character in Characters("买菜あアㄅ한，。！（）「」ＡＢ１🙂✅❤\uFE0F🇨🇳𠮷"))
        {
            Assert.IsTrue(NoteDeckLabel.IsUpright(character), character);
        }

        foreach (var character in Characters("aZ09,.!()-_#é я"))
        {
            Assert.IsFalse(NoteDeckLabel.IsUpright(character), character);
        }
    }

    private static NoteDeckLabel.Run Up(string text) => new(text, true);

    private static NoteDeckLabel.Run Turned(string text) => new(text, false);

    /// <summary>分段：正立的一字一格，别的整段在一起；空白挨着转着放的字就跟着那一段，夹在正立的字中间才是竖着的一格空。</summary>
    [TestMethod]
    public void LabelRuns()
    {
        CollectionAssert.AreEqual(new[] { Up("周"), Up("报") }, NoteDeckLabel.Runs("周报"));
        CollectionAssert.AreEqual(new[] { Turned("Groceries: milk") }, NoteDeckLabel.Runs("Groceries: milk"));
        CollectionAssert.AreEqual(new[] { Up("买"), Turned(" milk "), Up("和"), Up("蛋") }, NoteDeckLabel.Runs("买 milk 和蛋"));
        CollectionAssert.AreEqual(new[] { Up("你"), Up(" "), Up("好") }, NoteDeckLabel.Runs("你 好"));
        CollectionAssert.AreEqual(new[] { Turned("wifi"), Up("密"), Up("码"), Turned("2026") }, NoteDeckLabel.Runs("wifi密码2026"));
        CollectionAssert.AreEqual(new[] { Up("🙂"), Turned("ok") }, NoteDeckLabel.Runs("🙂ok"));
        Assert.AreEqual(0, NoteDeckLabel.Runs(string.Empty).Count);
    }

    /// <summary>排不下从后面截、加「…」：跟在转着的那段后面一起转；前面是正立的字就单独一段。</summary>
    [TestMethod]
    public void LabelsTruncateWithAnEllipsis()
    {
        // 正立的一格 10，转着的一个字 6
        static double Advance(NoteDeckLabel.Run run) => run.IsUpright ? 10 : NoteText.Count(run.Text) * 6;
        List<NoteDeckLabel.Run> Fitted(string title, double limit) => NoteDeckLabel.Fitted(title, limit, Advance);
        static double Length(List<NoteDeckLabel.Run> runs) => runs.Sum(Advance);

        CollectionAssert.AreEqual(NoteDeckLabel.Runs("周报"), Fitted("周报", 20)); // 正好放下：原样
        var cjk = Fitted("一二三四五六七八", 46);
        CollectionAssert.AreEqual(new[] { "一", "二", "三", "四", "…" }, cjk.Select(run => run.Text).ToList());
        Assert.IsFalse(cjk[^1].IsUpright);
        Assert.IsTrue(Length(cjk) <= 46);
        var latin = Fitted("Groceries and more", 50);
        CollectionAssert.AreEqual(new[] { Turned("Groceri…") }, latin);
        Assert.IsTrue(Length(latin) <= 50);
        // 截在空格上：不留「词 …」中间的空格
        CollectionAssert.AreEqual(new[] { Turned("ab…") }, Fitted("ab cd ef", 24));
        CollectionAssert.AreEqual(new[] { Turned("ab c…") }, Fitted("ab cd ef", 30));
        var mixed = Fitted("买 milk 和蛋 bread", 60);
        CollectionAssert.AreEqual(new[] { "买", " milk…" }, mixed.Select(run => run.Text).ToList());
        Assert.IsTrue(Length(mixed) <= 60);
        // 转着的那段一个字都放不下：省略号接在前面正立的字后面
        CollectionAssert.AreEqual(new[] { "买", "菜", "…" }, Fitted("买菜 milk", 26).Select(run => run.Text).ToList());
        // 压得很短、连一个字加省略号都放不下：只留打头的那一截，不加省略号
        CollectionAssert.AreEqual(new[] { Up("周") }, Fitted("周报和别的", 14));
        CollectionAssert.AreEqual(new[] { Turned("G") }, Fitted("Groceries", 11));
        CollectionAssert.AreEqual(new[] { Turned("…") }, Fitted("周报和别的", 5));
        // 整个标题竖着排多长
        Assert.AreEqual(20 + 6 * 4, NoteDeckLabel.Length("周报abcd", Advance));
    }

    // ---- 状态机 ----

    private static NoteDeckState State(params NoteDeckEvent[] events)
    {
        var state = new NoteDeckState();
        foreach (var e in events)
        {
            state.Handle(e);
        }

        return state;
    }

    private static readonly NoteDeckEvent Enter = NoteDeckEvent.PillEntered(false, true);

    private static bool IsOpen(NoteDeckState state, string id) => state.Phase == NoteDeckPhase.Open && state.OpenId == id;

    /// <summary>静置 → 扇出：鼠标进药丸。按着修饰键（要拖它）、这时不许扇出都不扇出。</summary>
    [TestMethod]
    public void PillEntryFansOut()
    {
        var state = new NoteDeckState();
        Assert.IsTrue(state.Phase == NoteDeckPhase.Rest && !state.ShowsAll && !state.IsDragging && state.OpenId is null);
        Assert.IsFalse(state.Handle(NoteDeckEvent.PillEntered(true, true)));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        Assert.IsFalse(state.Handle(NoteDeckEvent.PillEntered(false, false)));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        Assert.IsTrue(state.Handle(Enter));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        Assert.IsFalse(state.Handle(Enter)); // 已经扇着：没变
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
    }

    /// <summary>扇出 → 静置：离开热区、4 秒没动静、Esc / Ctrl+W（Dismiss）；拖着标签排序时不收。鼠标的「关」在只扇着时没有东西可关。</summary>
    [TestMethod]
    public void FanCollapses()
    {
        var fanned = State(Enter);
        Assert.IsFalse(fanned.Handle(NoteDeckEvent.Close));
        Assert.AreEqual(NoteDeckPhase.Fanned, fanned.Phase);
        foreach (var e in new[] { NoteDeckEvent.Left, NoteDeckEvent.Idle, NoteDeckEvent.Dismiss })
        {
            var state = State(Enter, NoteDeckEvent.ShowAll);
            Assert.IsTrue(state.ShowsAll);
            Assert.IsTrue(state.Handle(e), e.Kind.ToString());
            Assert.IsTrue(state.Phase == NoteDeckPhase.Rest && !state.ShowsAll, e.Kind.ToString());
        }

        var dragging = State(Enter, NoteDeckEvent.DragBegan);
        Assert.IsTrue(dragging.IsDragging);
        Assert.IsFalse(dragging.Handle(NoteDeckEvent.Left));
        Assert.IsFalse(dragging.Handle(NoteDeckEvent.Idle));
        Assert.AreEqual(NoteDeckPhase.Fanned, dragging.Phase);
        Assert.IsFalse(dragging.Handle(NoteDeckEvent.Tab("a"))); // 拖着时松手不算点
        Assert.AreEqual(NoteDeckPhase.Fanned, dragging.Phase);
        Assert.IsTrue(dragging.Handle(NoteDeckEvent.DragEnded));
        Assert.IsFalse(dragging.IsDragging);
        Assert.IsTrue(dragging.Handle(NoteDeckEvent.Left));
        Assert.AreEqual(NoteDeckPhase.Rest, dragging.Phase);
    }

    /// <summary>扇出 → 打开：点标签；打开着点另一张 = 换一条，点它自己 = 关（回到扇出）。</summary>
    [TestMethod]
    public void TabsOpenSwitchAndClose()
    {
        var state = State(Enter);
        Assert.IsTrue(state.Handle(NoteDeckEvent.Tab("a")));
        Assert.IsTrue(IsOpen(state, "a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Tab("b")));
        Assert.IsTrue(IsOpen(state, "b"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Tab("b")));
        Assert.IsTrue(state.Phase == NoteDeckPhase.Fanned && state.OpenId is null);
        // 「+N」展开着打开、关掉：还是展开着
        state.Handle(NoteDeckEvent.ShowAll);
        state.Handle(NoteDeckEvent.Tab("z"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Close));
        Assert.IsTrue(state.Phase == NoteDeckPhase.Fanned && state.ShowsAll);
    }

    /// <summary>打开的便签：用鼠标关、归档 / 删除之后回到扇出；用键盘关连那一列一起收回；点别处回到静置，固定的不收；不按时间自己收。</summary>
    [TestMethod]
    public void OpenNoteClosesOnlyWhenAsked()
    {
        var state = State(Enter, NoteDeckEvent.Tab("a"));
        Assert.IsFalse(state.Handle(NoteDeckEvent.Idle));
        Assert.IsFalse(state.Handle(NoteDeckEvent.Left));
        Assert.IsFalse(state.Handle(NoteDeckEvent.ClickedOutside(true)));
        Assert.IsFalse(state.Handle(Enter));
        Assert.IsFalse(state.Handle(NoteDeckEvent.DragBegan));
        Assert.IsTrue(IsOpen(state, "a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Close));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Dismiss));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        state.Handle(Enter);
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.ClickedOutside(false)));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        // 静置、扇出时点别处不关它的事
        Assert.IsFalse(state.Handle(NoteDeckEvent.ClickedOutside(false)));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        state.Handle(Enter);
        Assert.IsFalse(state.Handle(NoteDeckEvent.ClickedOutside(false)));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
    }

    /// <summary>静置时除了鼠标进药丸和新建，别的事都不动它。</summary>
    [TestMethod]
    public void RestIgnoresEverythingElse()
    {
        var state = new NoteDeckState();
        var events = new[]
        {
            NoteDeckEvent.Left, NoteDeckEvent.Idle, NoteDeckEvent.Tab("a"), NoteDeckEvent.ShowAll, NoteDeckEvent.Close, NoteDeckEvent.Dismiss,
            NoteDeckEvent.ClickedOutside(false), NoteDeckEvent.DragBegan, NoteDeckEvent.DragEnded, NoteDeckEvent.Suspend(true),
            NoteDeckEvent.Suspend(false), NoteDeckEvent.Yield(false), NoteDeckEvent.Yield(true),
        };
        foreach (var e in events)
        {
            Assert.IsFalse(state.Handle(e), e.ToString());
            Assert.AreEqual(new NoteDeckState(), state, e.ToString());
        }
    }

    /// <summary>新建一条：从哪种样子都直接打开它。</summary>
    [TestMethod]
    public void CreatingOpensFromAnywhere()
    {
        Assert.IsTrue(IsOpen(State(NoteDeckEvent.Created("n")), "n"));
        Assert.IsTrue(IsOpen(State(Enter, NoteDeckEvent.Created("n")), "n"));
        Assert.IsTrue(IsOpen(State(Enter, NoteDeckEvent.Tab("a"), NoteDeckEvent.Created("n")), "n"));
        var dragging = State(Enter, NoteDeckEvent.DragBegan, NoteDeckEvent.Created("n"));
        Assert.IsTrue(IsOpen(dragging, "n") && !dragging.IsDragging);
    }

    /// <summary>叫停：扇出的收起；打开的要不要收由调用方说。让给别的屏：扇着的收，打开的只收没固定的。</summary>
    [TestMethod]
    public void SuspendAndYield()
    {
        Assert.AreEqual(NoteDeckPhase.Rest, State(Enter, NoteDeckEvent.Suspend(false)).Phase);
        Assert.AreEqual(new NoteDeckState(), State(Enter, NoteDeckEvent.DragBegan, NoteDeckEvent.Suspend(false)));
        Assert.IsTrue(IsOpen(State(Enter, NoteDeckEvent.Tab("a"), NoteDeckEvent.Suspend(false)), "a"));
        Assert.AreEqual(NoteDeckPhase.Rest, State(Enter, NoteDeckEvent.Tab("a"), NoteDeckEvent.Suspend(true)).Phase);
        Assert.AreEqual(NoteDeckPhase.Rest, State(Enter, NoteDeckEvent.Yield(false)).Phase);
        Assert.AreEqual(NoteDeckPhase.Rest, State(Enter, NoteDeckEvent.Yield(true)).Phase);
        Assert.AreEqual(NoteDeckPhase.Rest, State(Enter, NoteDeckEvent.Tab("a"), NoteDeckEvent.Yield(false)).Phase);
        Assert.IsTrue(IsOpen(State(Enter, NoteDeckEvent.Tab("a"), NoteDeckEvent.Yield(true)), "a"));
    }

    /// <summary>「+N」：扇着、便签开着时都能点（列出全部，便签留着）；收回时跟着收起来。</summary>
    [TestMethod]
    public void ShowAllWorksWhileOpen()
    {
        var state = State(Enter, NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.ShowAll));
        Assert.IsTrue(state.ShowsAll && IsOpen(state, "a"));
        Assert.IsFalse(state.Handle(NoteDeckEvent.ShowAll));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Close));
        Assert.IsTrue(state.ShowsAll && state.Phase == NoteDeckPhase.Fanned);
        Assert.IsTrue(state.Handle(NoteDeckEvent.Left));
        Assert.IsFalse(state.ShowsAll);
    }

    /// <summary>「一直展开」：没有静置，收回就是回到扇出那一列（「+N」收起来）；关掉这个设置后照常收。</summary>
    [TestMethod]
    public void AlwaysFannedHasNoRest()
    {
        var state = new NoteDeckState();
        state.SetAlwaysFanned(true);
        Assert.IsTrue(state.Phase == NoteDeckPhase.Fanned && state.AlwaysFanned);
        Assert.IsFalse(state.IsExpanded, "一直展开时静置的那一列不算展开");
        state.Handle(NoteDeckEvent.ShowAll);
        Assert.IsTrue(state.Handle(NoteDeckEvent.Left));
        Assert.IsTrue(state.Phase == NoteDeckPhase.Fanned && !state.ShowsAll);
        Assert.IsFalse(state.Handle(NoteDeckEvent.Idle));
        Assert.IsFalse(state.Handle(NoteDeckEvent.Close));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.IsExpanded);
        Assert.IsTrue(state.Handle(NoteDeckEvent.ClickedOutside(false)));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Suspend(true)));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Yield(false)));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        // 一直展开时用键盘关：没有静置，回到那一列
        state.Handle(NoteDeckEvent.Tab("a"));
        Assert.IsTrue(state.Handle(NoteDeckEvent.Dismiss));
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase);
        state.SetAlwaysFanned(false);
        Assert.AreEqual(NoteDeckPhase.Fanned, state.Phase); // 还扇着，等鼠标离开 / 没动静
        Assert.IsTrue(state.Handle(NoteDeckEvent.Idle));
        Assert.AreEqual(NoteDeckPhase.Rest, state.Phase);
        // 打开着便签时开关这个设置：便签不动
        var open = State(Enter, NoteDeckEvent.Tab("a"));
        open.SetAlwaysFanned(true);
        Assert.IsTrue(IsOpen(open, "a"));
    }

    /// <summary>状态变了该做哪几件事（mac NoteDeck.effects）：只有新打开 / 换了一条才拿键盘、聚焦；任何「打开 → 扇出」都当场把键盘还回去；
    /// 用键盘关的（和点别处）整块收走。</summary>
    [TestMethod]
    public void EffectsOfEachTransition()
    {
        static NoteDeckEffects Effects(NoteDeckState old, NoteDeckEvent e)
        {
            var next = old;
            next.Handle(e);
            return NoteDeckState.EffectsOf(old, next);
        }

        var rest = new NoteDeckState();
        var fanned = State(Enter);
        var open = State(Enter, NoteDeckEvent.Tab("a"));
        Assert.AreEqual(NoteDeckEffects.Expand | NoteDeckEffects.Present | NoteDeckEffects.Watch, Effects(rest, Enter));
        Assert.AreEqual(NoteDeckEffects.Expand | NoteDeckEffects.Present | NoteDeckEffects.Focus, Effects(rest, NoteDeckEvent.Created("n")));
        Assert.AreEqual(NoteDeckEffects.Expand | NoteDeckEffects.Focus, Effects(fanned, NoteDeckEvent.Tab("a")));
        Assert.AreEqual(NoteDeckEffects.Watch, Effects(fanned, NoteDeckEvent.ShowAll));
        Assert.AreEqual(NoteDeckEffects.Hide, Effects(fanned, NoteDeckEvent.Left));
        Assert.AreEqual(NoteDeckEffects.Hide, Effects(fanned, NoteDeckEvent.Dismiss));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.Expand | NoteDeckEffects.Focus, Effects(open, NoteDeckEvent.Tab("b")));
        // 鼠标关、归档 / 删除之后：回到那一列，键盘当场还回去
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.ReleaseKey | NoteDeckEffects.Watch, Effects(open, NoteDeckEvent.Close));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.ReleaseKey | NoteDeckEffects.Watch, Effects(open, NoteDeckEvent.Tab("a")));
        // 键盘关、点别处、被叫停、让位：整块收走
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.Hide, Effects(open, NoteDeckEvent.Dismiss));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.Hide, Effects(open, NoteDeckEvent.ClickedOutside(false)));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.Hide, Effects(open, NoteDeckEvent.Suspend(true)));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.Hide, Effects(open, NoteDeckEvent.Yield(false)));
        // 便签开着时别的变化（「+N」、切「一直展开」）：什么都不做——尤其不许拿键盘
        Assert.AreEqual(NoteDeckEffects.None, Effects(open, NoteDeckEvent.ShowAll));
        var always = open;
        always.SetAlwaysFanned(true);
        Assert.AreEqual(NoteDeckEffects.None, NoteDeckState.EffectsOf(open, always));
        var back = always;
        back.SetAlwaysFanned(false);
        Assert.AreEqual(NoteDeckEffects.None, NoteDeckState.EffectsOf(always, back));
        // 一直展开：静置的直接成了那一列；用键盘关便签回到那一列、键盘还回去；关掉设置后只是重新看着
        var shown = rest;
        shown.SetAlwaysFanned(true);
        Assert.AreEqual(NoteDeckEffects.Expand | NoteDeckEffects.Present | NoteDeckEffects.Watch, NoteDeckState.EffectsOf(rest, shown));
        Assert.AreEqual(NoteDeckEffects.Flush | NoteDeckEffects.ReleaseKey | NoteDeckEffects.Watch, Effects(always, NoteDeckEvent.Dismiss));
        var watched = shown;
        watched.SetAlwaysFanned(false);
        Assert.AreEqual(NoteDeckEffects.Watch, NoteDeckState.EffectsOf(shown, watched));
    }

    /// <summary>显示器同名的加序号；拖药丸只有指定的那块真接着时才能换屏。</summary>
    [TestMethod]
    public void DisplayNamesAndCrossingScreens()
    {
        Assert.AreEqual(0, NoteDeckLayout.UniqueNames(Array.Empty<string>()).Count);
        CollectionAssert.AreEqual(new[] { "内建", "DELL" }, NoteDeckLayout.UniqueNames(new[] { "内建", "DELL" }));
        CollectionAssert.AreEqual(new[] { "DELL", "内建", "DELL 2", "DELL 3" }, NoteDeckLayout.UniqueNames(new[] { "DELL", "内建", "DELL", "DELL" }));
        var screens = new[] { Screen(), Screen("DELL", x: 1440) };
        Assert.IsTrue(NoteDeckLayout.CrossesScreens(NoteDeckDisplay.Named("DELL"), screens));
        Assert.IsFalse(NoteDeckLayout.CrossesScreens(NoteDeckDisplay.Named("拔掉的那块"), screens));
        Assert.IsFalse(NoteDeckLayout.CrossesScreens(NoteDeckDisplay.Main, screens));
        Assert.IsFalse(NoteDeckLayout.CrossesScreens(NoteDeckDisplay.All, screens));
        CollectionAssert.AreEqual(
            new[] { "main", "all", "chosen" },
            new[] { NoteDeckDisplayMode.Main, NoteDeckDisplayMode.All, NoteDeckDisplayMode.Chosen }.Select(mode => mode.Raw()).ToList());
        CollectionAssert.AreEqual(
            new[] { "tabs", "chips" }, new[] { NoteDeckTabStyle.Tabs, NoteDeckTabStyle.Chips }.Select(style => style.Raw()).ToList());
        Assert.AreEqual("右", NoteDeckEdge.Right.Title());
        Assert.AreEqual(NoteDeckEdge.Left, NoteDeckEdge.Right.Opposite());
    }
}
