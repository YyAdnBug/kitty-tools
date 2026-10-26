// PLAN-v7 U5 的强调色表单测：8 档齐全、默认品牌粉、符号 / 文字的对比度够。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AccentPaletteTests
{
    [TestMethod]
    public void HasEightUniqueAccentsAndPinkDefault()
    {
        Assert.AreEqual(8, AccentPalette.All.Count);
        Assert.AreEqual(8, AccentPalette.All.Select(item => item.Key).Distinct().Count());
        Assert.AreEqual("pink", AccentPalette.Default.Key);
        Assert.AreEqual(AccentPalette.Default, AccentPalette.FromSetting("brand", dark: false));
        Assert.AreEqual(AccentPalette.Default, AccentPalette.FromSetting("system", dark: true));
        Assert.AreEqual("blue", AccentPalette.FromSetting("blue", dark: false).Key);
        Assert.AreEqual(AccentPalette.Default, AccentPalette.FromSetting("nope", dark: false));
    }

    [TestMethod]
    public void SymbolOnEveryAccentHasEnoughContrast()
    {
        foreach (var accent in AccentPalette.All)
        {
            foreach (var dark in new[] { false, true })
            {
                var background = AccentPalette.Value(accent, dark);
                var foreground = AccentPalette.OnAccent(background);
                Assert.IsTrue(
                    AccentPalette.Contrast(background, foreground) >= 3.0,
                    $"{accent.Key} dark={dark} contrast={AccentPalette.Contrast(background, foreground):F2}");
            }
        }
    }

    [TestMethod]
    public void AccentTextReachesBodyContrast()
    {
        foreach (var accent in AccentPalette.All)
        {
            foreach (var dark in new[] { false, true })
            {
                var background = AccentPalette.Value(accent, dark);
                var text = AccentPalette.AccentText(background, dark);
                var page = dark ? 0x101010u : 0xFFFFFFu;
                Assert.IsTrue(
                    AccentPalette.Contrast(text, page) >= 4.5,
                    $"{accent.Key} dark={dark} contrast={AccentPalette.Contrast(text, page):F2}");
            }
        }
    }

    [TestMethod]
    public void RelativeLuminanceAndScaleAreSane()
    {
        Assert.AreEqual(0.0, AccentPalette.RelativeLuminance(0x000000), 0.0001);
        Assert.AreEqual(1.0, AccentPalette.RelativeLuminance(0xFFFFFF), 0.0001);
        Assert.AreEqual(0x808080u, AccentPalette.Scale(0xFFFFFF, 0.5019607843));
    }
}
