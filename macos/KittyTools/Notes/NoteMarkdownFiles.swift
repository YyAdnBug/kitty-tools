// 便签的 Markdown 导出 / 导入（PLAN §10「便签」第 8 批，拍板 D④；入口在 设置 › 便签「数据」）。
// - 导出：每条便签一个 .md 文件（文件名 = 显示标题，清理、截断、重名加「 2」「 3」），正文里的任务、颜色、
//   图片令牌换成 Markdown（§3.3）；图片从 notes-images/ 原样拷进旁边的 attachments/（同一张只拷一份）。
//   文件头带编号、自己起的标题、颜色、时间（到毫秒、本地时区）、修订号、归档、固定、顺序；**新建一个文件夹**
//   「Kitty Tools 便签 2026-10-17」（重名加「 2」「 3」），绝不覆盖、绝不往已有的文件夹里混写。
// - 导入：自己的文件按编号合并（NoteStore.adopt：改得更晚的才换、被换掉的那一版进「最近删除」），同一个文件夹
//   导两遍第二遍什么都不变；别处的 .md / .markdown / .txt 每个变一条新便签（新编号），开头有别人的 YAML 头就原样
//   留在正文里。图片路径相对那个 .md 所在的文件夹，解析符号链接之后必须还在用户选的那个文件夹里（不联网）。
// - 纯函数（文件名、文件头、三种换法、路径判断）都在这里配单测；读文件、写文件、存图片在 @concurrent 里做
//   （mac-native §3），`adopt` 和界面的刘海岛在主线程。
// - 上限：一次最多 2000 个文件（按文件名排序取前 2000）；单个文件超过 4 MB、不是 UTF-8、换完正文超过
//   Note.maxBodyBytes 的跳过；图片按 NoteImageStore 的上限（原始输入 160 MB、存下去的那份 20 MB）。
// ponytail: 导出时文件名截到 80 个字 / 200 字节，不是按文件系统的实际上限（255 字节）算的：够用，长名字截短比
//   截到 255 里再被系统拒了好。导入只读文件夹的第一层，不进子文件夹（SPEC §7 不做）。

import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated enum NoteMarkdownFiles {
  /// 导出文件夹的名字前缀
  static let folderPrefix = "Kitty Tools 便签 "
  /// 图片放在导出文件夹里的哪个子文件夹
  static let attachmentsName = "attachments"
  /// 一次最多导入这么多个文件（按文件名排序取前这么多）
  static let maxFiles = 2000
  /// 单个 .md 文件最多多大（字节）
  static let maxFileBytes = 4 << 20
  /// 文件名最多几个字、UTF-8 最多几个字节
  static let maxNameLength = 80
  static let maxNameBytes = 200

  // MARK: 文件名

  /// 一条便签导出时的文件名（不带 .md）：displayTitle 去掉控制字符，`/` `:` `\` 换成「-」，去掉两头的空白和开头的「.」，
  /// 截到 80 个字（且 UTF-8 不超过 200 字节），空的叫「未命名便签」
  static func fileName(for note: Note) -> String {
    var name = note.displayTitle.unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) }
      .map(String.init).joined()
    for character in ["/", ":", "\\"] {
      name = name.replacingOccurrences(of: character, with: "-")
    }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while name.hasPrefix(".") { name.removeFirst() }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    name = truncate(name, characters: maxNameLength, bytes: maxNameBytes)
    return name.isEmpty ? Note.untitled : name
  }

  /// 几条便签的文件名：重名（不分大小写、Unicode 规范化后比）加「 2」「 3」。taken 里是已经用掉的（不带 .md）
  static func fileNames(for notes: [Note], taken: Set<String> = []) -> [String] {
    var used = Set(taken.map(normalized))
    return notes.map { note in
      let base = fileName(for: note)
      var candidate = base
      var counter = 2
      while used.contains(normalized(candidate)) {
        candidate = numbered(base, counter)
        counter += 1
      }
      used.insert(normalized(candidate))
      return candidate
    }
  }

  /// 加序号之后仍不超过 80 个字 / 200 字节（序号算在里面）
  private static func numbered(_ base: String, _ number: Int) -> String {
    let suffix = " \(number)"
    let room = max(maxNameLength - suffix.count, 0)
    let head = truncate(base, characters: room, bytes: maxNameBytes - suffix.utf8.count)
    return head + suffix
  }

  /// 名字比较用的规范形：Unicode 规范化 + 小写（不分大小写）
  private static func normalized(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// 截到这么多个字、UTF-8 不超过这么多字节
  static func truncate(_ text: String, characters: Int, bytes: Int) -> String {
    var (count, size) = (0, 0)
    var end = text.startIndex
    while end < text.endIndex, count < characters {
      let next = text.index(after: end)
      size += text[end..<next].utf8.count
      guard size <= bytes else { break }
      (count, end) = (count + 1, next)
    }
    return String(text[..<end])
  }

  /// 导出文件夹的名字（本地日期）
  static func folderName(now: Date = .now, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    return String(
      format: "%@%04d-%02d-%02d", folderPrefix, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 在 parent 里新建一个不重名的文件夹（「Kitty Tools 便签 2026-10-17」「… 2」「… 3」），返回它的 URL。
  /// **绝不覆盖**：用 createDirectory 不带 withIntermediateDirectories 也会在已存在时抛错，这里先找名字
  static func makeFolder(in parent: URL, now: Date = .now) throws -> URL {
    let base = folderName(now: now)
    for number in 0..<10_000 {
      let name = number == 0 ? base : "\(base) \(number + 1)"
      let url = parent.appending(path: name, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: url.path) { continue }
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      return url
    }
    throw CocoaError(.fileWriteFileExists)
  }

  // MARK: 文件头

  /// 一条便签的文件头（`---` 那几行，不带后面的空行）
  static func header(for note: Note) -> String {
    var lines = ["---", "kitty-note: \(note.id)"]
    let own = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !own.isEmpty { lines.append("title: \(jsonString(note.title))") }
    lines.append("color: \(Note.clamped(color: note.color))")
    lines.append("created: \(iso(note.createdAt))")
    lines.append("modified: \(iso(note.modifiedAt))")
    lines.append("revision: \(min(max(note.revision, 0), Note.maxRevision))")
    lines.append("archived: \(note.isArchived)")
    lines.append("pinned: \(note.isPinned)")
    lines.append("order: \(note.order)")
    lines.append("---")
    return lines.joined(separator: "\n")
  }

  /// 值按 JSON 字符串写（引号、反斜杠、换行都转义）：JSON 字符串也是合法的 YAML
  static func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return text
  }

  /// 自家文件的头（第一行正好是 `---`、前 40 行里有收尾的 `---`、头里有合法的 `kitty-note`）。
  /// 只认导出的那几个键；每个值都验：颜色夹到 0–7、时间认不出用 fallback、revision 夹到 0…max、archived / pinned 只认
  /// true / false、order 有限的数否则 0、title 按 JSON 字符串解（解不出当空）。body 是收尾的 `---` 后面紧跟的一个换行之后
  struct Header: Equatable {
    var id: String
    var title = ""
    var color = 0
    var created: Date?
    var modified: Date?
    var revision = 0
    var archived = false
    var pinned = false
    var order: Double = 0
    var text = ""
  }

  static func parseHeader(_ text: String, modifiedFallback: Date = .now) -> Header? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---" else { return nil }
    var closing: Int?
    for index in 1..<min(lines.count, 41) where lines[index] == "---" {
      closing = index
      break
    }
    guard let closing else { return nil }
    var values: [String: String] = [:]
    for line in lines[1..<closing] {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      values[key] = value
    }
    guard let rawID = values["kitty-note"], let uuid = UUID(uuidString: rawID) else { return nil }
    var header = Header(id: uuid.uuidString)
    header.title = values["title"].flatMap(jsonDecode) ?? ""
    if let raw = values["color"], let color = Int(raw) { header.color = Note.clamped(color: color) }
    header.created = values["created"].flatMap(parseDate)
    header.modified = values["modified"].flatMap(parseDate) ?? modifiedFallback
    if let raw = values["revision"], let revision = Int(raw) {
      header.revision = min(max(revision, 0), Note.maxRevision)
    }
    if let raw = values["archived"] { header.archived = raw == "true" }
    if let raw = values["pinned"] { header.pinned = raw == "true" }
    if let raw = values["order"], let order = Double(raw), order.isFinite { header.order = order }
    // 收尾的 `---` 后面紧跟的一个换行不算正文（`\r\n` 在进来之前已经换成 `\n`）
    var start = min(closing + 1, lines.count)
    // 导出的文件在收尾的 `---` 后面空一行再写正文：那一行是分隔用的，不算正文。没有空行（别处手写的）照旧
    if start < lines.count, lines[start].isEmpty { start += 1 }
    header.text = lines[start...].joined(separator: "\n")
    return header
  }

  private static func jsonDecode(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  private static func parseDate(_ raw: String) -> Date? {
    let choices: [ISO8601DateFormatter.Options] = [
      [.withInternetDateTime, .withFractionalSeconds],
      [.withInternetDateTime],
    ]
    for options in choices {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: raw) { return Note.stamp(date) }
    }
    return nil
  }

  /// 开头有 YAML 头（`---` … `---`）时它到哪为止（含收尾那行的换行）；没有给 nil。别处的文件原样留在正文里，
  /// 只对它后面的字做任务 / 颜色 / 图片的换法
  static func foreignHeaderEnd(in text: String) -> Int? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---" else { return nil }
    for index in 1..<min(lines.count, 41) where lines[index] == "---" {
      return lines[0...index].joined(separator: "\n").utf16.count + 1
    }
    return nil
  }

  // MARK: 正文 ⇄ Markdown

  /// 一份正文档 → 导出时写进 .md 的正文（任务、颜色、图片都换好，代码块里的行不换任务和颜色）
  static func markdownBody(_ body: String) -> String {
    let tasks = NoteTasks.markdown(from: body)
    let colors = NoteMarkdown.html(from: tasks)
    return imagesToMarkdown(colors)
  }

  /// 正文里的图片令牌换成 `![image|宽](attachments/<编号>.<扩展名>)`；代码块里的行不换
  private static func imagesToMarkdown(_ body: String) -> String {
    markdownImages(body).text
  }

  /// 同上，另外给用到的图片
  /// ponytail: 代码块里的行不换令牌（第 7 批定的是块里的令牌也显示成图），导出时这些图不带文件。
  /// 上限：代码块里的图带到另一台 Mac 上会没有；升级路径是导出时一律换、导入时代码块里只认自己写出去的
  /// `attachments/<编号>.<扩展名>`。
  static func markdownImages(_ body: String) -> (
    text: String, images: [NoteImages.Image]
  ) {
    let text = body as NSString
    let blocks = NoteMarkdown.codeBlocks(in: text)
    let result = NSMutableString(capacity: text.length)
    var seen: [String: NoteImages.Image] = [:]
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      if NoteMarkdown.role(at: start, in: blocks) == nil, line.contains("kitty-note-image://") {
        let matches = NoteImages.matches(in: line as NSString)
        let lineResult = NSMutableString(string: line)
        // **从后往前换**：换上去的比原来短（`kitty-note-image://` → `attachments/`），从前往后换的话后面几张的位置就错了——
        // 一行两张图时越界闪退（0.5.0 测试包真机崩过），后面还有字时写坏文件
        for match in matches.reversed() {
          let image = match.image
          let key = "\(image.id.uuidString).\(image.ext)"
          if seen[key] == nil { seen[key] = image }
          let width = image.width.map { "|\($0)" } ?? ""
          lineResult.replaceCharacters(
            in: match.range,
            with: "![image\(width)](\(attachmentsName)/\(image.id.uuidString).\(image.ext))")
        }
        result.append(lineResult as String)
      } else {
        result.append(line)
      }
      result.append(
        text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = max(end, location + 1)
    }
    return (result as String, Array(seen.values))
  }

  /// 导入时把正文换回来：任务、颜色、图片（图片要读文件、存进 notes-images，所以在 @concurrent 的那一层做）
  static func bodyFromMarkdown(
    _ markdown: String, headerEnd: Int? = nil
  ) -> (prefix: String, body: String) {
    if let headerEnd {
      let text = markdown as NSString
      let prefix = text.substring(to: min(headerEnd, text.length))
      let body = text.substring(from: min(headerEnd, text.length))
      return (prefix, bodyFromMarkdown(body))
    }
    return ("", bodyFromMarkdown(markdown))
  }

  private static func bodyFromMarkdown(_ markdown: String) -> String {
    let tasks = NoteTasks.body(fromMarkdown: markdown)
    return NoteMarkdown.body(fromHTML: tasks)
  }

  // MARK: 别处的 Markdown 里的图片

  /// 一段 Markdown 图片：`![说明](路径)` / `![说明|宽](路径)`，range 是整段
  struct MarkdownImage: Equatable, Sendable {
    var range: NSRange
    var width: Int?
    var path: String
  }

  /// 一行里的 Markdown 图片（跳过行内代码里的）。没配上、不是图片的给空
  static func markdownImages(in line: String) -> [MarkdownImage] {
    let units = Array(line.utf16)
    let code = NoteMarkdown.inline(units, in: 0..<units.count).filter { $0.kind == .code }.map(
      \.range)
    var found: [MarkdownImage] = []
    var index = 0
    while index + 1 < units.count {
      guard units[index] == 0x21, units[index + 1] == 0x5B,
        !code.contains(where: { NSLocationInRange(index, $0) })
      else {
        index += 1
        continue
      }
      // 说明：到第一个没转义的 ]；说明里可以有反斜杠
      var close = index + 2
      while close < units.count, units[close] != 0x5D {
        if units[close] == 0x5C { close += 2 } else { close += 1 }
      }
      guard close < units.count, close + 1 < units.count, units[close + 1] == 0x28 else {
        index += 1
        continue
      }
      var end = close + 2
      var depth = 0
      while end < units.count {
        let unit = units[end]
        if unit == 0x5C {
          end += 2
          continue
        }
        if unit == 0x28 { depth += 1 }
        if unit == 0x29 {
          if depth == 0 { break }
          depth -= 1
        }
        end += 1
      }
      guard end < units.count, end > close + 2 else {
        index += 1
        continue
      }
      let alt = String(decoding: units[(index + 2)..<close], as: UTF16.self)
      let path = String(decoding: units[(close + 2)..<end], as: UTF16.self)
      var width: Int?
      if let bar = alt.lastIndex(of: "|"), let raw = Int(alt[alt.index(after: bar)...]) {
        width = NoteImages.width(raw)
      }
      found.append(
        MarkdownImage(
          range: NSRange(location: index, length: end + 1 - index), width: width, path: path))
      index = end + 1
    }
    return found
  }

  /// 图片路径是不是在 root 里（解析符号链接之后）：返回解析完的 URL；跑出去、不是本地相对路径的给 nil
  static func imageURL(path: String, in root: URL) -> URL? {
    let decoded = path.removingPercentEncoding ?? path
    guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("~"),
      !decoded.lowercased().hasPrefix("http://"),
      !decoded.lowercased().hasPrefix("https://"),
      !decoded.lowercased().hasPrefix("file:")
    else { return nil }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let url = base.appending(path: decoded).standardizedFileURL.resolvingSymlinksInPath()
    let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
    guard url.path.hasPrefix(prefix) else { return nil }
    return url
  }

  /// 文件大小（读不到属性给 nil）
  private static func fileSize(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
  }

  /// 文件是不是读得出来的普通文件、不是文件夹
  static func isRegularFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }
    return !isDirectory.boolValue
  }

  // MARK: 读写文件夹（@concurrent）

  /// 导出做了什么
  struct ExportResult: Sendable {
    var folder: URL?
    var folderName = ""
    var count = 0
    var missingImages = 0
    /// 写到一半停下：是哪个文件、为什么（已经写出去的留着）
    var failure: String?
  }

  /// 导出全部 notes 到 parent 下新建的一个文件夹。图片从 imageDirectory 拷进 attachments/（同一张只拷一份）。
  /// 写坏一个文件就停，已经写出去的留着
  @concurrent static func export(
    notes: [Note], imageDirectory: URL?, to parent: URL, now: Date = .now
  ) async -> ExportResult {
    var result = ExportResult()
    let folder: URL
    do {
      folder = try makeFolder(in: parent, now: now)
    } catch {
      result.failure = "没能新建导出文件夹：\(error.localizedDescription)"
      return result
    }
    result.folder = folder
    result.folderName = folder.lastPathComponent
    let names = fileNames(for: notes)
    var copied = Set<String>()
    guard let imageDirectory else {
      // 没有图片目录：令牌照样换、文件都不拷
      for (note, name) in zip(notes, names) {
        let (text, images) = fileText(for: note)
        do {
          try write(text, name: name, in: folder)
          result.count += 1
        } catch {
          result.failure = "「\(name).md」写不进去：\(error.localizedDescription)"
          return result
        }
        result.missingImages += images.count
      }
      return result
    }
    let attachments = folder.appending(path: attachmentsName, directoryHint: .isDirectory)
    for (note, name) in zip(notes, names) {
      let (text, images) = fileText(for: note)
      do {
        try write(text, name: name, in: folder)
        result.count += 1
      } catch {
        result.failure = "「\(name).md」写不进去：\(error.localizedDescription)"
        return result
      }
      for image in images {
        let key = "\(image.id.uuidString).\(image.ext)"
        guard !copied.contains(key) else { continue }
        copied.insert(key)
        if copy(image, from: imageDirectory, to: attachments) == .missing {
          result.missingImages += 1
        }
      }
    }
    return result
  }

  /// 一条便签在导出文件里的全文（文件头 + 空行 + 正文）和用到的图片。整个文件夹导出和单条导出共用这一份，
  /// 两边的文件必须一字不差（R12）
  static func fileText(for note: Note) -> (text: String, images: [NoteImages.Image]) {
    let tasks = NoteTasks.markdown(from: note.body)
    let (body, images) = markdownImages(tasks)
    return (header(for: note) + "\n\n" + NoteMarkdown.html(from: body), images)
  }

  /// 拷一张图的结果：拷好了、旁边已经有了（跳过、**不覆盖**）、源文件不在或拷不进去
  private enum CopyResult {
    case copied
    case alreadyThere
    case missing
  }

  /// 把一张图从 imageDirectory 拷进 attachments/（同一张已经有了就跳过，绝不覆盖已有的文件）。
  /// 有图要拷时才建 attachments/。整个文件夹导出和单条导出共用
  private static func copy(
    _ image: NoteImages.Image, from imageDirectory: URL, to attachments: URL
  ) -> CopyResult {
    let key = "\(image.id.uuidString).\(image.ext)"
    let source = imageDirectory.appending(path: key)
    guard isRegularFile(source) else { return .missing }
    let destination = attachments.appending(path: key)
    if FileManager.default.fileExists(atPath: destination.path) { return .alreadyThere }
    if !FileManager.default.fileExists(atPath: attachments.path) {
      try? FileManager.default.createDirectory(
        at: attachments, withIntermediateDirectories: true)
    }
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      return .copied
    } catch {
      return .missing
    }
  }

  // MARK: 单条导出（R8–R12）

  /// 单条导出写完了：给刘海岛说的话要用
  struct SingleResult: Sendable {
    /// 存成的文件名（带 .md）
    var fileName = ""
    /// 导出到旁边的图片张数（不包含不在的）
    var images = 0
    /// 不在、没导出的图片张数
    var missingImages = 0
    /// 写不进去时是什么原因
    var failure: String?
  }

  /// 把一条便签写成一个 .md（全文和整个文件夹导出时一样），图片从 imageDirectory 拷进同一个文件夹的
  /// attachments/（已经有了跳过、不覆盖；不在的算进 missingImages，不耽误文件本身）。
  /// 写文件、拷图片都在 @concurrent 里做（R10）
  @concurrent static func export(
    note: Note, imageDirectory: URL?, to url: URL
  ) async -> SingleResult {
    var result = SingleResult()
    result.fileName = url.lastPathComponent
    let (text, images) = fileText(for: note)
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
    } catch {
      result.failure = "「\(url.lastPathComponent)」写不进去：\(error.localizedDescription)"
      return result
    }
    guard let imageDirectory else {
      result.missingImages = images.count
      return result
    }
    let attachments = url.deletingLastPathComponent()
      .appending(path: attachmentsName, directoryHint: .isDirectory)
    var seen = Set<String>()
    for image in images {
      // 同一张图引用了几次也只算一张、只拷一份（和导出全部一样按编号去重）
      let key = "\(image.id.uuidString).\(image.ext)"
      guard seen.insert(key).inserted else { continue }
      switch copy(image, from: imageDirectory, to: attachments) {
      case .copied, .alreadyThere: result.images += 1
      case .missing: result.missingImages += 1
      }
    }
    return result
  }

  /// 三处入口菜单里那一项的名字（全部便签窗口的右键、那叠 / 浮动便签的操作菜单，R8）
  static let singleExportTitle = "导出为 Markdown…"

  /// 「导出为 Markdown…」的存储面板：选好之后在后台写文件，写完用刘海岛说一句（R9、R11）。
  /// 那叠、浮动便签的面板不激活 App：激活、把面板提到最前、关掉后把前台还给原来的 App 都在 FilePanel 里
  /// （同 NoteTextView.insertImageFromPanel），然后 restore 把键盘还给便签（调用方给）。
  /// 便签窗口（普通 NSWindow）也走这一条，行为三处一样（R10 允许 beginSheetModal / begin）
  @MainActor static func exportPanel(
    _ note: Note, imageDirectory: URL?, island: Island?,
    restore: @escaping @MainActor () -> Void = {}
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = fileName(for: note) + ".md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.canCreateDirectories = true
    panel.prompt = "导出"
    panel.message = "导出成一个 Markdown 文件；图片放在旁边的 attachments 文件夹里"
    panel.isExtensionHidden = false
    FilePanel.begin(panel) { response in
      restore()
      guard response == .OK, let url = panel.url else { return }
      Task {
        let result = await export(note: note, imageDirectory: imageDirectory, to: url)
        guard let island else { return }
        if let failure = result.failure {
          island.show(
            "导出没成", detail: failure, tone: .error,
            symbol: "exclamationmark.triangle.fill")
          return
        }
        if result.missingImages > 0 {
          var detail = "\(result.missingImages) 张图片不在，没导出"
          if result.images > 0 { detail = "\(result.images) 张图片在旁边的 attachments 文件夹 · " + detail }
          island.show("已导出「\(result.fileName)」", detail: detail)
          return
        }
        island.show(
          "已导出「\(result.fileName)」",
          detail: result.images > 0 ? "\(result.images) 张图片在旁边的 attachments 文件夹" : nil)
      }
    }
  }

  private static func write(_ text: String, name: String, in folder: URL) throws {
    try Data(text.utf8).write(to: folder.appending(path: "\(name).md"), options: .atomic)
  }

  /// 一个要导入的文件
  struct Source: Sendable {
    var url: URL
    /// 图片路径相对的文件夹（选的是文件夹就是它，选的是文件就是文件所在的文件夹）
    var root: URL
  }

  /// 导入做了什么
  struct ImportResult: Sendable {
    var notes: [Note] = []
    /// 跳过（不是 UTF-8、太大、换完超上限、读不出来、超过 2000 个）
    var skipped = 0
    /// 图片没导进来的张数（跑出文件夹、不在、太大、读不出、不是图片）
    var missingImages = 0
    /// 只导了前 2000 个
    var limitHit = false
  }

  /// 读 sources（已经按文件名排好、截到 maxFiles）、换成 Note。自己家的头按编号、别处的每个一条新便签。
  /// 图片读文件、存进 imageDirectory 都在这个 @concurrent 里；返回的 Note 由调用方在主线程 adopt
  @concurrent static func importNotes(
    sources: [Source], imageDirectory: URL?, now: Date = .now
  ) async -> ImportResult {
    var result = ImportResult()
    result.limitHit = sources.count > maxFiles
    let files = Array(
      sources.sorted {
        $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
          == .orderedAscending
      }.prefix(maxFiles))
    result.skipped += max(0, sources.count - maxFiles)
    for (index, source) in files.enumerated() {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path),
        let size = attributes[.size] as? Int, size <= maxFileBytes
      else {
        result.skipped += 1
        continue
      }
      guard let data = try? Data(contentsOf: source.url), let raw = decode(data) else {
        result.skipped += 1
        continue
      }
      let modified =
        (try? source.url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? now
      if var header = parseHeader(raw, modifiedFallback: modified) {
        let (body, failures) = await convertImages(
          in: bodyFromMarkdown(header.text).body, root: source.root, imageDirectory: imageDirectory)
        result.missingImages += failures
        guard body.utf8.count <= Note.maxBodyBytes else {
          result.skipped += 1
          continue
        }
        header.text = body
        var note = Note(
          id: header.id, title: Note.sanitized(title: header.title),
          body: Note.sanitized(text: body),
          color: header.color, createdAt: Note.stamp(header.created ?? modified),
          modifiedAt: Note.stamp(header.modified ?? modified), revision: header.revision,
          isArchived: header.archived, isPinned: header.pinned, order: header.order)
        note.title = Note.sanitized(title: header.title)
        note.body = Note.sanitized(text: body)
        result.notes.append(note)
      } else {
        // 别处的文件：一个文件一条新便签（新编号）；开头有 YAML 头就原样留在正文里
        let foreignEnd = foreignHeaderEnd(in: raw)
        let (prefix, body) = bodyFromMarkdown(raw, headerEnd: foreignEnd)
        let (converted, failures) = await convertImages(
          in: body, root: source.root, imageDirectory: imageDirectory)
        result.missingImages += failures
        guard converted.utf8.count <= Note.maxBodyBytes else {
          result.skipped += 1
          continue
        }
        let content = prefix + converted
        let lines = content.components(separatedBy: "\n")
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let hasHeading = first.hasPrefix("# ")
        let stem = source.url.deletingPathExtension().lastPathComponent
        let title = hasHeading ? "" : Note.sanitized(title: stem)
        let note = Note(
          id: UUID().uuidString, title: title, body: Note.sanitized(text: content), color: 0,
          createdAt: Note.stamp(min(modified, now)), modifiedAt: Note.stamp(min(modified, now)),
          order: -1_000_000_000 + Double(index))
        result.notes.append(note)
      }
    }
    return result
  }

  private static func decode(_ data: Data) -> String? {
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    guard let string = String(data: bytes, encoding: .utf8) else { return nil }
    return string.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  /// 正文里的 Markdown 图片：路径合法、在文件夹里、是图片、存得进去的换成令牌；别的原样留着。返回（正文, 失败张数）
  static func convertImages(
    in body: String, root: URL, imageDirectory: URL?
  ) async -> (body: String, failures: Int) {
    let text = body as NSString
    let blocks = NoteMarkdown.codeBlocks(in: text)
    let result = NSMutableString(capacity: text.length)
    var failures = 0
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      if NoteMarkdown.role(at: start, in: blocks) == nil, line.contains("!["),
        let directory = imageDirectory
      {
        var lineResult = line
        let images = markdownImages(in: line)
        if !images.isEmpty {
          let mutable = NSMutableString(string: line)
          for image in images.reversed() {
            guard let url = imageURL(path: image.path, in: root), isRegularFile(url) else {
              failures += 1
              continue
            }
            if let replacement = await storedImage(url, width: image.width, in: directory) {
              mutable.replaceCharacters(in: image.range, with: replacement)
            } else {
              failures += 1
            }
          }
          lineResult = mutable as String
        }
        result.append(lineResult)
      } else {
        result.append(line)
      }
      result.append(
        text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = max(end, location + 1)
    }
    return (result as String, failures)
  }

  /// 一张图 → 令牌（认得出是仓库里已有的那张、字节也一样就沿用编号；否则存一份新的）。
  /// 先比文件大小，一样才各读一次比字节（单张最大 160 MB，不先比大小的话两边都要整份读进来）
  private static func storedImage(
    _ url: URL, width: Int?, in directory: URL
  ) async -> String? {
    if let id = NoteImageStore.identifier(ofFileNamed: url.lastPathComponent) {
      let ext = url.pathExtension.lowercased()
      let existing = directory.appending(path: "\(id.uuidString).\(ext)")
      if let size = fileSize(url), size == fileSize(existing),
        let incoming = try? Data(contentsOf: url),
        let current = try? Data(contentsOf: existing),
        incoming == current
      {
        return NoteImages.token(NoteImages.Image(id: id, ext: ext, width: width))
      }
    }
    guard case .success(let stored) = await NoteImageStore.store(fileAt: url, in: directory) else {
      return nil
    }
    return NoteImages.token(
      NoteImages.Image(id: stored.image.id, ext: stored.image.ext, width: width))
  }

  /// 目录里第一层的 .md / .markdown（跳过隐藏文件、不进子文件夹）；选文件夹时用
  static func markdownFiles(in folder: URL) -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return
      names
      .filter { !$0.hasPrefix(".") }
      .map { folder.appending(path: $0) }
      .filter { url in
        guard isRegularFile(url) else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
      }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }
}
