// 图片文字识别（Vision，设备端）：剪贴板图片（让截图里的文字能被搜索到）和截图翻译共用。

import Foundation
import Vision

nonisolated enum OCR {
  /// 剪贴板入库文字上限：超大图可能识别出巨量文字（截图翻译不套，翻译那边另有 32KB 上限）
  static let maxCharacters = 4096

  /// 识别失败返回 nil；图里没有文字返回 ""
  @concurrent static func recognizeText(in url: URL) async -> String? {
    guard let observations = try? await request().perform(on: url) else { return nil }
    return String(join(observations).prefix(maxCharacters))
  }

  @concurrent static func recognizeText(in image: CGImage) async -> String? {
    guard let observations = try? await request().perform(on: image) else { return nil }
    return join(observations)
  }

  /// 只开自动识别语种、不给语言提示。实测：写死简中 / 繁中 / 英文会丢日文假名、韩文识别为空、
  /// 俄文变拉丁乱码（PLAN §11 #21）；给第一 / 第二语言作提示，中日韩混排图里日文、韩文整行丢失
  private static func request() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate  // .fast 不支持中日韩
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = []
    return request
  }

  /// 按 Vision 返回的顺序一行一行拼起来（左右分栏时先左栏后右栏）；段落怎么合并交给翻译的「去换行」设置
  private static func join(_ observations: [RecognizedTextObservation]) -> String {
    observations.compactMap {
      $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
  }
}
