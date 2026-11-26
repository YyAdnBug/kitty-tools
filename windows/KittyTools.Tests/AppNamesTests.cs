// 应用能搜的名字（PLAN-v27 B1 B4）：快捷方式目标 exe 的名字也能搜到（「命令提示符」打 cmd）、宿主和更新器不算、
// 商店应用的包名去掉发布者那一截。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class AppNamesTests
{
    private static LauncherItem App(string title, string fileTitle, string? target)
    {
        var (names, initials) = AppNames.Build(new[] { title, fileTitle }, target);
        return new LauncherItem { Kind = LauncherKind.App, Target = @"C:\x\" + fileTitle + ".lnk", Title = title, Names = names, Initials = initials };
    }

    [TestMethod]
    public void SystemToolsAreFoundByTheirExeName()
    {
        // 中文系统：标题是本地化名，.lnk 文件名是英文，目标带 %windir%（SLGP_RAWPATH 原样）
        var prompt = App("命令提示符", "Command Prompt", @"%windir%\system32\cmd.exe");
        Assert.AreEqual(100, LauncherMatch.Score("cmd", prompt));
        Assert.IsTrue(LauncherMatch.Score("命令", prompt) > 0);
        Assert.IsTrue(LauncherMatch.Score("command prompt", prompt) > 0);
        Assert.IsTrue(LauncherMatch.Score("mlts", prompt) > 0, "拼音首字母照旧");
        Assert.AreEqual(100, LauncherMatch.Score("regedit", App("注册表编辑器", "Registry Editor", @"%windir%\regedit.exe")));
        Assert.AreEqual(100, LauncherMatch.Score("taskmgr", App("任务管理器", "Task Manager", @"%windir%\system32\taskmgr.exe")));
        Assert.AreEqual(100, LauncherMatch.Score("services", App("服务", "services", @"%windir%\system32\services.msc")));
        // 以前只有副标题写着 cmd，打 cmd 一条都没有
        var old = new LauncherItem { Kind = LauncherKind.App, Title = "命令提示符", Names = new() { "命令提示符", "command prompt" }, Initials = new() { "cp" } };
        Assert.AreEqual(0, LauncherMatch.Score("cmd", old));
    }

    [TestMethod]
    public void HostsAndUpdatersAreNotNames()
    {
        Assert.AreEqual("cmd", AppNames.ExeStem(@"""C:\Windows\System32\cmd.exe"""));
        Assert.AreEqual("WeChat", AppNames.ExeStem(@"C:\Program Files\Tencent\WeChat\WeChat.exe"));
        Assert.IsNull(AppNames.ExeStem(@"C:\Users\yy\AppData\Local\Discord\Update.exe"), "Squirrel 装的应用都指向 Update.exe");
        Assert.IsNull(AppNames.ExeStem(@"C:\Program Files\Google\Chrome\Application\chrome_proxy.exe"), "网页应用");
        Assert.IsNull(AppNames.ExeStem(@"C:\Program Files\Java\bin\javaw.exe"));
        Assert.IsNull(AppNames.ExeStem(@"C:\Windows\System32\rundll32.exe"));
        Assert.IsNull(AppNames.ExeStem(@"C:\Windows\explorer.exe"), "打开文件夹的快捷方式（Windows SDK 那种）");
        Assert.IsNull(AppNames.ExeStem(@"C:\x\readme.txt"));
        Assert.IsNull(AppNames.ExeStem(null));
        Assert.IsNull(AppNames.ExeStem(@"C:\Program Files\Foo"));
        var discord = App("Discord", "Discord", @"C:\Users\yy\AppData\Local\Discord\Update.exe");
        Assert.AreEqual(0, LauncherMatch.Score("update", discord));
    }

    [TestMethod]
    public void NamesAreFoldedAndDistinct()
    {
        var (names, initials) = AppNames.Build(new[] { "Visual Studio Code", "Visual Studio Code", null, " " }, @"C:\x\Code.exe");
        CollectionAssert.AreEqual(new[] { "visual studio code", "code" }, names);
        CollectionAssert.AreEqual(new[] { "vsc" }, initials);
    }

    [TestMethod]
    public void StoreAppsAlsoGetThePackageName()
    {
        Assert.AreEqual("WindowsTerminal", AppNames.PackageShortName("Microsoft.WindowsTerminal"));
        Assert.AreEqual("WeChatDesktop", AppNames.PackageShortName("5319275A.WeChatDesktop"));
        Assert.IsNull(AppNames.PackageShortName("Microsoft.549981C3F5F10"), "一串编号不算");
        Assert.IsNull(AppNames.PackageShortName("NoDot"));
        Assert.IsNull(AppNames.PackageShortName(null));
        // 中文系统上「终端」：打 wt、terminal 都能搜到
        var (names, initials) = AppNames.Build(new[] { "终端", "终端", AppNames.PackageShortName("Microsoft.WindowsTerminal") });
        var terminal = new LauncherItem { Kind = LauncherKind.App, Title = "终端", Names = names, Initials = initials };
        Assert.IsTrue(LauncherMatch.Score("wt", terminal) > 0);
        Assert.IsTrue(LauncherMatch.Score("terminal", terminal) > 0);
        Assert.IsTrue(LauncherMatch.Score("zd", terminal) > 0, "拼音首字母照旧");
    }
}
