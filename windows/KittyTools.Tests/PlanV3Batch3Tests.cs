// 第三版第 3 批的纯函数单测：片段占位符、{cursor} 的字符数、收藏夹的名字与不变式。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SnippetRulesTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 25, 9, 5, 0, TimeSpan.FromHours(8));

    private static SnippetExpansion Expand(string template, string clipboard = "CURRENT", params string[] history)
        => SnippetRules.Expand(template, Now, Sequential(), clipboard, history);

    /// <summary>每调一次出一个新值，用来看「同一片段里两处、两次粘贴不一样」。</summary>
    private static Func<string> Sequential()
    {
        var count = 0;
        return () => "ABCD-" + (++count);
    }

    [TestMethod]
    public void ReplacesDateAndTime()
    {
        Assert.AreEqual("2026-10-25", Expand("{date}").Text);
        Assert.AreEqual("09:05", Expand("{time}").Text);
        Assert.AreEqual("2026-10-25 09:05", Expand("{datetime}").Text);
        Assert.AreEqual("星期日", Expand("{weekday}").Text);
        Assert.AreEqual("ABCD-1", Expand("{uuid}").Text);
    }

    [TestMethod]
    public void UuidIsNewForEachOccurrenceAndEachPaste()
    {
        // REVIEW R61：同一片段里的两处不一样。
        Assert.AreEqual("ABCD-1-ABCD-2", Expand("{uuid}-{uuid}").Text);

        // 两次粘贴也不一样（用真的生成器，和 Expander 传的一样）。
        static string One() => SnippetRules.Expand(
            "{uuid}", Now, () => Guid.NewGuid().ToString("D").ToUpperInvariant(),
            "CURRENT", Array.Empty<string>()).Text;
        var first = One();
        var second = One();
        Assert.AreNotEqual(first, second);
        Assert.AreEqual(36, first.Length);
    }

    [TestMethod]
    public void KeepsUnknownPlaceholders()
    {
        Assert.AreEqual("{what}", Expand("{what}").Text);
        Assert.AreEqual("a {b", Expand("a {b").Text);
        Assert.AreEqual("2026-10-25", Expand("{DATE}").Text); // 占位符名字不区分大小写
    }

    [TestMethod]
    public void ClipboardUsesCurrentThenHistory()
    {
        Assert.AreEqual("CURRENT", Expand("{clipboard}").Text);
        Assert.AreEqual("CURRENT", Expand("{clipboard:1}").Text);
        Assert.AreEqual("older", Expand("{clipboard:2}", "CURRENT", "CURRENT", "older").Text);
        Assert.AreEqual(string.Empty, Expand("{clipboard:9}", "CURRENT", "CURRENT").Text);
        Assert.AreEqual("first", Expand("{clipboard}", string.Empty, "first").Text);
    }

    [TestMethod]
    public void CursorCountsCharactersAfterIt()
    {
        var expansion = Expand("Hello {cursor}world");
        Assert.AreEqual("Hello world", expansion.Text);
        Assert.AreEqual(5, expansion.CursorBackChars);

        Assert.AreEqual(0, Expand("Hello{cursor}").CursorBackChars);
        Assert.AreEqual(0, Expand("no cursor").CursorBackChars);

        // 超过 500 字按 500 算（不往左挪那么远）
        var longText = new string('x', 800);
        Assert.AreEqual(SnippetRules.MaxCursorBackChars, Expand("{cursor}" + longText).CursorBackChars);
    }

    [TestMethod]
    public void CursorAndPlaceholdersTogether()
    {
        var expansion = Expand("{date} {cursor}{time}");
        Assert.AreEqual("2026-10-25 09:05", expansion.Text);
        Assert.AreEqual(5, expansion.CursorBackChars);
    }
}

[TestClass]
public sealed class ClipGroupRulesTests
{
    [TestMethod]
    public void NormalizesName()
    {
        Assert.AreEqual("工作", ClipGroups.Normalize("  工作  "));
        Assert.IsNull(ClipGroups.Normalize("   "));
        Assert.IsNull(ClipGroups.Normalize(null));
        Assert.AreEqual(24, ClipGroups.Normalize(new string('x', 30))!.Length);
    }

    [TestMethod]
    public void UniquenessIgnoresCaseAndCanIgnoreSelf()
    {
        Assert.IsFalse(ClipGroups.IsUnique("Work", new[] { "work" }));
        Assert.IsTrue(ClipGroups.IsUnique("Work", new[] { "Home" }));
        Assert.IsTrue(ClipGroups.IsUnique("work", new[] { "work" }, ignore: "work"));
        Assert.IsTrue(ClipGroups.IsUnique("work", new[] { "work" }, ignore: "WORK"));
    }

    [TestMethod]
    public void GroupImpliesFavorite()
    {
        Assert.IsTrue(ClipGroups.GroupImpliesFavorite(null, favorite: false));
        Assert.IsTrue(ClipGroups.GroupImpliesFavorite("g", favorite: true));
        Assert.IsFalse(ClipGroups.GroupImpliesFavorite("g", favorite: false));
    }
}
