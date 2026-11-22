import CoreGraphics
import ImageIO
import VisionKit

/// 钉图选字和截图识字共用一个实况文本识别器。语种沿用系统默认值，避免只提示中英时漏掉其他文字。
@MainActor enum LiveText {
  private static let analyzer = ImageAnalyzer()

  static func analysis(of image: CGImage) async throws -> ImageAnalysis? {
    guard ImageAnalyzer.isSupported else { return nil }
    return try await analyzer.analyze(
      image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
  }
}
