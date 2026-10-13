// 便签里的任务和列表（PLAN §10「便签」第 5 批）：全是纯函数，编辑器（NoteTextView）只管调，单测 NoteTasksTests 锁住。
// - 存储（已定）：正文里任务就是行首的「☐ 」（没做完）和「☑ 」（做完了），前面可以有空格 / Tab 缩进；方框后面得是一个
//   空格或者行尾（「☐abc」不算），行中间的方框不算。无序列表项是「- 」「* 」「+ 」开头，有序的是「1. 」「1) 」。
// - 改字的几件事都写成「这一行（或选区碰到的那几行）+ 光标在哪 → 换哪几段、换成什么、换完选区在哪」（Change），
//   位置都是 UTF-16 的、相对给进来的那段文字的开头：⌘T 切换（toggle）、回车续行和空项退出（newline）、
//   Tab / ⇧Tab 缩进（indent）、打出「- [ ]」再按空格的自动转换（shorthand）。
// - 和 Markdown 互转（第 8 批的导出导入用）：「☐ 」↔「- [ ] 」、「☑ 」↔「- [x] 」，缩进和换行符原样。
// - 任务进度（做完几条 / 共几条）：列表行和预览卡上显示。
// 交互借自 Noty（MIT；只借思路，一行代码都不拷）；不照它的两处：⌘T 不是三态循环（普通 → ☐ → ☑ → 普通），就是
// 「普通行 ↔ 任务」；方框后面要跟空格才算任务。

import Foundation

nonisolated enum NoteTasks {
  static let open: Character = "☐"
  static let done: Character = "☑"

  private static let openUnit = open.utf16.first ?? 0x2610
  private static let doneUnit = done.utf16.first ?? 0x2611
  private static let space: UInt16 = 0x20
  private static let tab: UInt16 = 0x09

  /// 行首（缩进之后）的列表标记是哪种
  enum Lead: Equatable, Sendable {
    case task(isDone: Bool)
    /// 无序：- * +
    case bullet(Character)
    /// 有序：数字和它后面的「.」或「)」
    case ordered(Int, Character)
  }

  /// 一行开头的列表标记（位置是 UTF-16 的、相对行首）
  struct Prefix: Equatable, Sendable {
    /// 缩进多长（空格 / Tab）
    var indent: Int
    var lead: Lead
    /// 标记本身多长（方框和无序符号是 1，「12.」是 3）
    var markerLength: Int
    /// 标记后面跟没跟着那个空格（方框在行尾时可以没有）
    var hasSpace: Bool

    /// 标记（连后面的空格）到哪为止 = 内容从哪开始
    var contentStart: Int { indent + markerLength + (hasSpace ? 1 : 0) }
  }

  /// 一处替换
  struct Replacement: Equatable, Sendable {
    var range: NSRange
    var text: String
  }

  /// 一次改动：若干处替换（从前到后、互不相交，位置都是改之前的）和改完之后的选区
  struct Change: Equatable, Sendable {
    var replacements: [Replacement]
    var selection: NSRange
  }

  // MARK: 认标记

  /// 这一行（不含行尾的换行）开头的列表标记；不是列表行给 nil
  static func prefix(of line: String) -> Prefix? { prefix(of: Array(line.utf16)) }

  private static func prefix(of units: [UInt16]) -> Prefix? {
    let indent = units.prefix { $0 == space || $0 == tab }.count
    guard indent < units.count else { return nil }
    let first = units[indent]
    let follower = indent + 1 < units.count ? units[indent + 1] : nil
    if first == openUnit || first == doneUnit {
      // 方框后面是空格或行尾才算（「☐abc」是别处贴来的符号，不当任务）
      guard follower == nil || follower == space else { return nil }
      return Prefix(
        indent: indent, lead: .task(isDone: first == doneUnit), markerLength: 1,
        hasSpace: follower != nil)
    }
    // - * +
    if first == 0x2D || first == 0x2A || first == 0x2B {
      guard follower == space else { return nil }
      return Prefix(
        indent: indent, lead: .bullet(Character(UnicodeScalar(UInt8(first)))), markerLength: 1,
        hasSpace: true)
    }
    // 有序：最多 9 位数字（再长不是序号，也免得溢出），后面「.」或「)」，再一个空格
    let digits = units[indent...].prefix { (0x30...0x39).contains($0) }
    let end = indent + digits.count
    guard (1...9).contains(digits.count), end + 1 < units.count, units[end + 1] == space,
      units[end] == 0x2E || units[end] == 0x29
    else { return nil }
    let number = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    return Prefix(
      indent: indent, lead: .ordered(number, Character(UnicodeScalar(UInt8(units[end])))),
      markerLength: digits.count + 1, hasSpace: true)
  }

  /// 这一行是任务的话，方框那个字在第几个位置（UTF-16，相对行首；点方框、画方框用）；不是任务给 nil
  static func box(in line: String) -> Int? {
    guard let prefix = prefix(of: line), case .task = prefix.lead else { return nil }
    return prefix.indent
  }

  /// 方框点一下换成另一个
  static func flipped(_ box: Character) -> Character { box == open ? done : open }

  // MARK: ⌘T

  /// ⌘T：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头。
  /// 都已经是任务（☐ 或 ☑）→ 都去掉标记；否则把还不是任务的变成任务：保留缩进，原来是「- 」「* 」「+ 」开头的无序列表项
  /// 就把那个符号换成 ☐，别的在缩进后面加「☐ 」。选了好几行时空行不算数、也不动（同编辑器里「注释 / 取消注释」的做法）；
  /// 只有一行时空行也变成任务（先按 ⌘T 再打字）。没有可改的给 nil
  static func toggle(_ block: String, selection: NSRange) -> Change? {
    let text = block as NSString
    var lines: [(start: Int, units: [UInt16])] = []
    var location = 0
    repeat {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      lines.append((start, Array(line.utf16)))
      // 最后一行后面还有换行（block 以换行结尾）：后面那个空行也算一行
      if end == text.length, contentsEnd < end { lines.append((end, [])) }
      location = end
    } while location < text.length
    let candidates =
      lines.count == 1
      ? lines : lines.filter { !$0.units.allSatisfy { $0 == space || $0 == tab } }
    guard !candidates.isEmpty else { return nil }
    let prefixes = candidates.map { prefix(of: $0.units) }
    let allTasks = prefixes.allSatisfy { prefix in
      if case .task = prefix?.lead { return true }
      return false
    }
    var replacements: [Replacement] = []
    for (line, prefix) in zip(candidates, prefixes) {
      if allTasks, let prefix {
        replacements.append(
          Replacement(
            range: NSRange(
              location: line.start + prefix.indent, length: prefix.contentStart - prefix.indent),
            text: ""))
      } else if case .task = prefix?.lead {
        continue
      } else if let prefix, case .bullet = prefix.lead {
        replacements.append(
          Replacement(
            range: NSRange(location: line.start + prefix.indent, length: 1), text: String(open)))
      } else {
        let indent = line.units.prefix { $0 == space || $0 == tab }.count
        replacements.append(
          Replacement(range: NSRange(location: line.start + indent, length: 0), text: "\(open) "))
      }
    }
    guard !replacements.isEmpty else { return nil }
    return Change(replacements: replacements, selection: mapped(selection, through: replacements))
  }

  /// 选区跟着替换挪（纯函数）：在某一处替换后面的往后 / 往前让，落在被换掉的那一段里面的收到那一段的新末尾。
  /// 光标（长度 0）正好停在插入点上时挪到插进去的字后面；一段选区的开头停在插入点上时不挪（选区照旧盖着整行）
  static func mapped(_ selection: NSRange, through replacements: [Replacement]) -> NSRange {
    func moved(_ position: Int, staysBeforeInsertion: Bool) -> Int {
      var shift = 0
      for replacement in replacements {
        let range = replacement.range
        let added = (replacement.text as NSString).length
        if position > NSMaxRange(range)
          || (position == NSMaxRange(range) && (range.length > 0 || !staysBeforeInsertion))
        {
          shift += added - range.length
        } else if position > range.location {
          // 落在被换掉的那一段里面
          return range.location + shift + added
        } else {
          break
        }
      }
      return position + shift
    }
    let start = moved(selection.location, staysBeforeInsertion: selection.length > 0)
    let end = moved(NSMaxRange(selection), staysBeforeInsertion: false)
    return NSRange(location: start, length: max(end - start, 0))
  }

  // MARK: 回车、Tab、自动转换

  /// 回车（没有选区时）：line 是光标所在行（不含行尾的换行），caret 是光标在这一行里的位置。
  /// 列表行、任务行：下一行自动带同样的标记（任务是「☐ 」，无序是同一个符号，有序是下一个数字），保留缩进；
  /// 空的列表项 / 空任务：去掉这一行的标记（留着缩进），退出列表。不是列表行、光标还在标记前面：nil = 照常换行
  static func newline(in line: String, caret: Int) -> Change? {
    let units = Array(line.utf16)
    guard let prefix = prefix(of: units), caret >= prefix.contentStart, caret <= units.count
    else { return nil }
    guard units[prefix.contentStart...].contains(where: { $0 != space && $0 != tab }) else {
      return Change(
        replacements: [
          Replacement(
            range: NSRange(location: prefix.indent, length: units.count - prefix.indent), text: "")
        ], selection: NSRange(location: prefix.indent, length: 0))
    }
    let marker: String
    switch prefix.lead {
    case .task: marker = "\(open) "
    case .bullet(let bullet): marker = "\(bullet) "
    case .ordered(let number, let delimiter): marker = "\(number + 1)\(delimiter) "
    }
    let inserted = "\n" + String(decoding: units[..<prefix.indent], as: UTF16.self) + marker
    return Change(
      replacements: [Replacement(range: NSRange(location: caret, length: 0), text: inserted)],
      selection: NSRange(location: caret + (inserted as NSString).length, length: 0))
  }

  /// 缩进一级是几个空格
  static let indentWidth = 2

  /// Tab / ⇧Tab（没有选区时）：列表行、任务行缩进 / 退回一级（2 个空格；退的时候行首是 Tab 就退那一个 Tab）。
  /// 不是列表行：nil = 照常（Tab 是制表符）。列表行已经没有缩进可退时给一个空的改动（这一下吞掉，不做事）
  static func indent(_ line: String, caret: Int, outdent: Bool) -> Change? {
    let units = Array(line.utf16)
    guard prefix(of: units) != nil else { return nil }
    guard outdent else {
      return Change(
        replacements: [
          Replacement(
            range: NSRange(location: 0, length: 0),
            text: String(repeating: " ", count: indentWidth))
        ], selection: NSRange(location: caret + indentWidth, length: 0))
    }
    let removed =
      units.first == tab ? 1 : min(units.prefix { $0 == space }.count, indentWidth)
    guard removed > 0 else {
      return Change(replacements: [], selection: NSRange(location: caret, length: 0))
    }
    return Change(
      replacements: [Replacement(range: NSRange(location: 0, length: removed), text: "")],
      selection: NSRange(location: max(caret - removed, 0), length: 0))
  }

  /// 打字自动转换：行首（缩进之后）已经是「- [ ]」（或「* [ ]」「+ [ ]」，方括号里是 x 就是做完的）、光标紧跟在后面，
  /// 这时按下空格——不插那个空格，把这五个字换成「☐ 」/「☑ 」（一步撤销，⌘Z 退回「- [ ]」）。
  /// line 是按空格之前的这一行，caret 是光标的位置；不是这种情况给 nil
  static func shorthand(in line: String, caret: Int) -> Change? {
    let units = Array(line.utf16)
    let indent = units.prefix { $0 == space || $0 == tab }.count
    guard caret == indent + 5, units.count >= caret else { return nil }
    let typed = String(decoding: units[indent..<caret], as: UTF16.self)
    guard let bullet = typed.first, "-*+".contains(bullet), typed.dropFirst().hasPrefix(" ["),
      typed.hasSuffix("]")
    else { return nil }
    let mark = typed.dropFirst(3).first
    guard mark == " " || mark == "x" || mark == "X" else { return nil }
    return Change(
      replacements: [
        Replacement(
          range: NSRange(location: indent, length: 5), text: "\(mark == " " ? open : done) ")
      ], selection: NSRange(location: indent + 2, length: 0))
  }

  // MARK: 和 Markdown 互转

  /// 正文 → Markdown：任务行的「☐」换成「- [ ]」、「☑」换成「- [x]」，缩进、后面的字、换行符原样
  static func markdown(from body: String) -> String {
    mapLines(of: body) { line in
      guard let prefix = prefix(of: line), case .task(let isDone) = prefix.lead else {
        return nil
      }
      return Replacement(
        range: NSRange(location: prefix.indent, length: 1), text: isDone ? "- [x]" : "- [ ]")
    }
  }

  /// Markdown → 正文：行首（缩进之后）的「- [ ]」「* [ ]」「+ [ ]」换成「☐」，方括号里是 x / X 的换成「☑」；
  /// 后面得是空格或行尾。正文 → Markdown → 正文往返不变（正文里原样写着「- [ ] 」的行除外：Markdown 里它本来就是任务）
  static func body(fromMarkdown markdown: String) -> String {
    mapLines(of: markdown) { line in
      let units = Array(line.utf16)
      let indent = units.prefix { $0 == space || $0 == tab }.count
      guard units.count >= indent + 5, units.count == indent + 5 || units[indent + 5] == space,
        let change = shorthand(in: line, caret: indent + 5)
      else { return nil }
      // shorthand 给的是「☐ 」（带空格，它替掉的是没打出来的那个空格）；这里空格本来就在，只换标记
      return Replacement(
        range: NSRange(location: indent, length: 5),
        text: String(change.replacements[0].text.prefix(1)))
    }
  }

  /// 一行一行过（换行符原样留着）：change 给这一行里要换的那一段，nil = 这一行不动
  private static func mapLines(of text: String, _ change: (String) -> Replacement?) -> String {
    let source = text as NSString
    let result = NSMutableString(capacity: source.length)
    var location = 0
    while location < source.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      source.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = NSMutableString(
        string: source.substring(with: NSRange(location: start, length: contentsEnd - start)))
      if let replacement = change(line as String) {
        line.replaceCharacters(in: replacement.range, with: replacement.text)
      }
      result.append(line as String)
      result.append(
        source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = end
    }
    return result as String
  }

  // MARK: 进度

  /// 任务做完几条 / 共几条；一条任务都没有是 nil。口径同 prefix(of:)：行首（缩进之后）的方框，后面是空格或行尾。
  /// 列表的每一行都要算它，所以一遍扫完、不拆行不建数组
  static func progress(in body: String) -> (done: Int, total: Int)? {
    var (finished, total) = (0, 0)
    // 还在行首的缩进里；刚读到行首的方框（true = 做完的），等着看它后面是不是空格 / 行尾
    var atLineStart = true
    var pending: Bool?
    func count(_ isDone: Bool) {
      total += 1
      if isDone { finished += 1 }
    }
    for scalar in body.unicodeScalars {
      // 换行符同 NSString 认的那几种
      let isNewline =
        scalar == "\n" || scalar == "\r" || scalar == "\u{85}" || scalar == "\u{2028}"
        || scalar == "\u{2029}"
      if let isDone = pending {
        if scalar == " " || isNewline { count(isDone) }
        pending = nil
      }
      if isNewline {
        atLineStart = true
      } else if atLineStart, scalar != " ", scalar != "\t" {
        atLineStart = false
        if scalar == "\u{2610}" || scalar == "\u{2611}" { pending = scalar == "\u{2611}" }
      }
    }
    if let isDone = pending { count(isDone) }
    return total > 0 ? (finished, total) : nil
  }
}

extension Note {
  /// 这条便签里的任务做完几条 / 共几条（没有任务是 nil）：列表行、悬停预览卡上显示
  var taskProgress: (done: Int, total: Int)? { NoteTasks.progress(in: body) }

  /// 进度写出来的样子：「2 / 5」；旁白读「任务完成 2 项，共 5 项」
  static func progressText(_ progress: (done: Int, total: Int)) -> String {
    "\(progress.done) / \(progress.total)"
  }

  static func progressSpoken(_ progress: (done: Int, total: Int)) -> String {
    "任务完成 \(progress.done) 项，共 \(progress.total) 项"
  }
}
