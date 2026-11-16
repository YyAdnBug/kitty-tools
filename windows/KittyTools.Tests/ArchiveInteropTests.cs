// 导出文件两边互相读得了（REVIEW R80–R82、R85，2026-11-15）。
// mac 的样本 Fixtures/mac-archive-9acd4306.json：照 mac origin/macos 9acd4306 的 Storage/SettingsArchive.swift（capture / encoded：
// 缩进、键排序、日期 .iso8601）和 KittyToolsTests/SettingsArchiveTests.swift 里的写法手写的（这台机器跑不了 Swift），不是用户的文件；
// 带着对象形式的快捷键（含 shot.<名字> 和清除了的 null）、网页搜索（含没有 {query} 的快捷链接、关着兜底的）、三个翻译服务（一个关着）、
// 状态屏的状态和提醒（在 preferences 里）、片段、生词、便签，还有几项 Windows 不认的 mac 设置。
// Windows 写出去的那一份按 mac 的必填字段逐项查（Core ArchiveMacCheck，规则照 mac 的解码代码）。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ArchiveInteropTests
{
    private static string MacSample()
        => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "mac-archive-9acd4306.json"));

    [TestMethod]
    public void MacSampleIsWhatMacWouldRead()
    {
        // 样本本身得是 mac 认的：查的规则和 mac 的解码一致，否则下面拿它查 Windows 的文件也不作数
        CollectionAssert.AreEqual(Array.Empty<string>(), ArchiveMacCheck.Problems(MacSample()));
    }

    [TestMethod]
    public void ReadsMacFileWithObjectHotkeys()
    {
        var (archive, failure) = SettingsArchive.Read(MacSample());
        Assert.AreEqual(SettingsArchive.ReadFailure.None, failure);
        Assert.IsNotNull(archive);

        // R81：对象形式的快捷键读得进来（原来整份失败），但不当 Windows 的快捷键导
        Assert.AreEqual(4, archive.Hotkeys!.Count);
        Assert.AreEqual(JsonValueKind.Object, archive.Hotkeys["clipboard"].ValueKind);
        Assert.IsNull(archive.WindowsKeys);
        // mac 的设置不整类导：只有状态、提醒两张列表（R82）
        Assert.IsNull(archive.WindowsSettings);
        Assert.IsFalse(archive.AppliesWindowsSettings);
        CollectionAssert.AreEquivalent(new[] { "statusScreenPresets", "reminders" }, archive.MacLists!.Keys.ToArray());
        var statuses = StatusPresets.ReadList(archive.MacLists["statusScreenPresets"])!;
        CollectionAssert.AreEqual(new[] { "meeting", "clean" }, statuses.Select(preset => preset.Id).ToArray());
        Assert.AreEqual("开会中", statuses[0].Title);
        var reminders = Reminders.ReadList(archive.MacLists["reminders"])!;
        Assert.AreEqual(1, reminders.Count);
        Assert.AreEqual("Mac 上的提醒", reminders[0].Title);
        Assert.IsTrue(reminders[0].IsOn);

        // R82：服务的开关读 isEnabled（关着的 DeepL 不能变成开）
        CollectionAssert.AreEqual(new bool?[] { true, false, true }, archive.TranslateServices!.Select(service => service.On).ToArray());
        Assert.AreEqual("openai", archive.TranslateServices![2].AiProtocol);
        // R82：搜索读 urlTemplate / enabled，快捷链接（没有 {query}）不筛掉
        Assert.AreEqual(2, archive.SearchEngines!.Count);
        Assert.AreEqual("https://mail.example.com/inbox", archive.SearchEngines[1].Template);
        CollectionAssert.AreEqual(new bool?[] { true, false }, archive.SearchEngines.Select(engine => engine.IsFallback).ToArray());

        Assert.AreEqual(2, archive.Clips!.Count);
        Assert.AreEqual(DateTimeOffset.Parse("2026-11-14T03:20:00Z"), archive.Clips[0].CopiedAt);
        Assert.AreEqual(1, archive.Vocabulary!.Count);
        Assert.AreEqual(1, NoteEntry.Sanitized(archive.Notes!).Count);
        Assert.AreEqual("0.9.0", archive.Version);
    }

    private static SettingsArchive WindowsArchive()
    {
        using var preferences = JsonDocument.Parse("""{"theme": "dark", "clipboardRetentionDays": 7, "statusScreenPresets": []}""");
        var note = new NoteEntry
        {
            Id = "4C1E8F6A-6A1B-4B0E-9D52-7B7A3E0C9F12", Title = "标题", Body = "正文 ✨", Color = 1, CreatedAt = 1763180000123,
            ModifiedAt = 1763183600456, Revision = 2, Pinned = true, Order = 1.5,
        };
        using var noteJson = JsonDocument.Parse(note.Json());
        return new SettingsArchive
        {
            Platform = SettingsArchive.WindowsPlatform,
            Version = "0.3.0",
            // 带毫秒、非 UTC：写出去要到秒、带 Z
            ExportedAt = new DateTimeOffset(2026, 11, 15, 17, 30, 5, 789, TimeSpan.FromHours(9)),
            WindowsPreferences = preferences.RootElement.EnumerateObject().ToDictionary(property => property.Name, property => property.Value.Clone()),
            WindowsHotkeys = new Dictionary<string, string?> { ["clipboard"] = "Alt+C", ["shotHistory"] = null },
            TranslateServices = new List<SettingsArchive.ArchiveService>
            {
                new() { Id = "zhipu", Kind = "zhipu", Name = "智谱 GLM（免费）", IsEnabled = true, Model = "glm-4-flash" },
                new() { Id = "ai:9f8e7d6c", Kind = "ai", Name = "本机模型", IsEnabled = false, BaseUrl = "http://localhost:11434/v1", AiProtocol = "openai" },
            },
            SearchEngines = new List<SettingsArchive.ArchiveEngine>
            {
                new() { Id = "google", Name = "Google", Keyword = "g", UrlTemplate = "https://www.google.com/search?q={query}", Enabled = true },
                new() { Id = "custom-1", Name = "工单", Keyword = "", UrlTemplate = "https://jira.example.com/board", Enabled = false },
            },
            Clips = new List<SettingsArchive.ArchiveClip>
            {
                new() { Text = "片段 {cursor}", Favorite = true, Snippet = true, Group = "工作", CopiedAt = DateTimeOffset.FromUnixTimeMilliseconds(1763180000999) },
            },
            ClipGroups = new List<string> { "工作" },
            Vocabulary = new List<SettingsArchive.ArchiveWord>
            {
                new() { Source = "dog", Target = "zh-Hans", Result = "狗", Service = "zhipu", CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds(1763180000001) },
            },
            Notes = new List<JsonElement> { noteJson.RootElement.Clone() },
        };
    }

    [TestMethod]
    public void WindowsFileHasEveryFieldMacRequires()
    {
        var text = SettingsArchive.Write(WindowsArchive());
        CollectionAssert.AreEqual(Array.Empty<string>(), ArchiveMacCheck.Problems(text), text);
        // Windows 的设置、快捷键不进 mac 会整类替换的那两个键（R80）
        using var document = JsonDocument.Parse(text);
        Assert.IsFalse(document.RootElement.TryGetProperty("preferences", out _));
        Assert.IsFalse(document.RootElement.TryGetProperty("hotkeys", out _));
        Assert.IsTrue(document.RootElement.TryGetProperty("windowsPreferences", out _));
        Assert.IsTrue(document.RootElement.TryGetProperty("windowsHotkeys", out _));
        // 时间到秒、带 Z（R85）；旧键名不再写
        StringAssert.Contains(text, "\"exportedAt\": \"2026-11-15T08:30:05Z\"");
        StringAssert.Contains(text, "\"copiedAt\": \"2025-11-15T04:13:20Z\"");
        Assert.IsFalse(text.Contains("\"fallback\"", StringComparison.Ordinal) || text.Contains("\"url\"", StringComparison.Ordinal));
        // 中文、表情原样写（R85）
        StringAssert.Contains(text, "智谱 GLM（免费）");
        StringAssert.Contains(text, "正文 ✨");
    }

    [TestMethod]
    public void WindowsFileRoundTrips()
    {
        var (archive, failure) = SettingsArchive.Read(SettingsArchive.Write(WindowsArchive()));
        Assert.AreEqual(SettingsArchive.ReadFailure.None, failure);
        Assert.IsTrue(archive!.AppliesWindowsSettings);
        Assert.AreEqual("dark", archive.WindowsSettings!["theme"].GetString());
        Assert.AreEqual("Alt+C", archive.WindowsKeys!["clipboard"]);
        Assert.IsNull(archive.WindowsKeys["shotHistory"]);
        Assert.IsNull(archive.MacLists, "Windows 的文件不走 mac 那两张列表的路");
        CollectionAssert.AreEqual(new bool?[] { true, false }, archive.TranslateServices!.Select(service => service.On).ToArray());
        Assert.AreEqual(2, archive.SearchEngines!.Count);
        Assert.AreEqual(false, archive.SearchEngines[1].IsFallback);
        Assert.AreEqual(1, NoteEntry.Sanitized(archive.Notes!).Count);
    }

    [TestMethod]
    public void OldWindowsFilesStillRead()
    {
        // 改格式之前 Windows 写的：platform、preferences、字符串的 hotkeys、enabled、url / fallback，没有 version / exportedAt
        const string old = """
            {"app": "Kitty Tools", "format": 2, "platform": "windows",
             "preferences": {"theme": "light"}, "hotkeys": {"clipboard": "Alt+V", "launcher": null},
             "translateServices": [{"id": "deepl", "kind": "deepl", "name": "DeepL", "enabled": false}],
             "searchEngines": [{"id": "g", "name": "G", "keyword": "g", "url": "https://g.example/?q={query}", "fallback": true},
                               {"id": "link", "name": "L", "keyword": "", "url": "https://link.example/"}],
             "clips": [{"text": "x", "favorite": true, "copiedAt": "2026-10-01T12:00:00.123+00:00"}]}
            """;
        var (archive, failure) = SettingsArchive.Read(old);
        Assert.AreEqual(SettingsArchive.ReadFailure.None, failure);
        Assert.AreEqual("light", archive!.WindowsSettings!["theme"].GetString());
        Assert.AreEqual("Alt+V", archive.WindowsKeys!["clipboard"]);
        Assert.IsNull(archive.WindowsKeys["launcher"]);
        Assert.AreEqual(false, archive.TranslateServices![0].On);
        Assert.AreEqual(2, archive.SearchEngines!.Count, "旧文件里的快捷链接也收");
        Assert.AreEqual("https://g.example/?q={query}", archive.SearchEngines[0].Template);
        Assert.AreEqual(true, archive.SearchEngines[0].IsFallback);
        Assert.AreEqual(DateTimeOffset.Parse("2026-10-01T12:00:00.123+00:00"), archive.Clips![0].CopiedAt);
    }

    [TestMethod]
    public void SaysWhyAFileCannotBeRead()
    {
        Assert.AreEqual(SettingsArchive.ReadFailure.NotArchive, SettingsArchive.Read("""{"app": "Other"}""").Failure);
        Assert.AreEqual(SettingsArchive.ReadFailure.NotArchive, SettingsArchive.Read("不是 JSON").Failure);
        // R85：格式比自己新的单独说「先更新」（同 mac .newer）
        Assert.AreEqual(SettingsArchive.ReadFailure.Newer, SettingsArchive.Read("""{"app": "Kitty Tools", "format": 3, "version": "9"}""").Failure);
        StringAssert.Contains(SettingsArchive.FailureText(SettingsArchive.ReadFailure.Newer), "先更新");
        Assert.AreEqual(SettingsArchive.ReadFailure.Unreadable, SettingsArchive.Read("""{"app": "Kitty Tools", "format": 2, "clips": "全部"}""").Failure);
    }

    [TestMethod]
    public void MacCheckCatchesTheOldWindowsShape()
    {
        // 改之前 Windows 写的样子：mac 读不了的几处都要被查出来（证明这张检查表管用）
        const string old = """
            {"app": "Kitty Tools", "format": 2, "platform": "windows", "hotkeys": {"clipboard": "Alt+C"},
             "translateServices": [{"id": "zhipu", "kind": "zhipu", "name": "智谱", "enabled": true, "aiProtocol": "openai"}],
             "searchEngines": [{"id": "g", "name": "G", "keyword": "g", "url": "https://g.example/?q={query}", "fallback": true}],
             "clips": [{"text": "x", "favorite": true, "snippet": false, "copiedAt": "2026-10-01T12:00:00.123+00:00"}]}
            """;
        var problems = ArchiveMacCheck.Problems(old);
        foreach (var expected in new[] { "version", "exportedAt", "hotkeys.clipboard", "translateServices[0].isEnabled", "searchEngines[0].urlTemplate", "searchEngines[0].enabled", "clips[0].copiedAt" })
        {
            Assert.IsTrue(problems.Any(problem => problem.StartsWith(expected, StringComparison.Ordinal)), $"{expected} 没查出来：{string.Join(" / ", problems)}");
        }
    }
}
