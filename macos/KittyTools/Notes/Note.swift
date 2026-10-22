// 便签的模型（便签库 notes 表的一行）和两条显示用的纯函数：标题（displayTitle）、列表里的一行摘要（preview）——
// 两样都不带正文里的符号（标题的 #、任务的五种方框、Markdown 的标记和颜色、代码块的围栏行；代码块里的字照原文）。
// 便签管「留着看、接着改」的东西（PLAN §10「便签」）；库、落盘、搜索、导入导出在 NoteStore，每日备份和打不开时的恢复在
// NotesBackup。
// 为以后的同步先留好的三样（这一版不同步）：稳定的编号（UUID 字符串，建了就不变，导出文件里带着）、修订号（任何字段变
// 一次 +1：判断「上次同步之后改没改过」不用看时钟）、删除记录（deletedAt 非空 = 在「最近删除」里，以后就是墓碑）。
// 时间只精确到毫秒：库里、导出文件里存的都是整数毫秒，内存里的值也先对齐到毫秒（stamp），往返不丢、能直接比。
// 进仓库、进文件之前要过一遍的收拾也在这里（sanitized(text:) / sanitized(title:) / clamped(color:) / nextRevision）：
// 仓库的每个写入口和读导出文件时用同一份。

import Foundation

nonisolated struct Note: Identifiable, Equatable, Sendable {
  /// 预设的纸色有几种：color 是 0..<colorCount 的下标（8 种纸色和它们的字色在 NotePaper），或者自定义的（customColor）
  static let colorCount = 8
  /// 自定义纸色在 color 里的写法（便签未来计划 B1）：`customColor | 0xRRGGBB`。**只在内存里这么写**：落盘拆成两样——
  /// `color` 写最接近的那种预设（storedPreset），色值另记（库的 tint 列、导出文件和 Markdown 文件头的 tint）。
  /// 已发布的 0.5.0 读到超范围的 color 会夹回石板、改一个字就写回库，所以这个整数不能原样存进去
  static let customColor = 1 << 24
  /// 拿正文第一行当标题时最多几个字、列表里的摘要最多几个字
  static let titleLength = 60
  static let previewLength = 120
  /// 标题和正文都没有内容时显示的名字
  static let untitled = "未命名便签"
  /// 一条便签的正文最多多大（UTF-8 字节）。导入的文件按它查（SettingsArchive：正文超了的那条不要；自己导出时有超的
  /// 就不让导出「便签」一类）；正文编辑器（NoteTextView.maxBytes）和快速记一条按它拦——会超的那一次输入不进。
  /// ponytail: 正文仓库自己不拦；现在能写正文的入口（编辑器、快速记一条、导入）各自先按它拦，以后新加的入口也要拦——
  /// 剪贴板单条文字可以到 5 MB，原样存成便签就会让「便签」一类导不出去、每日自动备份里也不带
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

  /// 纸色夹进合法的值：预设的下标夹进 0..<colorCount，自定义的原样
  static func clamped(color raw: Int) -> Int {
    customRGB(of: raw) != nil ? raw : min(max(raw, 0), colorCount - 1)
  }

  /// 自定义的纸色（色值 0xRRGGBB）
  static func custom(rgb: Int) -> Int { customColor | (rgb & 0xFFFFFF) }

  /// 自定义纸色的色值；预设的给 nil
  static func customRGB(of color: Int) -> Int? { color >> 24 == 1 ? color & 0xFFFFFF : nil }

  /// 落盘的那个下标：预设的照旧（夹进范围），自定义的是最接近的那种预设（0.5.0 看到的就是它）
  static func storedPreset(of color: Int) -> Int {
    customRGB(of: color).map(NotePaper.nearestPreset(rgb:)) ?? clamped(color: color)
  }

  /// 文件里读回来（导出文件、Markdown 文件头）：预设下标 + 色值 → 内存里的纸色。色值合法就是自定义的（文件里的 tint
  /// 只有新版本写、旧版本读进去再导出时整个丢掉，不会和 color 对不上），没有或写坏了用预设
  static func color(preset: Int, tint: Int?) -> Int {
    guard let tint, (0...0xFFFFFF).contains(tint) else {
      return min(max(preset, 0), colorCount - 1)
    }
    return custom(rgb: tint)
  }

  /// 库的 tint 列里存的：写入那一刻的预设下标 << 24 | 色值。读回来**只比这两个数**，不重算「最接近的预设」——
  /// 以后调了推导，已经存着的自定义色也不会因为对不上被当成旧版本换过颜色、悄悄丢掉
  static func storedTint(of color: Int) -> Int? {
    customRGB(of: color).map { storedPreset(of: color) << 24 | $0 }
  }

  /// 库里读回来：color 列 + tint 列 → 内存里的纸色。tint 里记的预设和 color 列对得上才算自定义；对不上说明旧版本
  /// （0.5.0 不认识 tint、只改 color）换过颜色，按它换的那种
  static func color(stored preset: Int, tint: Int?) -> Int {
    let preset = min(max(preset, 0), colorCount - 1)
    guard let tint, tint >= 0, tint >> 24 == preset else { return preset }
    return custom(rgb: tint & 0xFFFFFF)
  }

  /// ⌘. 和新建便签的轮换：只在 8 种预设里轮，自定义的从最接近的那种的下一种接着轮
  static func nextPreset(after color: Int) -> Int { (storedPreset(of: color) + 1) % colorCount }

  /// 色值在文件里的写法 `#RRGGBB`（导出文件、Markdown 文件头的 tint）
  static func hex(rgb: Int) -> String { String(format: "#%06X", rgb & 0xFFFFFF) }

  /// `#RRGGBB`（大小写不分）→ 色值；别的写法给 nil
  static func rgb(hex raw: String) -> Int? {
    let digits = raw.utf8.dropFirst()
    guard raw.utf8.first == UInt8(ascii: "#"), digits.count == 6,
      digits.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
    else { return nil }
    return Int(String(decoding: digits, as: UTF8.self), radix: 16)
  }

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
  /// 超过 titleLength 个字截断加「…」；都没有就是「未命名便签」。
  /// **只有图片的行跳过**（标题用下一行有字的；和字同一行的图去掉、不写「[图片]」）：整条便签只有图片时标题就是「[图片]」
  var displayTitle: String {
    let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !own.isEmpty { return own }
    // **标题里不带图片**：和字同一行的图整个去掉（原来换成「[图片]」夹在字中间，标签上是「测试图片[图片]123」，
    // 2026-10-18 用户真机报），去掉后留下的连串空白收成一个。只有图片的行照旧整行不算；整条便签只有图片时标题才是「[图片]」
    guard
      let line = Self.lines(
        of: NoteImages.stripping(body), skipping: 0, budget: 0, droppingImageLines: true
      ).first
    else {
      return NoteImages.containsToken(body) ? NoteImages.placeholder : Self.untitled
    }
    let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return Self.clipped(collapsed, to: Self.titleLength)
  }

  /// 列表里标题下面那一行摘要：其余有内容的行（标题取自正文第一行时不重复它）拼成一行，超过 previewLength 个字截断。
  /// 图片写成「[图片]」；**只有图片的行不占「标题那一行」**（和 displayTitle 同一个口径）：标题取的是跳过图片行之后
  /// 第一个有字的行，摘要就从那一行之后开始，不重复标题（F10）。图片行自己照留（它是这条便签的内容）
  var preview: String {
    let hasOwnTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // 整条便签只有图片、又没起标题：标题已经是「[图片]」，摘要不再重复一遍（空着：列表、预览卡上写「没有更多内容」）
    if !hasOwnTitle, NoteImages.containsToken(body),
      Self.lines(of: body, skipping: 0, budget: 0, droppingImageLines: true).isEmpty
    {
      return ""
    }
    let rest = Self.lines(of: body, skipping: hasOwnTitle ? 0 : 1, budget: Self.previewLength)
    return Self.clipped(rest.joined(separator: " "), to: Self.previewLength)
  }

  /// 「最近删除」里只读的那份正文（F11）：令牌换成「[图片]」，其余照原文（不带任务 / Markdown 的样式）。
  /// 只读视图那边不许直接 `Text(body)`（`![image](kitty-note-image://…)` 会原样露出来）
  var readOnlyBody: String { NoteImages.display(body) }

  /// 正文里有内容的行（每行过一遍 clean），跳过前 skipping 行；用空格拼起来超过 budget 个字就不再往下读（正文可以很长）。
  /// 代码块（NoteMarkdown.codeBlocks，同正文编辑器）的围栏行不算、块里的行照原文（只去两头的空白）。
  /// droppingImageLines：只有图片的行整行不算（标题取正文第一行时跳过这种行）
  /// **只有图片的行也不占「跳过前 skipping 行」的名额**：标题取的是跳过图片行之后第一个有字的行，
  /// 摘要（skipping 1）就从那一行之后开始，不重复标题（F10）
  /// ponytail: 认代码块只看正文开头 blockScanLimit 个字（标题、摘要只读开头几行；整篇认一遍 1 MB 要几毫秒，列表的每一行、
  /// 那叠的每张标签都要算）。上限：开头在这一段里、收尾在后面的块认不出来，它的围栏行和块里的字照普通的行去标记——
  /// 碰上了再改成「从头往后边读边认」
  private static func lines(
    of body: String, skipping: Int, budget: Int, droppingImageLines: Bool = false
  ) -> [String] {
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
      if droppingImageLines, NoteImages.isImageOnly(raw) { continue }
      let line: String
      switch NoteMarkdown.role(at: start, in: blocks) {
      case nil: line = clean(raw)
      case .content:
        // 代码块里的行照原文（只去两头的空白），但**图片的令牌要换成「[图片]」**：列表、标签、预览卡上不许露原文
        line = NoteImages.display(
          String(raw.prefix(scanLimit)).trimmingCharacters(in: .whitespaces))
      case .open, .close: continue
      }
      guard !line.isEmpty else { continue }
      // 只有图片的行不算「标题那一行」的名额（照留：它是这条便签的内容，不是标题）
      if skipped < skipping, !NoteImages.isImageOnly(raw) {
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
    if let first = line.first, NoteTasks.State(character: first) != nil {
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
