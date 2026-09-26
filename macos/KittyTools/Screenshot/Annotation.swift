// 截图标注（值类型）：矩形、椭圆、箭头、直线、画笔、荧光笔、文字、序号、马赛克、聚光灯（mac-whisker §6「工具」）。
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
      case .text: "textformat"
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
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
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
      case .pink: KittyTools.Style.Shot.accent  // 品牌粉（这里的 Style 是标注样式，要带模块名）
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

  /// 选中标注的调整手柄：矩形类四角，线类两端
  enum Handle { case start, end, topLeft, topRight, bottomLeft, bottomRight }

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
    case .arrow(let from, let to):
      let pad = max(Self.arrowWing(from: from, to: to, width: width), width)
      return Self.box(from, to).insetBy(dx: -pad, dy: -pad)
    case .line(let from, let to):
      return Self.box(from, to).insetBy(dx: -width / 2, dy: -width / 2)
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
  /// 只随压暗的档（见 dimLevel）和压暗范围（见 dimChange）变，挪洞、改洞只重画洞
  var drawBounds: CGRect {
    switch tool {
    case .mosaic, .highlighter, .spotlight: bounds
    default: bounds.insetBy(dx: -Self.shadowReach, dy: -Self.shadowReach)
    }
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
    case .arrow(let from, let to):
      return Self.distance(from: point, toSegment: from, to) <= width / 2 + tolerance
        || Self.arrowPath(from: from, to: to, width: width)?.contains(point) == true
    case .line(let from, let to):
      return Self.distance(from: point, toSegment: from, to) <= width / 2 + tolerance
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
    case .arrow(let from, let to), .line(let from, let to), .highlighter(let from, let to):
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
    case .arrow(let from, let to), .line(let from, let to), .highlighter(let from, let to):
      moved.shape = Self.segment(tool, from: shift(from), to: shift(to))
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

  /// 选中时的调整手柄：矩形类四角，线类两端；文字、序号、画笔只能拖动（空）
  var handles: [(Handle, CGPoint)] {
    switch shape {
    case .rectangle(let rect), .ellipse(let rect), .mosaic(let rect), .spotlight(let rect):
      [
        (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
        (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
      ]
    case .arrow(let from, let to), .line(let from, let to), .highlighter(let from, let to):
      [(.start, from), (.end, to)]
    case .pen, .text, .counter: []
    }
  }

  /// 拖手柄改大小：矩形类对角不动（拖过头会翻过去）、⇧ 正方形；线类另一端不动、⇧ 吸 45°。不认的手柄原样返回
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
      case .start, .end: return self
      }
      next.shape = Self.shape(for: tool, from: fixed, to: point, constrained: constrained) ?? shape
    case (.arrow(_, let to), .start), (.line(_, let to), .start), (.highlighter(_, let to), .start):
      next.shape = Self.segment(tool, from: constrained ? Self.snapped(to, point) : point, to: to)
    case (.arrow(let from, _), .end), (.line(let from, _), .end), (.highlighter(let from, _), .end):
      next.shape = Self.segment(
        tool, from: from, to: constrained ? Self.snapped(from, point) : point)
    default:
      return self
    }
    return next
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

  /// 线类工具的形状（别的工具不会走到这里）
  private static func segment(_ tool: Tool, from: CGPoint, to: CGPoint) -> Shape {
    switch tool {
    case .line: .line(from: from, to: to)
    case .highlighter: .highlighter(from: from, to: to)
    default: .arrow(from: from, to: to)
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
  /// shadowScale：Quartz 的阴影参数不跟 CTM 走——视图 / 图层的上下文按点算（系统设了基础变换），
  /// 自建位图按像素算，所以 render 要传每点几像素，屏幕上传 1
  static func drawAll(
    _ annotations: [Annotation], in context: CGContext, image: CGImage, viewSize: CGSize,
    shadowScale: CGFloat, dirty: CGRect? = nil, spotlightBounds: CGRect? = nil
  ) {
    let shown =
      dirty.map { dirty in annotations.filter { $0.drawBounds.intersects(dirty) } } ?? annotations
    for annotation in shown where annotation.tool == .highlighter {
      annotation.drawBackdrop(in: context, image: image, viewSize: viewSize)
    }
    for annotation in shown where annotation.layer == 0 {
      annotation.draw(in: context, image: image, viewSize: viewSize, shadowScale: shadowScale)
    }
    drawSpotlights(
      annotations.filter { $0.layer == 1 }, in: context,
      bounds: spotlightBounds ?? CGRect(origin: .zero, size: viewSize))
    for layer in 2...3 {
      for annotation in shown where annotation.layer == layer {
        annotation.draw(in: context, image: image, viewSize: viewSize, shadowScale: shadowScale)
      }
    }
  }

  private func draw(in context: CGContext, image: CGImage, viewSize: CGSize, shadowScale: CGFloat) {
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
    case .rectangle(let rect), .ellipse(let rect):
      let path =
        tool == .ellipse
        ? CGPath(ellipseIn: rect, transform: nil)
        : CGPath(
          roundedRect: rect, cornerWidth: min(3, rect.width / 2),
          cornerHeight: min(3, rect.height / 2),
          transform: nil)
      // 实心：先铺 0.28 的底（不带阴影，免得底下透出一片灰），再描带阴影的边
      if style.option == 1 {
        context.setFillColor(color.withAlphaComponent(0.28).cgColor)
        context.addPath(path)
        context.fillPath()
      }
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.addPath(path)
      context.strokePath()
    case .arrow(let from, let to):
      guard let path = Self.arrowPath(from: from, to: to, width: width) else { return }
      shadow()
      context.setFillColor(color.cgColor)
      context.addPath(path)
      context.fillPath()
    case .line(let from, let to):
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      context.strokeLineSegments(between: [from, to])
    case .pen(let points):
      shadow()
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(width)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.addPath(Self.penPath(points))
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
        NSAttributedString(
          string: string,
          attributes: [
            .font: font, .strokeWidth: 100.0 / 7,
            .strokeColor: style.color == .white ? NSColor.black : .white,
          ]
        ).draw(in: frame)
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

  /// 聚光灯合成一层：压暗范围 + 所有聚光灯的圆角 8 洞（先合并，重叠的洞按偶奇规则不会又被压暗），
  /// 压暗程度取最后一个聚光灯的档。先裁到压暗范围：洞伸出范围的那截按偶奇规则会反过来压暗范围外
  private static func drawSpotlights(
    _ spotlights: [Annotation], in context: CGContext, bounds: CGRect
  ) {
    let holes = spotlights.compactMap { annotation -> CGPath? in
      guard case .spotlight(let rect) = annotation.shape else { return nil }
      let radius = min(8, rect.width / 2, rect.height / 2)
      return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    guard let first = holes.first, let last = spotlights.last else { return }
    let path = CGMutablePath()
    path.addRect(bounds)
    path.addPath(holes.dropFirst().reduce(first) { $0.union($1) })
    context.saveGState()
    context.clip(to: bounds)
    context.setFillColor(CGColor(gray: 0, alpha: last.style.weight.spotlightDim))
    context.addPath(path)
    context.fillPath(using: .evenOdd)
    context.restoreGState()
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
    guard case (let crop, let frame)? = Self.frozen(rect, image: image, viewSize: viewSize) else {
      return
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
    else { return }
    small.interpolationQuality = blurred ? .high : .medium
    small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
    guard let blocks = small.makeImage() else { return }
    context.clip(to: rect)
    context.interpolationQuality = blurred ? .high : .none
    context.draw(blocks, in: frame)
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
  /// （比这还短的箭头只剩箭头）。零长度返回 nil
  static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath? {
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

  /// 箭头底边的半宽：头长 × tan 28°
  private static func arrowWing(from: CGPoint, to: CGPoint, width: CGFloat) -> CGFloat {
    min(hypot(to.x - from.x, to.y - from.y), width * 4) * tan(28 * .pi / 180)
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
