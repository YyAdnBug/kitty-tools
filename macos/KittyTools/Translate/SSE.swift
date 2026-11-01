// 流式译文的累积与清洗（纯逻辑，配单测）：拼接增量；去掉开头的 <think>…</think>（开标签可能被拆在多个
// 增量里，凑齐前先不显示）；最后去掉整段外面包的一层引号。正文中间出现的同名标签原样保留。
// isThinking：还在开头的 <think> 段里（卡片据此显示「思考中」扫光，mac-whisker S3）。
// 智谱的原文包在 <原文> 标签里（第四轮体检 E7）：模型照抄出来的首尾标签去掉（流式中凑了一半的也先不显示）。

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
    return Self.strippingSourceTags(String(text).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 去掉首尾的原文标签；开头 / 末尾是还没凑齐的半个标签（「<原」「</原文」）时也先去掉
  static func strippingSourceTags(_ text: String) -> String {
    let (open, close) = Zhipu.sourceTags
    var text = Substring(text)
    if text.hasPrefix(open) {
      text = text.dropFirst(open.count)
    } else if !text.isEmpty, open.hasPrefix(text) {
      return ""
    }
    if text.hasSuffix(close) {
      text = text.dropLast(close.count)
    } else if let partial = (2..<close.count).reversed().first(where: {
      text.hasSuffix(close.prefix($0))
    }) {
      text = text.dropLast(partial)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 还在开头的 <think> 段里（开标签可能还没凑齐），没有可显示的正文
  var isThinking: Bool {
    let trimmedStart = raw.drop { $0.isWhitespace }
    guard !trimmedStart.isEmpty else { return false }
    if trimmedStart.hasPrefix("<think>") { return trimmedStart.range(of: "</think>") == nil }
    return "<think>".hasPrefix(trimmedStart)
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
