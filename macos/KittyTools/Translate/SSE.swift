// 流式译文的累积与清洗（纯逻辑，配单测）：拼接增量；去掉开头的 <think>…</think>（开标签可能被拆在多个
// 增量里，凑齐前先不显示）；最后去掉整段外面包的一层引号。正文中间出现的同名标签原样保留。

import Foundation

nonisolated struct StreamingText: Sendable {
  private(set) var raw = ""

  mutating func append(_ delta: String) { raw += delta }

  /// 当前可显示的译文；还在思考段里时返回空
  var visible: String {
    var text = Substring(raw)
    let trimmedStart = text.drop { $0.isWhitespace }
    if trimmedStart.hasPrefix("<think>") {
      guard let end = trimmedStart.range(of: "</think>") else { return "" }
      text = trimmedStart[end.upperBound...]
    } else if "<think>".hasPrefix(trimmedStart), !trimmedStart.isEmpty {
      return ""  // 可能是被拆开的开标签，等下一段
    }
    return String(text).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 完成后的最终译文：再去掉外层引号
  var final: String {
    let text = visible
    for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where text.count >= 2 {
      if text.hasPrefix(open), text.hasSuffix(close), !text.dropFirst().dropLast().contains(close) {
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return text
  }
}
