// 截图翻译「原位覆盖」的单测：分段（行框并集成段）、字号拟合（正文统一一个字号）、行距照原文、去字范围、不压到下一段、
// 邻栏只认整个在右边的、列表记号另画、代码词的匹配；去字（只换字的像素）、取原文字色、行内代码块跟着词走
// 用合成的小图看像素。真实截图的效果交给手测（HANDTEST）

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

struct ScreenshotOverlayTests {
  /// 归一化行框（原点左下，和 Vision 一致）：top 是这一行的顶边
  private func line(
    _ text: String, top: CGFloat, width: CGFloat = 0.8, x: CGFloat = 0.1, height: CGFloat = 0.05
  ) -> OCR.Line {
    OCR.Line(text: text, box: CGRect(x: x, y: top - height, width: width, height: height))
  }

  private func segment(
    _ text: String, box: CGRect, lineHeight: CGFloat, lineCount: Int = 1
  ) -> ScreenshotOverlay.Segment {
    ScreenshotOverlay.Segment(box: box, text: text, lineHeight: lineHeight, lineCount: lineCount)
  }

  @Test func segmentsMergeLinesIntoParagraphs() {
    let lines = [
      line("The quick brown fox", top: 0.9),
      line("jumps over the dog", top: 0.83),
      line("A second paragraph", top: 0.6),
    ]
    let segments = ScreenshotOverlay.segments(
      of: lines, imageSize: CGSize(width: 1000, height: 500))
    #expect(segments.count == 2)
    #expect(segments[0].text == "The quick brown fox jumps over the dog")
    // 行框并集换成像素、原点左下（和 Vision 同方向，不翻）
    #expect(abs(segments[0].box.minX - 100) < 0.01)
    #expect(abs(segments[0].box.minY - 390) < 0.01)
    #expect(abs(segments[0].box.width - 800) < 0.01)
    #expect(abs(segments[0].box.height - 60) < 0.01)
    #expect(abs(segments[0].lineHeight - 25) < 0.01)
    #expect(segments[1].text == "A second paragraph")
  }

  @Test func segmentsJoinChineseWithoutSpaces() {
    let lines = [line("敏捷的棕色狐狸", top: 0.9), line("跳过了懒狗", top: 0.83)]
    let segments = ScreenshotOverlay.segments(
      of: lines, imageSize: CGSize(width: 100, height: 100))
    #expect(segments.map(\.text) == ["敏捷的棕色狐狸跳过了懒狗"])
  }

  @Test func shortTranslationKeepsTheOriginalSize() {
    let segment = segment(
      "原文", box: CGRect(x: 100, y: 400, width: 300, height: 30), lineHeight: 30)
    let spans = ScreenshotOverlay.spans(
      segments: [segment], translations: ["短译文"], imageSize: CGSize(width: 800, height: 600))
    #expect(spans.count == 1)
    let span = spans[0]
    // 塞得下就按基准（行高的 fontPerLineHeight 倍）排，不缩
    #expect(abs(span.fontSize - 30 * ScreenshotOverlay.fontPerLineHeight) < 0.01)
    // 文字从原文顶边往下排，抹掉的范围比原文大一圈（盖得住毛边）
    #expect(abs(span.frame.maxY - segment.box.maxY) < 0.01)
    #expect(span.erase.minY < segment.box.minY && span.erase.maxY > segment.box.maxY)
    // 图片底部没有别的东西：可以一直长到图片底边
    #expect(span.frame.minY == 0)
  }

  @Test func longTranslationShrinksInsteadOfOverflowing() {
    let segment = segment(
      "原文", box: CGRect(x: 100, y: 400, width: 300, height: 30), lineHeight: 30)
    let long = String(repeating: "这是一段很长的译文，得折成好几行才放得下。", count: 4)
    let spans = ScreenshotOverlay.spans(
      segments: [segment], translations: [long], imageSize: CGSize(width: 800, height: 600))
    #expect(spans.count == 1)
    let nominal = 30 * ScreenshotOverlay.fontPerLineHeight
    #expect(spans[0].fontSize < nominal)
    // 最多缩到基准的四分之三，再多就借下方的空白（下面没东西，空白够用）：不会一路缩到最小字号
    #expect(spans[0].fontSize >= nominal * 0.75 - 0.01)
    #expect(spans[0].frame.minY < segment.box.minY)
  }

  /// 正文段统一一个字号：行高差不到两成（Vision 的行框高低不齐，带行内代码块的行更高）的都按全图正文的行高；
  /// 明显高的（标题）按自己的
  @Test func bodyParagraphsShareOneFontSize() {
    let segments = [
      segment("A heading", box: CGRect(x: 40, y: 900, width: 400, height: 60), lineHeight: 60),
      segment(
        "First paragraph", box: CGRect(x: 40, y: 700, width: 900, height: 130), lineHeight: 36,
        lineCount: 3),
      segment(
        "Second paragraph", box: CGRect(x: 40, y: 500, width: 900, height: 140), lineHeight: 41,
        lineCount: 3),
      segment("Third", box: CGRect(x: 40, y: 400, width: 900, height: 39), lineHeight: 39),
    ]
    let spans = ScreenshotOverlay.spans(
      segments: segments, translations: ["标题", "第一段", "第二段", "第三段"],
      imageSize: CGSize(width: 1000, height: 1000))
    #expect(spans.count == 4)
    let body = Set(spans.dropFirst().map(\.fontSize))
    #expect(body.count == 1)
    #expect(spans[0].fontSize > (body.first ?? 0) * 1.3)
  }

  /// 2026-11-06 的「二十几像素宽的小字柱」：同一栏里下一段的段框左边界缩进一点、顶边又和本段的底边叠着，
  /// 以前被当成右边的邻栏，宽度截成 24 像素、字号缩到 6.5。只有整个在本段右边的才算邻栏
  @Test func indentedParagraphBelowIsNotANeighbourColumn() {
    let upper = segment(
      "• total_comments_addressed: The number of evaluated comments …",
      box: CGRect(x: 69, y: 364, width: 1160, height: 421), lineHeight: 39, lineCount: 8)
    let lower = segment(
      "max ), comment type (e.g., bug, security …",
      box: CGRect(x: 101, y: 206, width: 1113, height: 193), lineHeight: 40, lineCount: 4)
    let long = String(repeating: "开发者处理过的已评估评论数，", count: 12)
    let spans = ScreenshotOverlay.spans(
      segments: [upper, lower], translations: [long, "评论类型"],
      imageSize: CGSize(width: 1231, height: 1034))
    #expect(spans.count == 2)
    // 宽度只被图片右边界收一点（以前是 24 像素）
    #expect(spans[0].frame.width > upper.box.width * 0.95)
    #expect(spans[0].fontSize == spans[1].fontSize)
  }

  /// 行距照原文：多行的段按自己量出来的行距（基线到基线），一行的段用全图正文的；第一行的基线落在原文第一行的基线上
  @Test func translationFollowsTheOriginalLinePitch() {
    let paragraph = segment(
      "Three lines of text", box: CGRect(x: 40, y: 600, width: 900, height: 142), lineHeight: 40,
      lineCount: 3)
    let single = segment(
      "One line", box: CGRect(x: 40, y: 400, width: 900, height: 40), lineHeight: 40)
    let spans = ScreenshotOverlay.spans(
      segments: [paragraph, single], translations: ["三行", "一行"],
      imageSize: CGSize(width: 1000, height: 1000))
    #expect(spans.count == 2)
    #expect(abs(spans[0].pitch - 51) < 0.01)
    #expect(abs(spans[1].pitch - 51) < 0.01)
    // 没从像素里量基线时按行框估：落在第一行行框里
    #expect(spans[0].baseline < 742 && spans[0].baseline > 742 - 40)
    // 量过的基线、行距优先
    var measured = paragraph
    measured.baseline = 710
    measured.pitch = 49
    let fromPixels = ScreenshotOverlay.spans(
      segments: [measured], translations: ["三行"], imageSize: CGSize(width: 1000, height: 1000))
    #expect(fromPixels.first?.baseline == 710 && fromPixels.first?.pitch == 49)
  }

  /// 列表项：原文的记号会跟着被去掉，所以另画一个——译文里有就用译文的，服务丢了就用原文的；
  /// 正文从原文的正文列起（第二行起的左边界），不和记号挤在一起
  @Test func listItemKeepsItsMarker() {
    var item = segment(
      "• total_comments_evaluated: The number", box: CGRect(x: 69, y: 400, width: 900, height: 91),
      lineHeight: 40, lineCount: 2)
    item.inset = 32
    let size = CGSize(width: 1000, height: 600)
    let dropped = ScreenshotOverlay.spans(
      segments: [item], translations: ["评论数"], imageSize: size)
    #expect(dropped.first?.marker == "•")
    #expect(dropped.first?.text == "评论数")
    #expect(dropped.first?.frame.minX == 101)
    let tight = ScreenshotOverlay.spans(
      segments: [item], translations: ["•评论数"], imageSize: size)
    #expect(tight.first?.marker == "•")
    #expect(tight.first?.text == "评论数")
    // 分段时从第二行起的左边界量出正文列
    let segments = ScreenshotOverlay.segments(
      of: [
        line("• first item", top: 0.9, width: 0.8, x: 0.069),
        line("continues here", top: 0.84, width: 0.7, x: 0.101),
      ], imageSize: CGSize(width: 1000, height: 1000))
    #expect(segments.count == 1)
    #expect(abs(segments[0].inset - 32) < 0.01)
  }

  /// 代码串：前后不连着字母数字下划线才算（`max` 不认进 `maximum`、`max_size`）；重叠的留长的；
  /// 一个代码块里的几个词整串出现才算（单独的 `Copilot` 不算）；不分大小写、换回原文的写法
  @Test func codeSpansMatchWholePhrases() {
    let text = "maximum 和 max、max_size 以及 Total_count：total，授予 View Copilot Metrics 权限的 Copilot"
    let result = ScreenshotOverlay.codeSpans(
      in: text, phrases: [["max"], ["total_count"], ["total"], ["View", "Copilot", "Metrics"]])
    let found = result.ranges.map { (result.text as NSString).substring(with: $0) }
    // 一个代码块里的词之间换成不断行空格（别在行尾折成两截）
    #expect(found == ["max", "total_count", "total", "View\u{00A0}Copilot\u{00A0}Metrics"])
    // 句首被服务改成大写的代码词换回原文的写法，别的字不动
    #expect(result.text.contains("total_count：total") && !result.text.contains("Total_count"))
    #expect(result.text.hasSuffix("权限的 Copilot"))
    // 词之间隔着 `.` `-` 也认（Vision 把 `repos-1-day` 读成 `repos` `1-day`）
    let joined = ScreenshotOverlay.codeSpans(
      in: "每行 repos-1-day 报告", phrases: [["repos", "1-day"]])
    #expect(joined.ranges.map { (joined.text as NSString).substring(with: $0) } == ["repos-1-day"])
  }

  /// 没认出代码块的段（比如整段在一块有颜色的面板上）只去字：底色、底框都留着；
  /// 去字只换字的像素：深色页里行内代码块的底 (22,27,34)、描边都留着，代码块里的白字换成代码块的底色；
  /// 隔着空白的另一条线不动。译文用原文正文的字色（页面底上的灰字），不是一律白字
  @Test func inpaintingKeepsInlineCodeAndTakesTheTextColour() async throws {
    let width = 420
    let height = 200
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    func fill(_ rect: CGRect, _ rgb: (CGFloat, CGFloat, CGFloat)) {
      context.setFillColor(
        CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1))
      context.fill(rect)
    }
    fill(CGRect(x: 0, y: 0, width: width, height: height), (1, 4, 9))
    // 代码块：比文字框上面高出 10 像素，顶上一条 2 像素的浅描边；块里几笔白字
    fill(CGRect(x: 40, y: 90, width: 260, height: 40), (22, 27, 34))
    fill(CGRect(x: 40, y: 128, width: 260, height: 2), (33, 38, 45))
    for x in stride(from: CGFloat(200), to: 290, by: 12) {
      fill(CGRect(x: x, y: 100, width: 4, height: 18), (230, 237, 243))
    }
    // 代码块右边、页面底上的几笔灰字（正文）
    for x in stride(from: CGFloat(320), to: 400, by: 10) {
      fill(CGRect(x: x, y: 100, width: 4, height: 18), (139, 148, 158))
    }
    // 文字框上方隔着空白的一条线：不能被动
    fill(CGRect(x: 40, y: 170, width: 260, height: 2), (120, 120, 120))
    let image = try #require(context.makeImage())
    let box = CGRect(x: 50, y: 95, width: 360, height: 25)
    let composed = try #require(
      await ScreenshotOverlay.render(
        image, segments: [segment("inline code and text", box: box, lineHeight: 25)],
        translations: ["译"]))
    let pixels = try Self.pixels(composed)
    func near(_ color: (Int, Int, Int), _ rgb: (Int, Int, Int)) -> Bool {
      abs(color.0 - rgb.0) <= 4 && abs(color.1 - rgb.1) <= 4 && abs(color.2 - rgb.2) <= 4
    }
    // 白字的地方补成代码块的底，代码块本身、描边都还在（避开左边画译文的地方）
    for (x, y) in [(202, 110), (250, 105), (150, 125), (150, 92)] {
      #expect(near(pixels(x, y), (22, 27, 34)), "(\(x), \(y)) 是 \(pixels(x, y))")
    }
    #expect(near(pixels(150, 129), (33, 38, 45)))
    // 灰字的地方补成页面底；隔着空白的线没动
    #expect(near(pixels(322, 110), (1, 4, 9)), "\(pixels(322, 110))")
    #expect(pixels(150, 171).0 > 100)
    // 译文的字色是原文正文的灰，不是白：译文那几个像素里最亮的也不超过灰字
    var brightest = 0
    for y in 90..<125 { for x in 50..<90 { brightest = max(brightest, pixels(x, y).0) } }
    #expect(brightest > 100 && brightest <= 150, "最亮 \(brightest)")
  }

  /// 行内代码块跟着词走（2026-11-06 用户：底框有的偏移了，微信也没做好）：原来的底框连字一起去掉，
  /// 译文里还留着的代码词在新位置按原来的样子（底色、描边、上下高度）重画底框
  @Test func codeChipFollowsTheWord() async throws {
    let width = 420
    let height = 200
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    func fill(_ rect: CGRect, _ rgb: (CGFloat, CGFloat, CGFloat)) {
      context.setFillColor(
        CGColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1))
      context.fill(rect)
    }
    fill(CGRect(x: 0, y: 0, width: width, height: height), (1, 4, 9))
    // 原来的代码块在右边：底 (22,27,34)，顶上 2 像素的描边，里面几笔白字
    fill(CGRect(x: 250, y: 92, width: 150, height: 38), (22, 27, 34))
    fill(CGRect(x: 250, y: 128, width: 150, height: 2), (33, 38, 45))
    for x in stride(from: CGFloat(262), to: 388, by: 12) {
      fill(CGRect(x: x, y: 100, width: 4, height: 18), (230, 237, 243))
    }
    let image = try #require(context.makeImage())
    var segment = segment(
      "foo_bar here", box: CGRect(x: 20, y: 95, width: 380, height: 30), lineHeight: 25)
    segment.words = [OCR.Word(text: "foo_bar", box: CGRect(x: 260, y: 98, width: 130, height: 26))]
    // 译文里代码词跑到了最前面
    let composed = try #require(
      await ScreenshotOverlay.render(image, segments: [segment], translations: ["foo_bar 在左边"]))
    let pixels = try Self.pixels(composed)
    func near(_ color: (Int, Int, Int), _ rgb: (Int, Int, Int)) -> Bool {
      abs(color.0 - rgb.0) <= 4 && abs(color.1 - rgb.1) <= 4 && abs(color.2 - rgb.2) <= 4
    }
    // 原来的位置：底框和描边都没了，是页面底
    for (x, y) in [(395, 110), (395, 129), (255, 95)] {
      #expect(near(pixels(x, y), (1, 4, 9)), "(\(x), \(y)) 是 \(pixels(x, y))")
    }
    // 新位置（译文最前面，左边留出原来那么宽的边）：代码块的底色
    #expect(near(pixels(14, 120), (22, 27, 34)), "\(pixels(14, 120))")
    // 底框上下和原来一样高：基线（100）下 8 像素到基线上 30 像素
    #expect(near(pixels(16, 97), (22, 27, 34)), "\(pixels(16, 97))")
    #expect(near(pixels(14, 86), (1, 4, 9)))
    #expect(near(pixels(14, 134), (1, 4, 9)))
  }

  /// 读出图里一颗像素的 sRGB 值（0–255），坐标原点左下（和覆盖层的几何一致）
  private static func pixels(_ image: CGImage) throws -> (Int, Int) -> (Int, Int, Int) {
    let width = image.width
    let height = image.height
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    try #require(drawn)
    return { x, y in
      let offset = ((height - 1 - y) * width + x) * 4
      return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
  }

  @Test func frameStopsBeforeTheNextParagraph() {
    let upper = segment(
      "上面的原文", box: CGRect(x: 100, y: 500, width: 300, height: 30), lineHeight: 30)
    let lower = segment(
      "下面的原文", box: CGRect(x: 100, y: 400, width: 300, height: 30), lineHeight: 30)
    let long = String(repeating: "这一段译文很长，会想往下长。", count: 4)
    let spans = ScreenshotOverlay.spans(
      segments: [upper, lower], translations: [long, "下面那段"],
      imageSize: CGSize(width: 800, height: 600))
    #expect(spans.count == 2)
    // 上面那段的排字矩形不会伸进下面那段（留出间隙）
    #expect(spans[0].frame.minY >= lower.box.maxY)
    #expect(spans[0].frame.minY > lower.box.maxY)
  }

  @Test func widenedTranslationStopsBeforeTheNextColumn() {
    // 两列并排、间距很窄：左列放宽译文时不能压到右列，也不该把右列的原文抹掉
    let left = segment(
      "Left column text", box: CGRect(x: 40, y: 300, width: 200, height: 30), lineHeight: 30)
    let right = segment(
      "Right column text", box: CGRect(x: 260, y: 300, width: 200, height: 30), lineHeight: 30)
    let long = String(repeating: "左列这句译文很长，会想往右边放宽。", count: 3)
    let spans = ScreenshotOverlay.spans(
      segments: [left, right], translations: [long, "右边那列"],
      imageSize: CGSize(width: 600, height: 600))
    #expect(spans.count == 2)
    // 左列抹掉的范围整个留在右列原文的左边
    #expect(spans[0].erase.maxX <= right.box.minX)
    #expect(spans[0].frame.maxX <= right.box.minX)
    // 右列自己不受影响
    #expect(abs(spans[1].frame.minX - right.box.minX) < 0.01)
  }

  @Test func eraseCoversTheTranslationWhenItGrowsPastTheParagraph() {
    // 译文比原文多出几行：抹除框要跟着长，不能只盖原文那块（否则白字落到浅底上就看不见了）
    let only = segment(
      "One line", box: CGRect(x: 100, y: 400, width: 300, height: 28), lineHeight: 28)
    let long = String(repeating: "译文比原文长很多，得多占几行。", count: 3)
    let spans = ScreenshotOverlay.spans(
      segments: [only], translations: [long], imageSize: CGSize(width: 800, height: 600))
    #expect(spans.count == 1)
    #expect(spans[0].erase.height > only.box.height + 2)
    // 抹除从原文顶边（含 pad）往下，不能比原文还矮
    #expect(spans[0].erase.maxY >= only.box.maxY)
    #expect(spans[0].erase.minY < only.box.minY)
  }

  @Test func symbolOnlyParagraphsAreNotTranslated() {
    // OCR 会把分隔线认成一行符号：这种段没有可翻的内容，有道网页版会直接回错误码 40
    #expect(!ScreenshotOverlay.hasTranslatableContent("——— ... !!!"))
    #expect(!ScreenshotOverlay.hasTranslatableContent("• • •"))
    #expect(!ScreenshotOverlay.hasTranslatableContent("   "))
    #expect(ScreenshotOverlay.hasTranslatableContent("Order shipped"))
    #expect(ScreenshotOverlay.hasTranslatableContent("订单已发货"))
    #expect(ScreenshotOverlay.hasTranslatableContent("第 12 条"))
  }

  @Test func frameStaysInsideTheImage() {
    let segment = segment(
      "右边贴边的一段", box: CGRect(x: 700, y: 400, width: 90, height: 30), lineHeight: 30)
    let spans = ScreenshotOverlay.spans(
      segments: [segment], translations: ["贴在右边"], imageSize: CGSize(width: 800, height: 600))
    #expect(spans.count == 1)
    #expect(spans[0].frame.maxX <= 800)
    #expect(spans[0].erase.maxX <= 800)
    #expect(spans[0].erase.minY >= 0)
  }

  @Test func emptyTranslationIsSkipped() {
    let segment = segment(
      "原文", box: CGRect(x: 100, y: 400, width: 300, height: 30), lineHeight: 30)
    #expect(
      ScreenshotOverlay.spans(
        segments: [segment], translations: ["   "], imageSize: CGSize(width: 800, height: 600)
      ).isEmpty)
  }
}
