// 翻译纯函数单测：语言解析 / 检测、流式清洗、SSE、AI 地址与分档、复制即译过滤。
// 期望值从 mac 的 TranslateTests 搬；Windows 没有 NaturalLanguage，按书写系统检测的差异写在注释里。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LangTests
{
    private static LangPlan Resolve(Lang? source, Lang? target, Lang? detected)
        => Langs.Resolve(source, target, detected, Lang.ZhHans, Lang.En);

    [TestMethod]
    public void AutoTargetUsesFirstAndSecondLanguage()
    {
        Assert.AreEqual(new LangPlan(null, Lang.En, false), Resolve(null, null, Lang.ZhHans));
        Assert.AreEqual(new LangPlan(null, Lang.En, false), Resolve(null, null, Lang.ZhHant));
        Assert.AreEqual(new LangPlan(null, Lang.ZhHans, false), Resolve(null, null, Lang.Ja));
        Assert.AreEqual(new LangPlan(null, Lang.ZhHans, false), Resolve(null, null, null));
        Assert.AreEqual(new LangPlan(null, Lang.Ja, false), Resolve(null, Lang.Ja, Lang.En));
    }

    [TestMethod]
    public void FixedTargetEqualToTextFallsBackToAuto()
    {
        Assert.AreEqual(new LangPlan(null, Lang.ZhHans, true), Resolve(null, Lang.Ja, Lang.Ja));
        Assert.AreEqual(new LangPlan(null, Lang.En, true), Resolve(null, Lang.ZhHans, Lang.ZhHans));
        // 简体原文、固定目标繁体：是用户要的转换，不算同语言
        Assert.AreEqual(new LangPlan(null, Lang.ZhHant, false), Resolve(null, Lang.ZhHant, Lang.ZhHans));
    }

    [TestMethod]
    public void FixedSourceIsTrusted()
    {
        Assert.AreEqual(new LangPlan(Lang.En, Lang.Ja, false), Resolve(Lang.En, Lang.Ja, Lang.ZhHans));
        Assert.AreEqual(new LangPlan(Lang.En, Lang.ZhHans, false), Resolve(Lang.En, null, Lang.ZhHans));
        Assert.AreEqual(new LangPlan(Lang.ZhHans, Lang.En, false), Resolve(Lang.ZhHans, null, Lang.Ja));
        Assert.AreEqual(new LangPlan(Lang.En, Lang.ZhHans, false), Resolve(Lang.En, Lang.En, Lang.En));
    }

    [TestMethod]
    public void PreferredPairNeverRepeats()
    {
        Assert.AreEqual((Lang.ZhHans, Lang.En), Langs.Pair(null, null));
        Assert.AreEqual((Lang.Ja, Lang.En), Langs.Pair("ja", "ja"));
        Assert.AreEqual((Lang.En, Lang.ZhHans), Langs.Pair("en", "en"));
        Assert.AreEqual((Lang.ZhHans, Lang.En), Langs.Pair("zh-Hans", "zh-Hant"));
        Assert.AreEqual((Lang.ZhHans, Lang.En), Langs.Pair("zh-hans", "en-us"));
    }

    [TestMethod]
    public void DetectionByWritingSystem()
    {
        Assert.AreEqual(Lang.ZhHans, Langs.Detect("今天天气很好，我们去公园散步吧"));
        Assert.AreEqual(Lang.En, Langs.Detect("The quick brown fox jumps over the lazy dog"));
        Assert.AreEqual(Lang.Ja, Langs.Detect("こんにちは、元気ですか"));
        Assert.AreEqual(Lang.Ko, Langs.Detect("안녕하세요 반갑습니다"));
        Assert.AreEqual(Lang.Ru, Langs.Detect("Привет, как дела?"));
        Assert.IsNull(Langs.Detect("12345"));
        Assert.IsNull(Langs.Detect("  \n\t "));
    }

    [TestMethod]
    public void DetectionUsesPreferredChineseVariant()
    {
        var preferred = new[] { Lang.ZhHant, Lang.En };
        Assert.AreEqual(Lang.ZhHant, Langs.Detect("你好", preferred));
        Assert.AreEqual(Lang.ZhHant, Langs.Detect("頭髮", preferred));
        // Windows 不细分简繁：只有一个「汉字」信号，按偏好选。
        Assert.AreEqual(Lang.En, Langs.Detect("API", preferred));
    }

    [TestMethod]
    public void DetectionOfMixedCjkAndLatin()
    {
        var preferred = new[] { Lang.ZhHans, Lang.En };
        Assert.AreEqual(Lang.ZhHans, Langs.Detect("请帮我 review 一下这个 PR", preferred));
        Assert.AreEqual(Lang.ZhHans, Langs.Detect("iPhone 17 Pro Max 发布了", preferred));
        Assert.AreEqual(Lang.Ja, Langs.Detect("このアプリは iPhone で動く", preferred));
        Assert.AreEqual(Lang.En, Langs.Detect("The word 猫 means cat in Chinese", preferred));
    }

    [TestMethod]
    public void UrlAndPathLike()
    {
        Assert.IsTrue(Langs.IsUrlLike("https://example.com/a?b=c"));
        Assert.IsTrue(Langs.IsUrlLike("www.example.com"));
        Assert.IsFalse(Langs.IsUrlLike("see https://example.com for details"));
        Assert.IsTrue(Langs.IsPathLike("/usr/local/bin/swift"));
        Assert.IsTrue(Langs.IsPathLike("~/Library/Application Support"));
        Assert.IsTrue(Langs.IsPathLike(@"C:\Windows\notepad.exe"));
        Assert.IsTrue(Langs.IsPathLike(@"\\server\share\file.txt"));
        Assert.IsFalse(Langs.IsPathLike("这是一段中文"));
    }
}

[TestClass]
public sealed class StreamingTextTests
{
    [TestMethod]
    public void StripsLeadingThinkEvenWhenSplit()
    {
        var text = new StreamingText();
        text.Append("<thi");
        Assert.AreEqual(string.Empty, text.Visible);
        Assert.IsTrue(text.IsThinking);
        text.Append("nk>想一想");
        Assert.AreEqual(string.Empty, text.Visible);
        Assert.IsTrue(text.IsThinking);
        text.Append("</think>你好");
        Assert.AreEqual("你好", text.Visible);
        Assert.IsFalse(text.IsThinking);
        Assert.AreEqual("你好", text.Final);
    }

    [TestMethod]
    public void KeepsInnerTagsAndStripsOuterQuotes()
    {
        var text = new StreamingText();
        text.Append("“你好，世界”");
        Assert.AreEqual("你好，世界", text.Final);

        var inner = new StreamingText();
        inner.Append("用 <think> 标签");
        Assert.AreEqual("用 <think> 标签", inner.Final);

        var quoted = new StreamingText();
        quoted.Append("\"a\" and \"b\"");
        Assert.AreEqual("\"a\" and \"b\"", quoted.Final);
    }

    [TestMethod]
    public void EmptyAndWhitespace()
    {
        var text = new StreamingText();
        Assert.AreEqual(string.Empty, text.Visible);
        Assert.IsFalse(text.IsThinking);
        text.Append("  \n ");
        Assert.AreEqual(string.Empty, text.Final);
    }
}

[TestClass]
public sealed class SseTests
{
    [TestMethod]
    public void ParsesDataLines()
    {
        Assert.IsTrue(Sse.TryPayload("data: {\"a\":1}\r", out var payload));
        Assert.AreEqual("{\"a\":1}", payload);
        Assert.IsTrue(Sse.TryPayload("data:[DONE]", out var done));
        Assert.IsTrue(Sse.IsDone(done));
        Assert.IsFalse(Sse.TryPayload("event: message", out _));
        Assert.IsFalse(Sse.TryPayload("", out _));
    }
}

[TestClass]
public sealed class AiEndpointTests
{
    [TestMethod]
    public void ResolvesEndpoints()
    {
        Assert.AreEqual(
            "https://api.openai.com/v1/chat/completions",
            AiEndpoint.Resolve("https://api.openai.com/v1", AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual(
            "https://api.deepseek.com/v1/chat/completions",
            AiEndpoint.Resolve("api.deepseek.com", AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual(
            "http://127.0.0.1:11434/v1/chat/completions",
            AiEndpoint.Resolve("http://127.0.0.1:11434/v1/", AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual(
            "https://x.com/v1/chat/completions",
            AiEndpoint.Resolve("https://x.com/v1/chat/completions", AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual(
            "https://r.openai.azure.com/openai/v1/chat/completions",
            AiEndpoint.Resolve("https://r.openai.azure.com/openai/v1", AiProtocol.Azure)?.ToString());
        Assert.AreEqual(
            "https://api.ohmygpt.com/v1beta/chat/completions",
            AiEndpoint.Resolve("https://api.ohmygpt.com/v1beta", AiProtocol.OpenAi)?.ToString());
        Assert.AreEqual(
            "https://api.anthropic.com/v1/messages",
            AiEndpoint.Resolve("", AiProtocol.Anthropic)?.ToString());
        Assert.IsNull(AiEndpoint.Resolve("", AiProtocol.OpenAi));
    }

    [TestMethod]
    public void MaxTokensAndTiers()
    {
        var zhipu = new Uri("https://open.bigmodel.cn/api/paas/v4/chat/completions");
        var openAi = new Uri("https://api.openai.com/v1/chat/completions");
        var local = new Uri("http://192.168.1.8:8000/v1/chat/completions");
        Assert.AreEqual(1024, AiEndpoint.MaxTokens(zhipu, AiProtocol.OpenAi));
        Assert.IsNull(AiEndpoint.MaxTokens(openAi, AiProtocol.OpenAi));
        Assert.AreEqual(4096, AiEndpoint.MaxTokens(local, AiProtocol.OpenAi));

        Assert.AreEqual(1, AiEndpoint.Tiers(openAi, AiProtocol.OpenAi, "gpt-4o").Count);
        Assert.IsTrue(AiEndpoint.Tiers(zhipu, AiProtocol.OpenAi, "glm-4-flash")[0].ContainsKey("thinking"));
        Assert.IsTrue(AiEndpoint.Tiers(local, AiProtocol.OpenAi, "qwen3")[0].ContainsKey("chat_template_kwargs"));
        Assert.AreEqual(0, AiEndpoint.Tiers(openAi, AiProtocol.OpenAi, "gpt-5")[^1].Count);
    }

    [TestMethod]
    public void LocalNetwork()
    {
        foreach (var host in new[]
                 {
                     "http://localhost:1234", "http://127.0.0.1", "http://10.0.0.2", "http://172.20.1.1",
                     "http://192.168.0.5", "http://nas.local", "http://mybox", "http://[::1]:8080",
                 })
        {
            Assert.IsTrue(AiEndpoint.IsLocalNetwork(new Uri(host)), host);
        }

        foreach (var host in new[]
                 {
                     "https://api.openai.com", "http://172.32.0.1", "https://8.8.8.8",
                     "https://fcdn.example.com",
                 })
        {
            Assert.IsFalse(AiEndpoint.IsLocalNetwork(new Uri(host)), host);
        }
    }

    [TestMethod]
    public void VendorByHostAndName()
    {
        Assert.AreEqual(AiVendor.Zhipu, AiEndpoint.VendorOf(new Uri("https://open.bigmodel.cn/api")));
        Assert.AreEqual(AiVendor.OpenAi, AiEndpoint.VendorOf(new Uri("https://api.openai.com/v1")));
        Assert.AreEqual(AiVendor.Anthropic, AiEndpoint.VendorOf(new Uri("https://api.anthropic.com/v1")));
        Assert.AreEqual(AiVendor.Ollama, AiEndpoint.VendorOf(new Uri("http://127.0.0.1:11434/v1")));
        Assert.AreEqual(AiVendor.DeepSeek, AiEndpoint.VendorOfName("我的 DeepSeek"));
        Assert.AreEqual(AiVendor.SiliconFlow, AiEndpoint.VendorOfName("硅基流动 DeepSeek"));
        Assert.IsTrue(AiEndpoint.IsOpenCode(new Uri("https://opencode.ai/zen/v1/chat/completions")));
        Assert.IsFalse(AiEndpoint.IsOpenCode(new Uri("https://notopencode.ai/v1")));
    }
}

[TestClass]
public sealed class CopyTranslateRulesTests
{
    private static bool Worth(string text, string? translated = null, bool autoTarget = true)
        => CopyTranslateRules.WorthTranslating(text, translated, Lang.ZhHans, Lang.En, autoTarget);

    [TestMethod]
    public void FiltersOrdinaryCases()
    {
        Assert.IsTrue(Worth("The quick brown fox jumps over the lazy dog."));
        Assert.IsFalse(Worth("https://example.com/a?b=c"));
        Assert.IsFalse(Worth("file:///C:/Users/yy/a.txt"));
        Assert.IsTrue(Worth("see https://example.com for details"));
        Assert.IsFalse(Worth("/usr/local/bin/swift"));
        Assert.IsFalse(Worth("~/Library/Application Support"));
        Assert.IsFalse(Worth(@"C:\Windows\notepad.exe"));
        Assert.IsFalse(Worth("123 456.78 %"));
        Assert.IsFalse(Worth("  \n "));
        Assert.IsFalse(Worth(string.Concat(Enumerable.Repeat("a ", CopyTranslateRules.MaxSourceBytes))));
    }

    [TestMethod]
    public void SkipsTextAlreadyInFirstLanguageOnlyWhenTargetIsAuto()
    {
        Assert.IsFalse(Worth("这是一段中文"));
        Assert.IsTrue(Worth("这是一段中文", autoTarget: false));
        Assert.IsFalse(Worth(" Ship it \n", translated: "Ship it"));
        Assert.IsTrue(Worth("Ship it", translated: "Ship"));
    }
}
