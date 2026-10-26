// 第三版第 4 批的纯函数单测：链接预览的拦截与解析、多选粘贴的规则、识字命中的那一段。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LinkPreviewRulesTests
{
    [TestMethod]
    public void OnlySingleBareUrl()
    {
        Assert.AreEqual("https://example.com/a", LinkPreviewRules.SingleUrl("https://example.com/a")?.ToString());
        Assert.IsNull(LinkPreviewRules.SingleUrl("看看 https://example.com/a"));
        Assert.IsNull(LinkPreviewRules.SingleUrl("https://example.com/a 后面还有字"));
        Assert.IsNull(LinkPreviewRules.SingleUrl("ftp://example.com/a"));
        Assert.IsNull(LinkPreviewRules.SingleUrl("example.com"));
        Assert.IsNull(LinkPreviewRules.SingleUrl(null));
        Assert.IsNull(LinkPreviewRules.SingleUrl(new string('x', 4001)));
    }

    [TestMethod]
    public void BlocksLocalAndPrivateHosts()
    {
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://localhost:8080/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://127.0.0.1/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://[::1]/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://10.1.2.3/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://172.16.0.1/")));
        Assert.IsTrue(LinkPreviewRules.CanFetch(new Uri("http://172.32.0.1/"))); // 不在私有段，能访问
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://192.168.1.1/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://169.254.1.1/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://nas.local/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("http://intranet/")));
        Assert.IsFalse(LinkPreviewRules.CanFetch(new Uri("https://user:pass@example.com/")));
        Assert.IsTrue(LinkPreviewRules.CanFetch(new Uri("https://example.com/article")));
        Assert.IsTrue(LinkPreviewRules.CanFetch(new Uri("https://example.com/?q=hello")));
    }

    [TestMethod]
    public void BlocksTokenLikeLinks()
    {
        Assert.IsTrue(LinkPreviewRules.LooksLikeToken(
            "/download?token=abc123&signature=deadbeefdeadbeef"));
        Assert.IsTrue(LinkPreviewRules.LooksLikeToken(
            "/x/abcdefghijklmnopqrstuvwxyz0123456789-ABCDEFG"));
        Assert.IsFalse(LinkPreviewRules.LooksLikeToken("/blog/how-to-write-a-snippet"));
        Assert.IsTrue(LinkPreviewRules.IsPrivate("192.168.0.2"));
        Assert.IsTrue(LinkPreviewRules.IsPrivate("::1"));
        Assert.IsTrue(LinkPreviewRules.IsPrivate("fd00::1"));
        Assert.IsFalse(LinkPreviewRules.IsPrivate("8.8.8.8"));
    }

    [TestMethod]
    public void ParsesHeadMetadata()
    {
        var html = """
            <html><head>
            <title> 示例 &amp; 标题 </title>
            <meta property="og:description" content="一段描述">
            <meta name="twitter:image" content="/cover.png">
            <link rel="shortcut icon" href="/favicon.ico">
            </head><body>正文不算</body></html>
            """;
        var preview = LinkPreviewRules.Parse(new Uri("https://news.example.com/a/b"), html);
        Assert.IsNotNull(preview);
        Assert.AreEqual("示例 & 标题", preview!.Title);
        Assert.AreEqual("一段描述", preview.Description);
        Assert.AreEqual("https://news.example.com/cover.png", preview.ImageUrl);
        Assert.AreEqual("https://news.example.com/favicon.ico", preview.IconUrl);
        Assert.AreEqual("news.example.com", preview.Site);
        Assert.AreEqual("https://news.example.com/a/b", preview.Url);

        Assert.IsNull(LinkPreviewRules.Parse(new Uri("https://example.com"), "<html></html>"));
        Assert.IsNull(LinkPreviewRules.Parse(new Uri("https://example.com"), string.Empty));
    }
}

[TestClass]
public sealed class MultiPasteTests
{
    [TestMethod]
    public void ChoosesMode()
    {
        Assert.AreEqual(MultiPasteMode.MergeText, MultiPaste.Mode(3, allText: true, allFiles: false));
        Assert.AreEqual(MultiPasteMode.FilesTogether, MultiPaste.Mode(2, allText: false, allFiles: true));
        Assert.AreEqual(MultiPasteMode.Sequential, MultiPaste.Mode(2, allText: false, allFiles: false));
        Assert.AreEqual(MultiPasteMode.Sequential, MultiPaste.Mode(1, allText: true, allFiles: false));
    }

    [TestMethod]
    public void MergesAndDescribes()
    {
        Assert.AreEqual("a\nb\nc", MultiPaste.Merge(new[] { "a", "b", "c" }));
        Assert.AreEqual("a\nc", MultiPaste.Merge(new[] { "a", string.Empty, "c" }));
        Assert.AreEqual("合并粘贴 3 条", MultiPaste.Verb(MultiPasteMode.MergeText, 3));
        Assert.AreEqual("一起粘贴 2 个文件", MultiPaste.Verb(MultiPasteMode.FilesTogether, 2));
    }

    [TestMethod]
    public void OcrSnippetShowsTheHit()
    {
        var text = "上面是一段无关的话。发票号码 12345678，金额 99 元。下面还有字。";
        var snippet = OcrHit.Snippet(text, new[] { "发票", "金额" });
        Assert.IsNotNull(snippet);
        StringAssert.Contains(snippet!, "发票");
        StringAssert.Contains(snippet!, "12345678");
        Assert.IsTrue(snippet!.Length <= OcrHit.SnippetLength + 2); // 前后各一个省略号
        Assert.IsNull(OcrHit.Snippet(text, new[] { "不存在" }));
        Assert.IsNull(OcrHit.Snippet(null, new[] { "x" }));
        Assert.AreEqual("a b", OcrHit.Clean("a\n\t b"));
    }
}
