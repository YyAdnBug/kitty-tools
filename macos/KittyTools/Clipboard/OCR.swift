// 图片文字识别（Vision，设备端）：剪贴板图片（让截图里的文字能被搜索到）、截图翻译、识字共用；识字还认二维码 / 条码。

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

  /// 二维码 / 条码的内容（有几个返回几个，重复的去掉）。识字时有码优先用码
  @concurrent static func barcodes(in image: CGImage) async -> [String] {
    guard let observations = try? await DetectBarcodesRequest().perform(on: image) else {
      return []
    }
    var seen = Set<String>()
    return observations.compactMap(\.payloadString).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }

  /// 识字的「去换行」：所有行接成一段。中日文字之间直接连，其它加一个空格；行尾连字符断开的英文单词接回去。
  /// ponytail: Vision 按行返回、不分段落，这里整段合成一行；要保留段落得按行框的纵向间距切，有需要再做。纯函数，配单测
  static func joiningLines(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).reduce(into: "") { joined, line in
      let line = line.trimmingCharacters(in: .whitespaces)
      guard let last = joined.last, let first = line.first else {
        joined += line
        return
      }
      if last == "-", first.isLowercase {
        joined.removeLast()
      } else if !(isCJK(last) || isCJK(first)) {
        joined += " "
      }
      joined += line
    }
  }

  /// 汉字、假名、中日文标点和全角符号（韩文词之间本来就有空格，不算）
  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
      switch $0.value {
      case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
      default: false
      }
    }
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
