// 启动器的表情与符号搜索：「emoji 词」离线搜中文、英文、关键词和拼音；「emoji 」先列本机最近使用。
// 字符来自 Unicode Emoji 15.1 和 CLDR 46（macos/emoji-catalog.swift 生成），由系统字体绘制；不下载图片、不调用系统选择器。
// ↩ / ⌘↩ 的粘贴和复制走 LauncherModel / Paster；最近使用不进普通启动器常用、不导出不同步。

import Foundation

enum EmojiSearch {
  struct Entry: Decodable, Sendable {
    let glyph: String
    let name: String
    let english: String
    let keywords: [String]
    let pinyin: [String]
  }

  nonisolated static let commandID = "builtin:emoji"
  nonisolated static let promptTarget = "emoji-search"
  static let limit = 50
  static let recentLimit = 24

  /// 包里约四千条文字；只在第一次进入表情搜索时读和折叠，之后按键只折叠输入。
  private static let items: [LauncherItem] = {
    guard let url = Bundle.main.url(forResource: "emoji-catalog", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let entries = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    return entries.map { entry in
      LauncherItem(
        kind: .emoji, target: entry.glyph, title: entry.name, subtitle: entry.english,
        names: ([entry.name, entry.english] + entry.keywords + entry.pinyin).map(
          LauncherMatch.fold),
        payload: entry.glyph)
    }
  }()

  /// 把同一字符的名字串起来做字面粗筛，避免每次按键逐个遍历数万个中英文关键词；顺序与 items 一致。
  private static let terms = items.map { $0.names.joined(separator: "\u{1F}") }

  static var catalog: [LauncherItem] { items }

  /// 单输 emoji 仍是补全提示；必须有空白才进入专用搜索，不截走 emojify 这类普通输入。
  static func request(_ query: String) -> String? {
    let token = query.prefix { !$0.isWhitespace }
    guard token.lowercased() == "emoji", query.dropFirst(token.count).first?.isWhitespace == true
    else { return nil }
    return query.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func promptItems(for query: String) -> (exact: [LauncherItem], partial: [LauncherItem]) {
    let item = LauncherItem(
      kind: .prompt, target: promptTarget, title: "搜索表情与符号…",
      subtitle: "输入「emoji 空格 表情或符号名」，↩ 或 Tab 补全关键词", completion: "emoji ")
    switch LauncherMatch.promptMatch(
      query, keywords: ["emoji"], aliases: ["表情", "表情符号", "符号", "biaoqing", "fuhao"])
    {
    case .exact: return ([item], [])
    case .partial: return ([], [item])
    case nil: return ([], [])
    }
  }

  /// 空查询先列有效的最近使用、再补常用起步项；有查询时所有词都要命中，匹配质量优先、同分最近用过的在前。
  /// ponytail: 约四千条做一次线性粗筛再排序，最多 50 行；字符库扩大或实测按键变慢时再建倒排索引。
  static func search(_ text: String, recent: [String], in catalog: [LauncherItem]? = nil)
    -> [LauncherItem]
  {
    let terms = catalog.map { $0.map { $0.names.joined(separator: "\u{1F}") } } ?? Self.terms
    let catalog = catalog ?? items
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      let byGlyph = Dictionary(
        catalog.map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
      let seeds = ["😀", "😂", "😊", "🥰", "👍", "🙏", "🎉", "❤️", "✅", "🔥", "✨", "🚀"]
      var seen = Set<String>()
      return (recent + seeds).filter { seen.insert($0).inserted }.compactMap { byGlyph[$0] }
    }
    let unwrapped =
      query.count > 2 && query.first == ":" && query.last == ":"
      ? String(query.dropFirst().dropLast()) : query
    let folded = LauncherMatch.fold(unwrapped)
    // CLDR / 词表中的变体符可能不同，直接粘一个字符来找时统一比较；复制出去仍保留原始序列。
    let bare = unwrapped.replacingOccurrences(of: "\u{FE0F}", with: "")
    let tokens = LauncherMatch.tokens(folded)
    var positions: [String: Int] = [:]
    for (index, glyph) in recent.enumerated() where positions[glyph] == nil {
      positions[glyph] = index
    }
    return catalog.enumerated().compactMap { order, item -> (LauncherItem, Double, Int, Int)? in
      let glyphMatch = item.target.replacingOccurrences(of: "\u{FE0F}", with: "") == bare
      guard
        glyphMatch || tokens.allSatisfy({ terms[order].range(of: $0, options: .literal) != nil })
      else { return nil }
      let score =
        item.target == unwrapped ? 120 : glyphMatch ? 110 : LauncherMatch.score(folded, item: item)
      guard score > 0 else { return nil }
      return (item, score, positions[item.target] ?? Int.max, order)
    }
    .sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      if $0.2 != $1.2 { return $0.2 < $1.2 }
      return $0.3 < $1.3
    }
    .prefix(limit).map(\.0)
  }

  /// 本机状态：只记用户实际复制 / 粘贴过的字符；偏好被手动写坏也不重复、不无限增长。
  static func recent(after glyph: String, in recent: [String]) -> [String] {
    var seen = Set<String>()
    return Array(
      ([glyph] + recent).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(recentLimit))
  }

  static func loadRecents(_ defaults: UserDefaults = .standard) -> [String] {
    var seen = Set<String>()
    return Array(
      (defaults.stringArray(forKey: Prefs.launcherRecentEmoji) ?? [])
        .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(recentLimit))
  }
}
