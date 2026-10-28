// 行内 Markdown（PLAN-v9-translate F15）。
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
        Assert.AreEqual("# 标题\n- 一\n", string.Concat(InlineMarkdown.Parse("# 标题\n- 一\n").Select(span => span.Text)));
    }

    [TestMethod]
    public void DetectsMarkdown()
    {
        Assert.IsTrue(InlineMarkdown.Has("**词性** 名词"));
        Assert.IsTrue(InlineMarkdown.Has("见 [文档](https://a.b)"));
        Assert.IsFalse(InlineMarkdown.Has("普通的一句话 * 不算"));
    }
}
