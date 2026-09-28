// 剪贴板入库前的过滤（纯函数，配单测）：排除指定 App（按 bundle ID 精确匹配，体检 A11）、拦截看起来像密钥 / 卡号的文本。
// 密钥规则：
// 1. sk- 后面允许 - 和 _（sk-proj-… / sk-ant-api03-… 也拦）；为防误伤，prefix 前是词边界、token 里有数字；
// 2. bearer 只量 token 本身，文章里提到 bearer token 不会整段丢弃；
// 3. 固定前缀 + 长度的常见密钥（体检 B5）：GitHub、AWS Access Key、Slack、Google API Key、私钥块、JWT，前面要求词边界。
//    跑在 watcher 的轮询里（主线程，文本最多 5 MB）：先在 UTF-8 字节上 memmem 找确切的字面前缀，
//    每处命中只从那里起跑一次锚定的正则（只吃 token 那么长），不对全文跑正则。

import Foundation

enum ClipboardFilter {
  /// 来源 App 的 bundle ID 在排除列表里（精确匹配：填「Code」不会连 Xcode 一起排除）
  static func isExcluded(bundleID: String?, excluded: Set<String>) -> Bool {
    bundleID.map(excluded.contains) ?? false
  }

  /// 默认排除的密码管理器（大多会自己打 ConcealedType 标记，这里兜底）：1Password 8 / 7、Bitwarden、KeePassXC、
  /// 钥匙串访问、macOS 15 自带的「密码」
  static let defaultExcluded = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
  ]

  /// 旧版排除列表（名称或 bundle ID 关键词）换成 bundle ID 列表：含「.」的留下，名称关键词丢掉，再并上默认列表，
  /// 原来的密码管理器防护不会丢
  static func migratedExcluded(_ old: [String]) -> [String] {
    var result = old.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(".") }
    for id in defaultExcluded where !result.contains(id) { result.append(id) }
    return result
  }

  static func looksSensitive(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count >= 8 else { return false }
    return hasToken(in: trimmed, after: "sk-", minLength: 20, allowed: apiKeyCharacters)
      || hasToken(in: trimmed, after: "bearer ", minLength: 24, allowed: bearerCharacters)
      || looksLikeCardNumber(trimmed)
      || hasKnownSecret(trimmed)
  }

  /// 固定前缀的密钥（体检 B5）：needle 是确切的字面前缀，regex 从 needle 处锚定匹配（prefixMatch）
  private static let secretPatterns: [(needle: String, regex: Regex<Substring>)] = {
    let github = /gh[pousr]_[A-Za-z0-9]{36,}/
    return ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"].map { ($0, github) } + [
      ("github_pat_", /github_pat_[A-Za-z0-9_]{60,}/),  // GitHub 细粒度 token
      ("AKIA", /AKIA[0-9A-Z]{16}\b/),  // AWS Access Key ID
      ("xox", /xox[abposr]-[A-Za-z0-9-]{10,}/),  // Slack
      ("AIza", /AIza[0-9A-Za-z_\-]{35}/),  // Google API Key
      ("-----BEGIN ", /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/),  // 私钥块
      ("eyJ", /eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/),  // JWT
    ]
  }()

  /// 前缀前面要是词边界（前一个字节不是 ASCII 字母、数字、下划线；中文等非 ASCII 紧挨着也算边界，
  /// ponytail: 带变音的拉丁字母紧挨着也算边界，和正则 \b 略有出入，真误伤再按字符判断）
  private static func hasKnownSecret(_ text: String) -> Bool {
    var text = text
    text.makeContiguousUTF8()  // 下面按字节偏移取 String.Index 是 O(1)
    let utf8 = text.utf8
    let bytes = Array(utf8)
    for (needle, regex) in secretPatterns {
      let needleBytes = Array(needle.utf8)
      let wordStart = needleBytes[0] != UInt8(ascii: "-")
      var from = 0
      while let offset = Search.firstOffset(of: needleBytes, in: bytes, from: from) {
        from = offset + 1
        if wordStart, offset > 0, isWordByte(bytes[offset - 1]) { continue }
        let start = utf8.index(utf8.startIndex, offsetBy: offset)
        if text[start...].prefixMatch(of: regex) != nil { return true }
      }
    }
    return false
  }

  private static func isWordByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "_"):
      true
    default: false
    }
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
