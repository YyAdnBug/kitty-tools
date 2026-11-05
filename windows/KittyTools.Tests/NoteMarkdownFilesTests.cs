// PLAN-v13 第 7 批：便签 Markdown 导出 / 导入的纯函数（Core NoteMarkdownFiles，照 mac Notes/NoteMarkdownFiles.swift）。
// 用例照 mac macos/KittyToolsTests/NoteMarkdownFilesTests.swift 移植（另有 NoteCustomPaperTests 的 markdownHeaderCarriesTheTint、
// NoteSyncFolderTests 里碰到 NoteMarkdownFiles 的那几句），期望值原样；时间是整数毫秒（mac 的 created = 1_760_000_000.123 s、
// modified = 1_760_000_100.456 s），时区显式给（UTC、UTC+8），不看本机。
// mac 那边真读写临时目录的，这里只移纯函数那一半（读写文件、拷图片、存图片在 App 的 NotesTransfer），改成「文件全文 →
// ParseHeader / ForeignHeaderEnd → BodyFromMarkdown → ConvertImagesAsync（假的 store）→ OwnNote / ForeignNote」，不进仓库：
// exportThenImportRoundTrips、imagesInCodeBlocksTravelToo、foreignFilesBecomeNewNotes、importHandlesBOMCRLFAndBadFiles（Decode）、
// externallyEditedFilesComeBack（只验 edited 和改于，NoteStore.adopt 的 contentOnly 不在这里）、skipReasonsAndIslandMessage
// （跳过的原因直接往 ImportResult 里加）、importStoresForeignImagesAndKeepsBadOnes。
// 跳过的（要真的文件系统或仓库）：imagePathsStayInsideTheChosenFolder（imageURL 解析符号链接，App 的 ImagePath）、
// importSkipsSyncFiles（认同步文件是 NoteSyncFolder.IsSyncFile，NoteSyncTests 里测）、NoteCustomPaperTests.markdownExportImportKeepsTheTint
// 的读文件 + adopt 那半、NoteBatch8bTests 的 singleExportMatchesWholeFolderExport / singleExportCountsAnImageOnce /
// singleExportReportsMissingImages（拷图片、不覆盖已有的）、NoteBatch8ProbeTests（量测）。
// Windows 另加的：文件名里 Windows 不许的字符和设备名、导出文件夹的候选名、文件头的整段写法（时区）、ISO 时间的读法、
// 导出的头和同步文件的头去掉 sync- 那几行一字不差。
using System.Text;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Md = KittyTools.Core.Notes.NoteMarkdownFiles;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteMarkdownFilesTests
{
    private const long Created = 1_760_000_000_123;
    private const long Modified = 1_760_000_100_456;
    private const long Now = 1_800_000_000_000;
    private const string FixedId = "2F1C6E5A-1111-2222-3333-444455556666";

    private static readonly TimeZoneInfo Utc8 = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");

    private static string NewId() => NoteImages.IdText(Guid.NewGuid());

    private static Note Make(
        string body, string? id = null, string title = "", int color = 3, int revision = 12, bool archived = false,
        bool pinned = true, double order = 3.5)
        => new()
        {
            Id = id ?? NewId(), Title = title, Body = body, Color = color, CreatedAt = Created, ModifiedAt = Modified,
            Revision = revision, IsArchived = archived, IsPinned = pinned, Order = order,
        };

    private static string Token(Guid id, string width = "") => $"![image{width}](kitty-note-image://{NoteImages.IdText(id)}.png)";

    private static string Exported(Guid id, string width = "") => $"![image{width}](attachments/{NoteImages.IdText(id)}.png)";

    /// <summary>导出时写出去的 attachments/&lt;编号&gt;.&lt;扩展名&gt; 换回同一个令牌（mac storedImage：仓库里已有、字节一样就沿用编号）。</summary>
    private static Task<string?> SameImage(Md.MarkdownImage image)
    {
        var name = image.Path[(image.Path.LastIndexOf('/') + 1)..];
        var dot = name.LastIndexOf('.');
        return Task.FromResult<string?>(
            NoteImages.Token(new NoteImages.Image(Guid.Parse(name[..dot]), name[(dot + 1)..], image.Width)));
    }

    /// <summary>一份自家文件的全文 → 一条便签（App 的 NotesTransfer 那条路，去掉读文件）。</summary>
    private static async Task<(Note Note, bool Edited, int Failures)> Own(string text, long? fileModified)
    {
        var header = Md.ParseHeader(text, fileModified ?? Now);
        Assert.IsNotNull(header);
        var (_, body) = Md.BodyFromMarkdown(header.Text);
        var (converted, failures) = await Md.ConvertImagesAsync(body, SameImage);
        var note = Md.OwnNote(header, converted, fileModified, Now, out var edited);
        return (note, edited, failures);
    }

    /// <summary>别处的文件（没有自家的头）→ 一条新便签。</summary>
    private static Note Foreign(string raw, string stem, int index)
    {
        Assert.IsNull(Md.ParseHeader(raw, Now));
        var (prefix, body) = Md.BodyFromMarkdown(raw, Md.ForeignHeaderEnd(raw));
        return Md.ForeignNote(prefix + body, stem, index, Modified, Now, NewId());
    }

    private static void Says(string title, string? detail, bool warning, (string Title, string? Detail, bool Warning) actual)
    {
        Assert.AreEqual(title, actual.Title);
        Assert.AreEqual(detail, actual.Detail);
        Assert.AreEqual(warning, actual.Warning);
    }

    // ---- 文件名 ----

    [TestMethod]
    public void FileNamesAreCleanedAndDeduplicated()
    {
        Assert.AreEqual("未命名便签", Md.FileName(Make(string.Empty)));
        Assert.AreEqual("-报告- 一-二-三", Md.FileName(Make("  ../报告: 一/二\\三" + (char)7 + "  ")));
        var longTitle = Md.FileName(Make(string.Empty, title: new string('长', 100)));
        Assert.IsTrue(NoteText.Count(longTitle) <= 80 && Encoding.UTF8.GetByteCount(longTitle) <= 200);
        Assert.IsTrue(Md.FileName(Make("🙂🙂🙂")).StartsWith("🙂", StringComparison.Ordinal));
        // 重名（不分大小写、Unicode 规范化后比）加 2、3
        var notes = new[] { Make("Report", title: "Report"), Make("report", title: "report"), Make("REPORT"), Make("Report") };
        CollectionAssert.AreEqual(new[] { "Report", "report 2", "REPORT 3", "Report 4" }, Md.FileNames(notes));
        // 截断之后加序号也不超过 80 个字
        var longName = new string('字', 100);
        var names = Md.FileNames(new[] { Make(string.Empty, title: longName), Make(string.Empty, title: longName) });
        Assert.IsTrue(NoteText.Count(names[0]) <= 80 && NoteText.Count(names[1]) <= 80 && names[0] != names[1]);
        // 已经用掉的名字
        CollectionAssert.AreEqual(new[] { "Report 2" }, Md.FileNames(new[] { Make("Report") }, new HashSet<string> { "report" }));
        Assert.AreEqual("🙂🙂", Md.Truncate("🙂🙂🙂", 2, 100));
        Assert.AreEqual("长长", Md.Truncate("长长长", 10, 8));
    }

    /// <summary>Windows 另加：文件名里 Windows 不许的字符换成「-」，设备名前面加「_」。</summary>
    [TestMethod]
    public void FileNamesAvoidWhatWindowsRejects()
    {
        Assert.AreEqual("a-b-c-d-e-f-g", Md.FileName(Make(string.Empty, title: "a<b>c\"d|e?f*g")));
        Assert.AreEqual("_CON", Md.FileName(Make(string.Empty, title: "CON")));
        Assert.AreEqual("_nul.txt", Md.FileName(Make(string.Empty, title: "nul.txt")));
        Assert.AreEqual("_com1", Md.FileName(Make(string.Empty, title: "com1")));
        Assert.AreEqual("console", Md.FileName(Make(string.Empty, title: "console")));
        Assert.AreEqual("COM10", Md.FileName(Make(string.Empty, title: "COM10")));
    }

    [TestMethod]
    public void FolderNamesCountUp()
    {
        var names = Md.FolderNames(new DateTime(2026, 10, 17)).ToList();
        CollectionAssert.AreEqual(
            new[] { "Kitty Tools 便签 2026-10-17", "Kitty Tools 便签 2026-10-17 2", "Kitty Tools 便签 2026-10-17 3" },
            names.Take(3).ToList());
        Assert.AreEqual(10_000, names.Count);
    }

    // ---- 文件头 ----

    [TestMethod]
    public void HeaderRoundTrips()
    {
        var original = Make(
            "正文", id: FixedId, title: "他说「走吧」\n换行 \\ 反斜杠", color: 7, revision: 42, archived: true, pinned: false,
            order: 3.5);
        var header = Md.ParseHeader(Md.Header(original, null, Utc8) + "\n\n" + original.Body, 0);
        Assert.IsNotNull(header);
        Assert.AreEqual(original.Id, header.Id);
        Assert.AreEqual(original.Title, header.Title);
        Assert.AreEqual((long?)original.CreatedAt, header.Created);
        Assert.AreEqual((long?)original.ModifiedAt, header.Modified);
        Assert.AreEqual(7, header.Color);
        Assert.AreEqual(42, header.Revision);
        Assert.IsTrue(header.Archived);
        Assert.IsFalse(header.Pinned);
        Assert.AreEqual(3.5, header.Order);
        Assert.AreEqual("正文", header.Text);
        Assert.IsNull(header.Tint);
        Assert.IsNull(header.BodyHash);
        // 没有自己起的标题就不写那一行
        Assert.IsFalse(Md.Header(Make("正文"), null, Utc8).Contains("title:", StringComparison.Ordinal));
        // 坏的数值：颜色夹到 0–7、未知键忽略、时间认不出用 fallback、revision / order / 布尔按规矩
        var broken = string.Join(
            "\n", "---", "kitty-note: " + FixedId, "title: not json", "color: 99", "created: 昨天",
            "modified: 2026-10-12T09:30:05.123+08:00", "revision: -4", "archived: yes", "pinned: true", "order: 1e999",
            "other: 值", "---", "正文");
        var parsed = Md.ParseHeader(broken, 1_700_000_000_000);
        Assert.IsNotNull(parsed);
        Assert.AreEqual(string.Empty, parsed.Title);
        Assert.AreEqual(7, parsed.Color);
        Assert.IsNull(parsed.Created);
        Assert.AreEqual((long?)1_791_768_605_123, parsed.Modified);
        Assert.AreEqual(0, parsed.Revision);
        Assert.IsFalse(parsed.Archived);
        Assert.IsTrue(parsed.Pinned);
        Assert.AreEqual(0.0, parsed.Order);
        Assert.AreEqual("正文", parsed.Text);
        // 收尾的 --- 后面没有正文
        Assert.AreEqual(string.Empty, Md.ParseHeader("---\nkitty-note: " + NewId() + "\n---", 0)?.Text);
        // 没有合法编号的不是自家的
        Assert.IsNull(Md.ParseHeader("---\ntitle: x\n---\n正文", 0));
        Assert.IsNull(Md.ParseHeader("没有头", 0));
    }

    /// <summary>Windows 另加：整段的写法（同 mac：时间到毫秒、带时区）；编号小写也认、读出来是大写；时间带不带小数秒都认，
    /// 认不出的 modified 用 fallback。</summary>
    [TestMethod]
    public void HeaderFormatAndDates()
    {
        var expected = "---\nkitty-note: " + FixedId + "\ncolor: 3\ncreated: 2025-10-09T08:53:20.123Z\n" +
                       "modified: 2025-10-09T08:55:00.456Z\nrevision: 12\narchived: false\npinned: true\norder: 3.5\n" +
                       "body-hash: abc\n---";
        Assert.AreEqual(expected, Md.Header(Make("正文", id: FixedId), "abc", TimeZoneInfo.Utc));
        Assert.IsTrue(Md.Header(Make("正文"), null, Utc8)
            .Contains("\ncreated: 2025-10-09T16:53:20.123+08:00\nmodified: 2025-10-09T16:55:00.456+08:00\n", StringComparison.Ordinal));
        Assert.AreEqual(FixedId, Md.ParseHeader("---\nkitty-note: " + FixedId.ToLowerInvariant() + "\n---", 0)?.Id);
        string Dated(string modified) => "---\nkitty-note: " + FixedId + "\nmodified: " + modified + "\n---";
        Assert.AreEqual((long?)1_791_768_605_000, Md.ParseHeader(Dated("2026-10-12T01:30:05Z"), 0)?.Modified);
        Assert.AreEqual((long?)1_791_768_605_500, Md.ParseHeader(Dated("2026-10-12T01:30:05.5Z"), 0)?.Modified);
        Assert.AreEqual((long?)1_791_768_605_123, Md.ParseHeader(Dated("2026-10-11T20:30:05.123-05:00"), 0)?.Modified);
        Assert.AreEqual((long?)42, Md.ParseHeader(Dated("2026-02-30T01:30:05Z"), 42)?.Modified);
        Assert.AreEqual((long?)42, Md.ParseHeader(Dated("2026-10-12 01:30:05Z"), 42)?.Modified);
        Assert.AreEqual((long?)42, Md.ParseHeader(Dated("2026-10-12T01:30:05"), 42)?.Modified);
    }

    /// <summary>文件头：color 写最接近的预设、tint 带引号另写一行（YAML 里 # 起注释）；读回来合起来。没有 tint 的是预设、写坏的当没有
    /// （mac NoteCustomPaperTests.markdownHeaderCarriesTheTint）。</summary>
    [TestMethod]
    public void HeaderCarriesTheTint()
    {
        var note = Make("正文") with { Color = Note.Custom(0xFFE0F0) };
        var header = Md.Header(note, null, TimeZoneInfo.Utc);
        var preset = NotePaper.NearestPreset(0xFFE0F0);
        Assert.IsTrue(header.Contains($"\ncolor: {preset}\n", StringComparison.Ordinal));
        Assert.IsTrue(header.Contains("\ntint: \"#FFE0F0\"\n", StringComparison.Ordinal));
        var parsed = Md.ParseHeader(header + "\n\n正文", 0);
        Assert.IsNotNull(parsed);
        Assert.AreEqual(preset, parsed.Color);
        Assert.AreEqual((int?)0xFFE0F0, parsed.Tint);
        Assert.AreEqual(note.Color, Note.ColorFrom(parsed.Color, parsed.Tint));
        Assert.AreEqual(note.Color, Md.OwnNote(parsed, "正文", null, Now, out _).Color);
        Assert.IsFalse(Md.Header(note with { Color = 6 }, null, TimeZoneInfo.Utc).Contains("tint", StringComparison.Ordinal));
        Assert.IsNull(Md.ParseHeader(header.Replace("\"#FFE0F0\"", "#FFE0F0", StringComparison.Ordinal), 0)?.Tint);
    }

    /// <summary>同步文件的头这里也读得懂（设置里「导入…」认出是同步文件就跳过）；导出的文件不是同步文件、也读不成同步的便签；
    /// 标题不是空白时，导出的头 = 同步文件的头去掉 sync- 那几行（mac NoteSyncFolderTests 里的几句 + Windows 另加的对照）。</summary>
    [TestMethod]
    public void SyncFileHeadersAgree()
    {
        var tricky = Make(
            "\n\n---\n第一行 \r\n---" + (char)0x2028 + "☐ 待办\n\n", title: "  ", archived: true, pinned: true,
            order: -0.1 + 1e-9) with
        {
            Color = Note.Custom(0xC2DFF8),
            Clock = new Dictionary<string, long>(StringComparer.Ordinal) { ["A"] = 3, ["B-2"] = 7 },
            DeletedAt = Modified + 30_000,
        };
        var header = Md.ParseHeader(NoteSyncFolder.Text(tricky, TimeZoneInfo.Utc), 0);
        Assert.IsNotNull(header);
        Assert.AreEqual(tricky.Id, header.Id);
        Assert.AreEqual("  ", header.Title);
        Assert.IsTrue(header.Archived && header.Pinned);
        Assert.AreEqual(tricky.Color, Note.ColorFrom(header.Color, header.Tint));
        Assert.AreEqual(tricky.Order, header.Order);
        Assert.IsFalse(NoteSyncFolder.IsSyncFile(Md.Header(tricky, null, TimeZoneInfo.Utc) + "\n\n正文"));
        var good = Make("正文");
        Assert.IsNull(NoteSyncFolder.NoteFrom(Md.Header(good, null, TimeZoneInfo.Utc) + "\n\n正文", good.Id));
        var plain = Make("一行", title: "标题：带「引号」\"和\\反斜杠/\"\n换行") with { Color = Note.Custom(0xC2DFF8) };
        var lines = NoteSyncFolder.Text(plain, Utc8).Split('\n');
        var close = Array.IndexOf(lines, "---", 1);
        var synced = string.Join("\n", lines.Take(close + 1).Where(line => !line.StartsWith("sync-", StringComparison.Ordinal)));
        Assert.AreEqual(synced, Md.Header(plain, null, Utc8));
    }

    // ---- 三种换法 ----

    [TestMethod]
    public void MarkdownBodyConvertsTasksColorsAndImages()
    {
        var id = Guid.NewGuid();
        var body = "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n[红]{red} **粗**\n```\n☑ 块里 [不换]{red}\n```";
        var markdown = Md.MarkdownBody(body);
        Assert.IsTrue(markdown.Contains("- [ ] 一\n- [/] 二\n- [!] 三\n- [x] 四\n- [-] 五", StringComparison.Ordinal));
        Assert.IsTrue(markdown.Contains("<span style=\"color: #A11A14\">红</span> **粗**", StringComparison.Ordinal));
        Assert.AreEqual("前\n" + Exported(id, "|120"), Md.MarkdownBody("前\n" + Token(id, "|120")));
        Assert.IsTrue(markdown.Contains("```\n☑ 块里 [不换]{red}\n```", StringComparison.Ordinal));
        Assert.AreEqual(body, Md.BodyFromMarkdown(markdown).Body);
    }

    /// <summary>一行里有好几张图（mac 0.5.0 测试包崩过：第二张的位置按换之前的算）；同一张只给一次，按第一次出现的先后。</summary>
    [TestMethod]
    public void SeveralImagesOnOneLine()
    {
        var (a, b, c) = (Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid());
        var body = Token(a) + Token(b, "|120") + "\n前 " + Token(a) + " 中 " + Token(c) + " 后 " + Token(b) + " 尾\n" + Token(c) + Token(c);
        var (text, images) = Md.MarkdownImages(body);
        Assert.AreEqual(
            Exported(a) + Exported(b, "|120") + "\n前 " + Exported(a) + " 中 " + Exported(c) + " 后 " + Exported(b) + " 尾\n" +
            Exported(c) + Exported(c),
            text);
        CollectionAssert.AreEqual(new[] { a, b, c }, images.Select(image => image.Id).ToList());
        // 换行符原样（\r\n、U+2028 都算一行的结尾）
        var mixed = "x\r\n" + Token(a) + (char)0x2028 + "y";
        Assert.AreEqual("x\r\n" + Exported(a) + (char)0x2028 + "y", Md.MarkdownImages(mixed).Text);
    }

    [TestMethod]
    public void MarkdownImagesParseWidthAndPaths()
    {
        var images = Md.MarkdownImagesIn("前 ![说明|240](attachments/a.png) 中 ![图](b%20c.jpg) 后");
        Assert.AreEqual(2, images.Count);
        Assert.AreEqual((int?)240, images[0].Width);
        Assert.AreEqual("attachments/a.png", images[0].Path);
        Assert.AreEqual(new NoteRange(2, "![说明|240](attachments/a.png)".Length), images[0].Range);
        Assert.IsNull(images[1].Width);
        Assert.AreEqual("b%20c.jpg", images[1].Path);
        Assert.AreEqual(0, Md.MarkdownImagesIn("`![图](x.png)`").Count);
        Assert.AreEqual(0, Md.MarkdownImagesIn("![空]()").Count);
        Assert.IsNull(Md.MarkdownImagesIn("![宽|9](a.png)")[0].Width);
    }

    // ---- 导出 / 导入（纯函数那一半）----

    [TestMethod]
    public async Task ExportedFilesComeBackTheSame()
    {
        var imageId = Guid.NewGuid();
        var original = Make(
            "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n[红]{red} **粗**\n" + Token(imageId, "|120"), id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            title: "标题 / 测试", color: 5, revision: 7, archived: true, pinned: true, order: 1.25);
        Assert.AreEqual("标题 - 测试", Md.FileName(original));
        var (text, images) = Md.FileText(original, Utc8);
        CollectionAssert.AreEqual(new[] { new NoteImages.Image(imageId, "png", 120) }, images);
        Assert.IsTrue(text.Contains("kitty-note: " + original.Id, StringComparison.Ordinal));
        Assert.IsTrue(text.Contains("\ncolor: 5\n", StringComparison.Ordinal));
        Assert.IsTrue(text.Contains("- [!] 三", StringComparison.Ordinal));
        Assert.IsTrue(text.Contains("<span style=\"color: #A11A14\">红</span>", StringComparison.Ordinal));
        Assert.IsTrue(text.Contains(Exported(imageId, "|120"), StringComparison.Ordinal));
        Assert.IsTrue(text.Contains("\nbody-hash: ", StringComparison.Ordinal));
        // 导回来：内容一样（文件时间比导出时新——被拷过、碰过——也不算改过）；同一份读两遍一样
        var (back, edited, failures) = await Own(text, Modified + 3_600_000);
        Assert.IsFalse(edited);
        Assert.AreEqual(0, failures);
        Assert.AreEqual(original.Id, back.Id);
        Assert.AreEqual(original.Title, back.Title);
        Assert.AreEqual(original.Body, back.Body);
        Assert.AreEqual(original.Color, back.Color);
        Assert.IsTrue(back.IsArchived && back.IsPinned);
        Assert.AreEqual(1.25, back.Order);
        Assert.AreEqual(original.Revision, back.Revision);
        Assert.AreEqual(original.CreatedAt, back.CreatedAt);
        Assert.AreEqual(original.ModifiedAt, back.ModifiedAt);
        Assert.AreEqual(back, (await Own(text, Modified + 3_600_000)).Note);
    }

    /// <summary>代码块里的图：导出时也换成 attachments/ 的写法，导回来换回同一个令牌。代码块里只认导出时写出去的那种路径：
    /// 别的图片语法是代码，原样留着、不读文件、不算没导进来。</summary>
    [TestMethod]
    public async Task ImagesInCodeBlocksTravelToo()
    {
        var imageId = Guid.NewGuid();
        var body = "前\n```\n" + Token(imageId, "|90") + "\n☑ 块里\n```\n后";
        var (text, images) = Md.MarkdownImages(body);
        Assert.AreEqual("前\n```\n" + Exported(imageId, "|90") + "\n☑ 块里\n```\n后", text);
        CollectionAssert.AreEqual(new[] { imageId }, images.Select(image => image.Id).ToList());
        var (file, _) = Md.FileText(Make(body, title: "代码"), TimeZoneInfo.Utc);
        var (back, _, failures) = await Own(file, Modified);
        Assert.AreEqual(0, failures);
        Assert.AreEqual(body, back.Body);
        // 别处的 .md：代码块里别的图片语法原样留着
        const string code = "```\n![图](a.png) ![x](attachments/b.png)\n```";
        Assert.IsNull(Md.ForeignHeaderEnd(code));
        var calls = 0;
        var (converted, missing) = await Md.ConvertImagesAsync(
            Md.BodyFromMarkdown(code).Body,
            _ =>
            {
                calls++;
                return Task.FromResult<string?>(null);
            });
        Assert.AreEqual(code, converted);
        Assert.AreEqual(0, missing);
        Assert.AreEqual(0, calls);
        Assert.IsTrue(Md.IsExported("attachments/" + NoteImages.IdText(imageId) + ".png"));
        Assert.IsFalse(Md.IsExported("attachments/b.png"));
        Assert.IsFalse(Md.IsExported("x/" + NoteImages.IdText(imageId) + ".png"));
    }

    [TestMethod]
    public void ForeignFilesBecomeNewNotes()
    {
        var heading = Foreign("# 标题\n正文 **粗**", "有标题", 0);
        Assert.AreEqual(string.Empty, heading.Title);
        Assert.AreEqual("# 标题\n正文 **粗**", heading.Body);
        var plain = Foreign("第一行\n第二行", "没有标题", 1);
        Assert.AreEqual("没有标题", plain.Title);
        Assert.AreEqual("第一行\n第二行", plain.Body);
        Assert.AreEqual((int?)17, Md.ForeignHeaderEnd("---\ntitle: x\n---\n正文"));
        var yaml = Foreign("---\ntitle: x\n---\n正文", "别人的头", 2);
        Assert.AreEqual("别人的头", yaml.Title);
        Assert.AreEqual("---\ntitle: x\n---\n正文", yaml.Body);
        Assert.AreEqual(-1_000_000_000 + 2.0, yaml.Order);
        Assert.AreEqual(Modified, yaml.CreatedAt);
        Assert.AreEqual(Modified, yaml.ModifiedAt);
        Assert.AreNotEqual(heading.Id, plain.Id);
        // 别人的头原样留着，只换它后面的字
        Assert.AreEqual("---\n- [x] 在头里\n---\n☐ 待办", Foreign("---\n- [x] 在头里\n---\n- [ ] 待办", "t", 3).Body);
        // 文件时间比现在还晚：取现在
        Assert.AreEqual(Now, Md.ForeignNote("x", "x", 0, Now + 5000, Now, NewId()).ModifiedAt);
    }

    [TestMethod]
    public void DecodeHandlesBOMAndLineEndings()
    {
        var bom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("第一行\r\n第二行\r第三行")).ToArray();
        Assert.AreEqual("第一行\n第二行\n第三行", Md.Decode(bom));
        Assert.IsNull(Md.Decode(new byte[] { 0xFF, 0xFE, 0x00, 0x41 }));
        Assert.AreEqual(string.Empty, Md.Decode(Array.Empty<byte>()));
    }

    // ---- 在别处改过的自家文件（第四轮体检 E18）----

    /// <summary>有正文哈希只看它；没有的文件时间比文件头晚 2 秒以上才算；文件时间读不出来不算。</summary>
    [TestMethod]
    public void EditedElsewhereFollowsTheBodyHash()
    {
        const long header = 1_760_000_000_000;
        const long later = header + 3_600_000;
        Assert.IsFalse(Md.EditedElsewhere(header, later, false), "有哈希、对得上：文件时间再新也不算（被碰过）");
        Assert.IsTrue(Md.EditedElsewhere(header, later, true));
        Assert.IsFalse(Md.EditedElsewhere(header, null, true));
        Assert.IsFalse(Md.EditedElsewhere(header, header + 2000, null));
        Assert.IsFalse(Md.EditedElsewhere(header, header - 60_000, null));
        Assert.IsTrue(Md.EditedElsewhere(header, header + 2500, null));
    }

    /// <summary>被碰过（文件时间新了、字没动）不算改过；在别处改了正文算改过、改于是文件时间；没有哈希的旧文件按文件时间认。</summary>
    [TestMethod]
    public async Task ExternallyEditedFilesComeBack()
    {
        var (text, _) = Md.FileText(Make("原来的字"), TimeZoneInfo.Utc);
        Assert.IsTrue(text.Contains("\nbody-hash: ", StringComparison.Ordinal));
        var touched = await Own(text, Modified + 3_600_000);
        Assert.IsFalse(touched.Edited);
        Assert.AreEqual(Modified, touched.Note.ModifiedAt);
        // 在别的编辑器里改了正文（文件头没动）
        var changed = text.Replace("原来的字", "外面改的字", StringComparison.Ordinal);
        var editedAt = Modified + 7_200_000;
        var edited = await Own(changed, editedAt);
        Assert.IsTrue(edited.Edited);
        Assert.AreEqual("外面改的字", edited.Note.Body);
        Assert.AreEqual(editedAt, edited.Note.ModifiedAt);
        Assert.IsFalse((await Own(changed, null)).Edited, "文件时间读不出来：不算改过");
        // 没有哈希的旧文件：文件时间比文件头晚 2 秒以上才算改过
        var legacy = string.Join("\n", text.Split('\n').Where(line => !line.StartsWith("body-hash:", StringComparison.Ordinal)))
            .Replace("原来的字", "旧文件里改的", StringComparison.Ordinal);
        var late = await Own(legacy, Modified + 10_000);
        Assert.IsTrue(late.Edited);
        Assert.AreEqual("旧文件里改的", late.Note.Body);
        Assert.AreEqual(Modified + 10_000, late.Note.ModifiedAt);
        var close = await Own(legacy, Modified + 1_000);
        Assert.IsFalse(close.Edited);
        Assert.AreEqual(Modified, close.Note.ModifiedAt);
    }

    /// <summary>跳过的原因分开数；岛上那句话：新增 / 更新 / 没有变化 / 全被跳过时写原因 / 没有 .md。</summary>
    [TestMethod]
    public void SkipReasonsAndIslandMessage()
    {
        var skipped = new Md.ImportResult();
        skipped.Add(Md.Skip.TooLarge);
        skipped.Add(Md.Skip.NotText);
        skipped.Add(Md.Skip.Unreadable, 0);
        Assert.AreEqual(2, skipped.Skipped);
        Assert.AreEqual(2, skipped.Reasons.Count);
        Assert.AreEqual(1, skipped.Reasons[Md.Skip.TooLarge]);
        Assert.AreEqual(1, skipped.Reasons[Md.Skip.NotText]);
        Says("没有导入", "全部跳过了：1 个太大（超过 4 MB）、1 个不是 UTF-8 文本", true, Md.ImportMessage(2, skipped, 0, 0));
        Says("没有导入", "选的地方没有 .md 文件", true, Md.ImportMessage(0, new Md.ImportResult(), 0, 0));
        var read = new Md.ImportResult();
        read.Notes.AddRange(new[] { Make("一"), Make("二"), Make("三") });
        Says("没有变化", "3 条和现在的一样", false, Md.ImportMessage(3, read, 0, 0));
        Assert.AreEqual("已导入 3 条新便签", Md.ImportMessage(3, read, 3, 0).Title);
        Says("已更新 1 条便签", "2 条和现在的一样", false, Md.ImportMessage(3, read, 0, 1));
        read.Add(Md.Skip.TooLarge);
        read.MissingImages = 2;
        Says(
            "已导入：新增 1 条，更新 1 条", "1 条和现在的一样 · 跳过 1 个太大（超过 4 MB） · 2 张图片没导进来", false,
            Md.ImportMessage(4, read, 1, 1));
        // 超过 2000 个：只说「只导了前 2000 个」，不再算进跳过
        read.Add(Md.Skip.OverLimit, 7);
        read.LimitHit = true;
        Assert.AreEqual(
            "1 条和现在的一样 · 跳过 1 个太大（超过 4 MB） · 2 张图片没导进来 · 只导了前 2000 个",
            Md.ImportMessage(2007, read, 1, 1).Detail);
        Assert.AreEqual("超过一条便签 1 MB 的上限", Md.SkipText(Md.Skip.TooLong));
    }

    /// <summary>别处的图：存得进去的换成令牌（宽度照写），跑出文件夹的、不在的原样留着、算没导进来；一行里从后往前问 store。</summary>
    [TestMethod]
    public async Task ImportStoresForeignImagesAndKeepsBadOnes()
    {
        var stored = Guid.NewGuid();
        var calls = new List<string>();
        Task<string?> Store(Md.MarkdownImage image)
        {
            calls.Add(image.Path);
            return Task.FromResult<string?>(
                image.Path == "图.png" ? NoteImages.Token(new NoteImages.Image(stored, "png", image.Width)) : null);
        }

        var (body, failures) = await Md.ConvertImagesAsync("![图](../../outside.png) ![坏](missing.png) ![好|80](图.png)", Store);
        Assert.AreEqual(2, failures);
        CollectionAssert.AreEqual(new[] { "图.png", "missing.png", "../../outside.png" }, calls);
        Assert.AreEqual(
            "![图](../../outside.png) ![坏](missing.png) " + NoteImages.Token(new NoteImages.Image(stored, "png", 80)), body);
        Assert.AreEqual(3, Md.MarkdownImagesIn(body).Count);
        Assert.IsTrue(body.Contains("![image|80](kitty-note-image://", StringComparison.Ordinal));
    }
}
