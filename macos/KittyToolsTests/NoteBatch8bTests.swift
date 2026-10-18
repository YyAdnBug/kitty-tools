// 便签第 8 批之后的一轮（单条导出、格式菜单、格式合并）的纯函数单测：
// 粗体 / 斜体 / 删除线整段一种（R1）、颜色合并（R2）、复验挡住认不出的（R3）、块格式 / 链接 / 清除格式 / 代码块（R6）、
// 菜单打勾和停用要问的几个纯函数（R4）、单条导出和整个文件夹导出同一份全文（R8–R12）。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct NoteBatch8bTests {
  private struct Edit: Equatable {
    var text: String
    var selection: NSRange

    init(_ text: String, selection: NSRange) {
      self.text = text
      self.selection = selection
    }
  }

  private func applied(_ change: NoteTasks.Change?, to text: String) -> Edit? {
    guard let change else { return nil }
    let result = NSMutableString(string: text)
    for replacement in change.replacements.reversed() {
      result.replaceCharacters(in: replacement.range, with: replacement.text)
    }
    return Edit(result as String, selection: change.selection)
  }

  private func toggle(
    _ wrap: NoteMarkdown.Wrap, _ text: String, _ selection: NSRange
  ) -> Edit? {
    applied(NoteMarkdown.toggle(wrap, in: text, selection: selection), to: text)
  }

  private func colored(
    _ color: NoteColor?, _ text: String, _ selection: NSRange
  ) -> Edit? {
    applied(NoteMarkdown.color(color, in: text, selection: selection), to: text)
  }

  private func blocked(_ format: NoteMarkdown.BlockFormat, _ text: String, _ selection: NSRange)
    -> String?
  {
    applied(NoteMarkdown.block(format, in: text, selection: selection), to: text)?.text
  }

  private func cleared(_ text: String, _ selection: NSRange) -> Edit? {
    applied(NoteMarkdown.clear(in: text, selection: selection), to: text)
  }

  // MARK: R1 粗体 / 斜体 / 删除线整段一种

  @Test func emphasisMergesIntoWholeRuns() {
    // ab**cd**ef 全选按 ⌘B：原来那一段并进来，中间的标记不留（斜体、删除线同理）
    #expect(
      toggle(.bold, "ab**cd**ef", NSRange(location: 0, length: 10))
        == Edit("**abcdef**", selection: NSRange(location: 2, length: 6)))
    #expect(
      toggle(.italic, "ab*cd*ef", NSRange(location: 0, length: 8))
        == Edit("*abcdef*", selection: NSRange(location: 1, length: 6)))
    #expect(
      toggle(.strike, "12~~312~~3", NSRange(location: 0, length: 10))
        == Edit("~~123123~~", selection: NSRange(location: 2, length: 6)))
    // 数字中间的 ** / * 是乘号、不是标记（扫描器本来就当字显示）：全选加格式时**原样留着**、跟着一起变粗 / 斜，
    // 不当成标记删掉（复查抓到的：原来会把 60*40*30 改成 604030）
    #expect(
      toggle(.bold, "12**312**3", NSRange(location: 0, length: 10))
        == Edit("**12**312**3**", selection: NSRange(location: 2, length: 10)))
    #expect(
      toggle(.italic, "12*312*3", NSRange(location: 0, length: 8))
        == Edit("*12*312*3*", selection: NSRange(location: 1, length: 8)))
    // 用户打的、没配上的 * ** ~~（乘号、路径里的通配、单独的 ~~）：一个字都不许少
    for (wrap, line, expected) in [
      (NoteMarkdown.Wrap.italic, "60*40*30 立方", "*60*40*30 立方*"),
      (.bold, "2**3 等于 8", "**2**3 等于 8**"),
      (.bold, "src/**/a.swift 和 docs", "**src/**/a.swift 和 docs**"),
      (.strike, "价格 ~~ 不定", "~~价格 ~~ 不定~~"),
    ] {
      let all = NSRange(location: 0, length: (line as NSString).length)
      let result = toggle(wrap, line, all)
      #expect(result == nil || result?.text == expected, "\(line) → \(result?.text ?? "nil")")
      // 认不出来时响一声、不改也可以；改了的话用户打的字一个都不能少
      if let text = result?.text {
        #expect(text.filter { $0 != "*" && $0 != "~" } == line.filter { $0 != "*" && $0 != "~" })
        #expect(text.count == line.count + 2 * wrap.markerLength, "\(line) → \(text)")
      }
    }
    // **ab**cd 里选中 bc（连中间的两颗星）：跨在选区边上的 a 并进来，选区外的 d 不动
    #expect(
      toggle(.bold, "**ab**cd", NSRange(location: 3, length: 4))
        == Edit("**abc**d", selection: NSRange(location: 3, length: 2)))
    // **abc** 里只选 b：拆成 a、b、c 三段
    #expect(
      toggle(.bold, "**abc**", NSRange(location: 3, length: 1))
        == Edit("**a**b**c**", selection: NSRange(location: 5, length: 1)))
    // 斜体、删除线也一样
    #expect(
      toggle(.italic, "*ab*cd", NSRange(location: 2, length: 3))
        == Edit("*abc*d", selection: NSRange(location: 2, length: 2)))
    #expect(
      toggle(.strike, "~~ab~~cd", NSRange(location: 3, length: 4))
        == Edit("~~abc~~d", selection: NSRange(location: 3, length: 2)))
    // 都已经是：去掉，选区还是那些字
    #expect(
      toggle(.bold, "看**周报**了", NSRange(location: 1, length: 6))
        == Edit("看周报了", selection: NSRange(location: 1, length: 2)))
    // 没有可加的字：nil（不数字符）
    #expect(toggle(.bold, "   ", NSRange(location: 0, length: 3)) == nil)
    #expect(toggle(.bold, "`代码`", NSRange(location: 1, length: 2)) == nil)
  }

  @Test func emphasisMergesLineByLine() {
    // 第一行已经是、第二行不是：都包上，第一行并成一段、不留原来的标记
    #expect(
      toggle(.bold, "**一**行\n第二行", NSRange(location: 0, length: 10))
        == Edit("**一行**\n**第二行**", selection: NSRange(location: 2, length: 10)))
    // 两行都是：都去掉；空行和只有空白的行跳过
    #expect(
      toggle(.bold, "**一行**\n\n  \n**二行**", NSRange(location: 0, length: 17))
        == Edit("一行\n\n  \n二行", selection: NSRange(location: 0, length: 9)))
    // 别的标记断开一串：粗体不能跨过斜体标记
    #expect(
      toggle(.bold, "**a***b*", NSRange(location: 0, length: 8))
        == Edit("**a*****b***", selection: NSRange(location: 2, length: 7)))
  }

  @Test func emphasisKeepsCodeAndImagesAlone() {
    // 行内代码里的字不能加格式：选中的只有代码里的字 → nil
    #expect(toggle(.italic, "a `b` c", NSRange(location: 3, length: 1)) == nil)
    // 选区跨过行内代码：两边的字各自包，代码不包
    #expect(
      toggle(.bold, "a `b` c", NSRange(location: 0, length: 7))
        == Edit("**a** `b` **c**", selection: NSRange(location: 2, length: 11)))
    // 数字旁边重建出来的星号扫描器不认（复验挡住）
    #expect(toggle(.italic, "2*3*4", NSRange(location: 2, length: 1)) == nil)
  }

  // MARK: R2 颜色合并

  @Test func colorsConsolidateFragments() {
    func full(_ text: String) -> NSRange {
      NSRange(location: 0, length: (text as NSString).length)
    }
    // 碎成三段、颜色没变：全选再选红，合成一段（不再响一声）
    let fragmented = "[12]{red}[31232312]{red}[3]{red}"
    #expect(colored(.red, fragmented, full(fragmented))?.text == "[12312323123]{red}")
    // R2 的例子：旧的颜色标记不算断开
    let split = "[12]{red}3123[2312]{red}3"
    #expect(colored(.red, split, full(split))?.text == "[12312323123]{red}")
    // 只选碎标记围着的字：外面的不动
    let white = "白[12]{red}[3]{red}纸"
    let span = NSRange(
      location: 1, length: NSMaxRange((white as NSString).range(of: "[3]{red}")) - 1)
    #expect(colored(.red, white, span)?.text == "白[123]{red}纸")
    // 一行里两种颜色一起改：合成一段新的颜色
    let mixed = "[红]{red}[蓝]{blue}"
    #expect(colored(.green, mixed, full(mixed))?.text == "[红蓝]{green}")
    // 颜色标记透明：一串能跨过旧的颜色标记
    let pieces = "[a]{red}b[cd]{blue}e"
    #expect(colored(.red, pieces, full(pieces))?.text == "[abcde]{red}")
  }

  /// R3 的复杂度锁：两万字一行，全选 ⌘B、全选上色都在 0.5 s 以内（Debug）
  @Test func hugeLineStaysFast() {
    let text = String(repeating: "字", count: 20_000)
    let selection = NSRange(location: 0, length: (text as NSString).length)
    let started = Date.now
    #expect(NoteMarkdown.toggle(.bold, in: text, selection: selection) != nil)
    let bold = Date.now.timeIntervalSince(started)
    let coloredStarted = Date.now
    #expect(NoteMarkdown.color(.red, in: text, selection: selection) != nil)
    let colored = Date.now.timeIntervalSince(coloredStarted)
    print("notes-batch8b 两万字一行：⌘B \(bold) s，上色 \(colored) s")
    #expect(bold < 0.5 && colored < 0.5)
  }

  // MARK: R3 重建（复验挡住认不出的）

  @Test func rebuildGivesUpWhenItCannotBeScannedBack() {
    // 拼出来扫描器认不出是粗体（两头紧挨着数字）：复验挡住，整次不改
    #expect(toggle(.bold, "12345", NSRange(location: 1, length: 3)) == nil)
    // 正常的一段照样能拼出来
    #expect(
      toggle(.bold, "a2b3c", NSRange(location: 1, length: 3))
        == Edit("a**2b3**c", selection: NSRange(location: 3, length: 3)))
    #expect(toggle(.bold, "a b c", NSRange(location: 2, length: 1))?.text == "a **b** c")
  }

  // MARK: R6 块格式

  @Test func headingsQuoteAndLists() {
    #expect(blocked(.heading(1), "标题", NSRange(location: 0, length: 2)) == "# 标题")
    #expect(blocked(.heading(2), "# 标题", NSRange(location: 0, length: 1)) == "## 标题")
    #expect(blocked(.heading(1), "## 标题", NSRange(location: 0, length: 1)) == "# 标题")
    // 缩进留着，标记加在缩进后面
    #expect(blocked(.heading(1), "  标题", NSRange(location: 0, length: 2)) == "  # 标题")
    // 引用：别的标记留着，不是引用的行加 >，都是引用才去掉
    #expect(blocked(.quote, "# 标题", NSRange(location: 0, length: 1)) == "> # 标题")
    #expect(blocked(.quote, "> 引用\n普通", NSRange(location: 0, length: 8)) == "> 引用\n> 普通")
    // 列表：把原来的块标记换成列表符号
    #expect(blocked(.bullet, "> 引用", NSRange(location: 0, length: 1)) == "- 引用")
    // 一层层套着的块标记：转换时整串换掉
    #expect(blocked(.heading(1), "> 标题", NSRange(location: 0, length: 1)) == "# 标题")
    #expect(blocked(.heading(1), "> # 标题", NSRange(location: 0, length: 1)) == "# 标题")
    #expect(blocked(.bullet, "> - 项", NSRange(location: 0, length: 1)) == "- 项")
    #expect(blocked(.heading(1), "- ☐ 任务", NSRange(location: 0, length: 1)) == "# 任务")
    // 去掉时只去自己那种标记，别的留着
    #expect(blocked(.bullet, "- # 标题", NSRange(location: 0, length: 1)) == "# 标题")
    #expect(blocked(.quote, "> - 项", NSRange(location: 0, length: 1)) == "- 项")
    #expect(blocked(.bullet, "- 牛奶", NSRange(location: 0, length: 1)) == "牛奶")
    // 有序列表：同一缩进一组、每组从 1 开始
    #expect(
      blocked(.ordered, "a\n  b\nc", NSRange(location: 0, length: 7))
        == "1. a\n  1. b\n2. c")
    #expect(blocked(.ordered, "1. a\n2. b", NSRange(location: 0, length: 7)) == "a\nb")
    // 空行：选了好几行时空行不动，只有一行时空行也变
    #expect(blocked(.bullet, "a\n\nb", NSRange(location: 0, length: 4)) == "- a\n\n- b")
    #expect(blocked(.bullet, "  ", NSRange(location: 0, length: 1)) == "  - ")
  }

  // MARK: R6 代码块

  @Test func codeBlockSpots() {
    let text = "前\n```\n代码\n```\n后" as NSString
    #expect(NoteMarkdown.codeSpot(in: text, selection: NSRange(location: 8, length: 0)) == .inside)
    #expect(NoteMarkdown.codeSpot(in: text, selection: NSRange(location: 0, length: 1)) == .outside)
    #expect(
      NoteMarkdown.codeSpot(in: text, selection: NSRange(location: 0, length: 10)) == .straddles)
  }

  @Test func codeBlockToggles() {
    func block(_ text: String, _ selection: NSRange) -> String? {
      applied(NoteMarkdown.codeBlock(in: text as NSString, selection: selection), to: text)?.text
    }
    // 光标在空行上：插三行、光标在中间
    #expect(block("a\n\nb", NSRange(location: 2, length: 0)) == "a\n```\n\n```\nb")
    // 选了字：给碰到的行上下加围栏
    #expect(block("a\nb", NSRange(location: 0, length: 3)) == "```\na\nb\n```")
    // 块里：连围栏一起去掉
    #expect(block("```\na\n```\n", NSRange(location: 4, length: 1)) == "a\n")
    // 一半在块里一半在外：nil（界面停用 / 响一声）
    #expect(block("前\n```\na\n```\n后", NSRange(location: 0, length: 10)) == nil)
  }

  // MARK: R6 链接、清除格式

  @Test func links() {
    func link(_ text: String, _ selection: NSRange) -> Edit? {
      applied(NoteMarkdown.link(in: text, selection: selection), to: text)
    }
    #expect(
      link("看这里", NSRange(location: 1, length: 0))
        == Edit("看[]()这里", selection: NSRange(location: 2, length: 0)))
    #expect(
      link("看这里", NSRange(location: 1, length: 2))
        == Edit("看[这里]()", selection: NSRange(location: 6, length: 0)))
    #expect(link("两\n行", NSRange(location: 0, length: 3)) == nil)
  }

  @Test func clearingFormat() {
    #expect(
      cleared("**粗**体", NSRange(location: 0, length: 6))
        == Edit("粗体", selection: NSRange(location: 0, length: 2)))
    // 只选中间：外面照旧、会拆开
    #expect(cleared("**abc**", NSRange(location: 3, length: 1))?.text == "**a**b**c**")
    // 行内代码、链接整段去掉标记；块格式不动
    #expect(
      cleared("看 `代码` 和 [链接](https://e.com) 了", NSRange(location: 2, length: 16))?.text
        == "看 代码 和 链接 了")
    #expect(cleared("# **标题**", NSRange(location: 0, length: 10))?.text == "# 标题")
    #expect(cleared("[红]{red}色", NSRange(location: 0, length: 9))?.text == "红色")
    #expect(cleared("没有格式", NSRange(location: 0, length: 4)) == nil)
  }

  // MARK: R4 菜单打勾要问的

  @Test func formattingChecks() {
    #expect(
      NoteMarkdown.isFormatted(.bold, in: "**粗** 普通", selection: NSRange(location: 2, length: 1))
        == true)
    #expect(
      NoteMarkdown.isFormatted(.bold, in: "**粗** 普通", selection: NSRange(location: 6, length: 2))
        == false)
    // 混着：不是全部
    #expect(
      NoteMarkdown.isFormatted(.bold, in: "**粗** 普通", selection: NSRange(location: 0, length: 8))
        == false)
    #expect(
      NoteMarkdown.isFormatted(.bold, in: "`代码`", selection: NSRange(location: 1, length: 2)) == nil
    )
    #expect(
      NoteMarkdown.isFormatted(.bold, in: "**粗**", selection: NSRange(location: 0, length: 0))
        == nil)
    #expect(
      NoteMarkdown.blockIsOn(.bullet, in: "- a\n- b", selection: NSRange(location: 0, length: 7))
        == true)
    #expect(
      NoteMarkdown.blockIsOn(.bullet, in: "- a\nb", selection: NSRange(location: 0, length: 5))
        == false)
    #expect(
      NoteMarkdown.blockIsOn(.heading(1), in: "\n\n", selection: NSRange(location: 0, length: 2))
        == nil)
  }

  // MARK: R9–R12 单条导出

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kitty-notes-batch8b-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func singleExportMatchesWholeFolderExport() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let id = UUID()
    let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    try data.write(to: images.appending(path: "\(id.uuidString).png"))
    let note = Note(
      id: UUID().uuidString,
      title: "导出我",
      body: "第一行\n" + NoteImages.token(NoteImages.Image(id: id, ext: "png", width: 120)) + "\n最后",
      createdAt: .now, modifiedAt: .now)
    // 单条
    let url = root.appending(path: "单条.md")
    let single = await NoteMarkdownFiles.export(note: note, imageDirectory: images, to: url)
    #expect(single.failure == nil)
    #expect(single.fileName == "单条.md" && single.images == 1 && single.missingImages == 0)
    let written = try String(contentsOf: url, encoding: .utf8)
    // 和整个文件夹导出的一字不差
    let parent = root.appending(path: "all", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let all = await NoteMarkdownFiles.export(notes: [note], imageDirectory: images, to: parent)
    let name = try #require(all.folder).appending(path: "导出我.md")
    #expect(try String(contentsOf: name, encoding: .utf8) == written)
    #expect(written.hasPrefix(NoteMarkdownFiles.header(for: note)))
    #expect(written.contains("attachments/\(id.uuidString).png"))
    // 图片拷到旁边的 attachments，字节一样
    let copied = root.appending(path: "attachments/\(id.uuidString).png")
    #expect(try Data(contentsOf: copied) == data)
    // 再存一次：已有的图片不覆盖
    try Data([9, 9, 9]).write(to: copied)
    let again = await NoteMarkdownFiles.export(note: note, imageDirectory: images, to: url)
    #expect(again.images == 1 && again.missingImages == 0)
    #expect(try Data(contentsOf: copied) == Data([9, 9, 9]))
  }

  /// 同一张图在正文里引用两次：只算一张、只拷一份
  @Test func singleExportCountsAnImageOnce() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let id = UUID()
    let token = NoteImages.token(NoteImages.Image(id: id, ext: "png", width: nil))
    try Data([1, 2, 3]).write(to: images.appending(path: "\(id.uuidString).png"))
    let note = Note(
      id: UUID().uuidString, body: token + "\n" + token, createdAt: .now, modifiedAt: .now)
    let url = root.appending(path: "两张.md")
    let result = await NoteMarkdownFiles.export(note: note, imageDirectory: images, to: url)
    #expect(result.failure == nil && result.images == 1 && result.missingImages == 0)
  }

  @Test func singleExportReportsMissingImages() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let id = UUID()
    let note = Note(
      id: UUID().uuidString,
      body: NoteImages.token(NoteImages.Image(id: id, ext: "png", width: nil)),
      createdAt: .now, modifiedAt: .now)
    let url = root.appending(path: "缺图.md")
    let result = await NoteMarkdownFiles.export(note: note, imageDirectory: images, to: url)
    #expect(result.failure == nil && result.images == 0 && result.missingImages == 1)
    // 文件本身还是写出来了；一张图都没拷到就不建 attachments
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "attachments").path))
    // 没有图片目录：都算不在
    let noDirectory = await NoteMarkdownFiles.export(note: note, imageDirectory: nil, to: url)
    #expect(noDirectory.missingImages == 1 && noDirectory.images == 0)
  }
}
