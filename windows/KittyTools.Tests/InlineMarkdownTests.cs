// 翻译结果的 Markdown（PLAN-v9-translate F15；块级 2026-10-29）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class InlineMarkdownTests
{
    [TestMethod]
    public void BoldItalicCodeAndLinks()
    {
        var spans = InlineMarkdown.Parse("a **b** *c* `d` ~~e~~ [f](https://x.com)");
        Assert.AreEqual("a ", spans[0].Text);
        Assert.IsTrue(spans[1] is { Text: "b", Bold: true });
        Assert.IsTrue(spans.Any(span => span is { Text: "c", Italic: true }));
        Assert.IsTrue(spans.Any(span => span is { Text: "d", Code: true }));
        Assert.IsTrue(spans.Any(span => span is { Text: "e", Strike: true }));
        Assert.IsTrue(spans.Any(span => span is { Text: "f", Link: "https://x.com" }));
    }

    [TestMethod]
    public void UnpairedMarkersStayLiteral()
    {
        Assert.AreEqual("2 * 3 * 4", string.Concat(InlineMarkdown.Parse("2 * 3 * 4").Select(span => span.Text)));
        Assert.AreEqual("**open", string.Concat(InlineMarkdown.Parse("**open").Select(span => span.Text)));
        Assert.AreEqual("snake_case_name", string.Concat(InlineMarkdown.Parse("snake_case_name").Select(span => span.Text)));
        Assert.IsTrue(InlineMarkdown.Parse("[x](javascript:alert)").All(span => span.Link is null));
        Assert.AreEqual("#tag", Text("#tag"));
        Assert.AreEqual("-- 注释", Text("-- 注释"));
        Assert.AreEqual("1. 第一步", Text("1. 第一步"));
    }

    [TestMethod]
    public void BlockMarkers()
    {
        Assert.AreEqual("标题\n• 一\n  • 二\n• 三\n", Text("## 标题\n- 一\n  * 二\n+ 三\n"));
        Assert.IsTrue(InlineMarkdown.Parse("# **重点** 说明").All(span => span.Bold));
        Assert.IsTrue(InlineMarkdown.Parse("> 引用 **粗**").All(span => span.Dim));
        Assert.AreEqual("引用 粗", Text("> 引用 **粗**"));
        Assert.IsTrue(InlineMarkdown.Parse("上\n---\n下").Any(span => span is { Dim: true, Text: "────────" }));

        // 围栏行去掉，里面的行等宽、不解析行内记号。
        var code = InlineMarkdown.Parse("看：\n```cs\nvar a = **b**;\n```\n完");
        Assert.AreEqual("看：\nvar a = **b**;\n完", string.Concat(code.Select(span => span.Text)));
        Assert.IsTrue(code.Any(span => span is { Code: true, Text: "var a = **b**;" }));

        // 行内记号不跨行配对。
        Assert.AreEqual("**一\n二**", Text("**一\n二**"));
    }

    [TestMethod]
    public void DetectsMarkdown()
    {
        Assert.IsTrue(InlineMarkdown.Has("**词性** 名词"));
        Assert.IsTrue(InlineMarkdown.Has("见 [文档](https://a.b)"));
        Assert.IsFalse(InlineMarkdown.Has("普通的一句话 * 不算"));
        Assert.IsTrue(InlineMarkdown.Has("第一行\n# 标题"));
        Assert.IsTrue(InlineMarkdown.Has("- 一\n- 二"));
        Assert.IsTrue(InlineMarkdown.Has("> 引用"));
        Assert.IsFalse(InlineMarkdown.Has("#tag 和 1. 编号"));
    }

    private static string Text(string markdown) => string.Concat(InlineMarkdown.Parse(markdown).Select(span => span.Text));
}
