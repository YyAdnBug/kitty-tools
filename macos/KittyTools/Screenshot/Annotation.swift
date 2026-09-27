// 截图标注（值类型）：矩形、椭圆、箭头、直线（这两种拖中间的手柄弯成弧线）、画笔、荧光笔、文字、序号、马赛克、聚光灯
// （mac-whisker §6「工具」）。
// 坐标存整屏视图坐标（点，原点左下）：调整选区不丢标注（修旧版 #43）。屏幕显示（SelectionView 的标注层）和导出（render）
// 只走同一个 drawAll，所见即所得；马赛克从冻结帧取像素，所以导出、识字拿到的都是打码后的图（修旧版把原图拿去识字，#44）。
// 颜色是固定的 sRGB 值，不随深浅色变。除马赛克、聚光灯、荧光笔外都带 black 0.28 / blur 3 的阴影（白色标注在白底上也看得见）。
// 每个工具记住自己上次的样式（Style.remembered / remember，存 Prefs.screenshotToolStyles）。

import AppKit

struct Annotation: Identifiable, Equatable {
  /// 顺序即工具栏顺序和数字键（1–9、0）
  enum Tool: Int, CaseIterable {
    case rectangle = 1
    case ellipse, arrow, line, pen, highlighter, text, counter, mosaic, spotlight

    var title: String {
      switch self {
      case .rectangle: "矩形"
      case .ellipse: "椭圆"
      case .arrow: "箭头"
      case .line: "直线"
      case .pen: "画笔"
      case .highlighter: "荧光笔"
      case .text: "文字"
      case .counter: "序号"
      case .mosaic: "马赛克"
      case .spotlight: "聚光灯"
      }
    }

    var symbol: String {
      switch self {
      case .rectangle: "rectangle"
      case .ellipse: "circle"
      case .arrow: "arrow.up.right"
      case .line: "line.diagonal"
      case .pen: "scribble.variable"
      case .highlighter: "highlighter"
      case .text: "t.square"  // textformat 在中文系统上画成「格式」两个字；带拉丁字母的不跟系统语言换字形
      case .counter: "1.circle"
      case .mosaic: "checkerboard.rectangle"
      case .spotlight: "circle.square.fill"
      }
    }

    /// 数字键：第 10 个是 0
    var key: String { String(rawValue % 10) }

    /// 马赛克、聚光灯没有颜色（托盘不出色点）
    var hasColor: Bool { self != .mosaic && self != .spotlight }

    /// 样式托盘的选项分段（Style.option 是下标）；空 = 没有选项
    var optionTitles: [String] {
      switch self {
      case .rectangle, .ellipse: ["空心", "实心"]
      case .text: ["无底", "描边", "底色"]
      case .mosaic: ["像素", "模糊"]
      default: []
      }
    }

    var weightTitles: [String] {
      switch self {
      case .text: ["小", "中", "大"]
      case .spotlight: ["浅", "中", "深"]
      default: ["细", "中", "粗"]
      }
    }

    /// 拖出来的；文字、序号是单击放置
    var isDragDrawn: Bool { self != .text && self != .counter }
  }

  enum Shape: Equatable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    /// bend：弯箭头 / 弯直线的弧线中点（弯曲手柄）离弦中点的偏移，按弦记——dx 沿弦（from → to）、dy 在弦的左侧，单位是
    /// 弦长；.zero = 直的。存相对量：整条挪动、⌘D / ⌥ 复制、方向键、撤销都不用另算，拖两端时弯度跟着弦等比缩放、旋转
    case arrow(from: CGPoint, to: CGPoint, bend: CGVector = .zero)
    /// bend 同箭头
    case line(from: CGPoint, to: CGPoint, bend: CGVector = .zero)
    /// 画笔经过的点（调用方拖动时累点）
    case pen([CGPoint])
    case highlighter(from: CGPoint, to: CGPoint)
    /// origin：文字框左上角
    case text(String, origin: CGPoint)
    case counter(Int, center: CGPoint)
    case mosaic(CGRect)
    case spotlight(CGRect)
  }

  enum Palette: Int, CaseIterable, Codable {
    case pink, red, orange, yellow, green, blue, black, white

    var title: String {
      switch self {
      case .pink: "粉"
      case .red: "红"
      case .orange: "橙"
      case .yellow: "黄"
      case .green: "绿"
      case .blue: "蓝"
      case .black: "黑"
      case .white: "白"
      }
    }

    var color: NSColor {
      switch self {
      case .pink: AccentPalette.brandPink  // 品牌粉（标注颜色是内容色，不随强调色变）
      case .red: Self.srgb(0xFF3B30)
      case .orange: Self.srgb(0xFF9500)
      case .yellow: Self.srgb(0xFFCC00)
      case .green: Self.srgb(0x34C759)
      case .blue: Self.srgb(0x007AFF)
      case .black: Self.srgb(0x000000)
      case .white: Self.srgb(0xFFFFFF)
      }
    }

    private static func srgb(_ rgb: Int) -> NSColor {
      NSColor(
        srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// 压在这个颜色上的字（底色文字、序号）：黄、白上用黑字，其余白字
    var ink: NSColor { self == .yellow || self == .white ? .black : .white }
  }

  enum Weight: Int, CaseIterable, Codable {
    case small, medium, large

    var title: String { ["细", "中", "粗"][rawValue] }
    var lineWidth: CGFloat { [2, 4, 6][rawValue] }
    var fontSize: CGFloat { [14, 20, 28][rawValue] }
    /// 马赛克每格的边长（点）
    var mosaicBlock: CGFloat { [6, 10, 16][rawValue] }
    var counterDiameter: CGFloat { [20, 26, 34][rawValue] }
    var highlighterHeight: CGFloat { [12, 18, 26][rawValue] }
    /// 聚光灯外面压暗的程度
    var spotlightDim: CGFloat { [0.35, 0.5, 0.65][rawValue] }
  }

  /// 第一次用是红色中号（荧光笔黄色）；option 是 Tool.optionTitles 的下标
  struct Style: Equatable, Codable {
    var color = Palette.red
    var weight = Weight.medium
    var option = 0

    /// 这个工具上次用的样式
    static func remembered(for tool: Tool, in defaults: UserDefaults = .standard) -> Style {
      saved(in: defaults)[String(tool.rawValue)]
        ?? (tool == .highlighter ? Style(color: .yellow) : Style())
    }

    static func remember(_ style: Style, for tool: Tool, in defaults: UserDefaults = .standard) {
      var styles = saved(in: defaults)
      styles[String(tool.rawValue)] = style
      if let data = try? JSONEncoder().encode(styles) {
        defaults.set(data, forKey: Prefs.screenshotToolStyles)
      }
    }

    private static func saved(in defaults: UserDefaults) -> [String: Style] {
      defaults.data(forKey: Prefs.screenshotToolStyles)
        .flatMap { try? JSONDecoder().decode([String: Style].self, from: $0) } ?? [:]
    }
  }

  /// 选中标注的调整手柄：矩形类四角，线类两端，箭头、直线还有弧线中点（bend，拖它弯曲）
  enum Handle { case start, end, bend, topLeft, topRight, bottomLeft, bottomRight }

  var id = UUID()
  var shape: Shape
  var style = Style()

  var tool: Tool {
    switch shape {
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .arrow: .arrow
    case .line: .line
    case .pen: .pen
    case .highlighter: .highlighter
    case .text: .text
    case .counter: .counter
    case .mosaic: .mosaic
    case .spotlight: .spotlight
    }
  }

  // MARK: 几何

  /// 画出来占的范围（含线宽、箭头，不含阴影），用来画选中框、点中文字和马赛克
  var bounds: CGRect {
    let width = style.weight.lineWidth
    switch shape {
    case .rectangle(let rect), .ellipse(let rect):
      return rect.insetBy(dx: -width / 2, dy: -width / 2)
    case .arrow(let from, let to, let bend):
      // 弯的：弧线会鼓出两端围成的框，按弧线的外框算
      let pad = max(Self.arrowWing(from: from, to: to, width: width, bend: bend), width)
      return Self.curveBox(from, to, bend).insetBy(dx: -pad, dy: -pad)
    case .line(let from, let to, let bend):
      return Self.curveBox(from, to, bend).insetBy(dx: -width / 2, dy: -width / 2)
    case .highlighter(let from, let to):
      let half = style.weight.highlighterHeight / 2
      return Self.box(from, to).insetBy(dx: -half, dy: -half)
    case .pen(let points):
      let xs = points.map(\.x)
      let ys = points.map(\.y)
      guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
      else { return .null }
      return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        .insetBy(dx: -width / 2, dy: -width / 2)
    case .text(let string, let origin):
      // 有的字形（泰文声调、斜体）会画出文字框：按字号留边（至少盖住底色块），局部重画不留残影、不被裁掉
      let pad = max(style.weight.fontSize / 3, Self.platePadding.width)
      return Self.textFrame(string, origin: origin, weight: style.weight).insetBy(
        dx: -pad, dy: -pad)
    case .counter(_, let center):
      let radius = style.weight.counterDiameter / 2 + 1  // 白描边一半在圆外
      return CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    case .mosaic(let rect), .spotlight(let rect):
      return rect
    }
  }

  /// 连阴影一起占的范围：局部重画按它来，不然挪走后留下一圈阴影残影。聚光灯是它的洞：洞外的压暗铺满压暗范围（选区）、
  /// 只随压暗的档（见 dimLevel）和压暗范围（见 dimChange）变，挪洞、改洞只重画洞（屏幕上压暗在标注层下面的图层里，
  /// 重画的只是洞里垫底的标注补的那层压暗）
  var drawBounds: CGRect {
    switch tool {
    case .mosaic, .highlighter, .spotlight: bounds
    default: bounds.insetBy(dx: -Self.shadowReach, dy: -Self.shadowReach)
    }
  }

  /// 画笔拖动中往后接了点（previous 的点是现在的开头）时要重画的那一截：penPath 只有收尾变了（原来最后一段直线换成
  /// 曲线 + 新的收尾直线），都在倒数第三个旧点起的这些点围成的范围里（含线宽、阴影）。不是接着画的 = nil，按整条重画。
  /// 整条笔迹的外框在 5K 屏上可能是大半屏，每动一下都重画太慢
  func penGrowth(from previous: Annotation) -> CGRect? {
    guard case .pen(let points) = shape, case .pen(let old) = previous.shape,
      style == previous.style, old.count >= 2, points.count > old.count, points.starts(with: old)
    else { return nil }
    let tail = points[(old.count - 2)...]
    let xs = tail.map(\.x)
    let ys = tail.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return nil }
    let pad = style.weight.lineWidth / 2 + Self.shadowReach
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      .insetBy(dx: -pad, dy: -pad)
  }

  /// 聚光灯压暗的档（最后一个聚光灯的；没有 = nil）。它变了，局部重画的调用方要整块重画
  static func dimLevel(of annotations: [Annotation]) -> Weight? {
    annotations.last { $0.tool == .spotlight }?.style.weight
  }

  /// 压暗范围（选区）从 old 变到 new 时要重画的几条：每条边新旧位置之间、横跨两个选区的并集（盖住两者不重合的部分；
  /// 拖边、平移时每次只有几点宽）
  static func dimChange(from old: CGRect, to new: CGRect) -> [CGRect] {
    let union = old.union(new)
    let columns = [(old.minX, new.minX), (old.maxX, new.maxX)].filter { $0 != $1 }.map {
      CGRect(x: min($0, $1), y: union.minY, width: abs($0 - $1), height: union.height)
    }
    let rows = [(old.minY, new.minY), (old.maxY, new.maxY)].filter { $0 != $1 }.map {
      CGRect(x: union.minX, y: min($0, $1), width: union.width, height: abs($0 - $1))
    }
    return columns + rows
  }

  /// 画的层次（drawAll 的顺序）：马赛克 → 聚光灯 → 其余 → 序号
  private var layer: Int {
    switch tool {
    case .mosaic: 0
    case .spotlight: 1
    case .counter: 3
    default: 2
    }
  }

  /// 点中的最上面那条：按画的层次倒着找（序号压在后画的标注上面，马赛克、聚光灯垫在最下面），同一层后画的在上
  static func topmost(in annotations: [Annotation], at point: CGPoint) -> Annotation? {
    annotations.reversed().filter { $0.contains(point) }.max { $0.layer < $1.layer }
  }

  /// 点中它没有：空心矩形 / 椭圆和聚光灯只认边线（里面点不中，免得挡住下面的标注、聚光灯里还要接着画），
  /// 线类认线（箭头连箭头），实心形状、文字、序号、马赛克认整块
  func contains(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
    let width = style.weight.lineWidth
    let filled = style.option == 1
    switch shape {
    case .rectangle(let rect) where filled:
      return rect.insetBy(dx: -width / 2 - tolerance, dy: -width / 2 - tolerance).contains(point)
    case .rectangle(let rect):
      return Self.onEdge(point, of: rect, reach: width / 2 + tolerance)
    case .spotlight(let rect):
      return Self.onEdge(point, of: rect, reach: tolerance + 2)
    case .ellipse(let rect):
      let rx = max(rect.width / 2, 0.5)
      let ry = max(rect.height / 2, 0.5)
      let k = hypot((point.x - rect.midX) / rx, (point.y - rect.midY) / ry)
      // 到椭圆线的距离按短半轴近似（长轴两端偏宽容）
      let distance = (k - 1) * min(rx, ry)
      return filled ? distance <= width / 2 + tolerance : abs(distance) <= width / 2 + tolerance
    case .arrow(let from, let to, let bend), .line(let from, let to, let bend):
      // 先按外框（盖住线和箭头，见 bounds）排除：每次鼠标移动都要问一遍所有标注，弯的逐段量距离、建轮廓要几十微秒
      guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
      // 弯的认弧线（按 curvePoints 的折线算，直的就是那一段），箭头再认箭头
      let line = Self.curvePoints(from, to, bend)
      return zip(line, line.dropFirst()).contains {
        Self.distance(from: point, toSegment: $0, $1) <= width / 2 + tolerance
      }
        || tool == .arrow
          && Self.arrowPath(from: from, to: to, width: width, bend: bend)?.contains(point) == true
    case .highlighter(let from, let to):
      return Self.distance(from: point, toSegment: from, to)
        <= style.weight.highlighterHeight / 2 + tolerance
    case .pen(let points):
      let reach = width / 2 + tolerance
      guard let first = points.first else { return false }
      return hypot(point.x - first.x, point.y - first.y) <= reach
        || zip(points, points.dropFirst()).contains {
          Self.distance(from: point, toSegment: $0, $1) <= reach
        }
    case .counter(_, let center):
      return hypot(point.x - center.x, point.y - center.y)
        <= style.weight.counterDiameter / 2 + tolerance
    case .text, .mosaic:
      return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
  }

  /// 小到看不出来的（误点）不留
  var isMeaningful: Bool {
    switch shape {
    case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .spotlight(let rect):
      rect.width >= 3 && rect.height >= 3
    case .arrow(let from, let to, _), .line(let from, let to, _), .highlighter(let from, let to):
      hypot(to.x - from.x, to.y - from.y) >= 6
    case .pen(let points):
      points.count >= 2 && max(bounds.width, bounds.height) - style.weight.lineWidth >= 3
    case .text(let string, _): !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .counter: true
    }
  }

  func offset(by delta: CGSize) -> Annotation {
    let shift = { (point: CGPoint) in
      CGPoint(x: point.x + delta.width, y: point.y + delta.height)
    }
    var moved = self
    switch shape {
    case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .spotlight(let rect):
      moved.shape = Self.boxed(tool, rect.offsetBy(dx: delta.width, dy: delta.height))
    case .arrow(let from, let to, _), .line(let from, let to, _), .highlighter(let from, let to):
      moved.shape = Self.segment(tool, from: shift(from), to: shift(to), bend: bend)
    case .pen(let points): moved.shape = .pen(points.map(shift))
    case .text(let string, let origin): moved.shape = .text(string, origin: shift(origin))
    case .counter(let number, let center): moved.shape = .counter(number, center: shift(center))
    }
    return moved
  }

  /// 复制一份（新 id）：⌘D 往右下偏 12，⌥ 拖动传 .zero。序号的编号不变，要不要换由调用方决定
  func duplicated(offset delta: CGSize = CGSize(width: 12, height: -12)) -> Annotation {
    var copy = offset(by: delta)
    copy.id = UUID()
    return copy
  }

  /// 选中时的调整手柄：矩形类四角，线类两端；箭头、直线还有弧线中点（弯曲手柄，直的在弦中点：CleanShot 也是直的就给，
  /// 看得见才知道能弯），弦短于 32 点的不给（直的中点离两端不到 16 点，和端点手柄挤在一起）。只看弦、不看弧线中点离两端
  /// 多远：拖着弯曲手柄往一端靠时它不会在光标下消失；荧光笔不弯；文字、序号、画笔只能拖动（空）
  var handles: [(Handle, CGPoint)] {
    switch shape {
    case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .spotlight(let rect):
      return [
        (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
        (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
      ]
    case .arrow(let from, let to, let bend), .line(let from, let to, let bend):
      let roomy = hypot(to.x - from.x, to.y - from.y) >= 32
      return [(.start, from), (.end, to)]
        + (roomy ? [(.bend, Self.curveMidpoint(from: from, to: to, bend: bend))] : [])
    case .highlighter(let from, let to):
      return [(.start, from), (.end, to)]
    case .pen, .text, .counter: return []
    }
  }

  /// 拖手柄改大小：矩形类对角不动（拖过头会翻过去）、⇧ 正方形；线类另一端不动、⇧ 吸 45°（箭头、直线的弯度跟着弦等比变）；
  /// 弯曲手柄见 curveBend（⇧ 对称的弧）。不认的手柄原样返回
  func resized(_ handle: Handle, to point: CGPoint, constrained: Bool) -> Annotation {
    var next = self
    switch (shape, handle) {
    case (.rectangle(let rect), _), (.ellipse(let rect), _), (.mosaic(let rect), _),
      (.spotlight(let rect), _):
      let fixed: CGPoint
      switch handle {
      case .topLeft: fixed = CGPoint(x: rect.maxX, y: rect.minY)
      case .topRight: fixed = CGPoint(x: rect.minX, y: rect.minY)
      case .bottomLeft: fixed = CGPoint(x: rect.maxX, y: rect.maxY)
      case .bottomRight: fixed = CGPoint(x: rect.minX, y: rect.maxY)
      case .start, .end, .bend: return self
      }
      next.shape = Self.shape(for: tool, from: fixed, to: point, constrained: constrained) ?? shape
    case (.arrow(let from, let to, _), .bend), (.line(let from, let to, _), .bend):
      next.shape = Self.segment(
        tool, from: from, to: to,
        bend: Self.curveBend(from: from, to: to, through: point, constrained: constrained))
    case (.arrow(_, let to, _), .start), (.line(_, let to, _), .start),
      (.highlighter(_, let to), .start):
      next.shape = Self.segment(
        tool, from: constrained ? Self.snapped(to, point) : point, to: to, bend: bend)
    case (.arrow(let from, _, _), .end), (.line(let from, _, _), .end),
      (.highlighter(let from, _), .end):
      next.shape = Self.segment(
        tool, from: from, to: constrained ? Self.snapped(from, point) : point, bend: bend)
    default:
      return self
    }
    return next
  }

  /// 拉直（双击弯曲手柄）：两端不动；别的工具原样返回
  var straightened: Annotation {
    var next = self
    switch shape {
    case .arrow(let from, let to, _), .line(let from, let to, _):
      next.shape = Self.segment(tool, from: from, to: to)
    default: break
    }
    return next
  }

  /// 箭头、直线的弯度（别的工具 .zero）
  private var bend: CGVector {
    switch shape {
    case .arrow(_, _, let bend), .line(_, _, let bend): bend
    default: .zero
    }
  }

  /// 拖动画出的形状（文字、序号是单击放置，返回 nil；画笔先给起止两点，由调用方累点）。
  /// constrained（按住 ⇧）：矩形类变正方形 / 正圆，线类吸附到 45° 的倍数
  static func shape(for tool: Tool, from start: CGPoint, to end: CGPoint, constrained: Bool)
    -> Shape?
  {
    switch tool {
    case .rectangle, .ellipse, .mosaic, .spotlight:
      var end = end
      if constrained {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
      }
      return boxed(tool, box(start, end))
    case .arrow, .line, .highlighter:
      return segment(tool, from: start, to: constrained ? snapped(start, end) : end)
    case .pen: return .pen([start, end])
    case .text, .counter: return nil
    }
  }

  /// 下一个序号：现有最大的 + 1
  static func nextCounter(in annotations: [Annotation]) -> Int {
    let numbers = annotations.compactMap { annotation -> Int? in
      if case .counter(let number, _) = annotation.shape { number } else { nil }
    }
    return (numbers.max() ?? 0) + 1
  }

  private static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
  }

  /// 矩形类工具的形状（别的工具不会走到这里）
  private static func boxed(_ tool: Tool, _ rect: CGRect) -> Shape {
    switch tool {
    case .ellipse: .ellipse(rect)
    case .mosaic: .mosaic(rect)
    case .spotlight: .spotlight(rect)
    default: .rectangle(rect)
    }
  }

  /// 线类工具的形状（别的工具不会走到这里；bend 只有箭头、直线用，荧光笔不弯）
  private static func segment(_ tool: Tool, from: CGPoint, to: CGPoint, bend: CGVector = .zero)
    -> Shape
  {
    switch tool {
    case .line: .line(from: from, to: to, bend: bend)
    case .highlighter: .highlighter(from: from, to: to)
    default: .arrow(from: from, to: to, bend: bend)
    }
  }

  /// end 绕 start 吸到 45° 的倍数，长度不变
  private static func snapped(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
    let angle = (atan2(end.y - start.y, end.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
    let length = hypot(end.x - start.x, end.y - start.y)
    return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
  }

  private static func onEdge(_ point: CGPoint, of rect: CGRect, reach: CGFloat) -> Bool {
    let inner = rect.insetBy(dx: reach, dy: reach)
    return rect.insetBy(dx: -reach, dy: -reach).contains(point)
      && (inner.isNull || inner.isEmpty || !inner.contains(point))
  }

  // MARK: 文字

  /// SF Pro Rounded semibold（中文回退到苹方，没有圆体）
  static func font(_ weight: Weight) -> NSFont {
    rounded(size: weight.fontSize, weight: .semibold)
  }

  private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
      ?? font
  }

  /// 文字框（origin 是左上角）。空串和末尾换行也留出一行的高度（输入框里光标要有地方）
  static func textFrame(_ string: String, origin: CGPoint, weight: Weight) -> CGRect {
    let measured = string.isEmpty || string.hasSuffix("\n") ? string + " " : string
    let size = NSAttributedString(string: measured, attributes: [.font: font(weight)])
      .boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).size
    return CGRect(
      x: origin.x, y: origin.y - ceil(size.height), width: ceil(size.width),
      height: ceil(size.height))
  }

  /// 「描边」样式的外描边：字宽 1/7（一半压在字里，随后填上的字把它盖住），白色（白字用黑）。输入框所见即所得也用它
  static func outlineAttributes(_ style: Style) -> [NSAttributedString.Key: Any] {
    [
      .font: font(style.weight), .strokeWidth: 100.0 / 7,
      .strokeColor: style.color == .white ? NSColor.black : NSColor.white,
    ]
  }

  /// 「底色」样式的色块：文字框左右各留 6、上下各留 2，圆角 6（输入框所见即所得也用它）
  static let platePadding = CGSize(width: 6, height: 2)
  static func textPlate(_ frame: CGRect) -> CGRect {
    frame.insetBy(dx: -platePadding.width, dy: -platePadding.height)
  }

  // MARK: 绘制

  /// 阴影模糊半径（点）和它最远能画到的地方（高斯拖尾，留足了才不会在局部重画时留残影）
  private static let shadowBlur: CGFloat = 3
  private static let shadowReach: CGFloat = 8
  private static let shadowColor = NSColor.black.withAlphaComponent(0.28)

  /// 文字输入框用的同一个阴影（所见即所得）
  static var textShadow: NSShadow {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowColor = shadowColor
    return shadow
  }

  /// 画一组标注（视图坐标的上下文；导出时由 render 把上下文变换成视图坐标）。屏幕上的标注层和导出都只调它。
  /// 顺序固定：荧光笔垫底（见 drawBackdrop）→ 马赛克 → 合成一层的聚光灯 → 其余按列表顺序 → 序号永远最上。
  /// dirty：局部重画的范围，只画碰到它的（聚光灯压暗铺满整个压暗范围，有就总会画）。
  /// spotlightBounds：聚光灯压暗的范围。屏幕上传选区（选区外已经有遮罩的暗色蒙层，不再叠一层）；
  /// nil = 整个视图（导出的位图本来就只有选区那么大）。
  /// dimsUnderlaysOnly：屏幕上压暗由标注层下面的图层画（SelectionView，拖选区时只换路径，不重画这一层），这里只给画在
  /// 这一层里、本该压在暗色下面的（荧光笔垫的底、马赛克）补上同样的压暗，合起来和导出一样。
  /// shadowScale：Quartz 的阴影参数不跟 CTM 走——视图 / 图层的上下文按点算（系统设了基础变换），
  /// 自建位图按像素算，所以 render 要传每点几像素，屏幕上传 1
  static func drawAll(
    _ annotations: [Annotation], in context: CGContext, image: CGImage, viewSize: CGSize,
    shadowScale: CGFloat, dirty: CGRect? = nil, spotlightBounds: CGRect? = nil,
    dimsUnderlaysOnly: Bool = false
  ) {
    let shown =
      dirty.map { dirty in annotations.filter { $0.drawBounds.intersects(dirty) } } ?? annotations
    for annotation in shown where annotation.tool == .highlighter {
      annotation.banded(in: context) {
        annotation.drawBackdrop(in: context, image: image, viewSize: viewSize)
      }
    }
    for annotation in shown where annotation.layer == 0 {
      annotation.draw(in: context, image: image, viewSize: viewSize, shadowScale: shadowScale)
    }
    let spotlights = annotations.filter { $0.layer == 1 }
    let dimBounds = spotlightBounds ?? CGRect(origin: .zero, size: viewSize)
    if !dimsUnderlaysOnly {
      drawSpotlights(spotlights, in: context, bounds: dimBounds)
    } else if !spotlights.isEmpty {
      // 垫底的几块合成一个区域再压暗一次（马赛克压着荧光笔时重叠处不压两遍）
      let underlays = shown.compactMap(\.underlayRegion)
      if let first = underlays.first {
        context.saveGState()
        context.addPath(underlays.dropFirst().reduce(first) { $0.union($1) })
        context.clip()
        drawSpotlights(spotlights, in: context, bounds: dimBounds)
        context.restoreGState()
      }
    }
    for layer in 2...3 {
      for annotation in shown where annotation.layer == layer {
        annotation.draw(in: context, image: image, viewSize: viewSize, shadowScale: shadowScale)
      }
    }
  }

  /// 画在标注层里、本该压在聚光灯暗色下面的那块：马赛克的范围、荧光笔垫的底（笔迹）。其余 nil
  private var underlayRegion: CGPath? {
    switch shape {
    case .mosaic(let rect): CGPath(rect: rect, transform: nil)
    case .highlighter(let from, let to):
      Self.segmentPath(from, to).copy(
        strokingWithWidth: style.weight.highlighterHeight, lineCap: .butt, lineJoin: .miter,
        miterLimit: 10)
    default: nil
    }
  }

  private func draw(in context: CGContext, image: CGImage, viewSize: CGSize, shadowScale: CGFloat) {
    // 实心矩形 / 椭圆：先铺 0.28 的底（不带阴影，免得底下透出一片灰；铺满整块，不切条），再描带阴影的边
    if style.option == 1, let path = boxPath {
      context.setFillColor(style.color.color.withAlphaComponent(0.28).cgColor)
      context.addPath(path)
      context.fillPath()
    }
    // 箭头的轮廓只建一次：切条时每条都画一遍，弯的轮廓要沿弧线采样几百个点（长弧切出近百条，拖着就掉帧）
    var arrow: CGPath?
    if case .arrow(let from, let to, let bend) = shape {
      arrow = Self.arrowPath(from: from, to: to, width: style.weight.lineWidth, bend: bend)
    }
    banded(in: context) {
      drawInk(
        in: context, image: image, viewSize: viewSize, shadowScale: shadowScale, arrow: arrow)
    }
  }

  /// 矩形（圆角 3）/ 椭圆的路径；别的工具 nil
  private var boxPath: CGPath? {
    switch shape {
    case .rectangle(let rect):
      CGPath(
        roundedRect: rect, cornerWidth: min(3, rect.width / 2),
        cornerHeight: min(3, rect.height / 2), transform: nil)
    case .ellipse(let rect): CGPath(ellipseIn: rect, transform: nil)
    default: nil
    }
  }

  // MARK: 切条画

  /// 线条外框（连阴影）和裁剪区重叠超过这么大（点²）就切条画。单测改大它，对比切条前后逐像素相同
  static var bandingArea: CGFloat = 250_000

  /// 大的线条沿着骨架切成不重叠的细条、各自裁剪后画：CG 画阴影时按「图形外框 ∩ 裁剪区」开一整块透明层再模糊，
  /// 2000 × 1100 的空心矩形在 5K 屏上一次十几毫秒，拖出、挪动、改大小时跟不上鼠标；细条只模糊线条附近那一圈
  /// （阴影按裁剪区外扩模糊半径取内容，条和条之间接得上，结果逐像素相同）。小的、没有骨架的直接画
  private func banded(in context: CGContext, _ body: () -> Void) {
    let clip = context.boundingBoxOfClipPath
    let overlap = drawBounds.intersection(clip)
    guard let (lines, reach) = skeleton, !overlap.isNull,
      overlap.width * overlap.height > Self.bandingArea
    else { return body() }
    for band in Self.bands(along: lines, reach: reach, in: clip) {
      context.saveGState()
      context.clip(to: band)
      body()
      context.restoreGState()
    }
  }

  /// 线条的骨架（折线）和画出来的东西（连阴影）离骨架最远多少；文字、序号（小）、马赛克、聚光灯（整块都要画）、画笔没有
  private var skeleton: (lines: [[CGPoint]], reach: CGFloat)? {
    let width = style.weight.lineWidth
    let reach = width / 2 + Self.shadowReach
    switch shape {
    case .rectangle(let rect):
      let corners = [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
      ]
      return ([corners + [corners[0]]], reach)
    case .ellipse(let rect):
      // 64 边形：弦离弧最多 长半轴 × (1 − cos(π / 64))
      let sides = 64
      let points = (0...sides).map { index -> CGPoint in
        let angle = CGFloat(index) / CGFloat(sides) * 2 * .pi
        return CGPoint(
          x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
      }
      let sag = max(rect.width, rect.height) / 2 * (1 - cos(.pi / CGFloat(sides)))
      return ([points], reach + sag)
    case .arrow(let from, let to, let bend), .line(let from, let to, let bend):
      // 弯的：沿弧线的折线，再放宽折线离弧线最远的那点（直的是 0）；箭头按箭头的半宽放
      let line = Self.curvePoints(from, to, bend)
      let control = Self.curveControl(from: from, to: to, bend: bend)
      let sag =
        bend == .zero
        ? 0
        : hypot(from.x - 2 * control.x + to.x, from.y - 2 * control.y + to.y)
          / (4 * CGFloat((line.count - 1) * (line.count - 1)))
      let half =
        tool == .arrow
        ? max(Self.arrowWing(from: from, to: to, width: width, bend: bend), width) : width / 2
      return ([line], half + Self.shadowReach + sag)
    case .highlighter(let from, let to):
      return ([[from, to]], style.weight.highlighterHeight / 2 + 1)
    // ponytail: 画笔不切条（笔迹来回拐，一大条要切几百条，每条都要挑一遍附近的线段，反而更慢）；很长的笔迹整条挪动时
    // 还是按外框模糊，要快就给线段按横条分桶再切
    case .pen, .text, .counter, .mosaic, .spotlight: return nil
    }
  }

  /// 把 area 里骨架 ± reach 碰到的地方切成不重叠的整点矩形：横条高 16，每条里只留骨架碰到的 x 区间（重叠的合并）。
  /// 边界是整点：屏幕、导出的缩放都是整数倍，条和条的接缝落在整像素上，不会重复画半个像素
  private static func bands(along lines: [[CGPoint]], reach: CGFloat, in area: CGRect) -> [CGRect] {
    let height: CGFloat = 16
    var rows: [Int: [(low: CGFloat, high: CGFloat)]] = [:]
    for line in lines {
      let segments = line.count == 1 ? [(line[0], line[0])] : Array(zip(line, line.dropFirst()))
      for (a, b) in segments {
        let first = Int(((min(a.y, b.y) - reach) / height).rounded(.down))
        let last = Int(((max(a.y, b.y) + reach) / height).rounded(.down))
        for row in first...last {
          // 这一段落在「本条 ± reach」高度里的那截，左右再各放 reach
          let bottom = CGFloat(row) * height - reach
          let top = CGFloat(row + 1) * height + reach
          var low = min(a.x, b.x)
          var high = max(a.x, b.x)
          if a.y != b.y {
            let t0 = (bottom - a.y) / (b.y - a.y)
            let t1 = (top - a.y) / (b.y - a.y)
            let from = max(0, min(t0, t1))
            let to = min(1, max(t0, t1))
            guard from <= to else { continue }
            low = min(a.x + (b.x - a.x) * from, a.x + (b.x - a.x) * to)
            high = max(a.x + (b.x - a.x) * from, a.x + (b.x - a.x) * to)
          }
          rows[row, default: []].append(
            ((low - reach).rounded(.down), (high + reach).rounded(.up)))
        }
      }
    }
    var bands: [CGRect] = []
    for (row, spans) in rows {
      let y = CGFloat(row) * height
      guard y < area.maxY, y + height > area.minY else { continue }
      var merged: [(low: CGFloat, high: CGFloat)] = []
      for span in spans.sorted(by: { $0.low < $1.low }) {
        if let last = merged.last, span.low <= last.high {
          merged[merged.count - 1].high = max(last.high, span.high)
        } else {
          merged.append(span)
        }
      }
      for span in merged {
        let band = CGRect(x: span.low, y: y, width: span.high - span.low, height: height)
        if band.intersects(area) { bands.append(band) }
      }
    }
    return bands
  }

  /// 折线最长的一段
  private static func longestSegment(_ points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
  }

  /// 一个标注本身的线条（实心的底色在 draw 里先铺好了）：切条时每条各画一遍；arrow 是 draw 建好的箭头轮廓
  private func drawInk(
    in context: CGContext, image: CGImage, viewSize: CGSize, shadowScale: CGFloat, arrow: CGPath?
  ) {
    let color = style.color.color
    let width = style.weight.lineWidth
    context.saveGState()
    defer { context.restoreGState() }
    let shadow = {
      context.setShadow(
        offset: .zero, blur: Self.shadowBlur * shadowScale, color: Self.shadowColor.cgColor)
    }
    let noShadow = { context.setShadow(offset: .zero, blur: 0, color: nil) }
    switch shape {
    case .rectangle, .ellipse:
      guard let path = boxPath else { return }
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.addPath(path)
      context.strokePath()
    case .arrow:
      guard let path = arrow else { return }
      shadow()
      context.setFillColor(color.cgColor)
      context.addPath(path)
      context.fillPath()
    case .line(let from, let to, let bend):
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      if bend == .zero {
        context.strokeLineSegments(between: [from, to])  // 直的照旧（一个像素都不变）
      } else {
        context.move(to: from)
        context.addQuadCurve(to: to, control: Self.curveControl(from: from, to: to, bend: bend))
        context.strokePath()
      }
    case .pen(let points):
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.addPath(
        Self.penPath(
          points, near: context.boundingBoxOfClipPath, reach: width / 2 + Self.shadowReach))
      context.strokePath()
    case .highlighter(let from, let to):
      // 半透明 + 正片叠底：底下的字不被盖浅；没有阴影
      context.setBlendMode(.multiply)
      context.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
      context.setLineWidth(style.weight.highlighterHeight)
      context.setLineCap(.butt)
      context.strokeLineSegments(between: [from, to])
    case .text(let string, let origin):
      let frame = Self.textFrame(string, origin: origin, weight: style.weight)
      let font = Self.font(style.weight)
      var ink = color
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      shadow()
      switch style.option {
      case 1:
        // 描边：先画带阴影的外描边（字宽 1/7，一半压在字里），再不带阴影地把字填上去
        context.setLineJoin(.round)
        NSAttributedString(string: string, attributes: Self.outlineAttributes(style))
          .draw(in: frame)
        noShadow()
      case 2:
        // 底色：带阴影的圆角色块 + 白字（黄 / 白底黑字）
        let plate = Self.textPlate(frame)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        noShadow()
        ink = style.color.ink
      default:
        break
      }
      NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink])
        .draw(in: frame)
    case .counter(let number, let center):
      let diameter = style.weight.counterDiameter
      let circle = CGRect(
        x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
      shadow()
      context.setFillColor(color.cgColor)
      context.fillEllipse(in: circle)
      noShadow()
      context.setStrokeColor(NSColor.white.cgColor)
      context.setLineWidth(1.5)
      context.strokeEllipse(in: circle)
      Self.drawNumber(
        number, centeredAt: center, diameter: diameter, color: style.color.ink, in: context)
    case .mosaic(let rect):
      drawMosaic(rect, in: context, image: image, viewSize: viewSize)
    case .spotlight:
      break  // 合成一层画，见 drawSpotlights
    }
  }

  /// 画笔：相邻点的中点之间用二次曲线连（控制点是原来的点），笔迹不起棱角
  static func penPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first, let last = points.last else { return path }
    path.move(to: first)
    for (point, next) in zip(points.dropFirst(), points.dropFirst(2)) {
      path.addQuadCurve(
        to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
    }
    path.addLine(to: last)  // 只有一个点时是零长度线段，圆头画成一个点
    return path
  }

  /// 画笔只画 rect 附近的那几截（局部重画时整条笔迹上千个点，每次都描整条、再裁掉，越画越慢）：离 rect 不到
  /// reach 的线段连同前后各两段连成一截，各截照 penPath 画。截头截尾和整条笔迹不一样的只有最外面两段附近，离 rect 都远于
  /// reach，裁剪区里逐像素相同。二次曲线离折线最多半段长，远近按线段外框再放宽最长一段的一半
  static func penPath(_ points: [CGPoint], near rect: CGRect, reach: CGFloat) -> CGPath {
    guard points.count > 2 else { return penPath(points) }
    let pad = reach + longestSegment(points) / 2
    let (left, right) = (rect.minX - pad, rect.maxX + pad)
    let (bottom, top) = (rect.minY - pad, rect.maxY + pad)
    var ranges: [ClosedRange<Int>] = []
    for index in 0..<(points.count - 1) {
      let a = points[index]
      let b = points[index + 1]
      guard max(a.x, b.x) >= left, min(a.x, b.x) <= right, max(a.y, b.y) >= bottom,
        min(a.y, b.y) <= top
      else { continue }
      let range = max(0, index - 2)...min(points.count - 1, index + 3)
      if let last = ranges.last, range.lowerBound <= last.upperBound {
        ranges[ranges.count - 1] = last.lowerBound...range.upperBound
      } else {
        ranges.append(range)
      }
    }
    if ranges == [0...(points.count - 1)] { return penPath(points) }
    let path = CGMutablePath()
    for range in ranges { path.addPath(penPath(Array(points[range]))) }
    return path
  }

  /// 序号数字：SF Pro Rounded bold，按字形本身的外框居中（数字没有下伸部，按行框居中会偏上）；
  /// 两位以上缩到圆的 0.78 宽以内
  private static func drawNumber(
    _ number: Int, centeredAt center: CGPoint, diameter: CGFloat, color: NSColor,
    in context: CGContext
  ) {
    func line(_ size: CGFloat) -> CTLine {
      CTLineCreateWithAttributedString(
        NSAttributedString(
          string: String(number),
          attributes: [
            .font: rounded(size: size, weight: .bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
          ]))
    }
    var size = diameter * 0.575
    var text = line(size)
    let width = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds).width
    if width > diameter * 0.78 {
      size *= diameter * 0.78 / width
      text = line(size)
    }
    let glyphs = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: center.x - glyphs.midX, y: center.y - glyphs.midY)
    CTLineDraw(text, context)
  }

  /// 聚光灯合成一层的压暗（偶奇填充）：压暗范围 + 所有聚光灯的圆角 8 洞（先合并，重叠的洞按偶奇规则不会又被压暗；
  /// 再裁进范围，伸出范围的那截按偶奇规则会反过来压暗范围外），压暗程度取最后一个聚光灯的档。没有聚光灯是 nil。
  /// 导出、屏幕上垫底的（drawSpotlights）和屏幕上标注层下面的压暗图层（SelectionView）共用
  static func spotlightDim(_ spotlights: [Annotation], bounds: CGRect) -> (
    path: CGPath, alpha: CGFloat
  )? {
    let holes = spotlights.compactMap { annotation -> CGPath? in
      guard case .spotlight(let rect) = annotation.shape else { return nil }
      let radius = min(8, rect.width / 2, rect.height / 2)
      return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    guard let first = holes.first, let last = spotlights.last, !bounds.isEmpty else { return nil }
    let path = CGMutablePath()
    path.addRect(bounds)
    path.addPath(
      holes.dropFirst().reduce(first) { $0.union($1) }.intersection(
        CGPath(rect: bounds, transform: nil)))
    return (path, last.style.weight.spotlightDim)
  }

  private static func drawSpotlights(
    _ spotlights: [Annotation], in context: CGContext, bounds: CGRect
  ) {
    guard let (path, alpha) = spotlightDim(spotlights, bounds: bounds) else { return }
    context.saveGState()
    context.setFillColor(CGColor(gray: 0, alpha: alpha))
    context.addPath(path)
    context.fillPath(using: .evenOdd)
    context.restoreGState()
  }

  /// 一条线段的路径
  private static func segmentPath(_ from: CGPoint, _ to: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [from, to])
    return path
  }

  /// 荧光笔垫底：在笔迹范围里先铺一遍冻结帧，正片叠底才有东西可叠——屏幕上的标注层是透明的（冻结帧在下面的图层里），
  /// 不垫的话叠在透明上等于普通半透明，和导出不一样；导出时这一步画的就是底图本身，看不出来。
  /// 在马赛克、聚光灯之前画，不会把它们盖掉
  private func drawBackdrop(in context: CGContext, image: CGImage, viewSize: CGSize) {
    guard case .highlighter(let from, let to) = shape,
      case (let crop, let frame)? = Self.frozen(bounds, image: image, viewSize: viewSize)
    else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setLineWidth(style.weight.highlighterHeight)
    context.setLineCap(.butt)
    context.addLines(between: [from, to])
    context.replacePathWithStrokedPath()
    context.clip()
    context.draw(crop, in: frame)
  }

  /// 马赛克：冻结帧这一块缩小到每格一个像素，再放大回去。像素 = 不插值放大；
  /// 模糊（option 1）= 格子放大到 1.5 倍、再平滑插值放大（信息已经在缩小时丢掉，不像高斯模糊还能反卷积还原）
  private func drawMosaic(_ rect: CGRect, in context: CGContext, image: CGImage, viewSize: CGSize) {
    let blurred = style.option == 1
    guard let (blocks, frame) = mosaicBlocks(rect, image: image, viewSize: viewSize) else { return }
    context.clip(to: rect)
    context.interpolationQuality = blurred ? .high : .none
    context.draw(blocks, in: frame)
  }

  /// 最近画过的马赛克缩小图（按 id、范围、粗细、像素 / 模糊认；id 不会重复，换了冻结帧也认不错）：在它上面画箭头、
  /// 写字时局部重画不用每次都从冻结帧重新裁一大块、重新缩小（2000 × 1100 的一次 5–7 ms）。
  /// ponytail: 只留 8 张；拖着马赛克本身改范围时每下还是要重算，要更快就拖动中用图层预览
  private static var mosaicCache: [(key: MosaicKey, blocks: CGImage, frame: CGRect)] = []

  private struct MosaicKey: Equatable {
    let id: UUID
    let rect: CGRect
    let weight: Weight
    let option: Int
  }

  /// 冻结帧里这块缩小到每格一个像素的图，和它放回去的位置（视图坐标）
  private func mosaicBlocks(_ rect: CGRect, image: CGImage, viewSize: CGSize) -> (
    CGImage, CGRect
  )? {
    let key = MosaicKey(id: id, rect: rect, weight: style.weight, option: style.option)
    if let hit = Self.mosaicCache.first(where: { $0.key == key }) { return (hit.blocks, hit.frame) }
    guard case (let crop, let frame)? = Self.frozen(rect, image: image, viewSize: viewSize) else {
      return nil
    }
    let blurred = style.option == 1
    let cell =
      style.weight.mosaicBlock * (blurred ? 1.5 : 1) * CGFloat(image.width) / viewSize.width
    let columns = max(1, Int((CGFloat(crop.width) / cell).rounded(.up)))
    let rows = max(1, Int((CGFloat(crop.height) / cell).rounded(.up)))
    guard
      let small = CGContext(
        data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
        space: crop.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    small.interpolationQuality = blurred ? .high : .medium
    small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
    guard let blocks = small.makeImage() else { return nil }
    Self.mosaicCache.append((key, blocks, frame))
    if Self.mosaicCache.count > 8 { Self.mosaicCache.removeFirst() }
    return (blocks, frame)
  }

  /// 冻结帧里 rect（视图坐标）那块像素，和这块像素换回视图坐标的位置（取整后可能比 rect 大一点，调用方自己 clip）
  private static func frozen(_ rect: CGRect, image: CGImage, viewSize: CGSize) -> (
    CGImage, CGRect
  )? {
    let imageSize = CGSize(width: image.width, height: image.height)
    let pixels = RegionSelector.pixelRect(rect, viewSize: viewSize, imageSize: imageSize)
    guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels) else {
      return nil
    }
    let scaleX = imageSize.width / viewSize.width
    let scaleY = imageSize.height / viewSize.height
    return (
      crop,
      CGRect(
        x: pixels.minX / scaleX, y: (imageSize.height - pixels.maxY) / scaleY,
        width: pixels.width / scaleX, height: pixels.height / scaleY)
    )
  }

  /// 选区的最终图：冻结帧裁出 pixelRect，再用同一个 drawAll 画上标注。导出、钉图、识字都用它；
  /// 画进新的位图，不再引用整屏冻结帧（cropping 的结果会拖住整帧几十 MB）。纯函数，配单测
  static func render(
    _ annotations: [Annotation], over image: CGImage, pixelRect: CGRect, viewSize: CGSize
  ) -> CGImage? {
    guard pixelRect.width >= 1, pixelRect.height >= 1, let crop = image.cropping(to: pixelRect),
      let context = CGContext(
        data: nil, width: Int(pixelRect.width), height: Int(pixelRect.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height))
    // 视图坐标 → 这张图：先按像素 / 点缩放，再把像素矩形的左下角挪到原点（图的行从上往下，上下文原点在左下）
    let scaleX = CGFloat(image.width) / viewSize.width
    let scaleY = CGFloat(image.height) / viewSize.height
    context.scaleBy(x: scaleX, y: scaleY)
    context.translateBy(
      x: -pixelRect.minX / scaleX, y: -(CGFloat(image.height) - pixelRect.maxY) / scaleY)
    drawAll(annotations, in: context, image: image, viewSize: viewSize, shadowScale: scaleX)
    return context.makeImage()
  }

  /// 锥形实心箭头：一个填充多边形，杆从尾部 0.3 × 线宽渐粗到箭头处 1.2 × 线宽；箭头长 4 × 线宽、半角 28°
  /// （比这还短的箭头只剩箭头）。弯的见 curvedArrowPath（直的还是这个多边形，一个像素都不变）。零长度返回 nil
  static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat, bend: CGVector = .zero)
    -> CGPath?
  {
    if bend != .zero { return curvedArrowPath(from: from, to: to, width: width, bend: bend) }
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 0 else { return nil }
    let head = min(length, width * 4)
    let wing = arrowWing(from: from, to: to, width: width)
    let unit = CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
    let base = CGPoint(x: to.x - unit.x * head, y: to.y - unit.y * head)
    /// 沿法向偏出 side 点（正数在箭头方向的左边）
    func beside(_ point: CGPoint, _ side: CGFloat) -> CGPoint {
      CGPoint(x: point.x - unit.y * side, y: point.y + unit.x * side)
    }
    let tail = width * 0.15
    let neck = min(width * 0.6, wing)
    let path = CGMutablePath()
    path.addLines(between: [
      beside(from, tail), beside(base, neck), beside(base, wing), to, beside(base, -wing),
      beside(base, -neck), beside(from, -tail),
    ])
    path.closeSubpath()
    return path
  }

  /// 箭头底边的半宽：头长 × tan 28°（弯的头长按 4 × 线宽算，外框、切条宁大勿小）
  private static func arrowWing(
    from: CGPoint, to: CGPoint, width: CGFloat, bend: CGVector = .zero
  ) -> CGFloat {
    let head = bend == .zero ? min(hypot(to.x - from.x, to.y - from.y), width * 4) : width * 4
    return head * tan(28 * .pi / 180)
  }

  // MARK: 弯曲（箭头、直线）

  /// 弧线中点（弯曲手柄）：弦中点 + bend.dx · d + bend.dy · d⊥（d = to − from，d⊥ 是它逆时针转 90°，即弦的左侧）
  static func curveMidpoint(from: CGPoint, to: CGPoint, bend: CGVector) -> CGPoint {
    let d = CGVector(dx: to.x - from.x, dy: to.y - from.y)
    return CGPoint(
      x: (from.x + to.x) / 2 + bend.dx * d.dx - bend.dy * d.dy,
      y: (from.y + to.y) / 2 + bend.dx * d.dy + bend.dy * d.dx)
  }

  /// 二次贝塞尔的控制点：t = 0.5 处是 ¼ 起点 + ½ 控制点 + ¼ 终点，要它落在弧线中点上，控制点 = 2 · 中点 − 弦中点
  static func curveControl(from: CGPoint, to: CGPoint, bend: CGVector) -> CGPoint {
    let mid = curveMidpoint(from: from, to: to, bend: bend)
    return CGPoint(x: 2 * mid.x - (from.x + to.x) / 2, y: 2 * mid.y - (from.y + to.y) / 2)
  }

  /// 离弦（所在的直线）不到这么远就拉直：弯曲手柄拖回弦上时吸回直的
  static let straightSnap: CGFloat = 4

  /// 弯曲手柄拖到 point 时的弯度（弧线中点就在 point 上）：离弦不到 straightSnap 拉直；constrained（⇧）只留垂直弦的那份，
  /// 弯成左右对称的弧。沿弦的那份夹在 ±maxAlong（手柄拖过两端也停在弦的 ¼ / ¾ 处）。弦长为 0 时是直的
  static func curveBend(from: CGPoint, to: CGPoint, through point: CGPoint, constrained: Bool)
    -> CGVector
  {
    let d = CGVector(dx: to.x - from.x, dy: to.y - from.y)
    let lengthSquared = d.dx * d.dx + d.dy * d.dy
    let v = CGVector(dx: point.x - (from.x + to.x) / 2, dy: point.y - (from.y + to.y) / 2)
    let side = v.dy * d.dx - v.dx * d.dy  // v · d⊥ = 离弦的距离 × 弦长
    guard lengthSquared > 0, abs(side) >= straightSnap * lengthSquared.squareRoot() else {
      return .zero
    }
    let along = constrained ? 0 : (v.dx * d.dx + v.dy * d.dy) / lengthSquared
    return CGVector(dx: min(max(along, -maxAlong), maxAlong), dy: side / lengthSquared)
  }

  /// 弧线中点沿弦最多偏离弦中点多少（弦长为单位）：¼ 时控制点（2 · 中点 − 弦中点）正好落在一端的垂线上，弧线在弦上的
  /// 投影从头到尾单调，不会拐过端点再折回来（拖过尖端时线会叠成两层、箭头朝反方向）
  static let maxAlong: CGFloat = 0.25

  /// 箭头、直线的骨架折线：直的是两端，弯的是弧线上的采样点（curve）
  private static func curvePoints(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector) -> [CGPoint] {
    bend == .zero ? [from, to] : curve(from, curveControl(from: from, to: to, bend: bend), to)
  }

  /// 弧线的外框：两端 + 每个轴上的极值点（导数为 0 的 t）。直的就是两端围成的框
  private static func curveBox(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector) -> CGRect {
    guard bend != .zero else { return box(from, to) }
    let control = curveControl(from: from, to: to, bend: bend)
    /// 这一轴上 (1−t)²a + 2t(1−t)b + t²c 的极值点
    func extremum(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> CGFloat? {
      let denominator = a - 2 * b + c
      guard denominator != 0 else { return nil }
      let t = (a - b) / denominator
      return t > 0 && t < 1 ? t : nil
    }
    let turns = [extremum(from.x, control.x, to.x), extremum(from.y, control.y, to.y)]
      .compactMap { $0 }.map { quad(from, control, to, $0) }
    return turns.reduce(box(from, to)) { $0.union(CGRect(origin: $1, size: .zero)) }
  }

  /// 二次贝塞尔上 t 处的点
  private static func quad(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint, _ t: CGFloat)
    -> CGPoint
  {
    let u = 1 - t
    return CGPoint(
      x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
      y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
  }

  /// 二次贝塞尔上按 t 均分的点（含两端）：按控制折线长每 3 点一段、16–400 段（在 2x 屏上看不出折角）
  private static func curve(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint) -> [CGPoint] {
    let length =
      hypot(control.x - start.x, control.y - start.y) + hypot(end.x - control.x, end.y - control.y)
    let segments = min(400, max(16, Int(length / 3)))
    return (0...segments).map { quad(start, control, end, CGFloat($0) / CGFloat(segments)) }
  }

  /// 弯箭头：同直箭头的锥形实心多边形，沿二次贝塞尔（curveControl）弯过去。尖端是弧线的终点，箭头底边的中点落在弧线上
  /// 离尖端一个头长（4 × 线宽）处，箭头盖住弧线最后一截；杆是弧线到底边中点的那一段（de Casteljau 截出来，和弧线重合，
  /// 弯曲手柄就在杆上），沿弧长从尾部半宽 0.15 × 线宽渐粗到颈 0.6 × 线宽，按每个采样点的法向往两侧偏出；半角、颈宽同直箭头。
  /// 底边垂直于杆在颈部的走向，不垂直于底边中点到尖端的弦：弧线贴着尖端拐得急（沿弦拖到 ¼ / ¾ 附近、离弦不远时尖端带个钩）
  /// 时弦和杆差出二三十度，按弦摆的箭头会在颈部折一下；按杆摆，杆顺着接进箭头，箭头成略歪的三角、尖端还在终点上。
  /// 偏角最多 30°，再歪就成一根刺（只有头比杆还长的短箭头会碰到，剩下的那点折角盖在箭头里）。
  /// 整条弧都离尖端不到一个头长（弯过的箭头被拖短）时头缩到最远那点，同直箭头「比头还短只剩箭头」：弯的总画得出来，
  /// 和外框、点中、弯曲手柄（都按弧线算）对得上。零长度 nil。
  /// ponytail: 按法向偏移的轮廓在弧线半径小于杆的半宽（最粗 3.6 点）处内侧自交，那一小块可能描不满。沿弦夹在 maxAlong
  /// 以内后弧线不会拐过端点折回来，剩下只有弦很短、弯得很深的 U 形顶点会这么尖（顶点半径 = 弦² / (8 × 深度)，
  /// 弦 32、深 40 才 3.2 点）；真碰到再改成逐段取并集
  private static func curvedArrowPath(
    from: CGPoint, to: CGPoint, width: CGFloat, bend: CGVector
  ) -> CGPath? {
    let control = curveControl(from: from, to: to, bend: bend)
    let samples = curve(from, control, to)
    let head = min(width * 4, samples.map { hypot(to.x - $0.x, to.y - $0.y) }.max() ?? 0)
    let far = { (point: CGPoint) in hypot(to.x - point.x, to.y - point.y) >= head }
    guard head > 0, let index = samples.lastIndex(where: far) else { return nil }
    // 最后一个够远的采样点和下一个（不够远：最后一个采样点就是尖端）之间二分出底边中点
    let step = 1 / CGFloat(samples.count - 1)
    var (low, high) = (CGFloat(index) * step, CGFloat(index + 1) * step)
    for _ in 0..<24 {
      let middle = (low + high) / 2
      if far(quad(from, control, to, middle)) { low = middle } else { high = middle }
    }
    let base = quad(from, control, to, low)
    let length = hypot(to.x - base.x, to.y - base.y)
    guard length > 0 else { return nil }
    let axis = CGVector(dx: (to.x - base.x) / length, dy: (to.y - base.y) / length)
    // 杆：[0, low] 那段弧的控制点是 from → control 的 low 处；它在颈部的走向是 base − bodyControl
    let bodyControl = CGPoint(
      x: from.x + (control.x - from.x) * low, y: from.y + (control.y - from.y) * low)
    let end = CGVector(dx: base.x - bodyControl.x, dy: base.y - bodyControl.y)
    let skew = min(
      max(
        atan2(axis.dx * end.dy - axis.dy * end.dx, axis.dx * end.dx + axis.dy * end.dy), -.pi / 6),
      .pi / 6)
    let across = CGVector(
      dx: axis.dx * cos(skew) - axis.dy * sin(skew), dy: axis.dx * sin(skew) + axis.dy * cos(skew))
    /// 沿法向偏出 side 点（正数在前进方向的左边）
    func beside(_ point: CGPoint, _ direction: CGVector, _ side: CGFloat) -> CGPoint {
      CGPoint(x: point.x - direction.dy * side, y: point.y + direction.dx * side)
    }
    let body = curve(from, bodyControl, base)
    var run: [CGFloat] = [0]
    for (a, b) in zip(body, body.dropFirst()) {
      run.append(run.last! + hypot(b.x - a.x, b.y - a.y))
    }
    let total = max(run.last ?? 0, .ulpOfOne)
    let wing = head * tan(28 * .pi / 180)
    let tail = width * 0.15
    let neck = min(width * 0.6, wing)
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    for (index, point) in body.enumerated().dropLast() {
      // 切线：B'(s) ∝ (1 − s)(c − a) + s(b − c)；退化成 0 时用底边的朝向
      let s = CGFloat(index) / CGFloat(body.count - 1)
      let tangent = CGVector(
        dx: (1 - s) * (bodyControl.x - from.x) + s * (base.x - bodyControl.x),
        dy: (1 - s) * (bodyControl.y - from.y) + s * (base.y - bodyControl.y))
      let size = hypot(tangent.dx, tangent.dy)
      let direction =
        size > 0 ? CGVector(dx: tangent.dx / size, dy: tangent.dy / size) : across
      let half = tail + (neck - tail) * run[index] / total
      left.append(beside(point, direction, half))
      right.append(beside(point, direction, -half))
    }
    let path = CGMutablePath()
    path.addLines(
      between: left + [
        beside(base, across, neck), beside(base, across, wing), to, beside(base, across, -wing),
        beside(base, across, -neck),
      ] + right.reversed())
    path.closeSubpath()
    return path
  }

  private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
  }
}
