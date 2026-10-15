// 便签的模型（便签库 notes 表的一行）和两条显示用的纯函数：标题（displayTitle）、列表里的一行摘要（preview）——
// 两样都不带正文里的符号（标题的 #、任务的方框、Markdown 的标记、代码块的围栏行；代码块里的字照原文）。
// 便签管「留着看、接着改」的东西（PLAN §10「便签」）；库、落盘、搜索、导入导出在 NoteStore，每日备份和打不开时的恢复在
// NotesBackup。
// 为以后的同步先留好的三样（这一版不同步）：稳定的编号（UUID 字符串，建了就不变，导出文件里带着）、修订号（任何字段变
// 一次 +1：判断「上次同步之后改没改过」不用看时钟）、删除记录（deletedAt 非空 = 在「最近删除」里，以后就是墓碑）。
// 时间只精确到毫秒：库里、导出文件里存的都是整数毫秒，内存里的值也先对齐到毫秒（stamp），往返不丢、能直接比。
// 进仓库、进文件之前要过一遍的收拾也在这里（sanitized(text:) / sanitized(title:) / clamped(color:) / nextRevision）：
// 仓库的每个写入口和读导出文件时用同一份。

import Foundation

nonisolated struct Note: Identifiable, Equatable, Sendable {
  /// 纸色有几种：color 是 0..<colorCount 的下标（调色板以后的批次定）
  static let colorCount = 8
  /// 拿正文第一行当标题时最多几个字、列表里的摘要最多几个字
  static let titleLength = 60
  static let previewLength = 120
  /// 标题和正文都没有内容时显示的名字
  static let untitled = "未命名便签"
  /// 一条便签的正文最多多大（UTF-8 字节）。导入的文件按它查（SettingsArchive：正文超了的那条不要；自己导出时有超的
  /// 就不让导出「便签」一类）；正文编辑器（NoteTextView.maxBytes）和快速记一条按它拦——会超的那一次输入不进。
  /// ponytail: 正文仓库自己不拦。以后的「存成便签」这些入口要按它拦——剪贴板单条文字可以到 5 MB，原样存成便签就会让
  /// 「便签」一类导不出去、每日自动备份里也不带
  static let maxBodyBytes = 1 << 20
  /// 自己起的标题的上限：不超过这么多个字，并且 UTF-8 不超过这么多字节（一个字后面挂一长串组合符号的那种，按字数拦不住）。
  /// 超了的一律截到上限（sanitized(title:)）：仓库的写入口和读导出文件时都是
  static let maxTitleLength = 200
  static let maxTitleBytes = 1024
  /// 修订号的上限（导入的文件、读库时都夹到它；到顶了不再往上加，不会溢出）
  static let maxRevision = 1_000_000_000

  /// UUID 字符串，建了就不变
  let id: String
  /// 自己起的标题；空 = 用正文第一行（displayTitle）
  var title = ""
  var body = ""
  var color = 0
  var createdAt: Date
  /// 给人看的「改于」：只在标题 / 正文 / 颜色变时更新（归档、固定、挪顺序、删除不算）
  var modifiedAt: Date
  /// 任何字段变一次就 +1
  var revision = 0
  var isArchived = false
  var isPinned = false
  /// 排序值：小的在前；可以取两条中间的值，挪一条不用改别的
  var order: Double = 0
  /// 非空 = 在「最近删除」里（什么时候删的）
  var deletedAt: Date?

  /// 没归档、没删（「全部」里列的、屏幕边缘那叠里有的、能开着能浮着的）
  var isActive: Bool { !isArchived && deletedAt == nil }

  // MARK: 收拾（进仓库、进文件之前）

  /// 正文、标题里的 NUL（U+0000）去掉：库里的文字按 C 字符串存取，碰到它后面的就都丢了
  static func sanitized(text raw: String) -> String {
    guard raw.utf8.contains(0) else { return raw }
    return String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 != "\0" }))
  }

  /// 自己起的标题：去掉 NUL，再截到上限（maxTitleLength 个字、maxTitleBytes 字节，哪个先到算哪个）
  static func sanitized(title raw: String) -> String {
    let clean = sanitized(text: raw)
    var (count, bytes) = (0, 0)
    var end = clean.startIndex
    while end < clean.endIndex, count < maxTitleLength {
      let next = clean.index(after: end)
      bytes += clean[end..<next].utf8.count
      guard bytes <= maxTitleBytes else { break }
      (count, end) = (count + 1, next)
    }
    return end == clean.endIndex ? clean : String(clean[..<end])
  }

  /// 纸色的下标夹进 0..<colorCount
  static func clamped(color raw: Int) -> Int { min(max(raw, 0), colorCount - 1) }

  /// 改动之后的修订号：+1，到 maxRevision 为止（负的、超了的先夹回来）
  static func nextRevision(after revision: Int) -> Int {
    min(max(revision, 0), maxRevision - 1) + 1
  }

  // MARK: 时间

  /// 时间 → 整数毫秒（1970 年起）；离谱到换算不了的给 0
  static func milliseconds(_ date: Date) -> Int64 {
    Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) ?? 0
  }

  static func date(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  /// 对齐到毫秒：和存进库再读回来的是同一个值
  static func stamp(_ date: Date) -> Date { self.date(milliseconds: milliseconds(date)) }

  // MARK: 显示

  /// 显示用的标题：自己起的标题；没起就是正文第一个有内容的行（去掉行首的 #、任务符号和 Markdown 的标记），
  /// 超过 titleLength 个字截断加「…」；都没有就是「未命名便签」
  var displayTitle: String {
    let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !own.isEmpty { return own }
    guard let line = Self.lines(of: body, skipping: 0, budget: 0).first else {
      return Self.untitled
    }
    return Self.clipped(line, to: Self.titleLength)
  }

  /// 列表里标题下面那一行摘要：其余有内容的行（标题取自正文第一行时不重复它）拼成一行，超过 previewLength 个字截断
  var preview: String {
    let hasOwnTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let rest = Self.lines(of: body, skipping: hasOwnTitle ? 0 : 1, budget: Self.previewLength)
    return Self.clipped(rest.joined(separator: " "), to: Self.previewLength)
  }

  /// 正文里有内容的行（每行过一遍 clean），跳过前 skipping 行；用空格拼起来超过 budget 个字就不再往下读（正文可以很长）。
  /// 代码块（NoteMarkdown.codeBlocks，同正文编辑器）的围栏行不算、块里的行照原文（只去两头的空白）。
  /// ponytail: 认代码块只看正文开头 blockScanLimit 个字（标题、摘要只读开头几行；整篇认一遍 1 MB 要几毫秒，列表的每一行、
  /// 那叠的每张标签都要算）。上限：开头在这一段里、收尾在后面的块认不出来，它的围栏行和块里的字照普通的行去标记——
  /// 碰上了再改成「从头往后边读边认」
  private static func lines(of body: String, skipping: Int, budget: Int) -> [String] {
    var lines: [String] = []
    var (skipped, length) = (0, 0)
    let text = body as NSString
    let blocks = NoteMarkdown.codeBlocks(
      in: text.length > blockScanLimit ? text.substring(to: blockScanLimit) as NSString : text)
    var location = 0
    while location < text.length, length <= budget {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      location = max(end, location + 1)
      let raw = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      let line: String
      switch NoteMarkdown.role(at: start, in: blocks) {
      case nil: line = clean(raw)
      case .content: line = String(raw.prefix(scanLimit)).trimmingCharacters(in: .whitespaces)
      case .open, .close: continue
      }
      guard !line.isEmpty else { continue }
      guard skipped >= skipping else {
        skipped += 1
        continue
      }
      length += line.count + (lines.isEmpty ? 0 : 1)
      lines.append(line)
    }
    return lines
  }

  /// 一行去掉两头的空白、行首的标题标记（一到六个 # 后面跟空白；「#标签」不算）和任务符号（☐ ☑，还有贴进来没转成
  /// 方框的「- [ ] 」「- [x] 」），再去掉 Markdown 的标记（NoteMarkdown.plain，和正文编辑器同一个扫描器：`**粗**` → 粗、
  /// `[字](地址)` → 字；不是标题、不是任务的行连行首引用的 `>`、无序列表的符号一起去）。只管显示时不把符号带出来：
  /// 不看设置里的 Markdown 开关（标签上露着 `**` 没有意义），行首那两样也比编辑器的规则宽（方框后面不用跟空格、
  /// 只有 # 的行算空的）
  private static func clean(_ raw: String) -> String {
    var line = raw.drop(while: \.isWhitespace)
    // 去过标题标记 / 方框的行，剩下的是内容：里面只去行内的标记
    var isContent = false
    let hashes = line.prefix { $0 == "#" }.count
    if (1...6).contains(hashes), line.dropFirst(hashes).first?.isWhitespace ?? true {
      line = line.dropFirst(hashes).drop(while: \.isWhitespace)
      isContent = true
    }
    if let first = line.first, first == "☐" || first == "☑" {
      line = line.dropFirst().drop(while: \.isWhitespace)
      isContent = true
    } else if !isContent {
      // 贴进来没转成方框的「- [ ] 」「- [x] 」（哪些写法算，问 NoteTasks：它认的就是这 5 个字加空格或行尾）
      let head = String(line.prefix(6))
      if NoteTasks.body(fromMarkdown: head) != head {
        line = line.dropFirst(5).drop(while: \.isWhitespace)
        isContent = true
      }
    }
    // 标题、摘要只要开头的一百来个字：很长的一行（一整段没有换行的正文）不整行扫
    return NoteMarkdown.plain(String(line.prefix(scanLimit)), blocks: !isContent)
      .trimmingCharacters(in: .whitespaces)
  }

  /// 去标记时一行最多看这么多个字（比标题、摘要要的多得多；够放下一个带长地址的链接）
  private static let scanLimit = 4096
  /// 认代码块时最多看正文开头这么多个字（UTF-16，64 KB 上下）
  static let blockScanLimit = 1 << 16

  private static func clipped(_ text: String, to length: Int) -> String {
    text.count > length ? text.prefix(length) + "…" : text
  }
}
