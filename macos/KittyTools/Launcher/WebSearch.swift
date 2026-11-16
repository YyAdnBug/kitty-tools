// 启动器的网页搜索与快捷链接：一张列表存在 UserDefaults（字段名已定，改名会丢用户的列表）。网址里有 {query} 的是搜索：
// 「关键词 空格 内容」直达，勾了「兜底」的在没有本地结果时（或设置成总是）列在最后；单输关键词（排最前）
// 或名字的开头（排在本地结果后面，不抢同名 App）时出一条「↩ 补全关键词」的提示。没有 {query} 的是快捷链接（对标 Raycast Quicklinks）：按名字 / 关键词 / 拼音搜到，
// ↩ 打开固定网址（也可以是 / 或 ~ 开头的路径），和书签一样记使用。网页搜索不记使用（§11 #32）。

import Foundation

struct SearchEngine: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  /// 空 = 没有关键词直达
  var keyword: String
  /// {query} 处替换成编码后的搜索词；没有 {query} 就是快捷链接
  var urlTemplate: String
  /// 搜索：没有本地结果时是否作为兜底（关键词直达不受它影响）；快捷链接不看它
  var enabled: Bool

  var isQuicklink: Bool { !urlTemplate.contains("{query}") }

  /// 显示的名字：自带的预设、名字还是存的那个中文名（没改过）时按界面语言翻（「百度」→ Baidu）；改过的、自己加的照存的写。
  /// 存的照旧是中文（拍板 D6：存过就固定，只翻显示；默认列表全 App 一套，不按语言变）
  var displayName: String {
    WebSearch.presetTitle(id: id, name: name).map { String(localized: $0) } ?? name
  }

  /// 搜索用的名字：显示的、存的和中文名的全拼（英文界面里打「百度」「baidu」都找得到）
  var searchNames: [String] {
    let pinyin = AppCatalog.pinyin(name)?.full
    return [displayName, name, pinyin].compactMap { $0 }.map(LauncherMatch.fold)
      .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }
}

enum WebSearch {
  /// 可添加的预置搜索（设置里「添加」菜单）；新装时默认用前 8 个，只有一个兜底（体检 A24：三个同类的通用搜索兜底是
  /// 三行做同一件事）：一般是 Google，地区是中国大陆时是百度（第四轮体检 U8：Google 打不开），别的只走关键词。
  /// 没存过列表的人 engines 取 defaults，会跟着变；改过列表的不变
  static let presets = [
    preset("google", "Google", "g", "https://www.google.com/search?q={query}", fallback: true),
    preset("bing", "Bing", "bing", "https://www.bing.com/search?q={query}"),
    preset("baidu", "百度", "bd", "https://www.baidu.com/s?wd={query}"),
    preset("github", "GitHub", "gh", "https://github.com/search?q={query}"),
    preset("zhihu", "知乎", "zh", "https://www.zhihu.com/search?q={query}"),
    preset("bilibili", "哔哩哔哩", "bili", "https://search.bilibili.com/all?keyword={query}"),
    preset("wikipedia", "维基百科", "wiki", "https://zh.wikipedia.org/w/index.php?search={query}"),
    preset("youtube", "YouTube", "yt", "https://www.youtube.com/results?search_query={query}"),
    preset("maps", "地图", "map", "maps://?q={query}"),
    preset("taobao", "淘宝", "tb", "https://s.taobao.com/search?q={query}"),
    preset("jd", "京东", "jd", "https://search.jd.com/Search?keyword={query}"),
    preset("douban", "豆瓣", "db", "https://www.douban.com/search?q={query}"),
    preset("mdn", "MDN", "mdn", "https://developer.mozilla.org/search?q={query}"),
  ]

  static var defaults: [SearchEngine] { defaults(region: Locale.current.region) }

  /// 按地区给的默认列表（纯函数，单测注入地区）：中国大陆兜底换成百度，仍只有一个
  static func defaults(region: Locale.Region?) -> [SearchEngine] {
    let fallback = region == .chinaMainland ? "baidu" : "google"
    return presets.prefix(8).map { engine in
      var engine = engine
      engine.enabled = engine.id == fallback
      return engine
    }
  }

  /// 中文名的预设在别的语言里怎么写（存的名字还是这个中文名时）；品牌名本来就是英文的、改过名字的是 nil
  static func presetTitle(id: String, name: String) -> LocalizedStringResource? {
    let title = presetName(id)
    return title?.chinese == name ? title : nil
  }

  /// 预设的中文名（函数直接返回：赋给可选值的 switch 表达式里的字只有第一个抽得进目录，第 6 批实测）
  private static func presetName(_ id: String) -> LocalizedStringResource? {
    switch id {
    case "baidu": "百度"
    case "zhihu": "知乎"
    case "bilibili": "哔哩哔哩"
    case "wikipedia": "维基百科"
    case "maps": LocalizedStringResource("search.maps", defaultValue: "地图", comment: "网页搜索的预设：地图")
    case "taobao": "淘宝"
    case "jd": "京东"
    case "douban": "豆瓣"
    default: nil
    }
  }

  private static func preset(
    _ id: String, _ name: String, _ keyword: String, _ url: String, fallback: Bool = false
  ) -> SearchEngine {
    SearchEngine(id: id, name: name, keyword: keyword, urlTemplate: url, enabled: fallback)
  }

  static var engines: [SearchEngine] {
    get { engines(in: .standard) }
    set { setEngines(newValue, in: .standard) }
  }

  static func engines(in defaults: UserDefaults) -> [SearchEngine] {
    defaults.data(forKey: Prefs.launcherWebSearchEngines)
      .flatMap { try? JSONDecoder().decode([SearchEngine].self, from: $0) } ?? Self.defaults
  }

  static func setEngines(_ engines: [SearchEngine], in defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(engines), forKey: Prefs.launcherWebSearchEngines)
  }

  /// 「g swift」→ 用关键词为 g 的搜索搜 swift。关键词直达不看 enabled（enabled 只管兜底，和 Alfred 一致）；
  /// 关键词重复时取列表里靠前的
  static func keywordItem(for query: String, engines: [SearchEngine] = engines) -> LauncherItem? {
    let parts = query.trimmingCharacters(in: .whitespaces).split(
      separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2,
      let engine = engines.first(where: {
        !$0.isQuicklink && !$0.keyword.isEmpty && $0.keyword.lowercased() == parts[0].lowercased()
      })
    else { return nil }
    return item(engine, String(parts[1]))
  }

  static func fallbackItems(for query: String, engines: [SearchEngine] = engines) -> [LauncherItem]
  {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard LauncherMatch.isLongEnough(text) else { return [] }
    return engines.filter { $0.enabled && !$0.isQuicklink }.map { item($0, text) }
  }

  /// ⌃↩ 用的：第一个兜底搜索，没有就第一个搜索
  static func primary(in engines: [SearchEngine] = engines) -> SearchEngine? {
    engines.first { $0.enabled && !$0.isQuicklink } ?? engines.first { !$0.isQuicklink }
  }

  /// 快捷链接：和 App、书签一起参与匹配排序（↩ 打开）
  static func quicklinkItems(engines: [SearchEngine] = engines) -> [LauncherItem] {
    engines.filter(\.isQuicklink).map { engine in
      let pinyin = AppCatalog.pinyin(engine.name)
      let target = engine.urlTemplate.trimmingCharacters(in: .whitespaces)
      let isPath = target.hasPrefix("/") || target.hasPrefix("~")
      return LauncherItem(
        kind: isPath ? .path : .url,
        target: isPath ? (target as NSString).expandingTildeInPath : target,
        title: engine.displayName,
        subtitle: engine.keyword.isEmpty ? target : "\(engine.keyword) · \(target)",
        // 显示的名字也进来（预设改成快捷链接时英文界面打 Baidu 也找得到）
        names: engine.searchNames
          + [engine.keyword].filter { !$0.isEmpty }.map(LauncherMatch.fold),
        initials: [LauncherMatch.initials(engine.name), pinyin?.initials].compactMap { $0 },
        listed: true)
    }
  }

  /// 有关键词的搜索的提示（↩ / Tab 补「关键词 」）：查询正好是关键词（exact，放最前），
  /// 或是名字 / 拼音的开头（≥ 2 个字，放本地结果后面，免得「goo」「git」时抢了 Chrome、GitHub Desktop）
  static func promptItems(for query: String, engines: [SearchEngine] = engines) -> (
    exact: [LauncherItem], partial: [LauncherItem]
  ) {
    let folded = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    var exact: [LauncherItem] = []
    var partial: [LauncherItem] = []
    for engine in engines where !engine.isQuicklink && !engine.keyword.isEmpty {
      let item = LauncherItem(
        kind: .prompt, target: engine.id, title: String(localized: "用 \(engine.displayName) 搜索…"),
        subtitle: String(localized: "输入「\(engine.keyword) 空格 内容」，↩ 或 Tab 补全关键词"),
        completion: engine.keyword + " ")
      let names = engine.searchNames
      if folded == LauncherMatch.fold(engine.keyword) {
        exact.append(item)
      } else if folded.count >= 2, names.contains(where: { $0.hasPrefix(folded) }) {
        partial.append(item)
      }
    }
    return (exact, partial)
  }

  /// 关键词不能用的（值是设置里提示的占用者）：cb 留给剪贴板指令，fy 留给翻译，open / find 留给文件搜索，
  /// 提醒 / tx / remind 留给提醒（2026-11-04，ReminderPhrase.keywords）
  static let reservedKeywords: [String: LocalizedStringResource] = [
    "cb": "剪贴板指令", "fy": "翻译", "open": "文件搜索", "find": "文件搜索", "quit": "系统命令",
    "hide": "系统命令", "forcequit": "系统命令", "eject": "系统命令", "kill": "系统命令",
    "port": "系统命令", "提醒": "提醒", "tx": "提醒", "remind": "提醒",
    // 保持唤醒（插件，2026-11-12，KeepAwakePlan.keywords）
    "awake": "保持唤醒", "保持唤醒": "保持唤醒", "防息屏": "保持唤醒",
  ]

  static func url(_ engine: SearchEngine, _ text: String) -> String {
    let encoded =
      text.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "=", "?", "#"])) ?? text
    return engine.urlTemplate.replacing("{query}", with: encoded)
  }

  static func item(_ engine: SearchEngine, _ text: String) -> LauncherItem {
    LauncherItem(
      kind: .search, target: url(engine, text),
      title: String(localized: "用 \(engine.displayName) 搜索「\(text)」"),
      subtitle: String(localized: "网页搜索"),
      completion: engine.keyword.isEmpty ? nil : "\(engine.keyword) \(text)")
  }
}
