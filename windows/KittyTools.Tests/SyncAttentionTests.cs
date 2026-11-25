// 同步停了什么时候说（SyncAttention，照 mac 0.10.1 U1 的 NoteSyncServerTests 那几条口径）。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncAttentionTests
{
    private static TimeSpan Minutes(double minutes) => TimeSpan.FromMinutes(minutes);

    [TestMethod]
    public void NeedsYou_ToldAtOnce_OncePerKind()
    {
        var attention = new SyncAttention();
        Assert.IsTrue(attention.Stopped(SyncAttention.Unauthorized, Minutes(0)));
        Assert.IsTrue(attention.NeedsAttention);
        Assert.IsFalse(attention.Stopped(SyncAttention.Unauthorized, Minutes(1)), "同一段停着里同一种只说一次");
        Assert.IsTrue(attention.Stopped(SyncAttention.NotTheFolder, Minutes(2)), "换了一种要你处理的再说");
    }

    [TestMethod]
    public void Others_WaitQuietSpan_ThenOnce()
    {
        var attention = new SyncAttention();
        Assert.IsFalse(attention.Stopped(null, Minutes(0)));
        Assert.IsFalse(attention.Stopped(null, Minutes(29)));
        Assert.IsFalse(attention.NeedsAttention);
        Assert.IsTrue(attention.Stopped(null, Minutes(30)));
        Assert.IsTrue(attention.NeedsAttention);
        Assert.IsFalse(attention.Stopped(null, Minutes(60)), "别的几种合起来算一种");
    }

    [TestMethod]
    public void Recovered_StartsOver()
    {
        var attention = new SyncAttention();
        attention.Stopped(SyncAttention.Forbidden, Minutes(0));
        attention.Recovered();
        Assert.IsFalse(attention.NeedsAttention);
        Assert.IsTrue(attention.Stopped(SyncAttention.Forbidden, Minutes(1)), "好了之后再停从头算");
        attention.Recovered();
        Assert.IsFalse(attention.Stopped(null, Minutes(100)), "从这一次停下开始数，不是从上一段");
    }

    [TestMethod]
    public void Classify_RunnerMessages()
    {
        Assert.AreEqual(SyncAttention.Newer, SyncAttention.Classify(SyncRunner.NewerFormat));
        Assert.AreEqual(SyncAttention.Newer, SyncAttention.Classify(ClipSync.Unreadable));
        Assert.AreEqual(SyncAttention.NotTheFolder, SyncAttention.Classify(SyncRunner.ForeignFolder));
        Assert.IsNull(SyncAttention.Classify("文件夹不在了"));
        Assert.IsNull(SyncAttention.Classify("同步文件夹还没下载完"));
        Assert.IsTrue(SyncAttention.NeedsYou(SyncAttention.NoPassword));
        Assert.IsFalse(SyncAttention.NeedsYou(null));
        Assert.AreEqual("同步文件夹还没下载完", SyncAttention.Notice(null, "同步文件夹还没下载完"));
    }
}
