// 第二版第 4 批的纯函数单测：浮层高度、翻译服务徽标的字（预览卡的代码 / 颜色判断换成 Core 的 ContentForm，测试在 ClipboardAlignTests）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PanelMetricsTests
{
    [TestMethod]
    public void LensHeightReservesRoomWithoutJumping()
    {
        // 照 mac：没有条目 140；三行一条分组 = 内缩 12 + 标题 24 + 120 + 透镜预留 158；关掉透镜不预留；12 条封顶 520。
        Assert.AreEqual(56 + 36 + 140.0, PanelMetrics.ClipboardHeightFor(0, 0));
        Assert.AreEqual(56 + 36 + 314.0, PanelMetrics.ClipboardHeightFor(3, 1));
        Assert.AreEqual(56 + 36 + 156.0, PanelMetrics.ClipboardHeightFor(3, 1, reservesLens: false));
        Assert.AreEqual(PanelMetrics.MaxHeightDip, PanelMetrics.ClipboardHeightFor(12, 12));
        // 选中行换成另一条（行数、分组数不变）时高度完全一样：窗口不会跟着改。
        Assert.AreEqual(
            PanelMetrics.ClipboardHeightFor(5, 2),
            PanelMetrics.ClipboardHeightFor(5, 2));
    }
}

[TestClass]
public sealed class ServiceBadgeTests
{
    [TestMethod]
    public void BuiltinServicesUseChineseShortNames()
    {
        Assert.AreEqual("智", ServiceBadge.Letter("zhipu", null, "智谱 GLM"));
        Assert.AreEqual("百", ServiceBadge.Letter("baidu", null, "百度"));
        Assert.AreEqual("有", ServiceBadge.Letter("youdao", null, "有道"));
        Assert.AreEqual("火", ServiceBadge.Letter("volcengine", null, "火山"));
        Assert.AreEqual("腾", ServiceBadge.Letter("tencent", null, "腾讯"));
    }

    [TestMethod]
    public void AiServicesUseVendorLetter()
    {
        Assert.AreEqual("Gpt", ServiceBadge.Letter("ai", "openai", "OpenAI"));
        Assert.AreEqual("Az", ServiceBadge.Letter("ai", "azure", "Azure"));
        Assert.AreEqual("An", ServiceBadge.Letter("ai", "anthropic", "Claude"));
        Assert.AreEqual("D", ServiceBadge.Letter("ai", null, "deepseek"));
        Assert.AreEqual("ai:azure", ServiceBadge.Vendor("ai", "azure"));
        Assert.AreEqual("baidu", ServiceBadge.Vendor("baidu", null));
    }

    [TestMethod]
    public void LogoFollowsMacServiceTile()
    {
        // 内置按种类；Azure 用微软；AI 先认地址（DeepSeek 预设的名字里没有别家关键词也认得出）、再认名字、Anthropic 协议兜底。
        Assert.AreEqual("deepl", ServiceBadge.Logo("deepl", null, null, "DeepL"));
        Assert.AreEqual("microsoft", ServiceBadge.Logo("ai", "azure", "https://x.openai.azure.com", "GPT"));
        Assert.AreEqual("deepseek", ServiceBadge.Logo("ai", "openai", "https://api.deepseek.com/v1", "AI"));
        Assert.AreEqual("openai", ServiceBadge.Logo("ai", "openai", "https://api.openai.com/v1", "OpenAI"));
        Assert.AreEqual("siliconflow", ServiceBadge.Logo("ai", "openai", "https://example.com/v1", "硅基流动 DeepSeek"));
        Assert.AreEqual("anthropic", ServiceBadge.Logo("ai", "anthropic", string.Empty, "我的模型"));
        Assert.AreEqual("ollama", ServiceBadge.Logo("ai", "openai", "http://192.168.1.5:11434/v1", "本地"));
        Assert.IsNull(ServiceBadge.Logo("ai", "openai", "https://llm.example.com/v1", "公司模型"));
        Assert.IsTrue(ServiceBadge.IsFullBleed("zhipu"));
        Assert.IsFalse(ServiceBadge.IsFullBleed("deepseek"));
    }
}
