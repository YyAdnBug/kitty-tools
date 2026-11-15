// PLAN-v20 E1：截图框选时指针下面的元素一层层（照 mac ElementFinder 的 layers / step 单测的意思）：从小到大、最后是整扇窗口；
// 夹进窗口、太小的不要、几乎一样大的并成一层；滚轮换层夹在两头。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ElementLayersTests
{
    private static readonly (int, int, int, int) Window = (100, 100, 1100, 800);

    [TestMethod]
    public void SmallestFirstWindowLast()
    {
        var elements = new[]
        {
            (100, 140, 300, 800), // 侧栏
            (110, 200, 290, 230), // 侧栏里的一项
            (120, 205, 140, 225), // 那一项的图标
            (300, 140, 1100, 800), // 右边的内容（指针不在里面）
        };
        var layers = ElementLayers.At(125, 210, Window, elements);
        CollectionAssert.AreEqual(new[] { (120, 205, 140, 225), (110, 200, 290, 230), (100, 140, 300, 800), Window }, layers);
    }

    [TestMethod]
    public void ClipsTinyAndAlmostSameLayers()
    {
        var elements = new[]
        {
            (50, 50, 400, 400), // 伸出窗口：夹成 (100,100,400,400)
            (101, 101, 399, 399), // 和上一层差 1 像素：并成一层
            (200, 200, 204, 204), // 太小
            (100, 100, 1100, 800), // 和窗口一样大：并进窗口那一层
        };
        var layers = ElementLayers.At(202, 202, Window, elements);
        CollectionAssert.AreEqual(new[] { (100, 100, 400, 400), Window }, layers);
        CollectionAssert.AreEqual(new[] { Window }, ElementLayers.At(50, 50, Window, elements), "指针在窗口外：只有窗口");
        CollectionAssert.AreEqual(new[] { Window }, ElementLayers.At(500, 500, Window, Array.Empty<(int, int, int, int)>()), "还没读到元素：只有窗口");
    }

    [TestMethod]
    public void StepStaysInside()
    {
        Assert.AreEqual(1, ElementLayers.Step(0, 1, 3));
        Assert.AreEqual(2, ElementLayers.Step(2, 1, 3), "最大到整扇窗口");
        Assert.AreEqual(0, ElementLayers.Step(0, -1, 3), "最小到最里面那层");
        Assert.AreEqual(0, ElementLayers.Step(5, 1, 0));
    }
}
