// 来源过滤单测：默认排除的密码管理器、只有文件名 / 带路径、大小写。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ClipboardSourceRulesTests
{
    private static readonly string[] Defaults =
    {
        "KeePass.exe",
        "KeePassXC.exe",
        "1Password.exe",
        "Bitwarden.exe",
    };

    [TestMethod]
    public void DefaultsMatchCaseInsensitively()
    {
        Assert.IsTrue(ClipboardSourceRules.IsExcluded(@"C:\Program Files\KeePass Password Safe\KeePass.exe", Defaults));
        Assert.IsTrue(ClipboardSourceRules.IsExcluded(@"C:\Users\me\keepassxc.EXE", Defaults));
        Assert.IsTrue(ClipboardSourceRules.IsExcluded("1Password.exe", Defaults));
        Assert.IsTrue(ClipboardSourceRules.IsExcluded(@"D:\Bitwarden.exe", Defaults));
    }

    [TestMethod]
    public void UserMayWriteNameWithoutExtension()
    {
        Assert.IsTrue(ClipboardSourceRules.IsExcluded(@"C:\Tools\KeePass.exe", new[] { "KeePass" }));
        Assert.IsTrue(ClipboardSourceRules.IsExcluded(@"C:\Tools\KeePass.exe", new[] { " keepass.exe " }));
    }

    [TestMethod]
    public void OtherAppsPass()
    {
        Assert.IsFalse(ClipboardSourceRules.IsExcluded(@"C:\Windows\notepad.exe", Defaults));
        Assert.IsFalse(ClipboardSourceRules.IsExcluded(null, Defaults));
        Assert.IsFalse(ClipboardSourceRules.IsExcluded("", Defaults));
        Assert.IsFalse(ClipboardSourceRules.IsExcluded("KeePass.exe", Array.Empty<string>()));
        // 只按完整文件名比：KeePass 前缀别的程序不算
        Assert.IsFalse(ClipboardSourceRules.IsExcluded(@"C:\Tools\KeePassBackup.exe", Defaults));
    }
}
