// 设置侧栏分组、「已关闭」组、新装只开四个（PLAN-v16 G2，照 mac SettingsListTests / FeatureTests.seedsNewInstallOnly）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsSidebarTests
{
    private static readonly HashSet<string> None = new();

    [TestMethod]
    public void GroupsFollowTheMacOrder()
    {
        var groups = SettingsSidebar.Build(SettingsSidebar.AllPages.ToList(), None);
        CollectionAssert.AreEqual(new string?[] { null, "文字与搜索", "截图与录制", "便签与提醒", null }, groups.Select(group => group.Title).ToArray());
        CollectionAssert.AreEqual(
            new[] { "general", "clipboard", "launcher", "translate", "screenshot", "record", "notes", "reminders", "statusScreen", "hotkeys", "about" },
            groups.SelectMany(group => group.Pages).ToArray());
    }

    [TestMethod]
    public void OffFeaturesMoveToTheClosedGroup()
    {
        var off = new HashSet<string> { "record", "statusScreen", "notes", "reminders" };
        var groups = SettingsSidebar.Build(SettingsSidebar.AllPages.ToList(), off);
        // 截图与录制只剩截图；便签与提醒整组空了不画；「已关闭（4）」在最底下、照侧栏顺序
        CollectionAssert.AreEqual(new[] { "screenshot" }, groups.Single(group => group.Title == "截图与录制").Pages.ToArray());
        Assert.IsFalse(groups.Any(group => group.Title == "便签与提醒"));
        var closed = groups[^1];
        Assert.IsTrue(closed.IsOff);
        Assert.AreEqual("已关闭（4）", closed.Title);
        CollectionAssert.AreEqual(new[] { "record", "notes", "reminders", "statusScreen" }, closed.Pages.ToArray());
        // 搜索时只留匹配的
        var searched = SettingsSidebar.Build(new[] { "translate", "record" }, off);
        Assert.AreEqual(2, searched.Count);
        Assert.AreEqual("已关闭（1）", searched[1].Title);
    }

    [TestMethod]
    public void CollapsedGroupsOpenWhenSearchingOrShowingTheirPage()
    {
        var text = new SidebarGroup("文字与搜索", new[] { "clipboard", "launcher", "translate" });
        var collapsed = new HashSet<string> { "文字与搜索" };
        Assert.IsFalse(SettingsSidebar.IsExpanded(text, false, collapsed, false, "general"));
        Assert.IsTrue(SettingsSidebar.IsExpanded(text, true, collapsed, false, "general"));
        Assert.IsTrue(SettingsSidebar.IsExpanded(text, false, collapsed, false, "launcher"));
        Assert.IsTrue(SettingsSidebar.IsExpanded(text, false, None, false, "general"));
        var closed = new SidebarGroup("已关闭（1）", new[] { "record" }, true);
        Assert.IsFalse(SettingsSidebar.IsExpanded(closed, false, None, false, "general"));
        Assert.IsTrue(SettingsSidebar.IsExpanded(closed, false, None, true, "general"));
        Assert.IsTrue(SettingsSidebar.IsExpanded(closed, false, None, false, "record"));
    }

    [TestMethod]
    public void SeedsNewInstallWithFourFeatures()
    {
        var keys = new[] { "clipboard", "translate", "launcher", "screenshot", "recording", "notes", "statusScreen", "reminders" };
        var seeded = SettingsSidebar.SeedNewInstall(keys, null);
        CollectionAssert.AreEquivalent(new[] { "clipboard", "translate", "launcher", "screenshot" }, seeded.Where(pair => pair.Value).Select(pair => pair.Key).ToArray());
        Assert.AreEqual(8, seeded.Count);
        // 已经存过的不动
        var kept = SettingsSidebar.SeedNewInstall(keys, new Dictionary<string, bool> { ["notes"] = true, ["clipboard"] = false });
        Assert.IsTrue(kept["notes"]);
        Assert.IsFalse(kept["clipboard"]);
    }
}
