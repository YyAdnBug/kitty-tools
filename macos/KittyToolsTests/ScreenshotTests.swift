// 截图翻译单测：选区（点）→ 冻结帧像素矩形的换算（各种缩放、y 翻转、夹边），以及 Vision 识别多语种
// （锁住 §11 #21：写死一组语言、或给语言提示时，混排图里日文假名、韩文、俄文会丢）。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct ScreenshotTests {
  private func pixels(_ rect: CGRect, view: CGSize, image: CGSize) -> CGRect {
    RegionSelector.pixelRect(rect, viewSize: view, imageSize: image)
  }

  @Test func pixelRectScalesAndFlips() {
    let view = CGSize(width: 1512, height: 982)
    // 2x：原点左下 → 左上，尺寸翻倍
    #expect(
      pixels(
        CGRect(x: 10, y: 20, width: 100, height: 50), view: view,
        image: CGSize(width: 3024, height: 1964))
        == CGRect(x: 20, y: 1824, width: 200, height: 100))
    // 1x
    #expect(
      pixels(CGRect(x: 0, y: 0, width: 10, height: 10), view: view, image: view)
        == CGRect(x: 0, y: 972, width: 10, height: 10))
    // 非整数缩放（外接屏 1.5x）：向外取整，不丢边上的像素
    #expect(
      pixels(
        CGRect(x: 1, y: 1, width: 3, height: 3), view: CGSize(width: 100, height: 100),
        image: CGSize(width: 150, height: 150))
        == CGRect(x: 1, y: 144, width: 5, height: 5))
  }

  @Test func pixelRectClampsToImage() {
    let size = CGSize(width: 100, height: 100)
    #expect(
      pixels(CGRect(x: 90, y: -5, width: 20, height: 20), view: size, image: size)
        == CGRect(x: 90, y: 85, width: 10, height: 15))
  }

  @Test func recognizesMixedScripts() async throws {
    let image = try Self.render(["中文识别测试", "日本語のテキストです", "한국어 텍스트", "Привет мир", "Hello World"])
    let text = try #require(await OCR.recognizeText(in: image))
    for expected in ["中文识别", "日本語のテキスト", "한국어", "Привет", "Hello"] {
      #expect(text.contains(expected), "没识别出「\(expected)」：\(text)")
    }
  }

  @Test func blankImageHasNoText() async throws {
    let text = await OCR.recognizeText(in: try Self.render([]))
    #expect(text == "")
  }

  /// 白底黑字，一行一段，2x 像素
  static func render(_ lines: [String]) throws -> CGImage {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 120 * max(lines.count, 1),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
    for (index, line) in lines.enumerated() {
      NSAttributedString(
        string: line,
        attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
      ).draw(at: NSPoint(x: 30, y: bitmap.pixelsHigh - 100 - index * 120))
    }
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.cgImage)
  }
}
