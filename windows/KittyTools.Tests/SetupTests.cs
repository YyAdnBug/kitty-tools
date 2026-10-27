// 安装程序（PLAN-setup-inno）和 App 对得上的名字、路径比较的单测；安装 / 卸载本身走 tools/setup-e2e.ps1。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SetupRulesTests
{
    [TestMethod]
    public void TestKeyRenamesEverything()
    {
        var real = SetupRules.NamesFor(null);
        Assert.AreEqual("{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}_is1", real.UninstallKey);
        Assert.AreEqual("KittyTools", real.RunValue);
        Assert.AreEqual("Kitty Tools.lnk", real.ShortcutFile);
        Assert.AreEqual("KittyTools/", real.CredentialPrefix);
        Assert.AreEqual(@"Local\KittyTools", real.MutexName);
        Assert.AreEqual("KittyTools.Instance", real.PipeName);
        Assert.AreEqual("KittyTools", real.DataFolder);
        Assert.AreEqual("KittyTools-uninstall.log", real.LogFile);
        Assert.IsNull(real.ProbeProfile);
        Assert.AreEqual(real, SetupRules.NamesFor(string.Empty));

        // 和 App 的 KITTY_PROBE_PROFILE=e2e1 那一套同名（App/Paths.cs 的 Release 分支），
        // 也和 installer/KittyTools.iss 里 TestKey=e2e1 时的 #define 同名。
        var test = SetupRules.NamesFor("e2e1");
        Assert.AreEqual("KittyTools.Test.e2e1_is1", test.UninstallKey);
        Assert.AreEqual("KittyTools.Probe.e2e1", test.RunValue);
        Assert.AreEqual("Kitty Tools.Test.e2e1.lnk", test.ShortcutFile);
        Assert.AreEqual("KittyTools/.Probe.e2e1", test.CredentialPrefix);
        Assert.AreEqual(@"Local\KittyTools.Probe.e2e1", test.MutexName);
        Assert.AreEqual("KittyTools.Instance.Probe.e2e1", test.PipeName);
        Assert.AreEqual("KittyTools.Probe.e2e1", test.DataFolder);
        Assert.AreEqual("KittyTools.Probe.e2e1-uninstall.log", test.LogFile);
        Assert.AreEqual("e2e1", test.ProbeProfile);

        foreach (var bad in new[] { "a b", @"..\x", "测试", new string('a', 33) })
        {
            Assert.ThrowsExactly<ArgumentException>(() => SetupRules.NamesFor(bad), bad);
        }
    }

    [TestMethod]
    public void SamePathIgnoresCaseAndTrailingSlash()
    {
        // Inno 写的 InstallLocation 末尾带 \。
        Assert.IsTrue(SetupRules.SamePath(@"C:\Users\a\AppData\Local\Programs\Kitty Tools\", @"c:\users\a\appdata\local\programs\kitty tools"));
        Assert.IsTrue(SetupRules.SamePath("D:/Apps/Kitty Tools", @"D:\Apps\Kitty Tools"));
        Assert.IsFalse(SetupRules.SamePath(@"D:\Apps\Kitty Tools", @"D:\Apps\Kitty Tools 2"));
        Assert.AreEqual(@"C:\", SetupRules.Normalize("C:"));
    }
}
