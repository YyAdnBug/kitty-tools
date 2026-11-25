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

    /// <summary>PLAN-v26 C1：照 mac ContentFormTests.snippetOffsetsFormatsAndInputs（0.10.0 X20）。</summary>
    [TestMethod]
    public void OffsetsFormatsAndInputs()
    {
        string Fill(string text, IReadOnlyDictionary<string, string>? inputs = null)
            => SnippetRules.Expand(text, Tokyo, () => "u", () => null, _ => null, inputs ?? new Dictionary<string, string>()).Text;

        Assert.AreEqual("2026-09-27|2026-09-19|2026-10-26|2027-09-25", Fill("{date+1d}|{date-1w}|{DATE+1M}|{date+1y-1d}"));
        Assert.AreEqual("13:35|11:05|2026-09-27 13:05", Fill("{time+30m}|{time-2h}|{datetime+1d}"));
        Assert.AreEqual("2026/09/26|9月29日|13:05:00", Fill("{date:yyyy/MM/dd}|{date+3d:M月d日}|{time:HH:mm:ss}"));
        Assert.AreEqual("星期日", Fill("{weekday+1d}"));
        Assert.AreEqual("2026-09-26", Fill("{date:}"), "空格式按默认");
        // 认不出的原样：JSON、单位不对、多余的字
        Assert.AreEqual("{\"a\":1} {date+1x} {dates}", Fill("{\"a\":1} {date+1x} {dates}"));
        // 不像日期格式的冒号后面（JS 对象、Python f-string、全角数字的偏移）照旧原样
        foreach (var kept in new[] { "{time: 30}", "{date: today}", "{date:%Y-%m-%d}", "{time: 5 min}", "{date+１d}" })
        {
            Assert.AreEqual(kept, Fill(kept), kept);
        }

        Assert.AreEqual("Day 26", Fill("{date:'Day' d}"));
        // 没问过的（拖出去）：{input…} 原样留着
        Assert.AreEqual("你好 {input:称呼}",
            SnippetRules.Expand("你好 {input:称呼}", Tokyo, () => "u", () => null, _ => null, askedInputs: false).Text);
        // 填空：同名只问一次、几处都填；没写名字的是空串；没填的是空
        const string text = "你好 {input:称呼}，{INPUT:称呼} 的单号 {input: 单号 } {input}";
        CollectionAssert.AreEqual(new[] { "称呼", "单号", string.Empty }, SnippetRules.Inputs(text).ToArray());
        Assert.AreEqual("你好 张三，张三 的单号 42 完",
            Fill(text, new Dictionary<string, string> { ["称呼"] = "张三", ["单号"] = "42", [string.Empty] = "完" }));
        Assert.AreEqual(string.Empty, Fill("{input:x}"));
        Assert.AreEqual(0, SnippetRules.Inputs("{date} {cursor}").Count);
    }

    [TestMethod]
    public void UnicodeFormatPieces()
    {
        var at = new DateTime(2026, 9, 26, 13, 5, 7);
        Assert.AreEqual("26 九月 周六 下午 1:05", SnippetRules.UnicodeFormat(at, "d MMMM EEE a h:mm", TimeSpan.FromHours(9)));
        Assert.AreEqual("26-09-26 星期六 Q3 it's", SnippetRules.UnicodeFormat(at, "yy-MM-dd EEEE 'Q'Q 'it''s'", TimeSpan.Zero));
        Assert.AreEqual("+0900", SnippetRules.UnicodeFormat(at, "Z", TimeSpan.FromHours(9)));
        Assert.IsTrue(SnippetRules.IsDateFormat("yyyy/MM/dd"));
        Assert.IsFalse(SnippetRules.IsDateFormat(" yyyy"));
        Assert.IsFalse(SnippetRules.IsDateFormat("%Y"));
        Assert.IsFalse(SnippetRules.IsDateFormat("today"));
    }
}
