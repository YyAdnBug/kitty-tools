// 录快捷键时撞键的话（PLAN-v23 H3，照 mac HotKeyRecorder：和别的动作重复、关着的功能也算、和启动器命令重复）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class HotKeyConflictsTests
{
    private const uint KeyC = 'C';
    private const uint KeyR = 'R';
    private const uint VkControl = 0x11;

    private static readonly HotKeyOwner[] Globals =
    {
        new("clipboard", "剪贴板历史", KeyC, HotKeyModifiers.Alt),
        new("record", "录屏（再按一次停止）", KeyR, HotKeyModifiers.Alt, "录制"),
        new("home", "打开主界面", VkControl, HotKeyModifiers.None),
        new("shotHistory", "截图历史", 0, HotKeyModifiers.None),
    };

    private static readonly CommandKeyOwner[] Commands =
    {
        new("kill", "结束进程", 'K', HotKeyModifiers.Control | HotKeyModifiers.Alt),
    };

    [TestMethod]
    public void GlobalAgainstOtherActions()
    {
        Assert.AreEqual("和「剪贴板历史」重复", HotKeyConflicts.ForGlobal("launcher", KeyC, HotKeyModifiers.Alt, Globals, Commands));
        // 关着的功能的键也算，话里写明它关着
        Assert.AreEqual("和「录屏（再按一次停止）」重复（录制已关闭）", HotKeyConflicts.ForGlobal("launcher", KeyR, HotKeyModifiers.Alt, Globals, Commands));
        // 连按两下 Ctrl（存成键 + 无修饰）照样比
        Assert.AreEqual("和「打开主界面」重复", HotKeyConflicts.ForGlobal("launcher", VkControl, HotKeyModifiers.None, Globals, Commands));
        // 自己现在的键、别的修饰、没设（0）的都不算
        Assert.IsNull(HotKeyConflicts.ForGlobal("clipboard", KeyC, HotKeyModifiers.Alt, Globals, Commands));
        Assert.IsNull(HotKeyConflicts.ForGlobal("launcher", KeyC, HotKeyModifiers.Alt | HotKeyModifiers.Shift, Globals, Commands));
        Assert.IsNull(HotKeyConflicts.ForGlobal("launcher", 0, HotKeyModifiers.None, Globals, Commands));
    }

    [TestMethod]
    public void GlobalAgainstLauncherCommands()
    {
        Assert.AreEqual("和启动器命令「结束进程」重复",
            HotKeyConflicts.ForGlobal("launcher", 'K', HotKeyModifiers.Control | HotKeyModifiers.Alt, Globals, Commands));
    }

    [TestMethod]
    public void CommandAgainstGlobalsAndOtherCommands()
    {
        Assert.AreEqual("和全局快捷键「剪贴板历史」重复", HotKeyConflicts.ForCommand("ip", KeyC, HotKeyModifiers.Alt, Globals, Commands));
        Assert.AreEqual("和全局快捷键「录屏（再按一次停止）」重复（录制已关闭）", HotKeyConflicts.ForCommand("ip", KeyR, HotKeyModifiers.Alt, Globals, Commands));
        Assert.AreEqual("和命令「结束进程」重复", HotKeyConflicts.ForCommand("ip", 'K', HotKeyModifiers.Control | HotKeyModifiers.Alt, Globals, Commands));
        Assert.IsNull(HotKeyConflicts.ForCommand("kill", 'K', HotKeyModifiers.Control | HotKeyModifiers.Alt, Globals, Commands));
    }
}
