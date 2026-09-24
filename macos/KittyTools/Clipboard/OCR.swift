// 图片文字识别（Vision，设备端）：让截图里的文字能被搜索到。

import Foundation
import Vision

nonisolated enum OCR {
  /// 入库文字上限：超大图可能识别出巨量文字
  static let maxCharacters = 4096

  /// 识别失败返回 nil；图里没有文字返回 ""。语言必须显式指定，否则中文识别不出来
  @concurrent static func recognizeText(in url: URL) async -> String? {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].map(Locale.Language.init)
    guard let observations = try? await request.perform(on: url) else { return nil }
    let lines = observations.compactMap { observation in
      observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
    }
    return String(lines.filter { !$0.isEmpty }.joined(separator: "\n").prefix(maxCharacters))
  }
}
