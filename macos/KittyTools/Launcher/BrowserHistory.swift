// 启动器搜 Chrome 浏览历史（体检 D8，设置 › 启动器「浏览器书签与历史」里 Chrome 下的「也搜浏览历史」，默认关）：
// 各配置的 History 库克隆到临时目录，读 urls 表里常去的页面（没隐藏，且访问过至少 2 次或在地址栏手输过），按最后访问
// 时间取最近 3000 条。库的修改时间变了、且距上次读满 60 秒才重读。启动器里至少 2 个字才搜，只比标题和去掉协议的网址
// （不算拼音省开销），排在书签后面、和书签 / 用过的网址不重复，副标题「历史 · 主机 · 3 天前」。
// 读库在进程外：刚克隆的库是冷缓存，本机 57 MB 的 History 在进程里读要约 140 ms，所以交给 /usr/bin/sqlite3（Subprocess）
// 导出 JSON，主线程只解析和建行（Debug 构建本机 3000 条约 25 ms，60 秒最多一次）。

import Foundation
import Observation

@Observable final class BrowserHistory {
  static let shared = BrowserHistory()

  nonisolated struct Page: Equatable, Decodable {
    let url: String
    let title: String
    let visitedAt: Date

    enum CodingKeys: String, CodingKey {
      case url = "u"
      case title = "t"
      case visited = "v"
    }

    init(url: String, title: String, visitedAt: Date) {
      (self.url, self.title, self.visitedAt) = (url, title, visitedAt)
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      url = try container.decode(String.self, forKey: .url)
      title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
      visitedAt = Self.date(chrome: try container.decode(Double.self, forKey: .visited))
    }

    /// Chrome 的时间：1601-01-01 UTC 起的微秒数
    static func date(chrome microseconds: Double) -> Date {
      Date(timeIntervalSince1970: microseconds / 1_000_000 - 11_644_473_600)
    }
  }

  /// 设置页那一行：没读过 / 没找到 History 文件 / 读到了几条
  enum Status: Equatable {
    case unknown, noFile
    case read(Int)
  }

  private(set) var status = Status.unknown
  /// 建好的行（kind .url、副标题「历史 · 主机」、visitedAt 是最后访问时间，搜索时再拼上「3 天前」）
  @ObservationIgnored private(set) var items: [LauncherItem] = []
  @ObservationIgnored var root: URL? = Bookmarks.root(of: Bookmarks.chrome)
  @ObservationIgnored private var signature: [Date?]?
  @ObservationIgnored private var readAt: Date?
  @ObservationIgnored private var loading: Task<Void, Never>?

  static let limit = 3000
  static let rereadInterval: TimeInterval = 60
  /// 常去的页面：没隐藏，访问过至少 2 次或在地址栏手输过；最近的在前
  static let query = """
    SELECT url AS u, title AS t, last_visit_time AS v FROM urls
    WHERE hidden = 0 AND (visit_count >= 2 OR typed_count >= 1)
    ORDER BY last_visit_time DESC LIMIT \(limit)
    """

  /// sqlite3 的参数：-init /dev/null 不读用户的 ~/.sqliterc（里面的 .echo、.output 会往输出里掺东西或改走别处，
  /// JSON 就解析不出来了）
  static func arguments(_ path: String) -> [String] {
    ["-init", "/dev/null", "-readonly", "-json", path, query]
  }

  /// Chrome 装着、书签开关和历史开关都开着
  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: Prefs.launcherHistoryChrome) && Bookmarks.readsChrome
  }

  /// 要不要重读：没读过；或者库的修改时间变了、且距上次读满 60 秒
  static func needsReread(signature: [Date?]?, readAt: Date?, now: [Date?], at date: Date) -> Bool {
    guard let signature, let readAt else { return true }
    return signature != now && date.timeIntervalSince(readAt) >= rereadInterval
  }

  /// 呼出启动器、打开设置页时调：开关关着就清掉；该重读就在进程外读（同时只跑一个）。等它读完再返回，
  /// 返回这次有没有换上新读的行（启动器据此决定要不要重搜）
  @discardableResult func refresh(now: Date = .now) async -> Bool {
    guard Self.isEnabled, let root else {
      if signature != nil { (items, status, signature, readAt) = ([], .unknown, nil, nil) }
      return false
    }
    if let loading {
      await loading.value
      return false
    }
    let files = Bookmarks.profileFiles(named: ["History"], in: root)
    let current = files.map(Bookmarks.modified)
    guard Self.needsReread(signature: signature, readAt: readAt, now: current, at: now) else {
      return false
    }
    let task = Task {
      var pages: [Page] = []
      var read = 0
      for file in files {
        guard let copy = Bookmarks.clone(file) else { continue }
        defer { try? FileManager.default.removeItem(at: copy) }
        guard
          let result = try? await Subprocess.run(
            "/usr/bin/sqlite3", Self.arguments(copy.path), captures: true),
          result.status == 0
        else { continue }
        pages += Self.parse(Data(result.output.utf8))
        read += 1
      }
      // 一个都没读成（库正被写坏了一半这类）：留着上次的，下次呼出再试
      guard read > 0 || files.isEmpty else { return }
      items = Self.items(Self.merge(pages))
      status = files.isEmpty ? .noFile : .read(items.count)
      (signature, readAt) = (current, now)
    }
    loading = task
    await task.value
    loading = nil
    return readAt == now
  }

  // MARK: 纯函数（配单测）

  /// sqlite3 -json 的输出 → 页面；没有行时 sqlite3 什么都不输出
  static func parse(_ json: Data) -> [Page] {
    guard !json.isEmpty else { return [] }
    return (try? JSONDecoder().decode([Page].self, from: json)) ?? []
  }

  /// 几个配置的合起来：同一网址留最近的一次，最近的在前，最多 3000 条
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
