// 文本条目的内容形态（筛选与行图标用），优先级：颜色 > JSON > 链接 > 代码。纯函数，配单测。

import Foundation

nonisolated enum ContentForm: String, CaseIterable, Sendable {
  case color, json, link, code

  var title: String {
    switch self {
    case .color: "颜色"
    case .json: "JSON"
    case .link: "链接"
    case .code: "代码"
    }
  }

  /// 0...1 的 sRGB 分量
  struct RGBA: Equatable, Sendable {
    var red, green, blue, alpha: Double
  }

  static func detect(_ text: String) -> ContentForm? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if color(in: trimmed) != nil { return .color }
    if isJSON(trimmed) { return .json }
    if isWholeLink(trimmed) { return .link }
    if looksLikeCode(trimmed) { return .code }
    return nil
  }

  /// 整段是一个颜色值：#RGB / #RGBA / #RRGGBB / #RRGGBBAA、rgb()/rgba()、hsl()/hsla()
  static func color(in text: String) -> RGBA? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 64 else { return nil }
    if let match = text.wholeMatch(of: /#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})/) {
      var hex = String(match.1)
      if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
      if hex.count == 6 { hex += "ff" }
      guard let value = UInt32(hex, radix: 16) else { return nil }
      let channel = { (shift: UInt32) in Double((value >> shift) & 0xff) / 255 }
      return RGBA(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
    guard let match = text.lowercased().wholeMatch(of: /(rgba?|hsla?)\(([^()]*)\)/) else {
      return nil
    }
    let parts = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let values = parts.compactMap { Double($0.hasSuffix("%") ? String($0.dropLast()) : $0) }
    guard (3...4).contains(parts.count), values.count == parts.count else { return nil }
    let alpha = values.count == 4 ? min(max(values[3], 0), 1) : 1
    if match.1.hasPrefix("rgb") {
      let clamp = { (value: Double) in min(max(value, 0), 255) / 255 }
      return RGBA(
        red: clamp(values[0]), green: clamp(values[1]), blue: clamp(values[2]), alpha: alpha)
    }
    // HSL → RGB
    let hue = values[0].truncatingRemainder(dividingBy: 360) / 360
    let saturation = min(max(values[1], 0), 100) / 100
    let lightness = min(max(values[2], 0), 100) / 100
    let q =
      lightness < 0.5
      ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
    let p = 2 * lightness - q
    let component = { (offset: Double) -> Double in
      var t = hue + offset
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      if t < 1 / 6 { return p + (q - p) * 6 * t }
      if t < 1 / 2 { return q }
      if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
      return p
    }
    return RGBA(red: component(1 / 3), green: component(0), blue: component(-1 / 3), alpha: alpha)
  }

  /// 文本里第一个 http(s) 链接（「在浏览器打开」用）
  static func firstLink(in text: String) -> URL? {
    guard text.utf8.count <= 512_000 else { return nil }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(text.startIndex..., in: text)
    return detector?.matches(in: text, range: range).lazy.compactMap(\.url)
      .first { ["http", "https"].contains($0.scheme?.lowercased()) }
  }

  private static func isWholeLink(_ text: String) -> Bool {
    guard !text.isEmpty, !text.contains(where: \.isWhitespace), text.utf8.count <= 2048,
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
      let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return false }
    return match.range.length == (text as NSString).length
  }

  private static func isJSON(_ text: String) -> Bool {
    guard let first = text.first, first == "{" || first == "[", text.utf8.count <= 512_000 else {
      return false
    }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
  }

  /// ponytail: 关键词 + 符号的粗略启发式，会有漏判误判；够筛选用
  private static func looksLikeCode(_ text: String) -> Bool {
    let sample = String(text.prefix(4000))
    if sample.hasPrefix("#!") { return true }
    let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else { return false }
    let keywordLine =
      /(?m)^\s*(import|export|func|function|class|struct|const|let|var|def|#include|package|public|private|interface|enum|select|insert|update|create|return)\b/
      .ignoresCase()
    if sample.contains(keywordLine) { return true }
    let semicolonLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix(";") }
      .count
    return lines.count >= 3
      && ((sample.contains("{") && sample.contains("}")) || semicolonLines >= 2)
  }
}
