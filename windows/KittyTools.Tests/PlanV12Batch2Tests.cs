// PLAN-v12 第 2 批：剪贴板 / 启动器的「面板位置」（mac b923b882 OverlayPanel.placement / relocated）、
// 截图工具栏和录制条靠右（mac 0f83c117 SelectionView.toolbarPlacement alignRight）。长截图控速在 ScrollPacerTests。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV12Batch2Tests
{
    [TestMethod]
    public void PanelPlacement_ThreeChoices()
    {
        Assert.AreEqual(PanelPlacement.Top, MonitorLayout.Placement("top", hasUserFrame: true));
        Assert.AreEqual(PanelPlacement.Pointer, MonitorLayout.Placement("mouse", hasUserFrame: false));
        Assert.AreEqual(PanelPlacement.Last, MonitorLayout.Placement("last", hasUserFrame: true));
        // 没拖过的「上次位置」、认不出来的值都按屏幕上方。
        Assert.AreEqual(PanelPlacement.Top, MonitorLayout.Placement("last", hasUserFrame: false));
        Assert.AreEqual(PanelPlacement.Top, MonitorLayout.Placement(null, hasUserFrame: true));
        Assert.AreEqual(PanelPlacement.Top, MonitorLayout.Placement("pointer", hasUserFrame: true));
    }

    [TestMethod]
    public void Relocate_SameScreenKeepsPlaceOtherScreenKeepsRatio()
    {
        var left = new WorkArea(0, 0, 1920, 1040);
        var right = new WorkArea(1920, 0, 1920 + 2560, 1400);
        // 同一块屏：原样。
        Assert.AreEqual(new PixelRect(300, 200, 720, 400), MonitorLayout.Relocate(300, 200, left, left, 720, 400));
        // 拖到的地方在左屏 1/4、1/4 处，这次鼠标在右屏：右屏同一相对位置。
        Assert.AreEqual(new PixelRect(1920 + 640, 350, 720, 400), MonitorLayout.Relocate(480, 260, left, right, 720, 400));
        // 换算后放不下：夹进工作区。
        Assert.AreEqual(new PixelRect(1200, 640, 720, 400), MonitorLayout.Relocate(1900, 1000, left, left, 720, 400));
    }

    [TestMethod]
    public void Toolbar_AlignsRightBelowAboveAndInside()
    {
        // 下方 10，栏的右边线对齐选区右边线（选区 500..900）。
        Assert.AreEqual((300.0, 510.0, ToolbarSide.Below),
            SelectionChrome.Toolbar(new RectD(500, 200, 400, 300), 600, 40, 40, 1920, 1080, alignRight: true));
        // 翻到上方对齐不变。
        Assert.AreEqual((300.0, 550.0, ToolbarSide.Above),
            SelectionChrome.Toolbar(new RectD(500, 600, 400, 420), 600, 40, 40, 1920, 1080, alignRight: true));
        // 放进选区时离右边 10。
        Assert.AreEqual((1310.0, 1020.0, ToolbarSide.Inside),
            SelectionChrome.Toolbar(new RectD(0, 30, 1920, 1040), 600, 40, 40, 1920, 1080, alignRight: true));
        // 选区比栏窄、贴屏幕左边：夹在屏内 10。
        Assert.AreEqual(10, SelectionChrome.Toolbar(new RectD(0, 100, 100, 100), 600, 40, 0, 1920, 1080, alignRight: true).X);
        // 居中照旧。
        Assert.AreEqual(400, SelectionChrome.Toolbar(new RectD(500, 200, 400, 300), 600, 40, 40, 1920, 1080).X);
    }

    [TestMethod]
    public void RecordHud_AlignsRightWithTheBar()
    {
        // 100%：控制条 300 宽，右边线对齐选区右边（600）。
        var below = HudPlacement.Compute(100, 100, 600, 300, 0, 0, 1920, 1080, 1.0, widthDip: 300, alignRight: true);
        Assert.AreEqual(300, below.X);
        Assert.AreEqual(308, below.Y);
        // 选区占满整屏：贴在选区里面，右边往里收一个间距。
        var inside = HudPlacement.Compute(0, 0, 1920, 1080, 0, 0, 1920, 1080, 1.0, widthDip: 300, alignRight: true);
        Assert.AreEqual(1920 - 300 - 8, inside.X);
        // 选区比条窄、贴着屏幕左边：夹进工作区。
        Assert.AreEqual(0, HudPlacement.Compute(0, 100, 100, 300, 0, 0, 1920, 1080, 1.0, widthDip: 300, alignRight: true).X);
    }
}
