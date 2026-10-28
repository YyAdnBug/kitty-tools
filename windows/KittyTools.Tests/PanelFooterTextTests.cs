// 底栏文案单测（PLAN-v7 §3.1 §3.2）：剪贴板左边的状态、启动器的种类名和动词。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PanelFooterTextTests
{
    [TestMethod]
    public void ClipStatusShowsPause()
    {
        Assert.AreEqual("12 条", PanelFooterText.ClipStatus(12, paused: false));
        Assert.AreEqual("⏸ 已暂停记录 · 12 条", PanelFooterText.ClipStatus(12, paused: true));
        Assert.AreEqual("0 条", PanelFooterText.ClipStatus(0, paused: false));
        Assert.AreEqual("已选 3 条", PanelFooterText.ClipSelected(3));
    }

    [TestMethod]
    public void MultiSelectVerbFollowsMode()
    {
        Assert.AreEqual("合并粘贴", MultiPaste.ShortVerb(MultiPaste.Mode(3, allText: true, allFiles: false)));
        Assert.AreEqual("一起粘贴", MultiPaste.ShortVerb(MultiPaste.Mode(2, allText: false, allFiles: true)));
        Assert.AreEqual("依次粘贴", MultiPaste.ShortVerb(MultiPaste.Mode(2, allText: false, allFiles: false)));
    }

    [TestMethod]
    public void LauncherVerbFollowsKind()
    {
        // PLAN-v9-launcher：名字照 mac primaryAction。
        Assert.AreEqual(new FooterVerb("打开", false), PanelFooterText.LauncherVerb(LauncherKind.App, @"C:\a.exe", false));
        Assert.AreEqual("打开", PanelFooterText.LauncherVerb(LauncherKind.Setting, "ms-settings:display", false).Text);
        Assert.AreEqual("打开网址", PanelFooterText.LauncherVerb(LauncherKind.Url, "https://example.com", false).Text);
        Assert.AreEqual("打开", PanelFooterText.LauncherVerb(LauncherKind.Path, @"C:\a.txt", false).Text);
        Assert.AreEqual("搜索", PanelFooterText.LauncherVerb(LauncherKind.Search, "bing:x", false).Text);
        Assert.AreEqual("粘贴", PanelFooterText.LauncherVerb(LauncherKind.Calculation, "=2", false).Text);
        Assert.AreEqual("运行", PanelFooterText.LauncherVerb(LauncherKind.Command, "lock", false).Text);
        Assert.AreEqual("搜索", PanelFooterText.LauncherVerb(LauncherKind.Clip, "abc", false).Text);
        Assert.AreEqual("打开", PanelFooterText.LauncherVerb(LauncherKind.Clip, "", false).Text);
        Assert.AreEqual("翻译", PanelFooterText.LauncherVerb(LauncherKind.Translate, "abc", false).Text);
        Assert.AreEqual("结束", PanelFooterText.LauncherVerb(LauncherKind.Process, "42", false).Text);
        Assert.AreEqual("补全关键词", PanelFooterText.LauncherVerb(LauncherKind.Prompt, "system-kill", false).Text);
        Assert.AreEqual("运行", PanelFooterText.LauncherVerb(LauncherKind.Action, "action:screenshot", false).Text);
    }

    [TestMethod]
    public void ArmedIsDangerConfirm()
    {
        Assert.AreEqual(new FooterVerb("确认重启", true), PanelFooterText.LauncherVerb(LauncherKind.Command, "restart", true, "重启"));
        Assert.AreEqual(new FooterVerb("确认结束", true), PanelFooterText.LauncherVerb(LauncherKind.Process, "42", true));
        Assert.IsFalse(PanelFooterText.LauncherVerb(LauncherKind.Process, "42", false).Danger);
    }

    [TestMethod]
    public void KindNameFollowsMac()
    {
        Assert.AreEqual("应用", PanelFooterText.LauncherKindName(LauncherKind.App, "x"));
        Assert.AreEqual("系统", PanelFooterText.LauncherKindName(LauncherKind.Command, "lock"));
        Assert.AreEqual("进程", PanelFooterText.LauncherKindName(LauncherKind.Process, "42"));
        Assert.AreEqual("进程", PanelFooterText.LauncherKindName(LauncherKind.Process, "42:80"));
        Assert.AreEqual("命令", PanelFooterText.LauncherKindName(LauncherKind.Action, "action:screenshot"));
        Assert.AreEqual("计算", PanelFooterText.LauncherKindName(LauncherKind.Calculation, "=1"));
        Assert.AreEqual("PDF", PanelFooterText.LauncherKindName(LauncherKind.Path, @"C:\a\report.pdf"));
        Assert.AreEqual("文件夹", PanelFooterText.LauncherKindName(LauncherKind.Path, @"C:\a\"));
        Assert.AreEqual("系统", PanelFooterText.LauncherKindName(LauncherKind.Prompt, "system-quit"));
        Assert.AreEqual("搜索", PanelFooterText.LauncherKindName(LauncherKind.Prompt, "google"));
    }
}
