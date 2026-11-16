// 片段占位符和 mac 同样的期望值（REVIEW R86）：照 mac origin/macos 9acd4306 KittyToolsTests/ContentFormTests.swift 的
// snippetPlaceholders / snippetMorePlaceholders / snippetCursorOffset 搬过来（时区换成直接给 DateTimeOffset）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SnippetMacTests
{
    private static readonly DateTimeOffset Tokyo = new(2026, 9, 26, 13, 5, 0, TimeSpan.FromHours(9));

    private static SnippetExpansion Expand(string template, string? clipboard, params string[] history)
        => SnippetRules.Expand(template, Tokyo, () => Guid.NewGuid().ToString("D").ToUpperInvariant(), () => clipboard,
            n => n <= history.Length ? history[n - 1] : null);

    [TestMethod]
    public void Placeholders()
    {
        var expanded = Expand("日期 {DATE}，剪贴板 {clipboard}{cursor}", "abc");
        Assert.AreEqual("日期 2026-09-26，剪贴板 abc", expanded.Text);
        Assert.AreEqual(0, expanded.CursorBackChars);
        // 没用到 {clipboard} 就不读剪贴板
        var asked = false;
        SnippetRules.Expand("{date}", Tokyo, () => "u", () => { asked = true; return null; }, _ => null);
        Assert.IsFalse(asked);
        Assert.AreEqual("无占位符 {other}", Expand("无占位符 {other}", null).Text);
    }

    [TestMethod]
    public void MorePlaceholders()
    {
        var expanded = Expand("{TIME}|{datetime}|{weekday}|{clipboard:0}|{clipboard:2}|{clipboard:9}|{clipboard}", "当前", "第一条", "第二条");
        Assert.AreEqual("13:05|2026-09-26 13:05|星期六|当前|第二条||当前", expanded.Text);
        var uuids = Expand("{uuid} {uuid}", null).Text.Split(' ');
        Assert.AreEqual(2, uuids.Length);
        Assert.AreNotEqual(uuids[0], uuids[1]);
        Assert.IsTrue(uuids.All(text => Guid.TryParse(text, out _)));
        // 只用到历史时不读剪贴板
        var asked = false;
        SnippetRules.Expand("{clipboard:1}", Tokyo, () => "u", () => { asked = true; return null; }, _ => "x");
        Assert.IsFalse(asked);
    }

    [TestMethod]
    public void CursorOffsetCountsGraphemesAndOnlyTheFirst()
    {
        var result = Expand("Hi {Cursor}, see {clipboard}{cursor}!", "今天");
        Assert.AreEqual("Hi , see 今天!", result.Text);
        Assert.AreEqual(9, result.CursorBackChars);
        Assert.AreEqual(("", 0), (Expand("{cursor}", null).Text, Expand("{cursor}", null).CursorBackChars));
        // \r\n 和带肤色的表情各算一个字
        Assert.AreEqual(4, Expand("a{cursor}b\r\nc👍🏽", null).CursorBackChars);
        Assert.AreEqual(("前", 0), (Expand("前{cursor}", null).Text, Expand("前{cursor}", null).CursorBackChars));
    }

    [TestMethod]
    public void LeavesLooseSpellingsAlone()
    {
        // mac 只认 \{name(:\d)?\}：带空格、两位数、不是数字的都原样留着
        Assert.AreEqual("{ date } {clipboard:12} {clipboard:abc}", Expand("{ date } {clipboard:12} {clipboard:abc}", "x", "h").Text);
    }
}
