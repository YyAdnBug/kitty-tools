// 第三版第 1 批的纯函数单测：每日备份的规则、导出文件的格式、密钥的加解密（参数要和 mac 一致）、快捷键的写法。
using System.Text.Json;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class BackupPlanTests
{
    [TestMethod]
    public void NamesAndDays()
    {
        var day = new DateTime(2026, 10, 2);
        Assert.AreEqual("kitty-2026-10-02.sqlite3", BackupPlan.Name(day));
        Assert.AreEqual(day, BackupPlan.DayOf("kitty-2026-10-02.sqlite3"));
        Assert.IsNull(BackupPlan.DayOf("kitty.partial"));
        Assert.IsNull(BackupPlan.DayOf("Kitty Tools 自动备份 2026-10-02.json"));
        Assert.IsNull(BackupPlan.DayOf("kitty-2026-13-02.sqlite3"));
    }

    [TestMethod]
    public void DueOnlyOncePerDay()
    {
        var folder = Path.Combine(Path.GetTempPath(), "kitty-backup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var now = new DateTime(2026, 10, 5, 12, 0, 0);
            Assert.IsTrue(BackupPlan.IsDue(folder, now));
            File.WriteAllText(Path.Combine(folder, BackupPlan.Name(now)), "x");
            Assert.IsFalse(BackupPlan.IsDue(folder, now));
            Assert.IsTrue(BackupPlan.IsDue(folder, now.AddDays(1)));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void RotationKeepsNewestAndNeverDeletesWritten()
    {
        var now = new DateTime(2026, 10, 5);
        var copies = new List<(string Path, DateTime Day)>
        {
            ("/b/a.sqlite3", now),
            ("/b/b.sqlite3", now.AddDays(-1)),
            ("/b/c.sqlite3", now.AddDays(-2)),
            ("/b/d.sqlite3", now.AddDays(-3)),
            ("/b/future.sqlite3", now.AddDays(5)),
        };
        var written = "/b/a.sqlite3";
        var expired = BackupPlan.Expired(copies, written, now);
        // 留 3 份（含刚写的那份）：先删时钟跑到未来的，再删最旧的。
        Assert.IsFalse(expired.Contains(written));
        Assert.IsTrue(expired.Contains("/b/future.sqlite3"));
        Assert.IsTrue(expired.Contains("/b/d.sqlite3"));
        Assert.IsFalse(expired.Contains("/b/a.sqlite3"));
    }

    [TestMethod]
    public void DescribesDays()
    {
        var now = new DateTime(2026, 10, 5);
        Assert.AreEqual("10 月 5 日（今天）", BackupPlan.Describe(now, now));
        Assert.AreEqual("10 月 4 日（昨天）", BackupPlan.Describe(now.AddDays(-1), now));
        Assert.AreEqual("9 月 28 日（7 天前）", BackupPlan.Describe(now.AddDays(-7), now));
        Assert.AreEqual("damaged-20261005-213045", BackupPlan.AsideFolderName(new DateTime(2026, 10, 5, 21, 30, 45)));
    }

    [TestMethod]
    public void DropsOnlyOrdinaryRows()
    {
        var withTranslations = BackupPlan.DroppedStatements(true);
        Assert.IsTrue(withTranslations.Any(sql => sql.Contains("favorite = 0", StringComparison.Ordinal)));
        Assert.IsTrue(withTranslations.Any(sql => sql.Contains("launcher_usage", StringComparison.Ordinal)));
        Assert.IsTrue(withTranslations.Any(sql => sql.Contains("translations", StringComparison.Ordinal)));
        Assert.AreEqual(2, BackupPlan.DroppedStatements(false).Count);
    }

    [TestMethod]
    public void WordingMatchesChoices()
    {
        var now = new DateTime(2026, 10, 5);
        var (title, _, buttons) = BackupPlan.Wording("坏了", now.AddDays(-1), lost: false, now);
        Assert.AreEqual("数据打不开了", title);
        Assert.AreEqual(3, buttons.Length);
        Assert.IsTrue(buttons[0].Contains("10 月 4 日", StringComparison.Ordinal));

        var none = BackupPlan.Wording("坏了", null, lost: false, now);
        Assert.AreEqual(2, none.Buttons.Length);
    }
}

[TestClass]
public sealed class ArchiveTests
{
    private static List<SettingsArchive.ArchiveService> Services() => new()
    {
        new SettingsArchive.ArchiveService
        {
            Id = "zhipu",
            Kind = "zhipu",
            Name = "智谱",
            AiProtocol = "openai",
            BaseUrl = "https://open.bigmodel.cn/api/paas/v4",
            UsesDeepLX = false,
        },
        new SettingsArchive.ArchiveService
        {
            Id = "ai:0f8fad5b",
            Kind = "ai",
            Name = "本地",
            AiProtocol = "openai",
            BaseUrl = "http://127.0.0.1:11434/v1",
        },
    };

    [TestMethod]
    public void RoundTripsSecretsWithPassword()
    {
        var services = Services();
        var secrets = new Dictionary<string, string>
        {
            ["zhipu.apiKey"] = "secret-value-1",
            ["ai:0f8fad5b.apiKey"] = "secret-value-2",
        };
        var sealedSecrets = ArchiveCrypto.Seal(secrets, "correct horse battery", services);
        Assert.AreEqual("pbkdf2-hmac-sha256", sealedSecrets.Kdf);
        Assert.AreEqual(600_000, sealedSecrets.Rounds);

        var opened = ArchiveCrypto.Unseal(sealedSecrets, "correct horse battery", services);
        Assert.IsNotNull(opened);
        Assert.AreEqual(secrets["zhipu.apiKey"], opened!["zhipu.apiKey"]);

        Assert.IsNull(ArchiveCrypto.Unseal(sealedSecrets, "wrong password", services));

        // 服务地址被改过：同一段密钥解不开（附加校验数据对不上）。
        var tampered = Services();
        tampered[0].BaseUrl = "https://evil.example.com";
        Assert.IsNull(ArchiveCrypto.Unseal(sealedSecrets, "correct horse battery", tampered));
    }

    [TestMethod]
    public void RoutingIsLengthPrefixed()
    {
        var routing = System.Text.Encoding.UTF8.GetString(ArchiveCrypto.Routing(Services()));
        Assert.IsTrue(routing.StartsWith("5:zhipu5:zhipu", StringComparison.Ordinal));
        Assert.IsTrue(routing.Contains(":0", StringComparison.Ordinal));
    }

    [TestMethod]
    public void SerializesWindowsPlatformAndParsesMacFiles()
    {
        var archive = new SettingsArchive
        {
            Platform = SettingsArchive.WindowsPlatform,
            Clips = new List<SettingsArchive.ArchiveClip>
            {
                new() { Text = "hello", Favorite = true, CopiedAt = DateTimeOffset.FromUnixTimeMilliseconds(1) },
            },
        };
        var json = JsonSerializer.Serialize(archive, ArchiveJsonContext.Default.SettingsArchive);
        Assert.IsTrue(json.Contains("\"platform\": \"windows\"", StringComparison.Ordinal));
        Assert.IsTrue(json.Contains("\"app\": \"Kitty Tools\"", StringComparison.Ordinal));
        Assert.IsTrue(json.Contains("\"format\": 2", StringComparison.Ordinal));

        var mac = JsonSerializer.Deserialize(
            """{"app":"Kitty Tools","format":2,"clips":[{"text":"hi","favorite":true,"copiedAt":"2026-10-01T12:00:00Z"}]}""",
            ArchiveJsonContext.Default.SettingsArchive);
        Assert.IsNotNull(mac);
        Assert.IsFalse(mac!.AppliesWindowsSettings);
        Assert.AreEqual("hi", mac.Clips![0].Text);
        Assert.AreEqual(DateTimeOffset.Parse("2026-10-01T12:00:00Z"), mac.Clips[0].CopiedAt);
    }

    [TestMethod]
    public void SanitizedDropsJunkAndCaps()
    {
        var archive = new SettingsArchive
        {
            Clips = Enumerable.Range(0, SettingsArchive.MaxClips + 10)
                .Select(index => new SettingsArchive.ArchiveClip { Text = "x" + index })
                .Concat(new[] { new SettingsArchive.ArchiveClip { Text = string.Empty } })
                .ToList(),
            SearchEngines = new List<SettingsArchive.ArchiveEngine>
            {
                new() { Id = "g", Url = "https://example.com/?q={query}" },
                new() { Id = "", Url = "https://example.com/?q={query}" },
                new() { Id = "bad", Url = "https://example.com/" },
            },
            ClipGroups = new List<string> { " a ", "", new string('x', 40) },
        };
        var clean = archive.Sanitized();
        Assert.AreEqual(SettingsArchive.MaxClips, clean.Clips!.Count);
        Assert.AreEqual(1, clean.SearchEngines!.Count);
        Assert.AreEqual(1, clean.ClipGroups!.Count);
        Assert.AreEqual("a", clean.ClipGroups[0]);
    }

    [TestMethod]
    public void HotkeyTextRoundTrips()
    {
        Assert.IsTrue(HotKeyRules.TryParse("Ctrl+Alt+K", out var key, out var modifiers));
        Assert.AreEqual((uint)'K', key);
        Assert.AreEqual(HotKeyModifiers.Control | HotKeyModifiers.Alt, modifiers);
        Assert.AreEqual("Ctrl+Alt+K", HotKeyRules.Format(key, modifiers));

        Assert.IsTrue(HotKeyRules.TryParse("F12", out key, out modifiers));
        Assert.AreEqual(0x7Bu, key);
        Assert.AreEqual(HotKeyModifiers.None, modifiers);
        Assert.IsTrue(HotKeyRules.TryParse("Alt+Enter", out key, out _));
        Assert.AreEqual((uint)HotKeyRules.VkReturn, key);
        Assert.IsFalse(HotKeyRules.TryParse("Nope", out _, out _));
    }

    [TestMethod]
    public void ArchiveRotationKeepsNewest()
    {
        var folder = Path.Combine(Path.GetTempPath(), "kitty-archive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            for (var day = 1; day <= 10; day++)
            {
                File.WriteAllText(
                    Path.Combine(folder, $"Kitty Tools 自动备份 2026-10-{day:00}.json"), "{}");
            }

            ArchiveRotation.Expired(Directory.GetFiles(folder, "Kitty Tools 自动备份 *.json"), 7)
                .ForEach(path => File.Delete(path));
            var left = Directory.GetFiles(folder, "Kitty Tools 自动备份 *.json");
            Assert.AreEqual(7, left.Length);
            Assert.IsTrue(left.Any(path => path.EndsWith("2026-10-10.json", StringComparison.Ordinal)));
            Assert.IsFalse(left.Any(path => path.EndsWith("2026-10-01.json", StringComparison.Ordinal)));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
