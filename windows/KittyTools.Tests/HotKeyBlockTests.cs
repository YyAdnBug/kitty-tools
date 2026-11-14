// 按应用停用快捷键（PLAN-v17，照 mac HotKeyBlockTests）：名单的存法（往返、坏条目、重复、不认识的动作 id 留着）、此刻停哪些（全部 /
// 只停几个 / 空的当没停）、设置页那一行勾上取消的结果、下拉的字、全屏游戏认哪几种。不读写设置，全部喂字符串。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HotKeyBlockTests
{
    private static readonly string[] Known = { "clipboard", "launcher", "selectionTranslate", "screenshot" };

    [TestMethod]
    public void EntriesRoundTrip()
    {
        foreach (var entry in new[] { "Photoshop.exe", "foo.exe|clipboard,launcher", "foo.exe|", "Some App.exe" })
        {
            Assert.AreEqual(entry, HotKeyBlock.Parse(entry)?.Entry);
        }

        Assert.IsNull(HotKeyBlock.Parse("foo.exe")!.Actions);
        Assert.AreEqual(0, HotKeyBlock.Parse("foo.exe|")!.Actions!.Count);
    }

    [TestMethod]
    public void BadAndDuplicateEntriesAreDropped()
    {
        var list = HotKeyBlock.List(new[]
        {
            "", "|clipboard", " ", " lead.exe", @"C:\x\a.exe", "a.exe", "A.EXE|launcher", "c.exe", new string('x', 600),
        });
        CollectionAssert.AreEqual(new[] { "a.exe", "c.exe" }, list.Select(block => block.Exe).ToArray());
        Assert.IsNull(list[0].Actions, "同一个 exe 只认第一条（不分大小写）");
        Assert.AreEqual(HotKeyBlock.MaxEntries, HotKeyBlock.List(Enumerable.Range(0, 300).Select(i => $"app{i}.exe")).Count);
    }

    [TestMethod]
    public void RuleForFrontApp()
    {
        var entries = new[] { "all.exe", "some.exe|clipboard,screenshot", "none.exe|", "unknown.exe|fromTheFuture" };
        Assert.AreEqual(HotKeyBlockRule.All, HotKeyBlock.RuleFor("ALL.EXE", entries, Known));
        Assert.AreEqual(new HotKeyBlockRule(false, new HashSet<string> { "clipboard", "screenshot" }), HotKeyBlock.RuleFor("some.exe", entries, Known));
        Assert.IsNull(HotKeyBlock.RuleFor("none.exe", entries, Known));
        Assert.IsNull(HotKeyBlock.RuleFor("unknown.exe", entries, Known));
        Assert.IsNull(HotKeyBlock.RuleFor("other.exe", entries, Known));
        Assert.IsNull(HotKeyBlock.RuleFor(null, entries, Known));

        var some = new HotKeyBlockRule(false, new HashSet<string> { "clipboard" });
        Assert.IsTrue(some.Blocks("clipboard") && !some.Blocks("launcher") && !some.BlocksCommands);
        Assert.IsTrue(HotKeyBlockRule.All.Blocks("launcher") && HotKeyBlockRule.All.BlocksCommands);
        Assert.AreNotEqual(HotKeyBlockRule.All, some);
    }

    [TestMethod]
    public void TogglingActions()
    {
        var shown = new[] { "clipboard", "launcher", "screenshot" };
        var all = new HotKeyBlock("a.exe");
        // 从「全部」取消一个 = 只停看得见的其余几个，按全部动作的顺序存
        var fromAll = all.Setting("launcher", blocked: false, shown, Known);
        CollectionAssert.AreEqual(new[] { "clipboard", "screenshot" }, fromAll.Actions!.ToArray());
        Assert.IsTrue(fromAll.Blocks("clipboard") && !fromAll.Blocks("launcher"));
        // 不认识的动作 id（以后加的）原样留着
        var future = new HotKeyBlock("a.exe", new[] { "fromTheFuture", "screenshot" });
        CollectionAssert.AreEqual(
            new[] { "clipboard", "screenshot", "fromTheFuture" }, future.Setting("clipboard", blocked: true, shown, Known).Actions!.ToArray());
        CollectionAssert.AreEqual(new[] { "fromTheFuture" }, future.Setting("screenshot", blocked: false, shown, Known).Actions!.ToArray());
    }

    [TestMethod]
    public void ScopeTitles()
    {
        Assert.AreEqual("全部快捷键", HotKeyBlock.Scope(new HotKeyBlock("a.exe")));
        Assert.AreEqual("1 个快捷键", HotKeyBlock.Scope(new HotKeyBlock("a.exe", new[] { "clipboard" })));
        Assert.AreEqual("没有停用的", HotKeyBlock.Scope(new HotKeyBlock("a.exe", Array.Empty<string>())));
    }

    [TestMethod]
    public void FullscreenGameStates()
    {
        // QUNS_NOT_PRESENT 1、BUSY 2（全屏视频、F11 网页）、RUNNING_D3D_FULL_SCREEN 3、PRESENTATION_MODE 4、ACCEPTS_NOTIFICATIONS 5、QUIET_TIME 6、APP 7
        CollectionAssert.AreEqual(new[] { 3, 4 }, Enumerable.Range(0, 9).Where(HotKeyBlock.IsFullscreenGame).ToArray());
    }
}
