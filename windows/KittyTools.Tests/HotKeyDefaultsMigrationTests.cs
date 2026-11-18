// 默认快捷键对齐 mac 的一次性迁移（2026-11-18）：旧默认值换成新的，改过的不动，新键被占着的不换。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static KittyTools.Core.HotKeyDefaultsMigration;

namespace KittyTools.Tests;

[TestClass]
public sealed class HotKeyDefaultsMigrationTests
{
    private static Binding Alt(char key) => new(HotKeyModifiers.Alt, key);

    private static readonly Binding CtrlAltZ = new(HotKeyModifiers.Control | HotKeyModifiers.Alt, 'Z');

    private static Dictionary<string, Binding> OldDefaults() => new()
    {
        ["clipboard"] = Alt('C'),
        ["selectionTranslate"] = Alt('E'),
        ["screenshot"] = Alt('X'),
        ["screenshotLast"] = CtrlAltZ,
        ["record"] = Alt('R'),
        ["shotHistory"] = default,
    };

    [TestMethod]
    public void OldDefaultsAllMoveToMacKeys()
    {
        var plan = Plan(OldDefaults());
        Assert.AreEqual(3, plan.Count);
        Assert.AreEqual(Alt('A'), plan["screenshot"]);
        Assert.AreEqual(Alt('X'), plan["screenshotLast"], "截图先让出 Alt+X，截取上次区域换得过去");
        Assert.AreEqual(Alt('D'), plan["selectionTranslate"]);
    }

    [TestMethod]
    public void ChangedKeysStay()
    {
        var stored = OldDefaults();
        stored["screenshot"] = new(HotKeyModifiers.Control | HotKeyModifiers.Shift, 'S');
        stored["selectionTranslate"] = default; // 清掉了键
        var plan = Plan(stored);
        Assert.IsFalse(plan.ContainsKey("screenshot"));
        Assert.IsFalse(plan.ContainsKey("selectionTranslate"));
        Assert.AreEqual(Alt('X'), plan["screenshotLast"], "截图改成别的了，Alt+X 空着");
    }

    [TestMethod]
    public void TakenKeysAreNotStolen()
    {
        var stored = OldDefaults();
        stored["record"] = Alt('A');
        stored["clipboard"] = Alt('D');
        var plan = Plan(stored);
        Assert.IsFalse(plan.ContainsKey("screenshot"), "Alt+A 被录屏占着");
        Assert.IsFalse(plan.ContainsKey("screenshotLast"), "截图没换走，Alt+X 还是它的");
        Assert.IsFalse(plan.ContainsKey("selectionTranslate"), "Alt+D 被剪贴板占着");
    }

    [TestMethod]
    public void AlreadyNewDefaultsAreNoOp()
    {
        var stored = new Dictionary<string, Binding>
        {
            ["selectionTranslate"] = Alt('D'),
            ["screenshot"] = Alt('A'),
            ["screenshotLast"] = Alt('X'),
        };
        Assert.AreEqual(0, Plan(stored).Count);
    }
}
