// 便签正文的样式（PLAN §10「便签」第 5 批任务、第 6 批 Markdown、手测反馈第 4 批行距和代码块）：存的是纯文本，
// 样式是显示时加的属性——
// 只改属性、不改字、不进撤销栈、不动选区。分几块：
// - spans(in:markdown:)：纯函数，一行文字 → 若干「区间 + 样式种类」。任务的两种（方框那个字、做完的任务的内容）
//   不看 Markdown 开关；开着时再加 Markdown 的（标题、粗体、斜体、删除线、行内代码、链接、引用、无序列表的符号，
//   和它们的标记）——行内的那些由 NoteMarkdown 的扫描器认。任务行的内容里只认行内样式。
// - runs(of:)：纯函数，把可以互相套着的区间叠成一段段「最后长什么样」（Look）：字号跟这一行的标题级别走，
//   粗细 / 倾斜 / 等宽 / 划线叠上去——标题里的粗体不会缩回正文字号。
// - Pending / lines(covering:)：纯函数，编辑过的区间 → 要重排的那几行（前后各扩一个字符、扩到整行；输入法组字期间
//   攒着，确认后一次补上）。
// - 行距（手测反馈第 4 批）：每一行一个段落样式，行高定死 = 这一行的主字体（lineFontKey：标题的字 / 等宽的字 /
//   正文的字）的字号 × 倍数（Spacing 三档）；标题上下、引用块和代码块整块上下留一点（段前段后）。字在行里竖直居中由
//   布局管理器的代理定（centerLine：基线、和插入点按着画的 usedRect）。
// - 代码块：块里的行和围栏行整行一种样式（blockSpans），整行记着角色（roleKey）；角色跟着正文里围栏的配对变，
//   所以编辑之后除了改过的行，还要排角色变了的行（roleChanges），再各往上下带一行（neighborLines：引用块的段前段后）。
// - apply：薄的一层，把 Look 换成属性写进文本存储（先把这几行铺回基础样式，再一段段写）。**标记字符**（# ** ` [ 这些）：
//   光标在的那些行（shown）上淡淡显示（shownKey），别的行带 hiddenKey——布局管理器生成字形时（hideGlyphs、
//   isHidden，NoteTextView 是它的代理）把带这个属性的字当成**零宽的控制字符**：不画、不占宽度（涂成透明的话宽度还在）。
//   outdated 找出「露着但不该露」「该露但还藏着」的行——露着标记的行是记在字上的（属性跟着字走），编辑把它挪到哪都找得到。
//   **不用空字形（.null）**（Noty 的做法；2026-10-13 独立小程序实测 macOS 15.7）：行首的空字形会被排进**上一行**的
//   行尾——从长的一行按 ↓ 到短的一行，光标落到再下一行的行首；按那个字去问「在哪一行」得到的也是上一行。零宽的
//   控制字符留在自己的行里，点击、↑↓、行首行尾都对。
// 方框「☐」「☑」用同一种字体（Apple Symbols）：系统字体里只有「☑」没有「☐」，各走各的后备字体的话两个一大一小、
// 打勾时后面的字还会左右挪。
// 行高定死、字按主字体居中之后，任务行和普通行一样高（原来 Apple Symbols 的行高略大，任务行高 1 pt 左右）。
// ponytail: 方框就是那两个字形，没有自己画。要圆角的、做完是实心的方框：把方框那个字藏起来（hiddenKey）在
// NoteTextView.draw 里自己画。
// ponytail: outdated 每次把整篇的属性段过一遍（选区每变一次一遍）；10 KB 以内无感。实测（Release、M3 Air）1.2 MB、
// 11400 行、每行都有标记的正文：每挪一次光标约 31 ms、每打一个字约 51 ms；全选约 1.4 s、再点一下收回约 2.1 s
// （另加重新排版）。真卡了改成记「露着的是哪一段」、跟着编辑挪（Pending 的路数），再加一条「选区超过若干行就不露」。
// 手测反馈第 4 批之后（同样的正文，屏外的 -O 小程序，没进仓库；同一个程序量改之前是
// 打一个字 37 ms、挪一次光标 25 ms、之后排版到底 864 ms）：打一个字约 42 ms（中间有 20 个代码块时约 48 ms：
// 每次收尾整篇重认一遍代码块约 2.5 ms、有代码块时再找一遍角色变了的行），挪一次光标约 26 ms，之后排版到底约 960 ms
// （布局管理器的代理每个行片段都要问一次）；改一个围栏让后面 20 个块全部重新配对（整篇几乎都重排）约 430 ms。

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
    /// 代码块里的一行（整行，按原文）；代码块的围栏行（整行，一直显示、不藏）
    case codeBlock
    case fence
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

  /// 代码块里的一行：整行一种样式，里面什么 Markdown 都不认（任务的方框、列表符号也是原文）
  static func blockSpans(in line: String, role: NoteMarkdown.Role) -> [Span] {
    [
      Span(
        range: NSRange(location: 0, length: (line as NSString).length),
        kind: role == .content ? .codeBlock : .fence)
    ]
  }

  /// 一行在段落上是哪种（行高、段前段后、缩进按它定）
  enum Shape: Hashable, Sendable {
    case plain
    case heading(Int)
    case quote
    case code(NoteMarkdown.Role)
  }

  /// 这一行（不含行尾的换行）在段落上是哪种；和 spans 认的一样（任务行不是标题、不是引用）。role：它在不在代码块里
  static func shape(of units: [UInt16], markdown: Bool, role: NoteMarkdown.Role?) -> Shape {
    if let role { return .code(role) }
    guard markdown else { return .plain }
    if let prefix = NoteTasks.prefix(of: units), case .task = prefix.lead { return .plain }
    if let heading = NoteMarkdown.heading(units) { return .heading(heading.level) }
    return NoteMarkdown.quote(units) != nil ? .quote : .plain
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
    var isCodeBlock = false
    var isFence = false
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
    var codeBlock = 0
    var fence = 0
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
      case .codeBlock: codeBlock += step
      case .fence: fence += step
      // 一行最多一个标题；链接里不套链接
      case .heading(let level): heading = step > 0 ? level : 0
      case .link(let address): link = step > 0 ? address : nil
      }
    }

    var look: Look {
      Look(
        heading: heading, isBold: bold > 0, isItalic: italic > 0, isStruck: strike > 0,
        isCode: code > 0, isQuote: quote > 0, isDone: done > 0, isBullet: bullet > 0,
        isBox: box > 0, isMarker: marker > 0, isCodeBlock: codeBlock > 0, isFence: fence > 0,
        link: link)
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

  /// 这几行（整行）再往上、往下各带一行：引用块的段前段后看的是上下两行是不是引用，一行变了，挨着的两行也要重排
  static func neighborLines(_ lines: NSRange, in text: NSString) -> NSRange {
    let start =
      lines.location > 0
      ? text.lineRange(for: NSRange(location: lines.location - 1, length: 0)).location
      : lines.location
    let end =
      NSMaxRange(lines) < text.length
      ? NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0)))
      : NSMaxRange(lines)
    return NSRange(location: start, length: end - start)
  }

  /// 几段区间从前到后排好，重叠的、首尾相接的并成一段
  static func merged(_ ranges: [NSRange]) -> [NSRange] {
    var merged: [NSRange] = []
    for range in ranges.sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  /// 代码块里的角色和字上记着的（roleKey）不一样的那些行（整行，从前到后、挨着的并成一段）：开头、收尾的围栏配上了 /
  /// 拆开了，块里的行一下子都变了。字上记着的是上一次重排时的角色（重排一行就写一次），blocks 是照现在的正文认的。
  /// 只看两边沾着代码块的行：字上记着角色的、现在在块里的；两边都没有代码块时什么都不做
  static func roleChanges(in storage: NSTextStorage, blocks: [NoteMarkdown.CodeBlock]) -> [NSRange]
  {
    let text = storage.mutableString
    let full = NSRange(location: 0, length: storage.length)
    var found: [NSRange] = []
    func check(_ range: NSRange) {
      var location = range.location
      while location < NSMaxRange(range) {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let stored = storage.attribute(roleKey, at: line.location, effectiveRange: nil) as? Int
        // 还没排过的行（整段换字时只当场排了开头一屏，NoteTextView.styleRest 在后面补）不算：轮到它时照那时的正文排
        if stored != NoteMarkdown.role(at: line.location, in: blocks)?.rawValue,
          storage.attribute(lineFontKey, at: line.location, effectiveRange: nil) != nil
        {
          found.append(line)
        }
        location = max(NSMaxRange(line), location + 1)
      }
    }
    storage.enumerateAttribute(roleKey, in: full) { value, range, _ in
      if value != nil { check(range) }
    }
    for block in blocks { check(NSIntersectionRange(block.range, full)) }
    return merged(found)
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
  /// 标题上方、下方各留多少（正文一行的行高的几分之几；正文第一行的段前 TextKit 本来就不给）
  static let headingBefore: CGFloat = 0.5
  static let headingAfter: CGFloat = 0.25
  /// 引用块、代码块整块的上下各留多少（同上）
  static let blockMargin: CGFloat = 0.25
  /// 代码块里的字离那块底的左右边多远；那块底比开头、收尾两行再往上下各多出多少（伸进块外留的那点里：
  /// 围栏行的反引号贴着行顶，不多出一点看着顶上挤）；Tab 是几个空格那么宽
  static let codeInset: CGFloat = 8
  static let codePadding: CGFloat = 3
  static let codeTabWidth = 4

  /// 正文的行距（设置 › 便签「行距」，Prefs.notesLineSpacing）：每一行的行高 = 这一行的字号 × 倍数（整点），字在行里
  /// 竖直居中。标准 1.45：Typora、Notion、Obsidian 大多 1.5，便签的字小一点、略紧
  enum Spacing: String, CaseIterable, Sendable {
    case compact, standard, relaxed

    var multiple: CGFloat {
      switch self {
      case .compact: 1.2
      case .standard: 1.45
      case .relaxed: 1.7
      }
    }

    var title: String {
      switch self {
      case .compact: "紧凑"
      case .standard: "标准"
      case .relaxed: "宽松"
      }
    }
  }

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
  /// 代码块里的行（整行连换行）记着它的角色（NoteMarkdown.Role 的 rawValue）：NoteTextView 照它画那块底，
  /// 编辑之后照它找出角色变了的行（roleChanges）
  static let roleKey = NSAttributedString.Key("KittyNoteCodeRole")
  /// 这一行的主字体（整行连换行）：标题行是标题的字、代码块是等宽的字、别的是正文的字。行高按它的字号算，布局时字的
  /// 上下沿也按它居中（centerLine：一行里混着别的字——方框、行内代码——也不挪基线）
  static let lineFontKey = NSAttributedString.Key("KittyNoteLineFont")
  /// 图片那一行（整行连换行）记着图占多高（CGFloat）：段落样式按它撑高（图片会被裁成一行高，样机量出来的），
  /// 布局时 centerLine 按它把基线下移——图和字同行时字坐在图的底边那条基线上
  static let imageLineKey = NSAttributedString.Key("KittyNoteImageLine")

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
    var spacing = Spacing.standard

    init() {}

    init(paper: NotePaper, fontSize: CGFloat, markdown: Bool, spacing: Spacing) {
      font = .systemFont(ofSize: fontSize)
      ink = paper.inkColor
      faded = paper.fadedInkColor
      secondary = paper.secondaryInkColor
      marker = paper.markerInkColor
      codeFill = paper.codeFillColor
      bar = paper.quoteBarColor
      self.markdown = markdown
      self.spacing = spacing
    }

    /// size 号字那一行的行高（整点）
    func lineHeight(_ size: CGFloat) -> CGFloat { (size * spacing.multiple).rounded() }

    /// 正文的字那一行的段落样式（打进去的字带着它：空着的最后一行、组着的字按它排）
    var baseParagraph: NSParagraphStyle { paragraph(height: lineHeight(font.pointSize)) }
  }

  /// 一行的段落样式：行高定死（最小 = 最大）、段前段后、左缩进（tail：右边也缩进）、Tab 宽（0 = 系统的）
  static func paragraph(
    height: CGFloat, before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0,
    tail: CGFloat = 0, tab: CGFloat = 0
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = height
    style.maximumLineHeight = height
    style.paragraphSpacingBefore = before
    style.paragraphSpacing = after
    style.firstLineHeadIndent = indent
    style.headIndent = indent
    style.tailIndent = -tail
    if tab > 0 {
      style.tabStops = []
      style.defaultTabInterval = tab
    }
    return style
  }

  /// 把 range 那几行（整行）的样式重排一遍：铺回基础样式，再按 spans 加。只动属性。
  /// shown：现在该露出标记的行（整行的区间）——行首落在里面的那些行，标记淡淡显示，别的行藏起来。
  /// blocks：照现在的正文认出来的代码块（NoteMarkdown.codeBlocks；Markdown 关着时给空的）。
  /// availableWidth：正文可用宽（算没记宽度的图显示多大；墙卡片没有附件，给默认的不限）。
  /// 一行排成什么样只看：这一行的字、它在不在代码块里（什么角色）、上下两行是不是引用（引用块的段前段后）、露不露标记、
  /// 有没有图片（图占多高）——所以「每次编辑只排受影响的行」要排到：改过的行、角色变了的行（roleChanges），
  /// 再各往上下带一行（neighborLines）。
  /// **附件字符上的 `.attachment` 要放回去**：上面两步的 setAttributes 整段铺回会把它抹掉（图就没了）；
  /// 另外附件字符上不许有 hiddenKey（那样它变成零宽的控制字符、图也看不见）
  @MainActor
  static func apply(
    to storage: NSTextStorage, lines range: NSRange, theme: Theme, shown: [NSRange],
    blocks: [NoteMarkdown.CodeBlock], availableWidth: CGFloat = .greatestFiniteMagnitude
  ) {
    guard range.length > 0 else { return }
    let text = storage.mutableString
    let base = theme.font
    let box = NSFont(name: "AppleSymbols", size: (base.pointSize * boxScale).rounded())
    // 方框往上抬一点：Apple Symbols 的字形坐在基线上，抬到和字的中线差不多齐
    let lift = box.map { max(0, base.descender - $0.descender) } ?? 0
    let code = NSFont.monospacedSystemFont(ofSize: codeSize(base.pointSize), weight: .regular)
    let height = theme.lineHeight(base.pointSize)
    let margin = (height * blockMargin).rounded()
    // 同一种的行（引用之外）主字体和段落样式都一样：排一次记下
    var cache: [Shape: (NSFont, NSParagraphStyle)] = [:]

    func attributes(for look: Look, isShown: Bool) -> [NSAttributedString.Key: Any] {
      if look.isBox {
        return [.font: box ?? base, .baselineOffset: lift, .foregroundColor: theme.ink]
      }
      // 代码块：等宽、按原文、墨色；围栏行也是墨（不藏）——标记那一档（墨 35%）压在代码的底上最低 1.67:1，语言名读不出来；
      // 次要的墨（75%）压在底上沙色浅纸也只有 4.498:1、不到 4.5（墨对底 ≥ 7，NotesWindowTests.paperTable 锁住）
      if look.isCodeBlock || look.isFence {
        return [.font: code, .foregroundColor: theme.ink]
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
      if look.isQuote { result[quoteKey] = true }
      if look.isMarker { result[isShown ? shownKey : hiddenKey] = true }
      return result
    }

    /// 一行的主字体和段落样式。引用的段前段后看上下两行是不是引用（isFirst / isLast：引用块的头一行、末一行）
    func metrics(of shape: Shape, isFirst: Bool, isLast: Bool) -> (NSFont, NSParagraphStyle) {
      switch shape {
      case .plain:
        return (base, theme.baseParagraph)
      case .heading(let level):
        let font = NSFont.systemFont(
          ofSize: headingSize(level, base: base.pointSize), weight: .bold)
        let style = NoteStyles.paragraph(
          height: theme.lineHeight(font.pointSize), before: (height * headingBefore).rounded(),
          after: (height * headingAfter).rounded())
        return (font, style)
      case .quote:
        return (
          base,
          NoteStyles.paragraph(
            height: height, before: isFirst ? margin : 0, after: isLast ? margin : 0,
            indent: quoteIndent)
        )
      case .code(let role):
        // 块外留的那点从画出来的底算起（底比围栏行多出 codePadding）
        let space = (" " as NSString).size(withAttributes: [.font: code]).width
        let style = NoteStyles.paragraph(
          height: theme.lineHeight(code.pointSize),
          before: role == .open ? margin + codePadding : 0,
          after: role == .close ? margin + codePadding : 0, indent: codeInset, tail: codeInset,
          tab: space * CGFloat(codeTabWidth))
        return (code, style)
      }
    }

    /// 第 position 个字所在的那一行是不是引用（引用块的段前段后用）
    func isQuote(lineAt position: Int) -> Bool {
      var (start, contentsEnd) = (0, 0)
      text.getLineStart(
        &start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
      let units = Array(
        text.substring(with: NSRange(location: start, length: contentsEnd - start)).utf16)
      return shape(
        of: units, markdown: theme.markdown, role: NoteMarkdown.role(at: start, in: blocks))
        == .quote
    }

    /// 这一行（整行）里的图片附件（位置 + 附件 + 它显示多高）：铺回基础样式前先记下来，铺完放回去；
    /// 高按**这一行的可用宽**算（正文可用宽去掉这一行的 head / tail indent：引用、代码块里的图跟着窄，
    /// 和 cell 里 cellFrame 算的是同一个口径，F3；拖把手时用 cell 上临时的宽度）。
    func attachments(in line: NSRange, style: NSParagraphStyle) -> [(
      range: NSRange, attachment: NoteImageAttachment, height: CGFloat
    )] {
      let available = NoteImageLayout.availableWidth(availableWidth, style: style)
      var found: [(range: NSRange, attachment: NoteImageAttachment, height: CGFloat)] = []
      storage.enumerateAttribute(.attachment, in: line) { value, range, _ in
        guard let attachment = value as? NoteImageAttachment else { return }
        let live = (attachment.attachmentCell as? NoteImageAttachmentCell)?.liveWidth
        found.append(
          (
            range, attachment,
            NoteImageLayout.size(
              image: attachment.picture, metrics: attachment.metrics, available: available,
              live: live
            ).height
          ))
      }
      return found
    }

    storage.beginEditing()
    var location = range.location
    while location < NSMaxRange(range) {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      let role = NoteMarkdown.role(at: start, in: blocks)
      let shape = shape(of: Array(line.utf16), markdown: theme.markdown, role: role)
      let found: (font: NSFont, style: NSParagraphStyle)
      if shape == .quote {
        found = metrics(
          of: shape, isFirst: start == 0 || !isQuote(lineAt: start - 1),
          isLast: end >= text.length || !isQuote(lineAt: end))
      } else if let cached = cache[shape] {
        found = cached
      } else {
        found = metrics(of: shape, isFirst: false, isLast: false)
        cache[shape] = found
      }
      let images = attachments(
        in: NSRange(location: start, length: end - start), style: found.style)
      let imageHeight = images.map(\.height).max() ?? 0
      // 图片那一行：**行高不整段定死**（原来 min = max = 图高 + 留白，同一段里折出来的每一行都和图一样高）。
      // 现在只把 max 放开：含附件的那一个行片段由布局代理撑到图高 + 上下留白（centerLine 改行片段），
      // 同一段里折出来的别的行照正文行高（F16②）
      var style = found.style
      if imageHeight > 0, let taller = found.style.mutableCopy() as? NSMutableParagraphStyle {
        taller.maximumLineHeight = 0
        style = taller
      }
      var whole: [NSAttributedString.Key: Any] = [
        .paragraphStyle: style, lineFontKey: found.font,
      ]
      if imageHeight > 0 { whole[imageLineKey] = imageHeight }
      if let role { whole[roleKey] = role.rawValue }
      // 整行（连行尾的换行）铺回基础样式：段落、主字体、角色记在每个字上
      storage.setAttributes(
        whole.merging([.font: base, .foregroundColor: theme.ink]) { current, _ in current },
        range: NSRange(location: start, length: end - start))
      let isShown = shown.contains { $0.location <= start && start < NSMaxRange($0) }
      let spans =
        role.map { blockSpans(in: line, role: $0) } ?? spans(in: line, markdown: theme.markdown)
      for run in runs(of: spans) {
        storage.setAttributes(
          attributes(for: run.look, isShown: isShown).merging(whole) { current, _ in current },
          range: NSRange(location: start + run.range.location, length: run.range.length))
      }
      // 附件放回去（上面两步的 setAttributes 把它抹掉了），附件字符上不许有 hiddenKey（不然图变成零宽的、看不见）
      for image in images {
        storage.addAttribute(.attachment, value: image.attachment, range: image.range)
        storage.removeAttribute(hiddenKey, range: image.range)
      }
      // 引用行行尾的换行也记上：连着的几行引用是一整段（竖线不断开）
      if shape == .quote, end > contentsEnd {
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
    return merged(found)
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

  // MARK: 行高和插入点

  /// 布局管理器排好一个行片段时问到这里（NSLayoutManagerDelegate 的 shouldSetLineFragmentRect，NoteTextView 转过来）：
  /// 行高是段落样式定死的那么高（apply 给每一行的 minimumLineHeight = maximumLineHeight），这里把字按这一行的主字体
  /// （lineFontKey）在里面竖直居中——改的是基线，和「用到的那一块」（usedRect：插入点、选区的上下沿、行内代码的底都按它
  /// 画，所以插入点只有字那么高、不跟着撑高的行走）。段前的留白算在行片段里、不算在居中的那一条里。
  /// **图片那一行**（字上记着 imageLineKey）：基线移到「段前 + 上留白 + 图那么高」，用到的那一块就是图那一块——图和字
  /// 同行时字坐在图的底边那条基线上（cellBaselineOffset 是 0）。
  /// 不靠字上的 baselineOffset 居中：TextKit 排基线时看这一行所有字里最深的下沿（实测 15.7：带方框的任务行因为
  /// Apple Symbols 的下沿深，整行的字比普通行高 1 pt），这里按主字体直接定，一行里混着什么字都不挪。
  /// 返回改没改（没有主字体、行高没定死的不管）。布局时调的代码：只动传进来的东西、只读文本存储上的属性
  static func centerLine(
    in layoutManager: NSLayoutManager, glyphRange: NSRange, rect: UnsafeMutablePointer<NSRect>,
    used: inout NSRect, baseline: inout CGFloat
  ) -> Bool {
    guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
    let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    // 一次取全这个字上的属性（每个行片段都要问，几万行的正文排一遍版就是几万次）
    let attributes = storage.attributes(
      at: min(chars.location, storage.length - 1), effectiveRange: nil)
    guard let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.minimumLineHeight > 0
    else { return false }
    let before = spacingBefore(at: chars.location, style: style, in: storage.mutableString)
    // **图片那一行**（字上记着 imageLineKey，且这**一个行片段里真的有附件字形**）：把行片段撑到
    // 「段前 + 图高 + 上下留白」，基线落在图底、usedRect 收成图那一块——同一段里折出来的别的行片段不含附件，
    // 照正文行高居中（F16②）。段落样式那边只放开了 maximumLineHeight，不整段定死
    if let imageHeight = attributes[imageLineKey] as? CGFloat, imageHeight > 0,
      containsAttachment(in: chars, of: storage)
    {
      let padding = NoteImageLayout.padding
      rect.pointee.size.height = (before + padding * 2 + imageHeight).rounded()
      baseline = (rect.pointee.minY + before + padding + imageHeight).rounded()
      used.origin.y = rect.pointee.minY + before + padding
      used.size.height = imageHeight
      return true
    }
    guard let font = attributes[lineFontKey] as? NSFont else { return false }
    center(
      height: style.minimumLineHeight, ascender: font.ascender, descender: font.descender,
      before: before, rect: rect.pointee, used: &used, baseline: &baseline)
    return true
  }

  /// 这一段字里有没有挂着我们图片附件的字形（图片行的行高只按含附件的那一个行片段撑，见 centerLine）
  private static func containsAttachment(in chars: NSRange, of storage: NSTextStorage) -> Bool {
    var found = false
    storage.enumerateAttribute(.attachment, in: chars) { value, _, stop in
      if value is NoteImageAttachment {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  /// 字的上下沿（ascender / descender）在一条 height 高的行里居中：基线取整点（字形落在整像素上，最多偏 0.5），
  /// usedRect 的上下就是字的上下沿。before：行片段（rect）顶上那段段前留白。
  /// **不出自己的行片段**：居中的那条和收出来的高度都夹到 rect.height - before 以内。贴进来的软换行（U+2028、U+0085）
  /// 后面那一行，TextKit 1 不当分段、按这一段的段落样式排（行片段是上一行的行高），字上记的却是这一行自己的（比如标题的
  /// 行高和大字）——不夹的话插入点、输入法候选窗跑到上下两行上去
  static func center(
    height: CGFloat, ascender: CGFloat, descender: CGFloat, before: CGFloat, rect: NSRect,
    used: inout NSRect, baseline: inout CGFloat
  ) {
    let room = max(rect.height - before, 0)
    let height = min(height, room)
    let box = ascender - descender
    baseline = (before + (height - box) / 2 + ascender).rounded()
    used.origin.y = rect.minY + baseline - ascender
    used.size.height = box
    if box > room {
      used.origin.y = rect.minY + before
      used.size.height = room
    }
  }

  /// 正文的第一行里字的上沿离这一行的顶多远（行高定死、字居中让出来的那点）：正文框的占位要和第一个字对齐。
  /// 行高取 Theme.lineHeight（和正文编辑器排的是同一份）
  static func textTop(fontSize: CGFloat, spacing: Spacing) -> CGFloat {
    var theme = Theme()
    theme.font = .systemFont(ofSize: fontSize)
    theme.spacing = spacing
    let height = theme.lineHeight(fontSize)
    var (used, baseline) = (NSRect.zero, CGFloat(0))
    center(
      height: height, ascender: theme.font.ascender, descender: theme.font.descender, before: 0,
      rect: NSRect(x: 0, y: 0, width: 0, height: height), used: &used, baseline: &baseline)
    return used.minY
  }

  /// 从 location 开始的那个行片段顶上有多少段前留白：段首的行片段才有（段落样式的 paragraphSpacingBefore），
  /// 正文第一段没有（TextKit 1 不给，实测 15.7）。段的分隔同 NSString（\n \r U+2029；U+2028 只换行不分段）
  static func spacingBefore(at location: Int, style: NSParagraphStyle, in text: NSString) -> CGFloat
  {
    guard location > 0, location <= text.length else { return 0 }
    let previous = text.character(at: location - 1)
    return previous == 0x0A || previous == 0x0D || previous == 0x2029
      ? style.paragraphSpacingBefore : 0
  }

  /// 第 index 个字是不是藏着的标记（布局管理器排到一个控制字符时来问怎么处理：是的话零宽，不是的话——换行、Tab——
  /// 照系统原来的）。同样是布局时调的
  static func isHidden(at index: Int, in layoutManager: NSLayoutManager) -> Bool {
    guard let storage = layoutManager.textStorage, index < storage.length else { return false }
    return storage.attribute(hiddenKey, at: index, effectiveRange: nil) != nil
  }
}
