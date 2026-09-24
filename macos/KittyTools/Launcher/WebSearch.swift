// 启动器的网页搜索：引擎列表存在 UserDefaults（沿用旧版字段）。首词是某个引擎的关键词时直达那个引擎；
// 否则查询 ≥ 2 字、不是网址 / 路径时追加各启用引擎的兜底项（没有本地结果或查询带空格时放前面）。
// 网页搜索不记使用（§11 #32）。

import Foundation

struct SearchEngine: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  /// 空 = 没有关键词直达
  var keyword: String
  /// {query} 处替换成编码后的搜索词；漏写时追加到末尾
  var urlTemplate: String
  /// 没有本地结果时是否作为兜底（关键词直达不受它影响）
  var enabled: Bool
}

enum WebSearch {
  static let defaults = [
    SearchEngine(
      id: "google", name: "Google", keyword: "",
      urlTemplate: "https://www.google.com/search?q={query}",
      enabled: true),
    SearchEngine(
      id: "bing", name: "Bing", keyword: "", urlTemplate: "https://www.bing.com/search?q={query}",
      enabled: true),
    SearchEngine(
      id: "baidu", name: "百度", keyword: "", urlTemplate: "https://www.baidu.com/s?wd={query}",
      enabled: true),
  ]

  static var engines: [SearchEngine] {
    get {
      UserDefaults.standard.data(forKey: Prefs.launcherWebSearchEngines)
        .flatMap { try? JSONDecoder().decode([SearchEngine].self, from: $0) } ?? defaults
    }
    set {
      UserDefaults.standard.set(
        try? JSONEncoder().encode(newValue), forKey: Prefs.launcherWebSearchEngines)
    }
  }

  /// 「g swift」→ 用关键词为 g 的引擎搜 swift。关键词直达不看 enabled（enabled 只管兜底，和旧版、Alfred 一致）；
  /// 关键词重复时取列表里靠前的
  static func keywordItem(for query: String, engines: [SearchEngine] = engines) -> LauncherItem? {
    let parts = query.trimmingCharacters(in: .whitespaces).split(
      separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2,
      let engine = engines.first(where: {
        !$0.keyword.isEmpty && $0.keyword.lowercased() == parts[0].lowercased()
      })
    else { return nil }
    return item(engine, String(parts[1]))
  }

  static func fallbackItems(for query: String, engines: [SearchEngine] = engines) -> [LauncherItem]
  {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard text.count >= 2 else { return [] }
    return engines.filter(\.enabled).map { item($0, text) }
  }

  static func url(_ engine: SearchEngine, _ text: String) -> String {
    let encoded =
      text.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "=", "?", "#"])) ?? text
    return engine.urlTemplate.contains("{query}")
      ? engine.urlTemplate.replacing("{query}", with: encoded) : engine.urlTemplate + encoded
  }

  private static func item(_ engine: SearchEngine, _ text: String) -> LauncherItem {
    LauncherItem(
      kind: .search, target: url(engine, text), title: "用 \(engine.name) 搜索「\(text)」",
      subtitle: "网页搜索")
  }
}
