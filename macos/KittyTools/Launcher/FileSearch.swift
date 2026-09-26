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

import AppKit
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
      !terms.isEmpty
        && !terms.contains { $0.count >= 2 || $0.unicodeScalars.contains { !$0.isASCII } }
    }
  }

  /// Spotlight 找到的一个文件：只有索引里的属性
  struct Hit {
    var path: String
    var name: String
    /// UTI（kMDItemContentType）；按它取图标、判断是不是文件夹
    var contentType: String?
    /// 最近一次打开 / 修改 / 下载的时间，排序用
    var date: Date
  }

  /// 最多列多少条（Alfred 默认 40–50）
  static let limit = 50
  /// 最多处理多少条 Spotlight 结果：只读路径时每条约 3 µs，垃圾占七八成（「readme」6000 多条里九成在
  /// node_modules），只看前面一小段会漏掉干净的结果。ponytail: 2 万条约 60 ms，单个汉字这种更宽的词才会碰到上限
  static let processLimit = 20_000

  /// 路径上有这些目录的不要（常见的依赖和构建产物目录；隐藏目录 .git 等 Spotlight 本来就不收）
  static let excludedFolders: Set<String> = [
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
  static func isExcluded(_ path: String, home: String = NSHomeDirectory()) -> Bool {
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
    if isFolder(contentType) { return "文件夹" }
    let ext = (path as NSString).pathExtension
    return ext.isEmpty || ext.count > 6 ? "文件" : ext.uppercased()
  }

  /// 副标题里的位置：~ 缩写；iCloud 云盘写成「iCloud 云盘」（原路径 ~/Library/Mobile Documents/com~apple~CloudDocs
  /// 太长，截断后看不出在哪）
  static func location(of folder: String, home: String = NSHomeDirectory()) -> String {
    let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    if folder == iCloud || folder.hasPrefix(iCloud + "/") {
      return "iCloud 云盘" + folder.dropFirst(iCloud.count)
    }
    return (folder as NSString).abbreviatingWithTildeInPath
  }

  static func item(_ hit: Hit) -> LauncherItem {
    let stem = (hit.name as NSString).deletingPathExtension
    let pinyin = AppCatalog.pinyin(stem)
    let parent = location(of: (hit.path as NSString).deletingLastPathComponent)
    let path = (hit.path as NSString).abbreviatingWithTildeInPath
    return LauncherItem(
      kind: .path, target: hit.path, title: hit.name, subtitle: parent,
      names: [hit.name, stem, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
        .reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      initials: [LauncherMatch.initials(stem), pinyin?.initials].compactMap { $0 },
      // 直接给 Tab 补全的文字：通用的补全要 stat 文件判断是不是目录
      completion: isFolder(hit.contentType) ? path + "/" : path,
      // 声明这个类型的 App 卸载了时 Spotlight 还留着它的 UTI，系统却不认：按扩展名兜底，总要有个类型
      // （有类型才算文件搜索结果：find 的 ↩、图标都按它，不碰文件本身）
      contentType: hit.contentType.flatMap(UTType.init)
        ?? UTType(filenameExtension: (hit.path as NSString).pathExtension) ?? .data)
  }

  /// 匹配分 × 使用加成（和启动器其它结果同一公式）→ 最近打开 / 修改的在前 → 路径浅的在前。
  /// Spotlight 靠驼峰切词 / 中文词中间命中、我们的匹配分为 0 的给底分 30；只输关键词时只看使用和时间
  static func rank(
    _ hits: [Hit], terms: [String], boost: (LauncherItem) -> (global: Double, query: Double)
  ) -> [LauncherItem] {
    let query = terms.joined(separator: " ")
    return hits.map { hit -> (LauncherItem, Double, Date, Int) in
      let item = item(hit)
      let match = terms.isEmpty ? 1 : max(LauncherMatch.score(query, item: item), 30)
      let (f, a) = boost(item)
      let depth = hit.path.count { $0 == "/" }
      return (item, match * (1 + 0.5 * f / (f + 3) + a / (a + 2)), hit.date, depth)
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
        kind: .prompt, target: accessTarget, title: "搜不到桌面、文稿、下载、iCloud 云盘里的文件？",
        subtitle: "↩ 允许访问（系统会逐个询问，只要一次）")
    }
    guard !denied.isEmpty else { return nil }
    return LauncherItem(
      kind: .prompt, target: accessTarget,
      title: "没有权限搜" + denied.map { "「\($0)」" }.joined() + "里的文件",
      subtitle: "↩ 打开系统设置 › 隐私与安全性 › 文件和文件夹")
  }

  /// 单输（或拼到一半）「open」「find」时的补全提示，同网页搜索的关键词提示：正好是关键词的放最前，
  /// ≥ 2 个字的开头放本地结果后面
  static func promptItems(for query: String) -> (exact: [LauncherItem], partial: [LauncherItem]) {
    let text = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    var exact: [LauncherItem] = []
    var partial: [LauncherItem] = []
    for (keyword, title) in [("open", "搜索文件并打开…"), ("find", "搜索文件并在访达中显示…")] {
      let item = LauncherItem(
        kind: .prompt, target: "file-" + keyword, title: title,
        subtitle: "输入「\(keyword) 空格 文件名」，↩ 或 Tab 补全关键词", completion: keyword + " ")
      if text == keyword {
        exact.append(item)
      } else if text.count >= 2, keyword.hasPrefix(text) {
        partial.append(item)
      }
    }
    return (exact, partial)
  }

  // MARK: 查询

  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var onResults: ([Hit]) -> Void = { _ in }

  /// 开始一次查询（先停掉上一次）。结果分批到：每批都回调一次（第一批通常就是全部），收完或够数就停
  func start(_ request: Request, onResults: @escaping ([Hit]) -> Void) {
    stop()
    let text = request.terms.isEmpty ? Self.recentQuery : Self.queryString(request.terms)
    guard let predicate = NSPredicate(fromMetadataQueryString: text) else { return onResults([]) }
    let query = NSMetadataQuery()
    query.predicate = predicate
    query.searchScopes = [NSMetadataQueryUserHomeScope]
    query.sortDescriptors = [
      NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
    ]
    // 预取：按下标读这几个不用每条再去 mds 取（每条每个属性约 0.2 ms）；路径预取不了，单独读也很便宜
    query.valueListAttributes = [
      NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey, NSMetadataItemFSContentChangeDateKey,
      Self.lastUsedDateKey, Self.dateAddedKey,
    ]
    self.query = query
    self.onResults = onResults
    observers = [.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering].map {
      NotificationCenter.default.addObserver(forName: $0, object: query, queue: .main) {
        [weak self] notification in
        let finished = notification.name == .NSMetadataQueryDidFinishGathering
        MainActor.assumeIsolated { self?.deliver(finished: finished) }
      }
    }
    if !query.start() { stop() }
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    query?.stop()
    query = nil
  }

  private static let lastUsedDateKey = "kMDItemLastUsedDate"
  private static let dateAddedKey = "kMDItemDateAdded"

  private func deliver(finished: Bool) {
    guard let query else { return }
    query.disableUpdates()
    var hits: [Hit] = []
    for index in 0..<min(query.resultCount, Self.processLimit) {
      guard let item = query.result(at: index) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
        !Self.isExcluded(path)
      else { continue }
      let value = { query.value(ofAttribute: $0, forResultAt: index) }
      let dates = [NSMetadataItemFSContentChangeDateKey, Self.lastUsedDateKey, Self.dateAddedKey]
        .compactMap { value($0) as? Date }
      hits.append(
        Hit(
          path: path,
          name: value(NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
          contentType: value(NSMetadataItemContentTypeKey) as? String,
          date: dates.max() ?? .distantPast))
    }
    let onResults = onResults
    if finished || query.resultCount >= Self.processLimit {
      stop()
    } else {
      query.enableUpdates()
    }
    onResults(hits)
  }
}
