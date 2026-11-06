// 截图翻译「原位覆盖」的单测：分段（行框并集成段）、字号拟合（正文统一一个字号）、抹除范围、不压到下一段、
// 邻栏只认整个在右边的；抹除框按像素往外长那一步用合成的小图看像素。真实截图的效果交给手测（HANDTEST）

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
    // 塞得下就按「行高的 0.82 倍」排，不缩
    #expect(abs(span.fontSize - 30 * 0.82) < 0.01)
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
    #expect(spans[0].fontSize < 30 * 0.82)
    // 最多缩到基准的四分之三，再多就借下方的空白（下面没东西，空白够用）：不会一路缩到最小字号
    #expect(spans[0].fontSize >= 30 * 0.82 * 0.75 - 0.01)
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

  /// 列表项：原文的记号会跟着被抹掉，译文得带着它——服务丢了记号就从原文补，`•译文` 补一个空格
  @Test func listItemKeepsItsMarker() {
    let item = segment(
      "• total_comments_evaluated: The number", box: CGRect(x: 69, y: 400, width: 900, height: 40),
      lineHeight: 40)
    let size = CGSize(width: 1000, height: 600)
    let dropped = ScreenshotOverlay.spans(
      segments: [item], translations: ["评论数"], imageSize: size)
    #expect(dropped.first?.text == "• 评论数")
    let tight = ScreenshotOverlay.spans(
      segments: [item], translations: ["•评论数"], imageSize: size)
    #expect(tight.first?.text == "• 评论数")
  }

  /// 抹除框按像素往外长：深色页里行内代码块的底 (22,27,34) 比 Vision 的行框高出一截，顶边那条描边以前会留下来。
  /// 长到外面都是底色就停：隔着空白的另一条线不被抹掉
  @Test func eraseGrowsOverInlineCodeBackground() async throws {
    let width = 400
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
    let page: (CGFloat, CGFloat, CGFloat) = (1, 4, 9)
    fill(CGRect(x: 0, y: 0, width: width, height: height), page)
    // 代码块：比文字框上面高出 10 像素、左右各宽 10 像素，顶上一条 2 像素的浅描边
    fill(CGRect(x: 40, y: 90, width: 260, height: 40), (22, 27, 34))
    fill(CGRect(x: 40, y: 128, width: 260, height: 2), (33, 38, 45))
    // 文字框上方隔着空白的一条线（在外扩上限之外）：不能被抹掉
    fill(CGRect(x: 40, y: 160, width: 260, height: 2), (120, 120, 120))
    let image = try #require(context.makeImage())
    let box = CGRect(x: 50, y: 95, width: 240, height: 25)
    let composed = try #require(
      await ScreenshotOverlay.render(
        image, segments: [segment("inline code", box: box, lineHeight: 25)],
        translations: ["译"]))
    let pixels = try Self.pixels(composed)
    // 代码块的底、描边、左右多出来的那截都抹成了页面底色（避开左上角画字的地方）
    for (x, y) in [(200, 129), (200, 125), (45, 100), (295, 100), (200, 92)] {
      let color = pixels(x, y)
      #expect(
        abs(color.0 - 1) <= 3 && abs(color.1 - 4) <= 3 && abs(color.2 - 9) <= 3,
        "(\(x), \(y)) 是 \(color)")
    }
    #expect(pixels(200, 161).0 > 100)
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
