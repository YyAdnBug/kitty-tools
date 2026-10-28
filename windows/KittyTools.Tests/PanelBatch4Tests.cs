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
}
