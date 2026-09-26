// 查词（D4，对标 Bob：不单开「词典模式」，原文是单个词时自动出词典信息）：
// - isWord：原文算不算「一个词」——字母文字 1–3 个词（只含字母、连字符、撇号），中日文 1–4 个字；
// - 系统词典：DictionaryServices 的 DCSCopyTextDefinition（公开 C API，查「词典」App 里启用的词典），
//   返回一整行纯文本，这里按实测的格式（词头 音节 | 音标 | 词性 (变形) 1 释义: 例句 | 例句 • 子义项 … PHRASES …）
//   切成词性分组和义项。它会模糊匹配（look up 返回 lookup、give up 返回 give）：词头和原文对不上、
//   又不是变形（ran → run）时一律不要。首查要加载词典（实测最多约 0.3 s），在 @concurrent 里调。

import CoreServices
import Foundation

/// 系统词典的一条释义（已按词性分组、裁掉短语 / 派生词 / 词源）
nonisolated struct DictionaryEntry: Equatable, Sendable {
  struct Group: Equatable, Sendable {
    /// noun / verb / 名 / 动…；没写词性时为 nil
    var partOfSpeech: String?
    /// 变形表（runs, running; past ran; past participle run）
    var forms: String?
    var senses: [Sense]
  }

  struct Sense: Equatable, Sendable {
    var definition: String
    var example: String?
  }

  var headword: String
  /// 查的是变形时（ran → run）原文的那个词；和词头一样时为 nil
  var query: String?
  var phonetic: String?
  var groups: [Group]

  var senseCount: Int { groups.reduce(0) { $0 + $1.senses.count } }
}

nonisolated enum WordLookup {
  /// 原文算不算「一个词」（查词：系统词典、大模型的单词模式）
  static func isWord(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 40, !text.contains(where: \.isNewline) else { return false }
    if text.unicodeScalars.allSatisfy(isCJK) { return (1...4).contains(text.count) }
    let words = text.split(separator: " ")
    return (1...3).contains(words.count)
      && words.allSatisfy { word in
        word.first?.isLetter == true
          && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
      }
  }

  /// 单词模式提示词里的示例词条（照着示例写比照着说明写稳得多：免费的 glm-4-flash 会把「美 /音标/」这种说明原样抄出来）。
  /// 释义是中文时拿英文词 run 做例子，其它语言拿中文词 苹果 做例子
  static func example(to target: Lang) -> (word: String, entry: String) {
    if target.isSameLanguage(as: .zhHans) {
      return (
        "run",
        """
        美 /rʌn/  英 /rʌn/
        v. 跑；奔跑；运转；经营
        n. 跑步；一段时间；连续
        例：I run every morning. 我每天早上跑步。
        """
      )
    }
    return (
      "苹果",
      """
      píngguǒ
      n. apple; apple tree
      Example: 我每天吃一个苹果。 I eat an apple every day.
      """
    )
  }

  /// 汉字和假名（成语、日文词）
  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
    default: false
    }
  }

  /// 查系统词典（白名单：系统词典查词。首查会加载词典，不在主线程上等）
  @concurrent static func systemDictionary(_ word: String) async -> DictionaryEntry? {
    let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = CFRange(location: 0, length: (text as NSString).length)
    guard let raw = DCSCopyTextDefinition(nil, text as CFString, range)?.takeRetainedValue() else {
      return nil
    }
    return parse(raw as String, query: text)
  }

  // MARK: 解析（纯函数，配单测）

  /// 这些大写小节之后是短语、短语动词、派生词、词源、用法说明：查词卡片不要
  private static let sectionMarkers = [
    " PHRASES ", " PHRASAL VERBS ", " DERIVATIVES ", " ORIGIN ", " USAGE ", " WORD FAMILY ",
    " NOTE ",
  ]

  /// 英文词性（在词条开头，或跟在句末、右括号、音标竖线后面）
  private static let partOfSpeech = try! NSRegularExpression(
    pattern:
      #"(?:^|(?<=[.!?)\]|]\s))(noun|verb|adjective|adverb|exclamation|pronoun|preposition|conjunction|determiner|abbreviation|prefix|suffix|combining form|modal verb|auxiliary verb|contraction|symbol|predeterminer|interjection|article|numeral)(?=\s|$)"#
  )

  /// 汉语词典的词性缩写（跟在拼音后面）
  private static let chinesePartsOfSpeech = [
    "名", "动", "形", "副", "代", "数", "量", "介", "连", "助", "叹", "拟声", "区别", "前缀", "后缀",
  ]

  static func parse(_ raw: String, query: String) -> DictionaryEntry? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for marker in sectionMarkers {
      if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
    }
    let head: String
    var phonetic: String?
    var body: String
    if let bar = text.firstMatch(of: /\|\s*([^|]+?)\s*\|/) {
      // 英文：词头 音节 | 音标 | 正文
      head = String(text[..<bar.range.lowerBound])
      phonetic = String(bar.output.1)
      body = String(text[bar.range.upperBound...])
    } else {
      // 汉语：词 拼音 [词性] 释义
      let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
      guard parts.count >= 2 else { return nil }
      head = parts[0]
      if parts[1].allSatisfy({ $0.isLetter || $0 == "-" || $0 == "·" }),
        parts[1].unicodeScalars.allSatisfy({ !isCJK($0) })
      {
        phonetic = parts[1]
        body = parts.count > 2 ? parts[2] : ""
      } else {
        body = parts.dropFirst().joined(separator: " ")
      }
    }
    // 词头：去掉音节写法（带 ·）和同形词编号（go 1）
    var words = head.split(separator: " ").map(String.init).filter { !$0.contains("·") }
    if let last = words.last, Int(last) != nil { words.removeLast() }
    let headword = words.joined(separator: " ")
    guard !headword.isEmpty else { return nil }
    body = body.trimmingCharacters(in: .whitespaces)
    var entry = DictionaryEntry(
      headword: headword, phonetic: phonetic,
      groups: head.unicodeScalars.contains(where: isCJK) ? chineseGroups(body) : groups(body))
    if headword.lowercased() != query.lowercased() {
      // 变形（ran → run、children → child）：原文出现在第一组的变形表里才算
      guard let forms = entry.groups.first?.forms,
        forms.range(
          of: "\\b\(NSRegularExpression.escapedPattern(for: query))\\b",
          options: [.regularExpression, .caseInsensitive]) != nil
      else { return nil }
      entry.query = query
    }
    guard entry.senseCount > 0 else { return nil }
    return entry
  }

  /// 英文正文按词性切组；没有词性的整段算一组
  private static func groups(_ body: String) -> [DictionaryEntry.Group] {
    let ns = body as NSString
    let matches = partOfSpeech.matches(in: body, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return [group(nil, body)].compactMap { $0 } }
    return matches.enumerated().compactMap { index, match in
      let start = match.range.location + match.range.length
      let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
      return group(
        ns.substring(with: match.range),
        ns.substring(with: NSRange(location: start, length: end - start)))
    }
  }

  /// 一组：开头的括号是变形表（去掉里面的读音），后面按 1 2 3… 切义项
  private static func group(_ partOfSpeech: String?, _ chunk: String) -> DictionaryEntry.Group? {
    var rest = chunk.trimmingCharacters(in: .whitespaces)
    var forms: String?
    if rest.hasPrefix("("), let close = matchingParenthesis(in: rest) {
      forms = String(rest[rest.index(after: rest.startIndex)..<close])
        .replacing(/\|[^|]*\|/, with: "")
        .replacing(/\s+/, with: " ")
        .replacing(" ;", with: ";")
        .trimmingCharacters(in: .whitespaces)
      rest = String(rest[rest.index(after: close)...])
    }
    let senses = numberedParts(rest).compactMap(sense)
    guard !senses.isEmpty else { return nil }
    return DictionaryEntry.Group(partOfSpeech: partOfSpeech, forms: forms, senses: senses)
  }

  /// 汉语：开头是词性缩写就摘出来；义项按 ①② 切（没有就是一条）
  private static func chineseGroups(_ body: String) -> [DictionaryEntry.Group] {
    var rest = body
    var partOfSpeech: String?
    if let label = chinesePartsOfSpeech.first(where: { rest.hasPrefix($0 + " ") }) {
      partOfSpeech = label
      rest = String(rest.dropFirst(label.count + 1))
    }
    let parts = rest.split(whereSeparator: { ("①"..."⑳").contains($0) })
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let senses = parts.map { DictionaryEntry.Sense(definition: $0, example: nil) }
    return senses.isEmpty ? [] : [.init(partOfSpeech: partOfSpeech, forms: nil, senses: senses)]
  }

  /// 按顺序找「1 」「2 」「3 」…切开（只认依次递增的编号，释义里的「398 miles」不会被当成编号）；没有编号就整段一条
  private static func numberedParts(_ text: String) -> [String] {
    var parts: [String] = []
    var number = 1
    var cursor = text.startIndex
    var start: String.Index?
    while let found = text.range(
      of: "(^|\\s)\(number)\\s", options: .regularExpression, range: cursor..<text.endIndex)
    {
      if let start { parts.append(String(text[start..<found.lowerBound])) }
      start = found.upperBound
      cursor = found.upperBound
      number += 1
    }
    if let start { parts.append(String(text[start...])) }
    return parts.isEmpty ? [text] : parts
  }

  /// 一个义项：只取主义项（第一个 • 之前），「释义: 例句 | 例句」拆成释义和第一个例句，去掉 [no object] 这类语法标签
  private static func sense(_ raw: String) -> DictionaryEntry.Sense? {
    let main = raw.components(separatedBy: " • ")[0]
    var definition = main
    var example: String?
    if let colon = main.range(of: ": ") {
      definition = String(main[..<colon.lowerBound])
      // 例句前面也可能挂着语法标签（[no object, with adverbial] : the rumor ran…）
      example =
        String(main[colon.upperBound...].components(separatedBy: " | ")[0])
        .replacing(/\[[^\]]*\]/, with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: " .:")).nilIfEmpty
    }
    definition =
      definition
      .replacing(/\[[^\]]*\]/, with: "")
      .replacing(/\s+/, with: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: " :;."))
    guard !definition.isEmpty else { return nil }
    return DictionaryEntry.Sense(definition: definition, example: example)
  }

  /// 开头「(」对应的「)」（括号可以嵌套）
  private static func matchingParenthesis(in text: String) -> String.Index? {
    var depth = 0
    for index in text.indices {
      switch text[index] {
      case "(": depth += 1
      case ")":
        depth -= 1
        if depth == 0 { return index }
      default: break
      }
    }
    return nil
  }
}

extension String {
  nonisolated fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
