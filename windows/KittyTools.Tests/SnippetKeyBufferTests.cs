// PLAN-v26 第 5 批（C5）：打关键词展开认关键词的那一小段，期望值照 mac SnippetExpanderTests（键码换成 Windows 的虚拟键码）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SnippetKeyBufferTests
{
    private static List<string> Type(string text, SnippetKeyBuffer buffer, params string[] keywords)
    {
        var set = keywords.ToHashSet(StringComparer.Ordinal);
        return text.Select(c => buffer.Press(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Characters, c.ToString()), set))
            .OfType<string>().ToList();
    }

    [TestMethod]
    public void Classify()
    {
        Assert.AreEqual(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Characters, "a"), SnippetKeyBuffer.Classify(0x41, false, false, false, "a"));
        Assert.AreEqual(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Characters, "A"), SnippetKeyBuffer.Classify(0x41, false, false, false, "A"));
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Characters, SnippetKeyBuffer.Classify(0x51, true, true, false, "@").Kind, "AltGr 打出来的字照常算");
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Reset, SnippetKeyBuffer.Classify(0x56, true, false, false, string.Empty).Kind, "Ctrl+V");
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Reset, SnippetKeyBuffer.Classify(0x41, true, false, false, "\u0001").Kind);
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Reset, SnippetKeyBuffer.Classify(0x52, false, false, true, "r").Kind, "Win+R");
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Backspace, SnippetKeyBuffer.Classify(0x08, false, false, false, "\b").Kind);
        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Reset, SnippetKeyBuffer.Classify(0x08, true, false, false, string.Empty).Kind, "Ctrl+Backspace 删一个词");
        foreach (var key in new uint[] { 0x2E, 0x25, 0x26, 0x27, 0x28, 0x24, 0x23, 0x21, 0x22, 0x0D, 0x09, 0x1B, 0x70, 0x87 })
        {
            Assert.AreEqual(SnippetKeyBuffer.KeyKind.Reset, SnippetKeyBuffer.Classify(key, false, false, false, string.Empty).Kind, key.ToString("X"));
        }

        Assert.AreEqual(SnippetKeyBuffer.KeyKind.Ignore, SnippetKeyBuffer.Classify(0xDE, false, false, false, string.Empty).Kind, "死键的第一下");
    }

    [TestMethod]
    public void MatchesAtWordStartOnly()
    {
        var buffer = new SnippetKeyBuffer();
        CollectionAssert.AreEqual(new[] { ";mail" }, Type("hi ;mail", buffer, ";mail", "omyx", "ail"));
        Assert.AreEqual(string.Empty, buffer.Text, "认出来就清空");
        Assert.AreEqual(0, Type("roomyx", buffer, ";mail", "omyx", "ail").Count);
        buffer.Reset();
        CollectionAssert.AreEqual(new[] { "omyx" }, Type("omyx", buffer, ";mail", "omyx", "ail"));
        Assert.AreEqual(0, Type("a;mail", buffer, ";mail", "omyx", "ail").Count);
        buffer.Reset();
        Assert.AreEqual(0, Type("1omyx", buffer, ";mail", "omyx", "ail").Count);
        buffer.Reset();
        CollectionAssert.AreEqual(new[] { "omyx" }, Type("(omyx", buffer, ";mail", "omyx", "ail"));
    }

    [TestMethod]
    public void BackspaceAndResets()
    {
        var keywords = new HashSet<string> { ";mail" };
        var buffer = new SnippetKeyBuffer();
        Assert.AreEqual(0, Type(";maik", buffer, ";mail").Count);
        Assert.IsNull(buffer.Press(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Backspace), keywords));
        CollectionAssert.AreEqual(new[] { ";mail" }, Type("l", buffer, ";mail"));
        Assert.AreEqual(0, Type(";ma", buffer, ";mail").Count);
        Assert.IsNull(buffer.Press(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Reset), keywords));
        Assert.AreEqual(0, Type("il", buffer, ";mail").Count);
        buffer.Reset();
        Assert.IsNull(buffer.Press(new SnippetKeyBuffer.Key(SnippetKeyBuffer.KeyKind.Backspace), keywords), "打到空了照样没事");
    }

    [TestMethod]
    public void PrefersLongestAndKeepsCapacity()
    {
        var buffer = new SnippetKeyBuffer();
        CollectionAssert.AreEqual(new[] { ";mail" }, Type(" ;mail", buffer, ";mail", "mail"));
        buffer.Reset();
        CollectionAssert.AreEqual(new[] { "xmail" }, Type(" xmail", buffer, "xmail", "mail"));
        buffer.Reset();
        CollectionAssert.AreEqual(new[] { ";sig" }, Type(";sig", buffer, ";sig", ";sig2"));
        buffer = new SnippetKeyBuffer { Capacity = 5 };
        Assert.AreEqual(0, Type("x;sig", buffer, ";sig").Count);
        CollectionAssert.AreEqual(new[] { ";sig" }, Type(" ;sig", buffer, ";sig"));
        buffer = new SnippetKeyBuffer { Capacity = 4 };
        Type("abcdefgh", buffer);
        Assert.AreEqual("efgh", buffer.Text);
    }
}
