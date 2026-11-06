// 截图翻译的「原位覆盖」：把 OCR 认出的一段段文字从图上去掉，再把译文按原来的位置、原来的字色排回去，出一张能直接复制的图。
// 坐标全程是「像素、原点左下」，和 Vision 的归一化行框同一个方向，不用翻；CoreText 在这个坐标系里画字正好是正的。
// 排版规则（2026-11-06 改，原来每段各自从自己的行高缩起、一路能缩到 6.5，同一张图里字号忽大忽小）：
// 正文段（行高和全图正文差不到两成）统一用一个基准字号，标题、小字这类明显不一样高的按自己的行高；
// 译文行数多过原文时先缩，最多缩到基准的四分之三，再多就借下方的空白，借完还放不下才继续缩（宁可小也不丢字）。
// 观感对照微信的截图翻译（2026-11-06 用户给的对比图），并修掉微信也有的毛病：
// - 只去掉字的像素，底色、渐变、边框留着；字色取原文的（灰字还是灰字）；
// - 每行译文的基线落在原文一行的基线上（基线、行距从像素里量，不信 Vision 的行框——带行内代码块的行，框会被撑高）；
// - 行内代码块跟着词走：原来的底框连字一起去掉，译文里还留着的代码词（`total_comments_evaluated`）在新位置
//   按原来的样子（底色、描边、上下高度、字色，等宽字体）重画底框——微信是把底框留在原处，译文折行之后就错位了；
// - 列表项的记号单独画，正文和原文的正文列对齐。

import CoreGraphics
import CoreText
import Foundation

nonisolated enum ScreenshotOverlay {
  /// 一段：行框并集（像素、原点左下）、接好的原文、段内的中位行高、有几行；出图时再从像素里量出基线、行距、代码块
  struct Segment: Equatable, Sendable {
    var box: CGRect
    var text: String
    var lineHeight: CGFloat
    /// 原文占几行：译文排得比它多才缩字号（比高度稳：译文的行高跟字体走，和原文对不上）
    var lineCount = 1
    /// 列表项的正文列离段框左边多远（第二行起的左边界，记号在它左边）；不是列表项、或者只有一行量不出来时是 0
    var inset: CGFloat = 0
    /// 段里拉丁字母 / 数字组成的词和它们的框（像素）：认哪些词在行内代码块里
    var words: [OCR.Word] = []
    /// 从像素里量出来的第一行基线、行距（基线到基线）；没量（纯几何的单测）时按行框估
    var baseline: CGFloat?
    var pitch: CGFloat?
    /// 段里的行内代码块：哪些词、长什么样；没有就 nil
    var code: Code?
  }

  /// 行内代码块的样子，从原图量出来；译文里原样留着的代码词按它重画底框
  struct Code: Equatable, Sendable {
    /// 原来在代码块里的词
    var words: Set<String>
    var fill: RGB
    /// 描边（代码块边上和底色不一样的那一圈）和它多宽；没有描边时 nil
    var border: RGB?
    var borderWidth: CGFloat
    /// 代码块里字的颜色（常常比正文亮）；取不到 nil，用正文的
    var text: RGB?
    /// 底框比字左右各宽出多少、顶边在基线上方多少、底边在基线下方多少（像素）
    var padding: CGFloat
    var above: CGFloat
    var below: CGFloat
  }

  /// 一段排好之后要画的东西
  struct Span: Equatable, Sendable {
    /// 正文（列表记号拿出来另画）
    var text: String
    /// 列表记号：画在原文段框的左边、第一行的基线上
    var marker: String?
    /// 原文的段框
    var source: CGRect
    /// 要去字的范围：里面只换掉字的像素（有代码块的段连代码块的底框一起换），底色留着
    var erase: CGRect
    /// 正文排在哪：左边界和宽度；顶边和原文顶边齐平，底边是最多往下长到哪（下一段之前）
    var frame: CGRect
    /// 第一行的基线（和原文第一行的基线齐平）、行距（基线到基线，照原文）
    var baseline: CGFloat
    var pitch: CGFloat
    var fontSize: CGFloat
    /// 字号缩了多少（拟合后 / 基准）：重画的代码块底框跟着缩
    var scale: CGFloat
    /// 原文的行高：去字时按它切小块、定毛边扩多少
    var lineHeight: CGFloat
    var code: Code?
  }

  struct RGB: Equatable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    /// 相对亮度（Rec. 601）：深底配白字、浅底配黑字
    var luminance: CGFloat { 0.299 * red + 0.587 * green + 0.114 * blue }

    /// 两个颜色差多少：三个通道里差得最大的那个（0–1）
    func distance(to other: RGB) -> CGFloat {
      max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    static let light = RGB(red: 1, green: 1, blue: 1)
  }

  /// 可接受的最小字号（像素）：只有借完下方的空白还放不下时才会缩到这么小
  private static let minimumFontSize: CGFloat = 6.5
  /// 字号和 OCR 行高之比：Vision 的行框从上伸部到下伸部；0.9 时汉字的字面和原文的大写字母、上伸部差不多高（对照微信）
  static let fontPerLineHeight: CGFloat = 0.9
  /// 量不到基线时（纯几何的单测）按行框估：基线在行框顶边往下多少（行高的倍数）
  private static let baselineDrop: CGFloat = 0.72
  /// 代码词用等宽字体，比正文小一点（GitHub 的行内代码是正文的 85%）
  private static let codeScale: CGFloat = 0.88
  /// 行高和全图正文差不到这么多就算正文、用统一的基准字号
  private static let bodyTolerance: CGFloat = 0.2
  /// 译文太长时字号最多缩到基准的这么多，再长就借下方的空白
  private static let shrinkFloor: CGFloat = 0.75
  /// 去字的范围在段框外再扩多少（行高的倍数）：盖住抗锯齿的毛边、Vision 没框全的笔画，
  /// 以及行内代码块比字宽出来、高出来的那截（约三成行高）
  private static let erasePad: CGFloat = 0.3
  /// 和所在那一小块的底色差过这么多才算字（0–1）：GitHub 深色页里行内代码块的底 (22,27,34) 和页面底 (1,4,9)
  /// 只差 25 / 255、描边差 32 / 255，都不算字；字和底色一般差一半以上
  private static let inkThreshold: CGFloat = 0.16
  /// 和底色差过这么多算「不是底色」（代码块的底、描边）：截图无损，没有压缩噪点
  private static let fillThreshold: CGFloat = 0.03

  // MARK: 分段

  /// OCR 的行 → 按段分好的块（切段规则同 OCR.paragraphs）。纯函数，配单测
  static func segments(of lines: [OCR.Line], imageSize: CGSize) -> [Segment] {
    guard imageSize.width > 0, imageSize.height > 0 else { return [] }
    func pixels(_ box: CGRect) -> CGRect {
      CGRect(
        x: box.minX * imageSize.width, y: box.minY * imageSize.height,
        width: box.width * imageSize.width, height: box.height * imageSize.height)
    }
    return OCR.groups(lines).compactMap { group in
      let text = OCR.joinLine(group.map(\.text))
      guard !text.isEmpty else { return nil }
      var box = CGRect.null
      for line in group { box = box.union(line.box) }
      guard !box.isNull else { return nil }
      let heights = group.map { $0.box.height * imageSize.height }.sorted()
      let lineHeight = heights[heights.count / 2]
      // 列表项的正文列：第二行起的左边界（第一行左边是记号）
      var inset: CGFloat = 0
      if group.count > 1, OCR.listMarker(group[0].text) != nil,
        let column = group.dropFirst().map(\.box.minX).min()
      {
        let measured = (column - box.minX) * imageSize.width
        if measured > 0, measured < 4 * lineHeight { inset = measured }
      }
      return Segment(
        box: pixels(box), text: text, lineHeight: lineHeight, lineCount: group.count, inset: inset,
        words: group.flatMap(\.words).map { OCR.Word(text: $0.text, box: pixels($0.box)) })
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

  /// 每段用多大字号、画在哪：只算几何，不碰像素（基线、代码块在 render 里先量好放进 Segment）。纯函数，配单测
  static func spans(segments: [Segment], translations: [String], imageSize: CGSize) -> [Span] {
    let body = bodyLineHeight(segments)
    let bodyPitch = bodyPitch(segments, body: body)
    let bounds = CGRect(origin: .zero, size: imageSize)
    var spans: [Span] = []
    for (index, segment) in segments.enumerated() {
      guard index < translations.count else { continue }
      let (marker, text) = listItem(
        translations[index].trimmingCharacters(in: .whitespacesAndNewlines), source: segment.text)
      // 纯符号的段（分隔线、装饰符，OCR 常认成 `———`）不覆盖：里面没有可翻译的内容，
      // 送去服务那边还会直接回错误码（有道网页版是 40）
      guard !text.isEmpty, Self.hasTranslatableContent(segment.text) else { continue }
      let box = segment.box
      let others = segments.indices.filter { $0 != index }.map { segments[$0].box }
      let gap = max(2, segment.lineHeight * 0.3)
      let margin = max(2, segment.lineHeight * 0.2)

      // 正文统一一个基准：行高和全图正文差不到两成的都按正文的行高定字号、行距
      let isBody = abs(segment.lineHeight - body) <= body * bodyTolerance
      let lineHeight = isBody ? body : segment.lineHeight
      let nominal = lineHeight * fontPerLineHeight
      // 行距照原文：量出来的优先；多行的段按行框估；一行的段用全图正文的（标题这类用自己行高的 1.3 倍）
      let pitch = min(
        max(
          segment.pitch ?? estimatedPitch(segment) ?? (isBody ? bodyPitch : nil) ?? lineHeight
            * 1.3,
          lineHeight * 0.9),
        lineHeight * 2.5)

      // 右边**整个在本段右边**、高度上有重叠的那一栏：放宽译文时要让出它的位置。只看左边界在不在本段右边界之外——
      // 原来是「左边界比本段的靠右」就算，段框是几行的并集、又高又宽，同一栏里下一段的段框（或者被拆开的半行）
      // 左边界只要缩进一点就被当成邻栏，宽度被截成二十几像素，字号一路缩到最小（2026-11-06）
      let column = others.filter {
        $0.minX >= box.maxX - 0.5 && overlaps($0, box, vertically: true)
      }
      .map(\.minX).min()
      let rightRoom = (column ?? imageSize.width) - margin - box.minX
      let width = max(8, min(box.width * 1.25, rightRoom))
      // 列表项：记号画在段框左边，正文从原文的正文列起；量不出正文列时让出「记号 + 空格」的宽度
      let inset =
        segment.inset > 0
        ? segment.inset : marker.map { textWidth($0 + " ", fontSize: nominal) } ?? 0
      let columnWidth = max(8, width - inset)

      // 去字的范围：段框四边各往外扩一点，但不超过和那一边最近的另一段之间空隙的一半，别动到人家
      func pad(_ room: CGFloat?) -> CGFloat {
        max(1, min(segment.lineHeight * erasePad, (room ?? .infinity) / 2))
      }
      let left = others.filter { $0.maxX <= box.minX + 0.5 && overlaps($0, box, vertically: true) }
        .map { box.minX - $0.maxX }.min()
      let above = others.filter {
        $0.minY >= box.maxY - 0.5 && overlaps($0, box, vertically: false)
      }
      .map { $0.minY - box.maxY }.min()
      let under = others.filter {
        $0.maxY <= box.minY + 0.5 && overlaps($0, box, vertically: false)
      }
      .map { box.minY - $0.maxY }.min()
      let eraseMinX = box.minX - pad(left)
      let eraseMaxX = max(box.maxX + pad(column.map { $0 - box.maxX }), box.minX + width)

      // 往下能长到哪：**这一整条**（比原文宽）下面、横向有重叠的段里最高的那个顶边，再留一点空；
      // 下面没东西就到图片底边。横向范围要用放宽后的宽度，不然放宽的部分会压到下面那列的字
      let below = others.filter {
        $0.maxY < box.maxY - 0.5 && $0.maxX > eraseMinX && $0.minX < eraseMaxX
      }
      .map(\.maxY).max()
      let bottom: CGFloat = if let below { max(0, min(box.minY, below + gap)) } else { 0 }

      let baseline = segment.baseline ?? box.maxY - segment.lineHeight * baselineDrop
      let fitted = fit(
        text, width: columnWidth, nominal: nominal, pitch: pitch, lineCount: segment.lineCount,
        baseline: baseline, bottom: bottom, code: segment.code)

      // 去字的范围也要盖住译文多出来的行：那里可能压着别的笔画（比如分隔线），不去掉会和译文叠在一起
      let eraseMinY = min(box.minY - pad(under), max(bottom, fitted.textBottom))
      let erase = CGRect(
        x: eraseMinX, y: eraseMinY, width: eraseMaxX - eraseMinX,
        height: box.maxY + pad(above) - eraseMinY
      ).intersection(bounds)
      guard erase.width > 1, erase.height > 1 else { continue }
      spans.append(
        Span(
          text: text, marker: marker, source: box, erase: erase,
          frame: CGRect(
            x: box.minX + inset, y: bottom, width: columnWidth,
            height: max(box.height, box.maxY - bottom)),
          baseline: baseline, pitch: fitted.pitch, fontSize: fitted.fontSize,
          scale: fitted.fontSize / max(1, nominal), lineHeight: segment.lineHeight,
          code: segment.code))
    }
    return spans
  }

  /// 多行的段按行框估的行距（第一行顶到最后一行底，减一个行高，均分）
  private static func estimatedPitch(_ segment: Segment) -> CGFloat? {
    guard segment.lineCount > 1 else { return nil }
    return (segment.box.height - segment.lineHeight) / CGFloat(segment.lineCount - 1)
  }

  /// 全图正文的行高：各段行高按行数加权的中位数（正文行多，标题、小字的段行少，拉不动它）。纯符号的段不算
  private static func bodyLineHeight(_ segments: [Segment]) -> CGFloat {
    let heights = segments.filter { hasTranslatableContent($0.text) }
      .flatMap { Array(repeating: $0.lineHeight, count: max(1, $0.lineCount)) }
      .sorted()
    return heights.isEmpty ? 0 : heights[heights.count / 2]
  }

  /// 全图正文的行距：正文里多行的段各自的行距（量出来的优先）取中位数；没有多行的正文段时 nil
  private static func bodyPitch(_ segments: [Segment], body: CGFloat) -> CGFloat? {
    let pitches = segments.filter {
      $0.lineCount > 1 && hasTranslatableContent($0.text)
        && abs($0.lineHeight - body) <= body * bodyTolerance
    }
    .compactMap { $0.pitch ?? estimatedPitch($0) }
    .sorted()
    return pitches.isEmpty ? nil : pitches[pitches.count / 2]
  }

  /// 两个框在一个方向上有没有重叠（vertically: 看纵向，否则看横向）
  private static func overlaps(_ a: CGRect, _ b: CGRect, vertically: Bool) -> Bool {
    vertically ? a.minY < b.maxY && a.maxY > b.minY : a.minX < b.maxX && a.maxX > b.minX
  }

  /// 列表项拆成记号和正文：原文的记号会跟着被去掉，所以要另画一个——译文里有就用译文的，服务弄丢了就用原文的
  private static func listItem(_ text: String, source: String) -> (marker: String?, text: String) {
    if let marker = OCR.listMarker(text) {
      return (
        marker.trimmingCharacters(in: .whitespaces),
        String(text[marker.endIndex...]).trimmingCharacters(in: .whitespaces)
      )
    }
    return (OCR.listMarker(source).map { $0.trimmingCharacters(in: .whitespaces) }, text)
  }

  /// 字号拟合：从基准字号起，① 译文行数不多于原文、也没超出可用的高度，就用它；不然一档档缩，最多缩到基准的四分之三；
  /// ② 四分之三还多出行来，就用四分之三借下方的空白（行距不变，接着原文的行往下排）；
  /// ③ 借完还放不下才继续往下缩、行距跟着缩，宁可小也不丢字。
  /// 返回字号、行距、排成几行和最后一行字的底边（去字的范围要盖到那里）
  private static func fit(
    _ text: String, width: CGFloat, nominal: CGFloat, pitch: CGFloat, lineCount: Int,
    baseline: CGFloat, bottom: CGFloat, code: Code?
  ) -> (fontSize: CGFloat, pitch: CGFloat, lines: Int, textBottom: CGFloat) {
    let start = max(minimumFontSize, nominal)
    let floor = max(minimumFontSize, start * shrinkFloor)
    func textBottom(_ size: CGFloat, _ pitch: CGFloat) -> (lines: Int, bottom: CGFloat) {
      let lines = lines(of: text, width: width, fontSize: size, color: nil, code: code).count
      // 字的下沿：汉字在基线下一成多，拉丁字母的下伸部两成多；重画的代码块底框还要再往下一点
      let below = max(size * 0.25, (code?.below ?? 0) * size / start)
      return (lines, baseline - CGFloat(max(0, lines - 1)) * pitch - below)
    }
    var size = start
    while true {
      let measured = textBottom(size, pitch)
      if measured.lines <= max(1, lineCount), measured.bottom >= bottom {
        return (size, pitch, measured.lines, measured.bottom)
      }
      if size <= floor { break }
      size = max(floor, size * 0.92)
    }
    let borrowed = textBottom(size, pitch)
    if borrowed.bottom >= bottom { return (size, pitch, borrowed.lines, borrowed.bottom) }
    while size * 0.92 >= minimumFontSize {
      size *= 0.92
      let scaled = pitch * size / floor
      let measured = textBottom(size, scaled)
      if measured.bottom >= bottom { return (size, scaled, measured.lines, measured.bottom) }
    }
    let scaled = pitch * size / floor
    let last = textBottom(size, scaled)
    return (size, scaled, last.lines, last.bottom)
  }

  /// 一段字的宽度（列表记号让出多宽）
  private static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
    guard let string = attributed(text, fontSize: fontSize, color: nil, code: nil) else { return 0 }
    return CGFloat(
      CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
  }

  /// 按宽度折好的一行行，带每行在框里的横向偏移（量和画共用，折法一致）
  private static func lines(
    of text: String, width: CGFloat, fontSize: CGFloat, color: CGColor?, code: Code?,
    codeColor: CGColor? = nil
  ) -> [(line: CTLine, x: CGFloat)] {
    guard
      let string = attributed(
        text, fontSize: fontSize, color: color, code: code, codeColor: codeColor)
    else { return [] }
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let path = CGPath(
      rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
    guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return [] }
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    return zip(lines, origins).map { ($0, $1.x) }
  }

  /// 量和画共用的一份带格式文字：正文用系统字体；代码词用等宽字体（和颜色）
  private static func attributed(
    _ text: String, fontSize: CGFloat, color: CGColor?, code: Code?, codeColor: CGColor? = nil
  ) -> CFAttributedString? {
    guard let string = CFAttributedStringCreateMutable(nil, 0) else { return nil }
    CFAttributedStringReplaceString(string, CFRange(location: 0, length: 0), text as CFString)
    var attributes: [CFString: Any] = [kCTFontAttributeName: font(size: fontSize)]
    if let color { attributes[kCTForegroundColorAttributeName] = color }
    let whole = CFRange(location: 0, length: CFAttributedStringGetLength(string))
    CFAttributedStringSetAttributes(string, whole, attributes as CFDictionary, true)
    if let code {
      let mono = monospacedFont(size: fontSize * codeScale)
      for range in codeRanges(in: text, words: code.words) {
        let cfRange = CFRange(location: range.location, length: range.length)
        CFAttributedStringSetAttribute(string, cfRange, kCTFontAttributeName, mono)
        if let codeColor {
          CFAttributedStringSetAttribute(
            string, cfRange, kCTForegroundColorAttributeName, codeColor)
        }
      }
    }
    return string
  }

  /// 译文里原样出现的代码词（前后不连着字母、数字、下划线，免得 `max` 认进 `maximum`）的位置（UTF-16），
  /// 互相重叠的只留先出现、更长的那个
  static func codeRanges(in text: String, words: Set<String>) -> [NSRange] {
    let string = text as NSString
    func isWordCharacter(_ index: Int) -> Bool {
      guard index >= 0, index < string.length,
        let scalar = Unicode.Scalar(string.character(at: index))
      else { return false }
      return scalar.isASCII
        && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
          || scalar == "_")
    }
    var found: [NSRange] = []
    for word in words where !word.isEmpty {
      var search = NSRange(location: 0, length: string.length)
      while search.length > 0 {
        let range = string.range(of: word, options: .literal, range: search)
        guard range.location != NSNotFound else { break }
        if !isWordCharacter(range.location - 1), !isWordCharacter(range.upperBound) {
          found.append(range)
        }
        search = NSRange(location: range.upperBound, length: string.length - range.upperBound)
      }
    }
    var result: [NSRange] = []
    for range in found.sorted(by: {
      $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
    }) where result.last.map({ $0.upperBound <= range.location }) ?? true {
      result.append(range)
    }
    return result
  }

  // MARK: 出图

  /// 合成：先从原图量出每段的基线、行距和行内代码块，再排版；然后把原文的字从图上去掉（只换字的像素，
  /// 有代码块的段连底框一起换掉），按原文的字色把译文画上去，代码词在新位置重画底框
  @concurrent static func render(
    _ image: CGImage, segments: [Segment], translations: [String]
  ) async -> CGImage? {
    guard let context = canvas(like: image), let space = context.colorSpace,
      let data = context.data
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    // 直接在画布的像素上改（画布自己的色彩空间，不来回换算）；判断用原图那份，改过的段不影响后面的段
    let pixels = Pixels(
      data: data.assumingMemoryBound(to: UInt8.self), width: context.width,
      height: context.height, bytesPerRow: context.bytesPerRow)
    let original = pixels.snapshot()
    let measured = segments.map { measure($0, in: original) }
    let size = CGSize(width: image.width, height: image.height)
    let spans = Self.spans(segments: measured, translations: translations, imageSize: size)
    guard !spans.isEmpty else { return nil }
    var colors: [RGB] = []
    for span in spans {
      let background = original.ring(around: span.erase) ?? .light
      let ink = pixels.inpaint(
        span.erase, from: original, lineHeight: span.lineHeight, background: background,
        clearFills: span.code != nil)
      colors.append(textColor(ink: ink, background: background))
    }
    context.setShouldAntialias(true)
    func cgColor(_ color: RGB) -> CGColor? {
      CGColor(colorSpace: space, components: [color.red, color.green, color.blue, 1])
    }
    for (span, color) in zip(spans, colors) {
      guard let body = cgColor(color) else { continue }
      drawText(span, color: body, code: span.code?.text.flatMap(cgColor) ?? body, in: context) {
        cgColor($0)
      }
    }
    return context.makeImage()
  }

  /// 从原图量一段：每行的基线（第一行的、行距），哪些词在行内代码块里、代码块长什么样
  private static func measure(_ segment: Segment, in original: Snapshot) -> Segment {
    guard hasTranslatableContent(segment.text) else { return segment }
    var result = segment
    let baselines = original.baselines(in: segment.box, lineHeight: segment.lineHeight)
    result.baseline = baselines.first
    if baselines.count > 1 {
      let steps = zip(baselines, baselines.dropFirst()).map { $0 - $1 }.sorted()
      result.pitch = steps[steps.count / 2]
    }
    let background = original.ring(around: segment.box) ?? .light
    result.code = original.code(
      words: segment.words, baselines: baselines, lineHeight: segment.lineHeight,
      background: background)
    return result
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

  /// 字色：原文的字色（灰字还是灰字、白标题还是白的）；取不到、或者和底色太接近（看不清）时按底色深浅用近黑 / 近白
  private static func textColor(ink: RGB?, background: RGB) -> RGB {
    if let ink, abs(ink.luminance - background.luminance) >= 0.3 { return ink }
    return background.luminance > 0.55
      ? RGB(red: 0.08, green: 0.08, blue: 0.09) : RGB(red: 0.97, green: 0.97, blue: 0.97)
  }

  /// 一行行画在原文的行上：第一行的基线和原文第一行齐平，往下每行隔一个原文的行距。
  /// 先把这一段所有代码词的底框画完再画字：底框比行高，后画的底框会压住上一行字的下伸部
  private static func drawText(
    _ span: Span, color: CGColor, code codeColor: CGColor, in context: CGContext,
    _ cgColor: (RGB) -> CGColor?
  ) {
    context.saveGState()
    context.textMatrix = .identity
    let lines = lines(
      of: span.text, width: span.frame.width, fontSize: span.fontSize, color: color,
      code: span.code, codeColor: codeColor)
    if let code = span.code, let fill = cgColor(code.fill) {
      let ranges = codeRanges(in: span.text, words: code.words)
      for (index, item) in lines.enumerated() {
        let baseline = span.baseline - CGFloat(index) * span.pitch
        let lineRange = CTLineGetStringRange(item.line)
        for range in ranges {
          let start = max(range.location, lineRange.location)
          let end = min(range.upperBound, lineRange.location + lineRange.length)
          guard end > start else { continue }
          let x0 = span.frame.minX + item.x + CTLineGetOffsetForStringIndex(item.line, start, nil)
          let x1 = span.frame.minX + item.x + CTLineGetOffsetForStringIndex(item.line, end, nil)
          let padding = code.padding * span.scale
          let rect = CGRect(
            x: x0 - padding, y: baseline - code.below * span.scale,
            width: x1 - x0 + 2 * padding, height: (code.above + code.below) * span.scale)
          let radius = min(rect.height / 2, rect.height * 0.24)
          context.addPath(
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
          context.setFillColor(fill)
          context.fillPath()
          if let border = code.border.flatMap(cgColor), code.borderWidth > 0 {
            let inset = rect.insetBy(dx: code.borderWidth / 2, dy: code.borderWidth / 2)
            context.addPath(
              CGPath(
                roundedRect: inset, cornerWidth: max(0, radius - code.borderWidth / 2),
                cornerHeight: max(0, radius - code.borderWidth / 2), transform: nil))
            context.setStrokeColor(border)
            context.setLineWidth(code.borderWidth)
            context.strokePath()
          }
        }
      }
    }
    if let marker = span.marker,
      let string = attributed(marker, fontSize: span.fontSize, color: color, code: nil)
    {
      context.textPosition = CGPoint(x: span.source.minX, y: span.baseline)
      CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    for (index, item) in lines.enumerated() {
      context.textPosition = CGPoint(
        x: span.frame.minX + item.x, y: span.baseline - CGFloat(index) * span.pitch)
      CTLineDraw(item.line, context)
    }
    context.restoreGState()
  }

  /// 系统 UI 字体（中文系统上是苹方、西文是 SF）：译文可能是任何语言，不挑字体，系统字体覆盖最广
  private static func font(size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(.system, size, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
  }

  /// 代码词的等宽字体（SF Mono / Menlo）
  private static func monospacedFont(size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
      ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
  }

  /// 字色：够浓的字像素里出现最多的颜色。抗锯齿的边缘是字色和底色的混合，散在各处、凑不成多数；
  /// 门槛只取最浓那个的一半：最浓的常常是混进来的行内代码块里的白字，门槛按它定高了，正文的灰字会被筛掉
  private static func dominant(_ samples: [(distance: CGFloat, color: RGB)]) -> RGB? {
    guard let strongest = samples.map(\.distance).max() else { return nil }
    var counts: [Int: (count: Int, red: CGFloat, green: CGFloat, blue: CGFloat)] = [:]
    for sample in samples where sample.distance >= max(inkThreshold, strongest * 0.5) {
      let c = sample.color
      let key = Int(c.red * 15) << 8 | Int(c.green * 15) << 4 | Int(c.blue * 15)
      let old = counts[key] ?? (0, 0, 0, 0)
      counts[key] = (old.count + 1, old.red + c.red, old.green + c.green, old.blue + c.blue)
    }
    guard let best = counts.values.max(by: { $0.count < $1.count }) else { return nil }
    let n = CGFloat(best.count)
    return RGB(red: best.red / n, green: best.green / n, blue: best.blue / n)
  }

  // MARK: 像素

  /// 画布的像素（RGBA 各 8 位、预乘、画布自己的色彩空间）。行 0 是图像的顶部，坐标按左下原点换算
  private struct Pixels {
    let data: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    /// 改之前的一份拷贝：判断哪些是字、取底色都看它
    func snapshot() -> Snapshot {
      Snapshot(
        bytes: Array(UnsafeBufferPointer(start: data, count: bytesPerRow * height)),
        width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// 把范围里原文的字去掉，返回原文的字色（取不到 nil）。做法：
    /// ① 每一小块（边长约一个行高）出现最多的颜色当这一块的底色（行内代码块里的块是代码块的底，外面的是页面底）；
    /// ② 和所在小块的底色差过 inkThreshold 的像素算字（clearFills 时和页面底色有一点不一样的也算：代码块的底框
    ///    要连字一起去掉，在新位置重画），再往外扩一两像素盖住抗锯齿的毛边；
    /// ③ 字的像素用同一行左右、同一列上下最近的非字像素插值补上——底色、渐变、边框都接得上，不会整块抹平。
    /// 字色取页面底上（不在代码块里）的字：浓的那些像素里出现最多的颜色
    func inpaint(
      _ rect: CGRect, from original: Snapshot, lineHeight: CGFloat, background: RGB,
      clearFills: Bool
    ) -> RGB? {
      let x0 = max(0, Int(rect.minX.rounded(.down)))
      let x1 = min(width, Int(rect.maxX.rounded(.up)))
      let y0 = max(0, Int(rect.minY.rounded(.down)))
      let y1 = min(height, Int(rect.maxY.rounded(.up)))
      let w = x1 - x0
      let h = y1 - y0
      guard w > 0, h > 0 else { return nil }
      let modes = original.tileModes(x0: x0, x1: x1, y0: y0, y1: y1, lineHeight: lineHeight)
      // ② 哪些是字；顺手收页面底上的字色
      var ink = [Bool](repeating: false, count: w * h)
      var samples: [(distance: CGFloat, color: RGB)] = []
      for y in y0..<y1 {
        for x in x0..<x1 {
          let color = original.color(x: x, y: y)
          let local = modes.at(x, y)
          let distance = color.distance(to: local)
          if distance > inkThreshold {
            ink[(y - y0) * w + (x - x0)] = true
            if local.distance(to: background) < 0.06 { samples.append((distance, color)) }
          } else if clearFills, color.distance(to: background) > fillThreshold {
            ink[(y - y0) * w + (x - x0)] = true
          }
        }
      }
      let radius = max(1, Int((lineHeight * 0.06).rounded()))
      let mask = Self.dilate(ink, width: w, height: h, radius: radius)
      // ③ 插值补上：横着、竖着各补一遍，取平均
      var fills = [RGB?](repeating: nil, count: w * h)
      for y in 0..<h {
        var x = 0
        while x < w {
          guard mask[y * w + x] else {
            x += 1
            continue
          }
          var end = x
          while end < w, mask[y * w + end] { end += 1 }
          let left = x > 0 ? original.color(x: x0 + x - 1, y: y0 + y) : nil
          let right = end < w ? original.color(x: x0 + end, y: y0 + y) : nil
          for i in x..<end {
            fills[y * w + i] = Self.blend(
              left, right, at: CGFloat(i - x + 1) / CGFloat(end - x + 1))
          }
          x = end
        }
      }
      for x in 0..<w {
        var y = 0
        while y < h {
          guard mask[y * w + x] else {
            y += 1
            continue
          }
          var end = y
          while end < h, mask[end * w + x] { end += 1 }
          let low = y > 0 ? original.color(x: x0 + x, y: y0 + y - 1) : nil
          let high = end < h ? original.color(x: x0 + x, y: y0 + end) : nil
          for i in y..<end {
            let vertical = Self.blend(low, high, at: CGFloat(i - y + 1) / CGFloat(end - y + 1))
            let horizontal = fills[i * w + x]
            let color =
              switch (horizontal, vertical) {
              case (let a?, let b?): Self.blend(a, b, at: 0.5) ?? a
              case (let a?, nil): a
              case (nil, let b?): b
              case (nil, nil): clearFills ? background : modes.at(x0 + x, y0 + i)
              }
            write(color, x: x0 + x, y: y0 + i)
          }
          y = end
        }
      }
      return ScreenshotOverlay.dominant(samples)
    }

    /// 两头的颜色按比例插值；只有一头就用那一头
    private static func blend(_ a: RGB?, _ b: RGB?, at t: CGFloat) -> RGB? {
      switch (a, b) {
      case (let a?, let b?):
        RGB(
          red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
          blue: a.blue + (b.blue - a.blue) * t)
      case (let a?, nil): a
      case (nil, let b?): b
      case (nil, nil): nil
      }
    }

    /// 掩码往外扩 radius 像素（先横后竖，方形）
    private static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
      var rows = [Bool](repeating: false, count: mask.count)
      for y in 0..<height {
        for x in 0..<width where mask[y * width + x] {
          for i in max(0, x - radius)...min(width - 1, x + radius) { rows[y * width + i] = true }
        }
      }
      var result = [Bool](repeating: false, count: mask.count)
      for y in 0..<height {
        for x in 0..<width where rows[y * width + x] {
          for j in max(0, y - radius)...min(height - 1, y + radius) { result[j * width + x] = true }
        }
      }
      return result
    }

    private func write(_ color: RGB, x: Int, y: Int) {
      let offset = (height - 1 - y) * bytesPerRow + x * 4
      // 截图不透明：按不透明写（预乘下 alpha = 255 时就是原值）
      data[offset] = UInt8((color.red * 255).rounded())
      data[offset + 1] = UInt8((color.green * 255).rounded())
      data[offset + 2] = UInt8((color.blue * 255).rounded())
      data[offset + 3] = 255
    }
  }

  /// 每一小块（边长约一个行高）出现最多的颜色：这一块的底色
  private struct TileModes {
    let x0: Int
    let y0: Int
    let tile: Int
    let columns: Int
    let modes: [RGB]

    func at(_ x: Int, _ y: Int) -> RGB { modes[((y - y0) / tile) * columns + (x - x0) / tile] }
  }

  /// 原图像素的拷贝：只读
  private struct Snapshot {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int

    /// y 按左下原点（和框一致）：数据里第 0 行是图像顶部。预乘的除回去；全透明按白算（截图很少有透明）
    func raw(x: Int, y: Int) -> (Int, Int, Int) {
      let offset = (height - 1 - y) * bytesPerRow + x * 4
      let alpha = Int(bytes[offset + 3])
      guard alpha > 4 else { return (255, 255, 255) }
      guard alpha < 255 else {
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
      }
      return (
        min(255, Int(bytes[offset]) * 255 / alpha), min(255, Int(bytes[offset + 1]) * 255 / alpha),
        min(255, Int(bytes[offset + 2]) * 255 / alpha)
      )
    }

    func color(x: Int, y: Int) -> RGB {
      let (r, g, b) = raw(x: x, y: y)
      return RGB(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255)
    }

    func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < width && y >= 0 && y < height }

    /// 一块像素里出现最多的颜色（按 5 位量化分桶，桶里取平均）
    func mode(x0: Int, x1: Int, y0: Int, y1: Int) -> RGB? {
      var counts: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
      for y in max(0, y0)..<min(height, y1) {
        for x in max(0, x0)..<min(width, x1) {
          let (r, g, b) = raw(x: x, y: y)
          let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
          let old = counts[key] ?? (0, 0, 0, 0)
          counts[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
        }
      }
      guard let best = counts.values.max(by: { $0.count < $1.count }) else { return nil }
      let n = CGFloat(best.count) * 255
      return RGB(
        red: CGFloat(best.red) / n, green: CGFloat(best.green) / n, blue: CGFloat(best.blue) / n)
    }

    func tileModes(x0: Int, x1: Int, y0: Int, y1: Int, lineHeight: CGFloat) -> TileModes {
      let tile = max(6, Int(lineHeight.rounded()))
      let columns = (x1 - x0 + tile - 1) / tile
      let rows = (y1 - y0 + tile - 1) / tile
      var modes: [RGB] = []
      modes.reserveCapacity(columns * rows)
      for ty in 0..<rows {
        for tx in 0..<columns {
          modes.append(
            mode(
              x0: x0 + tx * tile, x1: min(x1, x0 + (tx + 1) * tile), y0: y0 + ty * tile,
              y1: min(y1, y0 + (ty + 1) * tile)) ?? .light)
        }
      }
      return TileModes(x0: x0, y0: y0, tile: tile, columns: columns, modes: modes)
    }

    /// 段里每一行字的基线（像素、原点左下，从上往下）：每一排像素数一数有多少字的像素，按空白的排切成一行行，
    /// 每行里字最密的那一截（x 高度那一带）的下沿就是基线。Vision 的行框量不准：带行内代码块的行，框会被代码块撑高
    func baselines(in box: CGRect, lineHeight: CGFloat) -> [CGFloat] {
      let x0 = max(0, Int(box.minX.rounded(.down)))
      let x1 = min(width, Int(box.maxX.rounded(.up)))
      let y0 = max(0, Int(box.minY.rounded(.down)))
      let y1 = min(height, Int(box.maxY.rounded(.up)))
      guard x1 > x0, y1 > y0 else { return [] }
      let modes = tileModes(x0: x0, x1: x1, y0: y0, y1: y1, lineHeight: lineHeight)
      var counts = [Int](repeating: 0, count: y1 - y0)
      for y in y0..<y1 {
        for x in x0..<x1 where color(x: x, y: y).distance(to: modes.at(x, y)) > inkThreshold {
          counts[y - y0] += 1
        }
      }
      guard let peak = counts.max(), peak > 0 else { return [] }
      // 从上往下扫：字的像素不到峰值 1% 的排算空白，把一行行隔开
      var rows: [ClosedRange<Int>] = []
      var top: Int?
      for y in stride(from: y1 - 1, through: y0 - 1, by: -1) {
        let busy = y >= y0 && counts[y - y0] * 100 > peak
        if busy, top == nil { top = y }
        if !busy, let start = top {
          rows.append((y + 1)...start)
          top = nil
        }
      }
      return rows.compactMap { row -> CGFloat? in
        // 太矮的一条（一排下划线、一串点）不算一行
        guard CGFloat(row.count) >= lineHeight * 0.25 else { return nil }
        let densest = row.map { counts[$0 - y0] }.max() ?? 0
        // 最密那一带的下沿：从下往上第一排过了峰值一半的
        guard let bottom = row.first(where: { counts[$0 - y0] * 2 >= densest }) else { return nil }
        return CGFloat(bottom)
      }
    }

    /// 段里哪些词在行内代码块里、代码块长什么样（取第一个量到的）：词框中间那一半出现最多的颜色和页面底不一样，
    /// 而且从词中间往两边走、穿过字和这块底色能走到页面底（被页面底围住的一块，不是整片面板）的，就是代码块。
    /// Vision 给的词框常常比代码块宽一点（`total_comments_addressed` 的框是 95…552、代码块是 103…547），
    /// 所以不从词框边上往外找，留白也按代码块边到第一笔字量
    func code(words: [OCR.Word], baselines: [CGFloat], lineHeight: CGFloat, background: RGB)
      -> Code?
    {
      var found = Set<String>()
      var style: Code?
      let reach = Int(lineHeight.rounded())
      func isFill(_ x: Int, _ y: Int) -> Bool {
        contains(x, y) && color(x: x, y: y).distance(to: background) > fillThreshold
      }
      for word in words {
        let bx0 = Int(word.box.minX.rounded())
        let bx1 = Int(word.box.maxX.rounded())
        let by0 = Int(word.box.minY.rounded())
        let by1 = Int(word.box.maxY.rounded())
        let quarter = (bx1 - bx0) / 4
        guard bx1 - bx0 >= 4, by1 - by0 >= 2,
          let fill = mode(x0: bx0 + quarter, x1: bx1 - quarter, y0: by0, y1: by1),
          fill.distance(to: background) > fillThreshold, fill.distance(to: background) < 0.5
        else { continue }
        let middle = (by0 + by1) / 2
        var left = (bx0 + bx1) / 2
        while left > bx0 - reach, isFill(left - 1, middle) { left -= 1 }
        var right = (bx0 + bx1) / 2
        while right < bx1 + reach, isFill(right, middle) { right += 1 }
        // 走到了上限还没碰到页面底：是一整片面板，不是代码块
        guard left > bx0 - reach, right < bx1 + reach, right - left >= (bx1 - bx0) / 2 else {
          continue
        }
        found.insert(word.text)
        guard style == nil else { continue }
        // 字在代码块里从哪一列到哪一列（列里有和代码块底色差得多的像素）
        func hasInk(_ x: Int) -> Bool {
          (max(0, by0)..<min(height, by1)).contains {
            color(x: x, y: $0).distance(to: fill) > inkThreshold
          }
        }
        var firstInk = left
        while firstInk < right, !hasInk(firstInk) { firstInk += 1 }
        var lastInk = right - 1
        while lastInk > firstInk, !hasInk(lastInk) { lastInk -= 1 }
        // 在字左边（或右边）的留白里竖着量上下沿：那一列没有字
        let probe = firstInk - left >= 2 ? (left + firstInk) / 2 : (lastInk + 1 + right) / 2
        // 先走代码块的底色，再走描边（最多 4 像素）就停：上下两行的代码块常常挨着、共用一条描边
        // （GitHub 列表里一行行都以代码块开头时），不停的话会一路穿进别的行的代码块
        func edge(_ step: Int) -> Int {
          var y = middle
          while abs(y + step - middle) <= reach * 2, isFill(probe, y + step),
            color(x: probe, y: y + step).distance(to: fill) <= 0.02
          {
            y += step
          }
          var rim = 0
          while rim < 4, isFill(probe, y + step),
            color(x: probe, y: y + step).distance(to: fill) > 0.02
          {
            y += step
            rim += 1
          }
          return y
        }
        let top = edge(1)
        let bottom = edge(-1)
        let baseline =
          baselines.first { $0 > CGFloat(bottom) && $0 <= CGFloat(top + 1) }
          ?? word.box.maxY - word.box.height * baselineDrop
        // 描边：最上面一排和底色不一样就是描边，往下数几排一样的就是多宽
        let edge = color(x: probe, y: top)
        var border: RGB?
        var borderWidth: CGFloat = 0
        if edge.distance(to: fill) > 0.02 {
          border = edge
          var y = top
          while y > bottom, color(x: probe, y: y).distance(to: edge) <= 0.03, borderWidth < 4 {
            borderWidth += 1
            y -= 1
          }
        }
        // 代码块里的字色
        var samples: [(distance: CGFloat, color: RGB)] = []
        for y in max(0, by0)..<min(height, by1) {
          for x in firstInk...max(firstInk, lastInk) {
            let c = color(x: x, y: y)
            let distance = c.distance(to: fill)
            if distance > inkThreshold { samples.append((distance, c)) }
          }
        }
        style = Code(
          words: [], fill: fill, border: border, borderWidth: borderWidth,
          text: ScreenshotOverlay.dominant(samples),
          padding: CGFloat(max(0, firstInk - left) + max(0, right - 1 - lastInk)) / 2,
          above: CGFloat(top + 1) - baseline, below: baseline - CGFloat(bottom))
      }
      guard !found.isEmpty, var style else { return nil }
      style.words = found
      return style
    }

    /// 框外一圈的采样，出现最多的那种颜色：原文的底色。不用亮度中位数——列表第一行常常整行都是行内代码块，
    /// 框外那一圈有一大半落在代码块的灰底上，中位数会取成代码块的颜色（2026-11-06 对照微信时撞上的）
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
      var counts: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
      func collect(_ x: Int, _ y: Int) {
        // 框里是原文，不能采；图外也没有
        guard !box.contains(CGPoint(x: x, y: y)), contains(x, y) else { return }
        let (r, g, b) = raw(x: x, y: y)
        let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
        let old = counts[key] ?? (0, 0, 0, 0)
        counts[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
      }
      for x in stride(from: x0, to: x1, by: stepX) {
        collect(x, y0)
        collect(x, y1 - 1)
      }
      for y in stride(from: y0, to: y1, by: stepY) {
        collect(x0, y)
        collect(x1 - 1, y)
      }
      guard let best = counts.values.max(by: { $0.count < $1.count }) else { return nil }
      let n = CGFloat(best.count) * 255
      return RGB(
        red: CGFloat(best.red) / n, green: CGFloat(best.green) / n, blue: CGFloat(best.blue) / n)
    }
  }
}
