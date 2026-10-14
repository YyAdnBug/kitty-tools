// 便签正文里的 Markdown（PLAN §10「便签」第 6 批，拍板 C① 第二步「边打边变样」）：认标记的扫描器。全是纯函数、
// **不用正则**，一遍从左到右扫完；位置都是 UTF-16 的。样式怎么叠、换成什么属性在 NoteStyles，这里只管「哪一段是什么」。
// 所有语法都不跨行：一行一行扫和整篇扫结果一样（NoteStyles 按行重排靠这一条）。
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
// - plain(_:)：把一行里的标记去掉，给标题和摘要用（Note.displayTitle / preview）。
// 不做（PLAN §10「便签」的「不做 / 以后再说」）：代码块、表格、有序列表的样式、分隔线、裸网址自动成链接、引用嵌套、
// ⌘B / ⌘I 这类加标记的快捷键。
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
