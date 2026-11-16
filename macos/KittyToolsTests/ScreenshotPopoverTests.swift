// 气泡、描边标签和按钮的截图翻译：真实 OCR 识别、排版合成及 1x/2x 离屏出图，不调用翻译服务。
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import KittyTools

struct ScreenshotPopoverTests {
  /// 右上角 New 标签的行距虽接近正文，横向只有少量重叠，必须单独翻译。
  @Test func badgeIsNotJoinedToTheParagraphBelow() {
    let lines = [
      OCR.Line(text: "New", box: CGRect(x: 0.84, y: 0.72, width: 0.08, height: 0.06)),
      OCR.Line(
        text: "Choose whether github.com opens to",
        box: CGRect(x: 0.1, y: 0.62, width: 0.76, height: 0.07)),
      OCR.Line(text: "Home or Feed.", box: CGRect(x: 0.1, y: 0.52, width: 0.72, height: 0.07)),
    ]
    #expect(
      OCR.groups(lines).map { $0.map(\.text) } == [
        ["New"], ["Choose whether github.com opens to", "Home or Feed."],
      ])
  }
  @Test(arguments: [1, 2])
  func popoverPreservesControlsAndTranslatesBadge(scale: Int) async throws {
    let factor = CGFloat(scale)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: 636 * scale, height: 400 * scale, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: factor, y: factor)
    func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
      CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
    context.setFillColor(rgb(13, 17, 23))
    context.fill(CGRect(x: 0, y: 0, width: 636, height: 400))
    func rounded(_ rect: CGRect, radius: CGFloat, fill: CGColor, stroke: CGColor) {
      let path = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
      context.addPath(path)
      context.setFillColor(fill)
      context.fillPath()
      context.addPath(path)
      context.setStrokeColor(stroke)
      context.setLineWidth(2)
      context.strokePath()
    }
    rounded(
      CGRect(x: 30, y: 20, width: 604, height: 338), radius: 12,
      fill: rgb(1, 4, 9), stroke: rgb(61, 68, 77))
    rounded(
      CGRect(x: 524, y: 284, width: 76, height: 38), radius: 19,
      fill: rgb(1, 4, 9), stroke: rgb(47, 129, 247))
    rounded(
      CGRect(x: 64, y: 54, width: 98, height: 54), radius: 12,
      fill: rgb(33, 40, 48), stroke: rgb(61, 68, 77))
    func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool, color: CGColor) {
      let font = CTFontCreateWithName(
        (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
      let string = NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    draw("Pin your homepage", x: 64, y: 294, size: 28, bold: true, color: rgb(230, 237, 243))
    draw("New", x: 538, y: 294, size: 24, bold: false, color: rgb(47, 129, 247))
    for (index, text) in [
      "Choose whether github.com opens to", "Home or Feed. Select the pin next to", "either one.",
    ].enumerated() {
      draw(
        text, x: 64, y: 235 - CGFloat(index) * 42, size: 28, bold: false,
        color: rgb(139, 148, 158))
    }
    draw("Got it", x: 82, y: 73, size: 24, bold: true, color: rgb(230, 237, 243))
    let source = try #require(context.makeImage())
    let lines = try #require(await OCR.recognizeLines(in: source, droppingIcons: true))
    let start = ContinuousClock.now
    let segments = await ScreenshotOverlay.prepareSegments(of: lines, in: source)
    #expect(segments.count == 4, "标题、标签、正文、按钮应分开：\(segments.map(\.text))")
    #expect(
      segments.contains { $0.text.lowercased() == "new" },
      "标签没有被 OCR 识别：\(segments.map(\.text))")
    let translations = segments.map { segment in
      let lower = segment.text.lowercased()
      if lower == "new" { return "新建" }
      if lower.contains("pin your") { return "固定你的主页" }
      if lower.contains("got") { return "知道了" }
      return "选择 github.com 打开时显示主页还是动态内容。在其中一个旁边选择固定选项。"
    }
    let outcome = await ScreenshotOverlay.render(
      source, segments: segments, translations: translations, pixelsPerPoint: factor)
    let elapsed = ContinuousClock.now - start
    #expect(outcome.leftovers.isEmpty, "未排入图内：\(outcome.leftovers.map(\.source))")
    let result = try #require(outcome.image)
    let resultLines = try #require(await OCR.recognizeLines(in: result))
    let recognized = resultLines.map(\.text).joined()
    #expect(recognized.contains("新建"), "译后标签：\(recognized)")
    #expect(recognized.contains("知道了"), "译后按钮：\(recognized)")
    #expect(recognized.contains("github.com"), "正文不能被标题的译文覆盖：\(recognized)")
    // 容器的描边不属于文字：检查标签、按钮和气泡外框的代表像素，不能被去字或译文改动。
    let sourceData = try #require(source.dataProvider?.data) as Data
    let resultData = try #require(result.dataProvider?.data) as Data
    for (x, y) in [(524, 303), (562, 322), (64, 81), (162, 81), (30, 200)] {
      let px = x * scale
      let py = y * scale
      let originalOffset = (source.height - 1 - py) * source.bytesPerRow + px * 4
      let resultOffset = (result.height - 1 - py) * result.bytesPerRow + px * 4
      for channel in 0..<3 {
        #expect(
          abs(Int(sourceData[originalOffset + channel]) - Int(resultData[resultOffset + channel]))
            <= 1)
      }
    }
    if let path = ProcessInfo.processInfo.environment["KITTY_READING_SHOTS"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, image) in [("source", source), ("translated", result)] {
        let destination = try #require(
          CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("popover-\(name)-\(scale)x.png") as CFURL,
            "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
      }
      let report =
        "识别：\(segments.map(\.text))\n未排入：\(outcome.leftovers.map(\.source))\n"
        + "合成耗时：\(elapsed)\n译后 OCR：\(recognized)\n"
      try report.write(
        to: directory.appendingPathComponent("popover-report-\(scale)x.txt"), atomically: true,
        encoding: .utf8)
    }
  }
}
