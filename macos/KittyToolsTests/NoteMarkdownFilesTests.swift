// 便签第 8 批 Markdown 导出 / 导入的单测（Notes/NoteMarkdownFiles.swift）：
// - 文件名（清理、截断、重名）、文件头（有 / 没有标题、引号换行、坏的数值）、三种换法（任务、颜色、图片）、路径判断；
// - 临时目录里真的导出、再导回来（编号、时间、颜色、归档、固定、顺序、图片、第二遍不重复）；
// - 别处的文件（有 / 没有 # 标题、别人的 YAML 头、BOM、CRLF、非 UTF-8、超大）、图片（已有的编号不复制、别处的存成新编号、
//   ../ 跑出去、符号链接、网址、文件不在）。
// - 第四轮体检 E18：在别处改过的自家文件（文件时间比文件头晚 2 秒以上）按文件时间算改于、导回来换上并把旧的放进最近删除；
//   导出的文件时间就是便签的改于（没动过的导回来不变）；跳过的原因分开数；岛上那句话怎么说。
// 窗口、系统剪贴板、用户的文件夹都不碰：全是测试自己建的临时目录。

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct NoteMarkdownFilesTests {
  private let manager = FileManager.default
  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-md-tests-\(UUID().uuidString)")

  init() throws {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func note(
    id: String = UUID().uuidString, title: String = "", body: String,
    created: Date = Date(timeIntervalSince1970: 1_760_000_000.123),
    modified: Date = Date(timeIntervalSince1970: 1_760_000_100.456),
    color: Int = 3, revision: Int = 12, archived: Bool = false, pinned: Bool = true,
    order: Double = 3.5
  ) -> Note {
    Note(
      id: id, title: title, body: body, color: color, createdAt: Note.stamp(created),
      modifiedAt: Note.stamp(modified), revision: revision, isArchived: archived,
      isPinned: pinned, order: order)
  }

  // MARK: 文件名

  @Test func fileNamesAreCleanedAndDeduplicated() {
    #expect(NoteMarkdownFiles.fileName(for: note(body: "")) == "未命名便签")
    #expect(
      NoteMarkdownFiles.fileName(for: note(body: "  ../报告: 一/二\\三\u{7}  "))
        == "-报告- 一-二-三")
    let longTitle = NoteMarkdownFiles.fileName(
      for: note(title: String(repeating: "长", count: 100), body: ""))
    #expect(longTitle.count <= 80 && longTitle.utf8.count <= 200)
    #expect(NoteMarkdownFiles.fileName(for: note(body: "🙂🙂🙂")).hasPrefix("🙂"))
    // 重名（不分大小写、Unicode 规范化后比）加 2、3
    let notes = [
      note(title: "Report", body: "Report"), note(title: "report", body: "report"),
      note(body: "REPORT"), note(body: "Report"),
    ]
    #expect(
      NoteMarkdownFiles.fileNames(for: notes)
        == ["Report", "report 2", "REPORT 3", "Report 4"])
    // 截断之后加序号也不超过 80 个字
    let long = String(repeating: "字", count: 100)
    let names = NoteMarkdownFiles.fileNames(for: [
      note(title: long, body: ""), note(title: long, body: ""),
    ])
    #expect(names[0].count <= 80 && names[1].count <= 80 && names[0] != names[1])
  }

  // MARK: 文件头

  @Test func headerRoundTrips() throws {
    let original = note(
      id: "2F1C6E5A-1111-2222-3333-444455556666", title: "他说「走吧」\n换行 \\ 反斜杠",
      body: "正文", color: 7, revision: 42, archived: true, pinned: false, order: 3.5)
    let text = NoteMarkdownFiles.header(for: original) + "\n\n" + original.body
    let header = try #require(NoteMarkdownFiles.parseHeader(text))
    #expect(header.id == original.id)
    #expect(header.title == original.title)
    #expect(
      Note.milliseconds(header.created ?? .distantPast) == Note.milliseconds(original.createdAt))
    #expect(
      Note.milliseconds(header.modified ?? .distantPast) == Note.milliseconds(original.modifiedAt))
    #expect(
      header.color == 7 && header.revision == 42 && header.archived && !header.pinned
        && header.order == 3.5 && header.text == "正文")
    // 没有自己起的标题就不写那一行
    #expect(!NoteMarkdownFiles.header(for: note(body: "正文")).contains("title:"))
    // 坏的数值：颜色夹到 0–7、未知键忽略、时间认不出用 fallback、revision / order / 布尔按规矩
    let broken = """
      ---
      kitty-note: 2F1C6E5A-1111-2222-3333-444455556666
      title: not json
      color: 99
      created: 昨天
      modified: 2026-10-12T09:30:05.123+08:00
      revision: -4
      archived: yes
      pinned: true
      order: 1e999
      other: 值
      ---
      正文
      """
    let fallback = Date(timeIntervalSince1970: 1_700_000_000)
    let parsed = try #require(NoteMarkdownFiles.parseHeader(broken, modifiedFallback: fallback))
    #expect(parsed.title == "" && parsed.color == 7 && parsed.created == nil)
    #expect(parsed.revision == 0 && !parsed.archived && parsed.pinned && parsed.order == 0)
    #expect(parsed.text == "正文")
    // 收尾的 --- 后面没有正文
    #expect(NoteMarkdownFiles.parseHeader("---\nkitty-note: \(UUID().uuidString)\n---")?.text == "")
    // 没有合法编号的不是自家的
    #expect(NoteMarkdownFiles.parseHeader("---\ntitle: x\n---\n正文") == nil)
    #expect(NoteMarkdownFiles.parseHeader("没有头") == nil)
  }

  // MARK: 三种换法

  @Test func markdownBodyConvertsTasksColorsAndImages() {
    let id = UUID()
    let body = "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n[红]{red} **粗**\n```\n☑ 块里 [不换]{red}\n```"
    let markdown = NoteMarkdownFiles.markdownBody(body)
    #expect(markdown.contains("- [ ] 一\n- [/] 二\n- [!] 三\n- [x] 四\n- [-] 五"))
    #expect(markdown.contains("<span style=\"color: #A11A14\">红</span> **粗**"))
    let withImage = "前\n![image|120](kitty-note-image://\(id.uuidString).png)"
    #expect(
      NoteMarkdownFiles.markdownBody(withImage)
        == "前\n![image|120](attachments/\(id.uuidString).png)")
    #expect(markdown.contains("```\n☑ 块里 [不换]{red}\n```"))
    let back = NoteMarkdownFiles.bodyFromMarkdown(markdown).body
    #expect(back == body)
  }

  /// 一行里有好几张图（真机 0.5.0 测试包崩过：导出全部时第二张的位置按换之前的算，`kitty-note-image://` 换成
  /// `attachments/` 短了 7 个字，第二张越界抛 NSRangeException、后台线程上直接闪退；后面还有字时不崩、但写坏文件）
  @Test func severalImagesOnOneLine() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    func token(_ id: UUID, _ width: String = "") -> String {
      "![image\(width)](kitty-note-image://\(id.uuidString).png)"
    }
    func exported(_ id: UUID, _ width: String = "") -> String {
      "![image\(width)](attachments/\(id.uuidString).png)"
    }
    // 两张挨着、在行尾（崩的那种）；三张中间夹字、后面还有字（写坏的那种）；同一张引用两次
    let body =
      "\(token(a))\(token(b, "|120"))\n前 \(token(a)) 中 \(token(c)) 后 \(token(b)) 尾\n\(token(c))\(token(c))"
    let (text, images) = NoteMarkdownFiles.markdownImages(body)
    #expect(
      text
        == "\(exported(a))\(exported(b, "|120"))\n前 \(exported(a)) 中 \(exported(c)) 后 \(exported(b)) 尾\n\(exported(c))\(exported(c))"
    )
    #expect(Set(images.map(\.id)) == [a, b, c])
  }

  @Test func markdownImagesParseWidthAndPaths() {
    let line = "前 ![说明|240](attachments/a.png) 中 ![图](b%20c.jpg) 后"
    let images = NoteMarkdownFiles.markdownImages(in: line)
    #expect(images.count == 2)
    #expect(images[0].width == 240 && images[0].path == "attachments/a.png")
    #expect(images[1].width == nil && images[1].path == "b%20c.jpg")
    #expect(NoteMarkdownFiles.markdownImages(in: "`![图](x.png)`").isEmpty)
  }

  @Test func imagePathsStayInsideTheChosenFolder() throws {
    let folder = root.appending(path: "inside", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appending(path: "a.png"))
    #expect(NoteMarkdownFiles.imageURL(path: "a.png", in: folder) != nil)
    #expect(NoteMarkdownFiles.imageURL(path: "sub/../a.png", in: folder) != nil)
    #expect(NoteMarkdownFiles.imageURL(path: "../a.png", in: folder) == nil)
    #expect(NoteMarkdownFiles.imageURL(path: "/etc/passwd", in: folder) == nil)
    #expect(NoteMarkdownFiles.imageURL(path: "https://a.b/x.png", in: folder) == nil)
    // 符号链接指到外面
    let link = folder.appending(path: "link.png")
    try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(NoteMarkdownFiles.imageURL(path: "link.png", in: folder) == nil)
  }

  // MARK: 导出 / 导入

  @Test func exportThenImportRoundTrips() async throws {
    let imageID = UUID()
    let imageDirectory = root.appending(path: "notes-images", directoryHint: .isDirectory)
    try manager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let imageBytes = NoteImageFixture.data(type: .png, width: 80, height: 60)
    try imageBytes.write(to: imageDirectory.appending(path: "\(imageID.uuidString).png"))
    let original = note(
      id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", title: "标题 / 测试",
      body:
        "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n[红]{red} **粗**\n![image|120](kitty-note-image://\(imageID.uuidString).png)",
      color: 5, revision: 7, archived: true, pinned: true, order: 1.25)
    let parent = root.appending(path: "导出", directoryHint: .isDirectory)
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let result = await NoteMarkdownFiles.export(
      notes: [original], imageDirectory: imageDirectory, to: parent,
      now: Date(timeIntervalSince1970: 1_760_000_000))
    #expect(result.failure == nil && result.count == 1 && result.missingImages == 0)
    let folder = try #require(result.folder)
    #expect(folder.lastPathComponent.hasPrefix("Kitty Tools 便签 "))
    let file = folder.appending(path: "标题 - 测试.md")
    #expect(manager.fileExists(atPath: file.path))
    #expect(
      manager.fileExists(
        atPath: folder.appending(path: "attachments/\(imageID.uuidString).png").path))
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("kitty-note: \(original.id)") && text.contains("color: 5"))
    #expect(text.contains("- [!] 三") && text.contains("<span style=\"color: #A11A14\">红</span>"))
    // 导回来（同一个文件夹）：内容一样、第二遍什么都不变
    let sources = [NoteMarkdownFiles.Source(url: file, root: folder)]
    let imported = await NoteMarkdownFiles.importNotes(
      sources: sources, imageDirectory: imageDirectory)
    #expect(imported.skipped == 0 && imported.missingImages == 0 && imported.notes.count == 1)
    let back = try #require(imported.notes.first)
    #expect(back.id == original.id && back.title == original.title && back.body == original.body)
    #expect(back.color == original.color && back.isArchived && back.isPinned && back.order == 1.25)
    #expect(Note.milliseconds(back.createdAt) == Note.milliseconds(original.createdAt))
    #expect(Note.milliseconds(back.modifiedAt) == Note.milliseconds(original.modifiedAt))
    // 合并进仓库：第一遍加进去，第二遍不动
    let store = try NoteStore(db: Database(path: ":memory:"))
    let entry = SettingsArchive.NoteEntry(
      id: back.id, title: back.title, body: back.body, color: back.color,
      createdAt: Note.milliseconds(back.createdAt), modifiedAt: Note.milliseconds(back.modifiedAt),
      revision: back.revision, archived: back.isArchived, pinned: back.isPinned, order: back.order)
    #expect(store.adopt([entry]).added == 1)
    #expect(store.adopt([entry]).added == 0 && store.note(back.id)?.body == original.body)
  }

  /// 代码块里的图（未来计划 D）：导出时也换成 attachments/ 的写法、带上图片文件，导回来换回同一个令牌。
  /// 代码块里只认导出时写出去的那种路径：别的图片语法是代码，原样留着、不读文件、不算没导进来
  @Test func imagesInCodeBlocksTravelToo() async throws {
    let imageID = UUID()
    let imageDirectory = root.appending(path: "code-images", directoryHint: .isDirectory)
    try manager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    try NoteImageFixture.data(type: .png, width: 40, height: 30)
      .write(to: imageDirectory.appending(path: "\(imageID.uuidString).png"))
    let body =
      "前\n```\n![image|90](kitty-note-image://\(imageID.uuidString).png)\n☑ 块里\n```\n后"
    let (text, images) = NoteMarkdownFiles.markdownImages(body)
    #expect(text == "前\n```\n![image|90](attachments/\(imageID.uuidString).png)\n☑ 块里\n```\n后")
    #expect(images.map(\.id) == [imageID])
    let parent = root.appending(path: "代码块导出", directoryHint: .isDirectory)
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let result = await NoteMarkdownFiles.export(
      notes: [note(title: "代码", body: body)], imageDirectory: imageDirectory, to: parent)
    #expect(result.failure == nil && result.count == 1 && result.missingImages == 0)
    let folder = try #require(result.folder)
    #expect(
      manager.fileExists(
        atPath: folder.appending(path: "attachments/\(imageID.uuidString).png").path))
    let file = folder.appending(path: "代码.md")
    let imported = await NoteMarkdownFiles.importNotes(
      sources: [NoteMarkdownFiles.Source(url: file, root: folder)], imageDirectory: imageDirectory)
    #expect(imported.missingImages == 0 && imported.notes.first?.body == body)
    // 别处的 .md：代码块里别的图片语法原样留着
    let foreign = folder.appending(path: "别处.md")
    let code = "```\n![图](a.png) ![x](attachments/b.png)\n```"
    try code.write(to: foreign, atomically: true, encoding: .utf8)
    let other = await NoteMarkdownFiles.importNotes(
      sources: [NoteMarkdownFiles.Source(url: foreign, root: folder)],
      imageDirectory: imageDirectory)
    #expect(other.missingImages == 0 && other.notes.first?.body == code)
    #expect(NoteMarkdownFiles.isExported("attachments/\(imageID.uuidString).png"))
    #expect(!NoteMarkdownFiles.isExported("attachments/b.png"))
    #expect(!NoteMarkdownFiles.isExported("x/\(imageID.uuidString).png"))
  }

  @Test func foreignFilesBecomeNewNotes() async throws {
    let folder = root.appending(path: "foreign", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let heading = folder.appending(path: "有标题.md")
    try "# 标题\n正文 **粗**".write(to: heading, atomically: true, encoding: .utf8)
    let plain = folder.appending(path: "没有标题.markdown")
    try "第一行\n第二行".write(to: plain, atomically: true, encoding: .utf8)
    let yaml = folder.appending(path: "别人的头.md")
    try "---\ntitle: x\n---\n正文".write(to: yaml, atomically: true, encoding: .utf8)
    let sources = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let result = await NoteMarkdownFiles.importNotes(sources: sources, imageDirectory: nil)
    #expect(result.notes.count == 3 && result.skipped == 0)
    let byTitle = Dictionary(uniqueKeysWithValues: result.notes.map { ($0.title, $0) })
    #expect(byTitle[""]?.body == "# 标题\n正文 **粗**")
    #expect(byTitle["没有标题"]?.body == "第一行\n第二行")
    #expect(byTitle["别人的头"]?.body == "---\ntitle: x\n---\n正文")
    #expect(Set(result.notes.map(\.id)).count == 3)
  }

  /// 同步文件夹里的文件（NoteSyncFolder，带 sync-clock）不导：这里读不全它的删除时刻，在最近删除里的会被当没删的导回来
  @Test func importSkipsSyncFiles() async throws {
    let folder = root.appending(path: "sync", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let trashed = Note(
      id: UUID().uuidString, body: "在最近删除里", createdAt: .now, modifiedAt: .now,
      deletedAt: .now, clock: ["A": 1])
    try NoteSyncFolder.text(of: trashed).write(
      to: folder.appending(path: NoteSyncFolder.fileName(of: trashed.id)), atomically: true,
      encoding: .utf8)
    try "普通的".write(to: folder.appending(path: "普通.md"), atomically: true, encoding: .utf8)
    let sources = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let result = await NoteMarkdownFiles.importNotes(sources: sources, imageDirectory: nil)
    #expect(result.notes.map(\.body) == ["普通的"] && result.skipped == 1)
  }

  @Test func importHandlesBOMCRLFAndBadFiles() async throws {
    let folder = root.appending(path: "formats", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var bom = Data([0xEF, 0xBB, 0xBF])
    bom.append(Data("第一行\r\n第二行\r第三行".utf8))
    try bom.write(to: folder.appending(path: "bom.md"))
    try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: folder.appending(path: "bad.md"))
    let sources = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let result = await NoteMarkdownFiles.importNotes(sources: sources, imageDirectory: nil)
    #expect(result.notes.count == 1 && result.skipped == 1)
    #expect(result.notes[0].body == "第一行\n第二行\n第三行")
  }

  // MARK: 在别处改过的自家文件（第四轮体检 E18）

  /// 在别处改过没有：有正文哈希只看它；没有的（0.7.1 之前导出的）文件时间比文件头晚 2 秒以上才算；文件时间读不出来不算
  @Test func editedElsewhereFollowsTheBodyHash() {
    let header = Date(timeIntervalSince1970: 1_760_000_000)
    let edited = NoteMarkdownFiles.editedElsewhere
    let later = header.addingTimeInterval(3600)
    #expect(!edited(header, later, false), "有哈希、对得上：文件时间再新也不算（被碰过）")
    #expect(edited(header, later, true))
    #expect(!edited(header, nil, true))
    #expect(!edited(header, header.addingTimeInterval(2), nil))
    #expect(!edited(header, header.addingTimeInterval(-60), nil))
    #expect(edited(header, header.addingTimeInterval(2.5), nil))
  }

  /// 导出的文件头里有正文的哈希：被碰过（文件时间新了、字没动）导回来什么都不变；在别处改了正文导回来换上（改于是
  /// 文件时间）、旧的进最近删除，固定 / 归档 / 顺序留本机的；没有哈希的旧文件按文件时间认（第四轮体检 E18）
  @Test func externallyEditedFilesComeBack() async throws {
    let parent = root.appending(path: "改过", directoryHint: .isDirectory)
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let store = try NoteStore(db: Database(path: ":memory:"))
    let original = store.create(
      body: "原来的字", now: Date(timeIntervalSince1970: 1_760_000_100.456))
    let result = await NoteMarkdownFiles.export(
      notes: [original], imageDirectory: nil, to: parent,
      now: Date(timeIntervalSince1970: 1_760_000_000))
    let file = try #require(result.folder).appending(path: "原来的字.md")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("\nbody-hash: "))
    func adopt() async throws -> NoteStore.Adoption {
      let imported = await NoteMarkdownFiles.importNotes(
        sources: [.init(url: file, root: file.deletingLastPathComponent())], imageDirectory: nil)
      return store.adopt(
        imported.notes.compactMap(SettingsArchive.NoteEntry.init),
        contentOnly: imported.editedElsewhere)
    }
    var adoption = try await adopt()
    #expect(adoption.added == 0 && adoption.updated == 0)
    // 导出之后本机又改了一下状态（固定）；文件被碰过（原样拷了一遍，时间新了）：不算改过、不盖本机的
    store.setPinned(true, of: original.id)
    let touchedAt = Date.now.addingTimeInterval(-60)
    try manager.setAttributes([.modificationDate: touchedAt], ofItemAtPath: file.path)
    adoption = try await adopt()
    #expect(adoption.updated == 0 && store.note(original.id)?.body == "原来的字")
    // 在别的编辑器里改了正文（文件头没动）
    let edited = try String(contentsOf: file, encoding: .utf8)
      .replacingOccurrences(of: "原来的字", with: "外面改的字")
    try edited.write(to: file, atomically: true, encoding: .utf8)
    let editedAt = Date.now.addingTimeInterval(-30)
    try manager.setAttributes([.modificationDate: editedAt], ofItemAtPath: file.path)
    adoption = try await adopt()
    #expect(adoption.updated == 1)
    let after = try #require(store.note(original.id))
    #expect(after.body == "外面改的字" && after.isPinned, "只取内容：固定留本机的")
    #expect(abs(after.modifiedAt.timeIntervalSince(editedAt)) < 0.01)
    #expect(store.trashed.map(\.body) == ["原来的字"], "被换下来的那版进最近删除")
    // 再导一遍：不变
    adoption = try await adopt()
    #expect(adoption.updated == 0 && store.trashed.count == 1)
    // 没有哈希的旧文件：文件时间比文件头晚就算改过
    let legacy = try String(contentsOf: file, encoding: .utf8)
      .components(separatedBy: "\n").filter { !$0.hasPrefix("body-hash:") }
      .joined(separator: "\n").replacingOccurrences(of: "外面改的字", with: "旧文件里改的")
    try legacy.write(to: file, atomically: true, encoding: .utf8)
    try manager.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-10)], ofItemAtPath: file.path)
    adoption = try await adopt()
    #expect(adoption.updated == 1 && store.note(original.id)?.body == "旧文件里改的")
  }

  /// 跳过的原因分开数（太大、不是 UTF-8）；岛上那句话：新增 / 更新 / 没有变化 / 全被跳过时写原因 / 没有 .md
  @Test func skipReasonsAndIslandMessage() async throws {
    let folder = root.appending(path: "跳过", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: NoteMarkdownFiles.maxFileBytes + 1).write(to: folder.appending(path: "大.md"))
    try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: folder.appending(path: "坏.md"))
    let sources = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let skipped = await NoteMarkdownFiles.importNotes(sources: sources, imageDirectory: nil)
    #expect(skipped.notes.isEmpty && skipped.skipped == 2)
    #expect(skipped.reasons == [.tooLarge: 1, .notText: 1])
    let message = NoteMarkdownFiles.importMessage
    let allSkipped = message(2, skipped, 0, 0)
    #expect(allSkipped.title == "没有导入" && allSkipped.warning)
    #expect(allSkipped.detail == "全部跳过了：1 个太大（超过 4 MB）、1 个不是 UTF-8 文本")
    #expect(message(0, .init(), 0, 0) == ("没有导入", "选的地方没有 .md 文件", true))
    var read = NoteMarkdownFiles.ImportResult()
    read.notes = [note(body: "一"), note(body: "二"), note(body: "三")]
    #expect(message(3, read, 0, 0) == ("没有变化", "3 条和现在的一样", false))
    #expect(message(3, read, 3, 0).title == "已导入 3 条新便签")
    #expect(message(3, read, 0, 1) == ("已更新 1 条便签", "2 条和现在的一样", false))
    read.skip(.tooLarge)
    read.missingImages = 2
    #expect(
      message(4, read, 1, 1)
        == (
          "已导入：新增 1 条，更新 1 条", "1 条和现在的一样 · 跳过 1 个太大（超过 4 MB） · 2 张图片没导进来",
          false
        ))
    // 超过 2000 个：只说「只导了前 2000 个」，不再算进跳过
    read.skip(.overLimit, count: 7)
    read.limitHit = true
    #expect(
      message(2007, read, 1, 1).detail
        == "1 条和现在的一样 · 跳过 1 个太大（超过 4 MB） · 2 张图片没导进来 · 只导了前 2000 个")
  }

  @Test func importStoresForeignImagesAndKeepsBadOnes() async throws {
    let folder = root.appending(path: "images", directoryHint: .isDirectory)
    let imageDirectory = root.appending(path: "images-store", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try manager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let source = folder.appending(path: "图.png")
    try NoteImageFixture.data(type: .png, width: 60, height: 40).write(to: source)
    let md = folder.appending(path: "带图.md")
    try "![图](../../outside.png) ![坏](missing.png) ![好|80](图.png)".write(
      to: md, atomically: true, encoding: .utf8)
    let result = await NoteMarkdownFiles.importNotes(
      sources: [NoteMarkdownFiles.Source(url: md, root: folder)],
      imageDirectory: imageDirectory)
    #expect(result.notes.count == 1 && result.missingImages == 2)
    let body = result.notes[0].body
    #expect(body.contains("![图](../../outside.png)") && body.contains("![坏](missing.png)"))
    #expect(body.contains("![image|80](kitty-note-image://"))
    #expect(NoteMarkdownFiles.markdownImages(in: body).count == 3)
    // 自有编号 + 一样的字节：导回来不复制、不重复
    let image = try #require(NoteImages.first(in: body))
    let existing = imageDirectory.appending(path: "\(image.id.uuidString).\(image.ext)")
    #expect(manager.fileExists(atPath: existing.path))
    let again = folder.appending(path: "再导.md")
    try "![image|80](\(image.id.uuidString).\(image.ext))"
      .write(to: again, atomically: true, encoding: .utf8)
    // 路径相对 md 所在的文件夹：先把文件拷到它旁边
    let copy = folder.appending(path: "\(image.id.uuidString).\(image.ext)")
    try manager.copyItem(at: existing, to: copy)
    let second = await NoteMarkdownFiles.importNotes(
      sources: [NoteMarkdownFiles.Source(url: again, root: folder)],
      imageDirectory: imageDirectory)
    #expect(second.notes.first?.body.contains("kitty-note-image://\(image.id.uuidString).") == true)
  }
}
