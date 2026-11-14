// 截图时的快捷键（PLAN-v18 S3，照 mac ShotKeysTests）：默认的那一套、存法（和默认一样删掉、清除存空串）、按键对哪个动作（Shift 往上滚）、
// 固定的键和重复的不收、和全局快捷键一样的不收、导入时只收认得的能用的。只喂字典，不读设置。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ShotKeysTests
{
    private static ShotKeyBinding Key(char key, HotKeyModifiers modifiers = HotKeyModifiers.None) => new(key, modifiers);

    [TestMethod]
    public void DefaultsAreTheOldFixedKeys()
    {
        CollectionAssert.AreEqual(
            new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }, ShotKeys.Tools.Select(entry => entry.Default.Display).ToArray());
        CollectionAssert.AreEqual(AnnotationKinds.All, ShotKeys.Tools.Select(entry => entry.Tool!.Value).ToArray());
        var others = ShotKeys.Others.ToDictionary(entry => entry.Id, entry => entry.Default.Display);
        Assert.AreEqual("Ctrl+C", others["copy"]);
        Assert.AreEqual("Ctrl+S", others["save"]);
        Assert.AreEqual("Ctrl+Shift+S", others["saveAs"]);
        Assert.AreEqual("Ctrl+Z", others["undo"]);
        Assert.AreEqual("Ctrl+Y", others["redo"]);
        Assert.AreEqual("P", others["pin"]);
        Assert.AreEqual("T", others["translate"]);
        Assert.AreEqual("S", others["scroll"]);
        Assert.AreEqual("A", others["autoScroll"]);
        Assert.AreEqual("O", others["recognize"]);
        Assert.AreEqual("R", others["record"]);
        Assert.AreEqual("X", others["crop"]);
        Assert.AreEqual("D", others["lastRegion"]);
        Assert.AreEqual("C", others["pickColor"]);
        // 默认的键互不重复，也都不是固定的键
        var all = ShotKeys.All.Select(entry => entry.Default).ToList();
        Assert.AreEqual(all.Count, all.Distinct().Count());
        Assert.IsTrue(all.All(ShotKeys.IsUsable));
    }

    [TestMethod]
    public void StoringAndMatching()
    {
        Dictionary<string, string>? stored = null;
        Assert.IsTrue(ShotKeys.ToolsAreDefault(stored));
        Assert.AreEqual(("record", false), ShotKeys.Matching('R', HotKeyModifiers.None, stored));
        // 矩形改成 R、录屏清掉
        stored = ShotKeys.Set(stored, "record", null);
        stored = ShotKeys.Set(stored, "rectangle", Key('R'));
        Assert.IsNull(ShotKeys.Current("record", stored));
        Assert.AreEqual(string.Empty, stored["record"]);
        Assert.AreEqual(("rectangle", false), ShotKeys.Matching('R', HotKeyModifiers.None, stored));
        Assert.IsNull(ShotKeys.Matching('1', HotKeyModifiers.None, stored));
        Assert.IsFalse(ShotKeys.ToolsAreDefault(stored));
        Assert.AreEqual("录屏", ShotKeys.Tip("录屏", "record", stored));
        Assert.AreEqual("矩形（R）", ShotKeys.Tip("矩形", "rectangle", stored));
        // 改回默认：删掉这一项（回到「没存过」）
        stored = ShotKeys.Set(stored, "rectangle", ShotKeys.Find("rectangle")!.Default);
        Assert.IsFalse(stored.ContainsKey("rectangle"));
        Assert.IsTrue(ShotKeys.ToolsAreDefault(stored));
        // 带修饰键的也行：Shift 是区分的
        stored = ShotKeys.Set(stored, "pin", Key('1', HotKeyModifiers.Alt));
        Assert.AreEqual(("pin", false), ShotKeys.Matching('1', HotKeyModifiers.Alt, stored));
        Assert.IsNull(ShotKeys.Matching('P', HotKeyModifiers.Shift, stored));
        // 长截图 / 自动滚加 Shift 往上，跟着改过的键走
        Assert.AreEqual(("scroll", true), ShotKeys.Matching('S', HotKeyModifiers.Shift, stored));
        stored = ShotKeys.Set(stored, "autoScroll", Key('G'));
        Assert.AreEqual(("autoScroll", true), ShotKeys.Matching('G', HotKeyModifiers.Shift, stored));
        Assert.IsNull(ShotKeys.Matching('A', HotKeyModifiers.Shift, stored));
        // 读不出来的写法当清除了
        Assert.IsNull(ShotKeys.Current("copy", new Dictionary<string, string> { ["copy"] = "Ctrl+Nope" }));
    }

    [TestMethod]
    public void ReservedDuplicatesAndGlobalsAreRefused()
    {
        var globals = new[] { ("截图", new ShotKeyBinding('X', HotKeyModifiers.Alt)) };
        foreach (var binding in new[]
                 {
                     new ShotKeyBinding(0x1B, 0), new(0x0D, 0), new(0x08, 0), new(0x2E, 0), new(0x09, 0), new(0x20, 0),
                     new(0x25, HotKeyModifiers.Control), new(0x28, HotKeyModifiers.Alt), new('D', HotKeyModifiers.Control),
                     new('W', HotKeyModifiers.Control), new(0xBB, HotKeyModifiers.Control), new(0x6D, HotKeyModifiers.Control),
                     new('Z', HotKeyModifiers.Control | HotKeyModifiers.Shift), new(0x11, 0), new(0xA0, 0), new('Q', HotKeyModifiers.Win),
                 })
        {
            Assert.IsTrue(ShotKeys.IsReserved(binding), binding.Display);
            StringAssert.Contains(ShotKeys.Problem(binding, "pin", null, globals), "另有用处");
        }

        // 截图里重复：T 是截图翻译的；自己原来的键不算重复
        Assert.AreEqual("和截图里的「截图翻译」重复", ShotKeys.Problem(Key('T'), "rectangle", null, globals));
        Assert.IsNull(ShotKeys.Problem(Key('T'), "translate", null, globals));
        // 和全局快捷键一样（截图的默认 Alt+X）
        Assert.AreEqual("和全局快捷键「截图」重复", ShotKeys.Problem(Key('X', HotKeyModifiers.Alt), "pin", null, globals));
        // 标点键也能录、写法能读回来
        var semicolon = new ShotKeyBinding(0xBA, HotKeyModifiers.Control);
        var stored = ShotKeys.Set(null, "pin", semicolon);
        Assert.AreEqual("Ctrl+;", stored["pin"]);
        Assert.AreEqual(semicolon, ShotKeys.Current("pin", stored));
        var keypad = new ShotKeyBinding(0x61, HotKeyModifiers.None);
        Assert.AreEqual(keypad, ShotKeys.Current("pin", ShotKeys.Set(null, "pin", keypad)));
    }

    [TestMethod]
    public void ImportKeepsOnlyKnownUsableKeys()
    {
        var read = ShotKeys.Sanitize(new Dictionary<string, string>
        {
            ["pin"] = "Alt+P",
            ["record"] = string.Empty,
            ["copy"] = "Esc",
            ["save"] = "Win+S",
            ["fromTheFuture"] = "F",
            ["undo"] = "nonsense",
        });
        CollectionAssert.AreEquivalent(new[] { "pin", "record" }, read.Keys.ToArray());
        Assert.AreEqual("Alt+P", read["pin"]);
        Assert.AreEqual(string.Empty, read["record"]);
        // 截图里重复的（复制和钉图都改成 Alt+P）：表里靠后的那个丢掉、回到默认
        var duplicated = ShotKeys.Sanitize(new Dictionary<string, string> { ["copy"] = "Alt+P", ["pin"] = "Alt+P" });
        CollectionAssert.AreEqual(new[] { "copy" }, duplicated.Keys.ToArray());
        Assert.AreEqual(("copy", false), ShotKeys.Matching('P', HotKeyModifiers.Alt, duplicated));
        Assert.AreEqual(("pin", false), ShotKeys.Matching('P', HotKeyModifiers.None, duplicated));
    }
}
