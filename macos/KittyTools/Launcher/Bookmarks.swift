// 启动器的浏览器书签：只读 Chromium 系（Chrome / Edge / Brave）的 Bookmarks JSON，不需要完全磁盘访问
// （Safari 书签要，所以不做）。各浏览器 Default / Profile N 目录；同一网址只留一条。
// 缓存到文件修改时间或开关变了才重读（修旧版 30 秒内不看开关，§11 #40）。

import Foundation

enum Bookmarks {
  struct Browser {
    let name: String
    let prefsKey: String
    /// ~/Library/Application Support 下的目录
    let directory: String
  }

  static let browsers = [
    Browser(name: "Chrome", prefsKey: Prefs.launcherBookmarksChrome, directory: "Google/Chrome"),
    Browser(name: "Edge", prefsKey: Prefs.launcherBookmarksEdge, directory: "Microsoft Edge"),
    Browser(
      name: "Brave", prefsKey: Prefs.launcherBookmarksBrave,
      directory: "BraveSoftware/Brave-Browser"),
  ]

  private static var cache: (signature: String, items: [LauncherItem]) = ("", [])

  /// 启用的浏览器的全部书签（按文件签名缓存）
  static func items() -> [LauncherItem] {
    let files = browsers.filter { UserDefaults.standard.bool(forKey: $0.prefsKey) }.flatMap {
      browser in
      profileFiles(browser).map { (browser, $0) }
    }
    let signature = files.map { browser, url in
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      return "\(url.path)@\(modified)"
    }.joined(separator: "\n")
    if signature == cache.signature { return cache.items }
    var seen = Set<String>()
    var items: [LauncherItem] = []
    for (browser, url) in files {
      guard let data = try? Data(contentsOf: url) else { continue }
      for bookmark in parse(data) where seen.insert(bookmark.url).inserted {
        items.append(item(bookmark, browser: browser.name))
      }
    }
    cache = (signature, items)
    return items
  }

  /// 全部浏览器的书签网址，不看开关（导入旧记录时还原网址大小写用；旧版默认关书签）
  static func allURLs() -> [String] {
    browsers.flatMap(profileFiles).compactMap { try? Data(contentsOf: $0) }.flatMap(parse).map(
      \.url)
  }

  private static func profileFiles(_ browser: Browser) -> [URL] {
    let root = URL.applicationSupportDirectory.appending(path: browser.directory)
    let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return profiles.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
      .map { root.appending(path: "\($0)/Bookmarks") }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Bookmarks JSON → (标题, 网址)。只收书签栏 / 其他书签 / 移动设备书签下的 http(s) 链接。纯函数，配单测
  static func parse(_ data: Data) -> [(title: String, url: String)] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let roots = json["roots"] as? [String: Any]
    else { return [] }
    var result: [(String, String)] = []
    func walk(_ node: [String: Any]) {
      if node["type"] as? String == "url", let url = node["url"] as? String,
        url.hasPrefix("http://") || url.hasPrefix("https://")
      {
        result.append((node["name"] as? String ?? url, url))
      }
      for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
    }
    for key in ["bookmark_bar", "other", "synced"] {
      if let root = roots[key] as? [String: Any] { walk(root) }
    }
    return result
  }

  private static func item(_ bookmark: (title: String, url: String), browser: String)
    -> LauncherItem
  {
    let host = URL(string: bookmark.url)?.host() ?? bookmark.url
    let pinyin = AppCatalog.pinyin(bookmark.title)
    // 网址只拿去掉协议和参数的部分参与匹配
    let bare = bookmark.url.replacing(/^https?:\/\//, with: "").replacing(/[?#].*$/, with: "")
    return LauncherItem(
      kind: .url, target: bookmark.url, title: bookmark.title.isEmpty ? host : bookmark.title,
      subtitle: "书签 · \(browser) · \(host)",
      names: [bookmark.title, bare, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [pinyin?.initials].compactMap { $0 })
  }
}
