// Search 和 SensitiveText 的单测：期望值从 mac 版的 SearchTests / ClipboardFilterTests 搬过来。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SearchTests
{
    [TestMethod]
    public void EmptyQueryKeepsOrder()
    {
        var items = new[] { "a", "b" };
        CollectionAssert.AreEqual(items, Filter(items, "  "));
    }

    [TestMethod]
    public void AllTokensMustMatch()
    {
        var items = new[] { "hello world", "hello" };
        CollectionAssert.AreEqual(new[] { "hello world" }, Filter(items, "world HELLO"));
    }

    [TestMethod]
    public void WidthAndCaseInsensitive()
    {
        Assert.AreEqual(1, Filter(new[] { "ＡＢＣ全角" }, "abc").Count);
    }

    [TestMethod]
    public void FilterKeepsOrder()
    {
        // 正文和来源都参与搜索（mac 的 filterKeepsOrder：来源名命中的那条不往前排）。
        var items = new[]
        {
            ("json 正文", ""), ("别的", "json 备注"), ("来自微信", "json 工具"), ("json 更早", ""),
        };
        CollectionAssert.AreEqual(
            new[] { "json 正文", "别的", "来自微信", "json 更早" },
            Filter(items, "json"));
    }

    [TestMethod]
    public void ExcerptStartsNearFirstHit()
    {
        var text = new string('前', 100) + "命中词" + new string('后', 100);
        var excerpt = Search.Excerpt(text, "命中", 40, 40);
        Assert.AreEqual("…" + new string('前', 40) + "命中词" + new string('后', 39) + "…", excerpt);
        Assert.AreEqual("…前前命中词…", Search.Excerpt(text, "后 命中", 2, 1));
        Assert.AreEqual("…789ＳｗｉｆｔＵＩ!", Search.Excerpt("0123456789ＳｗｉｆｔＵＩ!", "swiftui", 3, 5));
    }

    [TestMethod]
    public void ExcerptNilWhenHitIsNearStartOrMissing()
    {
        Assert.IsNull(Search.Excerpt("hello world", "world", 40));
        Assert.IsNull(Search.Excerpt("0123456789abc", "abc", 10));
        Assert.IsNull(Search.Excerpt("hello world", "zzz"));
        Assert.IsNull(Search.Excerpt("hello world", "  "));
    }

    private static List<string> Filter(IEnumerable<string> items, string query)
        => Filter(items.Select(item => (item, "")), query);

    private static List<string> Filter(IEnumerable<(string Text, string Source)> items, string query)
    {
        var tokens = Search.Tokens(query);
        var result = new List<string>();
        foreach (var (text, source) in items)
        {
            var folded = Search.FoldBytes(text + "\n" + source);
            if (tokens.Length == 0 || Search.Matches(folded, tokens))
            {
                result.Add(text);
            }
        }

        return result;
    }
}

[TestClass]
public sealed class SensitiveTextTests
{
    [TestMethod]
    public void CardNumbers()
    {
        Assert.IsTrue(SensitiveText.LooksSensitive("4111 1111 1111 1111"));
        Assert.IsTrue(SensitiveText.LooksSensitive("4111-1111-1111-1111"));
        Assert.IsFalse(SensitiveText.LooksSensitive("1234567890123456"));
        Assert.IsFalse(SensitiveText.LooksSensitive("order 4111111111111111"));
    }

    [TestMethod]
    public void ApiKeys()
    {
        Assert.IsTrue(SensitiveText.LooksSensitive("SK-ABCDEFGHIJ0123456789xyz"));
        Assert.IsTrue(SensitiveText.LooksSensitive("sk-proj-Ab3dEf6hIj9kLmN0pQrStUvWx"));
        Assert.IsTrue(SensitiveText.LooksSensitive("key: sk-ant-api03-AbC123dEf456GhI789jKl"));
        Assert.IsFalse(SensitiveText.LooksSensitive("sk-short1"));
        Assert.IsFalse(SensitiveText.LooksSensitive("desk-organizer-product-description-long"));
        Assert.IsFalse(SensitiveText.LooksSensitive("task-2024-roadmap-planning-document-v2"));
    }

    [TestMethod]
    public void BearerTokens()
    {
        Assert.IsTrue(SensitiveText.LooksSensitive("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6"));
        Assert.IsFalse(SensitiveText.LooksSensitive("Bearer abc123"));
        Assert.IsFalse(SensitiveText.LooksSensitive(
            "OAuth uses a bearer token in the Authorization header; this paragraph explains why."));
    }

    [TestMethod]
    public void OrdinaryText()
    {
        Assert.IsFalse(SensitiveText.LooksSensitive("你好，世界"));
        Assert.IsFalse(SensitiveText.LooksSensitive(string.Concat(Enumerable.Repeat("中文剪贴板内容", 500))));
    }

    [TestMethod]
    public void KnownSecretFormats()
    {
        var hits = new[]
        {
            "token: ghp_" + string.Concat(Enumerable.Repeat("a1B2", 9)),
            "github_pat_" + string.Concat(Enumerable.Repeat("Ab3_", 16)),
            "AKIAIOSFODNN7EXAMPLE",
            "xoxb-1234567890-abcdefghij",
            "AIza" + string.Concat(Enumerable.Repeat("Sy_-9", 7)),
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...",
            "-----BEGIN PRIVATE KEY-----",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "密钥ghp_" + string.Concat(Enumerable.Repeat("a1B2", 9)),
        };
        foreach (var text in hits)
        {
            Assert.IsTrue(SensitiveText.LooksSensitive(text), text);
        }

        var misses = new[]
        {
            "ghp_ 开头的 token 是 GitHub 的个人访问令牌",
            "ghp_short123",
            "xghp_" + string.Concat(Enumerable.Repeat("a1B2", 9)),
            "AKIA 开头的是 AWS 的访问密钥",
            "xoxb-short",
            "BEGIN PRIVATE KEY 是私钥文件的开头",
            "eyJ 开头的一般是 JWT",
        };
        foreach (var text in misses)
        {
            Assert.IsFalse(SensitiveText.LooksSensitive(text), text);
        }
    }

    [TestMethod]
    public void LargeTextStaysFast()
    {
        var prose = string.Concat(Enumerable.Repeat(
            "The night light was high, though the thought of ghosts ghostly eyJ xox AKIA. ", 13_000));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var sensitive = SensitiveText.LooksSensitive(prose);
        watch.Stop();
        Assert.IsFalse(sensitive);
        Assert.IsTrue(watch.Elapsed < TimeSpan.FromMilliseconds(500), watch.Elapsed.ToString());
        Assert.IsTrue(SensitiveText.LooksSensitive(prose + "ghp_" + string.Concat(Enumerable.Repeat("a1B2", 9))));
    }
}
