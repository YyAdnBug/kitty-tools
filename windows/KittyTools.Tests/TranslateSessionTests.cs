// 翻译会话的纯规则（PLAN-v9-translate 8a）：期望值照 mac KittyToolsTests/TranslateTests.swift 的同名测试。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class TranslateSessionTests
{
    [TestMethod]
    public void PrimaryIsFirstSuccessfulInOrder()
    {
        static int Pick(params (CardState, string)[] cards) => TranslateSession.Primary(cards);

        Assert.AreEqual(0, Pick((CardState.Done, "甲"), (CardState.Done, "乙"), (CardState.Waiting, "")));
        Assert.AreEqual(-1, Pick((CardState.Running, "半"), (CardState.Done, "乙"), (CardState.Done, "丙")));
        Assert.AreEqual(1, Pick((CardState.Failed, ""), (CardState.Done, "乙"), (CardState.Done, "丙")));
        Assert.AreEqual(2, Pick((CardState.Truncated, "半截"), (CardState.Failed, ""), (CardState.Done, "丙")));
        Assert.AreEqual(1, Pick((CardState.Done, ""), (CardState.Done, "乙"), (CardState.Waiting, "")));
        Assert.AreEqual(-1, Pick((CardState.Failed, ""), (CardState.Failed, ""), (CardState.Truncated, "x")));
    }

    [TestMethod]
    public void RewrapKeepsSelectionWhitespace()
    {
        Assert.AreEqual("你好，世界。\n", TranslateSession.Rewrap("你好，世界。 ", "Hello world.\n"));
        Assert.AreEqual("  你好  ", TranslateSession.Rewrap("你好", "  Hello  "));
        Assert.AreEqual("你好", TranslateSession.Rewrap("你好", "\n\n"));
    }

    [TestMethod]
    public void AutoCopyRules()
    {
        Assert.IsTrue(TranslateSession.AutoCopies(true, false, null, "a"));
        Assert.IsFalse(TranslateSession.AutoCopies(true, false, "a", "a"));
        Assert.IsTrue(TranslateSession.AutoCopies(true, false, "a", "ab"));
        Assert.IsFalse(TranslateSession.AutoCopies(true, true, null, "a"));
        Assert.IsFalse(TranslateSession.AutoCopies(false, false, null, "a"));
    }

    [TestMethod]
    public void EditedOnlyWhenTextChanged()
    {
        Assert.IsTrue(TranslateSession.IsEdited("hello", null));
        Assert.IsFalse(TranslateSession.IsEdited(" hello \n", "hello"));
        Assert.IsTrue(TranslateSession.IsEdited("hello!", "hello"));
        Assert.IsFalse(TranslateSession.IsEdited("   ", null));
    }

    [TestMethod]
    public void ExcerptIsFirstLineUpTo24()
    {
        Assert.AreEqual("你好", TranslateSession.Excerpt("  你好 \n"));
        Assert.AreEqual("第一行…", TranslateSession.Excerpt("第一行\n第二行"));
        Assert.AreEqual(new string('a', 24) + "…", TranslateSession.Excerpt(new string('a', 30)));
    }

    [TestMethod]
    public void ModelListUrlAndParsing()
    {
        Assert.AreEqual("https://api.openai.com/v1/models",
            AiEndpoint.ModelsUrl(new Uri("https://api.openai.com/v1/chat/completions"), AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual("https://api.anthropic.com/v1/models?limit=1000",
            AiEndpoint.ModelsUrl(new Uri("https://api.anthropic.com/v1/messages"), AiProtocol.Anthropic)?.ToString());
        CollectionAssert.AreEqual(new[] { "a", "b" },
            AiEndpoint.ParseModels("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"a\"}]}"));
        CollectionAssert.AreEqual(new[] { "llama3" }, AiEndpoint.ParseModels("{\"models\":[{\"name\":\"llama3\"}]}"));
        Assert.AreEqual(0, AiEndpoint.ParseModels("not json").Count);
        CollectionAssert.AreEqual(new[] { "gpt-4o", "gpt-4o-mini" },
            AiEndpoint.ModelSuggestions(new[] { "gpt-4o", "gpt-4o-mini", "o3" }, "GPT"));
        Assert.AreEqual(0, AiEndpoint.ModelSuggestions(new[] { "o3" }, "o3").Count);
        Assert.AreEqual(3, AiEndpoint.ModelSuggestions(new[] { "a", "b", "c" }, " ").Count);
    }

    [TestMethod]
    public void PanelHeightFitsFirstThreeCards()
    {
        Assert.AreEqual(851, TranslateSession.PanelHeight(851, 851, 992));
        Assert.AreEqual(851, TranslateSession.PanelHeight(1080, 851, 992));
        Assert.AreEqual(600, TranslateSession.PanelHeight(600, 400, 992));
        Assert.AreEqual(992 * 0.85, TranslateSession.PanelHeight(1000, 400, 992));
        Assert.AreEqual(825, TranslateSession.PanelHeight(900, 900, 849));
        Assert.AreEqual(220, TranslateSession.PanelHeight(120, 120, 992));
    }
}
