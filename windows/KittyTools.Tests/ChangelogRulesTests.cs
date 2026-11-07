// 关于页更新日志只展开当前版本（PLAN-v16 G1，照 mac ChangelogTests.expandsCurrentReleaseOrLatest）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ChangelogRulesTests
{
    [TestMethod]
    public void ExpandsCurrentReleaseOrLatest()
    {
        var versions = new[] { "0.7.1", "0.7.0", "0.6.0" };
        Assert.AreEqual("0.7.0", ChangelogRules.FirstExpanded(versions, "0.7.0"));
        Assert.AreEqual("0.7.1", ChangelogRules.FirstExpanded(versions, "0.8.0"));
        Assert.IsNull(ChangelogRules.FirstExpanded(System.Array.Empty<string>(), "0.8.0"));
    }

    [TestMethod]
    public void AccessibleNameSaysExpandedOrCollapsed()
    {
        Assert.AreEqual("0.1.2，当前版本，2026-11-05，已展开", ChangelogRules.AccessibleName("0.1.2", "2026-11-05", true, true));
        Assert.AreEqual("0.1.1，2026-11-03，已折叠", ChangelogRules.AccessibleName("0.1.1", "2026-11-03", false, false));
    }
}
