// 图片文字识别（Vision，设备端）：剪贴板图片（让截图里的文字能被搜索到）、截图翻译、识字共用；识字还认二维码 / 条码。
// 分段（体检 A32）：按行框的纵向间距和句末短行切段，段内的行按中日文 / 其它文字的规则接起来；截图翻译总是按段送去翻，
// 识字按设置 › 截图的开关；翻译的「把同一段里的换行接起来」调这里的 joiningLines（纯文本按空行分段），段内接行和识字同一个 joinLine。

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

  /// 截图翻译、识字：带行框的一行行（Vision 顺序，左右分栏时先左栏后右栏）；识别失败 nil、没有文字 []
  @concurrent static func recognizeLines(in image: CGImage) async -> [Line]? {
    guard let observations = try? await request().perform(on: image) else { return nil }
    return observations.compactMap { observation in
      guard
        let text = observation.topCandidates(1).first?.string
          .trimmingCharacters(in: .whitespaces), !text.isEmpty
      else { return nil }
      return Line(text: text, box: observation.boundingBox.cgRect)
    }
  }

  /// 识别出的一行：文字 + 行框（归一化坐标、原点左下，同 Vision）
  struct Line: Equatable, Sendable {
    var text: String
    var box: CGRect
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

  /// 按行框切段（纯函数，配单测）：两种情况断段——① 这一行和上一行的纵向间距大于 1.2 倍中位行高（空了一行、段间距）；
  /// ② 上一行以句末标点结尾、且不到中位行宽的 80%（段落最后一行）。另外往回跳（这一行在上一行上面，换栏）、
  /// 和上一行并排（同一高度的另一块）也断开。ponytail: 不看缩进和左边界（容易误判列表、代码）；
  /// macOS 26 的 RecognizeDocumentsRequest 直接给段落，有 26 测试机再换
  static func paragraphs(_ lines: [Line]) -> [[String]] {
    guard !lines.isEmpty else { return [] }
    let heights = lines.map(\.box.height).sorted()
    let widths = lines.map(\.box.width).sorted()
    let lineHeight = heights[heights.count / 2]
    let lineWidth = widths[widths.count / 2]
    var result: [[String]] = []
    var previous: Line?
    for line in lines {
      if let previous {
        let gap = previous.box.minY - line.box.maxY
        let endsSentence = previous.text.last.map { "。！？.!?".contains($0) } ?? false
        let breaks =
          gap > 1.2 * lineHeight || gap < -0.5 * lineHeight
          || (endsSentence && previous.box.width < 0.8 * lineWidth)
        if breaks { result.append([]) }
      } else {
        result.append([])
      }
      result[result.count - 1].append(line.text)
      previous = line
    }
    return result
  }

  /// 识别结果写成文字：joined = 段内的行接起来、段间用 separator（识字「接起来」开着时 \n，截图翻译 \n\n）；
  /// 不接时一行一行原样（\n）
  static func text(_ lines: [Line], joined: Bool, separator: String = "\n") -> String {
    guard joined else { return lines.map(\.text).joined(separator: "\n") }
    return paragraphs(lines).map { joinLine($0) }.joined(separator: separator)
  }

  /// 纯文本的「把同一段里的换行接起来」（翻译前的预处理）：空行分段（段间换成 paragraphSeparator），
  /// 段内的行按 joinLine 接起来。纯函数，配单测
  static func joiningLines(_ text: String, paragraphSeparator: String = "\n") -> String {
    text.split(separator: /\n[ \t\r]*\n\s*/)
      .map { joinLine($0.split(whereSeparator: \.isNewline)) }
      .filter { !$0.isEmpty }
      .joined(separator: paragraphSeparator)
  }

  /// 同一段里的行接成一行：中日文字之间直接连，其它加一个空格。行尾是紧跟字母的连字符时不加空格：下一行小写开头
  /// 是断开的单词（exam-/ple → example），去掉连字符；大写开头是复合词（State-/Of-the-art），连字符留着
  static func joinLine<S: StringProtocol>(_ lines: [S]) -> String {
    lines.reduce(into: "") { joined, line in
      let line = line.trimmingCharacters(in: .whitespaces)
      guard let last = joined.last, let first = line.first else {
        joined += line
        return
      }
      if last == "-", joined.dropLast().last?.isLetter == true {
        if first.isLowercase { joined.removeLast() }
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

  /// 按 Vision 返回的顺序一行一行拼起来（剪贴板图片的识别文字，只拿来搜索）
  private static func join(_ observations: [RecognizedTextObservation]) -> String {
    observations.compactMap {
      $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
  }
}
