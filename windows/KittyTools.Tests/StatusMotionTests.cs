// REVIEW R107：状态屏的几处动效的纯函数——标题逐字的时间表、小字整行排一次再切开（切在哪、滚不滚、冒号抬多高）、
// 选状态的卡片长成整屏（哪块屏、每一刻占哪、圆角）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class StatusMotionTests
{
    [TestMethod]
    public void GlyphsStartOneAfterAnother()
    {
        var entrance = new StatusEntrance(4);
        Assert.AreEqual(StatusEntrance.TitleStart, entrance.GlyphStart(0), 1e-9);
        Assert.AreEqual(StatusEntrance.TitleStart + 3 * StatusEntrance.Stagger, entrance.GlyphStart(3), 1e-9);
        Assert.AreEqual(entrance.GlyphStart(3), entrance.GlyphStart(9), 1e-9, "字形比字数多：跟最后一个字一起");
        Assert.AreEqual(0, entrance.Glyph(1, entrance.GlyphStart(1)), 1e-9);
        Assert.AreEqual(1, entrance.Glyph(1, entrance.GlyphStart(1) + StatusEntrance.GlyphSpan), 1e-9);

        // 30 个字：整个标题在 0.9 秒内都开始浮现
        var longTitle = new StatusEntrance(30);
        Assert.AreEqual(StatusEntrance.TitleStart + StatusEntrance.StaggerLimit, longTitle.GlyphStart(29), 1e-9);
        Assert.IsTrue(longTitle.GlyphStart(29) + StatusEntrance.GlyphSpan <= longTitle.End);
        Assert.AreEqual(StatusEntrance.TitleStart, new StatusEntrance(1).GlyphStart(5), 1e-9);
        // 两个都是常量（MSTEST0032）；留着是为了有人把它们改成不放大 / 不上浮时这里先红。
#pragma warning disable MSTEST0032
        Assert.IsTrue(StatusEntrance.EmergeScale > 1 && StatusEntrance.RiseFactor > 0);
#pragma warning restore MSTEST0032
    }

    [TestMethod]
    public void TickerSlicesMeetAtPixels()
    {
        // 「14:02」：各字左边在 0、7.4、14.8、18.3、25.7，行尾 33.1（DIP）；125% 屏
        var edges = new[] { 0, 7.4, 14.8, 18.3, 25.7, 33.1 };
        var slices = TickerLayout.Slices(edges, 1.25);
        Assert.AreEqual(5, slices.Count);
        Assert.AreEqual((0, 9), slices[0]);
        for (var index = 1; index < slices.Count; index++)
        {
            Assert.AreEqual(slices[index - 1].Right, slices[index].Left, "块和块正好接上，不重叠、不留缝");
        }

        Assert.AreEqual((int)Math.Round(33.1 * 1.25) + 2, slices[^1].Right, "最后一块往右多 1 DIP（125% 屏上取整是 2 像素）");
        Assert.AreEqual(0, TickerLayout.Slices(new[] { 1.0 }, 1).Count);
        Assert.AreEqual(0, TickerLayout.Slices(edges, 0).Count);
    }

    [TestMethod]
    public void OnlyDigitsInPlaceRoll()
    {
        string[] Split(string text) => text.Select(c => c.ToString()).ToArray();
        var edges = new[] { 0, 7.4, 14.8, 18.3, 25.7, 33.1 };
        CollectionAssert.AreEqual(new[] { 4 }, TickerLayout.Rolling(Split("14:02"), edges, Split("14:03"), edges, 1)!.ToList());
        CollectionAssert.AreEqual(new[] { 3, 4 }, TickerLayout.Rolling(Split("14:09"), edges, Split("14:10"), edges, -1)!.ToList());
        Assert.AreEqual(0, TickerLayout.Rolling(Split("14:02"), edges, Split("14:02"), edges, 1)!.Count, "什么都没变：能滚，没有要滚的");
        Assert.IsNull(TickerLayout.Rolling(Split("14:02"), edges, Split("14:03"), edges, 0), "没给方向：直接换");
        Assert.IsNull(TickerLayout.Rolling(Split("14:02"), edges, Split("14 02"), edges, 1), "变的不是数字换数字");
        Assert.IsNull(TickerLayout.Rolling(Split("59"), new[] { 0, 7.4, 14.8 }, Split("100"), new[] { 0, 7.4, 14.8, 22.2 }, 1), "字数变了");
        var moved = new[] { 0, 7.4, 14.8, 18.3, 25.9, 33.3 };
        Assert.IsNull(TickerLayout.Rolling(Split("14:02"), edges, Split("14:03"), moved, 1), "有字挪了地方（数字不等宽）");
    }

    [TestMethod]
    public void ColonBetweenDigitsIsLifted()
    {
        var characters = "14:02 开始 · 已 1 分 05 秒 a:b 3:".Select(c => c.ToString()).ToList();
        Assert.IsTrue(TickerLayout.LiftsColon(characters, 2));
        Assert.IsFalse(TickerLayout.LiftsColon(characters, characters.IndexOf("a") + 1), "两边不是数字");
        Assert.IsFalse(TickerLayout.LiftsColon(characters, characters.Count - 1), "在行尾");
        Assert.IsFalse(TickerLayout.LiftsColon(characters, 0));
        Assert.AreEqual(1.6, TickerLayout.ColonLift(16, 1.25), 1e-9, "16 × 0.1 = 1.6 DIP = 2 像素");
        Assert.AreEqual(2, TickerLayout.ColonLift(19, 1), 1e-9, "按像素取整");
        Assert.AreEqual(0, TickerLayout.ColonLift(19, 0));
    }

    [TestMethod]
    public void CardGrowsToTheScreen()
    {
        var screens = new[] { new PixelRect(0, 0, 2560, 1600), new PixelRect(2560, 0, 1920, 1080) };
        var card = new PixelRect(1000, 600, 250, 156);
        Assert.AreEqual(0, StatusScreenRules.GrowingIndex(card, screens));
        Assert.AreEqual(1, StatusScreenRules.GrowingIndex(card with { X = 3000 }, screens));
        Assert.AreEqual(0, StatusScreenRules.GrowingIndex(card with { X = -9000 }, screens), "都不在就第一块");

        var full = screens[0];
        var start = StatusScreenRules.GrowFrame(card, full, 0, 10);
        Assert.AreEqual((1000.0, 600.0, 250.0, 156.0, 10.0), (start.X, start.Y, start.Width, start.Height, start.Radius));
        Assert.AreEqual(250.0 / 2560, start.ScaleX, 1e-9, "横竖各缩各的");
        Assert.AreEqual(156.0 / 1600, start.ScaleY, 1e-9);

        var end = StatusScreenRules.GrowFrame(card, full, 1, 10);
        Assert.AreEqual((0.0, 0.0, 2560.0, 1600.0, 0.0, 1.0, 1.0), end);

        var middle = StatusScreenRules.GrowFrame(card, full, 0.5, 10);
        Assert.IsTrue(middle.Width > 250 && middle.Radius is > 0 and < 10);
        // island 有一点回弹：中途会略冲过整屏；圆角不回弹，一直不小于 0
        var frames = Enumerable.Range(0, 101).Select(step => StatusScreenRules.GrowFrame(card, full, step / 100.0, 10)).ToList();
        Assert.IsTrue(frames.All(frame => frame.Radius >= 0));
        Assert.IsTrue(frames.Max(frame => frame.Width) > 2560, "island 冲过头再回来");
    }
}
