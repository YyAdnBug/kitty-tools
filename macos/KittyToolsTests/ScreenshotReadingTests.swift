// 英文正文盖回中文的阅读回归：字号、段落边界、Retina 比例，以及离屏生成对照图。
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import KittyTools

struct ScreenshotReadingTests {
  /// 空间足够时允许译文多一行，不能为迁就原文行数先缩字。
  @Test func chineseParagraphKeepsReadableSizeAndParagraphAnchors() throws {
    var first = ScreenshotOverlay.Segment(
      box: CGRect(x: 44, y: 240, width: 580, height: 40),
      text: "The original paragraph spans two lines.",
      lineHeight: 14, lineCount: 2)
    first.pitch = 26
    let second = ScreenshotOverlay.Segment(
      box: CGRect(x: 44, y: 70, width: 580, height: 14), text: "The next paragraph.", lineHeight: 14
    )
    let translation = String(repeating: "请更新工作流程并使用支持的模型。", count: 6)
    let result = ScreenshotOverlay.layout(
      segments: [first, second], translations: [translation, "下一段译文"],
      imageSize: CGSize(width: 677, height: 320))
    #expect(result.leftovers.isEmpty)
    let upper = try #require(result.spans.first)
    let lower = try #require(result.spans.last)
    // 14 像素的英文字面不应被当成 12.6 像素的中文字号。
    #expect(upper.fontSize >= 18 && upper.fontSize <= 22)
    #expect(abs(upper.fontSize - lower.fontSize) < 0.01)
    #expect(upper.frame.minX == first.box.minX)
    #expect(upper.area.maxY == first.box.maxY)
    #expect(upper.area.minY < first.box.minY)  // 多排几行用下方空白，不先缩字号
    #expect(upper.area.minY > second.box.maxY)
    #expect(!upper.area.intersects(lower.area))
  }

  /// 源图是已知字号的四段英文，走真实 Vision 识字和合成，避免只测手填的框。
  /// KITTY_READING_SHOTS 指向临时目录时另存原文和结果；不联网、不截图、不写用户偏好。
  @Test(arguments: [1, 2])
  func englishArticleRendersChineseAtReadableSize(scale: Int) async throws {
    let factor = CGFloat(scale)
    let width = 677 * scale
    let height = 490 * scale
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: factor, y: factor)
    context.setFillColor(CGColor(srgbRed: 1 / 255, green: 4 / 255, blue: 9 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 677, height: 490))
    let paragraphs: [(CGFloat, [String])] = [
      (
        440,
        [
          "Claude Haiku 4.5 will remain available to individual GitHub Copilot subscribers",
          "on annual plans. The deprecation of Claude Haiku 4.5 does not apply to these",
          "customers.",
        ]
      ),
      (
        340,
        [
          "Please update your workflows and integrations to use the supported models",
          "before this date. Under default model enablement, the suggested alternatives are",
          "automatically enabled for Copilot Enterprise and Copilot Business customers",
          "unless an administrator has turned off the global default or explicitly disabled the",
          "model. If you have turned off the global default, you can enable access to the",
          "alternative models through their model policies in Copilot settings.",
        ]
      ),
      (
        163,
        [
          "Once enabled, users will see the model in the Copilot Chat model selector in",
          "supported GitHub Copilot experiences. No action is required to remove the",
          "models after they have been deprecated.",
        ]
      ),
      (
        61,
        [
          "GitHub Enterprise customers with questions or concerns are encouraged to",
          "contact their account team for assistance.",
        ]
      ),
    ]
    for (baseline, lines) in paragraphs {
      for (index, text) in lines.enumerated() {
        let string = NSAttributedString(
          string: text,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
              "Helvetica" as CFString, 16, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
              srgbRed: 139 / 255, green: 148 / 255, blue: 158 / 255, alpha: 1),
          ])
        context.textPosition = CGPoint(x: 44, y: baseline - CGFloat(index) * 26)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
      }
    }
    let source = try #require(context.makeImage())
    let lines = try #require(await OCR.recognizeLines(in: source))
    let segments = ScreenshotOverlay.segments(
      of: lines, imageSize: CGSize(width: width, height: height))
    #expect(segments.count == 4)
    let translations = [
      "Claude Haiku 4.5 将继续为个人 GitHub Copilot 订阅者提供年度计划服务。Claude Haiku 4.5 的弃用不适用于这些客户。",
      "请在此日期之前更新您的工作流程和集成，以使用支持的模型。在默认模型启用下，建议的替代方案会自动为 Copilot Enterprise 和 Copilot Business 客户启用，除非管理员关闭了全局默认设置或明确禁用了该模型。如果您关闭了全局默认设置，可以通过 Copilot 设置中的模型策略启用替代模型的访问权限。",
      "启用后，用户将在受支持的 GitHub Copilot 体验中的 Copilot 聊天模型选择器中看到该模型。模型停用后无需采取任何操作即可移除。",
      "如有疑问或顾虑，GitHub Enterprise 客户可联系其账户团队以获取帮助。",
    ]
    let outcome = await ScreenshotOverlay.render(
      source, segments: segments, translations: translations, pixelsPerPoint: factor)
    #expect(outcome.leftovers.isEmpty)
    let result = try #require(outcome.image)
    #expect(result.width == source.width && result.height == source.height)
    // 真实识字的行高应在原文字面范围内，不能把行距误当成字高。
    #expect(segments.allSatisfy { $0.lineHeight / factor > 10 && $0.lineHeight / factor < 20 })
    if let path = ProcessInfo.processInfo.environment["KITTY_READING_SHOTS"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, image) in [("source", source), ("translated", result)] {
        let url = directory.appendingPathComponent("\(name)-\(scale)x.png")
        let destination = try #require(
          CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
      }
    }
  }
}
