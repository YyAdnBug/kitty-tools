// 启动器「命令」表（PLAN-v18 L2，照 mac LauncherCommandsTests）：存法（改回原来的不存、清空 = 不要别名）、别名换回原关键词、
// 改掉 / 关掉的原关键词挡住、提示行换词或不出、和网页搜索关键词撞了算冲突、别名正好是另一条的关键词时那一条优先。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherCommandTableTests
{
    [TestMethod]
    public void SettingsRoundTrip()
    {
        var settings = LauncherCommandSettings.Empty
            .WithAlias("builtin:kill", " K ", "kill")
            .WithAlias("builtin:quit", "kill", "quit")
            .WithAlias("builtin:quit", "quit", "quit") // 改回原来的：不存
            .WithAlias("system:lock", string.Empty, "lock") // 清空：不要别名
            .WithOn("builtin:ip", false);
        CollectionAssert.AreEquivalent(new[] { "builtin:kill", "system:lock" }, settings.Aliases.Keys.ToArray());
        Assert.AreEqual(" K ", settings.Aliases["builtin:kill"], "存原样，比的时候折叠");
        Assert.AreEqual("k", settings.Alias("builtin:kill", "kill"));
        Assert.IsNull(settings.Alias("system:lock", "lock"));
        Assert.AreEqual("port", settings.Alias("builtin:port", "port"));
        Assert.IsTrue(!settings.IsOn("builtin:ip") && settings.IsOn("builtin:kill"));
        var restored = LauncherCommandTable.FromStored(settings.Aliases, settings.Off);
        Assert.AreEqual(settings, restored);
        Assert.AreEqual(0, LauncherCommandTable.FromStored(new Dictionary<string, string> { ["a"] = new string('x', 40) }, null).Aliases.Count);
    }

    [TestMethod]
    public void CanonicalAndPrompts()
    {
        var settings = new LauncherCommandSettings
        {
            Aliases = new Dictionary<string, string> { ["builtin:kill"] = "k", ["builtin:fy"] = string.Empty },
            Off = new HashSet<string> { "builtin:ip" },
        };
        Assert.AreEqual("kill chrome", LauncherCommandTable.Canonical("K chrome", settings).Query);
        var old = LauncherCommandTable.Canonical("kill chrome", settings);
        Assert.IsTrue(old.Query == "kill chrome" && old.Blocked.Contains("builtin:kill"));
        Assert.IsTrue(LauncherCommandTable.Canonical("ip", settings).Blocked.Contains("builtin:ip"));
        Assert.IsTrue(LauncherCommandTable.Canonical("fy hello", settings).Blocked.Contains("builtin:fy"));
        var plain = LauncherCommandTable.Canonical("open a", LauncherCommandSettings.Empty);
        Assert.IsTrue(plain.Query == "open a" && plain.Blocked.Count == 0);
        // 提示行：改了别名的换词，清空的、关掉的不出
        var kill = LauncherCommands.PromptItems("kill").Exact.Single();
        var relabeled = LauncherCommandTable.Relabel(kill, settings)!;
        Assert.AreEqual("输入「k 空格 进程名或 :端口」，Enter 或 Tab 补全关键词", relabeled.Subtitle);
        Assert.AreEqual("k ", relabeled.Completion);
        var fy = LauncherCommands.TranslatePrompts("fy").Single();
        Assert.IsNull(LauncherCommandTable.Relabel(fy, settings));
        var port = LauncherCommands.PromptItems("port").Exact.Single();
        Assert.AreEqual(port, LauncherCommandTable.Relabel(port, settings));
    }

    [TestMethod]
    public void Conflicts()
    {
        var found = LauncherCommandTable.Conflicts(
            new (string, string?)[] { ("a", "k"), ("b", "k"), ("c", "gh"), ("d", null), ("e", "x") }, new[] { "GH" });
        CollectionAssert.AreEquivalent(new[] { "a", "b", "c" }, found.ToArray());
        Assert.AreEqual(LauncherCommandTable.BuiltIns.Length, LauncherCommandTable.BuiltIns.Select(command => command.Id).Distinct().Count());
    }

    [TestMethod]
    public void AliasEqualToAnotherKeywordKeepsTheOriginal()
    {
        var settings = new LauncherCommandSettings { Aliases = new Dictionary<string, string> { ["builtin:find"] = "open" } };
        Assert.AreEqual("open 报告", LauncherCommandTable.Canonical("open 报告", settings).Query);
        CollectionAssert.AreEqual(new[] { "builtin:find" }, LauncherCommandTable.Canonical("find 报告", settings).Blocked.ToArray());
    }

    [TestMethod]
    public void ReminderAndCurrencyDefaultToEnglish()
    {
        Assert.IsTrue(LauncherCommandTable.BuiltIns.Any(command => command.Id == "builtin:reminder" && command.Keyword == "remind"));
        Assert.IsTrue(LauncherCommandTable.BuiltIns.Any(command => command.Id == "builtin:currency" && command.Keyword == "currency"));
        Assert.AreEqual("builtin:reminder", LauncherCommandTable.BuiltInForPrompt(ReminderLauncher.KeywordTarget)?.Id);
        Assert.AreEqual("builtin:currency", LauncherCommandTable.BuiltInForPrompt(ExchangeRates.PromptTarget)?.Id);
        // 提示里写用户打的那个词，和补进框的一致（mac 15bcac45）
        var tx = ReminderLauncher.Prompts("tx").Single();
        StringAssert.StartsWith(tx.Subtitle, "输入「tx 空格 时间 内容」");
        Assert.AreEqual("tx ", tx.Completion);
        // remind 改成 rm：打 rm（换回 remind）出的提示写 rm
        var settings = new LauncherCommandSettings { Aliases = new Dictionary<string, string> { ["builtin:reminder"] = "rm" } };
        Assert.AreEqual("remind", LauncherCommandTable.Canonical("rm", settings).Query);
        var relabeled = LauncherCommandTable.Relabel(ReminderLauncher.Prompts("remind").Single(), settings)!;
        StringAssert.StartsWith(relabeled.Subtitle, "输入「rm 空格");
        Assert.AreEqual("rm ", relabeled.Completion);
    }
}
