// 便签正文里的 Markdown（PLAN §10「便签」第 6 批，拍板 C① 第二步「边打边变样」）：认标记的扫描器。全是纯函数、
// **不用正则**，一遍从左到右扫完；位置都是 UTF-16 的。样式怎么叠、换成什么属性在 NoteStyles，这里只管「哪一段是什么」。
// 除了代码块，所有语法都不跨行：一行一行扫和整篇扫结果一样（NoteStyles 按行重排靠这一条）；代码块（codeBlocks）
// 是唯一跨行的，整篇认一遍、每一行拿到自己的角色（开头的围栏 / 块里 / 收尾的围栏），块里的行不再按 Markdown 扫。
// - 块（行首，前面最多 3 个空格）：标题 `#`…`######` 后面跟空白、再后面得有字（只有「# 」的不算——标记藏起来之后
//   这一行就什么都看不见了）；引用 `>`（单层，后面的一个空格算标记，可以没有内容——那时 `>` 不藏，NoteStyles.spans）。
//   无序列表的符号、任务的方框由 NoteTasks 认。
// - 行内：行内代码（反引号，几个开就几个关）、粗体 `**` `__`、斜体 `*` `_`、删除线 `~~`、链接 `[字](地址)`。
//   代码先认，代码里的 `*` `_` `~` `[` 都不是标记；前面有反斜杠的标点不算标记（反斜杠照常显示）；没配对的原样显示。
//   `*` 可以在词中间，开头的标记后面、结尾的标记前面不能是空白；`_` `__` 两边还得不是字（字母、数字、汉字）——
//   `snake_case_name` 里的下划线不是斜体。**紧挨着的前一个字和后一个字都是 ASCII 数字的一串 `*` 不是标记**（既不开
//   也不关）：`2*3*4`、`箱子 60*40*30` 是乘号，当成斜体藏起来就读成「604030」了；`*3*`、`第**3**个` 照常。
//   `***又粗又斜***` 两层都认。空的强调凑不出来（`****`、`__` 是一整串标记，自己配不了自己）。
// - 链接：方括号可以套、地址里的括号成对就行；地址里不能有空白（`[字](地址 "标题")` 不认）、字和地址都不能是空的；
//   链接的字里不再认链接。`![…](…)` 是图片（第 7 批），这里原样显示，里面什么都不认。
// - 代码块（便签手测反馈第 4 批）：行首（前面最多 3 个空格）三个以上的反引号或波浪号开一个块，同一种字符、不少于
//   开头个数、后面只有空白的那一行关；开头那行后面可以跟语言名（只显示）。**只认配上了对的**（codeBlocks 那里写了为什么）。
// - plain(_:)：把一行里的标记去掉，给标题和摘要用（Note.displayTitle / preview）。
// - 加标记的快捷键（⌘B ⌘I ⇧⌘X ⌘E，toggle）和粘贴网址成链接（linkPaste）的规则：纯函数，编辑器（NoteTextView）只管调。
// 不做（PLAN §10「便签」的「不做 / 以后再说」）：表格、斜杠菜单、自动补全成对符号、代码的语法高亮、有序列表的样式、
// 分隔线、裸网址自动成链接、引用嵌套。
// ponytail: 强调的定界没照 CommonMark，差在这几处——紧挨着的 `*a**b**c*` 按就近配对（它的「3 的倍数」规则没做）；
// 标点旁边的 `*` 不另算；数字中间的 `*` 一律不算（它那里 `2*3*4` 是斜体）。照了它的一处反而是已知的取舍：`__init__`
// 是粗体（要原样就写进反引号里）。上限：这几种写法和别的 Markdown 工具画出来的不一样；真有人在意，再把 emphasis
// 照它的「左 / 右定界」规则重写。
// ponytail: 链接地址最多 addressLimit 个字（再长的不当链接）——一行里全是「](」的怪文字不至于越扫越慢。
// 没关上的反引号要往后找到行尾：一行里塞满长度各不相同的反引号串时是 n 的 1.5 次方（1 MB 的一行约一秒），
// 真碰上了再记「这么长的串后面没有了」。

import Foundation

nonisolated enum NoteMarkdown {
  private static let space: UInt16 = 0x20
  private static let tab: UInt16 = 0x09
  private static let bang: UInt16 = 0x21
  private static let hash: UInt16 = 0x23
  private static let openParen: UInt16 = 0x28
  private static let closeParen: UInt16 = 0x29
  private static let star: UInt16 = 0x2A
  private static let greater: UInt16 = 0x3E
  private static let openBracket: UInt16 = 0x5B
  private static let backslash: UInt16 = 0x5C
  private static let closeBracket: UInt16 = 0x5D
  private static let underscore: UInt16 = 0x5F
  private static let backtick: UInt16 = 0x60
  private static let tilde: UInt16 = 0x7E

  /// 链接地址最多这么长（UTF-16）
  static let addressLimit = 2000

  private typealias Span = NoteStyles.Span

  /// 空白：空格、Tab、不换行空格、全角空格（中文输入法打出来的）
  private static func isBlank(_ unit: UInt16) -> Bool {
    unit == space || unit == tab || unit == 0xA0 || unit == 0x3000
  }

  /// ASCII 标点：反斜杠只转义这些
  private static func isPunctuation(_ unit: UInt16) -> Bool {
    (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit)
      || (0x7B...0x7E).contains(unit)
  }

  /// ASCII 数字：两边都是它的星号是乘号，不算强调
  private static func isDigit(_ unit: UInt16?) -> Bool {
    unit.map { (0x30...0x39).contains($0) } ?? false
  }

  /// 是不是「字」（字母、数字、汉字…）：下划线两边是字就不算强调。代理对（表情、生僻字）不算字
  private static func isWord(_ unit: UInt16?) -> Bool {
    guard let unit, let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
  }

  // MARK: 块

  /// 标题：级别（1–6）和标记的区间（那几个 # 连后面的空白）。不是标题给 nil
  static func heading(_ units: [UInt16]) -> (level: Int, marker: NSRange)? {
    let indent = units.prefix { $0 == space }.count
    let hashes = units[indent...].prefix { $0 == hash }.count
    guard indent <= 3, (1...6).contains(hashes) else { return nil }
    let blanks = units[(indent + hashes)...].prefix(while: isBlank).count
    // 后面得跟空白（「#标签」不算），再后面得有字
    guard blanks > 0, indent + hashes + blanks < units.count else { return nil }
    return (hashes, NSRange(location: indent, length: hashes + blanks))
  }

  /// 引用：标记的区间（`>` 连后面的一个空格）。不是引用给 nil
  static func quote(_ units: [UInt16]) -> NSRange? {
    let indent = units.prefix { $0 == space }.count
    guard indent <= 3, indent < units.count, units[indent] == greater else { return nil }
    let hasSpace = indent + 1 < units.count && isBlank(units[indent + 1])
    return NSRange(location: indent, length: hasSpace ? 2 : 1)
  }

  // MARK: 行内

  /// 一串强调标记（`*` `_` `~` 连着的几个）
  private struct Delimiter {
    let unit: UInt16
    /// 还没用掉的那一段从哪开始、有几个
    var start: Int
    var count: Int
    let canOpen: Bool
    let canClose: Bool
  }

  /// 还没配上的「[」
  private struct Bracket {
    /// 「[」在哪（图片是它前面的「!」后面那个）
    let position: Int
    let isImage: Bool
    /// 遇到它的时候已经出了几段样式、攒了几串强调标记：配成链接时里面的强调单独配，配成图片时里面的都不要
    let spanCount: Int
    let delimiterCount: Int
  }

  /// units 里 bounds 那一段的行内样式：粗体、斜体、删除线、代码、链接，和各自的标记（.marker）
  static func inline(_ units: [UInt16], in bounds: Range<Int>) -> [NoteStyles.Span] {
    var spans: [Span] = []
    var delimiters: [Delimiter] = []
    var brackets: [Bracket] = []
    // brackets 里排在这个数前面的「[」已经作废（它们后面配成了链接：链接里不套链接）；图片的不受它管
    var voided = 0
    let end = bounds.upperBound
    var index = bounds.lowerBound

    func run(of unit: UInt16, at start: Int) -> Int {
      var length = 1
      while start + length < end, units[start + length] == unit { length += 1 }
      return length
    }
    func marker(_ location: Int, _ length: Int) -> Span {
      Span(range: NSRange(location: location, length: length), kind: .marker)
    }

    while index < end {
      let unit = units[index]
      switch unit {
      case backslash:
        // 反斜杠后面的标点不算标记：两个都跳过（都照常显示）
        index += index + 1 < end && isPunctuation(units[index + 1]) ? 2 : 1

      case backtick:
        // 行内代码：往后找一串同样长的反引号；找不到就是普通的字
        let length = run(of: backtick, at: index)
        var close = index + length
        var found = false
        while close < end {
          guard units[close] == backtick else {
            close += 1
            continue
          }
          let closing = run(of: backtick, at: close)
          if closing == length {
            found = true
            break
          }
          close += closing
        }
        if found {
          spans.append(marker(index, length))
          spans.append(
            Span(
              range: NSRange(location: index + length, length: close - index - length), kind: .code)
          )
          spans.append(marker(close, length))
          index = close + length
        } else {
          index += length
        }

      case bang where index + 1 < end && units[index + 1] == openBracket:
        brackets.append(
          Bracket(
            position: index + 1, isImage: true, spanCount: spans.count,
            delimiterCount: delimiters.count))
        index += 2

      case openBracket:
        brackets.append(
          Bracket(
            position: index, isImage: false, spanCount: spans.count,
            delimiterCount: delimiters.count))
        index += 1

      case closeBracket:
        guard let bracket = brackets.popLast() else {
          index += 1
          break
        }
        let isVoid = !bracket.isImage && brackets.count < voided
        voided = min(voided, brackets.count)
        let text = (bracket.position + 1)..<index
        guard !isVoid, let address = address(units, after: index, end: end),
          units[text].contains(where: { !isBlank($0) })
        else {
          index += 1
          break
        }
        if bracket.isImage {
          // 图片（第 7 批）：原样显示，里面认出来的都不要
          spans.removeSubrange(bracket.spanCount...)
          delimiters.removeSubrange(bracket.delimiterCount...)
        } else {
          // 链接的字里的强调自己配，不和外面的配
          spans += emphasis(Array(delimiters[bracket.delimiterCount...]))
          delimiters.removeSubrange(bracket.delimiterCount...)
          spans.append(marker(bracket.position, 1))
          spans.append(
            Span(
              range: NSRange(location: text.lowerBound, length: text.count),
              kind: .link(String(decoding: units[address], as: UTF16.self))))
          // 「](地址)」
          spans.append(marker(index, address.upperBound + 1 - index))
          // 链接里不套链接：前面还开着的「[」作废（图片的留着：图片的说明里可以有链接的写法）
          voided = brackets.count
        }
        index = address.upperBound + 1

      case star, underscore, tilde:
        let length = run(of: unit, at: index)
        let before = index > bounds.lowerBound ? units[index - 1] : nil
        let after = index + length < end ? units[index + length] : nil
        // 开头的标记后面不能是空白，结尾的标记前面不能是空白；下划线两边还得不是字
        var canOpen = after.map { !isBlank($0) } ?? false
        var canClose = before.map { !isBlank($0) } ?? false
        if unit == underscore {
          canOpen = canOpen && !isWord(before)
          canClose = canClose && !isWord(after)
        }
        // 两边都是数字的一串星号是乘号（2*3*4、60*40*30）：既不开也不关
        let isTimes = unit == star && isDigit(before) && isDigit(after)
        // 删除线只认正好两个波浪号
        if !isTimes, unit != tilde || length == 2 {
          delimiters.append(
            Delimiter(
              unit: unit, start: index, count: length, canOpen: canOpen, canClose: canClose))
        }
        index += length

      default:
        index += 1
      }
    }
    return spans + emphasis(delimiters)
  }

  /// 「]」后面是不是紧跟着「(地址)」：给地址的区间（不含括号）。地址里不能有空白，括号要成对，不能是空的
  private static func address(_ units: [UInt16], after close: Int, end: Int) -> Range<Int>? {
    guard close + 1 < end, units[close + 1] == openParen else { return nil }
    let start = close + 2
    var depth = 0
    var index = start
    // 地址最长 addressLimit：收尾的「)」最远在 start + addressLimit
    while index < min(end, start + addressLimit + 1) {
      let unit = units[index]
      if isBlank(unit) { return nil }
      if unit == backslash, index + 1 < end, isPunctuation(units[index + 1]) {
        index += 2
        continue
      }
      if unit == openParen {
        depth += 1
      } else if unit == closeParen {
        if depth == 0 { return index > start ? start..<index : nil }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  /// 把一串串强调标记配成对（从左到右，结尾的标记找离它最近的、同一种字符的开头）：两边都还有两个以上就是粗体
  /// （用掉两个），否则是斜体（用掉一个）；`~~` 是删除线。配上的一对中间夹着的开头标记作废（样式不交叉）
  private static func emphasis(_ delimiters: [Delimiter]) -> [NoteStyles.Span] {
    var runs = delimiters
    var spans: [Span] = []
    // 三种字符各一摞还开着的开头标记（存的是 runs 的下标）
    var openers: [UInt16: [Int]] = [star: [], underscore: [], tilde: []]
    for current in runs.indices {
      let unit = runs[current].unit
      if runs[current].canClose {
        while runs[current].count > 0, let opener = openers[unit]?.last {
          let use = unit == tilde || min(runs[opener].count, runs[current].count) >= 2 ? 2 : 1
          // 开头那一串从里面（靠内容的一头）用起，结尾那一串从前面用起
          let open = runs[opener].start + runs[opener].count - use
          let close = runs[current].start
          let kind: NoteStyles.Kind = unit == tilde ? .strike : use == 2 ? .bold : .italic
          spans.append(Span(range: NSRange(location: open, length: use), kind: .marker))
          spans.append(
            Span(range: NSRange(location: open + use, length: close - open - use), kind: kind))
          spans.append(Span(range: NSRange(location: close, length: use), kind: .marker))
          runs[opener].count -= use
          runs[current].start += use
          runs[current].count -= use
          for key in [star, underscore, tilde] {
            while let top = openers[key]?.last, top > opener { openers[key]?.removeLast() }
          }
          if runs[opener].count == 0 { openers[unit]?.removeLast() }
        }
      }
      if runs[current].canOpen, runs[current].count > 0 { openers[unit]?.append(current) }
    }
    return spans
  }

  // MARK: 代码块（便签手测反馈第 4 批）

  /// 围栏行：行首（前面最多 3 个空格）三个以上同一种的反引号或波浪号。count 是几个，isBare = 后面只有空白
  /// （能当收尾的那一行；开头那行后面可以跟语言名，只显示）
  struct Fence: Equatable, Sendable {
    var mark: UInt16
    var count: Int
    var isBare: Bool
  }

  /// 代码块里一行的角色
  enum Role: Int, Sendable {
    /// 开头的围栏行
    case open = 1
    /// 块里的行
    case content
    /// 收尾的围栏行
    case close
  }

  /// 一个配上了对的代码块：开头、收尾那两行（整行，连行尾的换行；位置是 UTF-16 的）
  struct CodeBlock: Equatable, Sendable {
    var open: NSRange
    var close: NSRange

    /// 整块：开头那行的行首到收尾那行的行尾（连换行）
    var range: NSRange {
      NSRange(location: open.location, length: NSMaxRange(close) - open.location)
    }

    /// 行首在 lineStart 的那一行在这一块里是什么（不在这一块里给 nil）。开头的围栏是空的（长度 0：便签墙的卡片只带
    /// 正文的一段，块的开头被截在这一段前面，NoteWall.excerpt）时没有开头那一行，这一段的第一行是块里的字
    func role(at lineStart: Int) -> Role? {
      guard NSLocationInRange(lineStart, range) else { return nil }
      if lineStart == open.location, open.length > 0 { return .open }
      return lineStart == close.location ? .close : .content
    }
  }

  /// 这一行（不含行尾的换行，count 个字，按位置取：整篇扫的时候不为每一行建数组）是不是围栏行。反引号的围栏后面
  /// 不能再有反引号（「```a```」是一行里的行内代码）
  static func fence(count: Int, at unit: (Int) -> UInt16) -> Fence? {
    var index = 0
    while index < count, index < 4, unit(index) == space { index += 1 }
    guard index <= 3, index < count else { return nil }
    let mark = unit(index)
    guard mark == backtick || mark == tilde else { return nil }
    var run = 0
    while index + run < count, unit(index + run) == mark { run += 1 }
    guard run >= 3 else { return nil }
    var isBare = true
    for position in (index + run)..<count {
      let current = unit(position)
      if mark == backtick, current == backtick { return nil }
      if !isBlank(current) {
        isBare = false
        if mark == tilde { break }
      }
    }
    return Fence(mark: mark, count: run, isBare: isBare)
  }

  /// 正文里的代码块（从前到后）。**只认配上了对的**：开头的围栏往后找第一行「同一种字符、不少于开头个数、后面只有空白」
  /// 的围栏收尾，中间夹着的都是块里的字（别的围栏也是）；找不到收尾的那一行不是开头、照普通的一行显示，接着往下找。
  /// （CommonMark 是没关上就一直到正文末尾——边打边变样时，刚打出开头的三个反引号，后面整篇就突然都成了代码。）
  /// ponytail: 找收尾是在同一种字符的「能收尾的围栏」里往后走、跳过个数不够的；找不到时记下「这种字符、不少于几个」
  /// 再往后都不会有，后面同样或更多的开头直接跳过。上限：开头的个数一路递减（1000、999…个反引号的开头一行行往下排）
  /// 时每一行都要走一遍——几十万个反引号才碰得到，真碰上再改成按个数分桶。
  static func codeBlocks(in text: NSString) -> [CodeBlock] {
    var fences: [(line: NSRange, fence: Fence)] = []
    let length = text.length
    var location = 0
    while location < length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      // 先看行首几个字：绝大多数行到这里就不是了，不取整行
      if let found = fence(count: contentsEnd - start, at: { text.character(at: start + $0) }) {
        fences.append((NSRange(location: start, length: end - start), found))
      }
      location = max(end, location + 1)
    }
    // 每种字符能当收尾的围栏（fences 里的下标，从前到后）
    var closers: [UInt16: [Int]] = [:]
    for (index, item) in fences.enumerated() where item.fence.isBare {
      closers[item.fence.mark, default: []].append(index)
    }
    // 某种字符「不少于几个」的收尾在后面已经找不到了
    var hopeless: [UInt16: Int] = [:]
    var blocks: [CodeBlock] = []
    var index = 0
    while index < fences.count {
      let opener = fences[index].fence
      guard opener.count < hopeless[opener.mark] ?? .max, let candidates = closers[opener.mark]
      else {
        index += 1
        continue
      }
      // 排在开头后面的第一个
      var low = 0
      var high = candidates.count
      while low < high {
        let middle = (low + high) / 2
        if candidates[middle] <= index { low = middle + 1 } else { high = middle }
      }
      var found: Int?
      for candidate in candidates[low...] where fences[candidate].fence.count >= opener.count {
        found = candidate
        break
      }
      guard let close = found else {
        hopeless[opener.mark] = opener.count
        index += 1
        continue
      }
      blocks.append(CodeBlock(open: fences[index].line, close: fences[close].line))
      index = close + 1
    }
    return blocks
  }

  /// 行首在 lineStart 的那一行在不在代码块里、是什么角色（blocks 从前到后排好）
  static func role(at lineStart: Int, in blocks: [CodeBlock]) -> Role? {
    var low = 0
    var high = blocks.count
    while low < high {
      let middle = (low + high) / 2
      if NSMaxRange(blocks[middle].range) <= lineStart { low = middle + 1 } else { high = middle }
    }
    return low < blocks.count ? blocks[low].role(at: lineStart) : nil
  }

  // MARK: 加标记的快捷键（⌘B ⌘I ⇧⌘X ⌘E）

  /// 四种：粗体、斜体、删除线、行内代码
  enum Wrap: Int, CaseIterable, Sendable {
    case bold, italic, strike, code

    /// 两头各加的那一串
    var marker: String {
      switch self {
      case .bold: "**"
      case .italic: "*"
      case .strike: "~~"
      case .code: "`"
      }
    }

    /// 右键菜单「格式」里的名字
    var title: String {
      switch self {
      case .bold: "粗体"
      case .italic: "斜体"
      case .strike: "删除线"
      case .code: "代码"
      }
    }

    /// 扫描器认出来的这种样式（「已经包着」问的是它）
    var kind: NoteStyles.Kind {
      switch self {
      case .bold: .bold
      case .italic: .italic
      case .strike: .strike
      case .code: .code
      }
    }
  }

  /// 一行开头的块标记（标题的 #、引用的 >、列表的符号和任务的方框，连后面的空白）到哪为止：加标记从这后面算起，
  /// 不把「- 」「# 」包进去
  static func contentStart(of units: [UInt16]) -> Int {
    if let prefix = NoteTasks.prefix(of: units) { return prefix.contentStart }
    if let heading = heading(units) { return NSMaxRange(heading.marker) }
    if let quote = quote(units) { return NSMaxRange(quote) }
    return 0
  }

  /// ⌘B 这几个键：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头。
  /// - 没有选区：在光标处插一对标记、光标放中间；光标正夹在一对空的标记中间时（刚按过一次、还没打字）把这对删掉。
  /// - 有选区：每一行各自包（Markdown 的样式不跨行）——包的是选区在这一行里的那一段，去掉两头的空白、跳过行首的块标记、
  ///   去掉选进来的这种标记；这一段已经是这种样式的（扫描器认出来的，wrapping），就去掉它两头的标记；几段里有一段还没包，
  ///   就把没包的都包上，都包着才都去掉（同 ⌘T）。改完选中的是里面的字（不含标记）。
  /// 「已经包着」不数字符、问扫描器（inline）：数字中间的星号是乘号（`60*40*30` 选中 40 按 ⌘I 不会把两个乘号当成斜体
  /// 删掉），挨着的两段（`**a**|**b**`）中间的标记各归各的。斜体只认单数个星号由扫描器的配对定（粗体上按 ⌘I 是又粗又斜，
  /// 又粗又斜里按 ⌘I 去掉斜体）。都是空白、没有可包的给 nil。位置都是 UTF-16 的
  static func toggle(_ wrap: Wrap, in block: String, selection: NSRange) -> NoteTasks.Change? {
    let text = block as NSString
    let units = Array(block.utf16)
    let marker = wrap.marker
    let size = (marker as NSString).length
    let mark = marker.utf16.first ?? 0
    // [from, to) 里从 position 往后 / 往前连着几个 mark
    func run(from position: Int, to limit: Int) -> Int {
      var count = 0
      while position + count < limit, units[position + count] == mark { count += 1 }
      return count
    }
    func run(before position: Int, to limit: Int) -> Int {
      var count = 0
      while position - count > limit, units[position - count - 1] == mark { count += 1 }
      return count
    }
    // 第 location 个字所在的行：内容从哪开始（跳过块标记）、到哪为止
    func line(at location: Int) -> (content: Int, end: Int) {
      var (start, contentsEnd) = (0, 0)
      text.getLineStart(
        &start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let head = Array(units[start..<contentsEnd])
      return (start + contentStart(of: head), contentsEnd)
    }
    /// 扫描器在这一行里认出来的这种样式里，有没有一段正好是 inner：内容去掉两头紧挨着的别的标记（又粗又斜的 `***粗***`
    /// 里斜体的内容是「**粗**」）之后就是 inner。有就给它两头的那一对标记（要去掉的就是它们），没有给 nil
    func wrapping(_ inner: NSRange, in spans: [Span]) -> (open: NSRange, close: NSRange)? {
      let markers = spans.filter { $0.kind == .marker }.map(\.range)
      for span in spans where span.kind == wrap.kind {
        var core = span.range
        while let inside = markers.first(where: {
          $0.location == core.location && $0.length <= core.length
        }) {
          core = NSRange(location: NSMaxRange(inside), length: core.length - inside.length)
        }
        while let inside = markers.first(where: {
          NSMaxRange($0) == NSMaxRange(core) && $0.length <= core.length
        }) {
          core.length -= inside.length
        }
        // 这一对：紧挨着这一段的两头（强调的标记长度就是加的那一串，代码的是几个反引号）
        let fits = { (range: NSRange) in wrap == .code || range.length == size }
        guard core == inner,
          let open = markers.first(where: { NSMaxRange($0) == span.range.location && fits($0) }),
          let close = markers.first(where: { $0.location == NSMaxRange(span.range) && fits($0) })
        else { continue }
        return (open, close)
      }
      return nil
    }
    typealias Replacement = NoteTasks.Replacement

    guard selection.length > 0 else {
      let bounds = line(at: selection.location)
      let caret = min(max(selection.location, bounds.content), bounds.end)
      // 光标正夹在一对空的这种标记中间（刚按过一次、还没打字）：在光标处放一个字、用扫描器认一遍——认得出这个字正好是
      // 这种样式、两头紧挨着的就是这一对，才是（`**a**|**b**` 中间的两对各归各的，不是）
      let probe = Array(units[..<caret]) + [0x61] + Array(units[caret...])
      if let pair = wrapping(
        NSRange(location: caret, length: 1),
        in: inline(probe, in: bounds.content..<(bounds.end + 1))),
        pair.open == NSRange(location: caret - size, length: size),
        pair.close == NSRange(location: caret + 1, length: size)
      {
        // 一对空的标记：删掉
        return NoteTasks.Change(
          replacements: [
            Replacement(range: NSRange(location: caret - size, length: size), text: ""),
            Replacement(range: NSRange(location: caret, length: size), text: ""),
          ], selection: NSRange(location: caret - size, length: 0))
      }
      return NoteTasks.Change(
        replacements: [
          Replacement(range: NSRange(location: caret, length: 0), text: marker + marker)
        ],
        selection: NSRange(location: caret + size, length: 0))
    }

    // 每一行里选中的那一段（去掉两头的空白、跳过块标记）：去掉选进来的这种标记之后的字（start..<end），和它是不是已经
    // 包着（wrapped：要去掉的那一对标记；nil = 还没包）。标记一半在选区里、一半在外面也认——选了几行包上之后选区盖着的是
    // 「第一行的字……最后一行的字」，中间几行的标记都在里面
    var segments: [(start: Int, end: Int, wrapped: (open: NSRange, close: NSRange)?)] = []
    var location = selection.location
    let selectionEnd = NSMaxRange(selection)
    repeat {
      let bounds = line(at: location)
      var start = max(location, bounds.content)
      var end = min(selectionEnd, bounds.end)
      while start < end, isBlank(units[start]) { start += 1 }
      while end > start, isBlank(units[end - 1]) { end -= 1 }
      let leading = run(from: start, to: end)
      let trailing = run(before: end, to: start + leading)
      if end - trailing > start + leading {
        let inner = NSRange(location: start + leading, length: end - trailing - start - leading)
        segments.append(
          (
            inner.location, NSMaxRange(inner),
            wrapping(inner, in: inline(units, in: bounds.content..<bounds.end))
          ))
      }
      // 下一行（行尾的换行后面）
      var next = 0
      text.getLineStart(
        nil, end: &next, contentsEnd: nil, for: NSRange(location: location, length: 0))
      location = max(next, location + 1)
    } while location < selectionEnd
    guard !segments.isEmpty else { return nil }
    let unwraps = segments.allSatisfy { $0.wrapped != nil }
    var replacements: [Replacement] = []
    // 前面的改动让后面的位置挪了多少；里面的字改完在哪
    var delta = 0
    var inner: [(start: Int, end: Int)] = []
    for segment in segments {
      if unwraps, let pair = segment.wrapped {
        // 去掉这种样式的那一对（又粗又斜里去掉斜体：去的是最外面那两个星号）
        replacements.append(Replacement(range: pair.open, text: ""))
        delta -= pair.open.length
        inner.append((segment.start + delta, segment.end + delta))
        replacements.append(Replacement(range: pair.close, text: ""))
        delta -= pair.close.length
      } else if segment.wrapped == nil {
        replacements.append(
          Replacement(range: NSRange(location: segment.start, length: 0), text: marker))
        delta += size
        inner.append((segment.start + delta, segment.end + delta))
        replacements.append(
          Replacement(range: NSRange(location: segment.end, length: 0), text: marker))
        delta += size
      } else {
        // 有别的段还没包：已经包着的这段不动
        inner.append((segment.start + delta, segment.end + delta))
      }
    }
    let first = inner[0].start
    return NoteTasks.Change(
      replacements: replacements,
      selection: NSRange(location: first, length: (inner.last?.end ?? first) - first))
  }

  // MARK: 粘贴网址成链接

  /// 选中一段字、剪贴板里是一个能打开的网址时，粘贴成链接：line 是选区所在的那一行（不含行尾的换行），selection 相对
  /// 它的开头，pasted 是剪贴板里的字（两头的空白、换行去掉；中间有空白——几个网址、一段话——就不是）。给的是改动：
  /// 选中的字换成「[字](网址)」、光标放在后面；不该这么粘的给 nil（照常粘贴）。拼出来之后还要用同一个扫描器认得出
  /// 「这一段是链接、地址就是它」才算——选中的字在行内代码里、带着方括号、地址里括号不成对，拼出来就不是链接了
  static func linkPaste(_ pasted: String, in line: String, selection: NSRange) -> NoteTasks.Change?
  {
    let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    let units = Array(line.utf16)
    guard selection.length > 0, NSMaxRange(selection) <= units.count, !address.isEmpty,
      !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
      url(address) != nil
    else { return nil }
    let selected = String(
      decoding: units[selection.location..<NSMaxRange(selection)], as: UTF16.self)
    guard !selected.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) else {
      return nil
    }
    let link = "[\(selected)](\(address))"
    let rebuilt =
      Array(units[..<selection.location]) + Array(link.utf16)
      + Array(units[NSMaxRange(selection)...])
    let text = NSRange(location: selection.location + 1, length: selection.length)
    let content = contentStart(of: rebuilt)
    guard
      inline(rebuilt, in: content..<rebuilt.count).contains(where: {
        $0.range == text && $0.kind == .link(address)
      })
    else { return nil }
    let replacement = NoteTasks.Replacement(range: selection, text: link)
    return NoteTasks.Change(
      replacements: [replacement],
      selection: NSRange(location: selection.location + (link as NSString).length, length: 0))
  }

  // MARK: 链接

  /// 链接的地址能不能打开：只认 http、https（要有主机名）和 mailto（冒号后面要有东西）；别的给 nil
  static func url(_ address: String) -> URL? {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http", "https": return url.host?.isEmpty == false ? url : nil
    case "mailto": return address.count > "mailto:".count ? url : nil
    default: return nil
    }
  }

  // MARK: 去掉标记

  /// 这一行去掉 Markdown 标记之后的字（标题和摘要用）：行内的标记（`**粗**` → 粗、`[字](地址)` → 字），
  /// blocks 给 true 时连行首引用的 `>`、无序列表的符号一起去。标题的 `#` 和任务的方框由 Note.clean 去（它比这里宽），
  /// 去过的那一行剩下的是内容，只去行内的（blocks 给 false）
  static func plain(_ line: String, blocks: Bool) -> String {
    let units = Array(line.utf16)
    var removed: [NSRange] = []
    var start = 0
    if blocks, let quote = quote(units) {
      removed.append(NSRange(location: 0, length: NSMaxRange(quote)))
      start = NSMaxRange(quote)
    } else if blocks, let prefix = NoteTasks.prefix(of: line), case .bullet = prefix.lead {
      removed.append(NSRange(location: 0, length: prefix.contentStart))
      start = prefix.contentStart
    }
    removed += inline(units, in: start..<units.count).filter { $0.kind == .marker }.map(\.range)
    guard !removed.isEmpty else { return line }
    var kept: [UInt16] = []
    var index = 0
    for range in removed.sorted(by: { $0.location < $1.location }) {
      if range.location > index { kept += units[index..<range.location] }
      index = max(index, NSMaxRange(range))
    }
    kept += units[index...]
    return String(decoding: kept, as: UTF16.self)
  }
}
