// 翻译卡彗星边框的几何（Core 的 CometPath）：分层叠出来的亮度和 mac 的曲线对得上，光头的位置照角度匀速换算。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class CometPathTests
{
    [TestMethod]
    public void LayersStackUpToTheMacCurve()
    {
        const int count = 16;
        var layers = CometPath.Layers(count);
        Assert.AreEqual(1, layers[^1].Alpha, 1e-9);
        for (var s = -0.35; s <= 0.1; s += 0.001)
        {
            var clear = 1.0;
            foreach (var layer in layers)
            {
                if (s >= layer.Start && s <= layer.Start + layer.Length)
                {
                    clear *= 1 - layer.Alpha;
                }
            }

            Assert.AreEqual(CometPath.Brightness(s), 1 - clear, 1.0 / count, $"s={s}");
        }
    }

    [TestMethod]
    public void LayersAreNested()
    {
        var layers = CometPath.Layers(16);
        for (var k = 1; k < layers.Length; k++)
        {
            Assert.IsTrue(layers[k].Start >= layers[k - 1].Start);
            Assert.IsTrue(layers[k].Start + layers[k].Length <= layers[k - 1].Start + layers[k - 1].Length);
            Assert.IsTrue(layers[k].Length > 0);
        }
    }

    [TestMethod]
    public void TrackOnACircleIsUniform()
    {
        // 圆角取满的正方形就是圆：角度匀速 = 描边上匀速。
        var track = CometPath.HeadTrack(100, 100, 50, 0.3, 64);
        Assert.AreEqual(65, track.Length);
        for (var i = 1; i < track.Length; i++)
        {
            Assert.AreEqual(1.0 / 64, track[i] - track[i - 1], 1e-6);
        }
    }

    [TestMethod]
    public void TrackStartsWhereTheAngleSays()
    {
        // 0 圈 = 正上方：扁卡片上边的正中。
        var track = CometPath.HeadTrack(396, 54, 8, 0, 64);
        var (x, y) = CometPath.PointAt(396, 54, 8, track[0]);
        Assert.AreEqual(0, x, 0.01);
        Assert.AreEqual(-27, y, 0.01);
        Assert.AreEqual(track[0] + 1, track[^1], 1e-9);
    }

    [TestMethod]
    public void FlatCardCrawlsOnLongSidesAndRushesRoundTheEnds()
    {
        var track = CometPath.HeadTrack(396, 54, 8, 0, 64);
        for (var i = 1; i < track.Length; i++)
        {
            Assert.IsTrue(track[i] > track[i - 1]);
        }

        // 第 0 步在上边正中，第 16 步（四分之一圈）在右边正中。
        var top = track[1] - track[0];
        var end = track[17] - track[16];
        Assert.IsTrue(top * 5 < end, $"top={top} end={end}");
    }

    [TestMethod]
    public void PointsLieOnTheBorder()
    {
        for (var s = 0.0; s < 1; s += 0.01)
        {
            var (x, y) = CometPath.PointAt(200, 100, 10, s);
            var dx = Math.Max(Math.Abs(x) - 90, 0);
            var dy = Math.Max(Math.Abs(y) - 40, 0);
            // 到内缩 10 的矩形的距离正好是圆角半径。
            Assert.AreEqual(10, Math.Sqrt(dx * dx + dy * dy) + Math.Min(Math.Max(Math.Abs(x) - 90, Math.Abs(y) - 40), 0), 1e-6, $"s={s}");
        }
    }
}
