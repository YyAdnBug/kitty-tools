// 便签正文的样式（PLAN §10「便签」第 5 批任务、第 6 批 Markdown）：存的是纯文本，样式是显示时加的属性——
// 只改属性、不改字、不进撤销栈、不动选区。分几块：
// - spans(in:markdown:)：纯函数，一行文字 → 若干「区间 + 样式种类」。任务的两种（方框那个字、做完的任务的内容）
//   不看 Markdown 开关；开着时再加 Markdown 的（标题、粗体、斜体、删除线、行内代码、链接、引用、无序列表的符号，
//   和它们的标记）——行内的那些由 NoteMarkdown 的扫描器认。任务行的内容里只认行内样式。
// - runs(of:)：纯函数，把可以互相套着的区间叠成一段段「最后长什么样」（Look）：字号跟这一行的标题级别走，
//   粗细 / 倾斜 / 等宽 / 划线叠上去——标题里的粗体不会缩回正文字号。
// - Pending / lines(covering:)：纯函数，编辑过的区间 → 要重排的那几行（前后各扩一个字符、扩到整行；输入法组字期间
//   攒着，确认后一次补上）。
// - apply：薄的一层，把 Look 换成属性写进文本存储（先把这几行铺回基础样式，再一段段写）。**标记字符**（# ** ` [ 这些）：
//   光标在的那些行（shown）上淡淡显示（shownKey），别的行带 hiddenKey——布局管理器生成字形时（hideGlyphs、
//   isHidden，NoteTextView 是它的代理）把带这个属性的字当成**零宽的控制字符**：不画、不占宽度（涂成透明的话宽度还在）。
//   outdated 找出「露着但不该露」「该露但还藏着」的行——露着标记的行是记在字上的（属性跟着字走），编辑把它挪到哪都找得到。
//   **不用空字形（.null）**（Noty 的做法；2026-10-13 独立小程序实测 macOS 15.7）：行首的空字形会被排进**上一行**的
//   行尾——从长的一行按 ↓ 到短的一行，光标落到再下一行的行首；按那个字去问「在哪一行」得到的也是上一行。零宽的
//   控制字符留在自己的行里，点击、↑↓、行首行尾都对。
// 方框「☐」「☑」用同一种字体（Apple Symbols）：系统字体里只有「☑」没有「☐」，各走各的后备字体的话两个一大一小、
// 打勾时后面的字还会左右挪。
// ponytail: 方框就是那两个字形，没有自己画；Apple Symbols 的行高比系统字体略大，任务行因此比普通行高 1 pt 左右
// （各字号不同，13 / 17 号字是 0）。要圆角的、做完是实心的方框，或者行高分毫不差：把方框那个字藏起来（hiddenKey）
// 在 NoteTextView.draw 里自己画。
// ponytail: outdated 每次把整篇的属性段过一遍（选区每变一次一遍）；10 KB 以内无感。实测（Release、M3 Air）1 MB、
// 11400 行、每行都有标记的正文：每挪一次光标约 31 ms、每打一个字约 51 ms；全选约 1.4 s、再点一下收回约 2.1 s
// （另加重新排版）。真卡了改成记「露着的是哪一段」、跟着编辑挪（Pending 的路数），再加一条「选区超过若干行就不露」。

import AppKit

nonisolated enum NoteStyles {
  /// 样式的种类
  enum Kind: Equatable, Sendable {
    /// 任务的方框（☐ / ☑ 那一个字）
    case box
    /// 做完的任务的内容：划线、墨色变淡
    case done
    /// 标题（1–6 级）：整行，连标记
    case heading(Int)
    case bold
    case italic
    case strike
    /// 行内代码（不含两头的反引号）
    case code
    /// 链接的字；带着它的地址（原样，能不能打开看 NoteMarkdown.url）
    case link(String)
    /// 引用：整行，连标记
    case quote
    /// 无序列表的符号（- * +），和后面没有字的引用的 >：变淡，不藏
    case bullet
    /// Markdown 的标记字符：光标不在这一行时藏起来，在的时候淡淡显示
    case marker
  }

  /// 一段样式：区间是 UTF-16 的、相对这一行的开头。区间可以互相套着（粗体里的斜体、标题里的链接）
  struct Span: Equatable, Sendable {
    var range: NSRange
    var kind: Kind
  }

  /// 这一行（不含行尾的换行）要加哪些样式。markdown：设置 › 便签「Markdown 样式」开没开（任务不看它）
  static func spans(in line: String, markdown: Bool) -> [Span] {
    let units = Array(line.utf16)
    let whole = NSRange(location: 0, length: units.count)
    let prefix = NoteTasks.prefix(of: units)
    if let prefix, case .task(let isDone) = prefix.lead {
      var spans = [Span(range: NSRange(location: prefix.indent, length: 1), kind: .box)]
      if isDone, units.count > prefix.contentStart {
        spans.append(
          Span(
            range: NSRange(
              location: prefix.contentStart, length: units.count - prefix.contentStart),
            kind: .done))
      }
      // 任务行的内容里只认行内样式
      return markdown
        ? spans + NoteMarkdown.inline(units, in: prefix.contentStart..<units.count) : spans
    }
    guard markdown else { return [] }
    var spans: [Span] = []
    var content = 0
    if let heading = NoteMarkdown.heading(units) {
      spans = [
        Span(range: whole, kind: .heading(heading.level)),
        Span(range: heading.marker, kind: .marker),
      ]
      content = NSMaxRange(heading.marker)
    } else if let marker = NoteMarkdown.quote(units) {
      // 后面没有字的引用（夹在几行引用中间的空行）：> 不藏、只是变淡——全藏起来的话这一行什么都没有，
      // 在正文末尾时连行都不占
      let isEmpty = NSMaxRange(marker) == units.count
      spans = [
        Span(range: whole, kind: .quote), Span(range: marker, kind: isEmpty ? .bullet : .marker),
      ]
      content = NSMaxRange(marker)
    } else if let prefix, case .bullet = prefix.lead {
      spans = [Span(range: NSRange(location: prefix.indent, length: 1), kind: .bullet)]
      content = prefix.contentStart
    }
    return spans + NoteMarkdown.inline(units, in: content..<units.count)
  }

  // MARK: 叠起来

  /// 一小段字叠完之后长什么样
  struct Look: Equatable, Sendable {
    /// 标题的级别；0 = 不在标题里
    var heading = 0
    var isBold = false
    var isItalic = false
    var isStruck = false
    var isCode = false
    var isQuote = false
    var isDone = false
    var isBullet = false
    var isBox = false
    var isMarker = false
    /// 在链接的字里：它的地址
    var link: String?
  }

  /// 一段样子一样的字：区间是 UTF-16 的、相对这一行的开头
  struct Run: Equatable, Sendable {
    var range: NSRange
    var look: Look
  }

  /// 扫到某个位置时在几层什么里面（同一种可以套几层：粗体里的粗体）
  private struct Depth {
    var box = 0
    var done = 0
    var bold = 0
    var italic = 0
    var strike = 0
    var code = 0
    var quote = 0
    var bullet = 0
    var marker = 0
    var heading = 0
    var link: String?

    /// 进了（step 是 1）/ 出了（-1）一段 kind
    mutating func move(_ kind: Kind, by step: Int) {
      switch kind {
      case .box: box += step
      case .done: done += step
      case .bold: bold += step
      case .italic: italic += step
      case .strike: strike += step
      case .code: code += step
      case .quote: quote += step
      case .bullet: bullet += step
      case .marker: marker += step
      // 一行最多一个标题；链接里不套链接
      case .heading(let level): heading = step > 0 ? level : 0
      case .link(let address): link = step > 0 ? address : nil
      }
    }

    var look: Look {
      Look(
        heading: heading, isBold: bold > 0, isItalic: italic > 0, isStruck: strike > 0,
        isCode: code > 0, isQuote: quote > 0, isDone: done > 0, isBullet: bullet > 0,
        isBox: box > 0, isMarker: marker > 0, link: link)
    }
  }

  /// 把一行的样式区间叠成一段段（从左到右、互不相交；什么样式都没有的那些段不给）
  static func runs(of spans: [Span]) -> [Run] {
    // 每段的两头各记一笔，按位置排好，从左到右数「现在在几层什么里面」
    var edges: [(at: Int, step: Int, kind: Kind)] = []
    for span in spans where span.range.length > 0 {
      edges.append((span.range.location, 1, span.kind))
      edges.append((NSMaxRange(span.range), -1, span.kind))
    }
    edges.sort { $0.at < $1.at }
    var runs: [Run] = []
    var depth = Depth()
    var last = 0
    for edge in edges {
      let look = depth.look
      if edge.at > last, look != Look() {
        runs.append(Run(range: NSRange(location: last, length: edge.at - last), look: look))
      }
      last = edge.at
      depth.move(edge.kind, by: edge.step)
    }
    return runs
  }

  // MARK: 要重排哪几行

  /// 攒着的「编辑过的区间」（文本存储每处理完一次改字报一次）：合成一段，后来的编辑让前面记下的位置跟着挪。
  /// 输入法组字期间只攒不用，确认后一次拿走
  struct Pending: Equatable, Sendable {
    private(set) var range: NSRange?

    /// 记一次编辑：edited 是改完之后那一段的位置，delta 是长度变了多少
    mutating func record(_ edited: NSRange, delta: Int) {
      guard let old = range else {
        range = edited
        return
      }
      // 改之前那一段到哪为止：在它后面的位置都挪了 delta
      let oldEnd = NSMaxRange(edited) - delta
      var (start, end) = (old.location, NSMaxRange(old))
      if start >= oldEnd { start += delta }
      if end >= oldEnd { end += delta }
      start = max(min(start, edited.location), 0)
      end = max(end, NSMaxRange(edited))
      range = NSRange(location: start, length: end - start)
    }

    /// 拿走攒着的那一段
    mutating func take() -> NSRange? {
      defer { range = nil }
      return range
    }
  }

  /// 编辑过的区间 → 要重排的那几行（整行，连行尾的换行）：前后各扩一个字符再扩到整行——插入、删除换行时
  /// 两头的行都要重排。区间夹进正文的长度里（攒着的时候正文又变短了也不越界）
  static func lines(covering edited: NSRange, in text: NSString) -> NSRange {
    let start = min(max(edited.location - 1, 0), text.length)
    let end = min(max(NSMaxRange(edited) + 1, start), text.length)
    return text.lineRange(for: NSRange(location: start, length: end - start))
  }

  // MARK: 数值（长相在 mac-whisker-notes.mdc「正文里的 Markdown」）

  /// 方框比正文的字大多少
  static let boxScale: CGFloat = 1.1
  /// 标题比正文的字大多少（一到六级；五、六级和正文一样大，只加粗）
  static let headingScales: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1, 1]
  /// 行内代码的等宽字比旁边的字小多少（正文 13 → 代码 12）
  static let codeScale: CGFloat = 0.92
  /// 斜体斜多少：用 obliqueness，不换字体——中文字体没有斜体字形
  static let obliqueness = 0.2
  /// 引用缩进多少、左边那条竖线多宽
  static let quoteIndent: CGFloat = 14
  static let quoteBarWidth: CGFloat = 3

  /// level 级标题的字号（整点）
  static func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
    (base * headingScales[min(max(level, 1), headingScales.count) - 1]).rounded()
  }

  /// 旁边的字是 size 号时行内代码的字号（整点）
  static func codeSize(_ size: CGFloat) -> CGFloat { (size * codeScale).rounded() }

  // MARK: 属性

  /// 标记字符藏着（零宽、不画）/ 露着（淡淡显示）
  static let hiddenKey = NSAttributedString.Key("KittyNoteHidden")
  static let shownKey = NSAttributedString.Key("KittyNoteShown")
  /// 链接的字上记着的地址（URL；只有能打开的才记）。不用系统的 .link：它带蓝色的样式和自己的点击行为
  static let linkKey = NSAttributedString.Key("KittyNoteLink")
  /// 引用的行（连行尾的换行：连着的几行引用是一整段，左边的竖线照它画）
  static let quoteKey = NSAttributedString.Key("KittyNoteQuote")

  /// 套用时要的字体和颜色（一条便签的纸色、字号、Markdown 开关定下来的）
  struct Theme {
    var font = NSFont.systemFont(ofSize: 15)
    /// 墨
    var ink = NSColor.textColor
    /// 做完的任务、无序列表的符号
    var faded = NSColor.secondaryLabelColor
    /// 引用的字（引用里的行内代码除外：它用墨）
    var secondary = NSColor.secondaryLabelColor
    /// 露出来的标记
    var marker = NSColor.tertiaryLabelColor
    /// 行内代码的底
    var codeFill = NSColor.quaternaryLabelColor
    /// 引用左边的竖线（NoteTextView 画）
    var bar = NSColor.separatorColor
    var markdown = true

    init() {}

    init(paper: NotePaper, fontSize: CGFloat, markdown: Bool) {
      font = .systemFont(ofSize: fontSize)
      ink = paper.inkColor
      faded = paper.fadedInkColor
      secondary = paper.secondaryInkColor
      marker = paper.markerInkColor
      codeFill = paper.codeFillColor
      bar = paper.quoteBarColor
      self.markdown = markdown
    }
  }

  /// 把 range 那几行（整行）的样式重排一遍：铺回基础样式，再按 spans 加。只动属性。
  /// shown：现在该露出标记的行（整行的区间）——行首落在里面的那些行，标记淡淡显示，别的行藏起来
  @MainActor
  static func apply(to storage: NSTextStorage, lines range: NSRange, theme: Theme, shown: [NSRange])
  {
    guard range.length > 0 else { return }
    let text = storage.mutableString
    let base = theme.font
    let box = NSFont(name: "AppleSymbols", size: (base.pointSize * boxScale).rounded())
    // 方框往上抬一点：Apple Symbols 的字形坐在基线上，抬到和字的中线差不多齐
    let lift = box.map { max(0, base.descender - $0.descender) } ?? 0
    let quoteStyle = NSMutableParagraphStyle()
    quoteStyle.firstLineHeadIndent = quoteIndent
    quoteStyle.headIndent = quoteIndent

    func attributes(for look: Look, isShown: Bool) -> [NSAttributedString.Key: Any] {
      if look.isBox {
        return [.font: box ?? base, .baselineOffset: lift, .foregroundColor: theme.ink]
      }
      // 字号跟这一行的标题级别走，粗细、等宽叠上去
      let size = look.heading > 0 ? headingSize(look.heading, base: base.pointSize) : base.pointSize
      let weight: NSFont.Weight =
        look.heading > 0 ? (look.isBold ? .heavy : .bold) : (look.isBold ? .bold : .regular)
      var result: [NSAttributedString.Key: Any] = [:]
      if look.isCode {
        result[.font] = NSFont.monospacedSystemFont(ofSize: codeSize(size), weight: weight)
        result[.backgroundColor] = theme.codeFill
      } else if size == base.pointSize, weight == .regular {
        result[.font] = base
      } else {
        result[.font] = NSFont.systemFont(ofSize: size, weight: weight)
      }
      if look.isMarker {
        result[.foregroundColor] = theme.marker
      } else if look.isDone || look.isBullet {
        result[.foregroundColor] = theme.faded
      } else if look.isQuote, !look.isCode {
        // 引用里的行内代码不走这里、用墨色：次要的墨压在代码的底上不够 4.5:1（沙色浅纸）。做完的任务里的代码
        // 照旧跟着变淡（上一条）
        result[.foregroundColor] = theme.secondary
      } else {
        result[.foregroundColor] = theme.ink
      }
      if look.isItalic, !look.isMarker { result[.obliqueness] = obliqueness }
      // 做完的任务整段划线（连露出来的标记）；删除线自己的两个 ~~ 不划
      if look.isDone || (look.isStruck && !look.isMarker) {
        result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let address = look.link {
        result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        if let url = NoteMarkdown.url(address) { result[linkKey] = url }
      }
      if look.isQuote {
        result[.paragraphStyle] = quoteStyle
        result[quoteKey] = true
      }
      if look.isMarker { result[isShown ? shownKey : hiddenKey] = true }
      return result
    }

    storage.beginEditing()
    storage.setAttributes([.font: base, .foregroundColor: theme.ink], range: range)
    var location = range.location
    while location < NSMaxRange(range) {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      let isShown = shown.contains { $0.location <= start && start < NSMaxRange($0) }
      var isQuote = false
      for run in runs(of: spans(in: line, markdown: theme.markdown)) {
        storage.setAttributes(
          attributes(for: run.look, isShown: isShown),
          range: NSRange(location: start + run.range.location, length: run.range.length))
        isQuote = isQuote || run.look.isQuote
      }
      // 引用行行尾的换行也记上：连着的几行引用是一整段（竖线不断开）
      if isQuote, end > contentsEnd {
        storage.addAttribute(
          quoteKey, value: true, range: NSRange(location: contentsEnd, length: end - contentsEnd))
      }
      location = max(end, location + 1)
    }
    storage.endEditing()
    // 标记藏 / 露要重新生成字形（只这几行）。实测 macOS 15.7 改完属性系统自己会失效一遍，这里明说，不靠它
    for manager in storage.layoutManagers {
      manager.invalidateGlyphs(
        forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
      manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
      manager.invalidateDisplay(forCharacterRange: range)
    }
  }

  /// 标记露 / 藏得不对的那些行（整行；从前到后、互不相邻——挨着的并成一段）：露着但不在 shown 里的，和在 shown 里
  /// 但还藏着的。shown 的意思同 apply。拿到之后一段段各自 apply
  @MainActor
  static func outdated(in storage: NSTextStorage, shown: [NSRange]) -> [NSRange] {
    let text = storage.mutableString
    let full = NSRange(location: 0, length: storage.length)
    var found: [NSRange] = []
    storage.enumerateAttribute(shownKey, in: full, options: .longestEffectiveRangeNotRequired) {
      value, range, _ in
      guard value != nil else { return }
      let line = text.lineRange(for: NSRange(location: range.location, length: 0))
      if !shown.contains(where: { $0.location <= line.location && line.location < NSMaxRange($0) })
      {
        found.append(line)
      }
    }
    for target in shown {
      let range = NSIntersectionRange(target, full)
      guard range.length > 0 else { continue }
      var isHidden = false
      storage.enumerateAttribute(hiddenKey, in: range, options: .longestEffectiveRangeNotRequired) {
        value, _, stop in
        guard value != nil else { return }
        isHidden = true
        stop.pointee = true
      }
      if isHidden { found.append(text.lineRange(for: range)) }
    }
    var merged: [NSRange] = []
    for lines in found.sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, lines.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, lines)
      } else {
        merged.append(lines)
      }
    }
    return merged
  }

  /// 布局管理器生成一批字形时问到这里（NSLayoutManagerDelegate 的 shouldGenerateGlyphs，NoteTextView 转过来）：
  /// 带 hiddenKey 的字，字形属性改成「控制字符」——不画；宽度由下面的 isHidden 那一问给成零。返回存了几个字形；
  /// 0 = 这一批没有要藏的，照系统默认的来。布局时调的代码：只动传进来的布局管理器、只读文本存储上的属性
  static func hideGlyphs(
    in layoutManager: NSLayoutManager, glyphs: UnsafePointer<CGGlyph>,
    properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
    font: NSFont, glyphRange: NSRange
  ) -> Int {
    let count = glyphRange.length
    guard count > 0, let storage = layoutManager.textStorage else { return 0 }
    let indexes = UnsafeBufferPointer(start: characterIndexes, count: count)
    guard let low = indexes.min(), let high = indexes.max(), high < storage.length else { return 0 }
    let covered = NSRange(location: low, length: high - low + 1)
    // 一段属性一样的字只问一次
    var effective = NSRange(location: NSNotFound, length: 0)
    var isHidden =
      storage.attribute(hiddenKey, at: low, longestEffectiveRange: &effective, in: covered) != nil
    // 这一批里没有要藏的（绝大多数时候）：什么都不建
    if !isHidden, NSMaxRange(effective) >= NSMaxRange(covered) { return 0 }
    var changed = Array(UnsafeBufferPointer(start: properties, count: count))
    for position in 0..<count {
      let character = indexes[position]
      if !NSLocationInRange(character, effective) {
        isHidden =
          storage.attribute(
            hiddenKey, at: character, longestEffectiveRange: &effective, in: covered) != nil
      }
      if isHidden { changed[position] = .controlCharacter }
    }
    changed.withUnsafeBufferPointer { buffer in
      guard let pointer = buffer.baseAddress else { return }
      layoutManager.setGlyphs(
        glyphs, properties: pointer, characterIndexes: characterIndexes, font: font,
        forGlyphRange: glyphRange)
    }
    return count
  }

  /// 第 index 个字是不是藏着的标记（布局管理器排到一个控制字符时来问怎么处理：是的话零宽，不是的话——换行、Tab——
  /// 照系统原来的）。同样是布局时调的
  static func isHidden(at index: Int, in layoutManager: NSLayoutManager) -> Bool {
    guard let storage = layoutManager.textStorage, index < storage.length else { return false }
    return storage.attribute(hiddenKey, at: index, effectiveRange: nil) != nil
  }
}
