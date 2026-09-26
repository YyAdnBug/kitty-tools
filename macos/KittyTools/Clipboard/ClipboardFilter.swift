// 剪贴板入库前的过滤（纯函数，配单测）：排除指定 App、拦截看起来像密钥 / 卡号的文本。
// 密钥规则：
// 1. sk- 后面允许 - 和 _（sk-proj-… / sk-ant-api03-… 也拦）；为防误伤，prefix 前是词边界、token 里有数字；
// 2. bearer 只量 token 本身，文章里提到 bearer token 不会整段丢弃。

import Foundation

enum ClipboardFilter {
  /// 来源 App 名称或 bundle ID 包含任一关键词（不区分大小写）即排除
  static func isExcluded(appName: String?, bundleID: String?, excluded: [String]) -> Bool {
    excluded.contains { raw in
      let needle = raw.trimmingCharacters(in: .whitespaces)
      guard !needle.isEmpty else { return false }
      return [appName, bundleID].contains { $0?.localizedCaseInsensitiveContains(needle) == true }
    }
  }

  static func looksSensitive(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count >= 8 else { return false }
    return hasToken(in: trimmed, after: "sk-", minLength: 20, allowed: apiKeyCharacters)
      || hasToken(in: trimmed, after: "bearer ", minLength: 24, allowed: bearerCharacters)
      || looksLikeCardNumber(trimmed)
  }

  /// 整段（去掉空白和连字符后）是 13–19 位数字且通过 Luhn 校验
  static func looksLikeCardNumber(_ text: String) -> Bool {
    // 19 位数字最多配 18 个分隔符；更长的不可能是卡号，也免得对大段文本逐字过滤
    guard text.utf8.count <= 64 else { return false }
    let digits = text.filter { !$0.isWhitespace && $0 != "-" }
    guard (13...19).contains(digits.count), digits.allSatisfy(\.isASCII),
      digits.allSatisfy(\.isNumber)
    else { return false }
    return luhnValid(digits)
  }

  static func luhnValid(_ digits: String) -> Bool {
    var sum = 0
    for (offset, character) in digits.reversed().enumerated() {
      guard var value = character.wholeNumberValue else { return false }
      if offset % 2 == 1 {
        value *= 2
        if value > 9 { value -= 9 }
      }
      sum += value
    }
    return sum % 10 == 0
  }

  private static let apiKeyCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "-_"))
  private static let bearerCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "-_.~+/="))

  /// 任一处 prefix（不区分大小写、前面是词边界）后面紧跟至少 minLength 个 allowed 字符，且其中有数字。
  /// 词边界和「含数字」是放行 - 之后防误伤的：desk-organizer-product-description 这类连字符英文不算密钥
  private static func hasToken(
    in text: String, after prefix: String, minLength: Int, allowed: CharacterSet
  ) -> Bool {
    let scalars = text.unicodeScalars
    var searchStart = text.startIndex
    while let range = text.range(
      of: prefix, options: .caseInsensitive, range: searchStart..<text.endIndex)
    {
      searchStart = range.upperBound
      if range.lowerBound > text.startIndex,
        CharacterSet.alphanumerics.contains(scalars[scalars.index(before: range.lowerBound)])
      {
        continue
      }
      let token = scalars[range.upperBound...].prefix { $0.isASCII && allowed.contains($0) }
      if token.count >= minLength,
        token.contains(where: { CharacterSet.decimalDigits.contains($0) })
      {
        return true
      }
    }
    return false
  }
}
