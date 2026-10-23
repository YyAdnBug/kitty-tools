// HotKeyRules 的单测：覆盖 PLAN §5.3 的每一条规则。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HotKeyRulesTests
{
    [TestMethod]
    public void AltCIsAllowed()
    {
        Assert.IsTrue(HotKeyRules.Validate('C', HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void AltSpaceAndAltEAndAltXAreAllowed()
    {
        Assert.IsTrue(HotKeyRules.Validate(HotKeyRules.VkSpace, HotKeyModifiers.Alt).Ok);
        Assert.IsTrue(HotKeyRules.Validate('E', HotKeyModifiers.Alt).Ok);
        Assert.IsTrue(HotKeyRules.Validate('X', HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void FKeyAloneIsAllowed()
    {
        Assert.IsTrue(HotKeyRules.Validate(HotKeyRules.VkF1, HotKeyModifiers.None).Ok);
        Assert.IsTrue(HotKeyRules.Validate(HotKeyRules.VkF24, HotKeyModifiers.None).Ok);
    }

    [TestMethod]
    public void PlainLetterIsRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate('A', HotKeyModifiers.None).Ok);
    }

    [TestMethod]
    public void ShiftAloneIsRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate('A', HotKeyModifiers.Shift).Ok);
        Assert.IsFalse(HotKeyRules.Validate(HotKeyRules.VkF1, HotKeyModifiers.Shift).Ok);
    }

    [TestMethod]
    public void WinCombinationIsRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate('X', HotKeyModifiers.Win).Ok);
        Assert.IsTrue(HotKeyRules.Validate('X', HotKeyModifiers.Control | HotKeyModifiers.Win).Reason!.Contains("Win"));
    }

    [TestMethod]
    public void GenericCtrlKeysAreRejected()
    {
        foreach (var key in new uint[] { 'C', 'V', 'X', 'Z', 'Y', 'A', 'S', 'F', 'W', 'T', 'N', 'P' })
        {
            Assert.IsFalse(HotKeyRules.Validate(key, HotKeyModifiers.Control).Ok, ((char)key).ToString());
        }
    }

    [TestMethod]
    public void CtrlShiftGenericKeyIsStillRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate('C', HotKeyModifiers.Control | HotKeyModifiers.Shift).Ok);
    }

    [TestMethod]
    public void AltSystemKeysAreRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate(0x73, HotKeyModifiers.Alt).Ok); // F4
        Assert.IsFalse(HotKeyRules.Validate(HotKeyRules.VkTab, HotKeyModifiers.Alt).Ok);
        Assert.IsFalse(HotKeyRules.Validate(HotKeyRules.VkEscape, HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void CtrlEscapeAndCtrlAltDeleteAreRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate(HotKeyRules.VkEscape, HotKeyModifiers.Control).Ok);
        Assert.IsFalse(HotKeyRules.Validate(HotKeyRules.VkDelete, HotKeyModifiers.Control | HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void ModifierKeyItselfIsRejected()
    {
        Assert.IsFalse(HotKeyRules.Validate(0x11, HotKeyModifiers.Control).Ok);
        Assert.IsFalse(HotKeyRules.Validate(0x5B, HotKeyModifiers.Alt).Ok);
    }

    [TestMethod]
    public void FormatOrdersModifiers()
    {
        Assert.AreEqual("Ctrl+Alt+Shift+Space",
            HotKeyRules.Format(HotKeyRules.VkSpace, HotKeyModifiers.Shift | HotKeyModifiers.Alt | HotKeyModifiers.Control));
        Assert.AreEqual("Alt+C", HotKeyRules.Format('C', HotKeyModifiers.Alt));
        Assert.AreEqual("F9", HotKeyRules.Format(HotKeyRules.VkF1 + 8, HotKeyModifiers.None));
    }

    [TestMethod]
    public void KeyNamesAreReadable()
    {
        Assert.AreEqual("Space", HotKeyRules.KeyName(HotKeyRules.VkSpace));
        Assert.AreEqual("Enter", HotKeyRules.KeyName(HotKeyRules.VkReturn));
        Assert.AreEqual("Esc", HotKeyRules.KeyName(HotKeyRules.VkEscape));
        Assert.AreEqual("7", HotKeyRules.KeyName('7'));
    }
}
