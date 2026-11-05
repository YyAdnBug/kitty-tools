// 截图翻译的「原位覆盖」：把 OCR 认出的一段段文字按原来的位置抹成背景色，再把译文排回去，出一张能直接复制的图。
// 坐标全程是「像素、原点左下」，和 Vision 的归一化行框同一个方向，不用翻；CoreText 在这个坐标系里画字正好是正的。
// 排版规则（从原始需求出发，不做多余的兜底）：先缩字号塞回原段框，塞不下再借下方的空白，最后才是最小字号硬画。

import CoreGraphics
import CoreText
import Foundation

nonisolated enum ScreenshotOverlay {
  /// 一段：行框并集（像素、原点左下）、接好的原文、段内的中位行高
  struct Segment: Equatable, Sendable {
    var box: CGRect
    var text: String
    var lineHeight: CGFloat
  }

  /// 一段排好之后要画的东西：抹掉哪儿、文字画在哪个矩形里、多大字号
  struct Span: Equatable, Sendable {
    var text: String
    /// 原文所在的位置（往外放了一点，盖得住抗锯齿的毛边）
    var erase: CGRect
    /// 排译文的矩形：顶边和原文顶边齐平，往下最多长到下一段之前
    var frame: CGRect
    var fontSize: CGFloat
  }

  struct RGB: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    /// 相对亮度（Rec. 601）：深底配白字、浅底配黑字
    var luminance: CGFloat { 0.299 * red + 0.587 * green + 0.114 * blue }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    static let light = RGB(red: 1, green: 1, blue: 1)
  }

  /// 可接受的最小字号（像素）：再小就认不出了，宁可借下方的空白
  private static let minimumFontSize: CGFloat = 6.5

  // MARK: 分段

  /// OCR 的行 → 按段分好的块（切段规则同 OCR.paragraphs）。纯函数，配单测
  static func segments(of lines: [OCR.Line], imageSize: CGSize) -> [Segment] {
    guard imageSize.width > 0, imageSize.height > 0 else { return [] }
    return OCR.groups(lines).compactMap { group in
      let text = OCR.joinLine(group.map(\.text))
      guard !text.isEmpty else { return nil }
      var box = CGRect.null
      for line in group { box = box.union(line.box) }
      guard !box.isNull else { return nil }
      let heights = group.map { $0.box.height * imageSize.height }.sorted()
      return Segment(
        box: CGRect(
          x: box.minX * imageSize.width, y: box.minY * imageSize.height,
          width: box.width * imageSize.width, height: box.height * imageSize.height),
        text: text,
        lineHeight: heights[heights.count / 2])
    }
  }

  // MARK: 排版

  /// 每段用多大字号、画在哪个矩形：只算几何，不碰像素（采样背景在 render 里做）。
  /// ①字号从「比原行高略小」开始缩，缩到原段框塞得下为止；②还塞不下就借下方的空白；
  /// ③再不行用最小字号硬画（CoreText 自己会裁掉排不下的行）。纯函数，配单测
  static func spans(segments: [Segment], translations: [String], imageSize: CGSize) -> [Span] {
    var spans: [Span] = []
    for (index, segment) in segments.enumerated() {
      guard index < translations.count else { continue }
      let text = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let pad = max(1, segment.lineHeight * 0.05)
      let gap = max(2, segment.lineHeight * 0.3)
      let margin = max(2, segment.lineHeight * 0.2)

      // 宽度照原段框，最多放宽 25%（长句少折几行）。放宽之前先让出**同高度、在右边**那一列的位置：
      // 两列挨得近时，放宽出来的字会盖到隔壁那列的译文上
      let neighbour = segments
        .filter { candidate in
          candidate.box.minX > segment.box.minX + 0.5
            && candidate.box.minY < segment.box.maxY && candidate.box.maxY > segment.box.minY
        }
        .map(\.box.minX)
        .min()
      let rightRoom = (neighbour ?? imageSize.width) - margin - segment.box.minX
      let width = max(8, min(max(segment.box.width, segment.box.width * 1.25), rightRoom))
      let eraseWidth = max(segment.box.width + 2 * pad, width + pad)
      let eraseMinX = segment.box.minX - pad

      // 往下能长到哪：**抹掉的这一整条**（比原文宽）下面、横向有重叠的段里最高的那个顶边，再留一点空；
      // 下面没东西就到图片底边。横向范围要用抹除宽度，不然放宽的部分会压到下面那列的字
      let below = segments
        .filter { candidate in
          candidate.box.maxY < segment.box.maxY - 0.5
            && candidate.box.maxX > eraseMinX && candidate.box.minX < eraseMinX + eraseWidth
        }
        .map(\.box.maxY)
        .max()
      let bottom: CGFloat = if let below { max(0, min(segment.box.minY, below + gap)) } else { 0 }

      var frame = CGRect(
        x: segment.box.minX, y: bottom, width: width,
        height: max(segment.box.height, segment.box.maxY - bottom))
      let fitted = fitFontSize(
        text, width: width, boxHeight: segment.box.height, roomHeight: frame.height,
        lineHeight: segment.lineHeight)
      // 译文比原文短很多时垂直居中：顶对齐会让段里剩一大片空白，看着像丢了内容
      let centred = max(0, (segment.box.height - fitted.height) / 2)
      let shift = min(centred, frame.minY)
      frame = frame.offsetBy(dx: 0, dy: -shift)
      frame.size.height += shift

      // 抹掉的区域要盖住译文实际占的那块（不只是原文）：不然多出来的行会画在没抹的底色上，
      // 深底白字落到浅色背景上就看不见了
      let top = segment.box.maxY + pad
      let eraseHeight = min(
        top - frame.minY, max(segment.box.height + 2 * pad, fitted.height + pad))
      let erase = CGRect(
        x: eraseMinX, y: top - eraseHeight, width: eraseWidth, height: eraseHeight
      ).intersection(CGRect(origin: .zero, size: imageSize))
      guard erase.width > 1, erase.height > 1 else { continue }
      spans.append(
        Span(text: text, erase: erase, frame: frame, fontSize: fitted.fontSize))
    }
    return spans
  }

  /// 字号拟合：从「比原行高略小」往下试（CJK 的行高一般是字号的一点二到一点四倍）。
  /// 返回字号和这个字号下量出来的高度（抹除框要按它算盖到哪）
  private static func fitFontSize(
    _ text: String, width: CGFloat, boxHeight: CGFloat, roomHeight: CGFloat, lineHeight: CGFloat
  ) -> (fontSize: CGFloat, height: CGFloat) {
    let start = max(minimumFontSize, min(lineHeight * 0.82, boxHeight * 0.95))
    let tight = max(minimumFontSize, min(start, lineHeight * 0.62))
    var size = start
    while size >= tight {
      let height = measureHeight(text, width: width, fontSize: size)
      if height <= boxHeight { return (size, height) }
      size *= 0.92
    }
    size = tight
    while size >= minimumFontSize {
      let height = measureHeight(text, width: width, fontSize: size)
      if height <= roomHeight { return (size, height) }
      size *= 0.92
    }
    return (minimumFontSize, measureHeight(text, width: width, fontSize: minimumFontSize))
  }

  /// 这段文字在给定宽度、字号下要占多高（+1 留给排版取整的误差）
  private static func measureHeight(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
    let attributes: [CFString: Any] = [kCTFontAttributeName: font(size: fontSize)]
    guard
      let string = CFAttributedStringCreate(
        nil, text as CFString, attributes as CFDictionary)
    else { return .infinity }
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    return size.height + 1
  }

  // MARK: 出图

  /// 合成：每段先抹成自己那块背景色，再把译文画上去。整张图只读一遍像素（4K 约 33 MB）
  @concurrent static func render(
    _ image: CGImage, segments: [Segment], translations: [String]
  ) async -> CGImage? {
    let size = CGSize(width: image.width, height: image.height)
    let spans = Self.spans(segments: segments, translations: translations, imageSize: size)
    guard !spans.isEmpty else { return nil }
    return draw(image, spans: spans)
  }

  private static func draw(_ image: CGImage, spans: [Span]) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: full)
    context.setShouldAntialias(true)
    let sampler = Sampler(image)
    // 底色从每一段框外一圈采样：原文是深底白字还是白底黑字，看这个就知道
    let backgrounds = spans.map { sampler?.ring(around: $0.erase) ?? .light }
    // 先把所有抹除区域填完，再统一画字：两段挨得近、抹除框有重叠时，后填的色块不会盖掉先画好的译文
    for (span, background) in zip(spans, backgrounds) {
      context.setFillColor(background.cgColor)
      context.fill(span.erase)
    }
    for (span, background) in zip(spans, backgrounds) {
      let foreground =
        background.luminance > 0.55
        ? RGB(red: 0.08, green: 0.08, blue: 0.09)
        : RGB(red: 0.97, green: 0.97, blue: 0.97)
      drawText(span, color: foreground, in: context)
    }
    return context.makeImage()
  }

  private static func drawText(_ span: Span, color: RGB, in context: CGContext) {
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font(size: span.fontSize),
      kCTForegroundColorAttributeName: color.cgColor,
    ]
    guard
      let string = CFAttributedStringCreate(
        nil, span.text as CFString, attributes as CFDictionary)
    else { return }
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let path = CGPath(rect: span.frame, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
    context.saveGState()
    context.textMatrix = .identity
    CTFrameDraw(frame, context)
    context.restoreGState()
  }

  /// 系统 UI 字体（中文系统上是苹方、西文是 SF）：译文可能是任何语言，不挑字体，系统字体覆盖最广
  private static func font(size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
  }

  // MARK: 采样

  /// 读像素用的一张位图：只画一次，按坐标取色。行 0 是图像的顶部，坐标按左下原点换算
  private struct Sampler {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
      let width = image.width
      let height = image.height
      guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
      }
      let bytesPerRow = width * 4
      let raw = UnsafeMutableRawPointer.allocate(
        byteCount: bytesPerRow * height, alignment: 4)
      defer { raw.deallocate() }
      guard
        let context = CGContext(
          data: raw, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      self.width = width
      self.height = height
      self.bytesPerRow = bytesPerRow
      self.bytes = Array(
        UnsafeBufferPointer(
          start: raw.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }

    /// 框外一圈的采样，按亮度排序取中位那颗：原文的底色（描边、阴影、旁边别的字都不影响）
    func ring(around box: CGRect) -> RGB? {
      let outset = max(3, box.height * 0.12)
      let outer = box.insetBy(dx: -outset, dy: -outset)
      let x0 = Int(outer.minX.rounded(.down))
      let x1 = Int(outer.maxX.rounded(.up))
      let y0 = Int(outer.minY.rounded(.down))
      let y1 = Int(outer.maxY.rounded(.up))
      guard x1 > x0, y1 > y0 else { return nil }
      let stepX = max(1, (x1 - x0) / 40)
      let stepY = max(1, (y1 - y0) / 40)
      var samples: [(luminance: CGFloat, color: RGB)] = []
      func collect(_ x: Int, _ y: Int) {
        // 框里是原文，不能采；图外也没有
        guard !box.contains(CGPoint(x: x, y: y)) else { return }
        guard let color = color(x: x, y: y) else { return }
        samples.append((color.luminance, color))
      }
      for x in stride(from: x0, to: x1, by: stepX) {
        collect(x, y0)
        collect(x, y1 - 1)
      }
      for y in stride(from: y0, to: y1, by: stepY) {
        collect(x0, y)
        collect(x1 - 1, y)
      }
      guard !samples.isEmpty else { return nil }
      samples.sort { $0.luminance < $1.luminance }
      return samples[samples.count / 2].color
    }

    /// y 按左下原点（和框一致）：数据里第 0 行是图像顶部
    private func color(x: Int, y: Int) -> RGB? {
      guard x >= 0, x < width, y >= 0, y < height else { return nil }
      let offset = (height - 1 - y) * bytesPerRow + x * 4
      guard offset + 3 < bytes.count else { return nil }
      // 预乘：半透明的地方要除回去；全透明按白算（截图很少有透明）
      let alpha = CGFloat(bytes[offset + 3]) / 255
      guard alpha > 0.02 else { return .light }
      return RGB(
        red: min(1, CGFloat(bytes[offset]) / 255 / alpha),
        green: min(1, CGFloat(bytes[offset + 1]) / 255 / alpha),
        blue: min(1, CGFloat(bytes[offset + 2]) / 255 / alpha))
    }
  }
}
