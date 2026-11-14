// 连按两下修饰键（PLAN-v18 L9，照 mac ModifierTapsTests）：状态机认哪些算、哪些不算（按住太久、隔太久、换了键、两个修饰键、Win、
// 中间按了普通键、第二下按下时不算、不分左右）；快捷键里怎么记、怎么显示、导入认不认、提醒。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ModifierTapsTests
{
    private static List<ModifierTap?> Run(params (TapKey[] Held, long At)[] steps)
    {
        var taps = new ModifierTaps();
        return steps.Select(step => taps.Handle(step.Held, other: false, step.At)).ToList();
    }

    private static readonly TapKey[] None = Array.Empty<TapKey>();

    [TestMethod]
    public void QuickDoubleTapFiresOnSecondRelease()
    {
        var results = Run((new[] { TapKey.Control }, 0), (None, 100), (new[] { TapKey.Control }, 250), (None, 350));
        // 第二下按下时不算：松开那一刻再算
        Assert.IsTrue(results.Take(3).All(result => result is null));
        Assert.AreEqual(new ModifierTap(TapKey.Control, 0), results[^1]);
    }

    [TestMethod]
    public void EachModifierCounts()
    {
        foreach (var key in Enum.GetValues<TapKey>())
        {
            var results = Run((new[] { key }, 1000), (None, 1100), (new[] { key }, 1200), (None, 1300));
            Assert.AreEqual(new ModifierTap(key, 1000), results[^1]);
        }
    }

    [TestMethod]
    public void HoldingTooLongOrWaitingTooLongDoesNotCount()
    {
        var alt = new[] { TapKey.Alt };
        Assert.IsNull(Run((alt, 0), (None, 400), (alt, 500), (None, 600))[^1], "第一下按住 0.4 秒");
        Assert.IsNull(Run((alt, 0), (None, 100), (alt, 200), (None, 600))[^1], "第二下按住 0.4 秒");
        Assert.IsNull(Run((alt, 0), (None, 100), (alt, 500), (None, 600))[^1], "两下隔了 0.4 秒");
        // 隔太久的那一下当成新的第一下，再按一下就成
        Assert.AreEqual(new ModifierTap(TapKey.Alt, 500),
            Run((alt, 0), (None, 100), (alt, 500), (None, 600), (alt, 700), (None, 800))[^1]);
    }

    [TestMethod]
    public void DifferentKeysOrChordsDoNotCount()
    {
        Assert.IsNull(Run((new[] { TapKey.Control }, 0), (None, 100), (new[] { TapKey.Alt }, 200), (None, 300))[^1]);
        // 按着 Ctrl 又按 Shift（Ctrl+Shift 组合的开头），全松开前都不算；全松开后重新数
        var chord = Run(
            (new[] { TapKey.Control }, 0), (new[] { TapKey.Control, TapKey.Shift }, 50), (new[] { TapKey.Control }, 100), (None, 120),
            (new[] { TapKey.Control }, 200), (None, 250));
        Assert.IsTrue(chord.All(result => result is null));
        // Win 混进来不算
        var taps = new ModifierTaps();
        taps.Handle(new[] { TapKey.Control }, false, 0);
        taps.Handle(new[] { TapKey.Control }, true, 50);
        taps.Handle(None, false, 100);
        taps.Handle(new[] { TapKey.Control }, false, 200);
        Assert.IsNull(taps.Handle(None, false, 300));
    }

    [TestMethod]
    public void TypingInBetweenDoesNotCount()
    {
        // Ctrl 一下，接着 Ctrl+C（中间按了普通键）：不算连按
        var taps = new ModifierTaps();
        var ctrl = new[] { TapKey.Control };
        taps.Handle(ctrl, false, 0);
        taps.Handle(None, false, 80);
        taps.Handle(ctrl, false, 150);
        taps.Interrupt(modifiersHeld: true);
        Assert.IsNull(taps.Handle(None, false, 220));
        // 之后重新数照常
        taps.Handle(ctrl, false, 600);
        taps.Handle(None, false, 650);
        taps.Handle(ctrl, false, 700);
        Assert.AreEqual(new ModifierTap(TapKey.Control, 600), taps.Handle(None, false, 750));
    }

    [TestMethod]
    public void LeftAndRightAreTheSameKeyAndRepeatsAreIgnored()
    {
        // 左 Ctrl 按着时右 Ctrl 也按下、按住的自动重复：还是同一下
        var results = Run((new[] { TapKey.Control }, 0), (new[] { TapKey.Control }, 50), (None, 100), (new[] { TapKey.Control }, 200), (None, 300));
        Assert.AreEqual(new ModifierTap(TapKey.Control, 0), results[^1]);
        Assert.AreEqual(TapKey.Control, ModifierTaps.FromVirtualKey(0xA3));
        Assert.AreEqual(TapKey.Shift, ModifierTaps.FromVirtualKey(0xA0));
        Assert.IsNull(ModifierTaps.FromVirtualKey(0x5B));
    }

    [TestMethod]
    public void HotKeyStoresDoubleTapAsTheBareModifier()
    {
        foreach (var (key, text) in new[] { (0x11u, "Ctrl+Ctrl"), (0x12u, "Alt+Alt"), (0x10u, "Shift+Shift") })
        {
            Assert.IsTrue(HotKeyRules.IsDoubleTap(key, HotKeyModifiers.None));
            Assert.IsTrue(HotKeyRules.Validate(key, HotKeyModifiers.None).Ok);
            Assert.AreEqual(text, HotKeyRules.Format(key, HotKeyModifiers.None));
            Assert.IsTrue(HotKeyRules.TryParse(text, out var parsed, out var modifiers));
            Assert.AreEqual((key, HotKeyModifiers.None), (parsed, modifiers));
        }

        // Win 不认；带了修饰键的、左右分开的键位、「Ctrl+Alt」都不是连按
        Assert.IsFalse(HotKeyRules.IsDoubleTap(0x5B, HotKeyModifiers.None));
        Assert.IsFalse(HotKeyRules.IsDoubleTap(0x11, HotKeyModifiers.Control));
        Assert.IsFalse(HotKeyRules.Validate(0xA2, HotKeyModifiers.None).Ok);
        Assert.IsFalse(HotKeyRules.TryParse("Ctrl+Alt", out _, out _));
        // 普通组合照旧
        Assert.IsFalse(HotKeyRules.Validate('C', HotKeyModifiers.None).Ok);
        Assert.IsTrue(HotKeyRules.Validate('C', HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void DoubleTapHints()
    {
        StringAssert.Contains(HotKeyRules.DoubleTapHint(0x10), "中英文");
        StringAssert.Contains(HotKeyRules.DoubleTapHint(0x12), "菜单栏");
        Assert.IsNull(HotKeyRules.DoubleTapHint(0x11));
    }
}
