// 片段的关键词（片段展开，2026-11-22 拍板页 https://claude.ai/artifact/PNApPJNxAgNG36JcSC1q1B「全部按推荐」，PLAN §10「片段展开」）：
// 在任何 App 里打出关键词，就换成片段的内容。这里只放关键词本身的规矩（纯函数，配单测）：
// - 只收键盘能直接打出来的字：英文字母、数字、符号（可见的 ASCII，不含空格）。拦截认字是按键盘布局给的字（实测：中文输入法
//   下按 ; 拿到的也是 ;），输入法上屏的汉字不经过按键，写进关键词也永远对不上
// - 2–32 个字；大小写严格
// - 两条片段的关键词一样：不让存（Q12）；一个是另一个的开头：提示「打不出那一条」，照样能存（打完立刻展开，短的先展开）。
//   同步来的、重新存成片段的还是可能撞上：展开时用列表里最前（最近用过）的那条，设置页那一行标出来（duplicates）
// - 全是字母或数字的：提示「打普通单词时可能误展开，建议用 ; 开头」（Q5：不强制前缀）

import Foundation

nonisolated enum SnippetKeyword {
  static let minLength = 2
  static let maxLength = 32

  /// 输入框里的字收拾成关键词：去掉首尾空白；空的 nil（= 没有关键词）
  static func normalized(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// 能当关键词：长度够、每个字都是可见的 ASCII（不含空格）
  static func isValid(_ keyword: String) -> Bool {
    (minLength...maxLength).contains(keyword.count)
      && keyword.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
  }

  /// 存不了的原因
  enum Problem: Equatable {
    case tooShort
    case tooLong
    /// 有键盘打不出来的字（汉字、空格、全角符号……）
    case untypeable
    /// 和另一条片段的一样（那一条的叫法）
    case duplicate(String)
  }

  /// 能存、但要提醒的
  enum Warning: Hashable {
    /// 这个是另一条的开头：那一条打不出来（那一条的叫法）
    case hides(String)
    /// 另一条是这个的开头：这一条打不出来（那一条的叫法）
    case hiddenBy(String)
    /// 全是字母或数字：打普通单词时可能误展开
    case plainWord
  }

  /// 别的片段：关键词和叫法（名称，没有就是正文开头）
  struct Other: Equatable {
    var keyword: String
    var title: String
  }

  struct Check: Equatable {
    var problem: Problem?
    var warnings: [Warning] = []
  }

  /// 编辑框里打的这个关键词怎么样（others 不含正在编的这一条）。空的（不设关键词）什么都不说
  static func check(_ raw: String, others: [Other]) -> Check {
    guard let keyword = normalized(raw) else { return Check() }
    if keyword.unicodeScalars.contains(where: { !(0x21...0x7E).contains($0.value) }) {
      return Check(problem: .untypeable)
    }
    if keyword.count < minLength { return Check(problem: .tooShort) }
    if keyword.count > maxLength { return Check(problem: .tooLong) }
    if let same = others.first(where: { $0.keyword == keyword }) {
      return Check(problem: .duplicate(same.title))
    }
    var warnings: [Warning] = []
    if let longer = others.first(where: { $0.keyword.hasPrefix(keyword) }) {
      warnings.append(.hides(longer.title))
    }
    if let shorter = others.first(where: { keyword.hasPrefix($0.keyword) }) {
      warnings.append(.hiddenBy(shorter.title))
    }
    if keyword.allSatisfy({ $0.isLetter || $0.isNumber }) { warnings.append(.plainWord) }
    return Check(warnings: warnings)
  }

  /// 存不了的那句（编辑框下面红字）
  static func message(_ problem: Problem) -> String {
    switch problem {
    case .tooShort: String(localized: "关键词至少 \(minLength) 个字")
    case .tooLong: String(localized: "关键词最多 \(maxLength) 个字")
    case .untypeable: String(localized: "关键词只能用英文字母、数字和符号，不能有空格")
    case .duplicate(let title): String(localized: "和「\(title)」的关键词一样")
    }
  }

  /// 提醒的那句（编辑框下面橙字）
  static func message(_ warning: Warning) -> String {
    switch warning {
    case .hides(let title): String(localized: "打完它就会展开，「\(title)」的关键词打不出来了")
    case .hiddenBy(let title): String(localized: "「\(title)」的关键词是它的开头，打到那里就先展开了")
    case .plainWord: String(localized: "打普通单词时可能误展开，建议用 ; 开头")
    }
  }

  /// 一组片段的关键词里撞上了的（出现不止一次的）：设置页标出来，展开时只有列表里最前那条算数
  static func duplicates(_ keywords: [String]) -> Set<String> {
    var seen = Set<String>()
    return Set(keywords.filter { !seen.insert($0).inserted })
  }

  /// 片段的叫法（提示里说「和「…」重复」）：名称（存在备注里），没有就是正文开头一行
  static func title(note: String?, text: String?) -> String {
    if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
      return String(note.prefix(20))
    }
    let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let head = line.trimmingCharacters(in: .whitespaces)
    return head.count > 20 ? head.prefix(20) + "…" : head
  }
}
