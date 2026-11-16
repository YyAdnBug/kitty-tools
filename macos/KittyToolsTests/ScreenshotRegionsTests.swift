// 容器边界和控件排版的回归：嵌套同色标签、开放页面、按钮内边距与放不下时不截字。
import CoreGraphics
import Testing

@testable import KittyTools

struct ScreenshotRegionsTests {
  @Test func nestedBadgeUsesItsOwnBoundary() throws {
    var detector = ScreenshotRegions(width: 400, height: 240)
    let panel = CGRect(x: 10, y: 10, width: 380, height: 220)
    let badge = CGRect(x: 290, y: 170, width: 80, height: 40)
    let black = ScreenshotOverlay.RGB(red: 0, green: 0, blue: 0)
    let result = detector.container(
      around: CGRect(x: 306, y: 182, width: 48, height: 16), lineHeight: 16,
      background: black
    ) { x, y in
      let point = CGPoint(x: x, y: y)
      if badge.contains(point) {
        return badge.insetBy(dx: 2, dy: 2).contains(point)
          ? black : ScreenshotOverlay.RGB(red: 0, green: 0.4, blue: 1)
      }
      if panel.contains(point) {
        return panel.insetBy(dx: 2, dy: 2).contains(point)
          ? black : ScreenshotOverlay.RGB(red: 0.4, green: 0.4, blue: 0.4)
      }
      return ScreenshotOverlay.RGB(red: 1, green: 1, blue: 1)
    }
    #expect(try #require(result) == badge.insetBy(dx: 2, dy: 2))
  }

  @Test func openPageHasNoContainer() {
    var detector = ScreenshotRegions(width: 500, height: 300)
    let white = ScreenshotOverlay.RGB(red: 1, green: 1, blue: 1)
    let result = detector.container(
      around: CGRect(x: 50, y: 180, width: 300, height: 30), lineHeight: 30,
      background: white
    ) { _, _ in white }
    #expect(result == nil)
  }

  @Test func controlFitsWithoutCrossingItsBorder() throws {
    let button = CGRect(x: 64, y: 54, width: 98, height: 54)
    let segment = ScreenshotOverlay.Segment(
      box: CGRect(x: 82, y: 73, width: 62, height: 23), text: "Got it", lineHeight: 23,
      container: button)
    let result = ScreenshotOverlay.layout(
      segments: [segment], translations: ["知道了"], imageSize: CGSize(width: 636, height: 400))
    #expect(result.leftovers.isEmpty)
    let span = try #require(result.spans.first)
    #expect(button.insetBy(dx: 8, dy: 4).contains(span.area))
    #expect(abs(span.area.midX - button.midX) < 0.5)
    #expect(abs(span.area.midY - button.midY) < 0.5)
    #expect(span.text == "知道了")
    let tooLong = ScreenshotOverlay.layout(
      segments: [segment], translations: [String(repeating: "长按钮译文", count: 10)],
      imageSize: CGSize(width: 636, height: 400))
    #expect(tooLong.spans.isEmpty && tooLong.leftovers == [0])
  }
}
