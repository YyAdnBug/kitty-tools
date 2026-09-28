// 启动器的浏览器书签：只读 Chromium 系（Chrome / Edge / Brave）的书签 JSON，不需要完全磁盘访问
// （Safari 书签要，所以不做）。各浏览器 Default / Profile N 目录；同一网址只留一条。
// 每个目录读两个文件：Bookmarks（本机书签）和 AccountBookmarks（登录 Google 账号后存在账号里的书签，
// 新版 Chrome 把书签挪到这里后 Bookmarks 可能是空的），格式相同。
// 按浏览器缓存解析结果，文件修改时间变了才重读；开关只决定列哪几家（修旧版 30 秒内不看开关，§11 #40）。
// 设置 › 启动器每个开关下写读到了几条 / 没找到书签文件 / 没有安装（体检 B39），用的是同一份缓存。

import AppKit

enum Bookmarks {
  struct Browser {
    let name: String
    let prefsKey: String
    /// ~/Library/Application Support 下的目录
    let directory: String
    /// 判断装没装（LaunchServices 按 bundle id 找）
    let bundleID: String
  }

  static let browsers = [
    Browser(
      name: "Chrome", prefsKey: Prefs.launcherBookmarksChrome, directory: "Google/Chrome",
      bundleID: "com.google.Chrome"),
    Browser(
      name: "Edge", prefsKey: Prefs.launcherBookmarksEdge, directory: "Microsoft Edge",
      bundleID: "com.microsoft.edgemac"),
    Browser(
      name: "Brave", prefsKey: Prefs.launcherBookmarksBrave,
      directory: "BraveSoftware/Brave-Browser", bundleID: "com.brave.Browser"),
  ]

  /// 每家浏览器解析出来的书签（同一家里网址去重），按它那几个文件的签名缓存
  private static var parsed:
    [String: (signature: String, bookmarks: [(title: String, url: String)])] =
      [:]
  private static var cache: (signature: String, items: [LauncherItem]) = ("", [])

  /// 启用且装着的浏览器的全部书签（跨浏览器同一网址只留一条）。没装的不搜：卸载后书签文件通常还在，
  /// 设置里那个开关却是灰的、显示关着，用户关不掉
  static func items() -> [LauncherItem] {
    let enabled = browsers.filter {
      UserDefaults.standard.bool(forKey: $0.prefsKey) && isInstalled($0)
    }
    let lists = enabled.map { ($0, bookmarks($0)) }
    let signature = enabled.map { "\($0.name):" + (parsed[$0.name]?.signature ?? "") }
      .joined(separator: "\n\n")
    if signature == cache.signature { return cache.items }
    var seen = Set<String>()
    var items: [LauncherItem] = []
    for (browser, bookmarks) in lists {
      for bookmark in bookmarks where seen.insert(bookmark.url).inserted {
        items.append(item(bookmark, browser: browser.name))
      }
    }
    cache = (signature, items)
    return items
  }

  /// 设置页那一行的状态：没装 / 没找到书签文件 / 读到了几条
  enum Status: Equatable {
    case notInstalled, noFile
    case read(Int)
  }

  /// 关着的（enabled = false）只看装没装、不读书签文件，装着就是 nil
  static func status(of browser: Browser, enabled: Bool) -> Status? {
    guard isInstalled(browser) else { return .notInstalled }
    guard enabled else { return nil }
    return profileFiles(browser).isEmpty ? .noFile : .read(bookmarks(browser).count)
  }

  /// LaunchServices 按 bundle id 找（约 15 µs，搜索时每次都问）
  static func isInstalled(_ browser: Browser) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil
  }

  /// 一家浏览器的书签：各配置的 Bookmarks / AccountBookmarks 修改时间都没变就用上次解析的
  private static func bookmarks(_ browser: Browser) -> [(title: String, url: String)] {
    let files = profileFiles(browser)
    let signature = files.map { url in
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      return "\(url.path)@\(modified)"
    }.joined(separator: "\n")
    if let cached = parsed[browser.name], cached.signature == signature { return cached.bookmarks }
    var seen = Set<String>()
    let bookmarks = files.compactMap { try? Data(contentsOf: $0) }.flatMap(parse)
      .filter { seen.insert($0.url).inserted }
    parsed[browser.name] = (signature, bookmarks)
    return bookmarks
  }

  private static func profileFiles(_ browser: Browser) -> [URL] {
    profileFiles(in: URL.applicationSupportDirectory.appending(path: browser.directory))
  }

  /// 浏览器数据目录下各配置的书签文件（存在的才算）。
  /// ponytail: Chrome 同时还写了加密版（EncryptedAccountBookmarks2 等），哪天不再写明文就读不到了；
  /// 解密要钥匙串里的「Chrome Safe Storage」（得用户授权），真到那天再做
  static func profileFiles(in root: URL) -> [URL] {
    let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return profiles.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
      .flatMap { profile in
        ["Bookmarks", "AccountBookmarks"].map { root.appending(path: "\(profile)/\($0)") }
      }
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
