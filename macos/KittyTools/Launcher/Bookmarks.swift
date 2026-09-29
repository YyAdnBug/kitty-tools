// 启动器的浏览器书签（第 12 批起各家都读，浏览器表在 Browsers）：只读装了、书签开关开着的；同一网址只留一条。
// - Chromium 系：各配置（数据目录本身、Default、Profile N）读两个文件：Bookmarks（本机书签）和 AccountBookmarks
//   （登录 Google 账号后存在账号里的书签，新版 Chrome 把书签挪到这里后 Bookmarks 可能是空的），格式相同的 JSON。
// - Safari：~/Library/Safari/Bookmarks.plist（二进制 plist），要完全磁盘访问权限；没授权时读失败（不弹框），设置里写
//   「需要完全磁盘访问权限」+「去授权…」。
// - Firefox：书签在 places.sqlite 里，和浏览历史一起由 BrowserHistory 进程外读（库被 Firefox 锁着、改得很勤），这里取它
//   读好的。
// 按浏览器缓存解析结果，文件修改时间变了才重读；开关只决定列哪几家（修旧版 30 秒内不看开关，§11 #40）。
// 设置 › 启动器每个开关下写读到了几条 / 没找到书签文件 / 需要完全磁盘访问权限（体检 B39），用的是同一份缓存。

import AppKit

enum Bookmarks {
  typealias Bookmark = (title: String, url: String)

  /// 每家浏览器解析出来的书签（同一家里网址去重），按它那几个文件的签名缓存（读失败的不缓存，下次再试）
  private static var parsed: [String: (signature: String, bookmarks: [Bookmark])] = [:]
  private static var cache: (signature: String, items: [LauncherItem]) = ("", [])

  /// 开着且装着的浏览器的全部书签（跨浏览器同一网址只留一条）。没装的不搜：卸载后书签文件通常还在。
  /// 单测传要读的几家和假的数据目录，不碰偏好和全局的 Browsers.home
  static func items(
    from browsers: [Browsers.Browser] = Browsers.bookmarkBrowsers(),
    root: (Browsers.Browser) -> URL = { Browsers.root(of: $0) }
  ) -> [LauncherItem] {
    let lists = browsers.map { ($0, read($0, root: root($0))) }
    let signature = lists.map { "\($0.0.id):" + $0.1.signature }.joined(separator: "\n\n")
    if signature == cache.signature { return cache.items }
    var seen = Set<String>()
    var items: [LauncherItem] = []
    for (browser, list) in lists {
      for bookmark in list.bookmarks where seen.insert(bookmark.url).inserted {
        items.append(item(bookmark, browser: browser.name))
      }
    }
    cache = (signature, items)
    return items
  }

  /// 设置页那一行的状态（开关开着时才调）：读到了几条 / 没找到书签文件 / 没授权 / Firefox 还在读
  static func status(of browser: Browsers.Browser) -> Browsers.Status {
    read(browser).status
  }

  /// 一家的书签：Chromium 系、Safari 按文件修改时间缓存；Firefox 取 BrowserHistory 读好的
  private static func read(_ browser: Browsers.Browser, root: URL? = nil)
    -> (bookmarks: [Bookmark], status: Browsers.Status, signature: String)
  {
    if browser.format == .firefox {
      let source = BrowserHistory.Source(browser: browser, kind: .firefoxBookmarks)
      let pages = BrowserHistory.shared.pages(source)
      return (
        pages.map { ($0.title, $0.url) }, BrowserHistory.shared.status(source),
        BrowserHistory.shared.signature(source)
      )
    }
    let files = Browsers.files(
      named: browser.format == .safari ? ["Bookmarks.plist"] : ["Bookmarks", "AccountBookmarks"],
      of: browser, in: root)
    let signature = files.map { url in
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      return "\(url.path)@\(modified)"
    }.joined(separator: "\n")
    if let cached = parsed[browser.id], cached.signature == signature {
      return (cached.bookmarks, .read(cached.bookmarks.count), signature)
    }
    guard !files.isEmpty else { return ([], .noFile, signature) }
    var datas: [Data] = []
    for file in files {
      do {
        datas.append(try Data(contentsOf: file))
      } catch {
        // Safari 没授权 / 没有文件：不缓存，签名留空（没授权时修改时间照样拿得到，带上它授权前后签名一样，
        // items() 会一直用没有 Safari 的旧结果），授权后（设置窗重新变 key、再搜）就读得到
        if let failure = Browsers.failure(error), browser.format == .safari {
          return ([], failure, "")
        }
      }
    }
    var seen = Set<String>()
    let bookmarks = datas.flatMap(browser.format == .safari ? parseSafari : parse)
      .filter { seen.insert($0.url).inserted }
    parsed[browser.id] = (signature, bookmarks)
    return (bookmarks, .read(bookmarks.count), signature)
  }

  /// 去掉协议和参数的网址（参与匹配）：https://a.com/b?c → a.com/b。不用 Swift Regex：本机 3000 条浏览历史
  /// 用正则替换两次要约 145 ms
  static func bare(_ url: String) -> String {
    var text = Substring(url)
    if let scheme = ["https://", "http://"].first(where: { text.hasPrefix($0) }) {
      text = text.dropFirst(scheme.count)
    }
    if let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = text[..<end] }
    return String(text)
  }

  private static func isWeb(_ url: String) -> Bool {
    url.hasPrefix("http://") || url.hasPrefix("https://")
  }

  /// Chromium 系的 Bookmarks JSON → (标题, 网址)。只收书签栏 / 其他书签 / 移动设备书签下的 http(s) 链接。纯函数，配单测
  /// ponytail: Chrome 同时还写了加密版（EncryptedAccountBookmarks2 等），哪天不再写明文就读不到了；
  /// 解密要钥匙串里的「Chrome Safe Storage」（得用户授权），真到那天再做
  static func parse(_ data: Data) -> [Bookmark] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let roots = json["roots"] as? [String: Any]
    else { return [] }
    var result: [Bookmark] = []
    func walk(_ node: [String: Any]) {
      if node["type"] as? String == "url", let url = node["url"] as? String, isWeb(url) {
        result.append((node["name"] as? String ?? url, url))
      }
      for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
    }
    for key in ["bookmark_bar", "other", "synced"] {
      if let root = roots[key] as? [String: Any] { walk(root) }
    }
    return result
  }

  /// Safari 的 Bookmarks.plist → (标题, 网址)：递归 Children，收 WebBookmarkTypeLeaf 的 http(s) 链接（URLString），
  /// 标题在 URIDictionary.title。阅读列表（com.apple.ReadingList 文件夹）里也是这样的叶子，当书签一起收。纯函数，配单测
  static func parseSafari(_ data: Data) -> [Bookmark] {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return [] }
    var result: [Bookmark] = []
    func walk(_ node: [String: Any]) {
      if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
        let url = node["URLString"] as? String, isWeb(url)
      {
        result.append(((node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url, url))
      }
      for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
    }
    walk(root)
    return result
  }

  private static func item(_ bookmark: Bookmark, browser: String) -> LauncherItem {
    let host = URL(string: bookmark.url)?.host() ?? bookmark.url
    let pinyin = AppCatalog.pinyin(bookmark.title)
    // 网址只拿去掉协议和参数的部分参与匹配
    let bare = Self.bare(bookmark.url)
    return LauncherItem(
      kind: .url, target: bookmark.url, title: bookmark.title.isEmpty ? host : bookmark.title,
      subtitle: "书签 · \(browser) · \(host)",
      names: [bookmark.title, bare, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [pinyin?.initials].compactMap { $0 })
  }
}
