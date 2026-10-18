// 便签正文里的 Markdown（PLAN §10「便签」第 6 批，拍板 C① 第二步「边打边变样」）：认标记的扫描器。全是纯函数、
// **不用正则**，一遍从左到右扫完；位置都是 UTF-16 的。样式怎么叠、换成什么属性在 NoteStyles，这里只管「哪一段是什么」。
// 除了代码块，所有语法都不跨行：一行一行扫和整篇扫结果一样（NoteStyles 按行重排靠这一条）；代码块（codeBlocks）
// 是唯一跨行的，整篇认一遍、每一行拿到自己的角色（开头的围栏 / 块里 / 收尾的围栏），块里的行不再按 Markdown 扫。
// - 块（行首，前面最多 3 个空格）：标题 `#`…`######` 后面跟空白、再后面得有字（只有「# 」的不算——标记藏起来之后
//   这一行就什么都看不见了）；引用 `>`（单层，后面的一个空格算标记，可以没有内容——那时 `>` 不藏，NoteStyles.spans）。
//   无序列表的符号、任务的方框由 NoteTasks 认。
// - 行内：行内代码（反引号，几个开就几个关）、粗体 `**` `__`、斜体 `*` `_`、删除线 `~~`、链接 `[字](地址)`、
//   颜色 `[字]{名字}`（第 8 批：red / orange / green / blue / purple / gray，全小写）。
//   代码先认，代码里的 `*` `_` `~` `[` 都不是标记；前面有反斜杠的标点不算标记（反斜杠照常显示）；没配对的原样显示。
//   `*` 可以在词中间，开头的标记后面、结尾的标记前面不能是空白；`_` `__` 两边还得不是字（字母、数字、汉字）——
//   `snake_case_name` 里的下划线不是斜体。**紧挨着的前一个字和后一个字都是 ASCII 数字的一串 `*` 不是标记**（既不开
//   也不关）：`2*3*4`、`箱子 60*40*30` 是乘号，当成斜体藏起来就读成「604030」了；`*3*`、`第**3**个` 照常。
//   `***又粗又斜***` 两层都认。空的强调凑不出来（`****`、`__` 是一整串标记，自己配不了自己）。
// - 链接：方括号可以套、地址里的括号成对就行；地址里不能有空白（`[字](地址 "标题")` 不认）、字和地址都不能是空的；
//   链接的字里不再认链接。`![…](…)` 是图片（第 7 批），这里原样显示，里面什么都不认。
// - 颜色（第 8 批）：`]` 后面紧跟 `{名字}`，中间不许有空白；方括号里的字不能全是空白、不跨行；`![…]{red}` 不是颜色。
//   颜色里可以有粗体、斜体、删除线、行内代码、链接（`[[字]{red}](地址)`）；**颜色里不套颜色**（里面已经认出颜色的，
//   外面这一对不算，原样显示）。「链接里不套链接」的 voided 不管颜色。两头的 `[` 和 `]{名字}` 是标记（.marker），
//   中间是 `.color(颜色)`。
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
        // 颜色：`]` 后面紧跟着 `{名字}`。图片的方括号不是颜色；方括号里的字不能全是空白；颜色里不套颜色
        // （里面已经认出颜色的，外面这一对不算、原样显示）。配成颜色不看 voided（那是「链接里不套链接」）
        if !bracket.isImage, let found = color(after: index, units: units, end: end),
          units[text].contains(where: { !isBlank($0) }),
          !spans[bracket.spanCount...].contains(where: {
            if case .color = $0.kind { true } else { false }
          })
        {
          // 颜色里的强调自己配，不和外面的配；颜色套在它们外面
          spans += emphasis(Array(delimiters[bracket.delimiterCount...]))
          delimiters.removeSubrange(bracket.delimiterCount...)
          spans.append(marker(bracket.position, 1))
          spans.append(
            Span(
              range: NSRange(location: text.lowerBound, length: text.count),
              kind: .color(found.color)))
          spans.append(marker(index, found.length))
          index = found.end
          break
        }
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

  /// `]` 后面紧跟着 `{名字}`：给颜色、`{名字}` 到哪结束（end 是 `}` 后面的位置）、标记多长（`]{名字}`）。
  /// 名字只认全小写的 6 个，中间不许有空白
  static func color(after close: Int, units: [UInt16], end: Int) -> (
    color: NoteColor, end: Int, length: Int
  )? {
    guard close + 2 < end, units[close + 1] == 0x7B else { return nil }
    var index = close + 2
    while index < end, units[index] != 0x7D {
      // 名字里只可能是 a–z，碰到别的就不认（也不往后找第二个 }）
      guard units[index] >= 0x61, units[index] <= 0x7A else { return nil }
      index += 1
    }
    guard index < end, index > close + 2 else { return nil }
    let name = String(decoding: units[(close + 2)..<index], as: UTF16.self)
    guard let color = NoteColor.named(name) else { return nil }
    return (color, index + 1, index + 1 - close)
  }

  /// 一行里认出颜色的那几段（按 `inline` 的结果）：每段连它两头的标记（`[`、`]{名字}`）是哪几个区间。
  /// 颜色不套颜色，所以每段的两头紧挨着的那些标记就是它自己的。标记按位置查字典（一行上几千段颜色时，
  /// 原来每段都把全部标记过一遍，是平方的）
  static func colorRuns(in spans: [NoteStyles.Span]) -> [(
    color: NoteColor, range: NSRange, open: NSRange, close: NSRange
  )] {
    var byStart: [Int: NSRange] = [:]
    var byEnd: [Int: NSRange] = [:]
    for span in spans where span.kind == .marker {
      byStart[span.range.location] = span.range
      byEnd[NSMaxRange(span.range)] = span.range
    }
    var found: [(color: NoteColor, range: NSRange, open: NSRange, close: NSRange)] = []
    for span in spans {
      guard case .color(let color) = span.kind else { continue }
      guard
        let open = byEnd[span.range.location], open.length == 1,
        let close = byStart[NSMaxRange(span.range)],
        close.length == 3 + color.name.count
      else { continue }
      found.append((color, span.range, open, close))
    }
    return found
  }

  /// 一行里只有颜色和它的标记（设置里 Markdown 关着时用：颜色不看这个开关，别的 Markdown 照旧原样显示）。
  /// 没有 `]{` 的行不用扫
  static func colorOnlySpans(in line: String) -> [NoteStyles.Span] {
    guard line.contains("]{") else { return [] }
    let units = Array(line.utf16)
    let spans = inline(units, in: 0..<units.count)
    let markers = Set(colorRuns(in: spans).flatMap { [$0.open, $0.close] })
    return spans.filter { span in
      switch span.kind {
      case .color: true
      case .marker: markers.contains(span.range)
      default: false
      }
    }
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

    /// 两头的标记用几个字（斜体、代码是 1，粗体、删除线是 2）：找「这种样式自己的标记」按它认
    var markerLength: Int {
      switch self {
      case .bold, .strike: 2
      case .italic, .code: 1
      }
    }

    /// shapes 里这种样式占的那一位（重建之后照它比对）
    var flag: UInt16 {
      switch self {
      case .bold: 0x0080
      case .italic: 0x0100
      case .strike: 0x0200
      case .code: 0x0400
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

  /// ⌘B 这几个键：block 是选区碰到的那几行（不含最后一行的换行），selection 相对 block 的开头，位置都是 UTF-16 的。
  /// - 没有选区：在光标处插一对标记、光标放中间；光标正夹在一对空的标记中间时（刚按过一次、还没打字）把这对删掉。
  /// - 有选区、**粗体 / 斜体 / 删除线整段一种**（第 8 批之后的一轮 R1）：先问扫描器「选区里能加这种格式的字（看得见、
  ///   去掉空白、不在代码 / 图片里）是不是全都是这种格式」——不是就都把上（原来有的那几段并进来、中间的标记不留、
  ///   跨在选区边上的也并进来），都是就去掉（选区外的照旧，会拆开）；每一行各自重建（行内语法不跨行）。
  /// - 有选区、行内代码 ⌘E：照旧每一行各自包 / 去掉（代码里不能有别的格式，这一轮不动）。
  /// 「已经包着」不数字符、问扫描器：数字中间的星号是乘号（`2*3*4`），重建斜体时两头紧挨着数字会认不出来，
  /// 扫描器复验就挡住（响一声、不改）。都是空白、没有可包的给 nil
  static func toggle(_ wrap: Wrap, in block: String, selection: NSRange) -> NoteTasks.Change? {
    guard wrap != .code, selection.length > 0 else {
      return toggleSingle(wrap, in: block, selection: selection)
    }
    return toggleFormat(wrap, in: block, selection: selection)
  }

  /// 老的四样加标记：没有选区时插一对、删掉空的一对；有选区时每一行各自包（Markdown 的样式不跨行）——包的是选区在这一行里的
  /// 那一段，去掉两头的空白、跳过行首的块标记、去掉选进来的这种标记；这一段已经是这种样式的（扫描器认出来的，wrapping），
  /// 就去掉它两头的标记；几段里有一段还没包，就把没包的都包上，都包着才都去掉（同 ⌘T）。改完选中的是里面的字（不含标记）。
  /// 挨着的两段（`**a**|**b**`）中间的标记各归各的。斜体只认单数个星号由扫描器的配对定（粗体上按 ⌘I 是又粗又斜，
  /// 又粗又斜里按 ⌘I 去掉斜体）
  private static func toggleSingle(
    _ wrap: Wrap, in block: String, selection: NSRange
  ) -> NoteTasks.Change? {
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

  // MARK: 上色（第 8 批）

  /// 右键「文字颜色」：给 block 里选区碰到的那几行上色（nil = 默认颜色、去掉颜色）。
  /// 每一行各自处理：选中的那一段去掉两头的空白、跳过行首的块标记；把「能上色的字」（不是标记、不在行内代码里、
  /// 不是图片）设成新颜色；再把这**一行**所有的颜色标记去掉，按「连着的、能上色的、同一种颜色」的一串串重新加
  /// `[` `]{名字}`（一串碰到不能上色的字就断开，所以颜色永远在最里层）。
  /// 拼好之后用同一个扫描器认一遍：每个字除了颜色以外的样子都和原来一样、颜色都是想要的，才算；不然给 nil（响一声）。
  /// 替换只动这一行里变了的那几段；改完选区盖着原来选中的那些字（不含标记）。位置都是 UTF-16 的、相对 block 的开头
  static func color(_ color: NoteColor?, in block: String, selection: NSRange) -> NoteTasks.Change?
  {
    guard selection.length > 0 else { return nil }
    let text = block as NSString
    var replacements: [NoteTasks.Replacement] = []
    var (first, last) = (Int.max, 0)
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      let units = Array(line.utf16)
      let selStart = max(selection.location, start)
      let selEnd = min(NSMaxRange(selection), start + units.count)
      if selEnd > selStart,
        let lineChange = recolor(
          units: units, section: selStart - start..<selEnd - start, color: color)
      {
        for replacement in lineChange.replacements {
          replacements.append(
            NoteTasks.Replacement(
              range: NSRange(
                location: replacement.range.location + start, length: replacement.range.length),
              text: replacement.text))
        }
        first = min(first, start + lineChange.selection.location)
        last = max(last, start + NSMaxRange(lineChange.selection))
      }
      location = max(end, location + 1)
    }
    guard first != .max, last >= first else { return nil }
    let mappedStart = NoteTasks.mappedPosition(
      first, through: replacements, staysBeforeInsertion: false)
    let mappedEnd = NoteTasks.mappedPosition(
      last, through: replacements, staysBeforeInsertion: true)
    return NoteTasks.Change(
      replacements: replacements,
      selection: NSRange(location: mappedStart, length: mappedEnd - mappedStart))
  }

  // MARK: 格式合并（粗体、斜体、删除线整段一种；第 8 批之后的一轮 R1–R3）

  /// 一行扫一遍的结果（重建强调、上色、清除格式共用）
  private struct Line {
    var units: [UInt16]
    var spans: [Span]
    /// 每个字除颜色以外的样子（见 shapes）
    var flags: [UInt16]
    /// 每个字的链接地址
    var links: [String?]
    /// 看得见的字在这一行里的位置
    var visible: [Int]
    /// 看得见的字本身（和 visible 一一对应）
    var shown: [UInt16]
    /// 标记字符（看不见的字）
    var hidden: [Bool]
    /// 不能加格式的字：别的标记、行内代码、图片（附件字符和令牌）
    var blocked: [Bool]
    /// 旧的颜色标记（上色时它们不算断开）
    var colorMarkers: [Bool]
  }

  /// 扫这一行。transparent：这些标记区间不算「不能加格式」（它们反正要删掉，一串可以跨过去）。
  /// extraHidden：扫描器没配上、但看着像这种格式标记的那几串（见 looseMarkers），也当看不见的标记
  private static func line(
    _ units: [UInt16], transparent: Set<NSRange> = [], extraHidden: [NSRange] = []
  ) -> Line {
    let content = contentStart(of: units)
    let spans = inline(units, in: content..<units.count)
    let shapes = shapes(of: units, spans: spans)
    let shown = visible(units, spans: spans, hiding: extraHidden)
    var hidden = [Bool](repeating: false, count: units.count)
    var blocked = [Bool](repeating: false, count: units.count)
    var colorMarkers = [Bool](repeating: false, count: units.count)
    for range in extraHidden {
      for index in range.location..<NSMaxRange(range) where index < units.count {
        hidden[index] = true
      }
    }
    func fill(_ range: NSRange) {
      for index in range.location..<NSMaxRange(range) where index < units.count {
        blocked[index] = true
      }
    }
    for span in spans {
      switch span.kind {
      case .marker:
        for index in span.range.location..<NSMaxRange(span.range) where index < units.count {
          hidden[index] = true
        }
        guard !transparent.contains(span.range) else { continue }
        fill(span.range)
      case .code:
        fill(span.range)
      default: break
      }
    }
    for run in colorRuns(in: spans) {
      for range in [run.open, run.close] {
        for index in range.location..<NSMaxRange(range) where index < units.count {
          colorMarkers[index] = true
        }
      }
    }
    for index in units.indices where units[index] == 0xFFFC { blocked[index] = true }
    let text = String(decoding: units, as: UTF16.self)
    for match in NoteImages.matches(in: text as NSString) { fill(match.range) }
    return Line(
      units: units, spans: spans, flags: shapes.flags, links: shapes.links,
      visible: shown.indices, shown: shown.units, hidden: hidden, blocked: blocked,
      colorMarkers: colorMarkers)
  }

  /// 这一行的文字拆成一行行的（和 NoteTasks 里那份一样的拆法：最后一行没有换行时也有一行）
  private static func lines(of block: String) -> [(start: Int, units: [UInt16])] {
    let text = block as NSString
    var rows: [(start: Int, units: [UInt16])] = []
    var location = 0
    repeat {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      rows.append((start, Array(line.utf16)))
      if end == text.length, contentsEnd < end { rows.append((end, [])) }
      location = end
    } while location < text.length
    return rows
  }

  /// 一行里这种样式两头的标记（`***粗***` 里粗体那一对是里面两个星号）
  private static func markers(of wrap: Wrap, in spans: [Span]) -> [NSRange] {
    guard wrap != .code else { return [] }
    let all = spans.filter { $0.kind == .marker }.map(\.range)
    var found: [NSRange] = []
    for span in spans where span.kind == wrap.kind {
      guard
        let open = all.first(where: {
          NSMaxRange($0) == span.range.location && $0.length == wrap.markerLength
        }),
        let close = all.first(where: {
          $0.location == NSMaxRange(span.range) && $0.length == wrap.markerLength
        })
      else { continue }
      found.append(open)
      found.append(close)
    }
    return found.sorted { $0.location < $1.location }
  }

  /// 扫描器没配上、看着却像这种格式标记的那几串：正好 markerLength 个、和选区有交集、不在代码 / 链接 / 图片里、
  /// 也不和任何认出来的标记重叠。R1 的例子 `12**312**3` 全选 ⌘B：两边的数字让扫描器把 `**` 当成了乘号，
  /// 但用户按 ⌘B 的意思是它们本来就该是粗体标记——重建时一并去掉，结果 `**123123**`
  private static func looseMarkers(
    of wrap: Wrap, units: [UInt16], spans: [Span], section: Range<Int>
  ) -> [NSRange] {
    guard wrap != .code else { return [] }
    let unit: UInt16
    switch wrap {
    case .bold, .italic: unit = 0x2A
    case .strike: unit = 0x7E
    case .code: return []
    }
    // 按位置铺开：候选串里有一个字落在认出来的标记 / 代码 / 链接 / 图片里就不要。整行 O(字数 + 区间数)
    var known = [Bool](repeating: false, count: units.count)
    for range in spans.map(\.range) {
      for index in range.location..<min(NSMaxRange(range), units.count) { known[index] = true }
    }
    var awayFrom = known
    for span in spans {
      switch span.kind {
      case .code, .link:
        for index in span.range.location..<min(NSMaxRange(span.range), units.count) {
          awayFrom[index] = true
        }
      default: break
      }
    }
    let text = String(decoding: units, as: UTF16.self)
    for match in NoteImages.matches(in: text as NSString) {
      for index in match.range.location..<min(NSMaxRange(match.range), units.count) {
        awayFrom[index] = true
      }
    }
    func intersects(_ mask: [Bool], _ range: NSRange) -> Bool {
      let end = min(NSMaxRange(range), mask.count)
      guard range.location < end else { return false }
      for index in range.location..<end where mask[index] { return true }
      return false
    }
    let selection = NSRange(location: section.lowerBound, length: section.count)
    var found: [NSRange] = []
    var index = contentStart(of: units)
    while index < units.count {
      guard units[index] == unit else {
        index += 1
        continue
      }
      var end = index + 1
      while end < units.count, units[end] == unit { end += 1 }
      let range = NSRange(location: index, length: end - index)
      index = end
      guard range.length == wrap.markerLength,
        NSIntersectionRange(range, selection).length > 0,
        !intersects(known, range), !intersects(awayFrom, range)
      else { continue }
      found.append(range)
    }
    return found
  }

  /// 选区里能加这种格式的字（看得见、不是空白、不在代码 / 图片里）是不是全都是这种格式；没有这种字给 nil。
  /// 菜单打勾和 ⌘B 的「全都是」都用它（不数字符，问扫描器）
  static func isFormatted(_ wrap: Wrap, in block: String, selection: NSRange) -> Bool? {
    guard selection.length > 0 else { return nil }
    var found = false
    for row in lines(of: block) {
      let lineEnd = row.start + row.units.count
      let lower = max(selection.location, row.start)
      let upper = min(NSMaxRange(selection), lineEnd)
      guard upper > lower else { continue }
      let analyzed = line(row.units)
      for index in (lower - row.start)..<(upper - row.start)
      where !analyzed.hidden[index] && !analyzed.blocked[index]
        && !isBlank(row.units[index])
      {
        found = true
        if analyzed.flags[index] & wrap.flag == 0 { return false }
      }
    }
    return found ? true : nil
  }

  /// 一行里选中的那一段重建这种格式（R3）：算出每个看得见的字要不要 → 去掉这一行这种格式的全部标记 →
  /// 按连着的、要这种格式的字一串串重新加（两头不能是空白，别的标记 / 代码 / 图片断开，这种格式自己的旧标记跨过去）→
  /// 用扫描器认一遍。返回这一行的替换、改完选区盖着的那一段（相对这一行）；认不对给 nil。
  private static func formatLine(
    _ wrap: Wrap, units: [UInt16], section: Range<Int>, want: Bool
  ) -> LineOutcome? {
    let content = contentStart(of: units)
    var start = max(section.lowerBound, content)
    var end = min(section.upperBound, units.count)
    while start < end, isBlank(units[start]) { start += 1 }
    while end > start, isBlank(units[end - 1]) { end -= 1 }
    guard start < end else { return LineOutcome() }
    let spans = inline(units, in: content..<units.count)
    let own = markers(of: wrap, in: spans)
    // 扫描器没配上的、看着像这种格式标记的几串（数字中间的 `**` 被当成乘号那种）：选中了就一起当成标记去掉
    let loose = looseMarkers(of: wrap, units: units, spans: spans, section: start..<end)
    let deletions = (own + loose).sorted { $0.location < $1.location }
    let analyzed = line(units, transparent: Set(deletions), extraHidden: loose)
    var oldMarker = [Bool](repeating: false, count: units.count)
    for range in deletions {
      for index in range.location..<NSMaxRange(range) where index < units.count {
        oldMarker[index] = true
      }
    }
    // 选区里能加的字（改完选区盖着它们）
    var first = Int.max
    var last = 0
    for index in start..<end
    where !analyzed.hidden[index] && !analyzed.blocked[index] && !isBlank(units[index]) {
      first = min(first, index)
      last = max(last, index + 1)
    }
    guard first != .max else { return LineOutcome() }
    var desired = analyzed.flags.map { $0 & wrap.flag != 0 }
    for index in start..<end where !analyzed.hidden[index] && !analyzed.blocked[index] {
      desired[index] = want
    }
    // 连着的、要这种格式的字一串串
    var runs: [Range<Int>] = []
    var index = 0
    while index < units.count {
      if oldMarker[index] {
        index += 1
        continue
      }
      guard !analyzed.hidden[index], !analyzed.blocked[index], desired[index] else {
        index += 1
        continue
      }
      var tail = index + 1
      var lastDesired = index
      while tail < units.count {
        if oldMarker[tail] {
          tail += 1
          continue
        }
        guard !analyzed.hidden[tail], !analyzed.blocked[tail], desired[tail] else { break }
        lastDesired = tail
        tail += 1
      }
      var lower = index
      while lower <= lastDesired, isBlank(units[lower]) { lower += 1 }
      var upper = lastDesired
      while upper >= lower, isBlank(units[upper]) { upper -= 1 }
      if lower <= upper { runs.append(lower..<(upper + 1)) }
      index = lastDesired + 1
    }
    var insertions: [(location: Int, text: String)] = []
    for run in runs {
      insertions.append((run.lowerBound, wrap.marker))
      insertions.append((run.upperBound, wrap.marker))
    }
    // 空白：在一串里面就跟着这一串，不在串里（两头的、被代码 / 标记断开的）就不要这种格式
    var inside = [Bool](repeating: false, count: units.count)
    for run in runs {
      for position in run { inside[position] = true }
    }
    for index in units.indices where isBlank(units[index]) && !inside[index] {
      desired[index] = false
    }
    let (lineChange, newUnits) = edits(
      units: units, deletions: deletions,
      insertions: insertions.sorted { $0.location < $1.location })
    // 这一行本来就是这样：不动它，但选区还是要盖住它里面的字
    guard newUnits != units, !lineChange.replacements.isEmpty else {
      return LineOutcome(first: first, last: last)
    }
    guard formatMatches(old: analyzed, new: newUnits, desired: desired, wrap: wrap) else {
      return nil
    }
    return LineOutcome(change: lineChange, first: first, last: last)
  }

  /// 一行重建的结果：改了什么（本来就是这样时没有）、选区在这一行里盖着哪一段（没有能加的字时都没有）；
  /// nil 表示认不对（整次不改、响一声）
  private struct LineOutcome {
    var change: NoteTasks.Change?
    var first: Int?
    var last: Int?
  }

  /// 重建之后认一遍：看得见的字一样、别的格式一样、链接一样、这种格式每个能加的字都对
  private static func formatMatches(
    old: Line, new units: [UInt16], desired: [Bool], wrap: Wrap
  ) -> Bool {
    let spans = inline(units, in: contentStart(of: units)..<units.count)
    let shown = visible(units, spans: spans)
    guard old.shown == shown.units else { return false }
    let shapes = shapes(of: units, spans: spans)
    let mask = wrap.flag
    for (offset, oldIndex) in old.visible.enumerated() {
      let newIndex = shown.indices[offset]
      guard (old.flags[oldIndex] & ~mask) == (shapes.flags[newIndex] & ~mask),
        old.links[oldIndex] == shapes.links[newIndex]
      else { return false }
      guard !old.hidden[oldIndex], !old.blocked[oldIndex] else { continue }
      guard ((shapes.flags[newIndex] & mask) != 0) == desired[oldIndex] else { return false }
    }
    return true
  }

  /// ⌘B / ⌘I / ⇧⌘X 有选区时的整段一种（R1）：先看整个选区是不是全都已经是，再每行各自重建
  private static func toggleFormat(
    _ wrap: Wrap, in block: String, selection: NSRange
  ) -> NoteTasks.Change? {
    let rows = lines(of: block)
    let end = NSMaxRange(selection)
    var sections: [(start: Int, units: [UInt16], range: Range<Int>)] = []
    for row in rows {
      let lineEnd = row.start + row.units.count
      let lower = max(selection.location, row.start)
      let upper = min(end, lineEnd)
      guard upper > lower else { continue }
      sections.append((row.start, row.units, (lower - row.start)..<(upper - row.start)))
    }
    // 「全都是」看整个选区
    var found = false
    var all = true
    outer: for section in sections {
      let analyzed = line(section.units)
      for index in section.range
      where !analyzed.hidden[index] && !analyzed.blocked[index]
        && !isBlank(section.units[index])
      {
        found = true
        if analyzed.flags[index] & wrap.flag == 0 {
          all = false
          break outer
        }
      }
    }
    guard found else { return nil }
    let want = !all
    var replacements: [NoteTasks.Replacement] = []
    var (first, last) = (Int.max, 0)
    for section in sections {
      guard
        let result = formatLine(
          wrap, units: section.units, section: section.range, want: want)
      else { return nil }
      guard let lineFirst = result.first, let lineLast = result.last else { continue }
      first = min(first, section.start + lineFirst)
      last = max(last, section.start + lineLast)
      for replacement in result.change?.replacements ?? [] {
        replacements.append(
          NoteTasks.Replacement(
            range: NSRange(
              location: replacement.range.location + section.start,
              length: replacement.range.length), text: replacement.text))
      }
    }
    guard first != .max, last >= first, !replacements.isEmpty else { return nil }
    let mappedStart = NoteTasks.mappedPosition(
      first, through: replacements, staysBeforeInsertion: false)
    let mappedEnd = NoteTasks.mappedPosition(
      last, through: replacements, staysBeforeInsertion: true)
    return NoteTasks.Change(
      replacements: replacements,
      selection: NSRange(location: mappedStart, length: mappedEnd - mappedStart))
  }

  // MARK: 块格式、链接、清除格式（右键「格式」的新几项，R6）

  /// 右键「格式」里的块格式（标题 1–3、引用、无序列表、有序列表）
  enum BlockFormat: Equatable, Sendable {
    case heading(Int)
    case quote
    case bullet
    case ordered

    /// 菜单里的名字
    var title: String {
      switch self {
      case .heading(1): "标题 1"
      case .heading(2): "标题 2"
      case .heading(3): "标题 3"
      case .quote: "引用"
      case .bullet: "无序列表"
      case .ordered: "有序列表"
      case .heading: "标题"
      }
    }
  }

  /// 一行开头原有的块标记（缩进之后）：引用、标题、任务 / 列表可以一层层套（`> # 标题`、`- ☐ 任务`），
  /// 转换时整串换掉；标题后面不再往下认（`# - 字` 里的横杠是标题里的字）
  private static func blockMarker(of units: [UInt16]) -> (indent: Int, end: Int)? {
    let indent = units.prefix { $0 == space || $0 == tab }.count
    var position = indent
    var found = false
    while position < units.count {
      if let next = quoteEnd(at: position, in: units) {
        position = next
        found = true
        continue
      }
      if let next = headingEnd(at: position, in: units) {
        position = next
        found = true
        break
      }
      let rest = Array(units[position...])
      if let prefix = NoteTasks.prefix(of: rest) {
        position += prefix.contentStart
        found = true
        continue
      }
      break
    }
    return found ? (indent, position) : nil
  }

  /// 从 position 起的一个 `>`（连后面那个空格）到哪结束
  private static func quoteEnd(at position: Int, in units: [UInt16]) -> Int? {
    guard position < units.count, units[position] == 0x3E else { return nil }
    return position + (position + 1 < units.count && isBlank(units[position + 1]) ? 2 : 1)
  }

  /// 从 position 起的一个 `#` 标题标记（连后面那些空白）到哪结束
  private static func headingEnd(at position: Int, in units: [UInt16]) -> Int? {
    var end = position
    while end < units.count, units[end] == hash { end += 1 }
    let hashes = end - position
    guard (1...6).contains(hashes) else { return nil }
    var blanks = 0
    while end + blanks < units.count, isBlank(units[end + blanks]) { blanks += 1 }
    guard blanks > 0, end + blanks < units.count else { return nil }
    return end + blanks
  }

  /// 去掉的时候只去这一种格式自己的标记（标题去掉 `#`，引用去掉 `> `，列表只去掉符号），别的留着
  private static func ownMarker(
    of format: BlockFormat, units: [UInt16]
  ) -> (indent: Int, end: Int)? {
    let indent = units.prefix { $0 == space || $0 == tab }.count
    switch format {
    case .heading:
      guard let head = heading(units) else { return nil }
      return (units.prefix { $0 == space }.count, NSMaxRange(head.marker))
    case .quote:
      guard let quote = quote(units) else { return nil }
      return (units.prefix { $0 == space || $0 == tab }.count, NSMaxRange(quote))
    case .bullet, .ordered:
      guard let prefix = NoteTasks.prefix(of: units) else { return nil }
      let matches: Bool
      switch (format, prefix.lead) {
      case (.bullet, .bullet), (.ordered, .ordered): matches = true
      default: matches = false
      }
      guard matches else { return nil }
      return (prefix.indent, prefix.contentStart)
    }
  }

  /// 这一行是不是这种块格式
  private static func isOn(_ format: BlockFormat, units: [UInt16]) -> Bool {
    switch format {
    case .heading(let level): heading(units)?.level == level
    case .quote: quote(units) != nil
    case .bullet:
      if case .bullet = NoteTasks.prefix(of: units)?.lead { true } else { false }
    case .ordered:
      if case .ordered = NoteTasks.prefix(of: units)?.lead { true } else { false }
    }
  }

  /// 选区碰到的这一行：没有选区时光标在行里（或行尾），有选区时和这一行有交集
  private static func touched(_ row: (start: Int, units: [UInt16]), by selection: NSRange) -> Bool {
    let range = NSRange(location: row.start, length: row.units.count)
    if selection.length == 0 {
      return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(range, selection).length > 0
  }

  /// 只有空白的一行
  private static func isBlankRow(_ units: [UInt16]) -> Bool {
    units.allSatisfy { isBlank($0) }
  }

  /// 选区碰到的非空行是不是全都已经是这种块格式（菜单打勾用）；没有非空行给 nil
  static func blockIsOn(
    _ format: BlockFormat, in block: String, selection: NSRange
  ) -> Bool? {
    var found = false
    for row in lines(of: block) where touched(row, by: selection) {
      guard !isBlankRow(row.units) else { continue }
      found = true
      if !isOn(format, units: row.units) { return false }
    }
    return found ? true : nil
  }

  /// 换成这种块格式 / 去掉（R6）：选了好几行时空行不动，只有一行时空行也变。
  /// 标题保留原来的缩进、在缩进后加 `# `；引用给不是引用的行加 `> `（别的标记留着）；无序列表和有序列表把原来的
  /// 块标记（别级的 #、引用的 >、列表符号、任务方框）换成 `- ` / `1. ` `2. `…；有序列表**同一缩进算一组、每组从 1
  /// 开始**。没有可改的给 nil
  static func block(
    _ format: BlockFormat, in block: String, selection: NSRange
  ) -> NoteTasks.Change? {
    var candidates = lines(of: block).filter { touched($0, by: selection) }
    if candidates.count > 1 { candidates = candidates.filter { !isBlankRow($0.units) } }
    guard !candidates.isEmpty else { return nil }
    let all = candidates.allSatisfy { isOn(format, units: $0.units) }
    var replacements: [NoteTasks.Replacement] = []
    var counters: [Int: Int] = [:]
    for row in candidates {
      let units = row.units
      let indent = units.prefix { $0 == space || $0 == tab }.count
      if all {
        guard let old = ownMarker(of: format, units: units) else { continue }
        replacements.append(
          NoteTasks.Replacement(
            range: NSRange(location: row.start + old.indent, length: old.end - old.indent),
            text: ""))
        continue
      }
      let marker: String
      switch format {
      case .quote:
        // 别的标记留着（在缩进后面插「> 」，不换掉标题 / 列表的标记）；已经是引用的不动
        guard quote(units) == nil else { continue }
        replacements.append(
          NoteTasks.Replacement(
            range: NSRange(location: row.start + indent, length: 0), text: "> "))
        continue
      case .bullet:
        marker = "- "
      case .ordered:
        let number = (counters[indent] ?? 0) + 1
        counters[indent] = number
        marker = "\(number). "
      case .heading(let level):
        marker = String(repeating: "#", count: level) + " "
      }
      let old = blockMarker(of: units)
      let end = old?.end ?? indent
      replacements.append(
        NoteTasks.Replacement(
          range: NSRange(location: row.start + indent, length: end - indent), text: marker))
    }
    guard !replacements.isEmpty else { return nil }
    return NoteTasks.Change(
      replacements: replacements,
      selection: NoteTasks.mapped(selection, through: replacements))
  }

  /// 选区是不是跨了好几行（链接那一项要停用）
  static func crossesLines(_ block: String, selection: NSRange) -> Bool {
    let units = Array(block.utf16)
    guard NSMaxRange(selection) <= units.count else { return false }
    return units[selection.location..<NSMaxRange(selection)].contains {
      $0 == 0x0A || $0 == 0x0D || $0 == 0x2028 || $0 == 0x2029
    }
  }

  /// 「链接」那一项（R6）：没选字插 `[]()`、光标在方括号里；选了字换成 `[选中的字]()`、光标在小括号里。
  /// 跨行给 nil
  static func link(in block: String, selection: NSRange) -> NoteTasks.Change? {
    let units = Array(block.utf16)
    let content = contentStart(of: units)
    let start = max(selection.location, content)
    let end = min(NSMaxRange(selection), units.count)
    guard start <= end, !crossesLines(block, selection: selection) else { return nil }
    if start == end {
      return NoteTasks.Change(
        replacements: [
          NoteTasks.Replacement(range: NSRange(location: start, length: 0), text: "[]()")
        ],
        selection: NSRange(location: start + 1, length: 0))
    }
    let text = String(decoding: units[start..<end], as: UTF16.self)
    return NoteTasks.Change(
      replacements: [
        NoteTasks.Replacement(
          range: NSRange(location: start, length: end - start), text: "[\(text)]()")
      ],
      selection: NSRange(location: start + 1 + (text as NSString).length + 2, length: 0))
  }

  /// 清除格式（R6）：选区里的粗体、斜体、删除线、颜色去掉（走 R3 的重建，选区外的照旧、会拆开），
  /// 碰到的行内代码、链接整段去掉标记（代码去掉反引号、链接留下字、去掉 `[` 和 `](地址)`）；块格式不动
  static func clear(in block: String, selection: NSRange) -> NoteTasks.Change? {
    guard selection.length > 0 else { return nil }
    let rows = lines(of: block)
    let end = NSMaxRange(selection)
    var sections: [(start: Int, units: [UInt16], range: Range<Int>)] = []
    for row in rows {
      let lineEnd = row.start + row.units.count
      let lower = max(selection.location, row.start)
      let upper = min(end, lineEnd)
      guard upper > lower else { continue }
      sections.append((row.start, row.units, (lower - row.start)..<(upper - row.start)))
    }
    var replacements: [NoteTasks.Replacement] = []
    var (first, last) = (Int.max, 0)
    for section in sections {
      guard let result = clearLine(units: section.units, section: section.range) else { continue }
      for replacement in result.change.replacements {
        replacements.append(
          NoteTasks.Replacement(
            range: NSRange(
              location: replacement.range.location + section.start,
              length: replacement.range.length), text: replacement.text))
      }
      first = min(first, section.start + result.first)
      last = max(last, section.start + result.last)
    }
    guard first != .max, last >= first, !replacements.isEmpty else { return nil }
    let mappedStart = NoteTasks.mappedPosition(
      first, through: replacements, staysBeforeInsertion: false)
    let mappedEnd = NoteTasks.mappedPosition(
      last, through: replacements, staysBeforeInsertion: true)
    return NoteTasks.Change(
      replacements: replacements,
      selection: NSRange(location: mappedStart, length: mappedEnd - mappedStart))
  }

  /// 一行里清除格式（R6/R3）：删掉这一行三种强调和颜色的全部标记、碰到（和选区有交集）的行内代码 / 链接的标记，
  /// 按「选区里的字去掉、选区外照旧」一串串重新加；拼完认一遍
  private static func clearLine(
    units: [UInt16], section: Range<Int>
  ) -> (change: NoteTasks.Change, first: Int, last: Int)? {
    let content = contentStart(of: units)
    var start = max(section.lowerBound, content)
    var end = min(section.upperBound, units.count)
    while start < end, isBlank(units[start]) { start += 1 }
    while end > start, isBlank(units[end - 1]) { end -= 1 }
    guard start < end else { return nil }
    let spans = inline(units, in: content..<units.count)
    let markerRanges = spans.filter { $0.kind == .marker }.map(\.range)
    let sectionRange = NSRange(location: start, length: end - start)
    let emphasis =
      (markers(of: .bold, in: spans) + markers(of: .italic, in: spans)
      + markers(of: .strike, in: spans))
      .sorted { $0.location < $1.location }
    let colorSegments = colorRuns(in: spans)
    let colorMarkers = colorSegments.flatMap { [$0.open, $0.close] }.sorted {
      $0.location < $1.location
    }
    // 碰到的行内代码、链接：整段去掉标记
    func pair(_ span: Span) -> (open: NSRange, close: NSRange)? {
      guard
        let open = markerRanges.first(where: { NSMaxRange($0) == span.range.location }),
        let close = markerRanges.first(where: { $0.location == NSMaxRange(span.range) })
      else { return nil }
      return (open, close)
    }
    var codeRanges: [NSRange] = []
    var linkRanges: [NSRange] = []
    var syntax: [NSRange] = []
    for span in spans {
      let touchedHere = NSIntersectionRange(span.range, sectionRange).length > 0
      guard touchedHere else { continue }
      switch span.kind {
      case .code:
        codeRanges.append(span.range)
        if let found = pair(span) { syntax += [found.open, found.close] }
      case .link:
        linkRanges.append(span.range)
        if let found = pair(span) { syntax += [found.open, found.close] }
      default: break
      }
    }
    let deletions = (emphasis + colorMarkers + syntax).sorted { $0.location < $1.location }
    let transparent = Set(deletions)
    let analyzed = line(units, transparent: transparent)
    var blocked = analyzed.blocked
    var codeFlag = [Bool](repeating: false, count: units.count)
    for range in codeRanges {
      for index in range.location..<NSMaxRange(range) where index < units.count {
        blocked[index] = false
        codeFlag[index] = true
      }
    }
    // 要哪种格式：选区里去掉、选区外照旧
    var bold = analyzed.flags.map { $0 & Wrap.bold.flag != 0 }
    var italic = analyzed.flags.map { $0 & Wrap.italic.flag != 0 }
    var strike = analyzed.flags.map { $0 & Wrap.strike.flag != 0 }
    var desiredColors = [NoteColor?](repeating: nil, count: units.count)
    for run in colorSegments {
      for index in run.range.location..<NSMaxRange(run.range) where index < units.count {
        desiredColors[index] = run.color
      }
    }
    var first = Int.max
    var last = 0
    for index in start..<end
    where !analyzed.hidden[index] && !blocked[index] && !isBlank(units[index]) {
      first = min(first, index)
      last = max(last, index + 1)
    }
    guard first != .max else { return nil }
    for index in start..<end where !analyzed.hidden[index] && !blocked[index] {
      bold[index] = false
      italic[index] = false
      strike[index] = false
      desiredColors[index] = nil
    }
    var insertions: [(location: Int, text: String)] = []
    for (wrap, desired) in [
      (Wrap.bold, bold), (.italic, italic), (.strike, strike),
    ] {
      for run in flaggedRuns(desired, units: units, blocked: blocked, hidden: analyzed.hidden) {
        insertions.append((run.lowerBound, wrap.marker))
        insertions.append((run.upperBound, wrap.marker))
      }
    }
    for run in tintedRuns(
      desiredColors, units: units, blocked: blocked, hidden: analyzed.hidden)
    {
      insertions.append((run.range.lowerBound, "["))
      insertions.append((run.range.upperBound, "]{\(run.color.name)}"))
    }
    let ordered = insertions.enumerated().sorted {
      $0.element.location != $1.element.location
        ? $0.element.location < $1.element.location : $0.offset < $1.offset
    }.map { $0.element }
    let (lineChange, newUnits) = edits(
      units: units, deletions: deletions, insertions: ordered)
    guard newUnits != units, !lineChange.replacements.isEmpty else { return nil }
    // 认一遍：看得见的字一样、别的格式一样、链接该没的没了、这种格式每个能加的字都对、颜色也对
    let newSpans = inline(newUnits, in: contentStart(of: newUnits)..<newUnits.count)
    let shown = visible(newUnits, spans: newSpans)
    guard analyzed.shown == shown.units else { return nil }
    let shapes = shapes(of: newUnits, spans: newSpans)
    let newColors = colors(at: newUnits, spans: newSpans)
    let formatMask = Wrap.bold.flag | Wrap.italic.flag | Wrap.strike.flag
    for (offset, oldIndex) in analyzed.visible.enumerated() {
      let newIndex = shown.indices[offset]
      var expected = analyzed.flags[oldIndex] & ~formatMask
      if codeFlag[oldIndex] { expected &= ~Wrap.code.flag }
      guard expected == (shapes.flags[newIndex] & ~formatMask) else { return nil }
      let gone = linkRanges.contains { NSLocationInRange(oldIndex, $0) }
      guard (gone ? nil : analyzed.links[oldIndex]) == shapes.links[newIndex] else {
        return nil
      }
      guard !analyzed.hidden[oldIndex], !blocked[oldIndex] else { continue }
      guard (shapes.flags[newIndex] & Wrap.bold.flag != 0) == bold[oldIndex],
        (shapes.flags[newIndex] & Wrap.italic.flag != 0) == italic[oldIndex],
        (shapes.flags[newIndex] & Wrap.strike.flag != 0) == strike[oldIndex],
        newColors[newIndex] == desiredColors[oldIndex]
      else { return nil }
    }
    for index in newUnits.indices where newUnits[index] == 0xFFFC {
      guard newColors[index] == nil else { return nil }
    }
    return (lineChange, first, last)
  }

  /// 一种格式（或者颜色去了）要加的地方：连着的、要它的字一串串，两头不能是空白；别的标记 / 代码 / 图片断开，
  /// 透明的旧标记（hidden 但没 blocked）跨过去
  private static func flaggedRuns(
    _ desired: [Bool], units: [UInt16], blocked: [Bool], hidden: [Bool]
  ) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var index = 0
    while index < units.count {
      if hidden[index], !blocked[index] {
        index += 1
        continue
      }
      guard !hidden[index], !blocked[index], desired[index] else {
        index += 1
        continue
      }
      var tail = index + 1
      var lastDesired = index
      while tail < units.count {
        if hidden[tail], !blocked[tail] {
          tail += 1
          continue
        }
        guard !hidden[tail], !blocked[tail], desired[tail] else { break }
        lastDesired = tail
        tail += 1
      }
      var lower = index
      while lower <= lastDesired, isBlank(units[lower]) { lower += 1 }
      var upper = lastDesired
      while upper >= lower, isBlank(units[upper]) { upper -= 1 }
      if lower <= upper { runs.append(lower..<(upper + 1)) }
      index = lastDesired + 1
    }
    return runs
  }

  /// 颜色要加的地方（同 flaggedRuns，一串同一种颜色）
  private static func tintedRuns(
    _ desired: [NoteColor?], units: [UInt16], blocked: [Bool], hidden: [Bool]
  ) -> [(range: Range<Int>, color: NoteColor)] {
    var runs: [(range: Range<Int>, color: NoteColor)] = []
    var index = 0
    while index < units.count {
      if hidden[index], !blocked[index] {
        index += 1
        continue
      }
      guard !hidden[index], !blocked[index], let ink = desired[index] else {
        index += 1
        continue
      }
      var tail = index + 1
      var lastDesired = index
      while tail < units.count {
        if hidden[tail], !blocked[tail] {
          tail += 1
          continue
        }
        guard !hidden[tail], !blocked[tail], desired[tail] == ink else { break }
        lastDesired = tail
        tail += 1
      }
      var lower = index
      while lower <= lastDesired, isBlank(units[lower]) { lower += 1 }
      var upper = lastDesired
      while upper >= lower, isBlank(units[upper]) { upper -= 1 }
      if lower <= upper { runs.append((lower..<(upper + 1), ink)) }
      index = lastDesired + 1
    }
    return runs
  }

  // MARK: 代码块（右键「格式」的「代码块」那一项，R6）

  /// 选区和代码块的关系
  enum CodeSpot: Equatable, Sendable {
    /// 不在任何代码块里
    case outside
    /// 选区碰到的行全都在同一个块里（连围栏）
    case inside
    /// 一半在块里、一半在外（或者跨了两个块）
    case straddles
  }

  /// 光标 / 选区落在代码块的哪：选区碰到的行都在同一个块里算「块里」，碰到的行既有块里的又有块外的算「一半一半」
  static func codeSpot(in text: NSString, selection: NSRange) -> CodeSpot {
    let blocks = codeBlocks(in: text)
    guard !blocks.isEmpty else { return .outside }
    let rows = text.lineRange(for: selection)
    let touched = blocks.filter { NSIntersectionRange(rows, $0.range).length > 0 }
    guard !touched.isEmpty else { return .outside }
    if touched.count == 1, NSLocationInRange(rows.location, touched[0].range),
      NSMaxRange(rows) <= NSMaxRange(touched[0].range)
    {
      return .inside
    }
    return .straddles
  }

  /// 「代码块」那一项：块里的行（连围栏）→ 去掉两行围栏；光标在空行上 → 插三行、光标在中间；别的 → 给选区碰到的
  /// 行上下各加一行围栏。一半在块里一半在外给 nil。围栏一律三个反引号（选中的字里正好有 ``` 时不再加长，见 ponytail）
  static func codeBlock(in text: NSString, selection: NSRange) -> NoteTasks.Change? {
    switch codeSpot(in: text, selection: selection) {
    case .straddles: return nil
    case .inside:
      guard
        let block = codeBlocks(in: text).first(where: {
          NSLocationInRange(text.lineRange(for: selection).location, $0.range)
        })
      else { return nil }
      let open = text.lineRange(for: NSRange(location: block.range.location, length: 0))
      let close = text.lineRange(for: NSRange(location: block.close.location, length: 0))
      guard NSMaxRange(open) <= close.location else { return nil }
      let replacements = [
        NoteTasks.Replacement(range: open, text: ""),
        NoteTasks.Replacement(range: close, text: ""),
      ]
      return NoteTasks.Change(
        replacements: replacements,
        selection: NoteTasks.mapped(selection, through: replacements))
    case .outside:
      let rows = text.lineRange(for: selection)
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: selection)
      let isEmptyLine = contentsEnd == start
      let atEnd = end >= text.length
      if isEmptyLine, selection.length == 0 {
        // 光标在空行上：插三行，光标在中间
        let body = atEnd && contentsEnd == end ? "```\n\n```" : "```\n\n```\n"
        let replacement = NoteTasks.Replacement(range: rows, text: body)
        return NoteTasks.Change(
          replacements: [replacement],
          selection: NSRange(location: rows.location + 4, length: 0))
      }
      // 给选区碰到的行上下各加一行围栏
      var closeText = "```\n"
      if text.length == 0 || NSMaxRange(rows) >= text.length {
        let last = text.length > 0 ? text.character(at: text.length - 1) : 0
        closeText = last == 0x0A || last == 0x0D ? "```\n" : "\n```"
      }
      let replacements = [
        NoteTasks.Replacement(range: NSRange(location: rows.location, length: 0), text: "```\n"),
        NoteTasks.Replacement(
          range: NSRange(location: NSMaxRange(rows), length: 0), text: closeText),
      ]
      return NoteTasks.Change(
        replacements: replacements,
        selection: NSRange(location: selection.location + 4, length: selection.length))
    }
  }

  /// 一行里选中的那一段重新上色。section 是这一行里的选区（UTF-16）；给这一行的替换（相对这一行）和改完选区盖着的
  /// 那一段（相对这一行）。没有字要改、或者拼出来认不对给 nil
  private static func recolor(
    units: [UInt16], section: Range<Int>, color: NoteColor?
  ) -> NoteTasks.Change? {
    let content = contentStart(of: units)
    var start = max(section.lowerBound, content)
    var end = min(section.upperBound, units.count)
    guard start < end else { return nil }
    while start < end, isBlank(units[start]) { start += 1 }
    while end > start, isBlank(units[end - 1]) { end -= 1 }
    guard start < end else { return nil }
    let spans = inline(units, in: content..<units.count)
    // 不能上色的字：标记、行内代码、图片（编辑器里是一张图的附件字符；存的形式里是令牌）。**旧的颜色标记例外**
    // （第 8 批之后的一轮 R2）：它们反正要删掉，上色时不算断开——连着的同一种颜色合成一段
    // （`[12]{red}3123[2312]{red}3` 全选上红 → 一整段）
    let oldRuns = colorRuns(in: spans)
    var colorMarkers = [Bool](repeating: false, count: units.count)
    for run in oldRuns {
      for range in [run.open, run.close] {
        for index in range.location..<NSMaxRange(range) where index < units.count {
          colorMarkers[index] = true
        }
      }
    }
    var blocked = [Bool](repeating: false, count: units.count)
    for span in spans {
      switch span.kind {
      case .marker:
        guard !colorMarkers[span.range.location] else { continue }
        for index in span.range.location..<NSMaxRange(span.range) where index < units.count {
          blocked[index] = true
        }
      case .code:
        for index in span.range.location..<NSMaxRange(span.range) where index < units.count {
          blocked[index] = true
        }
      default: break
      }
    }
    for index in units.indices where units[index] == 0xFFFC { blocked[index] = true }
    let line = String(decoding: units, as: UTF16.self)
    for match in NoteImages.matches(in: line as NSString) {
      for index in match.range.location..<NSMaxRange(match.range) where index < units.count {
        blocked[index] = true
      }
    }
    var current = [NoteColor?](repeating: nil, count: units.count)
    for run in oldRuns {
      for index in run.range.location..<NSMaxRange(run.range) where index < units.count {
        current[index] = run.color
      }
    }
    var desired = current
    for index in start..<end where !blocked[index] { desired[index] = color }
    // 连着的、能上色的、同一种颜色的一串串（旧的颜色标记跨过去：它们不算断开）
    var runs: [(range: Range<Int>, color: NoteColor)] = []
    var index = 0
    while index < units.count {
      if colorMarkers[index] {
        index += 1
        continue
      }
      guard let ink = desired[index], !blocked[index] else {
        index += 1
        continue
      }
      var tail = index + 1
      var last = index
      while tail < units.count {
        if colorMarkers[tail] {
          tail += 1
          continue
        }
        guard !blocked[tail], desired[tail] == ink else { break }
        last = tail
        tail += 1
      }
      runs.append((index..<(last + 1), ink))
      index = last + 1
    }
    let deletions = oldRuns.flatMap { [$0.open, $0.close] }
      .sorted { $0.location < $1.location }
    var insertions: [(Int, String)] = []
    for run in runs {
      insertions.append((run.range.lowerBound, "["))
      insertions.append((run.range.upperBound, "]{\(run.color.name)}"))
    }
    // 拼出改完的这一行，再照它认一遍。**和原来不一样就改**（R2：颜色没变、只是标记碎了也要整理，
    // 不是「有字的颜色变了才改」）；一模一样就不动（响一声）
    let (lineChange, newUnits) = edits(units: units, deletions: deletions, insertions: insertions)
    guard newUnits != units, !lineChange.replacements.isEmpty else { return nil }
    guard
      recolorMatches(
        old: units, oldSpans: spans, blocked: blocked, new: newUnits, section: start..<end,
        color: color)
    else { return nil }
    return NoteTasks.Change(
      replacements: lineChange.replacements,
      selection: NSRange(location: start, length: end - start))
  }

  /// 把一行的删除和插入拼成替换（位置都是改之前的），再拼出改完的那一行。同一处的插入按给的顺序接起来；
  /// 插在被删掉的那一段开头 / 里面 / 末尾的并进那一段。插入和删除都按位置从前往后一起扫（一行上几千段颜色时，
  /// 原来每个删除都把全部插入过一遍，是平方的）
  private static func edits(
    units: [UInt16], deletions: [NSRange], insertions: [(Int, String)]
  ) -> (change: NoteTasks.Change, newUnits: [UInt16]) {
    // 两个数组都按位置从前往后排好了（oldRuns 和 runs 都是这个顺序），不另排：排一次就多 m log m
    var edits: [(range: NSRange, text: String)] = []
    var extras: [(location: Int, text: String)] = []
    var index = 0
    for range in deletions {
      var text = ""
      while index < insertions.count, insertions[index].0 < range.location {
        extras.append(insertions[index])
        index += 1
      }
      while index < insertions.count, insertions[index].0 <= NSMaxRange(range) {
        text += insertions[index].1
        index += 1
      }
      edits.append((range, text))
    }
    for insertion in insertions[index...] {
      extras.append((insertion.0, insertion.1))
    }
    var extraText: [Int: String] = [:]
    for extra in extras { extraText[extra.location, default: ""] += extra.text }
    edits = edits.map { edit in
      (edit.range, edit.text + (extraText.removeValue(forKey: edit.range.location) ?? ""))
    }
    for (location, text) in extraText.sorted(by: { $0.key < $1.key }) {
      edits.append((NSRange(location: location, length: 0), text))
    }
    edits.sort { $0.range.location < $1.range.location }
    let text = NSMutableString(string: String(decoding: units, as: UTF16.self))
    for edit in edits.reversed() {
      text.replaceCharacters(in: edit.range, with: edit.text)
    }
    let replacements = edits.map { NoteTasks.Replacement(range: $0.range, text: $0.text) }
    return (
      NoteTasks.Change(replacements: replacements, selection: NSRange(location: 0, length: 0)),
      Array((text as String).utf16)
    )
  }

  /// 上色之后照同一个扫描器认一遍：看得见的字一样；每个字除颜色以外的样式和原来一样；颜色都是想要的。
  /// 新旧两行各只扫一遍（`blocked` 是 `recolor` 已经算好的「能不能上色」）——原来每个看得见的字都把整行重新
  /// 扫一遍，长段落全选上色是平方的
  private static func recolorMatches(
    old: [UInt16], oldSpans: [Span], blocked: [Bool], new: [UInt16], section: Range<Int>,
    color: NoteColor?
  ) -> Bool {
    let oldVisible = visible(old, spans: oldSpans)
    let newSpans = inline(new, in: contentStart(of: new)..<new.count)
    let newVisible = visible(new, spans: newSpans)
    guard oldVisible.units == newVisible.units else { return false }
    // 旧的每个可见字原来什么颜色（看它自己的位置）
    let oldColors = colors(at: old, spans: oldSpans)
    let newColors = colors(at: new, spans: newSpans)
    let oldShapes = shapes(of: old, spans: oldSpans)
    let newShapes = shapes(of: new, spans: newSpans)
    for (offset, oldIndex) in oldVisible.indices.enumerated() {
      let newIndex = newVisible.indices[offset]
      guard oldShapes.flags[oldIndex] == newShapes.flags[newIndex],
        oldShapes.links[oldIndex] == newShapes.links[newIndex]
      else { return false }
      let wanted = section.contains(oldIndex) && !blocked[oldIndex] ? color : oldColors[oldIndex]
      guard newColors[newIndex] == wanted else { return false }
    }
    // 附件字符不许被包进颜色里
    for index in new.indices where new[index] == 0xFFFC {
      guard newColors[index] == nil else { return false }
    }
    return true
  }

  /// 看得见的字（去掉所有标记）和它们在这一行里的位置
  private static func visible(
    _ units: [UInt16], spans: [Span], hiding extra: [NSRange] = []
  ) -> (indices: [Int], units: [UInt16]) {
    var hidden = [Bool](repeating: false, count: units.count)
    for range in extra {
      for index in range.location..<NSMaxRange(range) where index < units.count {
        hidden[index] = true
      }
    }
    for span in spans where span.kind == .marker {
      let end = min(NSMaxRange(span.range), units.count)
      guard span.range.location < end else { continue }
      for index in span.range.location..<end { hidden[index] = true }
    }
    var indices: [Int] = []
    var shown: [UInt16] = []
    indices.reserveCapacity(units.count)
    shown.reserveCapacity(units.count)
    for index in units.indices where !hidden[index] {
      indices.append(index)
      shown.append(units[index])
    }
    return (indices, shown)
  }

  /// 每个字是什么颜色（同 `colorRuns`）
  private static func colors(at units: [UInt16], spans: [Span]) -> [NoteColor?] {
    var found = [NoteColor?](repeating: nil, count: units.count)
    for run in colorRuns(in: spans) {
      for index in run.range.location..<NSMaxRange(run.range) where index < units.count {
        found[index] = run.color
      }
    }
    return found
  }

  /// 每个字除颜色和标记以外的样子：样式按位存（任务状态三位、标题级别三位、其余每种一位），链接的地址另外
  /// 一字一份。扫一遍区间往数组里填，不再每个字都把全部区间过一遍
  private struct Shapes {
    var flags: [UInt16]
    var links: [String?]
  }

  private static func shapes(of units: [UInt16], spans: [Span]) -> Shapes {
    var flags = [UInt16](repeating: 0, count: units.count)
    var links = [String?](repeating: nil, count: units.count)
    for span in spans {
      let end = min(NSMaxRange(span.range), units.count)
      guard span.range.location < end else { continue }
      let range = span.range.location..<end
      if case .link(let address) = span.kind {
        for index in range { links[index] = address }
        continue
      }
      let flag: UInt16
      switch span.kind {
      case .color, .marker, .link: continue
      // 任务状态 0 是「不是任务」，五种状态用 1–5（低三位）
      case .box(let state): flag = UInt16(state.rawValue + 1)
      case .done: flag = 0x0008
      case .heading(let level): flag = UInt16(level) << 4
      case .bold: flag = 0x0080
      case .italic: flag = 0x0100
      case .strike: flag = 0x0200
      case .code: flag = 0x0400
      case .quote: flag = 0x0800
      case .bullet: flag = 0x1000
      case .codeBlock: flag = 0x2000
      case .fence: flag = 0x4000
      }
      for index in range { flags[index] |= flag }
    }
    return Shapes(flags: flags, links: links)
  }

  /// 正文去掉颜色的标记（`[`、`]{red}`）之后的字（字数、搜索用）：别的 Markdown 标记照旧留着（那是用户自己打的）。
  /// 代码块里的行不动
  static func strippingColors(from body: String) -> String {
    guard body.contains("]{") else { return body }
    let text = body as NSString
    let blocks = codeBlocks(in: text)
    let result = NSMutableString(capacity: text.length)
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      if NoteMarkdown.role(at: start, in: blocks) == nil, line.contains("]{") {
        let units = Array(line.utf16)
        let runs = colorRuns(in: inline(units, in: 0..<units.count))
        let resultLine = NSMutableString(string: line)
        for range in runs.flatMap({ [$0.open, $0.close] }).sorted(by: { $0.location > $1.location })
        {
          resultLine.deleteCharacters(in: range)
        }
        result.append(resultLine as String)
      } else {
        result.append(line)
      }
      result.append(
        text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = max(end, location + 1)
    }
    return result as String
  }

  // MARK: 颜色 ⇄ <span>（导出 / 导入 Markdown 文件时换，正文里不存这些）

  /// 正文档 → 导出用的 Markdown：代码块里的行不动；别的行把扫描器认得出的颜色换成
  /// `<span style="color: #A11A14">字</span>`（浅色那套的色值，大小写和空格按我们自己写出去的来）
  static func html(from body: String) -> String {
    guard body.contains("]{") else { return body }
    let text = body as NSString
    let blocks = codeBlocks(in: text)
    let result = NSMutableString(capacity: text.length)
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      if NoteMarkdown.role(at: start, in: blocks) == nil, line.contains("]{") {
        result.append(htmlLine(line))
      } else {
        result.append(line)
      }
      result.append(
        text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = max(end, location + 1)
    }
    return result as String
  }

  private static func htmlLine(_ line: String) -> String {
    let units = Array(line.utf16)
    let runs = colorRuns(in: inline(units, in: 0..<units.count))
    guard !runs.isEmpty else { return line }
    var deletions: [NSRange] = []
    var insertions: [(Int, String)] = []
    for run in runs {
      deletions.append(run.open)
      deletions.append(run.close)
      insertions.append(
        (run.open.location, "<span style=\"color: #\(String(format: "%06X", run.color.light))\">"))
      insertions.append((NSMaxRange(run.range), "</span>"))
    }
    return String(
      decoding: edits(units: units, deletions: deletions, insertions: insertions).newUnits,
      as: UTF16.self)
  }

  /// 导入 Markdown 时把**我们自己写出去的那种**颜色换回 `[字]{名字}`：同一行里
  /// `<span style="color: #RRGGBB">`（冒号后空格可有可无、末尾分号可有可无、十六进制不分大小写），色值是这 6 个之一，
  /// 到第一个 `</span>` 为止、中间不含 `<span`、不在行内代码和代码块里。别的 HTML 原样留着（显示成字）
  static func body(fromHTML body: String) -> String {
    guard body.contains("<span") else { return body }
    let text = body as NSString
    let blocks = codeBlocks(in: text)
    let result = NSMutableString(capacity: text.length)
    var location = 0
    while location < text.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      if NoteMarkdown.role(at: start, in: blocks) == nil, line.contains("<span") {
        result.append(decodeColors(in: line))
      } else {
        result.append(line)
      }
      result.append(
        text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      location = max(end, location + 1)
    }
    return result as String
  }

  private static func decodeColors(in line: String) -> String {
    let text = line as NSString
    let units = Array(line.utf16)
    let code = inline(units, in: 0..<units.count).filter { $0.kind == .code }.map(\.range)
    var edits: [(range: NSRange, text: String)] = []
    var search = 0
    while search < text.length {
      let opening = text.range(
        of: "<span style=\"color:", options: [],
        range: NSRange(location: search, length: text.length - search))
      guard opening.location != NSNotFound else { break }
      if code.contains(where: { NSLocationInRange(opening.location, $0) }) {
        search = NSMaxRange(opening)
        continue
      }
      guard let found = parseColorSpan(text, opening: opening) else {
        search = NSMaxRange(opening)
        continue
      }
      edits.append(
        (
          NSRange(location: opening.location, length: found.end - opening.location),
          "[\(found.content)]{\(found.color.name)}"
        ))
      search = found.end
    }
    guard !edits.isEmpty else { return line }
    let result = NSMutableString(string: line)
    for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
    return result as String
  }

  /// 从 `<span style="color:` 往后认；认得出给颜色、内容、整段到哪结束（`</span>` 后面）
  private static func parseColorSpan(
    _ text: NSString, opening: NSRange
  ) -> (color: NoteColor, content: String, end: Int)? {
    var index = NSMaxRange(opening)
    if index < text.length, text.character(at: index) == 0x20 { index += 1 }
    guard index + 8 <= text.length, text.character(at: index) == 0x23 else { return nil }
    index += 1
    var hex = 0
    for _ in 0..<6 {
      guard index < text.length, let scalar = UnicodeScalar(text.character(at: index)),
        let digit = Character(scalar).hexDigitValue
      else { return nil }
      hex = hex * 16 + digit
      index += 1
    }
    if index < text.length, text.character(at: index) == 0x3B { index += 1 }
    // 我们写的是 style="color: #RRGGBB"：十六进制后面是收尾的引号，再是 >
    if index < text.length, text.character(at: index) == 0x22 { index += 1 }
    guard index < text.length, text.character(at: index) == 0x3E else { return nil }
    let contentStart = index + 1
    let closing = text.range(
      of: "</span>", options: [],
      range: NSRange(location: contentStart, length: text.length - contentStart))
    guard closing.location != NSNotFound else { return nil }
    let content = text.substring(
      with: NSRange(location: contentStart, length: closing.location - contentStart))
    guard !content.isEmpty,
      !content.lowercased().contains("<span"),
      let color = NoteColor.value(hex)
    else { return nil }
    return (color, content, NSMaxRange(closing))
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
  /// 去过的那一行剩下的是内容，只去行内的（blocks 给 false）。
  /// 图片的令牌（第 7 批）整段换成「[图片]」（它里面的 `[` `]` `(` `)` 不是标记）
  static func plain(_ line: String, blocks: Bool) -> String {
    let line = NoteImages.display(line)
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
