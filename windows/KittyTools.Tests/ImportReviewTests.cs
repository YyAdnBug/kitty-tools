// PLAN-v9 G2 G3：导入前要先说的几句、翻译服务的地址、备份清单里的名字。
using System.Text.Json;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ImportReviewTests
{
    private static SettingsArchive Archive(string preferences, string platform = SettingsArchive.WindowsPlatform)
    {
        using var document = JsonDocument.Parse(preferences);
        return new SettingsArchive
        {
            Platform = platform,
            Preferences = document.RootElement.EnumerateObject()
                .ToDictionary(property => property.Name, property => property.Value.Clone()),
        };
    }

    [TestMethod]
    public void WarnsAboutShorterRetentionAndWeakerPrivacy()
    {
        var archive = Archive("""{"clipboardRetentionDays": 7, "clipboardBlockSensitive": false, "clipboardExcludedApps": ["keepass.exe"]}""");
        var warnings = ImportReview.Warnings(archive, 30, blockSensitive: true, new[] { "KeePass.exe", "1password.exe" });
        Assert.AreEqual(3, warnings.Count);
        StringAssert.Contains(warnings[0], "7 天");
        StringAssert.Contains(warnings[1], "疑似密钥");
        StringAssert.Contains(warnings[2], "1 个应用");

        // 本机是永久、文件是 30 天：也算变短。本机 7 天、文件 30 天：不说。
        Assert.AreEqual(1, ImportReview.Warnings(Archive("""{"clipboardRetentionDays": 30}"""), 0, false, Array.Empty<string>()).Count);
        Assert.AreEqual(0, ImportReview.Warnings(Archive("""{"clipboardRetentionDays": 30}"""), 7, false, Array.Empty<string>()).Count);
        // 本机本来就关着「不记录疑似密钥」：不说。
        Assert.AreEqual(0, ImportReview.Warnings(Archive("""{"clipboardBlockSensitive": false}"""), 7, false, Array.Empty<string>()).Count);
    }

    [TestMethod]
    public void MacSettingsAreNotImportedSoNoWarnings()
    {
        var archive = Archive("""{"clipboardRetentionDays": 1}""", platform: "mac");
        Assert.AreEqual(0, ImportReview.Warnings(archive, 30, true, new[] { "a.exe" }).Count);
    }

    [TestMethod]
    public void ListsCustomAddressesOnce()
    {
        var archive = new SettingsArchive
        {
            TranslateServices = new List<SettingsArchive.ArchiveService>
            {
                new() { Id = "a", BaseUrl = "https://llm.example.com/v1" },
                new() { Id = "b", BaseUrl = " https://LLM.example.com/v1 " },
                new() { Id = "c", BaseUrl = null },
                new() { Id = "d", BaseUrl = "http://192.168.1.5:11434" },
            },
        };
        CollectionAssert.AreEqual(
            new[] { "https://llm.example.com/v1", "http://192.168.1.5:11434" }, ImportReview.Addresses(archive));
        Assert.AreEqual(0, ImportReview.Addresses(new SettingsArchive()).Count);
    }

    [TestMethod]
    public void BackupTitles()
    {
        var now = new DateTime(2026, 10, 8, 16, 0, 0);
        Assert.AreEqual("10 月 8 日（今天）", ImportReview.BackupTitle("Kitty Tools 自动备份 2026-10-08.json", now));
        Assert.AreEqual("10 月 7 日（昨天）", ImportReview.BackupTitle(@"C:\x\Kitty Tools 自动备份 2026-10-07.json", now));
        Assert.AreEqual("10 月 3 日（5 天前）", ImportReview.BackupTitle("Kitty Tools 自动备份 2026-10-03.json", now));
        Assert.AreEqual("导入前 · 10 月 8 日（今天） 15:30", ImportReview.BackupTitle("Kitty Tools 导入前 2026-10-08 15.30.12.json", now));
        Assert.IsNull(ImportReview.BackupTitle("kitty-2026-10-08.sqlite3", now));
    }
}
