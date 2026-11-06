// 截图翻译的「原位覆盖」：把 OCR 认出的一段段文字按原来的位置抹成背景色，再把译文排回去，出一张能直接复制的图。
// 坐标全程是「像素、原点左下」，和 Vision 的归一化行框同一个方向，不用翻；CoreText 在这个坐标系里画字正好是正的。
// 排版规则（2026-11-06 改，原来每段各自从自己的行高缩起、一路能缩到 6.5，同一张图里字号忽大忽小）：
// 正文段（行高和全图正文差不到两成）统一用一个基准字号，标题、小字这类明显不一样高的按自己的行高；
// 译文行数多过原文时先缩，最多缩到基准的四分之三，再多就借下方的空白，借完还放不下才继续缩（宁可小也不丢字）。

import CoreGraphics
import CoreText
import Foundation

nonisolated enum ScreenshotOverlay {
  /// 一段：行框并集（像素、原点左下）、接好的原文、段内的中位行高、有几行
  struct Segment: Equatable, Sendable {
    var box: CGRect
    var text: String
    var lineHeight: CGFloat
    /// 原文占几行：译文排得比它多才缩字号（比高度稳：译文的行高跟字体走，和原文对不上）
    var lineCount = 1
  }

  /// 一段排好之后要画的东西：抹掉哪儿、文字画在哪个矩形里、多大字号
  struct Span: Equatable, Sendable {
    var text: String
    /// 原文所在的位置（往外放了一小圈，盖得住抗锯齿的毛边）
    var erase: CGRect
    /// 抹除框最多能长到哪：出图时框外一圈还不是底色（行内代码块的底框、没框全的笔画）就往外长，长到这里为止
    var eraseLimit: CGRect
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

    /// 和另一颜色有差别（任一通道差过 4%，约 10 / 255）：抹除框往外长时用来认「还不是底色」。
    /// 门槛要低：GitHub 深色页里行内代码块的底 (22,27,34) 和页面底 (1,4,9) 只差 25 / 255；截图是无损的，没有压缩噪点
    func differs(from other: RGB) -> Bool {
      max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) > 0.04
    }

    static let light = RGB(red: 1, green: 1, blue: 1)
  }

  /// 可接受的最小字号（像素）：只有借完下方的空白还放不下时才会缩到这么小
  private static let minimumFontSize: CGFloat = 6.5
  /// 字号和 OCR 行高之比：Vision 的行框从上伸部到下伸部，比字号高两成左右
  private static let fontPerLineHeight: CGFloat = 0.82
  /// 行高和全图正文差不到这么多就算正文、用统一的基准字号
  private static let bodyTolerance: CGFloat = 0.2
  /// 译文太长时字号最多缩到基准的这么多，再长就借下方的空白
  private static let shrinkFloor: CGFloat = 0.75
  /// 抹除框先往外扩多少（行高的倍数）：盖住抗锯齿的毛边
  private static let erasePad: CGFloat = 0.1
  /// 抹除框最多往外长多少（行高的倍数）：网页里行内代码块的底框比 Vision 的行框高出三成行高上下，
  /// 抹少了顶边的描边会留下一条细线（2026-11-06）。只在框外不是底色时才长，见 Sampler.grow
  private static let eraseReach: CGFloat = 0.5

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
        lineHeight: heights[heights.count / 2],
        lineCount: group.count)
    }
  }

  /// 这段有没有值得翻译的内容：字母、数字、汉字都算；纯标点、分隔线、装饰符不算。
  /// OCR 常把一条分割线认成 `———`、把项目符号认成 `•`，这种送去有道网页版会直接回错误码 40，
  /// 一段失败就拖垮整张图（分段翻译是串行的）
  static func hasTranslatableContent(_ text: String) -> Bool {
    text.unicodeScalars.contains {
      CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
    }
  }

  // MARK: 排版

  /// 每段用多大字号、画在哪个矩形：只算几何，不碰像素（采样背景在 render 里做）。纯函数，配单测
  static func spans(segments: [Segment], translations: [String], imageSize: CGSize) -> [Span] {
    let body = bodyLineHeight(segments)
    let bounds = CGRect(origin: .zero, size: imageSize)
    var spans: [Span] = []
    for (index, segment) in segments.enumerated() {
      guard index < translations.count else { continue }
      let text = listItem(
        translations[index].trimmingCharacters(in: .whitespacesAndNewlines), source: segment.text)
      // 纯符号的段（分隔线、装饰符，OCR 常认成 `———`）不覆盖：里面没有可翻译的内容，
      // 送去服务那边还会直接回错误码（有道网页版是 40）
      guard !text.isEmpty, Self.hasTranslatableContent(segment.text) else { continue }
      let box = segment.box
      let others = segments.indices.filter { $0 != index }.map { segments[$0].box }
      let gap = max(2, segment.lineHeight * 0.3)
      let margin = max(2, segment.lineHeight * 0.2)

      // 右边**整个在本段右边**、高度上有重叠的那一栏：放宽译文时要让出它的位置。只看左边界在不在本段右边界之外——
      // 原来是「左边界比本段的靠右」就算，段框是几行的并集、又高又宽，同一栏里下一段的段框（或者被拆开的半行）
      // 左边界只要缩进一点就被当成邻栏，宽度被截成二十几像素，字号一路缩到最小（2026-11-06）
      let column = others.filter {
        $0.minX >= box.maxX - 0.5 && overlaps($0, box, vertically: true)
      }
      .map(\.minX).min()
      let rightRoom = (column ?? imageSize.width) - margin - box.minX
      let width = max(8, min(box.width * 1.25, rightRoom))

      // 抹除框四边往外扩：先扩一小圈，出图时按像素最多再长到 eraseReach；都不超过和那一边最近的另一段之间空隙的一半，
      // 别抹到人家
      func pad(_ room: CGFloat?, _ reach: CGFloat = erasePad) -> CGFloat {
        max(1, min(segment.lineHeight * reach, (room ?? .infinity) / 2))
      }
      let left = others.filter { $0.maxX <= box.minX + 0.5 && overlaps($0, box, vertically: true) }
        .map { box.minX - $0.maxX }.min()
      let right = column.map { $0 - box.maxX }
      let above = others.filter {
        $0.minY >= box.maxY - 0.5 && overlaps($0, box, vertically: false)
      }
      .map { $0.minY - box.maxY }.min()
      let under = others.filter {
        $0.maxY <= box.minY + 0.5 && overlaps($0, box, vertically: false)
      }
      .map { box.minY - $0.maxY }.min()
      let eraseMinX = box.minX - pad(left)
      let eraseMaxX = max(box.maxX + pad(right), box.minX + width)

      // 往下能长到哪：**抹掉的这一整条**（比原文宽）下面、横向有重叠的段里最高的那个顶边，再留一点空；
      // 下面没东西就到图片底边。横向范围要用抹除宽度，不然放宽的部分会压到下面那列的字
      let below = others.filter {
        $0.maxY < box.maxY - 0.5 && $0.maxX > eraseMinX && $0.minX < eraseMaxX
      }
      .map(\.maxY).max()
      let bottom: CGFloat = if let below { max(0, min(box.minY, below + gap)) } else { 0 }
      let frame = CGRect(
        x: box.minX, y: bottom, width: width, height: max(box.height, box.maxY - bottom))

      // 正文统一一个基准：行高和全图正文差不到两成的都按正文的行高定字号
      let lineHeight =
        abs(segment.lineHeight - body) <= body * bodyTolerance ? body : segment.lineHeight
      let fitted = fitFontSize(
        text, width: width, nominal: lineHeight * fontPerLineHeight,
        lineCount: segment.lineCount, roomHeight: frame.height)

      // 抹掉的区域要盖住译文实际占的那块（不只是原文）：不然多出来的行会画在没抹的底色上，
      // 深底白字落到浅色背景上就看不见了。译文从原文顶边往下排
      let eraseMinY = min(box.minY - pad(under), max(frame.minY, box.maxY - fitted.height))
      let erase = CGRect(
        x: eraseMinX, y: eraseMinY, width: eraseMaxX - eraseMinX,
        height: box.maxY + pad(above) - eraseMinY
      ).intersection(bounds)
      guard erase.width > 1, erase.height > 1 else { continue }
      let reachMinX = box.minX - pad(left, eraseReach)
      let reachMinY = box.minY - pad(under, eraseReach)
      let reach = CGRect(
        x: reachMinX, y: reachMinY, width: box.maxX + pad(right, eraseReach) - reachMinX,
        height: box.maxY + pad(above, eraseReach) - reachMinY)
      let limit = erase.union(reach).intersection(bounds)
      spans.append(
        Span(
          text: text, erase: erase, eraseLimit: limit, frame: frame, fontSize: fitted.fontSize))
    }
    return spans
  }

  /// 全图正文的行高：各段行高按行数加权的中位数（正文行多，标题、小字的段行少，拉不动它）。纯符号的段不算
  private static func bodyLineHeight(_ segments: [Segment]) -> CGFloat {
    let heights = segments.filter { hasTranslatableContent($0.text) }
      .flatMap { Array(repeating: $0.lineHeight, count: max(1, $0.lineCount)) }
      .sorted()
    return heights.isEmpty ? 0 : heights[heights.count / 2]
  }

  /// 两个框在一个方向上有没有重叠（vertically: 看纵向，否则看横向）
  private static func overlaps(_ a: CGRect, _ b: CGRect, vertically: Bool) -> Bool {
    vertically ? a.minY < b.maxY && a.maxY > b.minY : a.minX < b.maxX && a.maxX > b.minX
  }

  /// 列表项的译文：原文那个记号会跟着被抹掉，所以译文得带着它——服务把它弄丢了就从原文补回来；
  /// 记号后面补一个空格（服务常把 `• text` 翻成 `•译文`），悬挂缩进按「记号 + 空格」量
  private static func listItem(_ text: String, source: String) -> String {
    guard let marker = OCR.listMarker(text) else {
      guard let original = OCR.listMarker(source), !text.isEmpty else { return text }
      return original.trimmingCharacters(in: .whitespaces) + " " + text
    }
    guard marker.last?.isWhitespace != true else { return text }
    return String(marker) + " " + String(text[marker.endIndex...])
  }

  /// 字号拟合：从基准字号起，① 译文行数不多于原文、也没超出可用的高度，就用它；不然一档档缩，最多缩到基准的四分之三；
  /// ② 四分之三还多出行来，就用四分之三借下方的空白（可用高度是原段框加上到下一段之前的空白）；
  /// ③ 借完还放不下才继续往下缩，宁可小也不让 CoreText 把排不下的行裁掉。
  /// 返回字号和这个字号下量出来的高度（抹除框要按它算盖到哪）
  private static func fitFontSize(
    _ text: String, width: CGFloat, nominal: CGFloat, lineCount: Int, roomHeight: CGFloat
  ) -> (fontSize: CGFloat, height: CGFloat) {
    let start = max(minimumFontSize, nominal)
    let floor = max(minimumFontSize, start * shrinkFloor)
    var size = start
    while true {
      let measured = measure(text, width: width, fontSize: size)
      if measured.lines <= max(1, lineCount), measured.height <= roomHeight {
        return (size, measured.height)
      }
      if size <= floor { break }
      size = max(floor, size * 0.92)
    }
    while size >= minimumFontSize {
      let height = measure(text, width: width, fontSize: size).height
      if height <= roomHeight { return (size, height) }
      size *= 0.92
    }
    return (minimumFontSize, measure(text, width: width, fontSize: minimumFontSize).height)
  }

  /// 这段文字在给定宽度、字号下排几行、要占多高（+1 留给排版取整的误差）
  private static func measure(_ text: String, width: CGFloat, fontSize: CGFloat) -> (
    lines: Int, height: CGFloat
  ) {
    guard let string = attributed(text, fontSize: fontSize, color: nil) else {
      return (.max, .infinity)
    }
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    let path = CGPath(
      rect: CGRect(x: 0, y: 0, width: width, height: size.height + fontSize * 4), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
    return (CFArrayGetCount(CTFrameGetLines(frame)), size.height + 1)
  }

  /// 量和画共用的一份带格式文字：字体、颜色（量的时候不要），列表项加悬挂缩进（折下去的行和记号后面的字对齐）
  private static func attributed(_ text: String, fontSize: CGFloat, color: CGColor?)
    -> CFAttributedString?
  {
    let font = font(size: fontSize)
    var attributes: [CFString: Any] = [kCTFontAttributeName: font]
    if let color { attributes[kCTForegroundColorAttributeName] = color }
    if let marker = OCR.listMarker(text),
      let prefix = CFAttributedStringCreate(
        nil, String(marker) as CFString, [kCTFontAttributeName: font] as CFDictionary)
    {
      var indent = CGFloat(
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix), nil, nil, nil))
      let style = withUnsafeBytes(of: &indent) { raw in
        var setting = CTParagraphStyleSetting(
          spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: raw.baseAddress!)
        return CTParagraphStyleCreate(&setting, 1)
      }
      attributes[kCTParagraphStyleAttributeName] = style
    }
    return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
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

  /// 把译文图贴回整屏冻结帧的选区位置（截图页里就地翻译）。pixels 是图里的像素矩形（原点左上），冻结帧尺寸不变
  @concurrent static func paste(_ patch: CGImage, into frame: CGImage, at pixels: CGRect) async
    -> CGImage?
  {
    guard let context = canvas(like: frame) else { return nil }
    context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    // CGContext 原点在左下，pixels 的原点在左上：翻一下 y
    context.draw(
      patch,
      in: CGRect(
        x: pixels.minX, y: CGFloat(frame.height) - pixels.maxY, width: pixels.width,
        height: pixels.height))
    return context.makeImage()
  }

  /// 和原图同尺寸、同色彩空间的画布：冻结帧是屏幕的色彩空间（多半是 Display P3），换成 sRGB 画一遍
  /// 选区里饱和的颜色会被压掉；原图的色彩空间建不了位图时才退回 sRGB
  private static func canvas(like image: CGImage) -> CGContext? {
    guard image.width > 0, image.height > 0 else { return nil }
    let make = { (space: CGColorSpace) in
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    return image.colorSpace.flatMap(make)
      ?? CGColorSpace(name: CGColorSpace.sRGB).flatMap(make)
  }

  private static func draw(_ image: CGImage, spans: [Span]) -> CGImage? {
    let width = image.width
    let height = image.height
    guard let context = canvas(like: image) else { return nil }
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: full)
    context.setShouldAntialias(true)
    let sampler = Sampler(image)
    // 底色从每一段框外一圈采样：原文是深底白字还是白底黑字，看这个就知道
    let backgrounds = spans.map { sampler?.ring(around: $0.erase) ?? .light }
    // 先把所有抹除区域填完，再统一画字：两段挨得近、抹除框有重叠时，后填的色块不会盖掉先画好的译文。
    // 抹之前按原图的像素把框长到外面一圈都是底色（读的是原图，前面填过的色块不影响后面的判断）
    for (span, background) in zip(spans, backgrounds) {
      context.setFillColor(background.cgColor)
      context.fill(
        sampler?.grow(span.erase, within: span.eraseLimit, background: background) ?? span.erase)
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
    guard let string = attributed(span.text, fontSize: span.fontSize, color: color.cgColor) else {
      return
    }
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

    /// 把抹除框往外长：四条边哪条紧贴着的外面一排像素里有不是底色的（行内代码块的底框和描边、没框全的笔画），
    /// 那条边就往外挪一像素，直到外面都是底色或者到了 limit。外面本来就是底色的边不动——字旁边隔着一点空白的
    /// 线条、图标不会被顺手抹掉
    func grow(_ box: CGRect, within limit: CGRect, background: RGB) -> CGRect {
      var x0 = Int(box.minX.rounded(.down))
      var x1 = Int(box.maxX.rounded(.up))
      var y0 = Int(box.minY.rounded(.down))
      var y1 = Int(box.maxY.rounded(.up))
      let lx0 = Int(limit.minX.rounded(.down))
      let lx1 = Int(limit.maxX.rounded(.up))
      let ly0 = Int(limit.minY.rounded(.down))
      let ly1 = Int(limit.maxY.rounded(.up))
      // 一排里超过这么多颗不是底色才算「压着东西」：一两颗杂色不算
      func busy(_ points: [(Int, Int)]) -> Bool {
        let threshold = max(1, points.count / 100)
        var count = 0
        for (x, y) in points {
          guard let color = color(x: x, y: y), color.differs(from: background) else { continue }
          count += 1
          if count > threshold { return true }
        }
        return false
      }
      var grew = true
      while grew {
        grew = false
        if y1 < ly1, busy((x0..<x1).map { ($0, y1) }) {
          y1 += 1
          grew = true
        }
        if y0 > ly0, busy((x0..<x1).map { ($0, y0 - 1) }) {
          y0 -= 1
          grew = true
        }
        if x0 > lx0, busy((y0..<y1).map { (x0 - 1, $0) }) {
          x0 -= 1
          grew = true
        }
        if x1 < lx1, busy((y0..<y1).map { (x1, $0) }) {
          x1 += 1
          grew = true
        }
      }
      return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
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
