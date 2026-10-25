// 第二版第 3 批：轻提示胶囊宽度生长用的弹簧进度（Core 的 SpringEase），
// 以及 Review R1 的地址白名单之外的几个纯函数边界（胶囊宽度上下限）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SpringEaseTests
{
    [TestMethod]
    public void EndpointsAreExact()
    {
        Assert.AreEqual(0, SpringEase.Progress(0, 0.22), 1e-9);
        Assert.AreEqual(0, SpringEase.Progress(-1, 0.22), 1e-9);
        Assert.AreEqual(1, SpringEase.Progress(1, 0.22), 1e-9);
        Assert.AreEqual(1, SpringEase.Progress(2, 0.22), 1e-9);
    }

    [TestMethod]
    public void OvershootsWithBounceAndSettlesWithout()
    {
        // 有回弹：中途会冲过 1。
        var peak = 0.0;
        for (var t = 0.0; t < 1; t += 0.01)
        {
            peak = Math.Max(peak, SpringEase.Progress(t, 0.22));
        }

        Assert.IsTrue(peak > 1.0, $"peak={peak}");

        // 没有回弹：不超过 1。
        for (var t = 0.0; t < 1; t += 0.01)
        {
            Assert.IsTrue(SpringEase.Progress(t, 0) <= 1.0 + 1e-9);
        }
    }

    [TestMethod]
    public void LerpMovesMonotonicallyForward()
    {
        Assert.AreEqual(36, SpringEase.Lerp(36, 200, 0, 0.22), 1e-9);
        Assert.AreEqual(200, SpringEase.Lerp(36, 200, 1, 0.22), 1e-9);
        var mid = SpringEase.Lerp(36, 200, 0.5, 0.22);
        // 有回弹时中途会略过冲，落在目标附近而不是停在两端。
        Assert.IsTrue(mid > 150 && mid < 250, $"mid={mid}");
    }
}
