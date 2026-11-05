// 截图翻译「原位覆盖」的单测：分段（行框并集成段）、字号拟合、抹除范围、不压到下一段；
// 真实出图要看像素，交给手测（HANDTEST）

import CoreGraphics
import Testing

@testable import KittyTools

struct ScreenshotOverlayTests {
  /// 归一化行框（原点左下，和 Vision 一致）：top 是这一行的顶边
  private func line(
    _ text: String, top: CGFloat, width: CGFloat = 0.8, x: CGFloat = 0.1, height: CGFloat = 0.05
  ) -> OCR.Line {
    OCR.Line(text: text, box: CGRect(x: x, y: top - height, width: width, height: height))
  }

  private func segment(_ text: String, box: CGRect, lineHeight: CGFloat) -> ScreenshotOverlay.Segment {
    ScreenshotOverlay.Segment(box: box, text: text, lineHeight: lineHeight)
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
    #expect(spans[0].fontSize >= 6.5)
  }

  @Test func frameStopsBeforeTheNextParagraph() {
    let upper = segment(
      "上面的原文", box: CGRect(x: 100, y: 500, width: 300, height: 30), lineHeight: 30)
    let lower = segment(
      "下面的原文", box: CGRect(x: 100, y: 400, width: 300, height: 30), lineHeight: 30)
    let long = String(repeating: "这一段译文很长，会想往下长。", count: 4)
    let spans = ScreenshotOverlay.spans(
      segments: [upper, lower], translations: [long, "下面那段"], imageSize: CGSize(width: 800, height: 600))
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
    #expect(!ScreenshotOverlay.worthTranslating("——— ... !!!"))
    #expect(!ScreenshotOverlay.worthTranslating("• • •"))
    #expect(!ScreenshotOverlay.worthTranslating("   "))
    #expect(ScreenshotOverlay.worthTranslating("Order shipped"))
    #expect(ScreenshotOverlay.worthTranslating("订单已发货"))
    #expect(ScreenshotOverlay.worthTranslating("第 12 条"))
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
