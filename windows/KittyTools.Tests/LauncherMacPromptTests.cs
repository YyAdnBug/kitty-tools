// 启动器补全提示认中文叫法和全拼、底栏动词（REVIEW R92，照 mac SystemCommands.Verb.aliases、FileSearch.promptItems、
// LauncherModel.translatePrompts / primaryAction）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherMacPromptTests
{
    [TestMethod]
    public void CommandPromptsKnowChineseAndPinyin()
    {
        string[] Partial(string query) => LauncherCommands.PromptItems(query).Partial.Select(item => item.Target).ToArray();
        CollectionAssert.AreEqual(new[] { "system-port" }, Partial("端口"));
        CollectionAssert.AreEqual(new[] { "system-port" }, Partial("duank"));
        CollectionAssert.AreEqual(new[] { "file-open" }, Partial("文件"));
        CollectionAssert.AreEqual(new[] { "system-kill" }, Partial("进程"));
        CollectionAssert.Contains(Partial("退出"), "system-quit");
        CollectionAssert.Contains(Partial("最小化"), "system-hide");
        // 中文叫法不算正好打对：不排最前
        Assert.AreEqual(0, LauncherCommands.PromptItems("端口").Exact.Count);
        Assert.AreEqual(1, LauncherCommands.PromptItems("port").Exact.Count);
    }

    [TestMethod]
    public void TranslatePromptForChineseGoesAfterLocalResults()
    {
        Assert.AreEqual(1, LauncherCommands.TranslatePrompts("fy").Count);
        Assert.AreEqual(0, LauncherCommands.TranslatePromptsPartial("fy").Count);
        Assert.AreEqual(0, LauncherCommands.TranslatePrompts("翻译").Count);
        Assert.AreEqual("fy ", LauncherCommands.TranslatePromptsPartial("翻译").Single().Completion);
        Assert.AreEqual(1, LauncherCommands.TranslatePromptsPartial("fanyi").Count);
        Assert.AreEqual(0, LauncherCommands.TranslatePromptsPartial("x").Count);
    }

    [TestMethod]
    public void FooterVerbsFollowMac()
    {
        Assert.AreEqual("填进示例", PanelFooterText.LauncherVerb(LauncherKind.Prompt, ExchangeRates.PromptTarget, false).Text);
        Assert.AreEqual("补全货币", PanelFooterText.LauncherVerb(LauncherKind.Prompt, ExchangeRates.SuggestionPrefix + "USD", false).Text);
        Assert.AreEqual("去设置里添加", PanelFooterText.LauncherVerb(LauncherKind.Prompt, PluginOffers.Prefix + "keepAwake", false).Text);
        Assert.AreEqual("补全关键词", PanelFooterText.LauncherVerb(LauncherKind.Prompt, "system-kill", false).Text);
    }
}
