// 保留策略单测：期望值从 mac 版 ClipboardStoreTests 的 enforceLimits 两条搬过来。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class RetentionTests
{
    private const long Day = 86_400_000;

    [TestMethod]
    public void AgeDeletesOnlyOrdinaryExpired()
    {
        var now = 100 * Day;
        var items = new[]
        {
            Text("favorite", now - 30 * Day, favorite: true),
            Text("old", now - 10 * Day),
            Text("fresh", now - 2 * Day),
            Image("old-image", now - 9 * Day, 100),
        };

        var doomed = Retention.Plan(items, new RetentionLimits(7, 0), now);

        CollectionAssert.AreEquivalent(new[] { "old", "old-image" }, doomed.ToArray());
    }

    [TestMethod]
    public void ImageBudgetCountsOnlyOrdinaryImages()
    {
        var now = 100 * Day;
        var items = new[]
        {
            Image("favorite", now - 40, 1000, favorite: true),
            Image("hash2", now - 10, 100),
            Image("hash1", now - 20, 100),
            Image("hash0", now - 30, 100),
        };

        var first = Retention.Plan(items, new RetentionLimits(0, 250), now);
        CollectionAssert.AreEquivalent(new[] { "hash0" }, first.ToArray());

        var afterFirst = items.Where(item => !first.Contains(item.Id)).ToArray();
        var second = Retention.Plan(afterFirst, new RetentionLimits(0, 50), now);
        CollectionAssert.AreEquivalent(new[] { "hash1" }, second.ToArray());

        // 只剩最新的一张普通图片：额度再小也留着它。
        var afterSecond = afterFirst.Where(item => !second.Contains(item.Id)).ToArray();
        Assert.AreEqual(0, Retention.Plan(afterSecond, new RetentionLimits(0, 1), now).Count);
    }

    [TestMethod]
    public void ZeroLimitsDeleteNothing()
    {
        var now = 100 * Day;
        var items = new[]
        {
            Text("ancient", now - 999 * Day),
            Image("big", now - 500 * Day, 1_000_000),
        };

        Assert.AreEqual(0, Retention.Plan(items, new RetentionLimits(0, 0), now).Count);
    }

    [TestMethod]
    public void FavoritesSurviveBothRules()
    {
        var now = 100 * Day;
        var items = new[]
        {
            Image("fav", now - 999 * Day, 1_000_000, favorite: true),
            Image("recent", now, 1_000_000),
        };

        Assert.AreEqual(0, Retention.Plan(items, new RetentionLimits(1, 1), now).Count);
    }

    [TestMethod]
    public void AgeDoomedImageDoesNotShieldTheNextOne()
    {
        var now = 100 * Day;
        var items = new[]
        {
            Image("newest", now - 1 * Day, 100),
            Image("middle", now - 9 * Day, 100),
            Image("oldest", now - 10 * Day, 100),
        };

        // oldest 超天数先删；图片额度只剩 middle / newest 时，最新的一张（newest）仍受保护。
        var doomed = Retention.Plan(items, new RetentionLimits(7, 150), now);
        CollectionAssert.AreEquivalent(new[] { "oldest", "middle" }, doomed.ToArray());
    }

    private static RetentionItem Text(string id, long copiedAt, bool favorite = false)
        => new(id, ClipKind.Text, copiedAt, 0, favorite);

    private static RetentionItem Image(string id, long copiedAt, int bytes, bool favorite = false)
        => new(id, ClipKind.Image, copiedAt, bytes, favorite);
}
