// PLAN-v26 N1：粘网页、文稿时 HTML 转 Markdown（Core/Notes/NoteRichPaste，照 mac NoteBacklogTests.richTextBecomesMarkdown 的例子，
// 加上谷歌文档、Word 那种用 style 标粗体的写法）。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteRichPasteTests
{
    [TestMethod]
    public void MacExampleBecomesMarkdown()
    {
        const string html = """
            <h1>标题</h1>
            <p>看 <a href="https://example.com/a">这里</a> 和 <b>粗体</b> <s>删掉</s> 跑 <code>ls -l</code></p>
            <ul>
              <li>第一项</li>
              <li>第二项</li>
            </ul>
            <pre>let a = 1</pre>
            <p>结尾</p>
            """;
        Assert.AreEqual("# 标题\n看 [这里](https://example.com/a) 和 **粗体** ~~删掉~~ 跑 `ls -l`\n- 第一项\n- 第二项\n`let a = 1`\n结尾",
            NoteRichPaste.Markdown(html));
    }

    [TestMethod]
    public void PlainHtmlStaysPlain()
    {
        Assert.IsNull(NoteRichPaste.Markdown("<p>just text</p><p>second</p>"), "一个标记都没转出来：照常粘纯文本");
        Assert.IsNull(NoteRichPaste.Markdown(string.Empty));
    }

    [TestMethod]
    public void StyleSpansAndGoogleDocsWrapper()
    {
        // 谷歌文档整段包在 font-weight:normal 的 <b> 里，粗体靠 span 的 style
        const string html = """<b style="font-weight:normal;"><p><span style="font-weight:700">重要</span><span> 和 </span><span style="font-style:italic">斜的</span></p></b>""";
        Assert.AreEqual("**重要** 和 *斜的*", NoteRichPaste.Markdown(html));
    }

    [TestMethod]
    public void NestedAndOrderedLists()
    {
        const string html = "<ol><li><p>一</p><ul><li>里面</li></ul></li><li>二</li></ol>";
        Assert.AreEqual("1. 一\n  - 里面\n1. 二", NoteRichPaste.Markdown(html));
    }

    [TestMethod]
    public void CodeBlocksKeepBlankLines()
    {
        const string html = "<p>看：</p><pre><code>a = 1\n\nb = 2</code></pre>";
        Assert.AreEqual("看：\n```\na = 1\n\nb = 2\n```", NoteRichPaste.Markdown(html));
        Assert.AreEqual("`` a`b ``", NoteRichPaste.Markdown("<code>a`b</code>"), "行内代码里有反引号");
    }

    [TestMethod]
    public void LinksAndEntities()
    {
        Assert.AreEqual("[维基](https://x.org/a_%28b%29)", NoteRichPaste.Markdown("""<a href="https://x.org/a_(b)">维基</a>"""));
        Assert.AreEqual("**a & b**", NoteRichPaste.Markdown("<strong>a &amp; b</strong>"));
        Assert.IsNull(NoteRichPaste.Markdown("""<a href="javascript:alert(1)">x</a>"""), "不是网址的链接不转");
        Assert.AreEqual("前 **粗** 后", NoteRichPaste.Markdown("前 <b> 粗 </b> 后"), "首尾的空白留在标记外面");
    }

    [TestMethod]
    public void RemoteResourcesAndScriptsRemoved()
    {
        const string html = """<style>p{color:red}</style><script>alert(1)</script><p><img src="https://x/y.png"><b>字</b></p>""";
        Assert.AreEqual("**字**", NoteRichPaste.Markdown(html));
    }

    [TestMethod]
    public void TablesUseTabs()
    {
        const string html = "<table><tr><td><b>名</b></td><td>值</td></tr><tr><td>a</td><td>1</td></tr></table>";
        Assert.AreEqual("**名**\t值\na\t1", NoteRichPaste.Markdown(html));
    }

    [TestMethod]
    public void ClipboardFragmentAndFitting()
    {
        const string clip = "Version:0.9\r\nStartHTML:0000000105\r\n<html><body><!--StartFragment--><b>x</b><!--EndFragment--></body></html>";
        Assert.AreEqual("<b>x</b>", NoteRichPaste.Fragment(clip));
        Assert.AreEqual("\n```\nx\n```\n", NoteRichPaste.Fitting("```\nx\n```", 'a', 'b'));
        Assert.AreEqual("```\nx\n```", NoteRichPaste.Fitting("```\nx\n```", '\n', null));
        Assert.AreEqual("**x**", NoteRichPaste.Fitting("**x**", 'a', 'b'));
    }
}
