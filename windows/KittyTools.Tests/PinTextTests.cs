// 钉住剪贴板里的文字（PLAN-v16 S3 / S4，照 mac ScreenshotTests.clipboardTextSource / textCardSize 里能在 Core 测的那一半）：
// 去掉首尾空行、留行首缩进，只有空白不算；卡片的上限；剪贴板历史里哪些条目能钉。读剪贴板（有文件、隐私标记）在 App 里。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PinTextTests
{
    [TestMethod]
    public void CleansLeadingAndTrailingBlankLinesButKeepsIndent()
    {
        Assert.AreEqual("  if x {\n    y()\n  }", PinText.Clean("\n  if x {\n    y()\n  }\n\n"));
        Assert.AreEqual("  hello", PinText.Clean("\r\n  hello\r\n"));
        Assert.IsNull(PinText.Clean(" \n\t "));
        Assert.IsNull(PinText.Clean(string.Empty));
        Assert.IsNull(PinText.Clean(null));
    }

    [TestMethod]
    public void CardLimitIsSixtyPercentWideAndEightyPercentTall()
    {
        Assert.AreEqual((480.0, 400.0), PinText.CardLimit(800, 500));
        Assert.AreEqual((560.0, 864.0), PinText.CardLimit(2560, 1080));
    }

    [TestMethod]
    public void OnlyImagesAndRealTextCanBePinned()
    {
        Assert.IsTrue(PinText.CanPin(ClipKind.Image, null));
        Assert.IsTrue(PinText.CanPin(ClipKind.Text, "hello"));
        Assert.IsFalse(PinText.CanPin(ClipKind.Text, "  \n "));
        Assert.IsFalse(PinText.CanPin(ClipKind.Files, @"C:\a.txt"));
    }
}
