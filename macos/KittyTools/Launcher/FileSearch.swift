// 启动器的文件搜索（对标 Alfred File Search，M13）：「open 词」打开、「find 词」在访达里选中、空格开头 = open；
// 只输关键词（或一个空格）列最近打开 / 下载的文件。查 Spotlight 索引（NSMetadataQuery），零授权。
// 本机实测（2026-09-26，PLAN §10「文件搜索」）：
// - 每个词一个 `kMDItemFSName == "词*"cdw`（词首；中文按词切、拼音也能命中）用 && 连，≥ 2 个字 P50 约 40 ms；
//   子串写法「ab」要 1–17 s，1 个拉丁字母也要 1–7 s，所以不查。再去掉系统文件（~/Library 的绝大部分）。
// - 隐藏文件、包内部 Spotlight 本来不收；node_modules、build 这类占结果七八成，按路径再滤一遍。
// - 上次打开时间只有千分之一的文件有；代码目录在桌面，「最近修改 / 添加」全是源码。所以「最近的文件」=
//   30 天内打开过的 + 14 天内下载的（带下载来源 kMDItemWhereFroms），约 70 ms。
// 只读 Spotlight 给的属性（路径、名字、类型、日期），不 stat、不读文件，图标按类型取：桌面 / 文稿 / 下载里的
// 文件搜到、显示都不碰文件本身；打开交给 NSWorkspace。
// 查询在自己的串行队列上跑（文件末尾的 Spotlight，2026-11-24 用户反馈打「.xl」、删字都卡）：主线程只收拼好的 [Hit]。

import AppKit
import Synchronization
import UniformTypeIdentifiers

final class FileSearch {
  enum Mode {
    /// ↩ 打开（⌘↩ 在访达中显示）
    case open
    /// ↩ 在访达里选中（⌘↩ 打开）；修旧版回车只打开父目录（§11 #28）
    case find
  }

  struct Request: Equatable {
    var mode: Mode
    /// 空 = 只输了关键词，列最近的文件
    var terms: [String]

    /// 只有 1 个拉丁字母（或数字）的词：Spotlight 要 1–7 s，先不查。1 个汉字照查
    var isTooShort: Bool {
      !terms.isEmpty && !terms.contains(where: Self.isLongEnough)
    }

    /// 只数字母和数字：Spotlight 按词首比、标点只当分隔，「.x」和「x」一样宽（2026-11-24 本机 6118 条，
    /// 打「.xlsx」路过它时主线程读结果卡 0.6–1 s）
    static func isLongEnough(_ term: String) -> Bool {
      term.unicodeScalars.contains { !$0.isASCII }
        || term.count { $0.isLetter || $0.isNumber } >= 2
    }
  }

  /// Spotlight 找到的一个文件：只有索引里的属性（在 Spotlight 的队列上拼好，交回主线程）
  nonisolated struct Hit: Equatable {
    var path: String
    var name: String
    /// UTI（kMDItemContentType）；按它取图标、判断是不是文件夹
    var contentType: String?
    /// 最近一次打开 / 修改 / 下载的时间，排序用
    var date: Date
  }

  /// 最多列多少条（Alfred 默认 40–50）
  nonisolated static let limit = 50
  /// 最多处理多少条 Spotlight 结果：垃圾占七八成（「readme」6000 多条里九成在 node_modules），只看前面一小段会漏掉
  /// 干净的结果。读一条的路径是一次进程间调用（2026-11-24 本机 13–110 µs，Spotlight 忙时更慢），所以在队列上读。
  /// ponytail: 2 万条在队列上要 0.3–2 s（「re」近 4 万条），结果晚到、不卡输入框；要更快得换成按需分页读
  nonisolated static let processLimit = 20_000

  /// 路径上有这些目录的不要（常见的依赖和构建产物目录；隐藏目录 .git 等 Spotlight 本来就不收）
  nonisolated static let excludedFolders: Set<String> = [
    "node_modules", "bower_components", "DerivedData", "build", "dist", "target", "out", "Pods",
    "Carthage", "vendor", "venv", "__pycache__", "coverage",
  ]

  static let notSystem = #"kMDItemSupportFileType != "MDSystemFile""#
  static let recentQuery =
    #"((kMDItemLastUsedDate >= $time.today(-30)) || (kMDItemDateAdded >= $time.today(-14) && kMDItemWhereFroms == "*")) && "#
    + notSystem

  // MARK: 纯函数（配单测）

  /// 「open 词」「find 词」、空格开头（= open）；只输「open」「find」不算（出补全提示，不抢同名 App）
  static func request(for query: String) -> Request? {
    let mode: Mode
    let rest: Substring
    let lower = query.lowercased()
    if query.first?.isWhitespace == true {
      (mode, rest) = (.open, Substring(query))
    } else if lower.hasPrefix("open"), query.dropFirst(4).first?.isWhitespace == true {
      (mode, rest) = (.open, query.dropFirst(4))
    } else if lower.hasPrefix("find"), query.dropFirst(4).first?.isWhitespace == true {
      (mode, rest) = (.find, query.dropFirst(4))
    } else {
      return nil
    }
    return Request(mode: mode, terms: rest.split(whereSeparator: \.isWhitespace).map(String.init))
  }

  /// Spotlight 查询串：每个词一个词首条件（引号、星号、问号、反斜杠要转义），再去掉系统文件
  static func queryString(_ terms: [String]) -> String {
    let conditions = terms.map { term in
      let escaped = term.reduce(into: "") { result, character in
        if "\\\"*?".contains(character) { result.append("\\") }
        result.append(character)
      }
      return #"kMDItemFSName == ""# + escaped + #"*"cdw"#
    }
    return (conditions + [notSystem]).joined(separator: " && ")
  }

  /// 主目录外的、~/Library 里的（iCloud 云盘、第三方云盘除外）、路径上有 `excludedFolders` 的都不要
  nonisolated static func isExcluded(_ path: String, home: String = NSHomeDirectory()) -> Bool {
    guard path.hasPrefix(home + "/") else { return true }
    let components = path.dropFirst(home.count + 1).split(separator: "/")
    if components.first == "Library",
      !(components.count > 1 && ["Mobile Documents", "CloudStorage"].contains(components[1]))
    {
      return true
    }
    return components.dropLast().contains { excludedFolders.contains(String($0)) }
  }

  static func isFolder(_ contentType: String?) -> Bool {
    guard let type = contentType.flatMap(UTType.init) else { return false }
    // .app、.bundle 这类包在访达里是一个文件，↩ 直接打开
    return type.conforms(to: .directory) && !type.conforms(to: .package)
  }

  /// 右侧的种类：文件夹、扩展名大写（DMG、MD），没有扩展名写「文件」
  static func kindTitle(path: String, contentType: String?) -> String {
    if isFolder(contentType) { return String(localized: "文件夹") }
    let ext = (path as NSString).pathExtension
    return ext.isEmpty || ext.count > 6 ? String(localized: "文件") : ext.uppercased()
  }

  /// 副标题里的位置：~ 缩写；iCloud 云盘写成「iCloud 云盘」（原路径 ~/Library/Mobile Documents/com~apple~CloudDocs
  /// 太长，截断后看不出在哪）
  static func location(of folder: String, home: String = NSHomeDirectory()) -> String {
    let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    if folder == iCloud || folder.hasPrefix(iCloud + "/") {
      return String(localized: "iCloud 云盘") + folder.dropFirst(iCloud.count)
    }
    return (folder as NSString).abbreviatingWithTildeInPath
  }

  /// pinyin：名字转拼音全拼 + 首字母（一条约 0.12 ms）；查询词里没有拉丁字母时用不上，不转（P3）
  static func item(_ hit: Hit, pinyin withPinyin: Bool = true) -> LauncherItem {
    let (names, initials) = matchNames(hit, pinyin: withPinyin)
    let parent = location(of: (hit.path as NSString).deletingLastPathComponent)
    let path = (hit.path as NSString).abbreviatingWithTildeInPath
    return LauncherItem(
      kind: .path, target: hit.path, title: hit.name, subtitle: parent, names: names,
      initials: initials,
      // 直接给 Tab 补全的文字：通用的补全要 stat 文件判断是不是目录
      completion: isFolder(hit.contentType) ? path + "/" : path,
      // 声明这个类型的 App 卸载了时 Spotlight 还留着它的 UTI，系统却不认：按扩展名兜底，总要有个类型
      // （有类型才算文件搜索结果：find 的 ↩、图标都按它，不碰文件本身）
      contentType: hit.contentType.flatMap(UTType.init)
        ?? UTType(filenameExtension: (hit.path as NSString).pathExtension) ?? .data)
  }

  typealias MatchNames = (names: [String], initials: [String])

  /// 参与匹配的名字（文件名、去掉扩展名的、拼音全拼，折叠过、去重）和缩写：条目和主线程外的先挑一遍同一份
  nonisolated static func matchNames(_ hit: Hit, pinyin withPinyin: Bool) -> MatchNames {
    let stem = (hit.name as NSString).deletingPathExtension
    let pinyin = withPinyin ? AppCatalog.pinyin(stem) : nil
    return (
      [hit.name, stem, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
        .reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      [LauncherMatch.initials(stem), pinyin?.initials].compactMap { $0 }
    )
  }

  /// 交回主线程之前，在 Spotlight 的队列上先挑一遍：按匹配分 → 时间 → 路径深浅排出前 limit 条，再带上用过的（used：
  /// 使用记录里的文件路径，有加成、可能排上来）。主线程只给这些做行、加使用加成、按 rank 排——和全部交给它排的结果一样：
  /// 没用过的加成是 0，最终分就是匹配分，排不过这前 limit 条（它们的最终分都不低于自己的匹配分，同分时先后的比法也一样）。
  /// 2026-11-24：「␣rep」3182 条全在主线程做行、排序要 456 ms。
  /// names：同一次查询各批之间按路径记下的名字和缩写（每批都是到目前为止的全部，转拼音一条约 0.12 ms，不记就每批重转）
  nonisolated static func shortlist(
    _ hits: [Hit], terms: [String], used: Set<String>, names cache: inout [String: MatchNames]
  ) -> [Hit] {
    guard hits.count > limit else { return hits }
    let query = terms.joined(separator: " ")
    let pinyin = needsPinyin(terms)
    let ranked = hits.indices.map { index -> (index: Int, match: Double, depth: Int) in
      let hit = hits[index]
      let match: Double
      if terms.isEmpty {
        match = 1
      } else {
        let (names, initials) = cache[hit.path] ?? matchNames(hit, pinyin: pinyin)
        cache[hit.path] = (names, initials)
        match = max(LauncherMatch.score(query, names: names, initials: initials), 30)
      }
      return (index, match, hit.path.count { $0 == "/" })
    }
    // 和 rank 同样的比法；排序是稳定的，完全同分的按原来的先后
    .sorted {
      if $0.match != $1.match { return $0.match > $1.match }
      if hits[$0.index].date != hits[$1.index].date {
        return hits[$0.index].date > hits[$1.index].date
      }
      return $0.depth < $1.depth
    }
    let kept = Set(ranked.prefix(limit).map(\.index))
    // 按原来的先后交出去：完全同分时 rank 排出来的先后和全部交给它时一样
    return hits.indices.filter { kept.contains($0) || used.contains(hits[$0].path) }.map {
      hits[$0]
    }
  }

  /// 拼音只在查询词里有拉丁字母时才用得上（「季度」「2024」不会去比拼音）
  nonisolated static func needsPinyin(_ terms: [String]) -> Bool {
    terms.contains { $0.contains { $0.isASCII && $0.isLetter } }
  }

  /// 匹配分 × 使用加成（和启动器其它结果同一公式）→ 最近打开 / 修改的在前 → 路径浅的在前。
  /// Spotlight 靠驼峰切词 / 中文词中间命中、我们的匹配分为 0 的给底分 30；只输关键词时只看使用和时间。
  /// item：一条命中变成条目（启动器传按路径缓存的 `FileSearch.item(_:pinyin:)`，P3）
  static func rank(
    _ hits: [Hit], terms: [String], item: (Hit) -> LauncherItem = { FileSearch.item($0) },
    boost: (LauncherItem) -> (global: Double, query: Double)
  ) -> [LauncherItem] {
    let query = terms.joined(separator: " ")
    return hits.map { hit -> (LauncherItem, Double, Date, Int) in
      let item = item(hit)
      let match = terms.isEmpty ? 1 : max(LauncherMatch.score(query, item: item), 30)
      let (f, a) = boost(item)
      let depth = hit.path.count { $0 == "/" }
      return (item, LauncherMatch.weighted(match, global: f, query: a), hit.date, depth)
    }
    .sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      if $0.2 != $1.2 { return $0.2 > $1.2 }
      return $0.3 < $1.3
    }
    .prefix(limit).map(\.0)
  }

  /// 授权提示的目标（↩ 交给 AppDelegate：没问过就逐个弹系统框，问过就打开系统设置）
  static let accessTarget = "folder-access"

  /// 文件结果最后一行的授权提示：nil = 还没问过；空 = 都允许了，不出提示
  static func accessHint(denied: [String]?) -> LauncherItem? {
    guard let denied else {
      return LauncherItem(
        kind: .prompt, target: accessTarget, title: String(localized: "搜不到桌面、文稿、下载、iCloud 云盘里的文件？"),
        subtitle: String(localized: "↩ 允许访问（系统会逐个询问，只要一次）"))
    }
    guard !denied.isEmpty else { return nil }
    return LauncherItem(
      kind: .prompt, target: accessTarget,
      title: String(localized: "没有权限搜「\(denied.joined(separator: quotedSeparator))」里的文件"),
      subtitle: String(localized: "↩ 打开系统设置 › \(Permissions.privacyPane) › 文件和文件夹"))
  }

  /// 一串加了引号的名字（「桌面」「文稿」）里两个名字之间的那一段（同 AppDelegate）
  private static var quotedSeparator: String {
    String(localized: "list.quoted", defaultValue: "」「", comment: "「A」「B」这样一串名字里两个名字之间的那一段")
  }

  /// 单输（或拼到一半）「open」「find」时的补全提示，同网页搜索的关键词提示：正好是关键词的放最前，
  /// ≥ 2 个字的开头放本地结果后面
  static func promptItems(for query: String) -> (exact: [LauncherItem], partial: [LauncherItem]) {
    var exact: [LauncherItem] = []
    var partial: [LauncherItem] = []
    // 中文叫法和全拼只算打了一半（LauncherMatch.promptMatch）
    let prompts = [
      ("open", String(localized: "搜索文件并打开…"), ["搜索文件", "打开文件", "文件", "sousuowenjian", "wenjian"]),
      (
        "find", String(localized: "搜索文件并在访达中显示…"),
        ["查找文件", "在访达中显示", "chazhaowenjian", "chazhao"]
      ),
    ]
    for (keyword, title, aliases) in prompts {
      let item = LauncherItem(
        kind: .prompt, target: "file-" + keyword, title: title,
        subtitle: LauncherCommands.promptSubtitle("file-" + keyword, keyword: keyword) ?? "",
        completion: keyword + " ")
      switch LauncherMatch.promptMatch(query, keywords: [keyword], aliases: aliases) {
      case .exact: exact.append(item)
      case .partial: partial.append(item)
      case nil: break
      }
    }
    return (exact, partial)
  }

  // MARK: 按路径缓存的条目（P3）

  /// 每批结果都是到目前为止的全部（上限 2 万），转拼音一条约 0.12 ms，单个汉字能命中几千条：不缓存的话每到一批都要全部重转。
  /// 换查询也接着用（打字时前后两次的结果大半重叠），收起面板时清掉。
  /// ponytail: 满 2 万条整个清掉重来，要更省就换成按最近用到的淘汰
  private var items: [String: (item: LauncherItem, pinyin: Bool)] = [:]

  /// 这条命中的条目：缓存里有、且转过拼音（或这次用不上拼音）就直接用
  func item(_ hit: Hit, pinyin: Bool) -> LauncherItem {
    if let cached = items[hit.path], cached.pinyin || !pinyin { return cached.item }
    if items.count >= Self.processLimit { items.removeAll(keepingCapacity: true) }
    let item = Self.item(hit, pinyin: pinyin)
    items[hit.path] = (item, pinyin)
    return item
  }

  func forgetItems() { items = [:] }

  // MARK: 查询

  private let spotlight = Spotlight()
  /// 这一次查询的编号：换了查询、停了以后，还在路上的那一批不要
  private var generation = 0
  /// 有一次查询起了、还没停（没起过就不用每敲一个字都往队列里投一次停）
  private var isRunning = false
  private var onResults: ([Hit]) -> Void = { _ in }

  /// 开始一次查询（先停掉上一次）。结果分批到：每批都回调一次（到目前为止的全部先挑过一遍，和上一批一样的不回调），
  /// 收完或够数就停。建查询、start、读结果、先挑一遍都在 Spotlight 的队列上，这里只收拼好的 [Hit]
  /// used：使用记录里的文件路径（队列上先挑一遍时带上它们，shortlist）
  func start(
    _ request: Request, used: Set<String> = [], onResults: @escaping ([Hit]) -> Void
  ) {
    generation += 1
    isRunning = true
    let id = generation
    self.onResults = onResults
    let text = request.terms.isEmpty ? Self.recentQuery : Self.queryString(request.terms)
    spotlight.start(text, terms: request.terms, used: used, id: id) { [weak self] hits in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.onResults(hits)
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    spotlight.stop(generation)
  }
}

/// FileSearch 的 Spotlight 查询：建、start、收进度、读结果、停都在自己的串行队列上，交出来的只有 [Hit]（2026-11-24）。
/// 原来都在主线程，本机量的：start() 偶尔 100–200 ms；读一条结果的路径是一次进程间调用（13–110 µs，Spotlight 忙时更慢），
/// 「.x」6118 条一批 0.6–1 s、「re」近 4 万条 1.5 s，进度每到一批就读一遍——打字、删字时输入框跟着卡。
/// NSMetadataQuery 不是 Sendable：放在 Mutex 里、只在这个队列上碰（它的文档：start 要在 operationQueue 或主线程上调）
nonisolated private final class Spotlight: Sendable {
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "kitty.file-search"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    return queue
  }()
  /// 最新一次 start / stop 的编号：排着的那次轮到时已经不是最新的就不起（连着打字时只查最后那个词）
  private let latest = Mutex(0)
  private let running = Mutex<Running?>(nil)

  private struct Running {
    let id: Int
    let query: NSMetadataQuery
    let observers: [any NSObjectProtocol]
    /// 上一批交出去的：和它一样就不再交（收完的那一批常和最后一次进度一样，主线程不用再排一遍）
    var delivered: [FileSearch.Hit]?
    /// 先挑一遍时按路径记下的名字和缩写（FileSearch.shortlist）
    var names: [String: FileSearch.MatchNames] = [:]
  }

  private static let lastUsedDateKey = "kMDItemLastUsedDate"
  private static let dateAddedKey = "kMDItemDateAdded"

  /// terms、used：读完一批先在队列上挑一遍（FileSearch.shortlist），只把挑出来的交出去
  func start(
    _ text: String, terms: [String], used: Set<String>, id: Int,
    deliver: @escaping @Sendable ([FileSearch.Hit]) -> Void
  ) {
    latest.withLock { $0 = id }
    queue.addOperation { [self] in
      tearDown()
      guard latest.withLock({ $0 }) == id else { return }
      // 查询整个在锁里建、起：NSMetadataQuery 不是 Sendable，在外面建好再放进来编译器不让（region 检查）
      let started = running.withLock { running in
        guard let predicate = NSPredicate(fromMetadataQueryString: text) else { return false }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [
          NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
        ]
        // 预取：按下标读这几个不用每条再去 mds 取；路径预取不了，只能一条条读
        query.valueListAttributes = [
          NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey,
          NSMetadataItemFSContentChangeDateKey,
          Self.lastUsedDateKey, Self.dateAddedKey,
        ]
        // 进度和收完的通知投到这个队列上，观察者（queue: nil）就在这里跑
        query.operationQueue = queue
        let observers = [
          NSNotification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering,
        ].map { name in
          NotificationCenter.default.addObserver(forName: name, object: query, queue: nil) {
            [weak self] note in
            let finished = note.name == .NSMetadataQueryDidFinishGathering
            // 再排一次队：就算通知是在锁里（start / enableUpdates 时）同步发出来的，也只是排进队列，不会在锁里再进 collect
            self?.queue.addOperation { [weak self] in
              self?.collect(id: id, finished: finished, terms: terms, used: used, deliver: deliver)
            }
          }
        }
        running = Running(id: id, query: query, observers: observers)
        return query.start()
      }
      if !started {
        tearDown()
        deliver([])
      }
    }
  }

  func stop(_ id: Int) {
    latest.withLock { $0 = id }
    queue.addOperation { [self] in tearDown() }
  }

  private func tearDown() {
    running.withLock { running in
      running.map(Self.halt)
      running = nil
    }
  }

  /// 停掉这一次（先移除观察者再 stop）。只在 running 的锁里调
  private static func halt(_ current: Running) {
    current.observers.forEach(NotificationCenter.default.removeObserver)
    current.query.stop()
  }

  /// 进度 / 收完：读到目前为止的全部（最多 processLimit 条）；收完或够数就停
  private func collect(
    id: Int, finished: Bool, terms: [String], used: Set<String>,
    deliver: @Sendable ([FileSearch.Hit]) -> Void
  ) {
    let hits: [FileSearch.Hit]? = running.withLock { running in
      guard var current = running, current.id == id else { return nil }
      // 又打了字、停了：这一批不读了，当场停掉（排在后面的新查询不用等它读完、挑完；不调 tearDown，锁里再加锁会崩）
      let isStale = { self.latest.withLock { $0 } != id }
      guard !isStale() else {
        Self.halt(current)
        running = nil
        return nil
      }
      let query = current.query
      query.disableUpdates()
      var hits: [FileSearch.Hit] = []
      for index in 0..<min(query.resultCount, FileSearch.processLimit) {
        if index % 256 == 255, isStale() {
          Self.halt(current)
          running = nil
          return nil
        }
        guard let item = query.result(at: index) as? NSMetadataItem,
          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
          !FileSearch.isExcluded(path)
        else { continue }
        let value = { query.value(ofAttribute: $0, forResultAt: index) }
        let dates = [NSMetadataItemFSContentChangeDateKey, Self.lastUsedDateKey, Self.dateAddedKey]
          .compactMap { value($0) as? Date }
        hits.append(
          FileSearch.Hit(
            path: path,
            name: value(NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
            contentType: value(NSMetadataItemContentTypeKey) as? String,
            date: dates.max() ?? .distantPast))
      }
      hits = FileSearch.shortlist(hits, terms: terms, used: used, names: &current.names)
      let done = finished || query.resultCount >= FileSearch.processLimit
      // 和上一批一样的不交；还没收完、一条都没挑到的那批也不交（列表先留着上一次的，免得先空再长；收完还是空的照交）
      let skip = hits == current.delivered || (!done && hits.isEmpty)
      if done {
        Self.halt(current)
        running = nil
      } else {
        query.enableUpdates()
        if !hits.isEmpty { current.delivered = hits }
        running = current
      }
      return skip ? nil : hits
    }
    if let hits { deliver(hits) }
  }
}
