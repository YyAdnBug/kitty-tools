// 屏幕边缘那叠（PLAN §10「便签」第 3 批；窗口的规矩在 mac-overlay-panel §12，长相在 mac-whisker-notes.mdc）的几何。
// 全是纯函数，单测 NoteDeckTests 锁住（设置在 NoteDeckOptions.swift）：
// - NoteDeckMetrics：药丸和标签的各个尺寸，按大小档（0.85 / 1 / 1.25）一起缩放、取整到整点（叠着的标签不出缝）；
// - NoteDeckLayout：一列标签怎么排（每张露出多长、要不要压短、「+N」、放不下时在视口里滚），加上一组算 frame 的函数——
//   药丸多高、放哪块屏哪条边（两块屏相接的那条边不放）、药丸 / 那叠 / 打开的便签摆在哪、⌥ 拖药丸落在哪、
//   拖动排序落在第几格、鼠标离开多远算走了（热区）；
// - NoteDeckLabel：竖排的标题——哪些字正着放、怎么分段、太长怎么截。
// 交互和数值借自 Noty（MIT；只借数值和思路、一行代码都不拷，mac-whisker §11），长相按 Whisker 自己画。

import AppKit

/// 各个尺寸（点）。写的是标准大小时的值，统一乘上大小档再取整：整点上叠着的标签才不出缝
nonisolated struct NoteDeckMetrics: Equatable, Sendable {
  let scale: CGFloat

  private func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

  // 药丸：12 宽的一条，一条便签一道色条
  var pillWidth: CGFloat { scaled(12) }
  var pillMinHeight: CGFloat { scaled(28) }
  var pillPadding: CGFloat { scaled(6) }
  var dashWidth: CGFloat { scaled(6) }
  var dashHeight: CGFloat { scaled(10) }
  var dashGap: CGFloat { scaled(4) }

  // 带标题的标签：30 宽，一张压一张（下一张盖住上一张 lap 这么多），露出的一截在 stripMin…stripMax 之间跟着最长的
  // 标题走，放不下时最小压到 stripFloor
  var tabWidth: CGFloat { scaled(30) }
  var lap: CGFloat { scaled(40) }
  var stripMin: CGFloat { scaled(56) }
  var stripMax: CGFloat { scaled(106) }
  var stripFloor: CGFloat { scaled(36) }
  /// 露出的一截 = 最长的标题 + 这么多；标题排在那一截里上下一共让出 labelInset（两个不一样，末尾那个字才不被取整挤掉）
  var labelPadding: CGFloat { scaled(20) }
  var labelInset: CGFloat { scaled(12) }

  // 只有色块：30 × 24，间隔 6
  var chipHeight: CGFloat { scaled(24) }
  var chipGap: CGFloat { scaled(6) }

  // 「+N」和最下面的「+」
  var moreHeight: CGFloat { scaled(30) }
  var moreGap: CGFloat { scaled(7) }
  var plusSize: CGFloat { scaled(26) }
  var plusGap: CGFloat { scaled(10) }

  /// 标签上的字（最小 10 pt，mac-whisker §3）
  var fontSize: CGFloat { max(10, scaled(12)) }
  var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
  /// 正着放的一个字占多高
  var glyphAdvance: CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

/// 一列标签的排法，和那叠的各种 frame
nonisolated struct NoteDeckLayout: Equatable, Sendable {
  /// 药丸上最多画几道色条（再多的合成一道灰的）、一次最多扇出几张（其余收进「+N」）
  static let maxDashes = 14
  static let fanLimit = 5
  /// 那一列最多占可见区高度的这么多
  static let heightBudget: CGFloat = 0.68
  /// 鼠标离开标签列再往外这么远才算走了
  static let hotMargin: CGFloat = 20
  /// 打开的便签离标签列多远、面板在便签外侧给阴影留多少、便签离面板上下边至少多少、标签列离上下边至少多少
  static let noteGap: CGFloat = 8
  static let panelMargin: CGFloat = 40
  static let noteInset: CGFloat = 10
  static let columnInset: CGFloat = 12
  /// 药丸离可见区上下边至少多少
  static let pillMargin: CGFloat = 8
  /// 预览卡多宽、离标签列多远、最高大约多高（标题一行 + 摘要四行；太靠下时按它往上收，别出了面板）
  static let previewWidth: CGFloat = 220
  static let previewGap: CGFloat = 10
  static let previewHeight: CGFloat = 130
  /// 按着标签挪过这么多才算拖动排序（没到就是点了一下）
  static let dragSlop: CGFloat = 5

  let metrics: NoteDeckMetrics
  let style: NoteDeckOptions.TabStyle
  /// 画出来几张；「+N」里收着几条（0 = 没有「+N」）
  let count: Int
  let hidden: Int
  /// 相邻两张顶边差多少（带标题的 = 露出的那一截）、每张多高
  let step: CGFloat
  let itemHeight: CGFloat
  /// 标签那一段一共多高；比预算高时（「+N」展开之后）给一个视口，在里面滚
  let stackHeight: CGFloat
  let viewport: CGFloat?

  /// - Parameters:
  ///   - longestLabel: 这一列里最长的标题竖着排多长（NoteDeckLabel.length；只有色块时不用）
  ///   - height: 面板（那块屏的可见区）多高
  init(
    count: Int, hidden: Int, longestLabel: CGFloat, height: CGFloat, options: NoteDeckOptions
  ) {
    let metrics = NoteDeckMetrics(scale: options.size.scale)
    let count = max(count, 0)
    let hidden = max(hidden, 0)
    let reserved =
      (hidden > 0 ? metrics.moreGap + metrics.moreHeight : 0) + metrics.plusGap + metrics.plusSize
    // 预算取整到整点（600 × 0.68 在浮点里不是整 408）
    let budget = max((height * Self.heightBudget).rounded(.down) - reserved, 0)
    switch options.style {
    case .chips:
      itemHeight = metrics.chipHeight
      step = metrics.chipHeight + metrics.chipGap
    case .tabs:
      var strip = min(max(longestLabel + metrics.labelPadding, metrics.stripMin), metrics.stripMax)
      // 一共占的高度超了预算：把露出的那一截压短，最短到 stripFloor
      if count > 0, CGFloat(count) * strip + metrics.lap > budget {
        strip = max(metrics.stripFloor, ((budget - metrics.lap) / CGFloat(count)).rounded(.down))
        // 压到最短还是放不下（「+N」展开之后）：反正要在视口里滚，就不压了——压到 36 标题只剩一个字
        if CGFloat(count) * strip + metrics.lap > budget { strip = metrics.stripMin }
      }
      itemHeight = strip + metrics.lap
      step = strip
    }
    self.metrics = metrics
    style = options.style
    self.count = count
    self.hidden = hidden
    stackHeight = count == 0 ? 0 : CGFloat(count - 1) * step + itemHeight
    viewport = count > 0 && stackHeight > budget ? max(budget, itemHeight) : nil
  }

  var tabWidth: CGFloat { metrics.tabWidth }
  /// 标签在竖排的栈里的间距（带标题的是负的：下一张压住上一张）
  var spacing: CGFloat { step - itemHeight }
  /// 标签那一段在列里占多高（要滚的时候是视口的高）
  var tabsHeight: CGFloat { viewport ?? stackHeight }
  /// 整列多高：标签 +「+N」+ 最下面的「+」
  var columnHeight: CGFloat {
    tabsHeight + (hidden > 0 ? metrics.moreGap + metrics.moreHeight : 0) + metrics.plusGap
      + metrics.plusSize
  }

  /// 第 index 张露在外面的那一截多长（最后一张没人压，整张露着）
  func strip(at index: Int) -> CGFloat { index >= count - 1 ? itemHeight : step }

  /// 标题排在每张顶上多高的一截里：带标题的是露出的那一截（最后一张也按这么长排，和别的对齐），色块是整块
  var labelHeight: CGFloat { style == .tabs ? step : itemHeight }

  /// 第 index 张那一截的中线离这一列的顶多远（打开的便签对着它摆；滚动过的不算，夹在视口里）
  func tabCenter(_ index: Int) -> CGFloat {
    min(CGFloat(index) * step + labelHeight / 2, tabsHeight)
  }

  // MARK: 药丸

  /// 药丸多高：一条便签一道色条，超过 maxDashes 条的合成一道
  static func pillHeight(count: Int, metrics: NoteDeckMetrics) -> CGFloat {
    let dashes = CGFloat(max(min(count, maxDashes) + (count > maxDashes ? 1 : 0), 1))
    return max(
      metrics.pillMinHeight,
      metrics.pillPadding * 2 + dashes * metrics.dashHeight + (dashes - 1) * metrics.dashGap)
  }

  /// 药丸那块窗口的 frame（全局坐标）：贴着可见区的那条边，宽 = 感应范围（比药丸还窄时至少装得下药丸，
  /// 这时只有贴边的那一条感应，见 NoteDeckPill），高 = 药丸高，纵向按 position 摆
  static func pillFrame(
    on screen: NoteDeckScreen, edge: NoteDeckOptions.Edge, count: Int, options: NoteDeckOptions
  ) -> CGRect {
    let metrics = NoteDeckMetrics(scale: options.size.scale)
    let visible = screen.visibleFrame
    let height = min(
      pillHeight(count: count, metrics: metrics), max(visible.height - 2 * pillMargin, 1))
    let width = max(options.sense, metrics.pillWidth + 1)
    let top = visible.maxY - pillMargin - height
    let bottom = visible.minY + pillMargin
    let y = (top - CGFloat(options.position) * max(top - bottom, 0)).rounded()
    return CGRect(
      x: edge == .right ? visible.maxX - width : visible.minX, y: y, width: width, height: height)
  }

  // MARK: 放哪块屏、哪条边

  /// 这块屏的这条边是不是和别的屏相接（那边贴着另一块屏、纵向有重叠）：相接的边鼠标一过就到了另一块屏，不放
  static func isJoined(
    _ edge: NoteDeckOptions.Edge, of index: Int, in screens: [NoteDeckScreen]
  ) -> Bool {
    let own = screens[index].frame
    let x = edge == .right ? own.maxX : own.minX
    return screens.enumerated().contains { offset, other in
      let facing = edge == .right ? other.frame.minX : other.frame.maxX
      return offset != index && abs(facing - x) < 1 && other.frame.minY < own.maxY
        && other.frame.maxY > own.minY
    }
  }

  /// 想放 edge：它和别的屏相接就换另一侧，两侧都相接这块屏不放（nil）
  static func freeEdge(
    of index: Int, in screens: [NoteDeckScreen], preferring edge: NoteDeckOptions.Edge
  ) -> NoteDeckOptions.Edge? {
    [edge, edge.opposite].first { !isJoined($0, of: index, in: screens) }
  }

  /// 每块屏放不放、放哪边。screens 的第一块是主显示器（NSScreen.screens 的顺序）
  static func placements(
    _ screens: [NoteDeckScreen], options: NoteDeckOptions
  ) -> [NoteDeckPlacement] {
    guard !screens.isEmpty else { return [] }
    let targets: [Int]
    switch options.display {
    case .main: targets = [0]
    case .all: targets = Array(screens.indices)
    case .named(let name): targets = [screens.firstIndex { $0.name == name } ?? 0]
    }
    return targets.compactMap { index in
      freeEdge(of: index, in: screens, preferring: options.edge).map {
        NoteDeckPlacement(screen: index, edge: $0)
      }
    }
  }

  /// 显示器的名字去重：同名的第二块起加序号（「DELL」「DELL 2」「DELL 3」），顺序不变。设置页的菜单和
  /// 「指定某一块」认的都是去重后的名字
  static func uniqueNames(_ names: [String]) -> [String] {
    var seen: [String: Int] = [:]
    return names.map { name in
      let count = (seen[name] ?? 0) + 1
      seen[name] = count
      return count == 1 ? name : "\(name) \(count)"
    }
  }

  /// ⌥ 拖药丸能不能拖到别的屏：只有「指定某一块」、而且指定的那块真接着的时候——它不在、药丸是退回主显示器的，
  /// 这时拖只换边和高度，不改写「指定的是哪块」（不然外接屏插回来药丸不再回去）
  static func crossesScreens(_ display: NoteDeckOptions.Display, screens: [NoteDeckScreen]) -> Bool
  {
    if case .named(let name) = display { return screens.contains { $0.name == name } }
    return false
  }

  /// 按住 ⌥ 拖药丸到 mouse：贴鼠标所在那一半的边（那条边和别的屏相接就换另一侧），高度跟着鼠标。
  /// crossesScreens：能不能拖到别的屏（只有「指定某一块」时能）；鼠标所在的屏两侧都放不了就留在原来那块屏。
  /// 原来那块屏也放不了时是 nil
  static func dragged(
    to mouse: CGPoint, screens: [NoteDeckScreen], from index: Int, crossesScreens: Bool,
    pillHeight: CGFloat
  ) -> (placement: NoteDeckPlacement, position: Double)? {
    guard screens.indices.contains(index) else { return nil }
    let under = crossesScreens ? screens.firstIndex { $0.frame.contains(mouse) } : nil
    for target in [under, index].compactMap({ $0 }) {
      let wanted: NoteDeckOptions.Edge = mouse.x < screens[target].frame.midX ? .left : .right
      guard let edge = freeEdge(of: target, in: screens, preferring: wanted) else { continue }
      let visible = screens[target].visibleFrame
      let top = visible.maxY - pillMargin - pillHeight
      let span = top - (visible.minY + pillMargin)
      let ratio = span > 0 ? (top - (mouse.y - pillHeight / 2)) / span : 0.5
      return (NoteDeckPlacement(screen: target, edge: edge), Double(min(max(ratio, 0), 1)))
    }
    return nil
  }

  // MARK: 那叠

  /// 那叠的面板（全局坐标）：贴着可见区的那条边，宽 = 便签宽 + 间隔 + 标签列 + 给阴影的余量，高 = 可见区高
  static func panelFrame(
    on screen: NoteDeckScreen, edge: NoteDeckOptions.Edge, options: NoteDeckOptions
  ) -> CGRect {
    let visible = screen.visibleFrame
    let tab = NoteDeckMetrics(scale: options.size.scale).tabWidth
    let width = min(options.noteSize.size.width + noteGap + tab + panelMargin, visible.width)
    return CGRect(
      x: edge == .right ? visible.maxX - width : visible.minX, y: visible.minY, width: width,
      height: visible.height)
  }

  /// 标签列的顶离面板顶多远：整列对着药丸的中线居中，夹在面板里
  static func columnTop(pillCenter: CGFloat, columnHeight: CGFloat, panelHeight: CGFloat) -> CGFloat
  {
    let lowest = max(panelHeight - columnHeight - columnInset, columnInset)
    return min(max(pillCenter - columnHeight / 2, columnInset), lowest).rounded()
  }

  /// 打开的便签多大（屏幕太小时夹进面板）、它的顶离面板顶多远：对着它那张标签露出的一截居中，夹在面板里
  static func noteSize(_ size: CGSize, in panel: CGSize, tabWidth: CGFloat) -> CGSize {
    CGSize(
      width: min(size.width, max(panel.width - tabWidth - noteGap, 1)),
      height: min(size.height, max(panel.height - 2 * noteInset, 1)))
  }

  static func noteTop(tabCenter: CGFloat, noteHeight: CGFloat, panelHeight: CGFloat) -> CGFloat {
    let lowest = max(panelHeight - noteHeight - noteInset, noteInset)
    return min(max(tabCenter - noteHeight / 2, noteInset), lowest).rounded()
  }

  /// 贴着边的一竖条在屏幕上的位置（全局坐标）：宽 width，顶离面板顶 top，高 height
  static func columnFrame(
    panel: CGRect, edge: NoteDeckOptions.Edge, top: CGFloat, height: CGFloat, width: CGFloat
  ) -> CGRect {
    CGRect(
      x: edge == .right ? panel.maxX - width : panel.minX, y: panel.maxY - top - height,
      width: width, height: height)
  }

  /// 打开的便签在屏幕上的位置（全局坐标）：挨着标签列（隔 noteGap），顶离面板顶 top
  static func noteFrame(
    panel: CGRect, edge: NoteDeckOptions.Edge, top: CGFloat, size: CGSize, tabWidth: CGFloat
  ) -> CGRect {
    let offset = tabWidth + noteGap
    return CGRect(
      x: edge == .right ? panel.maxX - offset - size.width : panel.minX + offset,
      y: panel.maxY - top - size.height, width: size.width, height: size.height)
  }

  /// 热区（全局坐标）：标签列四周再往外 hotMargin；预览卡出着时连它一起算（鼠标要能挪过去点它）
  static func hotZone(
    panel: CGRect, edge: NoteDeckOptions.Edge, columnTop: CGFloat, columnHeight: CGFloat,
    tabWidth: CGFloat, showsPreview: Bool
  ) -> CGRect {
    columnFrame(
      panel: panel, edge: edge, top: columnTop, height: columnHeight,
      width: tabWidth + (showsPreview ? previewGap + previewWidth : 0)
    )
    .insetBy(dx: -hotMargin, dy: -hotMargin)
  }

  /// 拖动排序：从第 index 格拖了 offset（往下为正），落在第几格。要拖过一格的 60% 才换位——50% 的话手一抖
  /// 就在两格之间来回跳
  static func dragTarget(from index: Int, offset: CGFloat, step: CGFloat, count: Int) -> Int {
    guard count > 0, step > 0 else { return index }
    let raw = offset / step
    let moved = raw > 0 ? (raw + 0.4).rounded(.down) : (raw - 0.4).rounded(.up)
    return min(max(index + Int(moved), 0), count - 1)
  }
}

/// 一块显示器（NSScreen 里要用的那几样；单测直接造）
nonisolated struct NoteDeckScreen: Equatable, Sendable {
  var name: String
  var frame: CGRect
  var visibleFrame: CGRect
}

/// 放在第几块屏的哪条边
nonisolated struct NoteDeckPlacement: Equatable, Sendable {
  var screen: Int
  var edge: NoteDeckOptions.Edge
}

/// 竖排的标题：中日韩文字、全角符号、表情正着放、一字一格；别的文字（拉丁字母、数字）整段转 90°，
/// 一个词不拆成一摞字母
nonisolated enum NoteDeckLabel {
  /// 一段：正着放的一格（一个字），或者转着放的一段
  struct Run: Equatable, Sendable {
    var text: String
    var isUpright: Bool
  }

  static let ellipsis = "…"

  /// 这个字竖排时正着放吗
  static func isUpright(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      // 表情（本来就按表情画的，或者带了「按表情画」的变体选择符）
      if scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F { return true }
      switch scalar.value {
      case 0x1100...0x11FF,  // 谚文字母
        0x2E80...0x303F,  // 部首、中日韩符号和标点
        0x3040...0x31FF,  // 假名、注音
        0x3200...0x4DBF,  // 带圈的、兼容用的中日韩字符，扩展 A
        0x4E00...0x9FFF,  // 汉字
        0xA960...0xA97F, 0xAC00...0xD7FF,  // 谚文
        0xF900...0xFAFF,  // 兼容汉字
        0xFE10...0xFE1F, 0xFE30...0xFE6F,  // 竖排用的标点、小写变体
        0xFF01...0xFF60, 0xFFE0...0xFFE6,  // 全角字母、数字、符号
        0x1F000...0x1FAFF,  // 表情和图形符号
        0x20000...0x3134F:  // 汉字扩展 B 起
        return true
      default: return false
      }
    }
  }

  /// 分段。空白：挨着转着放的字就跟着那一段转（「buy milk」是一段），夹在两个正立的字中间才是竖着的一格空
  static func runs(for title: String) -> [Run] {
    let characters = Array(title)
    var runs: [Run] = []
    var rotated = ""
    func flush() {
      if !rotated.isEmpty { runs.append(Run(text: rotated, isUpright: false)) }
      rotated = ""
    }
    for (index, character) in characters.enumerated() {
      let upright: Bool
      if character.isWhitespace {
        let next = characters[(index + 1)...].first { !$0.isWhitespace }
        upright = rotated.isEmpty && next.map(isUpright) ?? true
      } else {
        upright = isUpright(character)
      }
      if upright {
        flush()
        runs.append(Run(text: String(character), isUpright: true))
      } else {
        rotated.append(character)
      }
    }
    flush()
    return runs
  }

  /// 排得下就原样；排不下从后面截，末尾加「…」（跟着转着的那段一起转，前面是正立的字就单独一段——转过来正好是
  /// 竖着的三个点）。advance：一段占多长（单测传固定的数，界面传 advance(of:metrics:)）
  static func fitted(_ title: String, limit: CGFloat, advance: (Run) -> CGFloat) -> [Run] {
    let all = runs(for: title)
    guard all.reduce(0, { $0 + advance($1) }) > limit else { return all }
    let dots = Run(text: ellipsis, isUpright: false)
    let room = limit - advance(dots)
    var kept: [Run] = []
    var used: CGFloat = 0
    for run in all {
      let length = advance(run)
      if used + length <= room {
        kept.append(run)
        used += length
        continue
      }
      guard !run.isUpright else { break }
      // 转着放的这一段放不全：一个字一个字试，连省略号一起量
      var head = ""
      for character in run.text {
        let candidate = Run(text: head + String(character) + ellipsis, isUpright: false)
        guard used + advance(candidate) <= limit else { break }
        head.append(character)
      }
      let trimmed = trimmingTail(head)
      if !trimmed.isEmpty {
        kept.append(Run(text: trimmed + ellipsis, isUpright: false))
        return kept
      }
      break
    }
    // 连一个字加省略号都放不下（标签压得很短）：只留打头的那一截、不加省略号——总比只剩三个点强
    if kept.isEmpty, let first = all.first {
      if first.isUpright {
        if advance(first) <= limit { return [first] }
      } else {
        var head = ""
        for character in first.text {
          guard advance(Run(text: head + String(character), isUpright: false)) <= limit else {
            break
          }
          head.append(character)
        }
        if !trimmingTail(head).isEmpty { return [Run(text: trimmingTail(head), isUpright: false)] }
      }
    }
    // 末尾是竖着的空格就不留了
    while let last = kept.last, last.isUpright, last.text.allSatisfy(\.isWhitespace) {
      kept.removeLast()
    }
    if let last = kept.last, !last.isUpright {
      kept[kept.count - 1].text = trimmingTail(last.text) + ellipsis
    } else {
      kept.append(dots)
    }
    return kept
  }

  /// 去掉末尾的空白（开头的留着：那是和前一个字之间的空）
  private static func trimmingTail(_ text: String) -> String {
    String(text.reversed().drop(while: \.isWhitespace).reversed())
  }

  /// 一段占多长：正着放的一格是一个字高，转着放的是这段字横排的宽
  static func advance(of run: Run, metrics: NoteDeckMetrics) -> CGFloat {
    run.isUpright
      ? metrics.glyphAdvance
      : ceil((run.text as NSString).size(withAttributes: [.font: metrics.font]).width)
  }

  /// 整个标题竖着排多长
  static func length(_ title: String, metrics: NoteDeckMetrics) -> CGFloat {
    runs(for: title).reduce(0) { $0 + advance(of: $1, metrics: metrics) }
  }
}
