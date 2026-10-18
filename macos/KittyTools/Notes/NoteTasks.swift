// 便签里的任务和列表（PLAN §10「便签」第 5 批，第 8 批五种状态）：全是纯函数，编辑器（NoteTextView）只管调，单测 NoteTasksTests 锁住。
// - 存储（已定）：正文里任务就是行首的五个方框之一（前面可以有空格 / Tab 缩进）：
//   ☐ 待办、◧ 进行中、▣ 紧急、☑ 完成、☒ 取消。方框后面得是一个空格或者行尾（「☐abc」不算），行中间的方框不算。
//   无序列表项是「- 」「* 」「+ 」开头，有序的是「1. 」「1) 」。
// - 改字的几件事都写成「这一行（或选区碰到的那几行）+ 光标在哪 → 换哪几段、换成什么、换完选区在哪」（Change），
//   位置都是 UTF-16 的、相对给进来的那段文字的开头：⌘T 切换（toggle）、改状态（state）、回车续行和空项退出（newline）、
//   Tab / ⇧Tab 缩进（indent）、打出「- [ ]」再按空格的自动转换（shorthand）。
// - 和 Markdown 互转（第 8 批的导出导入用）：「☐ 」↔「- [ ] 」、「◧ 」↔「- [/] 」、「▣ 」↔「- [!] 」、
//   「☑ 」↔「- [x] 」、「☒ 」↔「- [-] 」，缩进和换行符原样；代码块里的行不换（块里的方框只是字）。
// - 任务进度（做完几条 / 共几条）：做完 = 完成，共 = 除了取消的全部；只有取消的没有进度。列表行和预览卡上显示。
// 交互借自 Noty（MIT；只借思路，一行代码都不拷）；不照它的两处：⌘T 不是三态循环，就是「普通行 ↔ 任务」；
// 方框后面要跟空格才算任务。
//
// 五种状态（2026-10-17 第 8 批，拍板 B）：
//   待办 ☐ U+2610、进行中 ◧ U+25E7、紧急 ▣ U+25A3、完成 ☑ U+2611、取消 ☒ U+2612。
//   完成 / 取消算「关掉了」（内容划线变淡）；除了取消都算「进度」。点方框：待办 / 进行中 / 紧急 → 完成，
//   完成 / 取消 → 待办；右键点方框只弹这五种；正文菜单的「任务状态」作用于选区碰到的每一行。
// 紧急是红的（NoteStyles 出颜色）；进行中是半实心、紧急是方框里一个实心小方块，不只靠颜色分（色弱的人看形状）。

import Foundation

nonisolated enum NoteTasks {
  /// 五种状态
  enum State: Int, CaseIterable, Sendable {
    case todo, doing, urgent, done, cancelled

    /// 存进正文的那个字
    var character: Character {
      switch self {
      case .todo: "☐"
      case .doing: "◧"
      case .urgent: "▣"
      case .done: "☑"
      case .cancelled: "☒"
      }
    }

    /// 菜单、旁白里的名字
    var title: String {
      switch self {
      case .todo: "待办"
      case .doing: "进行中"
      case .urgent: "紧急"
      case .done: "完成"
      case .cancelled: "取消"
      }
    }

    /// Markdown 的方括号里那个字（导出 / 导入时换）
    var markdown: String {
      switch self {
      case .todo: " "
      case .doing: "/"
      case .urgent: "!"
      case .done: "x"
      case .cancelled: "-"
      }
    }

    /// 算不算关掉了：完成 / 取消（内容划线、变淡）
    var isClosed: Bool { self == .done || self == .cancelled }

    /// 算不算进度：除了取消都算
    var countsAsProgress: Bool { self != .cancelled }

    init?(character: Character) {
      guard let found = Self.allCases.first(where: { $0.character == character }) else {
        return nil
      }
      self = found
    }

    /// Markdown 方括号里那个字 → 状态（大小写都认 x）
    init?(markdown: Character) {
      let unit = String(markdown).lowercased()
      guard let found = Self.allCases.first(where: { $0.markdown == unit }) else { return nil }
      self = found
    }
  }

  private static let space: UInt16 = 0x20
  private static let tab: UInt16 = 0x09

  /// 行首（缩进之后）的列表标记是哪种
  enum Lead: Equatable, Sendable {
    case task(State)
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

  /// 同上，给已经拆成 UTF-16 的一行（样式那边一行只拆一次）
  static func prefix(of units: [UInt16]) -> Prefix? {
    let indent = units.prefix { $0 == space || $0 == tab }.count
    guard indent < units.count else { return nil }
    let first = units[indent]
    let follower = indent + 1 < units.count ? units[indent + 1] : nil
    if let scalar = UnicodeScalar(first), let state = State(character: Character(scalar)) {
      // 方框后面是空格或行尾才算（「☐abc」是别处贴来的符号，不当任务）
      guard follower == nil || follower == space else { return nil }
      return Prefix(
        indent: indent, lead: .task(state), markerLength: 1, hasSpace: follower != nil)
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

  /// 这一行的任务是什么状态（不是任务给 nil）
  static func state(of line: String) -> State? {
    guard let prefix = prefix(of: line), case .task(let state) = prefix.lead else { return nil }
    return state
  }

  /// 点方框：待办 / 进行中 / 紧急 → 完成；完成 / 取消 → 待办（一步撤销，光标不动）
  static func flipped(_ box: Character) -> Character {
    guard let state = State(character: box) else { return box }
    return (state.isClosed ? State.todo : State.done).character
  }

  // MARK: ⌘T 和「任务状态」

  /// ⌘T：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头。
  /// 都已经是任务（五种都算）→ 都去掉标记；否则把还不是任务的变成待办：保留缩进，原来是「- 」「* 」「+ 」开头的无序列表项
  /// 就把那个符号换成 ☐，别的在缩进后面加「☐ 」。选了好几行时空行不算数、也不动（同编辑器里「注释 / 取消注释」的做法）；
  /// 只有一行时空行也变成任务（先按 ⌘T 再打字）。没有可改的给 nil
  static func toggle(_ block: String, selection: NSRange) -> Change? {
    let lines = linesInBlock(block)
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
            range: NSRange(location: line.start + prefix.indent, length: 1),
            text: String(State.todo.character)))
      } else {
        let indent = line.units.prefix { $0 == space || $0 == tab }.count
        replacements.append(
          Replacement(
            range: NSRange(location: line.start + indent, length: 0),
            text: "\(State.todo.character) "))
      }
    }
    guard !replacements.isEmpty else { return nil }
    return Change(replacements: replacements, selection: mapped(selection, through: replacements))
  }

  /// 右键菜单「任务状态 ›」：把选区碰到的每一行改成 state。已经是这种状态的跳过；不是任务的变成这种状态的任务
  /// （保留缩进，- * + 的符号换掉，别的在缩进后面加方框；选了好几行时空行不动，只有一行时空行也变成任务）。
  /// 一行都不用改时给 nil（编辑器响一声）。代码块由编辑器先挡掉
  static func setState(_ state: State, in block: String, selection: NSRange) -> Change? {
    let lines = linesInBlock(block)
    let candidates =
      lines.count == 1
      ? lines : lines.filter { !$0.units.allSatisfy { $0 == space || $0 == tab } }
    guard !candidates.isEmpty else { return nil }
    var replacements: [Replacement] = []
    for line in candidates {
      let prefix = prefix(of: line.units)
      if case .task(let current) = prefix?.lead {
        guard current != state else { continue }
        replacements.append(
          Replacement(
            range: NSRange(location: line.start + (prefix?.indent ?? 0), length: 1),
            text: String(state.character)))
      } else if let prefix, case .bullet = prefix.lead {
        replacements.append(
          Replacement(
            range: NSRange(location: line.start + prefix.indent, length: 1),
            text: String(state.character)))
      } else {
        let indent = prefix?.indent ?? line.units.prefix { $0 == space || $0 == tab }.count
        replacements.append(
          Replacement(
            range: NSRange(location: line.start + indent, length: 0),
            text: "\(state.character) "))
      }
    }
    guard !replacements.isEmpty else { return nil }
    return Change(replacements: replacements, selection: mapped(selection, through: replacements))
  }

  /// 选区碰到的每一行是任务的话，都是同一种状态时给那种（菜单里打勾）；没有任务、或不一样给 nil
  static func state(in block: String, selection: NSRange) -> State? {
    let text = block as NSString
    var found: State?
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let lineRange = NSRange(location: start, length: contentsEnd - start)
      let touched =
        selection.length == 0
        ? NSLocationInRange(selection.location, lineRange)
          || selection.location == NSMaxRange(lineRange)
        : NSIntersectionRange(lineRange, selection).length > 0
      if touched {
        let line = text.substring(with: lineRange)
        if let state = Self.state(of: line) {
          if let found, found != state { return nil }
          found = state
        }
      }
      location = max(end, location + 1)
    }
    return found
  }

  /// 选区的改动挪到哪：在某一处替换后面的往后 / 往前让，落在被换掉的那一段里面的收到那一段的新末尾。
  /// 光标（长度 0）正好停在插入点上时挪到插进去的字后面；一段选区的开头停在插入点上时不挪（选区照旧盖着整行）
  static func mapped(_ selection: NSRange, through replacements: [Replacement]) -> NSRange {
    let start = mappedPosition(
      selection.location, through: replacements, staysBeforeInsertion: selection.length > 0)
    let end = mappedPosition(
      NSMaxRange(selection), through: replacements, staysBeforeInsertion: false)
    return NSRange(location: start, length: max(end - start, 0))
  }

  /// 一个位置经过这些替换之后在哪。staysBeforeInsertion：正好停在插入点上时不往后挪（一段选区的开头、结尾用）
  static func mappedPosition(
    _ position: Int, through replacements: [Replacement], staysBeforeInsertion: Bool
  ) -> Int {
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

  // MARK: 回车、Tab、自动转换

  /// 回车（没有选区时）：line 是光标所在行（不含行尾的换行），caret 是光标在这一行里的位置。
  /// 列表行、任务行：下一行自动带同样的标记（任务一律是「☐ 」，无序是同一个符号，有序是下一个数字），保留缩进；
  /// 空的列表项 / 空任务（任何状态）：去掉这一行的标记（留着缩进），退出列表。不是列表行、光标还在标记前面：nil = 照常换行
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
    case .task: marker = "\(State.todo.character) "
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

  /// 打字自动转换：行首（缩进之后）已经是「- [ ]」（或「* [ ]」「+ [ ]」，方括号里是 /、!、x、- 就是别的状态）、
  /// 光标紧跟在后面，这时按下空格——不插那个空格，把这五个字换成对应的方框 + 空格（一步撤销，⌘Z 退回「- [ ]」）。
  /// line 是按空格之前的这一行，caret 是光标的位置；不是这种情况给 nil
  static func shorthand(in line: String, caret: Int) -> Change? {
    let units = Array(line.utf16)
    let indent = units.prefix { $0 == space || $0 == tab }.count
    guard caret == indent + 5, units.count >= caret else { return nil }
    let typed = String(decoding: units[indent..<caret], as: UTF16.self)
    guard let bullet = typed.first, "-*+".contains(bullet), typed.dropFirst().hasPrefix(" ["),
      typed.hasSuffix("]")
    else { return nil }
    let mark = typed.dropFirst(3).first ?? " "
    guard let state = State(markdown: mark) else { return nil }
    return Change(
      replacements: [
        Replacement(
          range: NSRange(location: indent, length: 5), text: "\(state.character) ")
      ], selection: NSRange(location: indent + 2, length: 0))
  }

  // MARK: 和 Markdown 互转

  /// 正文 → Markdown：任务行的方框换成「- [ ]」「- [/]」「- [!]」「- [x]」「- [-]」，缩进、后面的字、换行符原样。
  /// **代码块里的行不换**（块里的方框只是字）：照 NoteMarkdown.codeBlocks 认，围栏行和块里的行都跳过
  static func markdown(from body: String) -> String {
    let blocks = codeBlocks(in: body)
    return mapLines(of: body, blocks: blocks) { line, _ in
      guard let prefix = prefix(of: line), case .task(let state) = prefix.lead else {
        return nil
      }
      return Replacement(
        range: NSRange(location: prefix.indent, length: 1), text: "- [\(state.markdown)]")
    }
  }

  /// Markdown → 正文：行首（缩进之后）的「- [ ]」「- [/]」「- [!]」「- [x]」「- [-]」（`*` `+` 开头也算）换成方框；
  /// 后面得是空格或行尾。代码块里的行不换。正文 → Markdown → 正文往返不变（正文里原样写着「- [ ] 」的行除外：
  /// Markdown 里它本来就是任务）
  static func body(fromMarkdown markdown: String) -> String {
    let blocks = codeBlocks(in: markdown)
    return mapLines(of: markdown, blocks: blocks) { line, _ in
      let units = Array(line.utf16)
      let indent = units.prefix { $0 == space || $0 == tab }.count
      guard units.count >= indent + 5, units.count == indent + 5 || units[indent + 5] == space
      else { return nil }
      let typed = String(decoding: units[indent..<(indent + 5)], as: UTF16.self)
      guard let bullet = typed.first, "-*+".contains(bullet), typed.dropFirst().hasPrefix(" ["),
        typed.hasSuffix("]"), let mark = typed.dropFirst(3).first,
        let state = State(markdown: mark)
      else { return nil }
      return Replacement(
        range: NSRange(location: indent, length: 5), text: String(state.character))
    }
  }

  /// 正文里认出来的代码块（只在真的可能有围栏时才整篇认一遍：绝大多数便签没有代码块）
  private static func codeBlocks(in text: String) -> [NoteMarkdown.CodeBlock] {
    guard text.contains("```") || text.contains("~~~") else { return [] }
    return NoteMarkdown.codeBlocks(in: text as NSString)
  }

  /// 一行一行过（换行符原样留着）：change 给这一行里要换的那一段，nil = 这一行不动。代码块里的行（围栏行、块里的行）
  /// 一律不动
  private static func mapLines(
    of text: String, blocks: [NoteMarkdown.CodeBlock],
    _ change: (String, Int) -> Replacement?
  ) -> String {
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
      if NoteMarkdown.role(at: start, in: blocks) == nil,
        let replacement = change(line as String, start)
      {
        line.replaceCharacters(in: replacement.range, with: replacement.text)
      }
      result.append(line as String)
      result.append(
        source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = end
    }
    return result as String
  }

  /// 把 block 拆成行（每行的 start 相对 block 的开头；不含行尾的换行；block 以换行结尾时后面的空行也算一行）
  private static func linesInBlock(_ block: String) -> [(start: Int, units: [UInt16])] {
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
      if end == text.length, contentsEnd < end { lines.append((end, [])) }
      location = end
    } while location < text.length
    return lines
  }

  // MARK: 进度

  /// 任务做完几条 / 共几条；一条都不算（没有任务、只有取消的）是 nil。口径同 prefix(of:)：行首（缩进之后）的方框，
  /// 后面是空格或行尾；**代码块里的行不算**（块里的方框只是字）
  static func progress(in body: String) -> (done: Int, total: Int)? {
    let text = body as NSString
    let blocks = codeBlocks(in: body)
    var (finished, total) = (0, 0)
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      if NoteMarkdown.role(at: start, in: blocks) == nil {
        let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
        if let state = Self.state(of: line), state.countsAsProgress {
          total += 1
          if state == .done { finished += 1 }
        }
      }
      location = max(end, location + 1)
    }
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
