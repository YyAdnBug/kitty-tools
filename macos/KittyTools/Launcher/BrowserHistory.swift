// 启动器搜浏览历史（体检 D8；第 12 批起各家都读：设置 › 启动器「浏览器书签与历史」每家书签开关下的「也搜浏览历史」，
// 默认关）+ Firefox 的书签（也在 SQLite 库里，同一套读法）。各配置的库克隆到临时目录，交给 /usr/bin/sqlite3 进程外读
// 常去的页面，按最后访问时间取最近 3000 条；筛选规则各家对齐 Chrome：
// - Chromium 系 History：urls 表没隐藏，且访问过至少 2 次或在地址栏手输过；时间是 1601 起的微秒。
// - Safari History.db：history_items.visit_count ≥ 2，标题和时间取最近一次 history_visits；时间是 2001 起的秒数。
//   要完全磁盘访问权限，没授权时克隆就失败（不弹框），状态 needsAccess、不缓存，授权后下次就读得到。
// - Firefox places.sqlite：moz_places 没隐藏，且访问过至少 2 次或手输过；时间是 1970 起的微秒。书签 = moz_bookmarks
//   type 1 join moz_places（去掉标签文件夹里的）。
// 每一份（某家的历史 / Firefox 书签）单独缓存：库（连 -wal）的修改时间变了、且距上次读满 60 秒才重读；开关关掉、卸载了立刻扔掉。
// 启动器里至少 2 个字才搜，只比标题和去掉协议的网址（不算拼音省开销），排在书签后面、和书签 / 用过的网址不重复，
// 副标题「历史 · 主机 · 3 天前」。
// 读库在进程外：刚克隆的库是冷缓存，本机 57 MB 的 History 在进程里读要约 140 ms，所以交给 sqlite3（Subprocess）导出
// JSON，主线程只解析和建行（Debug 构建本机 3000 条约 25 ms，60 秒最多一次）。

import Foundation
import Observation

@Observable final class BrowserHistory {
  static let shared = BrowserHistory()

  /// 要读的一份：某家浏览器的浏览历史，或 Firefox 的书签
  struct Source: Hashable {
    enum Kind { case history, firefoxBookmarks }
    let browser: Browsers.Browser
    let kind: Kind
  }

  nonisolated struct Page: Equatable {
    let url: String
    let title: String
    let visitedAt: Date
  }

  /// sqlite3 -json 的一行：网址、标题、各家自己的时间
  private nonisolated struct Row: Decodable {
    let u: String
    let t: String?
    let v: Double?
  }

  /// 设置页各行的状态（没在里面 = 还没读完）
  private(set) var statuses: [Source: Browsers.Status] = [:]
  /// 建好的历史行（kind .url、副标题「历史 · 主机」、visitedAt 是最后访问时间，搜索时再拼上「3 天前」）
  @ObservationIgnored private(set) var items: [LauncherItem] = []
  /// 这会儿该读哪几份、各家的数据目录；单测、截图自检换成固定的 / 临时目录
  @ObservationIgnored var sources: () -> [Source] = { BrowserHistory.enabledSources() }
  @ObservationIgnored var root: (Browsers.Browser) -> URL = { Browsers.root(of: $0) }
  @ObservationIgnored private var caches:
    [Source: (signature: [Date?], readAt: Date, pages: [Page])] =
      [:]
  @ObservationIgnored private var loading: Task<Bool, Never>?

  static let limit = 3000
  static let rereadInterval: TimeInterval = 60

  /// 开着的：书签、历史开关都开着的各家浏览历史 + 书签开着的 Firefox 的书签
  static func enabledSources() -> [Source] {
    Browsers.historyBrowsers().map { Source(browser: $0, kind: .history) }
      + Browsers.bookmarkBrowsers().filter { $0.format == .firefox }.map {
        Source(browser: $0, kind: .firefoxBookmarks)
      }
  }

  func status(_ source: Source) -> Browsers.Status { statuses[source] ?? .reading }

  /// 读到的页面（Firefox 书签给 Bookmarks 用）
  func pages(_ source: Source) -> [Page] { caches[source]?.pages ?? [] }

  /// 这一份读成的时刻（Bookmarks 拿它当缓存签名）
  func signature(_ source: Source) -> String {
    caches[source].map { "\($0.readAt.timeIntervalSinceReferenceDate)" } ?? ""
  }

  /// 要不要重读：没读过；或者库的修改时间变了、且距上次读满 60 秒
  static func needsReread(signature: [Date?]?, readAt: Date?, now: [Date?], at date: Date) -> Bool {
    guard let signature, let readAt else { return true }
    return signature != now && date.timeIntervalSince(readAt) >= rereadInterval
  }

  /// 呼出启动器、打开设置页、开关变了时调：关掉的扔掉；该重读的在进程外读（同时只跑一批）。等它读完再返回，
  /// 返回这次有没有换上新的（启动器据此决定要不要重搜）
  @discardableResult func refresh(now: Date = .now) async -> Bool {
    let sources = sources()
    let dropped = caches.keys.filter { !sources.contains($0) }
    for source in dropped { caches[source] = nil }
    if statuses.keys.contains(where: { !sources.contains($0) }) {
      statuses = statuses.filter { sources.contains($0.key) }
    }
    if !dropped.isEmpty { rebuild() }
    // 正在读的那一批不含它读的时候刚打开的（比如连着打开两家的开关）：等它读完，再按现在的开关补读一次
    if let loading {
      let changed = await loading.value
      return await refresh(now: now) || changed || !dropped.isEmpty
    }
    let due = sources.compactMap { source -> (Source, [URL], [Date?])? in
      let files = Browsers.files(
        named: [Self.file(source)], of: source.browser, in: root(source.browser))
      // 连 -wal 的修改时间一起看：Safari、Firefox 的库是 WAL 模式，浏览器开着时新的改动只写进 -wal，
      // 主文件要等合回（攒够页数或退出）才变
      let current = files.flatMap {
        [Browsers.modified($0), Browsers.modified(URL(filePath: $0.path + "-wal"))]
      }
      let cached = caches[source]
      guard
        Self.needsReread(
          signature: cached?.signature, readAt: cached?.readAt, now: current, at: now)
      else { return nil }
      return (source, files, current)
    }
    guard !due.isEmpty else { return !dropped.isEmpty }
    let task = Task {
      // 读完就放开（先于等它的人醒来），等它的人补读时不会再等到这一批
      defer { loading = nil }
      var changed = false
      for (source, files, signature) in due {
        guard let outcome = await Self.read(source, files: files),
          self.sources().contains(source)  // 读的时候开关被关掉了：不要了
        else { continue }
        statuses[source] = outcome.status
        // 没授权：不缓存，授权后（设置窗重新变 key、再呼出启动器）就读得到
        guard outcome.status != .needsAccess else { continue }
        caches[source] = (signature, now, outcome.pages)
        changed = true
      }
      if changed { rebuild() }
      return changed
    }
    loading = task
    return await task.value || !dropped.isEmpty
  }

  /// 读一份：各配置克隆后交给 sqlite3。有一个没权限 → needsAccess；没有文件 → noFile；有文件却一个都没读成
  /// （库正被写坏了一半这类）→ nil，留着上次的，下次再试
  private static func read(_ source: Source, files: [URL]) async
    -> (pages: [Page], status: Browsers.Status)?
  {
    var pages: [Page] = []
    var read = 0
    var missing = 0
    for file in files {
      let copy: URL
      do {
        copy = try Browsers.clone(file)
      } catch {
        switch Browsers.failure(error) {
        case .needsAccess: return ([], .needsAccess)
        case .noFile: missing += 1
        default: break
        }
        continue
      }
      defer { Browsers.discard(copy) }
      guard
        let result = try? await Subprocess.run(
          "/usr/bin/sqlite3", arguments(copy.path, query(source)), captures: true),
        result.status == 0
      else { continue }
      pages += parse(Data(result.output.utf8), format: source.browser.format)
      read += 1
    }
    guard read > 0 || missing == files.count else { return nil }
    let merged = merge(pages)
    return (merged, read == 0 ? .noFile : .read(merged.count))
  }

  private func rebuild() {
    let pages = caches.filter { $0.key.kind == .history }.values.flatMap(\.pages)
    items = Self.items(Self.merge(pages))
  }

  // MARK: 各家的库和查询

  static func file(_ source: Source) -> String {
    switch (source.kind, source.browser.format) {
    case (.firefoxBookmarks, _), (.history, .firefox): "places.sqlite"
    case (.history, .safari): "History.db"
    case (.history, .chromium): "History"
    }
  }

  /// 常去的页面（最近的在前，最多 3000 条）；Firefox 书签去掉标签文件夹里的（标签也存成书签，标题是空的）
  static func query(_ source: Source) -> String {
    switch (source.kind, source.browser.format) {
    case (.history, .chromium):
      """
      SELECT url AS u, title AS t, last_visit_time AS v FROM urls
      WHERE hidden = 0 AND (visit_count >= 2 OR typed_count >= 1)
      ORDER BY last_visit_time DESC LIMIT \(limit)
      """
    case (.history, .safari):
      """
      SELECT i.url AS u, h.title AS t, MAX(h.visit_time) AS v
      FROM history_items i JOIN history_visits h ON h.history_item = i.id
      WHERE i.visit_count >= 2 GROUP BY i.id ORDER BY v DESC LIMIT \(limit)
      """
    case (.history, .firefox):
      """
      SELECT url AS u, title AS t, last_visit_date AS v FROM moz_places
      WHERE hidden = 0 AND (visit_count >= 2 OR typed = 1) AND last_visit_date IS NOT NULL
      ORDER BY last_visit_date DESC LIMIT \(limit)
      """
    case (.firefoxBookmarks, _):
      """
      SELECT p.url AS u, b.title AS t, b.dateAdded AS v
      FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk
      WHERE b.type = 1 AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%')
        AND b.parent NOT IN (SELECT id FROM moz_bookmarks WHERE parent =
          (SELECT id FROM moz_bookmarks WHERE guid = 'tags________'))
      LIMIT \(limit)
      """
    }
  }

  /// sqlite3 的参数：-init /dev/null 不读用户的 ~/.sqliterc（里面的 .echo、.output 会往输出里掺东西或改走别处，
  /// JSON 就解析不出来了）
  static func arguments(_ path: String, _ query: String) -> [String] {
    ["-init", "/dev/null", "-readonly", "-json", path, query]
  }

  // MARK: 纯函数（配单测）

  /// 各家的时间 → Date：Chromium 系 1601-01-01 UTC 起的微秒，Safari 2001 起的秒，Firefox 1970 起的微秒
  static func date(_ value: Double, format: Browsers.Browser.Format) -> Date {
    switch format {
    case .chromium: Date(timeIntervalSince1970: value / 1_000_000 - 11_644_473_600)
    case .safari: Date(timeIntervalSinceReferenceDate: value)
    case .firefox: Date(timeIntervalSince1970: value / 1_000_000)
    }
  }

  /// sqlite3 -json 的输出 → 页面；没有行时 sqlite3 什么都不输出
  static func parse(_ json: Data, format: Browsers.Browser.Format) -> [Page] {
    guard !json.isEmpty, let rows = try? JSONDecoder().decode([Row].self, from: json) else {
      return []
    }
    return rows.map {
      Page(url: $0.u, title: $0.t ?? "", visitedAt: date($0.v ?? 0, format: format))
    }
  }

  /// 几个配置 / 几家合起来：同一网址留最近的一次，最近的在前，最多 3000 条
  static func merge(_ pages: [Page]) -> [Page] {
    var seen = Set<String>()
    return pages.sorted { $0.visitedAt > $1.visitedAt }.filter { seen.insert($0.url).inserted }
      .prefix(limit).map { $0 }
  }

  /// 行：标题（空的写主机）、副标题「历史 · 主机」；只拿标题和去掉协议、参数的网址参与匹配（不转拼音）
  static func items(_ pages: [Page]) -> [LauncherItem] {
    pages.compactMap { page in
      guard let host = SiteIcons.host(of: page.url) else { return nil }
      let bare = Bookmarks.bare(page.url)
      var item = LauncherItem(
        kind: .url, target: page.url, title: page.title.isEmpty ? host : page.title,
        subtitle: "历史 · \(host)",
        names: [page.title, bare].filter { !$0.isEmpty }.map(LauncherMatch.fold))
      item.visitedAt = page.visitedAt
      return item
    }
  }

  /// 搜到时的副标题：「历史 · 主机 · 3 天前」（按搜的那一刻算，缓存的行放久了也不会写错）
  static func subtitle(_ item: LauncherItem, now: Date = .now) -> String {
    guard let visitedAt = item.visitedAt else { return item.subtitle }
    // 相对时间的格式总是对着「现在」算：按 now 平移过去（平时 now 就是现在，单测能摆固定的时刻）
    let ago = Date.now.addingTimeInterval(min(visitedAt.timeIntervalSince(now), 0)).formatted(
      .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
    return item.subtitle + " · " + ago
  }
}
