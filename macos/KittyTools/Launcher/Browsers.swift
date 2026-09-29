// 启动器读哪些浏览器（第 12 批，2026-09-29 用户「加 Safari + 只列装了的」）：浏览器表（一处定义，纯数据）、装没装
// （LaunchServices 按 bundle id 找）、数据目录和各配置里的文件、偏好里开着哪几家、克隆别人的库。
// 设置 › 启动器「浏览器书签与历史」只列装了的（表的顺序 = 常用程度），启动器也只读装了且开着的——卸载后留下的数据不算。
// 三种格式：Chromium 系（书签 JSON、History / Favicons 库，多配置）、Safari（~/Library/Safari 的 Bookmarks.plist、
// History.db，受「完全磁盘访问权限」保护）、Firefox（每个配置一个 places.sqlite）。
// 书签在 Bookmarks，浏览历史（和 Firefox 的书签，都是 SQLite 库）在 BrowserHistory，网站图标在 SiteIcons。

import AppKit

enum Browsers {
  struct Browser: Hashable, Identifiable {
    enum Format { case chromium, safari, firefox }

    /// 偏好里存的 id（Prefs.launcherBrowserBookmarks / History 两个列表）
    let id: String
    let name: String
    let bundleID: String
    let format: Format
    /// 主目录下的数据目录
    let directory: String
  }

  /// 顺序 = 设置里的顺序（按常用程度：Safari、Chrome、Edge、Arc、Brave、Firefox，其余在后）。
  /// 本机核实过（2026-09-29）：bundle id —— Safari、Chrome、Chrome Dev（mdfind kMDItemCFBundleIdentifier）；
  /// 数据目录 —— Google/Chrome、Google/Chrome Dev、Microsoft Edge、BraveSoftware/Brave-Browser、Vivaldi、
  /// com.operasoftware.Opera、Chromium（~/Library/Application Support 下的目录名）。其余按各家文档：Chrome Beta / Canary
  /// 的目录见 chromium.org「User Data Directory」，Edge Beta / Dev / Canary 见微软「原生消息」文档里的目录，Arc 在
  /// Arc/User Data，Firefox 的配置在 Firefox/Profiles（Mozilla 支持文档「配置文件」）
  static let all: [Browser] = [
    Browser(
      id: "safari", name: "Safari", bundleID: "com.apple.Safari", format: .safari,
      directory: "Library/Safari"),
    chromium("chrome", "Chrome", "com.google.Chrome", "Google/Chrome"),
    chromium("edge", "Edge", "com.microsoft.edgemac", "Microsoft Edge"),
    // ponytail: Arc 的书签栏在侧栏（Arc/StorableSidebar.json，自己的格式），Bookmarks 里常是空的；这批只读 Bookmarks，
    // 真有人要再解析侧栏
    chromium("arc", "Arc", "company.thebrowser.Browser", "Arc/User Data"),
    chromium("brave", "Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
    Browser(
      id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", format: .firefox,
      directory: "Library/Application Support/Firefox"),
    chromium("vivaldi", "Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
    // Opera 的配置就是数据目录本身（opera://about 的「配置」路径），profileFiles 连数据目录一起看
    chromium("opera", "Opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
    chromium("chromium", "Chromium", "org.chromium.Chromium", "Chromium"),
    chromium("chrome-beta", "Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
    chromium("chrome-dev", "Chrome Dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
    chromium("chrome-canary", "Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
    chromium("edge-beta", "Edge Beta", "com.microsoft.edgemac.Beta", "Microsoft Edge Beta"),
    chromium("edge-dev", "Edge Dev", "com.microsoft.edgemac.Dev", "Microsoft Edge Dev"),
    chromium("edge-canary", "Edge Canary", "com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
  ]

  private static func chromium(
    _ id: String, _ name: String, _ bundleID: String, _ directory: String
  ) -> Browser {
    Browser(
      id: id, name: name, bundleID: bundleID, format: .chromium,
      directory: "Library/Application Support/" + directory)
  }

  /// 设置 › 启动器、SiteIcons、BrowserHistory、Bookmarks 读写偏好时的状态（设置页一行的说明）
  enum Status: Equatable {
    /// 进程外还没读完（浏览历史、Firefox 书签）
    case reading
    case noFile
    /// 读的时候被拒：Safari 没给完全磁盘访问权限
    case needsAccess
    case read(Int)
  }

  // MARK: 装没装（单测、截图自检换成固定的）

  /// App 在哪（没装是 nil；LaunchServices 按 bundle id 找，约 15 µs）
  static var locate: (Browser) -> URL? = {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID)
  }

  /// 装了的和它的 App 位置（表的顺序，设置只列这些、行上画它的图标）
  static func installed(_ locate: (Browser) -> URL? = { Browsers.locate($0) }) -> [(
    browser: Browser, app: URL
  )] {
    all.compactMap { browser in locate(browser).map { (browser, $0) } }
  }

  // MARK: 偏好：开着的 id，换行分隔（一个键管全部，SiteIcon、设置页用 @AppStorage 读一个键就能跟着变）

  static func ids(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init)
  }

  /// 列表里打开 / 关掉一家：按表的顺序写回，表里没有的旧 id 顺手丢掉
  static func setting(_ id: String, on: Bool, in text: String) -> String {
    var ids = Set(ids(text))
    if on { ids.insert(id) } else { ids.remove(id) }
    return all.map(\.id).filter(ids.contains).joined(separator: "\n")
  }

  /// 书签开关开着、装着的（先看开关再问装没装，搜索时每次都调）
  static func bookmarkBrowsers(
    _ defaults: UserDefaults = .standard, isInstalled: (Browser) -> Bool = { locate($0) != nil }
  ) -> [Browser] {
    let ids = ids(defaults.string(forKey: Prefs.launcherBrowserBookmarks) ?? "")
    return all.filter { ids.contains($0.id) && isInstalled($0) }
  }

  /// 书签、历史开关都开着、装着的（「也搜浏览历史」在书签开关下面，书签关着就不算）
  static func historyBrowsers(
    _ defaults: UserDefaults = .standard, isInstalled: (Browser) -> Bool = { locate($0) != nil }
  ) -> [Browser] {
    let ids = ids(defaults.string(forKey: Prefs.launcherBrowserHistory) ?? "")
    return bookmarkBrowsers(defaults, isInstalled: isInstalled).filter { ids.contains($0.id) }
  }

  /// 书签开着的 Chromium 系有没有（网站图标只从它们的 Favicons 库取；Safari、Firefox 的图标库不读）
  static func readsFavicons(_ bookmarkIDs: String) -> Bool {
    let ids = ids(bookmarkIDs)
    return all.contains { $0.format == .chromium && ids.contains($0.id) }
  }

  // MARK: 数据目录与文件

  /// 数据目录的起点：主目录；单测、截图自检换成临时目录，不碰用户真实的浏览器数据
  static var home = URL.homeDirectory

  static func root(of browser: Browser) -> URL {
    home.appending(path: browser.directory)
  }

  /// 这家各配置里叫这些名字的文件（root 默认是它的数据目录）。Chromium 系、Firefox 只算存在的；Safari 没有配置，就是 ~/Library/Safari 里那个，
  /// 不看在不在，读的时候再按错误分「没授权 / 没有文件」。没给完全磁盘访问权限时（本机实测）stat 能过、修改时间照样拿得到，
  /// 只有 open 被拒（EPERM），列目录也被拒——所以读失败的结果不能拿修改时间当缓存签名（授权前后签名一样，就不重读了）
  static func files(named names: [String], of browser: Browser, in root: URL? = nil) -> [URL] {
    let root = root ?? self.root(of: browser)
    switch browser.format {
    case .safari:
      return names.map { root.appending(path: $0) }
    case .chromium:
      return profileFiles(named: names, in: root)
    case .firefox:
      // 每个配置都读（和 Chromium 系读全部配置一样），不只 profiles.ini 里的默认那个
      let profiles = root.appending(path: "Profiles")
      let found = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
      return found.sorted()
        .flatMap { profile in names.map { profiles.appending(path: "\(profile)/\($0)") } }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
  }

  /// Chromium 系各配置（数据目录本身（Opera）、Default、Profile N）里叫这些名字的文件，存在的才算
  static func profileFiles(named names: [String], in root: URL) -> [URL] {
    let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let directories =
      [root]
      + profiles.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
      .map { root.appending(path: $0) }
    return directories.flatMap { directory in names.map { directory.appending(path: $0) } }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 文件的修改时间（只 stat）：库变没变
  static func modified(_ file: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
  }

  /// 把别人的库克隆到自己的临时文件夹里再读（APFS 上是克隆，瞬时、不占空间）：浏览器开着时库被它锁着，直接读会忙等。
  /// 连 -wal 一起克隆（Safari、Firefox 的库是 WAL 模式，最近的改动还在 -wal 里，只克隆主文件就读不到）；先克隆 -wal
  /// 再克隆主文件，两次之间浏览器正好把 -wal 合回主文件也读不到半截。没有 -wal（Chromium 系、浏览器退出时合回后删掉，
  /// 可能正删在看和拷之间）就只拷主文件，只有主文件没有才算「没有文件」。用完 discard；没权限、没文件时抛错（`failure` 分）
  static func clone(_ file: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appending(path: file.lastPathComponent)
    do {
      do {
        try FileManager.default.copyItem(
          at: URL(filePath: file.path + "-wal"), to: URL(filePath: copy.path + "-wal"))
      } catch  where failure(error) == .noFile {}
      try FileManager.default.copyItem(at: file, to: copy)
    } catch {
      discard(copy)
      throw error
    }
    return copy
  }

  /// 删掉克隆（连同读的时候 SQLite 在旁边建的 -shm、-wal）
  static func discard(_ copy: URL) {
    try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
  }

  /// 读别人的文件失败的原因：没权限（完全磁盘访问被拒是 EPERM、权限位不够是 EACCES，Foundation 都报
  /// fileReadNoPermission）→ needsAccess，没有文件 → noFile，别的（读到一半）→ nil。读本身不弹系统框：
  /// 完全磁盘访问权限没有请求授权的 API，TCC 只拒绝（Safari 那一行在设置里给「去授权…」）
  static func failure(_ error: any Error) -> Status? {
    let error = error as NSError
    let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
      $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
    }
    if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
      || posix == EPERM || posix == EACCES
    {
      return .needsAccess
    }
    if error.domain == NSCocoaErrorDomain
      && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) || posix == ENOENT
    {
      return .noFile
    }
    return nil
  }
}
