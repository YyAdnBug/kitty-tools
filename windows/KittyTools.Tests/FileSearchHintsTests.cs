// 文件搜索最后一行的说明、设置页的状态、兜底行（PLAN-v25 F9、F15；Core FileSearchHints）。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class FileSearchHintsTests
{
    private static readonly string[] None = Array.Empty<string>();

    private static FileIndexStatus Status(
        IndexService service = IndexService.Running, int catalog = 0, int reason = 0, int pending = 0, int items = 120_000,
        string[]? drives = null)
        => new(service, catalog, reason, pending, items, drives ?? None, None);

    [TestMethod]
    public void EverythingNeverGetsAHint()
    {
        Assert.IsNull(FileSearchHints.Pick(Status(IndexService.Stopped), FileSearchSource.Everything, 0));
        Assert.IsNull(FileSearchHints.Pick(Status(drives: new[] { "D:" }), FileSearchSource.Everything, 0));
    }

    [TestMethod]
    public void WalkSaysWhyTheIndexWasNotUsed()
    {
        var stopped = FileSearchHints.Pick(Status(IndexService.Stopped, catalog: -1), FileSearchSource.Walk, 3)!;
        Assert.AreEqual(FileSearchHints.ServiceTarget, stopped.Target);
        Assert.AreEqual(LauncherKind.Prompt, stopped.Kind);
        StringAssert.Contains(stopped.Title, "服务没开");

        Assert.AreEqual(FileSearchHints.ServiceTarget, FileSearchHints.Pick(Status(IndexService.Disabled), FileSearchSource.Walk, 0)!.Target);
        Assert.AreEqual(FileSearchHints.NoneTarget, FileSearchHints.Pick(Status(IndexService.Missing), FileSearchSource.Walk, 0)!.Target);
        // 服务在跑、查询却失败了，或者读不出状态：只说索引用不了，↩ 打开设置
        Assert.AreEqual(FileSearchHints.SettingsTarget, FileSearchHints.Pick(Status(), FileSearchSource.Walk, 0)!.Target);
        Assert.AreEqual(FileSearchHints.SettingsTarget, FileSearchHints.Pick(null, FileSearchSource.Walk, 0)!.Target);
    }

    [TestMethod]
    public void NothingToSayWhenTheIndexIsFine()
    {
        Assert.IsNull(FileSearchHints.Pick(Status(), FileSearchSource.Index, 0));
        Assert.IsNull(FileSearchHints.Pick(null, FileSearchSource.Index, 0));
        // 增量建索引、只剩零星几项：平常的，不说
        Assert.IsNull(FileSearchHints.Pick(Status(catalog: 4, pending: 12), FileSearchSource.Index, 0));
        // 暂停了但没什么要建：不影响搜索，不说
        Assert.IsNull(FileSearchHints.Pick(Status(catalog: 1, reason: 8, pending: 0), FileSearchSource.Index, 0));
    }

    [TestMethod]
    public void IndexingAndPausedComeBeforeUncoveredDrives()
    {
        var full = FileSearchHints.Pick(Status(catalog: 3, pending: 45_678, drives: new[] { "D:" }), FileSearchSource.Index, 0)!;
        Assert.AreEqual(FileSearchHints.SettingsTarget, full.Target);
        StringAssert.Contains(full.Title, "还在建索引（还剩约 4.6 万项）");

        var busy = FileSearchHints.Pick(Status(catalog: 4, pending: 2_000), FileSearchSource.Index, 30)!;
        StringAssert.Contains(busy.Title, "还剩约 2000 项");

        var recovering = FileSearchHints.Pick(Status(catalog: 2, pending: -1), FileSearchSource.Index, 30)!;
        StringAssert.Contains(recovering.Title, "Windows 还在建索引，结果可能不全");

        var paused = FileSearchHints.Pick(Status(catalog: 1, reason: 4, pending: 5_000), FileSearchSource.Index, 30)!;
        StringAssert.Contains(paused.Title, "暂停了（在用电池）");
    }

    [TestMethod]
    public void UncoveredDrivesOnlyWhenFewResults()
    {
        var status = Status(drives: new[] { "D:", "E:" });
        var hint = FileSearchHints.Pick(status, FileSearchSource.Index, FileSearchHints.FewResults - 1)!;
        Assert.AreEqual(FileSearchHints.SettingsTarget, hint.Target);
        StringAssert.Contains(hint.Title, "「D:」「E:」不在 Windows 搜索的索引里");
        Assert.IsNull(FileSearchHints.Pick(status, FileSearchSource.Index, FileSearchHints.FewResults));

        var many = FileSearchHints.Pick(Status(drives: new[] { "D:", "E:", "F:", "G:" }), FileSearchSource.Index, 0)!;
        StringAssert.Contains(many.Title, "「D:」「E:」「F:」等不在");
    }

    [TestMethod]
    public void SettingsStatusText()
    {
        Assert.AreEqual(("正常 · 已编入约 12 万项", false), FileSearchHints.Status(Status()));
        Assert.AreEqual(("正常", false), FileSearchHints.Status(Status(items: -1)));
        Assert.IsTrue(FileSearchHints.Status(Status(IndexService.Disabled)).Problem);
        StringAssert.Contains(FileSearchHints.Status(Status(IndexService.Stopped)).Text, "服务没开");
        Assert.AreEqual(("正在建索引，还剩约 3000 项", false), FileSearchHints.Status(Status(catalog: 3, pending: 3_000)));
        var drives = FileSearchHints.Status(Status(drives: new[] { "D:" }));
        Assert.IsTrue(drives.Problem);
        StringAssert.Contains(drives.Text, "「D:」不在索引里");
        Assert.AreEqual(("读不出 Windows 搜索的状态", false), FileSearchHints.Status(null));
    }

    [TestMethod]
    public void LogLineHasNoPaths()
    {
        var line = FileSearchHints.LogLine(new FileIndexStatus(IndexService.Running, 0, 0, 0, 10, new[] { "D:" }, new[] { @"D:\Users\YY\桌面" }));
        StringAssert.Contains(line, "drives-out=D:");
        StringAssert.Contains(line, "folders-out=1");
        Assert.IsFalse(line.Contains("桌面", StringComparison.Ordinal));
    }

    [TestMethod]
    public void ItemsUseWanAboveTenThousand()
    {
        Assert.AreEqual("9999 项", FileSearchHints.Items(9_999));
        Assert.AreEqual("1 万项", FileSearchHints.Items(10_000));
        Assert.AreEqual("12.3 万项", FileSearchHints.Items(123_456));
    }

    [TestMethod]
    public void FallbackRowSwitchesToFileSearch()
    {
        var row = FileSearchHints.FallbackItem("季度报告");
        Assert.AreEqual(LauncherKind.Prompt, row.Kind);
        Assert.AreEqual(FileSearchHints.FallbackTarget, row.Target);
        Assert.AreEqual("在文件里找「季度报告」", row.Title);
        Assert.AreEqual(" 季度报告", row.Completion);
        // 空格开头就是文件搜索（LauncherCommands.Classify）
        Assert.AreEqual(LauncherMode.FileSearch, LauncherCommands.Classify(row.Completion!).Mode);
        Assert.IsFalse(FileSearchHints.IsHint(row.Target));
        Assert.IsTrue(FileSearchHints.IsHint(FileSearchHints.ServiceTarget));
    }

    [TestMethod]
    public void FooterNamesTheNewRows()
    {
        Assert.AreEqual("文件", PanelFooterText.LauncherKindName(LauncherKind.Prompt, FileSearchHints.FallbackTarget));
        Assert.AreEqual("文件", PanelFooterText.LauncherKindName(LauncherKind.Prompt, FileSearchHints.SettingsTarget));
        Assert.AreEqual("搜文件", PanelFooterText.LauncherVerb(LauncherKind.Prompt, FileSearchHints.FallbackTarget, armed: false).Text);
        Assert.AreEqual("启用", PanelFooterText.LauncherVerb(LauncherKind.Prompt, FileSearchHints.ServiceTarget, armed: false).Text);
        Assert.AreEqual("打开设置", PanelFooterText.LauncherVerb(LauncherKind.Prompt, FileSearchHints.SettingsTarget, armed: false).Text);
    }
}
