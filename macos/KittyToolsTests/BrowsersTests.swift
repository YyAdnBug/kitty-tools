import Foundation
import Testing

@testable import KittyTools

/// 第 12 批：浏览器书签与历史——浏览器表、只列装了的、偏好迁移、Safari / Firefox 的书签与历史。
/// 全用临时目录里的假文件、临时偏好域和注入的「装没装」，不读用户真实的浏览器数据、不写真实偏好
struct BrowsersTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kitty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func browser(_ id: String) throws -> Browsers.Browser {
    try #require(Browsers.all.first { $0.id == id })
  }

  // MARK: 浏览器表

  @Test func tableIsComplete() {
    let all = Browsers.all
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(Set(all.map(\.bundleID)).count == all.count)
    #expect(Set(all.map(\.directory)).count == all.count)
    #expect(all.allSatisfy { !$0.name.isEmpty && $0.directory.hasPrefix("Library/") })
    // 常用的在前（设置里的顺序）
    #expect(
      all.prefix(6).map(\.id) == ["safari", "chrome", "edge", "arc", "brave", "firefox"])
    #expect(all.filter { $0.format == .safari }.map(\.id) == ["safari"])
    #expect(all.filter { $0.format == .firefox }.map(\.id) == ["firefox"])
    #expect(
      all.filter { $0.format == .chromium }.allSatisfy {
        $0.directory.hasPrefix("Library/Application Support/")
      })
    // 旧键里的三家都还在表里，默认开的 Chrome 也在
    #expect(
      Prefs.launcherBookmarksLegacy.allSatisfy { legacy in all.contains { $0.id == legacy.0 } })
    #expect(all.contains { $0.id == Prefs.defaultBookmarkIDs })
  }

  /// 设置只列装了的（表的顺序）；启动器只读装了且开着的，书签关着的历史也不算
  @Test func onlyInstalledAndEnabled() throws {
    let installed: Set = ["safari", "firefox", "chrome-dev", "chrome"]
    #expect(
      Browsers.installed {
        installed.contains($0.id) ? URL(filePath: "/Applications/\($0.name).app") : nil
      }
      .map(\.browser.id) == [
        "safari", "chrome", "firefox", "chrome-dev",
      ])
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("edge\nfirefox\nchrome\nsafari", forKey: Prefs.launcherBrowserBookmarks)
    defaults.set("firefox\nbrave\nsafari", forKey: Prefs.launcherBrowserHistory)
    let isInstalled = { (browser: Browsers.Browser) in installed.contains(browser.id) }
    #expect(
      Browsers.bookmarkBrowsers(defaults, isInstalled: isInstalled).map(\.id) == [
        "safari", "chrome", "firefox",
      ])
    #expect(
      Browsers.historyBrowsers(defaults, isInstalled: isInstalled).map(\.id) == [
        "safari", "firefox",
      ])
    // 开关写回：按表的顺序，表里没有的旧 id 丢掉
    #expect(Browsers.setting("safari", on: true, in: "gone\nchrome") == "safari\nchrome")
    #expect(Browsers.setting("chrome", on: false, in: "safari\nchrome") == "safari")
    #expect(Browsers.ids("") == [])
    #expect(!Browsers.readsFavicons("safari\nfirefox"))
    #expect(Browsers.readsFavicons("safari\narc"))
  }

  /// 旧的每家一个开关搬进两个列表、删掉旧键；已经有新值不覆盖；没动过旧键的不写新键（跟着默认走）
  @Test func migratesLegacyToggles() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    Prefs.migrate(defaults, domainName: suite)
    // 只看持久域（别的测试调过 registerDefaults 时，注册域的默认值对所有偏好域都可见）
    let stored = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(stored[Prefs.launcherBrowserBookmarks] == nil)
    #expect(stored[Prefs.launcherBrowserHistory] == nil)
    // 关掉了 Chrome（默认开）、打开了 Edge，Brave 没动过（按旧默认关）；Chrome 历史开着
    defaults.set(false, forKey: "launcherBookmarksChrome")
    defaults.set(true, forKey: "launcherBookmarksEdge")
    defaults.set(true, forKey: Prefs.launcherHistoryChromeLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.string(forKey: Prefs.launcherBrowserBookmarks) == "edge")
    #expect(defaults.string(forKey: Prefs.launcherBrowserHistory) == "chrome")
    for (_, key, _) in Prefs.launcherBookmarksLegacy {
      #expect(defaults.object(forKey: key) == nil)
    }
    #expect(defaults.object(forKey: Prefs.launcherHistoryChromeLegacy) == nil)
    // 只动过 Brave：Chrome 按旧默认开着
    defaults.removeObject(forKey: Prefs.launcherBrowserBookmarks)
    defaults.set(true, forKey: "launcherBookmarksBrave")
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.string(forKey: Prefs.launcherBrowserBookmarks) == "chrome\nbrave")
    // 新键已经有值：旧键只删不搬
    defaults.set("safari", forKey: Prefs.launcherBrowserBookmarks)
    defaults.set(true, forKey: "launcherBookmarksEdge")
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.string(forKey: Prefs.launcherBrowserBookmarks) == "safari")
    #expect(defaults.object(forKey: "launcherBookmarksEdge") == nil)
  }

  // MARK: 文件

  /// Firefox 每个配置都读（有 places.sqlite 的）；Safari 不看在不在（读的时候按错误分没授权 / 没有文件）
  @Test func profileFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for profile in ["b1.default-release", "a2.default", "c3.work"] {
      let directory = root.appending(path: "Profiles/\(profile)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if profile != "a2.default" {
        try Data().write(to: directory.appending(path: "places.sqlite"))
      }
    }
    let firefox = try browser("firefox")
    #expect(
      Browsers.files(named: ["places.sqlite"], of: firefox, in: root).map {
        $0.deletingLastPathComponent().lastPathComponent
      } == ["b1.default-release", "c3.work"])
    let safari = try browser("safari")
    #expect(
      Browsers.files(named: ["History.db"], of: safari, in: root) == [
        root.appending(path: "History.db")
      ])
    #expect(
      Browsers.root(of: safari).path.hasSuffix("/Library/Safari")
        && Browsers.root(of: firefox).path.hasSuffix("/Library/Application Support/Firefox"))
  }

  /// 读失败分两种：没权限（设置里「需要完全磁盘访问权限」）、没有文件；克隆失败不留临时文件夹
  @Test func readFailures() throws {
    let root = try temporaryDirectory()
    let locked = root.appending(path: "Safari")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: locked.appending(path: "Bookmarks.plist"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
      try? FileManager.default.removeItem(at: root)
    }
    let denied = #expect(throws: (any Error).self) {
      try Data(contentsOf: locked.appending(path: "Bookmarks.plist"))
    }
    #expect(denied.flatMap { Browsers.failure($0) } == .needsAccess)
    let cloneDenied = #expect(throws: (any Error).self) {
      try Browsers.clone(locked.appending(path: "Bookmarks.plist"))
    }
    #expect(cloneDenied.flatMap { Browsers.failure($0) } == .needsAccess)
    let missing = #expect(throws: (any Error).self) {
      try Browsers.clone(root.appending(path: "History.db"))
    }
    #expect(missing.flatMap { Browsers.failure($0) } == .noFile)
    #expect(Browsers.failure(CocoaError(.fileReadCorruptFile)) == nil)
  }

  // MARK: Safari

  @Test func parsesSafariBookmarks() throws {
    func leaf(_ title: String?, _ url: String) -> [String: Any] {
      var node: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url]
      if let title { node["URIDictionary"] = ["title": title] }
      return node
    }
    let plist: [String: Any] = [
      "WebBookmarkType": "WebBookmarkTypeList",
      "Children": [
        ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
        [
          "WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar",
          "Children": [
            leaf("Apple", "https://www.apple.com/"),
            [
              "WebBookmarkType": "WebBookmarkTypeList", "Title": "文档",
              "Children": [
                leaf("Swift", "https://swift.org/"), leaf("书签脚本", "javascript:void(0)"),
              ],
            ],
          ],
        ],
        [
          "WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList",
          "Children": [leaf(nil, "http://read.later/")],
        ],
      ],
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .binary, options: 0)
    let bookmarks = Bookmarks.parseSafari(data)
    #expect(
      bookmarks.map(\.url) == [
        "https://www.apple.com/", "https://swift.org/", "http://read.later/",
      ])
    #expect(bookmarks.map(\.title) == ["Apple", "Swift", "http://read.later/"])  // 阅读列表也收，没标题写网址
    #expect(Bookmarks.parseSafari(Data("不是 plist".utf8)).isEmpty)
  }

  /// Safari 的库（WAL 模式、还开着——最近的改动在 -wal 里）：克隆后 sqlite3 读，访问 ≥ 2 次，标题和时间取最近一次
  @Test func safariHistoryThroughSqlite3() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try Database(path: root.appending(path: "History.db").path)
    try Self.makeSafariHistory(database)
    let pages = try await Self.export(
      root.appending(path: "History.db"), source: .init(browser: browser("safari"), kind: .history))
    #expect(pages.map(\.url) == ["https://www.apple.com/", "https://swift.org/"])
    #expect(pages.map(\.title) == ["Apple", "Swift"])
    #expect(pages[0].visitedAt == Date(timeIntervalSinceReferenceDate: 800_000_200))
    _ = try database.query("SELECT 1") { _ in 0 }  // 读的时候库一直开着（改动在 -wal 里）
  }

  // MARK: Firefox

  @Test func firefoxThroughSqlite3() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try Database(path: root.appending(path: "places.sqlite").path)
    try Self.makeFirefoxPlaces(database)
    let firefox = try browser("firefox")
    let history = try await Self.export(
      root.appending(path: "places.sqlite"), source: .init(browser: firefox, kind: .history))
    // 没隐藏、访问 ≥ 2 次或手输过、有访问时间；最近的在前
    #expect(history.map(\.url) == ["https://typed.example/", "https://www.mozilla.org/"])
    #expect(history[1].visitedAt == Date(timeIntervalSince1970: 1_700_000_000))
    let bookmarks = try await Self.export(
      root.appending(path: "places.sqlite"),
      source: .init(browser: firefox, kind: .firefoxBookmarks))
    // 标签文件夹里的、place: 的不算
    #expect(bookmarks.map(\.url) == ["https://example.com/tagged", "https://www.mozilla.org/"])
    #expect(bookmarks.map(\.title) == ["示例", "Mozilla 首页"])
    _ = try database.query("SELECT 1") { _ in 0 }  // 读的时候库一直开着（改动在 -wal 里）
  }

  /// 各家的时间换算
  @Test func dates() {
    #expect(
      BrowserHistory.date(11_644_473_600 * 1_000_000, format: .chromium)
        == Date(timeIntervalSince1970: 0))
    #expect(BrowserHistory.date(0, format: .safari) == Date(timeIntervalSinceReferenceDate: 0))
    #expect(
      BrowserHistory.date(1_000_000, format: .firefox) == Date(timeIntervalSince1970: 1))
  }

  // MARK: 整条读法（注入数据目录和要读的几份，不碰全局）

  /// Safari 没授权：needsAccess、不缓存，授权后再 refresh 就读到；没有文件是 noFile；Firefox 书签不进历史行；
  /// 关掉的立刻扔掉
  @Test func refreshReadsEachSource() async throws {
    let root = try temporaryDirectory()
    let safariDirectory = root.appending(path: "safari")
    let profile = root.appending(path: "firefox/Profiles/x.default-release")
    for directory in [safariDirectory, profile, root.appending(path: "chrome")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: safariDirectory.path)
      try? FileManager.default.removeItem(at: root)
    }
    try Self.makeSafariHistory(Database(path: safariDirectory.appending(path: "History.db").path))
    try Self.makeFirefoxPlaces(Database(path: profile.appending(path: "places.sqlite").path))
    let (safari, firefox, chrome) = try (browser("safari"), browser("firefox"), browser("chrome"))
    let sources: [BrowserHistory.Source] = [
      .init(browser: safari, kind: .history), .init(browser: firefox, kind: .history),
      .init(browser: firefox, kind: .firefoxBookmarks), .init(browser: chrome, kind: .history),
    ]
    let history = BrowserHistory()
    history.root = { root.appending(path: $0.id) }
    var enabled = sources
    history.sources = { enabled }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0], ofItemAtPath: safariDirectory.path)
    let now = Date.now
    #expect(await history.refresh(now: now))
    #expect(history.status(sources[0]) == .needsAccess)
    #expect(history.status(sources[1]) == .read(2))
    #expect(history.status(sources[2]) == .read(2))
    #expect(history.status(sources[3]) == .noFile)
    #expect(history.pages(sources[2]).count == 2)
    #expect(
      history.items.map(\.target) == ["https://typed.example/", "https://www.mozilla.org/"])
    // 授权了（同一时刻再读，没授权的没缓存，不等 60 秒）
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: safariDirectory.path)
    #expect(await history.refresh(now: now))
    #expect(history.status(sources[0]) == .read(2))
    #expect(history.items.count == 4)
    #expect(!(await history.refresh(now: now)))  // 都读过、没变：不重读
    // 关掉 Firefox：它的历史和书签立刻扔掉
    enabled = [sources[0]]
    #expect(await history.refresh(now: now))
    #expect(history.items.map(\.target) == ["https://www.apple.com/", "https://swift.org/"])
    #expect(history.pages(sources[2]).isEmpty && history.status(sources[2]) == .reading)
  }

  /// 读的时候又打开了一家（连着打开两家的开关）：后来的 refresh 等前一批读完，再补读新打开的，不停在「正在读取…」
  @Test func refreshCatchesUpAfterInFlightRead() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let safariDirectory = root.appending(path: "safari")
    let profile = root.appending(path: "firefox/Profiles/x.default-release")
    for directory in [safariDirectory, profile] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Self.makeSafariHistory(Database(path: safariDirectory.appending(path: "History.db").path))
    try Self.makeFirefoxPlaces(Database(path: profile.appending(path: "places.sqlite").path))
    let firefox = BrowserHistory.Source(browser: try browser("firefox"), kind: .history)
    let safari = BrowserHistory.Source(browser: try browser("safari"), kind: .history)
    let history = BrowserHistory()
    history.root = { root.appending(path: $0.id) }
    var enabled = [firefox]
    history.sources = { enabled }
    let first = Task { await history.refresh() }
    await Task.yield()  // 前一批开始读 Firefox
    enabled = [firefox, safari]
    #expect(await history.refresh())
    #expect(history.status(safari) == .read(2))
    #expect(history.status(firefox) == .read(2))
    _ = await first.value
  }

  /// Safari 没授权时（stat 能过、open 被拒，同完全磁盘访问：只把文件本身设成不可读，修改时间不变）搜不到它的书签；
  /// 授权后文件没变也要重建，不能一直用没授权时缓存的那份
  @Test func safariBookmarksAfterGrant() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "safari/Bookmarks.plist")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "WebBookmarkType": "WebBookmarkTypeList",
      "Children": [
        [
          "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://granted.example/",
          "URIDictionary": ["title": "授权后"],
        ]
      ],
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
      .write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    let safari = try browser("safari")
    let items = { Bookmarks.items(from: [safari], root: { root.appending(path: $0.id) }) }
    #expect(items().isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(items().map(\.title) == ["授权后"])
  }

  /// 浏览器开着时新的改动只在 -wal 里、主文件不变：满 60 秒再 refresh 也要读到
  @Test func rereadsWhenOnlyWALChanged() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "safari/History.db")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let database = try Database(path: file.path)  // 一直开着，改动留在 -wal 里
    try Self.makeSafariHistory(database)
    let source = BrowserHistory.Source(browser: try browser("safari"), kind: .history)
    let history = BrowserHistory()
    history.root = { root.appending(path: $0.id) }
    history.sources = { [source] }
    let now = Date.now
    #expect(await history.refresh(now: now))
    #expect(history.status(source) == .read(2))
    let modified = Browsers.modified(file)
    try database.execute(
      "INSERT INTO history_items(id, url, visit_count) VALUES (4, 'https://new.example/', 2)")
    try database.execute(
      "INSERT INTO history_visits(history_item, visit_time, title) VALUES (4, 800000400.0, 'New')")
    #expect(Browsers.modified(file) == modified)  // 主文件没变
    #expect(await history.refresh(now: now.addingTimeInterval(BrowserHistory.rereadInterval)))
    #expect(history.status(source) == .read(3))
    _ = try database.query("SELECT 1") { _ in 0 }  // 库一直开着到最后（关库会把 -wal 合回主文件）
  }

  /// 设置侧栏搜得到
  @Test func settingsSearch() {
    for word in ["Safari", "firefox", "Arc", "完全磁盘访问", "浏览器"] {
      #expect(SettingsPage.launcher.matches(word), "\(word)")
    }
  }

  // MARK: 假库

  /// 克隆后交给 sqlite3（和 BrowserHistory 同一套参数、查询）
  private static func export(_ file: URL, source: BrowserHistory.Source) async throws
    -> [BrowserHistory.Page]
  {
    let copy = try Browsers.clone(file)
    defer { Browsers.discard(copy) }
    let result = try await Subprocess.run(
      "/usr/bin/sqlite3", BrowserHistory.arguments(copy.path, BrowserHistory.query(source)),
      captures: true)
    #expect(result.status == 0, "\(result.error)")
    return BrowserHistory.merge(
      BrowserHistory.parse(Data(result.output.utf8), format: source.browser.format))
  }

  /// Safari History.db 的两张表（只建用到的列）：apple 访问 3 次（最近一次标题「Apple」）、swift 2 次、once 1 次
  static func makeSafariHistory(_ database: Database) throws {
    try database.execute(
      "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, visit_count INTEGER NOT NULL)"
    )
    try database.execute(
      "CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL)"
    )
    for (id, url, count) in [
      (1, "https://www.apple.com/", 3), (2, "https://once.example/", 1),
      (3, "https://swift.org/", 2),
    ] {
      try database.execute(
        "INSERT INTO history_items(id, url, visit_count) VALUES (?, ?, ?)", [id, url, count])
    }
    for (item, time, title) in [
      (1, 800_000_100.0, "旧标题"), (1, 800_000_200.0, "Apple"), (2, 800_000_300.0, "Once"),
      (3, 800_000_150.0, "Swift"),
    ] {
      try database.execute(
        "INSERT INTO history_visits(history_item, visit_time, title) VALUES (?, ?, ?)",
        [item, time, title])
    }
  }

  /// Firefox places.sqlite 的两张表（只建用到的列）：书签根、工具栏、标签根（guid 固定）；
  /// 标签「work」下的条目、place: 智能书签不算书签
  static func makeFirefoxPlaces(_ database: Database) throws {
    try database.execute(
      "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER)"
    )
    try database.execute(
      "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, dateAdded INTEGER, guid TEXT)"
    )
    let places: [(Int, String, String?, Int, Int, Int, Int?)] = [
      (1, "https://www.mozilla.org/", "Mozilla", 5, 0, 0, 1_700_000_000_000_000),
      (2, "https://example.com/tagged", "Tagged", 1, 0, 0, 1_700_000_100_000_000),
      (3, "place:sort=8", nil, 0, 0, 0, nil),
      (4, "https://hidden.example/", "Hidden", 9, 1, 0, 1_700_000_200_000_000),
      (5, "https://typed.example/", "Typed", 1, 0, 1, 1_700_000_300_000_000),
      (6, "https://never.example/", "Never", 3, 0, 0, nil),
    ]
    for (id, url, title, visits, hidden, typed, last) in places {
      try database.execute(
        "INSERT INTO moz_places(id, url, title, visit_count, hidden, typed, last_visit_date) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [id, url, title, visits, hidden, typed, last])
    }
    let bookmarks: [(Int, Int, Int?, Int, String?, Int, String)] = [
      (1, 2, nil, 0, "", 0, "root________"), (3, 2, nil, 1, "toolbar", 0, "toolbar_____"),
      (4, 2, nil, 1, "tags", 0, "tags________"), (10, 1, 1, 3, "Mozilla 首页", 1, "b10"),
      (11, 2, nil, 4, "work", 2, "b11"), (12, 1, 2, 11, nil, 3, "b12"),
      (13, 1, 3, 3, "最近的书签", 4, "b13"), (14, 1, 2, 3, "示例", 5, "b14"),
    ]
    for (id, type, fk, parent, title, added, guid) in bookmarks {
      try database.execute(
        "INSERT INTO moz_bookmarks(id, type, fk, parent, title, dateAdded, guid) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [id, type, fk, parent, title, added, guid])
    }
  }
}
