// 自检进程的判断（不登记托盘图标，免得「其他系统托盘图标」里每个探针路径多一条）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AutomatedRunRulesTests
{
    private static string? NoVariables(string name) => null;

    [TestMethod]
    public void SwitchesCount()
    {
        Assert.IsTrue(AutomatedRunRules.IsAutomated(new[] { @"C:\a\KittyTools.exe", "--smoke" }, NoVariables));
        Assert.IsTrue(AutomatedRunRules.IsAutomated(new[] { "x.exe", @"--ui-snapshots=D:\tmp\ui" }, NoVariables));
        Assert.IsTrue(AutomatedRunRules.IsAutomated(new[] { "x.exe", "--CLIP-SCROLL-TEST" }, NoVariables));
        Assert.IsTrue(AutomatedRunRules.IsAutomated(new[] { "x.exe", "--notice-anim-test=out" }, NoVariables));
    }

    [TestMethod]
    public void ManualRunsKeepTheTray()
    {
        Assert.IsFalse(AutomatedRunRules.IsAutomated(new[] { @"C:\a\KittyTools.exe" }, NoVariables));
        // 手动的调试开关：开发时要看托盘。
        Assert.IsFalse(AutomatedRunRules.IsAutomated(new[] { "x.exe", "--notice", "--launcher" }, NoVariables));
        // 只是前缀相同的别的开关不算。
        Assert.IsFalse(AutomatedRunRules.IsAutomated(new[] { "x.exe", "--smoke-free" }, NoVariables));
        // KITTY_PROBE_PROFILE 本身不算（HANDTEST 300 要看探针档的托盘）。
        Assert.IsFalse(AutomatedRunRules.IsAutomated(
            new[] { "x.exe" }, name => name == "KITTY_PROBE_PROFILE" ? "abc" : null));
    }

    [TestMethod]
    public void ProbeVariablesCount()
    {
        Assert.IsTrue(AutomatedRunRules.IsAutomated(
            new[] { "x.exe" }, name => name == "KITTY_MEMORY_PROBE" ? "1" : null));
        Assert.IsTrue(AutomatedRunRules.IsAutomated(
            new[] { "x.exe" }, name => name == "KITTY_RECORD_PROBE_SECONDS" ? "60" : null));
        Assert.IsFalse(AutomatedRunRules.IsAutomated(
            new[] { "x.exe" }, name => name == "KITTY_MEMORY_PROBE" ? string.Empty : null));
    }
}
