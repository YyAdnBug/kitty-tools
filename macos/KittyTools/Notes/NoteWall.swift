// 全部便签窗口的「便签墙」（2026-10-15 手测反馈，用户原话「类似真正的便签条形式，就像留言板的便签墙那种形式」；
// 长相在 mac-whisker-notes.mdc「便签墙」，界面在 NotesWallView.swift）。这里是纯函数和数值：
// - 卡片一样宽、高随内容（有上下限），按窗口宽度排几列（列宽固定、整块居中：窗口变宽只多排列，卡片的高不用重算）；
// - 瀑布流：每张放进当时最矮的那一列；分两段（固定的 / 其他，各有一行小标题；最近删除里不分）；
// - 每张微微斜一点：大小按便签编号定（1–2°，每次一样），方向按位置交错（同一列上下相邻、左右相邻的不同向）；
// - 方向键在卡片之间怎么走、指针下面是哪张、拖动排序落到哪（只看拖动开始时那份排法：dropTarget）、落成仓库的哪个
//   下标；编辑卡多大、它那块纸从哪长出来 / 缩回哪（paperRect：按那一刻的排法和滚动位置算）；
// - 卡片上那段字（Card）：标题 + 正文开头几行，样式和正文编辑器同一套（NoteStyles.apply），藏着的标记删掉，
//   量好高——卡片怎么排只看量出来的高，不量视图。按便签缓存在仓库那一层（NoteStore.wallCard）；排的时候卡片的高可以
//   边排边要（layout(_:width:height:)）：可见区附近的当场建，往下的先按估计的高排（estimatedHeight）。

import AppKit

nonisolated enum NoteWall {
  // MARK: 数值（mac-whisker-notes.mdc「便签墙」）

  /// 卡片的宽、卡片之间（左右、上下）的距离、墙四周至少留多少
  static let cardWidth: CGFloat = 224
  static let gap: CGFloat = 16
  static let margin: CGFloat = 20
  /// 两段之间多空的、每段的小标题多高
  static let sectionGap: CGFloat = 12
  static let headerHeight: CGFloat = 24
  /// 卡片的高的上下限：短的也是一张方方的纸，长的截断、底下渐隐
  static let minHeight: CGFloat = 112
  static let maxHeight: CGFloat = 320
  /// 卡片里：顶上色条、左右内边距、色条下到标题、标题和正文之间、正文和底下小字之间、小字那一行、底边
  static let stripHeight: CGFloat = 3
  static let padding: CGFloat = 12
  static let topInset: CGFloat = 10
  static let titleGap: CGFloat = 4
  static let footerGap: CGFloat = 8
  static let footerHeight: CGFloat = 14
  static let bottomInset: CGFloat = 10
  /// 标题：字号、行高（定死）、最多几行；固定的给右上角的图钉让出多少
  static let titleSize: CGFloat = 14
  static let titleLine: CGFloat = 19
  static let titleLines = 2
  static let pinRoom: CGFloat = 16
  /// 正文的字号（行距是正文编辑器「标准」那一档）
  static let bodySize: CGFloat = 12
  /// 正文超出时底下渐隐的那一截
  static let fadeHeight: CGFloat = 28
  /// 卡片上带正文开头多少：最多几行、最多多少字（UTF-16）；认代码块时看正文开头多少
  static let excerptLines = 16
  static let excerptLength = 1200
  static let excerptScan = 8192
  /// 每张斜多少度（大小按编号在两数之间取）
  static let minTilt = 1.0
  static let maxTilt = 2.0
  /// 编辑卡：占墙的多少、最大多大（同屏幕边缘那叠里打开的便签「特大」）
  static let editorShare = CGSize(width: 0.78, height: 0.84)
  static let editorMax = CGSize(width: 680, height: 560)
  /// 编辑卡后面的那层暗：平时 / 降低透明度时
  static let dim = 0.25
  static let solidDim = 0.5
  /// 拖动时指针得进到另一张卡片里面这么多（按边长的比例）才换位置：刚换完位置、它挪开了一点，不来回跳
  static let dragInset: CGFloat = 0.2
  /// 按下之后挪过这么远才算拖（没到就是点了一下）
  static let dragSlop: CGFloat = 4
  /// 还没建好的卡片先按多高排（可见区以下的；建好了换成量出来的高）
  static let estimatedHeight: CGFloat = 200
  /// 编辑卡那块纸没有卡片可回（不在墙上、滚出了可见区）时，在中央比编辑卡小这么一圈长出来 / 淡掉
  static let paperInset: CGFloat = 24

  static var textWidth: CGFloat { cardWidth - padding * 2 }

  // MARK: 排

  /// 一段：小标题（nil = 不画）、卡片的编号和高（从前到后）
  struct Section: Equatable, Sendable {
    var title: String?
    var ids: [String]
    var heights: [CGFloat]
  }

  struct Header: Equatable, Sendable {
    var title: String
    var frame: CGRect
  }

  /// 排好的墙（墙的坐标：滚动内容的左上角是原点）。frames、columns、tilts、ids 按墙上的顺序（各段接着排）
  struct Layout: Equatable, Sendable {
    var ids: [String] = []
    var frames: [CGRect] = []
    var columns: [Int] = []
    var tilts: [Double] = []
    var headers: [Header] = []
    /// 每段在 ids 里的下标范围（空的段不在里面）
    var sections: [Range<Int>] = []
    var columnCount = 1
    var height: CGFloat = 0

    func index(of id: String) -> Int? { ids.firstIndex(of: id) }

    /// 第 index 张在哪一段（sections 里的下标）
    func section(of index: Int) -> Int? { sections.firstIndex { $0.contains(index) } }
  }

  /// 这么宽的墙排几列：列宽固定，放得下几列就几列（至少一列）
  static func columnCount(width: CGFloat) -> Int {
    max(1, Int(((width - margin * 2 + gap) / (cardWidth + gap)).rounded(.down)))
  }

  /// 排一面墙。width：墙多宽（滚动区里内容的宽）。各段依次往下排：有标题的先放一行小标题，卡片按顺序一张张放进
  /// 当时最矮的那一列（一样矮的取左边的）；空的段整段跳过（连标题）
  static func layout(_ sections: [Section], width: CGFloat) -> Layout {
    let heights = sections.flatMap(\.heights)
    return layout(sections.map { ($0.title, $0.ids) }, width: width) { index, _ in heights[index] }
  }

  /// 同上，卡片的高边排边要：height(第几张（墙上的顺序，各段接着数），它的顶落在哪（墙的坐标）)。卡片的顶按排的顺序
  /// 只增不减（每张都放进当时最矮的那一列），所以调用方可以只为顶在可见区附近的现建、往下的先给估计的高
  /// （NotesWindowModel.wallLayout）——上面的那些位置都是准的
  static func layout(
    _ sections: [(title: String?, ids: [String])], width: CGFloat,
    height: (_ index: Int, _ top: CGFloat) -> CGFloat
  ) -> Layout {
    let columns = columnCount(width: width)
    let span = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
    let left = max(margin, ((width - span) / 2).rounded(.down))
    var layout = Layout(columnCount: columns)
    var y = margin
    for section in sections where !section.ids.isEmpty {
      if !layout.sections.isEmpty { y += sectionGap }
      if let title = section.title {
        layout.headers.append(
          Header(title: title, frame: CGRect(x: left, y: y, width: span, height: headerHeight)))
        y += headerHeight
      }
      var bottoms = [CGFloat](repeating: y, count: columns)
      // 这一段里每一列放了几张（倾斜的方向按它交错；每段从头数，各段的第一排都是一正一反）
      var rows = [Int](repeating: 0, count: columns)
      let start = layout.ids.count
      for id in section.ids {
        let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
        let height = height(layout.ids.count, bottoms[column])
        layout.ids.append(id)
        layout.frames.append(
          CGRect(
            x: left + CGFloat(column) * (cardWidth + gap), y: bottoms[column], width: cardWidth,
            height: height))
        layout.columns.append(column)
        layout.tilts.append(tilt(id: id, column: column, row: rows[column]))
        bottoms[column] += height + gap
        rows[column] += 1
      }
      layout.sections.append(start..<layout.ids.count)
      y = (bottoms.max() ?? y) - gap
    }
    layout.height = y + margin
    return layout
  }

  /// 一张卡片斜多少度（顺时针为正，SwiftUI rotationEffect 的方向）：大小按编号定（1–2°，FNV-1a，每次启动一样——
  /// 不用 hashValue，它每次运行都换种子），方向按位置交错：列号 + 它是这一段里这一列的第几张，偶数逆时针、奇数
  /// 顺时针——同一列上下挨着的一定不同向，一段的第一排左右挨着的不同向；往下瀑布流错开之后左右挨着的不保证（卡片不成排），
  /// 但不会一整列、一整排都朝一边。方向不按编号定：只靠编号，挨着的两张一半的机会同向，保证不了「不一直朝一边」
  static func tilt(id: String, column: Int, row: Int) -> Double {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    let size = minTilt + (maxTilt - minTilt) * Double(hash % 1001) / 1000
    return (column + row) % 2 == 0 ? -size : size
  }

  // MARK: 方向键

  enum Direction: Sendable {
    case up, down, left, right
  }

  /// 从第 index 张往 direction 走到哪张；走不动是 nil。
  /// ↑↓：同一列里上一张 / 下一张（跨段接着走）；这一列那边没有了，就去最近的有卡片的那一列里离得最近的一张。
  /// ←→：那边最近的一列里，竖直方向上中心离这张最近的那张（瀑布流的卡片不成排）
  static func neighbor(of index: Int, _ direction: Direction, in layout: Layout) -> Int? {
    guard layout.frames.indices.contains(index) else { return nil }
    let here = layout.frames[index]
    let column = layout.columns[index]
    let others = layout.frames.indices.filter { $0 != index }
    func distance(_ other: Int) -> Int { abs(layout.columns[other] - column) }
    switch direction {
    case .down:
      return others.filter { layout.frames[$0].minY > here.minY }
        .min { (distance($0), layout.frames[$0].minY) < (distance($1), layout.frames[$1].minY) }
    case .up:
      return others.filter { layout.frames[$0].minY < here.minY }
        .min { (distance($0), -layout.frames[$0].minY) < (distance($1), -layout.frames[$1].minY) }
    case .left, .right:
      let candidates = others.filter {
        direction == .left ? layout.columns[$0] < column : layout.columns[$0] > column
      }
      func off(_ other: Int) -> CGFloat { abs(layout.frames[other].midY - here.midY) }
      return candidates.min { (distance($0), off($0)) < (distance($1), off($1)) }
    }
  }

  // MARK: 拖动排序

  /// 指针下面是哪张：point 落在它里面（四边各往里收 inset × 边长；拖动时用，见 dragInset）
  static func item(at point: CGPoint, in layout: Layout, inset: CGFloat = 0) -> Int? {
    layout.frames.firstIndex {
      $0.insetBy(dx: $0.width * inset, dy: $0.height * inset).contains(point)
    }
  }

  /// items 里把第 from 个挪成第 to 个（挪完之后的下标）
  static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
    guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
    var items = items
    items.insert(items.remove(at: from), at: to)
    return items
  }

  /// 拖着原来第 from 张的那张、停在第 over 张上：它落成第几张——就是 over 那个位置；
  /// 两张不在同一段（固定的和没固定的各在各的区里）时不换，nil
  static func landing(from: Int, over: Int, in layout: Layout) -> Int? {
    guard let section = layout.section(of: from), layout.section(of: over) == section else {
      return nil
    }
    return over
  }

  /// 拖着原来第 from 张、现在让到第 current 张的那张，指针在 point（墙的坐标）：它该让到第几张。**只看拖动开始时那份
  /// 排法（base：让位之前的）**——指针进到同一段里另一张的里面（四边各收 dragInset）就落到那张的位置，不在任何一张
  /// 里面、在别的段里就不动（current）。所以落点只取决于指针在哪：同一个位置怎么问都一样。原来按「让过位之后」重排
  /// 出来的墙判断，那份墙又随落点变，指针不动也会在两个位置之间来回跳（手测反馈第 6 批评审：随机拖 400 次约 14%）
  static func dropTarget(from: Int, current: Int, at point: CGPoint, in base: Layout) -> Int {
    guard let over = item(at: point, in: base, inset: dragInset),
      let to = landing(from: from, over: over, in: base)
    else { return current }
    return to
  }

  /// 墙上拖完之后的顺序 → 仓库挪顺序（NoteStore.move）要的下标（「全部」里没归档没删的那一列，挪完之后的下标）：
  /// 仓库的顺序里固定的和没固定的是混着排的，所以照它在墙上同一段里紧挨着的那张放——后面有一张就放到那张前面，
  /// 它是这一段的最后一张就放到前面那张后面。active：仓库现在的顺序（编号）
  static func storeIndex(of id: String, in order: [String], section: Range<Int>, active: [String])
    -> Int?
  {
    let rest = active.filter { $0 != id }
    guard let at = order.firstIndex(of: id), section.contains(at) else { return nil }
    if at + 1 < section.upperBound, let next = rest.firstIndex(of: order[at + 1]) { return next }
    if at > section.lowerBound, let previous = rest.firstIndex(of: order[at - 1]) {
      return previous + 1
    }
    return nil
  }

  // MARK: 编辑卡

  /// 编辑卡多大：墙（连顶上那一条）的七八成，有上限
  static func editorSize(in container: CGSize) -> CGSize {
    CGSize(
      width: min(editorMax.width, (container.width * editorShare.width).rounded()),
      height: min(editorMax.height, (container.height * editorShare.height).rounded()))
  }

  /// 编辑卡那块纸长出来的起点、缩回去的终点：那张卡片**现在**在这一块（墙连顶上那一条；编辑卡也摆在这个坐标里）的
  /// 位置——墙上的位置 − 滚过的 + 顶上那一条多高。card：它在现在的排法里的位置（不在墙上是 nil：被搜索词筛掉了、删了、
  /// 归档了）；viewport：墙的可见区多高。整张都在可见区外（滚走了）或者不在墙上给 nil：纸在中央略小一圈长出来 / 淡掉。
  /// 收回时按收回那一刻算（手测反馈第 6 批，用户报「收回时往中间缩、不回到原来的位置」：原来用的是视图消失前最后一次
  /// 求值时算的）
  static func paperRect(card: CGRect?, top: CGFloat, scrollY: CGFloat, viewport: CGFloat)
    -> CGRect?
  {
    guard let card else { return nil }
    let rect = card.offsetBy(dx: 0, dy: top - scrollY)
    return rect.maxY > top && rect.minY < top + viewport ? rect : nil
  }

  // MARK: 卡片上的字

  /// 卡片上带的正文：标题之后的开头几行（原文，连着的一段）和这一段里的代码块（位置相对这一段）。
  /// 没自己起标题的，标题就是正文第一个有内容的行（Note.displayTitle），这一行不再重复（跳过前面的空行和代码块的
  /// 围栏行）。最多 excerptLines 行、excerptLength 个字；只认正文开头 excerptScan 个字里的代码块，一块被截在中间的
  /// 照样算块（后半截不在这一段里）
  static func excerpt(of note: Note) -> (text: String, blocks: [NoteMarkdown.CodeBlock]) {
    let body = note.body as NSString
    let head =
      body.length > excerptScan
      ? body.substring(with: body.rangeOfComposedCharacterSequences(for: NSRange(0..<excerptScan)))
        as NSString : body
    let blocks = NoteMarkdown.codeBlocks(in: head)
    var start = 0
    var location = 0
    var (lineStart, lineEnd, contentsEnd) = (0, 0, 0)
    func line(at position: Int) {
      head.getLineStart(
        &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
        for: NSRange(location: position, length: 0))
    }
    func isBlank() -> Bool {
      head.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        .allSatisfy(\.isWhitespace)
    }
    // 标题取自正文第一行时跳过它（和它前面的空行、围栏行）
    if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      while location < head.length {
        line(at: location)
        location = max(lineEnd, location + 1)
        let role = NoteMarkdown.role(at: lineStart, in: blocks)
        if isBlank() || role == .open || role == .close { continue }
        break
      }
    }
    // 开头的空行不要；标题取自代码块里的一行时，紧跟着的收尾围栏也不要（单独一行「```」没有意思）
    while location < head.length {
      line(at: location)
      guard isBlank() || NoteMarkdown.role(at: lineStart, in: blocks) == .close else { break }
      location = max(lineEnd, location + 1)
    }
    start = location
    var end = start
    var lines = 0
    while location < head.length, lines < excerptLines, end - start < excerptLength {
      line(at: location)
      end = contentsEnd
      location = max(lineEnd, location + 1)
      lines += 1
    }
    end = min(end, start + excerptLength)
    guard end > start else { return ("", []) }
    let range = head.rangeOfComposedCharacterSequences(
      for: NSRange(location: start, length: end - start))
    let text = head.substring(with: range)
    // 碰到这一段的块，挪到这一段的坐标里；被截在头上的从第一行开头算，截在尾上的收尾放在这一段的末尾之外
    let shifted = blocks.compactMap { block -> NoteMarkdown.CodeBlock? in
      guard NSMaxRange(block.range) > range.location, block.open.location < NSMaxRange(range)
      else { return nil }
      let open =
        block.open.location >= range.location
        ? NSRange(location: block.open.location - range.location, length: block.open.length)
        : NSRange(location: 0, length: 0)
      let close =
        NSMaxRange(block.close) <= NSMaxRange(range)
        ? NSRange(location: block.close.location - range.location, length: block.close.length)
        : NSRange(location: range.length + 1, length: 0)
      return NoteMarkdown.CodeBlock(open: open, close: close)
    }
    return (text, shifted)
  }
}

/// 一张卡片上画的字和它的高（NoteWall.card 建；按便签缓存，标题、正文、颜色、Markdown 开关、固定没变就是同一个）。
/// 是个类：卡片的字那一层按它是不是同一个判断要不要重画
final class NoteWallCard {
  let title: NSAttributedString
  let body: NSAttributedString
  /// 标题排多宽（固定的给图钉让出一截）、画多高（一两行）、正文排完多高、正文在卡片里露出来多高（超出的截断渐隐）、
  /// 整张卡片多高
  let titleWidth: CGFloat
  let titleHeight: CGFloat
  let bodyHeight: CGFloat
  let bodyRoom: CGFloat
  let height: CGFloat

  var overflows: Bool { bodyHeight > bodyRoom + 0.5 }
  /// 卡片上字的那一块多高：标题 + 露出来的正文
  var textHeight: CGFloat { titleHeight + (bodyHeight > 0 ? NoteWall.titleGap + bodyRoom : 0) }

  init(title: NSAttributedString, body: NSAttributedString, isPinned: Bool) {
    self.title = title
    self.body = body
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    titleWidth = NoteWall.textWidth - (isPinned ? NoteWall.pinRoom : 0)
    let measured = title.boundingRect(
      with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude), options: options
    ).height
    titleHeight = min(
      ceil(measured), NoteWall.titleLine * CGFloat(NoteWall.titleLines))
    bodyHeight =
      body.length == 0
      ? 0
      : ceil(
        body.boundingRect(
          with: NSSize(width: NoteWall.textWidth, height: .greatestFiniteMagnitude),
          options: options
        ).height)
    let chrome =
      NoteWall.stripHeight + NoteWall.topInset + titleHeight + NoteWall.footerGap
      + NoteWall.footerHeight + NoteWall.bottomInset
    let natural = chrome + (bodyHeight > 0 ? NoteWall.titleGap + bodyHeight : 0)
    height = min(max(natural, NoteWall.minHeight), NoteWall.maxHeight)
    bodyRoom = max(0, height - chrome - NoteWall.titleGap)
  }

  /// 这条便签的卡片：标题是显示用的标题（title，NoteStore.summary 给的），正文是开头几行（NoteWall.excerpt），
  /// 样式照正文编辑器（NoteStyles.apply：任务的方框和划线、标题、粗体斜体、代码、链接、引用；markdown 关着时只有任务），
  /// 藏着的标记和代码块的围栏行删掉（编辑器里标记是零宽的字形，这里直接画字串，不删就露出来），代码块里的行垫代码的底
  /// （编辑器里那块底是文本视图自己画的）。
  /// ponytail: 引用左边的竖线、代码块的圆角底没画（卡片上只是一眼看个大概）；要的话改成自己逐行画
  static func make(for note: Note, title: String, markdown: Bool) -> NoteWallCard {
    let paper = NotePaper.of(note)
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.minimumLineHeight = NoteWall.titleLine
    titleStyle.maximumLineHeight = NoteWall.titleLine
    let titleText = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: NoteWall.titleSize, weight: .semibold),
        .foregroundColor: paper.inkColor,
        .paragraphStyle: titleStyle,
      ])
    let (text, blocks) = NoteWall.excerpt(of: note)
    let storage = NSTextStorage(string: text)
    if storage.length > 0 {
      NoteStyles.apply(
        to: storage, lines: NSRange(location: 0, length: storage.length),
        theme: NoteStyles.Theme(
          paper: paper, fontSize: NoteWall.bodySize, markdown: markdown, spacing: .standard),
        shown: [], blocks: markdown ? blocks : [])
      storage.beginEditing()
      // 藏着的标记、代码块的围栏行（整行连换行）都是记号，卡片上不要
      var hidden: [NSRange] = []
      let whole = NSRange(location: 0, length: storage.length)
      storage.enumerateAttributes(in: whole) { attributes, range, _ in
        let role = (attributes[NoteStyles.roleKey] as? Int).flatMap(NoteMarkdown.Role.init)
        if attributes[NoteStyles.hiddenKey] != nil || role == .open || role == .close {
          hidden.append(range)
        }
      }
      for range in hidden.reversed() { storage.deleteCharacters(in: range) }
      // 末尾删剩下的换行（收尾的围栏删了，前一行的换行还在）：不然多出一行空的高
      while storage.length > 0,
        CharacterSet.newlines.contains(
          UnicodeScalar(storage.mutableString.character(at: storage.length - 1)) ?? " ")
      {
        storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
      }
      storage.enumerateAttribute(
        NoteStyles.roleKey, in: NSRange(location: 0, length: storage.length)
      ) { value, range, _ in
        if value != nil {
          storage.addAttribute(.backgroundColor, value: paper.codeFillColor, range: range)
        }
      }
      storage.endEditing()
    }
    return NoteWallCard(
      title: titleText, body: NSAttributedString(attributedString: storage),
      isPinned: note.isPinned)
  }
}
