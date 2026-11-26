// 应用别名（PLAN-v18 L5 / D10）：键（商店应用 aumid:、桌面应用 exe: + 折过的路径、不认 .lnk）、输完整的别名才认、导入只收认得的；
// PLAN-v27 B5：一个应用几个别名、别名也当名字搜。
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

    [TestMethod]
    public void SeveralAliasesPerApp()
    {
        // PLAN-v27 B5（同 mac）：中英文逗号、分号、顿号、换行隔开；折叠、去空白、去重；超过 32 个字的那个不算
        CollectionAssert.AreEqual(new[] { "wx", "聊天", "chat", "vscode" },
            AppAliases.Words("wx, 聊天；Chat，WX、VS Code\n" + new string('x', 40)));
        Assert.AreEqual(0, AppAliases.Words(" , ；").Count);
        var aliases = new Dictionary<string, string> { ["exe:a"] = "wx, 聊天" };
        Assert.AreEqual("exe:a", AppAliases.KeyFor("聊天", aliases));
        Assert.AreEqual("exe:a", AppAliases.KeyFor("WX", aliases));
        Assert.IsNull(AppAliases.KeyFor("wx, 聊天", aliases), "整段原文不是别名");
        // 导入：几个别名的那段照收，原文超过 256 字的不收
        var read = AppAliases.Sanitize(new Dictionary<string, string> { ["exe:a"] = "wx, 聊天", ["exe:b"] = string.Join(",", Enumerable.Repeat("ab", 100)) });
        CollectionAssert.AreEquivalent(new[] { "exe:a" }, read.Keys.ToArray());
    }

    [TestMethod]
    public void AliasesBecomeSearchableNames()
    {
        var app = new LauncherItem
        {
            Kind = LauncherKind.App, Target = @"C:\x\WeChat.lnk", Title = "微信", AliasKey = "exe:a",
            Names = new() { "微信", "weixin" }, Initials = new() { "微", "wx" },
        };
        var aliases = new Dictionary<string, string> { ["exe:a"] = "聊天, talk" };
        var applied = AppAliases.Apply(app, aliases);
        Assert.IsTrue(LauncherMatch.Score("talk", applied) > 0);
        Assert.IsTrue(LauncherMatch.Score("ta", applied) > 0, "打别名的开头也行");
        Assert.IsTrue(LauncherMatch.Score("liaotian", applied) > 0, "中文别名的拼音");
        Assert.AreEqual(app.Id, applied.Id, "Target 不变：使用记录、收藏照旧认");
        Assert.AreEqual(0, LauncherMatch.Score("talk", app), "原来那个不动");
        // 没有别名的原样返回（同一个对象，不白分配）
        Assert.AreSame(app, AppAliases.Apply(app, new Dictionary<string, string> { ["exe:b"] = "x" }));
        Assert.AreSame(app, AppAliases.Apply(app, null));
        var keyless = app with { AliasKey = null };
        Assert.AreSame(keyless, AppAliases.Apply(keyless, aliases), "起不了别名的应用");
    }
}
