// 第二版第 4 批的纯函数单测：浮层高度、预览卡的代码 / 颜色判断、翻译服务徽标的字。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PanelMetricsTests
{
    [TestMethod]
    public void HeightsFollowRowsWithMinAndMax()
    {
        Assert.AreEqual(PanelMetrics.LauncherChrome + 3 * PanelMetrics.LauncherRowHeight, PanelMetrics.LauncherHeight(1));
        Assert.AreEqual(PanelMetrics.LauncherChrome + 8 * PanelMetrics.LauncherRowHeight, PanelMetrics.LauncherHeight(9));
        Assert.AreEqual(PanelMetrics.LauncherChrome + 8 * PanelMetrics.LauncherRowHeight, PanelMetrics.LauncherHeight(40));
    }

    [TestMethod]
    public void LauncherShowsAtLeastAsMuchAsClipboardPerRow()
    {
        // PLAN-v7 U3：启动器一行 40，和剪贴板一样高；同样行数时两者只差顶栏 / 底栏的 6 DIP。
        Assert.IsTrue(PanelMetrics.LauncherHeight(5) <= PanelMetrics.ClipboardHeightFor(5, 1, reservesLens: false));
    }

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
public sealed class PreviewRulesTests
{
    [TestMethod]
    public void DetectsCode()
    {
        Assert.IsTrue(PreviewRules.LooksLikeCode("{\n    \"a\": 1,\n    \"b\": [1, 2]\n}"));
        Assert.IsTrue(PreviewRules.LooksLikeCode("const value = Compute(input);\nreturn value;"));
        Assert.IsTrue(PreviewRules.LooksLikeCode("def hello(name):\n    print(name)"));
        Assert.IsTrue(PreviewRules.LooksLikeCode("```csharp\nvar x = 1;\n```"));
    }

    [TestMethod]
    public void DoesNotTreatPlainTextAsCode()
    {
        Assert.IsFalse(PreviewRules.LooksLikeCode("今天下午三点开会，记得带电脑。"));
        Assert.IsFalse(PreviewRules.LooksLikeCode("hello world"));
        Assert.IsFalse(PreviewRules.LooksLikeCode("12345"));
        Assert.IsFalse(PreviewRules.LooksLikeCode(null));
        Assert.IsFalse(PreviewRules.LooksLikeCode(string.Empty));
    }

    [TestMethod]
    public void ParsesColorValues()
    {
        Assert.IsTrue(PreviewRules.TryParseColor("#FF4D7E", out var r, out var g, out var b));
        Assert.AreEqual((255, 77, 126), ((int)r, (int)g, (int)b));

        Assert.IsTrue(PreviewRules.TryParseColor("#f00", out r, out g, out b));
        Assert.AreEqual((255, 0, 0), ((int)r, (int)g, (int)b));

        Assert.IsTrue(PreviewRules.TryParseColor("#CCFF4D7E", out r, out g, out b));
        Assert.AreEqual((255, 77, 126), ((int)r, (int)g, (int)b));

        Assert.IsTrue(PreviewRules.TryParseColor("rgb(0, 120, 255)", out r, out g, out b));
        Assert.AreEqual((0, 120, 255), ((int)r, (int)g, (int)b));

        Assert.IsTrue(PreviewRules.TryParseColor("rgba(10, 20, 30, 0.5)", out r, out g, out b));
        Assert.AreEqual((10, 20, 30), ((int)r, (int)g, (int)b));

        Assert.IsFalse(PreviewRules.TryParseColor("#FF4D7", out _, out _, out _));
        Assert.IsFalse(PreviewRules.TryParseColor("rgb(1,2)", out _, out _, out _));
        Assert.IsFalse(PreviewRules.TryParseColor("这是红色", out _, out _, out _));
        Assert.IsFalse(PreviewRules.TryParseColor(null, out _, out _, out _));
    }

    [TestMethod]
    public void SourceAndAgeJoinsWithMiddleDot()
    {
        Assert.AreEqual("Chrome · 3 分钟前", PreviewRules.SourceAndAge("Chrome", "3 分钟前"));
        Assert.AreEqual("3 分钟前", PreviewRules.SourceAndAge("  ", "3 分钟前"));
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
