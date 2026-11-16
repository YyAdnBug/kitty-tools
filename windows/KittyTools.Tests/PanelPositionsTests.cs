// 翻译浮窗「跟随鼠标」两边同存 mouse（REVIEW R83）：旧的 pointer 读设置时换掉；同步表里 mouse 往返不变，pointer 不再发得出去。
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PanelPositionsTests
{
    [TestMethod]
    public void OldPointerBecomesMouse()
    {
        Assert.AreEqual("mouse", PanelPositions.Normalize("pointer"));
        Assert.AreEqual("mouse", PanelPositions.Normalize("mouse"));
        Assert.AreEqual("last", PanelPositions.Normalize("last"));
        Assert.AreEqual("top", PanelPositions.Normalize("top"));
        Assert.AreEqual("top", PanelPositions.Normalize(null));
        Assert.AreEqual("top", PanelPositions.Normalize("cursor"));
    }

    [TestMethod]
    public void TranslatePositionRoundTripsWithMac()
    {
        var key = SettingsSyncMap.Shared.Single(item => item.Field == "TranslateWindowPosition");
        // Windows 选了跟随鼠标：发出去 mac 认得的 mouse，mac 发来的 mouse 收下还是 mouse
        var wire = key.Outgoing(SettingValue.Of(PanelPositions.Normalize("pointer")));
        Assert.IsNotNull(wire);
        Assert.AreEqual("mouse", key.Incoming(wire)!.Text);
        Assert.AreEqual(PanelPositions.Mouse, PanelPositions.Normalize(key.Incoming(SettingValue.Of("mouse").Encode())!.Text));
        // 万一还是旧写法 pointer：发出去也换成 mouse；对面发来 pointer（不是 mac 的值）不收
        Assert.AreEqual(SettingValue.Of("mouse").Encode(), key.Outgoing(SettingValue.Of("pointer")));
        Assert.IsNull(key.Incoming(SettingValue.Of("pointer").Encode()));
    }
}

/// <summary>框选吸附（REVIEW R87）：竖边吸 x、横边吸 y。</summary>
[TestClass]
public sealed class SnapEdgesTests
{
    [TestMethod]
    public void GuidesOnlyWhereTheSelectionLands()
    {
        // REVIEW G7：吸上的边真落在选区边上才画参考线（锁比例时另一边由比例定，吸的那条可能没落上）
        var edges = RegionMath.SnapEdges(1920, 1080, new[] { (300.0, 200.0, 900.0, 700.0) });
        var snapped = RegionMath.SnapPointWithEdges(903, 650, edges, 6);
        Assert.AreEqual((900.0, 650.0, (double?)900, (double?)null), snapped);
        Assert.AreEqual(((double?)900, (double?)null), RegionMath.Guides(snapped.EdgeX, snapped.EdgeY, new RectD(100, 100, 800, 550)));
        Assert.AreEqual(((double?)null, (double?)null), RegionMath.Guides(900, 700, new RectD(100, 100, 700, 550)));
    }

    [TestMethod]
    public void SnapsToTheRightKindOfEdge()
    {
        // 屏幕 1920 × 1080，一扇窗口 左 300、上 200、右 900、下 700
        var edges = RegionMath.SnapEdges(1920, 1080, new[] { (300.0, 200.0, 900.0, 700.0) });
        CollectionAssert.AreEqual(new[] { 0.0, 1920, 300, 900 }, edges.X);
        CollectionAssert.AreEqual(new[] { 0.0, 1080, 200, 700 }, edges.Y);
        // 窗口右边、下边吸得上（原来 x 吸的是 {0, 0, 左, 上}，右下角吸不到窗口右边）
        Assert.AreEqual((900.0, 700.0), RegionMath.SnapPoint(903, 696, edges, 6));
        // 屏幕上边吸得上（原来 y 那组里没有 0）
        Assert.AreEqual((500.0, 0.0), RegionMath.SnapPoint(500, 4, edges, 6));
        // 横坐标不会吸到窗口的上边 200（原来 x 那组里有它）
        Assert.AreEqual((203.0, 450.0), RegionMath.SnapPoint(203, 450, edges, 6));
        // 窗口左边、上边
        Assert.AreEqual((300.0, 200.0), RegionMath.SnapPoint(297, 205, edges, 6));
    }
}
