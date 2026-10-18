// 便签任务的方框（2026-10-18，用户选的「A · 圆角方框」，长相在 mac-whisker-notes.mdc「任务」）：正文里存的还是行首那五个字
// （☐ ◧ ▣ ☑ ☒），排版照旧占那个字的前进宽，**字形不画**——布局管理器（NoteLayoutManager.drawGlyphs）画到方框那个字时
// 不交给系统，改调这里画一个圆角方框：待办只有描边、进行中左半边填实、紧急红底感叹号、完成色条色底对勾、取消变淡加一道横线。
// 纯 CoreGraphics / NSBezierPath、nonisolated：布局管理器画的时候调，只读传进来的值（颜色是动态色，画的那一刻按当前外观取）。

import AppKit

nonisolated enum NoteTaskBox {
  // MARK: 数值（15 pt 正文时边长约 13 pt、描边约 1.4 pt）

  /// 边长 = 正文字号 × 这么多
  static let sideRatio: CGFloat = 0.88
  /// 圆角半径 = 边长 × 这么多
  static let cornerRatio: CGFloat = 0.24
  /// 描边宽 = 字号 ÷ 这么多（不小于 1 pt）
  static let strokeDivisor: CGFloat = 11
  /// 对勾、感叹号、横线比描边粗这么多
  static let markRatio: CGFloat = 1.2
  /// 待办、进行中的描边：墨的这么多（增强对比度时是墨）
  static let strokeOpacity = 0.72

  /// 一个方框画在哪、多粗（视图坐标，y 朝下）
  struct Geometry: Equatable {
    /// 方框的外沿（描边画在它里面）
    var rect: CGRect
    var corner: CGFloat
    var stroke: CGFloat
    var mark: CGFloat
  }

  /// size：这一行正文的字号；advance：方框那个字占的那一格（x 和宽）；baseline：这一行的基线（y）；capHeight：正文字的
  /// 大写字母高——方框的中心对着基线上方 capHeight / 2（量过：和汉字字形的竖直中点只差 0.1–0.3 pt，见 NoteTaskBoxTests）。
  /// scale：屏幕像素 / 点：外沿、描边宽都取整到整像素，描边不糊
  static func geometry(
    size: CGFloat, advance: (x: CGFloat, width: CGFloat), baseline: CGFloat, capHeight: CGFloat,
    scale: CGFloat
  ) -> Geometry {
    let scale = max(scale, 1)
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    let side = max(snap(size * sideRatio), 1 / scale)
    let stroke = max(snap(max(size / strokeDivisor, 1)), 1 / scale)
    let rect = CGRect(
      x: snap(advance.x + (advance.width - side) / 2), y: snap(baseline - capHeight / 2 - side / 2),
      width: side, height: side)
    return Geometry(
      rect: rect, corner: side * cornerRatio, stroke: stroke, mark: stroke * markRatio)
  }

  /// 画一个方框。color：描边 / 底的颜色（待办、进行中是描边色，紧急是红，完成是色条色，取消是变淡的墨）；
  /// mark：紧急、完成上那个记号（感叹号 / 对勾）的颜色，别的状态不用
  static func draw(_ state: NoteTasks.State, in geometry: Geometry, color: NSColor, mark: NSColor?)
  {
    let rect = geometry.rect
    let inner = rect.insetBy(dx: geometry.stroke / 2, dy: geometry.stroke / 2)
    let radius = max(geometry.corner - geometry.stroke / 2, 0)
    switch state {
    case .urgent, .done:
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: geometry.corner, yRadius: geometry.corner).fill()
    case .todo, .doing, .cancelled:
      color.setStroke()
      let outline = NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
      outline.lineWidth = geometry.stroke
      outline.stroke()
    }
    if state == .doing {
      // 左半边填实（连描边那一圈：外沿的圆角路径裁到左半边）
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(
        rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
      )
      .addClip()
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: geometry.corner, yRadius: geometry.corner).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
    // 记号按方框里的比例画（y 朝下），圆头圆角
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
    let path = NSBezierPath()
    path.lineWidth = geometry.mark
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    switch state {
    case .done:
      path.move(to: point(0.27, 0.52))
      path.line(to: point(0.43, 0.68))
      path.line(to: point(0.74, 0.35))
    case .urgent:
      path.move(to: point(0.5, 0.25))
      path.line(to: point(0.5, 0.55))
    case .cancelled:
      path.move(to: point(0.3, 0.5))
      path.line(to: point(0.7, 0.5))
    case .todo, .doing:
      return
    }
    (state == .cancelled ? color : mark ?? .white).setStroke()
    path.stroke()
    if state == .urgent {
      // 感叹号的点
      (mark ?? .white).setFill()
      let dot = geometry.mark * 1.1
      let center = point(0.5, 0.75)
      NSBezierPath(
        ovalIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
      ).fill()
    }
  }

  // MARK: 颜色

  /// 记号（对勾、感叹号）压在 fill 这个底上用什么色：白色和 ink（这张纸浅色那套的墨）里对底对比度高的那个——
  /// 浅色纸的色条色（柠檬 0xE0AD08）上白勾只有 2.07:1，深色外观的红底（0xFF9C94）上白色只有 2.0:1
  static func mark(on fill: Int, ink: Int) -> Int {
    contrast(0xFFFFFF, fill) >= contrast(ink, fill) ? 0xFFFFFF : ink
  }

  /// WCAG 对比度（0xRRGGBB，sRGB）
  static func contrast(_ a: Int, _ b: Int) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  static func luminance(_ hex: Int) -> Double {
    func linear(_ shift: Int) -> Double {
      let value = Double(hex >> shift & 0xFF) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
  }
}

nonisolated extension NotePaper {
  /// 待办、进行中的描边：墨的 72%，增强对比度时是墨
  var taskStrokeColor: NSColor {
    Self.dynamic(light.ink, dark.ink, alpha: NoteTaskBox.strokeOpacity)
  }
  /// 完成的底：色条色，增强对比度时是墨（同引用的竖线）
  var taskDoneColor: NSColor { quoteBarColor }
  /// 完成上的对勾：白和浅色那套的墨取对比度高的；增强对比度时底是墨，勾用纸色
  var taskDoneMarkColor: NSColor {
    Self.dynamic(
      NoteTaskBox.mark(on: light.strip, ink: light.ink),
      NoteTaskBox.mark(on: dark.strip, ink: light.ink), contrast: (light.paper, dark.paper))
  }
  /// 紧急上的感叹号：压在文字颜色的红上，同上取色（增强对比度时底不变，记号也不变）
  var taskUrgentMarkColor: NSColor {
    Self.dynamic(
      NoteTaskBox.mark(on: NoteColor.red.light, ink: light.ink),
      NoteTaskBox.mark(on: NoteColor.red.dark, ink: light.ink))
  }
}
