// PLAN-v8 第 1 批：截图历史的清理规则、标注 JSON 往返、缩略图尺寸、按天分组的标题。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ShotHistoryTests
{
    private const long Day = 86_400_000L;

    [TestMethod]
    public void StaleDropsExpiredAndOverBudgetButKeepsNewest()
    {
        var now = 100 * Day;
        var items = new[]
        {
            new ShotStaleItem("old", now - 31 * Day, 10),
            new ShotStaleItem("a", now - 1 * Day, 600),
            new ShotStaleItem("newest", now, 600),
            new ShotStaleItem("b", now - 2 * Day, 600),
        };

        // 30 天：old 过期；1000 字节：newest 留着（最新那条不按总量删），a 累计 1200 超了，b 也超了。
        CollectionAssert.AreEquivalent(
            new[] { "old", "a", "b" }, ShotHistoryRules.Stale(items, now, 30, 1000));
        // 不限天数、不限总量：一条都不删。
        Assert.AreEqual(0, ShotHistoryRules.Stale(items, now, 0, 0).Count);
        // 上限比一张图还小：最新那条照样留着。
        CollectionAssert.AreEquivalent(
            new[] { "a", "b", "old" }, ShotHistoryRules.Stale(items, now, 0, 1));
    }

    [TestMethod]
    public void AnnotationsRoundTrip()
    {
        var annotations = new List<ShotAnnotationData>
        {
            new("rectangle", new RectD(1.5, 2, 30, 40), Array.Empty<PointD>(), string.Empty, 0xFFFF2D55, 3),
            new("pen", new RectD(0, 0, 0, 0), new[] { new PointD(1, 2), new PointD(3.25, 4) }, string.Empty, 0x80112233, 5),
            new("text", new RectD(10, 10, 100, 20), Array.Empty<PointD>(), "你好 \"<&>\"", 0xFF000000, 2),
        };

        var json = ShotHistoryRules.EncodeAnnotations(annotations);
        Assert.IsNotNull(json);
        StringAssert.Contains(json, "\"tool\":\"rectangle\"");
        StringAssert.Contains(json, "\"color\":\"#80112233\"");
        var decoded = ShotHistoryRules.DecodeAnnotations(json);
        Assert.AreEqual(3, decoded.Count);
        for (var index = 0; index < annotations.Count; index++)
        {
            Assert.AreEqual(annotations[index].Tool, decoded[index].Tool);
            Assert.AreEqual(annotations[index].Rect, decoded[index].Rect);
            CollectionAssert.AreEqual(annotations[index].Points.ToList(), decoded[index].Points.ToList());
            Assert.AreEqual(annotations[index].Text, decoded[index].Text);
            Assert.AreEqual(annotations[index].Argb, decoded[index].Argb);
            Assert.AreEqual(annotations[index].Width, decoded[index].Width);
        }

        Assert.IsNull(ShotHistoryRules.EncodeAnnotations(new List<ShotAnnotationData>()));
        Assert.AreEqual(0, ShotHistoryRules.DecodeAnnotations(null).Count);
        Assert.AreEqual(0, ShotHistoryRules.DecodeAnnotations("不是 JSON").Count);
        // 坏一条不连累别的。
        Assert.AreEqual(1, ShotHistoryRules.DecodeAnnotations(
            "[{\"tool\":\"arrow\"},{\"tool\":\"arrow\",\"rect\":[0,0,1,1]}]").Count);
    }

    [TestMethod]
    public void KindsAndTitles()
    {
        foreach (var kind in Enum.GetValues<ShotKind>())
        {
            Assert.AreEqual(kind, ShotHistoryRules.Parse(ShotHistoryRules.StorageName(kind)));
        }

        Assert.IsNull(ShotHistoryRules.Parse("nope"));
        Assert.IsTrue(ShotHistoryRules.IsRecording(ShotKind.Gif));
        Assert.IsFalse(ShotHistoryRules.IsRecording(ShotKind.Scroll));
    }

    [TestMethod]
    public void ThumbnailSizeAndDayTitle()
    {
        Assert.AreEqual((480, 270), ShotHistoryRules.ThumbnailSize(1920, 1080));
        Assert.AreEqual((24, 480), ShotHistoryRules.ThumbnailSize(1000, 20000));
        Assert.AreEqual((300, 200), ShotHistoryRules.ThumbnailSize(300, 200));

        var today = new DateTime(2026, 10, 26, 23, 0, 0);
        Assert.AreEqual("今天", ShotHistoryRules.DayTitle(new DateTime(2026, 10, 26, 1, 0, 0), today));
        Assert.AreEqual("昨天", ShotHistoryRules.DayTitle(new DateTime(2026, 10, 25, 23, 59, 0), today));
        Assert.AreEqual("10 月 24 日", ShotHistoryRules.DayTitle(new DateTime(2026, 10, 24), today));
        Assert.AreEqual("2025 年 12 月 31 日", ShotHistoryRules.DayTitle(new DateTime(2025, 12, 31), today));
    }
}
