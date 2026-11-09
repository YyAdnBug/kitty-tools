// 启动器的应用别名：一个 App 可以有多个别名（中英文逗号、分号或换行分隔），原名照样能搜。
// 按 bundle id 保存，没有标识的包才退到路径；不改结果 id / target，使用记录、收藏和打开动作仍认原来的 App。
// 设置保存输入原文，匹配时才折叠、去重、转拼音；缺席的 App 留在偏好里，重新安装后继续用。

import Foundation

struct AppAliases {
  static let entryLimit = 256
  /// 和 SettingsArchive.Kind.text 一样，保证编辑出来的设置能导出、同步。
  static let textLimit = 65_536

  let values: [String: String]
  private let aliases: [String: [String]]

  init(text: String = "") {
    let decoded: [String: String]
    if text.count <= Self.textLimit, let data = text.data(using: .utf8),
      let dictionary = try? JSONDecoder().decode([String: String].self, from: data)
    {
      decoded = dictionary.filter {
        !$0.key.isEmpty && $0.key.count <= 4096 && $0.value.count <= Self.entryLimit
      }
    } else {
      decoded = [:]
    }
    values = decoded
    aliases = decoded.mapValues(Self.parse)
  }

  /// 同一个 App 的不同副本共享别名；没有 bundle id 的包按标准化路径认，用户目录缩成 ~。
  static func key(for item: LauncherItem) -> String {
    if let id = item.appBundleID, !id.isEmpty { return "bundle:" + id }
    let path = (item.target as NSString).standardizingPath
    return "path:" + (path as NSString).abbreviatingWithTildeInPath
  }

  static func parse(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n\r"))
      .map { LauncherMatch.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  var count: Int { aliases.values.filter { !$0.isEmpty }.count }

  func text(for item: LauncherItem) -> String { values[Self.key(for: item)] ?? "" }

  /// nil = 超过可保存的长度；不截输入，不丢其它 App（含本机没装的）的配置。
  func setting(_ text: String, for item: LauncherItem) -> String? {
    guard item.kind == .app, text.count <= Self.entryLimit else { return nil }
    var values = values
    values[Self.key(for: item)] = text.isEmpty ? nil : text
    if values.isEmpty { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(values), let result = String(data: data, encoding: .utf8),
      result.count <= Self.textLimit
    else { return nil }
    return result
  }

  /// 只扩充搜索词，不重命名应用；由 LauncherModel 按偏好原文、App 目录变化缓存结果。
  func applying(to item: LauncherItem) -> LauncherItem {
    guard item.kind == .app, let words = aliases[Self.key(for: item)], !words.isEmpty else {
      return item
    }
    var result = item
    for word in words {
      let pinyin = AppCatalog.pinyin(word)
      for name in [word, pinyin?.full].compactMap({ $0 }) where !result.names.contains(name) {
        result.names.append(name)
      }
      for initial in [LauncherMatch.initials(word), pinyin?.initials].compactMap({ $0 })
      where !initial.isEmpty && !result.initials.contains(initial) {
        result.initials.append(initial)
      }
    }
    return result
  }

  func exactlyMatches(_ item: LauncherItem, query: String) -> Bool {
    guard item.kind == .app else { return false }
    let query = LauncherMatch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    return !query.isEmpty && aliases[Self.key(for: item)]?.contains(query) == true
  }
}
