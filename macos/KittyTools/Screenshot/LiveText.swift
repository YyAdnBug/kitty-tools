// 系统的实况文本（VisionKit）：钉图上选字、拷贝图中文字（接起来开着、或 Vision 还没准备好时，PR #45）共用一个识别器。
// 识别在系统服务 mediaanalysisd 里跑，本进程只多几 MB（Vision 进程内 +100 MB 上下）。

import CoreGraphics
import ImageIO
import VisionKit

/// ponytail: 语种跟系统默认（实测给提示两头难：只给中英会整行丢韩文，不给时粗体中文标题偶尔认成拉丁字母，Vision 也一样）。
/// 没有超时：系统服务一直不答时拷贝图中文字一直挂着「识别中…」，碰上了再加「几秒没回就退回 Vision」
@MainActor enum LiveText {
  private static let analyzer = ImageAnalyzer()

  static func analysis(of image: CGImage) async throws -> ImageAnalysis? {
    guard ImageAnalyzer.isSupported else { return nil }
    return try await analyzer.analyze(
      image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
  }
}
