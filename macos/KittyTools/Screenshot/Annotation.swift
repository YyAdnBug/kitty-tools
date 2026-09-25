// 截图标注（值类型）：矩形、箭头、文字、马赛克。坐标存整屏视图坐标（点，原点左下）：调整选区不丢标注（修旧版 #43）。
// 屏幕显示（SelectionView 的标注层）和导出（render）共用同一个 draw，所见即所得；马赛克从冻结帧取像素，
// 所以导出、识字拿到的都是打码后的图（修旧版把原图拿去识字，#44）。颜色是固定的 sRGB 值，不随深浅色变。
// 外观（Whisker §6）：矩形圆角 3、锥形实心箭头（头长 4 × 线宽、半角 28°）、文字 SF Pro Rounded semibold，
// 除马赛克外都带 black 0.28 / blur 3 的阴影（白色标注在白底上也看得见）。

import AppKit

struct Annotation: Identifiable, Equatable {
  enum Tool: Int, CaseIterable {
    case rectangle = 1
    case arrow, text, mosaic

    var title: String {
      switch self {
      case .rectangle: "矩形"
      case .arrow: "箭头"
      case .text: "文字"
      case .mosaic: "马赛克"
      }
    }

    var symbol: String {
      switch self {
      case .rectangle: "rectangle"
      case .arrow: "arrow.up.right"
      case .text: "textbox"
      case .mosaic: "checkerboard.rectangle"
      }
    }
  }

  enum Shape: Equatable {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    /// origin：文字框左上角
    case text(String, origin: CGPoint)
    case mosaic(CGRect)
  }

  enum Palette: Int, CaseIterable {
    case red, yellow, green, blue, black, white

    var title: String {
      switch self {
      case .red: "红"
      case .yellow: "黄"
      case .green: "绿"
      case .blue: "蓝"
      case .black: "黑"
      case .white: "白"
      }
    }

    var color: NSColor {
      let rgb: Int =
        switch self {
        case .red: 0xFF3B30
        case .yellow: 0xFFCC00
        case .green: 0x34C759
        case .blue: 0x007AFF
        case .black: 0x000000
        case .white: 0xFFFFFF
        }
      return NSColor(
        srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
  }

  enum Weight: Int, CaseIterable {
    case small, medium, large

    var title: String { ["细", "中", "粗"][rawValue] }
    var lineWidth: CGFloat { [2, 4, 6][rawValue] }
    var fontSize: CGFloat { [14, 20, 28][rawValue] }
    /// 马赛克每格的边长（点）
    var mosaicBlock: CGFloat { [6, 10, 16][rawValue] }
  }

  /// 旧版用户的标注全是红色 4 点粗的矩形：默认就是它
  struct Style: Equatable {
    var color = Palette.red
    var weight = Weight.medium
  }

  var id = UUID()
  var shape: Shape
  var style = Style()

  // MARK: 几何

  /// 画出来占的范围（含线宽、箭头，不含阴影），用来画选中框、点中文字和马赛克
  var bounds: CGRect {
    let width = style.weight.lineWidth
    switch shape {
    case .rectangle(let rect):
      return rect.insetBy(dx: -width / 2, dy: -width / 2)
    case .arrow(let from, let to):
      let pad = max(Self.arrowWing(from: from, to: to, width: width), width)
      return CGRect(
        x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x),
        height: abs(to.y - from.y)
      ).insetBy(dx: -pad, dy: -pad)
    case .text(let string, let origin):
      // 有的字形（泰文声调、斜体）会画出文字框：按字号留边，局部重画不留残影、不被裁掉
      let pad = style.weight.fontSize / 3
      return Self.textFrame(string, origin: origin, weight: style.weight).insetBy(
        dx: -pad, dy: -pad)
    case .mosaic(let rect):
      return rect
    }
  }

  /// 连阴影一起占的范围：局部重画按它来，不然挪走后留下一圈阴影残影
  var drawBounds: CGRect {
    isMosaic ? bounds : bounds.insetBy(dx: -Self.shadowReach, dy: -Self.shadowReach)
  }

  /// 点中它没有：矩形只认边线（空心框里面点不中，免得挡住下面的标注），箭头认杆和箭头，文字、马赛克认整块
  func contains(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
    let width = style.weight.lineWidth
    switch shape {
    case .rectangle(let rect):
      let reach = width / 2 + tolerance
      let inner = rect.insetBy(dx: reach, dy: reach)
      return rect.insetBy(dx: -reach, dy: -reach).contains(point)
        && (inner.isNull || inner.isEmpty || !inner.contains(point))
    case .arrow(let from, let to):
      return Self.distance(from: point, toSegment: from, to) <= width / 2 + tolerance
        || Self.arrowPath(from: from, to: to, width: width)?.contains(point) == true
    case .text, .mosaic:
      return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
  }

  var isMosaic: Bool {
    if case .mosaic = shape { true } else { false }
  }

  /// 小到看不出来的（误点）不留
  var isMeaningful: Bool {
    switch shape {
    case .rectangle(let rect), .mosaic(let rect): rect.width >= 3 && rect.height >= 3
    case .arrow(let from, let to): hypot(to.x - from.x, to.y - from.y) >= 6
    case .text(let string, _): !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  func offset(by delta: CGSize) -> Annotation {
    var moved = self
    switch shape {
    case .rectangle(let rect):
      moved.shape = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
    case .arrow(let from, let to):
      moved.shape = .arrow(
        from: CGPoint(x: from.x + delta.width, y: from.y + delta.height),
        to: CGPoint(x: to.x + delta.width, y: to.y + delta.height))
    case .text(let string, let origin):
      moved.shape = .text(
        string, origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
    case .mosaic(let rect):
      moved.shape = .mosaic(rect.offsetBy(dx: delta.width, dy: delta.height))
    }
    return moved
  }

  /// 拖动画出的形状（文字不是拖出来的，返回 nil）。constrained（按住 ⇧）：矩形变正方形，箭头吸附到 45° 的倍数
  static func shape(for tool: Tool, from start: CGPoint, to end: CGPoint, constrained: Bool)
    -> Shape?
  {
    var end = end
    if constrained {
      let dx = end.x - start.x
      let dy = end.y - start.y
      if tool == .arrow {
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
      } else {
        let side = max(abs(dx), abs(dy))
        end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
      }
    }
    let rect = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
      height: abs(end.y - start.y))
    switch tool {
    case .rectangle: return .rectangle(rect)
    case .arrow: return .arrow(from: start, to: end)
    case .text: return nil
    case .mosaic: return .mosaic(rect)
    }
  }

  // MARK: 文字

  /// SF Pro Rounded semibold（中文回退到苹方，没有圆体）
  static func font(_ weight: Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: weight.fontSize, weight: .semibold)
    return font.fontDescriptor.withDesign(.rounded).flatMap {
      NSFont(descriptor: $0, size: weight.fontSize)
    } ?? font
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

  /// 在视图坐标的上下文里画（导出时由 render 把上下文变换成视图坐标）。马赛克要从冻结帧取像素。
  /// shadowScale：Quartz 的阴影参数不跟 CTM 走——视图 / 图层的上下文按点算（系统设了基础变换），
  /// 自建位图按像素算，所以 render 要传每点几像素，屏幕上传 1
  func draw(in context: CGContext, image: CGImage, viewSize: CGSize, shadowScale: CGFloat = 1) {
    let color = style.color.color.cgColor
    let width = style.weight.lineWidth
    context.saveGState()
    defer { context.restoreGState() }
    if !isMosaic {
      context.setShadow(
        offset: .zero, blur: Self.shadowBlur * shadowScale, color: Self.shadowColor.cgColor)
    }
    switch shape {
    case .rectangle(let rect):
      let radius = min(3, rect.width / 2, rect.height / 2)
      context.setStrokeColor(color)
      context.setLineWidth(width)
      context.addPath(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.strokePath()
    case .arrow(let from, let to):
      guard let path = Self.arrowPath(from: from, to: to, width: width) else { return }
      context.setFillColor(color)
      context.addPath(path)
      context.fillPath()
    case .text(let string, let origin):
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      NSAttributedString(
        string: string,
        attributes: [.font: Self.font(style.weight), .foregroundColor: style.color.color]
      ).draw(in: Self.textFrame(string, origin: origin, weight: style.weight))
      NSGraphicsContext.restoreGraphicsState()
    case .mosaic(let rect):
      drawMosaic(rect, in: context, image: image, viewSize: viewSize)
    }
  }

  /// 马赛克：冻结帧这一块缩小到每格一个像素，再不插值地放大回去
  private func drawMosaic(_ rect: CGRect, in context: CGContext, image: CGImage, viewSize: CGSize) {
    let imageSize = CGSize(width: image.width, height: image.height)
    let pixels = RegionSelector.pixelRect(rect, viewSize: viewSize, imageSize: imageSize)
    guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels) else {
      return
    }
    let scaleX = imageSize.width / viewSize.width
    let scaleY = imageSize.height / viewSize.height
    let block = style.weight.mosaicBlock * scaleX
    let columns = max(1, Int((pixels.width / block).rounded(.up)))
    let rows = max(1, Int((pixels.height / block).rounded(.up)))
    guard
      let small = CGContext(
        data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
        space: crop.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    small.interpolationQuality = .medium
    small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
    guard let blocks = small.makeImage() else { return }
    context.clip(to: rect)
    context.interpolationQuality = .none
    // 像素矩形换回视图坐标（取整后可能比 rect 大一点点，已经被 clip 掉）
    context.draw(
      blocks,
      in: CGRect(
        x: pixels.minX / scaleX, y: (imageSize.height - pixels.maxY) / scaleY,
        width: pixels.width / scaleX, height: pixels.height / scaleY))
  }

  /// 选区的最终图：冻结帧裁出 pixelRect，再用同一个 draw 画上标注。导出、钉图、识字都用它；
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
    for annotation in annotations {
      annotation.draw(in: context, image: image, viewSize: viewSize, shadowScale: scaleX)
    }
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
