// 查词（D4，对标 Bob：不单开「词典模式」，原文是单个词时自动出词典信息）：
// - isWord / isPhrase：原文算不算「一个词」——字母文字 1 个词（只含字母、连字符、撇号），中日文 1–4 个字；
//   2–3 个词的（isPhrase）只有系统词典查到同一个词头时才算（sameHeadword，第四轮体检 U2：Sign in、Privacy Policy 不该出词典）；
// - 系统词典：DictionaryServices 的 DCSCopyTextDefinition（公开 C API，查「词典」App 里启用的词典），
//   返回一整行纯文本，这里按实测的格式（词头 音节 | 音标 | 词性 (变形) 1 释义: 例句 | 例句 • 子义项 … PHRASES …）
//   切成词性分组和义项。它会模糊匹配（look up 返回 lookup、give up 返回 give）：词头和原文对不上、
//   又不是变形（ran → run）时一律不要。首查要加载词典（实测最多约 0.3 s），在 @concurrent 里调。
// - 双语词典（「牛津英汉汉英词典」排在最前时，2026-11-05 用户反馈「没排版」）是另一种格式：A. B. 分词性、①② 分义项、
//   ▸ 引出例句、英译中的每个中文释义后面带拼音；汉译英是「词 拼音 词性 释义」。拼音去掉（D2），语域标签和括号里的说明
//   收成义项后面的一句注（D1），短语动词小节不要（D4）。

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
    /// 双语词典的注：语域标签（informal、British）、括号里的义项说明（personal items、指程度）、方括号里的注
    var note: String?
    var examples: [String] = []
  }

  /// 一个读音：双语词典分英音、美音（BrE / AmE），英英词典和汉语拼音不分（accent 为 nil）
  struct Phonetic: Equatable, Sendable {
    enum Accent: Sendable { case uk, us }
    var accent: Accent?
    var text: String
  }

  var headword: String
  /// 查的是变形时（ran → run）原文的那个词；和词头一样时为 nil
  var query: String?
  var phonetic: String?
  var groups: [Group]

  var senseCount: Int { groups.reduce(0) { $0 + $1.senses.count } }
  var phonetics: [Phonetic] { phonetic.map(WordLookup.phonetics) ?? [] }
}

nonisolated enum WordLookup {
  /// 原文算不算「一个词」（查词：系统词典、大模型的单词模式）：字母文字 1 个词、中日文 1–4 个字
  static func isWord(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, text.unicodeScalars.allSatisfy(isCJK) { return (1...4).contains(text.count) }
    return words(text)?.count == 1
  }

  /// 字母文字 2–3 个词（ice cream、look up）：要系统词典查到同一个词头（sameHeadword）才算查词（U2）
  static func isPhrase(_ text: String) -> Bool {
    (2...3).contains(words(text)?.count ?? 0)
  }

  /// 词典查到的是不是这个词组本身（不分大小写、多个空格算一个）：look up 查到 lookup、Sign in 查到 sign 都不算
  static func sameHeadword(_ entry: DictionaryEntry, _ text: String) -> Bool {
    func normalized(_ text: String) -> String {
      text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return entry.query == nil && normalized(entry.headword) == normalized(text)
  }

  /// 拆成词：一行、≤ 40 字，每个词字母开头、只含字母 / 连字符 / 撇号；不是这样的返回 nil
  private static func words(_ text: String) -> [Substring]? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 40, !text.contains(where: \.isNewline) else { return nil }
    let words = text.split(separator: " ")
    let valid = words.allSatisfy { word in
      word.first?.isLetter == true
        && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
    }
    return valid ? words : nil
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
    " PHRASES ", " PHRASAL VERB", " DERIVATIVES ", " ORIGIN ", " USAGE ", " WORD FAMILY ",
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
      // 汉语：词 拼音 [词性] 释义；双语词典在词后面另写繁体（闰 （閏） rùn …），去掉
      text = text.replacing(/^(\S+) （[^）]*）/) { String($0.output.1) }
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
    let chineseHead = head.unicodeScalars.contains(where: isCJK)
    let groups: [DictionaryEntry.Group]
    if chineseHead {
      // 汉译英的双语词典：拼音后面是英文词性（名字 mínɡzi noun name▸ …）；拼音里的 ɡ 换成普通的 g
      if bilingualStart.firstMatch(
        in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
      {
        phonetic = phonetic?.replacing("ɡ", with: "g")
        groups = bilingualGroups(body, chineseGlosses: false)
      } else {
        groups = chineseGroups(body)
      }
    } else {
      // 英译中的双语词典：正文里有汉字
      groups =
        body.unicodeScalars.contains(where: isCJK)
        ? bilingualGroups(body, chineseGlosses: true) : self.groups(body)
    }
    var entry = DictionaryEntry(headword: headword, phonetic: phonetic, groups: groups)
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
    let senses = parts.map { DictionaryEntry.Sense(definition: $0) }
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

  /// 一个义项：只取主义项（第一个 • 之前），「释义: 例句 | 例句」拆成释义和例句，去掉 [no object] 这类语法标签
  private static func sense(_ raw: String) -> DictionaryEntry.Sense? {
    let main = raw.components(separatedBy: " • ")[0]
    var definition = main
    var examples: [String] = []
    if let colon = main.range(of: ": ") {
      definition = String(main[..<colon.lowerBound])
      // 例句前面也可能挂着语法标签（[no object, with adverbial] : the rumor ran…）
      examples = main[colon.upperBound...].components(separatedBy: " | ").compactMap {
        $0.replacing(/\[[^\]]*\]/, with: "")
          .trimmingCharacters(in: CharacterSet(charactersIn: " .:")).nilIfEmpty
      }
    }
    definition =
      definition
      .replacing(/\[[^\]]*\]/, with: "")
      .replacing(/\s+/, with: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: " :;."))
    guard !definition.isEmpty else { return nil }
    return DictionaryEntry.Sense(definition: definition, examples: examples)
  }

  // MARK: 双语词典（牛津英汉汉英）

  /// 双语词典的英文词性和显示用的中文名（长的在前：transitive verb 要先于 verb 认）
  private static let bilingualPartsOfSpeech: [(english: String, chinese: String)] = [
    ("transitive verb", "及物动词"), ("intransitive verb", "不及物动词"), ("reflexive verb", "反身动词"),
    ("auxiliary verb", "助动词"), ("modal verb", "情态动词"), ("phrasal verb", "短语动词"),
    ("measure word", "量词"), ("noun", "名词"), ("verb", "动词"), ("adjective", "形容词"),
    ("adverb", "副词"), ("pronoun", "代词"), ("preposition", "介词"), ("conjunction", "连词"),
    ("exclamation", "感叹词"), ("interjection", "感叹词"), ("determiner", "限定词"),
    ("abbreviation", "缩略词"), ("prefix", "前缀"), ("suffix", "后缀"), ("numeral", "数词"),
    ("number", "数词"), ("classifier", "量词"), ("particle", "助词"), ("modifier", "修饰语"),
    ("article", "冠词"), ("onomatopoeia", "拟声词"),
  ]

  private static let bilingualPartOfSpeech = try! NSRegularExpression(
    pattern: "\\b(" + bilingualPartsOfSpeech.map(\.english).joined(separator: "|") + ")\\b")

  /// 汉译英词条的正文开头：（A. ）英文词性
  private static let bilingualStart = try! NSRegularExpression(
    pattern: "^(A\\. )?(" + bilingualPartsOfSpeech.map(\.english).joined(separator: "|") + ")\\b")

  /// 读音：双语词典写成「BrE ˈapl, AmE ˈæp(ə)l」（同一种口音有几个读法时只取第一个），别的原样一个
  static func phonetics(_ raw: String) -> [DictionaryEntry.Phonetic] {
    guard raw.contains("BrE ") || raw.contains("AmE ") else {
      return [.init(accent: nil, text: raw)]
    }
    var result: [DictionaryEntry.Phonetic] = []
    for part in raw.components(separatedBy: ", ") {
      let accent: DictionaryEntry.Phonetic.Accent
      if part.hasPrefix("BrE ") {
        accent = .uk
      } else if part.hasPrefix("AmE ") {
        accent = .us
      } else {
        continue
      }
      let text = part.dropFirst(4).trimmingCharacters(in: .whitespaces)
      if !text.isEmpty, !result.contains(where: { $0.accent == accent }) {
        result.append(.init(accent: accent, text: text))
      }
    }
    return result.isEmpty ? [.init(accent: nil, text: raw)] : result
  }

  /// 双语词典的正文：按 A. B. C. 切成词性段（只认从 A 开始依次递增的），每段按 ①② 切义项。
  /// chineseGlosses：释义是中文（英译中）——去拼音、把释义前面的英文语域标签收进注
  private static func bilingualGroups(_ body: String, chineseGlosses: Bool) -> [DictionaryEntry
    .Group]
  {
    lettered(body).compactMap { bilingualGroup($0, chineseGlosses: chineseGlosses) }
  }

  /// 按「A. 」「B. 」…切开；开头不是「A. 」就整段一个
  private static func lettered(_ text: String) -> [String] {
    guard text.hasPrefix("A. ") else { return [text] }
    var parts: [String] = []
    var letter = Character("B")
    var start = text.index(text.startIndex, offsetBy: 3)
    var cursor = start
    while let found = text.range(of: " \(letter). ", range: cursor..<text.endIndex) {
      parts.append(String(text[start..<found.lowerBound]))
      start = found.upperBound
      cursor = found.upperBound
      guard let next = letter.asciiValue.map({ Character(UnicodeScalar($0 + 1)) }) else { break }
      letter = next
    }
    parts.append(String(text[start...]))
    return parts
  }

  /// 一个词性段：词性前面的（to stuff oneself）和后面的语法标签（uncountable、plural children）算变形表一栏
  private static func bilingualGroup(_ chunk: String, chineseGlosses: Bool) -> DictionaryEntry
    .Group?
  {
    var rest = chunk.trimmingCharacters(in: .whitespaces)
    var forms: [String] = []
    var partOfSpeech: String?
    // 词性只在第一个义项、例句、括号、汉字之前找
    let headEnd =
      rest.firstIndex { "①▸(（".contains($0) || $0.unicodeScalars.contains(where: isCJK) }
      ?? rest.endIndex
    let head = String(rest[..<headEnd])
    if let match = bilingualPartOfSpeech.firstMatch(
      in: head, range: NSRange(location: 0, length: (head as NSString).length)),
      let range = Range(match.range, in: head)
    {
      let english = String(head[range])
      partOfSpeech = bilingualPartsOfSpeech.first { $0.english == english }?.chinese ?? english
      let before = tidy(String(head[..<range.lowerBound]))
      if !before.isEmpty { forms.append(before) }
      rest = (String(head[range.upperBound...]) + rest[headEnd...])
        .trimmingCharacters(in: .whitespaces)
      // 只拿掉开头这几种语法标签，后面的字是释义
      while let grammar = rest.prefixMatch(
        of: /(uncountable|countable|singular|plural(?: [A-Za-z'’-]+(?= ))?)\s*/)
      {
        let word = String(grammar.output.1)
        forms.append(
          word == "uncountable"
            ? "不可数"
            : word == "countable"
              ? "可数" : word == "singular" ? "单数" : word.replacing("plural", with: "复数"))
        rest = String(rest[grammar.range.upperBound...])
      }
    }
    var pieces = rest.split(whereSeparator: isCircledNumber).map(String.init)
    if rest.contains(where: isCircledNumber), rest.first.map(isCircledNumber) == false,
      let first = pieces.first, !first.unicodeScalars.contains(where: isCJK)
    {
      // ① 之前还有几个英文字（对整段都适用的标签）：并进变形表那一栏
      let label = tidy(first)
      if !label.isEmpty { forms.append(label) }
      pieces.removeFirst()
    }
    let senses = pieces.compactMap { bilingualSense($0, chineseGlosses: chineseGlosses) }
    guard !senses.isEmpty else { return nil }
    return DictionaryEntry.Group(
      partOfSpeech: partOfSpeech, forms: forms.isEmpty ? nil : forms.joined(separator: "，"),
      senses: senses)
  }

  /// ①–⑳、㉑–㉟、㊱–㊿
  private static func isCircledNumber(_ character: Character) -> Bool {
    guard let value = character.unicodeScalars.first?.value, character.unicodeScalars.count == 1
    else { return false }
    return (0x2460...0x2473).contains(value) || (0x3251...0x325F).contains(value)
      || (0x32B1...0x32BF).contains(value)
  }

  /// 一个义项：▸ 之后是例句；‹…› 搭配词去掉；圆括号 / 方括号里的说明和释义前面的英文标签收成注
  static func bilingualSense(_ raw: String, chineseGlosses: Bool) -> DictionaryEntry.Sense? {
    var parts = raw.components(separatedBy: "▸")
    var text = parts.removeFirst().replacing(/‹[^›]*›/, with: " ")
    let examples = parts.compactMap { tidy($0).nilIfEmpty }
    var notes: [String] = []
    for match in text.matches(of: /\(([^()]*)\)|（([^（）]*)）|\[([^\]]*)\]|［([^］]*)］/) {
      if let note = (match.output.1 ?? match.output.2 ?? match.output.3 ?? match.output.4).map({
        tidy(String($0))
      }), !note.isEmpty {
        notes.append(note)
      }
    }
    text = tidy(text.replacing(/\([^()]*\)|（[^（）]*）|\[[^\]]*\]|［[^］]*］/, with: " "))
    var definition = text
    if chineseGlosses {
      if let firstHan = text.firstIndex(where: { $0.unicodeScalars.contains(where: isCJK) }) {
        // 汉字前面的英文是语域标签（informal、British、US Politics），排在注的最前面
        let labels = tidy(String(text[..<firstHan]))
        if !labels.isEmpty { notes.insert(labels, at: 0) }
        definition = withoutPinyin(String(text[firstHan...]))
          .replacing(/\s*[,，]\s*/, with: "，").replacing(/\s*[;；]\s*/, with: "；")
      } else if let index = notes.firstIndex(where: { $0.unicodeScalars.contains(where: isCJK) }) {
        // 中文释义写在方括号里（[表示不感兴趣或拒绝]）
        definition = notes.remove(at: index)
        if !text.isEmpty { notes.insert(text, at: 0) }
      }
    }
    definition = definition.trimmingCharacters(in: CharacterSet(charactersIn: " ;,；，"))
    if definition.isEmpty, !notes.isEmpty { definition = notes.removeFirst() }
    guard !definition.isEmpty else { return nil }
    return DictionaryEntry.Sense(
      definition: definition, note: notes.isEmpty ? nil : notes.joined(separator: " · "),
      examples: examples)
  }

  /// 去掉汉字后面的拼音（东西 dōngxi、美丽的 měilì de、把…塞进 bǎ… sāijìn）：紧跟在含汉字的词后面、
  /// 一串只由拼音字母组成、至少一个带声调的词。词尾的逗号分号留下
  static func withoutPinyin(_ text: String) -> String {
    let tones = Set("āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜńňǹ")
    let letters = Set("abcdefghijklmnopqrstuvwxyzüɡ…-'’").union(tones)
    var kept: [String] = []
    var run: [(core: String, tail: String)] = []
    func flush(afterHan: Bool) {
      if afterHan, run.contains(where: { $0.core.contains(where: tones.contains) }) {
        // 拼音整串去掉，标点挂回前一个词
        let tail = run.map(\.tail).joined()
        if !tail.isEmpty, let last = kept.indices.last { kept[last] += tail }
      } else {
        kept += run.map { $0.core + $0.tail }
      }
      run = []
    }
    var afterHan = false
    for token in text.split(separator: " ").map(String.init) {
      let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;，；"))
      let tail = String(token.dropFirst(core.count))
      if !core.isEmpty, token.hasPrefix(core), core.lowercased().allSatisfy(letters.contains) {
        run.append((core, tail))
        continue
      }
      flush(afterHan: afterHan)
      kept.append(token)
      afterHan = token.unicodeScalars.contains(where: isCJK)
    }
    flush(afterHan: afterHan)
    return kept.joined(separator: " ")
  }

  /// 空白收成一个、去掉首尾
  private static func tidy(_ text: String) -> String {
    text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
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
