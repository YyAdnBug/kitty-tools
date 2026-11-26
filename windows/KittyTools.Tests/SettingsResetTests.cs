// PLAN-v26 G1：设置页「恢复默认」动哪几项——按页分，保留期、占用上限、历史开关、自己攒的列表不动。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsResetTests
{
    private static readonly string[] Ids =
    {
        "clipboardHistoryRetentionDays", "clipboardImageCacheMaxMb", "clipboardBlockSensitive", "clipboardImageRows", "ClipboardExcludedApps",
        "translateHistoryLimit", "translateHistoryEnabled", "translateWordMode", "autoCopy", "shotHistory", "shotHistoryDays",
        "shotHistoryMegabytes", "screenshotShowsHint", "ScreenshotCursor", "launcherScripts", "LauncherCommandsOff", "notesFontSize",
    };

    [TestMethod]
    public void KeepsRetentionAndLists()
    {
        CollectionAssert.AreEqual(new[] { "clipboardBlockSensitive", "clipboardImageRows" }, SettingsReset.KeysFor("clipboard", Ids));
        CollectionAssert.AreEqual(new[] { "translateWordMode", "autoCopy" }, SettingsReset.KeysFor("translate", Ids));
        CollectionAssert.AreEqual(new[] { "screenshotShowsHint", "ScreenshotCursor" }, SettingsReset.KeysFor("screenshot", Ids), "截图历史的保留和开关不动");
        CollectionAssert.AreEqual(new[] { "launcherScripts" }, SettingsReset.KeysFor("launcher", Ids), "命令表不动");
        Assert.AreEqual(0, SettingsReset.KeysFor("general", Ids).Count, "通用页没有");
    }
}
