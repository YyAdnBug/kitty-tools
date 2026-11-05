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
