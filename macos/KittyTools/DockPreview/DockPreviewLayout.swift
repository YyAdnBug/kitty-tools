// 程序坞预览面板的尺寸、位置和「还算不算在面板附近」（第九族第 2 批，拍板 C5；纯函数，配单测 DockPreviewTests）：
// 缩略图高 140 点、宽按窗口比例（夹在 80…260）；沿程序坞的方向排一排（程序坞在下面就横排，在左右两边就竖排），
// 放不下先把缩略图一起缩（最小高 90），还放不下就换行（往屏幕里面多排几排）；排满这块屏还放不下的不列。不用滚动：
// 面板从不当 key，滚动视图里的点击、只有竖滚轮的鼠标都靠不住（评审 M5 M6）。没有屏幕录制授权时缩略图换成一块
// 140 × 76 的图标位（拍板 A2：只列图标和标题）。面板贴着图标那一边、离图标 6 点，夹进那块屏里（内缩 8）。

import AppKit

enum DockPreviewLayout {
  /// 程序坞在屏幕的哪一边（偏好 com.apple.dock 的 orientation；没有就是下面）
  enum Edge: Equatable {
    case bottom, left, right

    init(orientation: String?) {
      switch orientation {
      case "left": self = .left
      case "right": self = .right
      default: self = .bottom
      }
    }

    /// 缩略图横着排（程序坞在下面）
    var isHorizontal: Bool { self == .bottom }
  }

  static let thumbHeight: CGFloat = 140
  static let minimumThumbHeight: CGFloat = 90
  static let thumbWidths: ClosedRange<CGFloat> = 80...260
  /// 没有屏幕录制授权时的图标位（32 点的图标居中，下面还放得下角标、不叠在一起）
  static let compactThumb = CGSize(width: 140, height: 76)
  /// 面板四周（玻璃 / 毛玻璃的内边距）
  static let padding: CGFloat = 10
  /// 面板顶上一行：App 图标 + 名字
  static let headerHeight: CGFloat = 26
  /// 一张卡片四周（悬停的浅灰底就是这么大）
  static let cardPadding: CGFloat = 6
  /// 缩略图到标题、标题一行
  static let titleGap: CGFloat = 4
  static let titleHeight: CGFloat = 15
  /// 卡片之间、排和排之间
  static let spacing: CGFloat = 4
  /// 面板离图标
  static let gap: CGFloat = 6
  /// 面板离屏幕边
  static let screenInset: CGFloat = 8
  /// 没有屏幕录制授权时最底下那行说明
  static let noteHeight: CGFloat = 20

  /// 排好的样子
  struct Plan: Equatable {
    /// 列出来的每一扇的缩略图框（点）；窗口太多、排满这块屏还放不下时比窗口少，多的不列
    var thumbs: [CGSize]
    /// 每一排是 thumbs 里的哪几张（沿程序坞的方向排，排满了另起一排）
    var lines: [Range<Int>]
    /// 卡片那一块的长宽
    var content: CGSize
    var panel: CGSize
  }

  /// 一张缩略图的框：高 height，宽按窗口比例夹在 thumbWidths 里（跟着 height 等比缩）
  static func thumb(for window: CGSize, height: CGFloat) -> CGSize {
    let scale = height / thumbHeight
    let ratio = window.height > 0 ? window.width / window.height : 1
    let width = min(
      max(height * ratio, thumbWidths.lowerBound * scale), thumbWidths.upperBound * scale)
    return CGSize(width: width.rounded(), height: height)
  }

  /// 一张卡片（缩略图 + 标题 + 四周）
  static func card(_ thumb: CGSize) -> CGSize {
    CGSize(
      width: thumb.width + cardPadding * 2,
      height: thumb.height + titleGap + titleHeight + cardPadding * 2)
  }

  /// 排：along 是沿程序坞方向能用的长度（下面：屏宽；左右：可见区的高），across 是往屏幕里能用的长度（下面：图标上沿
  /// 到可见区顶；左右：图标外沿到屏幕另一边）；compact = 没有屏幕录制授权（图标位 + 最底下一行说明）
  static func plan(
    _ windows: [CGSize], edge: Edge, along: CGFloat, across: CGFloat, compact: Bool = false
  ) -> Plan {
    let horizontal = edge.isHorizontal
    let note = compact ? noteHeight : 0
    // 面板上不放卡片的那部分：沿程序坞方向、往屏幕里方向各多少（顶上那行和说明总在上下）
    let chromeAlong = horizontal ? padding * 2 : padding * 2 + headerHeight + note
    let chromeAcross = horizontal ? padding * 2 + headerHeight + note : padding * 2
    func alongSize(_ size: CGSize) -> CGFloat { horizontal ? size.width : size.height }
    func acrossSize(_ size: CGSize) -> CGFloat { horizontal ? size.height : size.width }
    func lineLength(_ cards: ArraySlice<CGSize>) -> CGFloat {
      cards.map(alongSize).reduce(0, +) + spacing * CGFloat(max(cards.count - 1, 0))
    }
    func thumbs(_ height: CGFloat) -> [CGSize] {
      compact
        ? Array(repeating: compactThumb, count: windows.count)
        : windows.map { thumb(for: $0, height: height) }
    }

    // 一排：缩略图一点点缩，放得下为止（到下限就不缩了）
    var height = thumbHeight
    var sized = thumbs(height)
    while !compact, height > minimumThumbHeight,
      lineLength(sized.map(card)[...]) + chromeAlong > along
    {
      height -= 1
      sized = thumbs(height)
    }
    let cards = sized.map(card)

    // 还放不下就换行（一张也放不下的也自己占一排）
    let room = max(along - chromeAlong, 0)
    var lines: [Range<Int>] = []
    var start = 0
    for index in cards.indices where index > start {
      if lineLength(cards[start...index]) > room {
        lines.append(start..<index)
        start = index
      }
    }
    if !cards.isEmpty { lines.append(start..<cards.count) }

    // 往屏幕里排满了：后面几排不列（ponytail: 一块屏最小高 90 时能排几十扇，更多的窗口少见；要全列再加一张「还有 N 扇」）
    func thickness(_ line: Range<Int>) -> CGFloat { cards[line].map(acrossSize).max() ?? 0 }
    func depth(_ lines: [Range<Int>]) -> CGFloat {
      lines.map(thickness).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
    }
    while lines.count > 1, depth(lines) + chromeAcross > across { lines.removeLast() }
    let shown = lines.last?.upperBound ?? 0

    let longest = lines.map { lineLength(cards[$0]) }.max() ?? 0
    let content =
      horizontal
      ? CGSize(width: longest, height: depth(lines)) : CGSize(width: depth(lines), height: longest)
    let panel = CGSize(
      width: content.width + padding * 2,
      height: content.height + headerHeight + padding * 2 + note)
    return Plan(thumbs: Array(sized.prefix(shown)), lines: lines, content: content, panel: panel)
  }

  /// 面板左下角（AppKit 全局坐标）：贴着图标朝屏幕里的那一边，居中对着图标，夹进 screen（这块屏的 frame；
  /// 左右两边时竖着夹进可见区 visible，不压菜单栏）
  static func origin(panel: CGSize, item: CGRect, edge: Edge, screen: CGRect, visible: CGRect)
    -> CGPoint
  {
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
      max(low, min(value, max(low, high)))
    }
    switch edge {
    case .bottom:
      return CGPoint(
        x: clamp(
          item.midX - panel.width / 2, screen.minX + screenInset,
          screen.maxX - screenInset - panel.width),
        y: item.maxY + gap)
    case .left, .right:
      let x = edge == .left ? item.maxX + gap : item.minX - gap - panel.width
      return CGPoint(
        x: x,
        y: clamp(
          item.midY - panel.height / 2, visible.minY + screenInset,
          visible.maxY - screenInset - panel.height))
    }
  }

  /// 这一边能用多长、往屏幕里能用多深（plan 的 along / across）
  static func room(item: CGRect, edge: Edge, screen: CGRect, visible: CGRect) -> (
    along: CGFloat, across: CGFloat
  ) {
    switch edge {
    case .bottom:
      return (screen.width - screenInset * 2, visible.maxY - screenInset - (item.maxY + gap))
    case .left:
      return (visible.height - screenInset * 2, screen.maxX - screenInset - (item.maxX + gap))
    case .right:
      return (visible.height - screenInset * 2, item.minX - gap - (screen.minX + screenInset))
    }
  }

  /// 图标在哪块屏：中心落在哪块屏里就是哪块，都不在（自动隐藏的程序坞正在滑出来）就挑离得最近的
  static func screenIndex(for item: CGRect, in screens: [CGRect]) -> Int? {
    let center = CGPoint(x: item.midX, y: item.midY)
    func distance(_ rect: CGRect) -> CGFloat {
      let dx = max(rect.minX - center.x, 0, center.x - rect.maxX)
      let dy = max(rect.minY - center.y, 0, center.y - rect.maxY)
      return (dx * dx + dy * dy).squareRoot()
    }
    return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
  }

  /// 鼠标还算不算在预览附近：在面板上（外扩 4 点）、在图标上（外扩 2 点），或者在图标和面板之间那道缝里
  /// （图标那么宽、从图标边到面板边）。弹着时按它决定收不收，不看追踪区的进出（面板改尺寸、淡出时进出事件会丢）
  static func keepsOpen(mouse: CGPoint, panel: CGRect, item: CGRect, edge: Edge) -> Bool {
    if panel.insetBy(dx: -4, dy: -4).contains(mouse) || item.insetBy(dx: -2, dy: -2).contains(mouse)
    {
      return true
    }
    let bridge =
      switch edge {
      case .bottom:
        CGRect(
          x: item.minX, y: item.maxY, width: item.width, height: max(panel.minY - item.maxY, 0))
      case .left:
        CGRect(
          x: item.maxX, y: item.minY, width: max(panel.minX - item.maxX, 0), height: item.height)
      case .right:
        CGRect(
          x: panel.maxX, y: item.minY, width: max(item.minX - panel.maxX, 0), height: item.height)
      }
    return bridge.insetBy(dx: -2, dy: -2).contains(mouse)
  }

  /// 鼠标离开预览之后的倒计时：离开满 delay 秒才收，回来就重新算
  struct Linger: Equatable {
    static let delay: TimeInterval = 0.3
    private(set) var leftAt: TimeInterval?

    /// 这一刻在不在附近；返回 true = 该收了
    mutating func update(inside: Bool, now: TimeInterval) -> Bool {
      guard !inside else {
        leftAt = nil
        return false
      }
      guard let leftAt else {
        self.leftAt = now
        return false
      }
      return now - leftAt >= Self.delay
    }
  }
}
