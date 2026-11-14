// 应用别名（PLAN-v18 L5 / D10）：键（商店应用 aumid:、桌面应用 exe: + 折过的路径、不认 .lnk）、输完整的别名才认、导入只收认得的。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AppAliasesTests
{
    private static readonly (string, string)[] Folders =
    {
        ("%ProgramFiles%", @"C:\Program Files"),
        ("%ProgramFiles(x86)%", @"C:\Program Files (x86)"),
        ("%LocalAppData%", @"C:\Users\yy\AppData\Local"),
    };

    [TestMethod]
    public void KeysSurviveShortcutMovesAndUpdates()
    {
        Assert.AreEqual("aumid:microsoft.windowscalculator_8wekyb3d8bbwe!app",
            AppAliases.Key(@"shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", null, Folders));
        // 开始菜单的 .lnk 挪了位置，目标 exe 还是那个：键一样
        var a = AppAliases.Key(@"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\VS Code.lnk",
            @"C:\Users\yy\AppData\Local\Programs\Microsoft VS Code\Code.exe", Folders);
        var b = AppAliases.Key(@"C:\Users\yy\Desktop\Code.lnk", @"C:\USERS\yy\AppData\Local\Programs\Microsoft VS Code\Code.exe", Folders);
        Assert.AreEqual(@"exe:%localappdata%\programs\microsoft vs code\code.exe", a);
        Assert.AreEqual(a, b);
        // Program Files (x86) 不会被当成 Program Files 折
        Assert.AreEqual(@"exe:%programfiles(x86)%\foo\foo.exe", AppAliases.Key("x.lnk", @"C:\Program Files (x86)\Foo\Foo.exe", Folders));
        Assert.AreEqual(@"exe:d:\tools\everything.exe", AppAliases.Key(@"D:\Tools\Everything.exe", @"D:\Tools\Everything.exe", Folders));
        Assert.IsNull(AppAliases.Key(@"C:\x\readme.lnk", @"C:\x\readme.txt", Folders));
        Assert.IsNull(AppAliases.Key(@"C:\x\a.lnk", null, Folders));
    }

    [TestMethod]
    public void OnlyTheWholeAliasCounts()
    {
        var aliases = new Dictionary<string, string> { ["exe:a"] = "vs", ["aumid:b"] = " Calc " };
        Assert.AreEqual("exe:a", AppAliases.KeyFor("VS", aliases));
        Assert.AreEqual("aumid:b", AppAliases.KeyFor("calc", aliases));
        Assert.IsNull(AppAliases.KeyFor("v", aliases));
        Assert.IsNull(AppAliases.KeyFor("vsc", aliases));
        Assert.IsNull(AppAliases.KeyFor("  ", aliases));
    }

    [TestMethod]
    public void ImportKeepsKnownKeys()
    {
        var read = AppAliases.Sanitize(new Dictionary<string, string>
        {
            ["exe:a"] = "vs", ["aumid:b"] = "calc", ["com.apple.Safari"] = "sf", ["exe:c"] = " ", ["exe:d"] = new string('x', 40),
        });
        CollectionAssert.AreEquivalent(new[] { "exe:a", "aumid:b" }, read.Keys.ToArray());
    }
}
