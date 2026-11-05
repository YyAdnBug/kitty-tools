// 动画表情包（2026-11-05 用户「所有图标按 URL 加载、缓存在本地」，同日改成「动画表情」「系统表情」两个入口；PLAN §10
// 「功能管理」下的记录）：「动画表情」气泡（AnimatedEmojiPicker）里挑的 Microsoft Fluent Emoji Animated（746 个，默认肤色，
// 存「pack:编号」），第一次用到时下载那个动画、缓存在本机，之后就是动的。对标 Teams、Telegram：动画表情用到时从自己的服务器
// 下载、存在本机。系统表情不走这里（永远系统样子）。
// - 对照表 Resources/emoji-pack.json（每个一条：编号、表情字、分类、CLDR 中文名、关键词；macos/emoji-pack.swift 生成）和
//   96 × 96 的缩略图 Resources/emoji-thumbs/ 打进包里；动画文件在本仓库一个单独的 release（tag 写在对照表里，不标 latest：
//   App 内更新只认 macos-v*），一个约 0.2 MB。包里自带的 28 个和眼睛不下载（bundledID）。
// - 缓存在数据目录的 emoji-pack/（<编号>.heics），不备份、不导出、不同步（另一台用到时自己下）；用一次把文件的修改时间碰成现在，
//   超过 50 MB 删最久没用的（启动时、每下好一个之后）。
// - 什么时候下：选上的那个显示到的时候（设置的图标格子、列表行、进入状态屏、全屏提醒），和气泡里鼠标停在一格 0.4 s（预览）——
//   还没下好、没联网时先垫缩略图，下好了 generation 加一，画它的视图跟着换成动画的静止画面 / 帧。同一个同时只下一次；下不成的
//   这次运行里 10 分钟内不再试。
// - 开关「自动下载动画表情」（Prefs.emojiPackDownloads，默认开，设置 › 状态屏 / 提醒两页各一行、同一个偏好）：关掉就不联网，
//   已经下好的照用。
// - 下下来的东西按不可信输入看：不超过 3 MB、解得出两帧以上、256 × 256 才存（主线程外，@concurrent 第 1 类：图片解码 / 写盘）。

import Foundation
import ImageIO
import OSLog
import Observation

@MainActor @Observable final class EmojiPack {
  static let shared = EmojiPack()

  /// 每下好一个加一：画自己挑的系统表情的视图读它，下好了跟着重画
  private(set) var generation = 0
  @ObservationIgnored private var loading: [String: Task<Bool, Never>] = [:]
  @ObservationIgnored private var failedAt: [String: Date] = [:]

  /// 对照表里的一个：编号、表情字（去掉了 U+FE0F）、分类（smileys / people / nature / travel / other）、中文名、搜索用的
  /// 中文 / 英文关键词（Unicode CLDR 的中文注释 + Fluent 的英文）
  nonisolated struct Entry: Decodable, Hashable, Sendable {
    let id: String
    let glyph: String
    let group: String
    let name: String
    let keywords: [String]
  }

  nonisolated struct Catalog: Decodable, Sendable {
    let tag: String
    let emoji: [Entry]
  }

  /// 包里的对照表；读不出来就当没有动画包（只画静态）
  nonisolated static let catalog: Catalog? = Bundle.main.url(
    forResource: "emoji-pack", withExtension: "json"
  )
  .flatMap { try? Data(contentsOf: $0) }
  .flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }

  nonisolated static let folderName = "emoji-pack"
  nonisolated static let maxCacheBytes = 50 * 1_048_576
  nonisolated static let maxFileBytes = 3 * 1_048_576
  static let retryAfter: TimeInterval = 600
  nonisolated static var folder: URL { AppDelegate.supportDirectory.appending(path: folderName) }

  /// 包里的编号和自带的不一样的那几个（其余同名）：挑到这几个字时直接用自带的文件
  nonisolated static let bundledAliases = [
    "telephone-receiver": "telephone", "busts-in-silhouette": "busts",
    "hourglass-not-done": "hourglass", "person-in-lotus-position": "lotus-position",
  ]

  /// 编号 → 那一条
  nonisolated static let entries: [String: Entry] = Dictionary(
    (catalog?.emoji ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

  nonisolated static func contains(_ id: String) -> Bool { entries[id] != nil }

  /// 一个编号的中文名
  nonisolated static func name(_ id: String) -> String? { entries[id]?.name }

  /// 包里带的小缩略图（Resources/emoji-thumbs/emoji-thumb-<编号>.heic，96 × 96，打进包里是平铺的）：还没下好动画时垫着用（一次
  /// 一张，在主线程上现解约 3–5 ms）。解好画进位图再缓存（ImageIO 给的 HEIC 每画一次重解一次，同 StatusEmoji.bitmap 的注释）
  static func thumbnail(_ id: String) -> CGImage? {
    if let cached = thumbnails.object(forKey: id as NSString) { return cached }
    guard let image = decodeThumbnail(id) else { return nil }
    thumbnails.setObject(image, forKey: id as NSString)
    return image
  }

  /// 缓存里已经解好的（没有就 nil，不解）：气泡的格子一出来先拿它，再开过一次就不闪
  static func cachedThumbnail(_ id: String) -> CGImage? {
    thumbnails.object(forKey: id as NSString)
  }

  /// 气泡的格子用：缓存里有就直接给，没有在主线程外解（@concurrent 第 1 类：图片解码），一开气泡几十格不卡主线程
  static func loadThumbnail(_ id: String) async -> CGImage? {
    if let cached = thumbnails.object(forKey: id as NSString) { return cached }
    guard let image = await decodeThumbnailInBackground(id) else { return nil }
    thumbnails.setObject(image, forKey: id as NSString)
    return image
  }

  @concurrent nonisolated private static func decodeThumbnailInBackground(_ id: String) async
    -> CGImage?
  { decodeThumbnail(id) }

  nonisolated private static func decodeThumbnail(_ id: String) -> CGImage? {
    guard contains(id),
      let url = Bundle.main.url(forResource: "emoji-thumb-" + id, withExtension: "heic"),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return nil }
    return StatusEmoji.bitmap(source, 0)
  }

  /// 解好的一张约 36 KB：最多留 300 张（约 11 MB），内存吃紧时系统自己清
  private static let thumbnails: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 300
    return cache
  }()

  /// 「动画表情」弹窗里搜（纯函数）：空格分开的词都要对上中文名、关键词或表情字本身（不分大小写）；没写词就是全部
  nonisolated static func search(_ query: String, in list: [Entry]) -> [Entry] {
    // 对照表里的字去掉了 U+FE0F；系统表情面板插进来的「❤️」带着它
    let words = query.replacingOccurrences(of: "\u{FE0F}", with: "").lowercased()
      .split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return list }
    return list.filter { entry in
      let haystack = ([entry.name, entry.glyph] + entry.keywords).map { $0.lowercased() }
      return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }
  }

  /// 动画包的编号如果是包里自带的那 28 个之一，自带的 id（不下载）
  nonisolated static func bundledID(for packID: String) -> String? {
    let id = bundledAliases[packID] ?? packID
    return StatusEmoji.ids.contains(id) ? id : nil
  }

  /// 包里带着动画文件的（自带的 28 个、眼睛）：不下载，直接用包里的
  nonisolated static func bundledFile(for packID: String) -> String? {
    bundledID(for: packID) ?? (packID == StatusEmoji.eyes ? packID : nil)
  }

  /// 缓存里的那个文件（下好了才有）
  nonisolated static func cachedURL(_ packID: String) -> URL? {
    let url = folder.appending(path: packID + ".heics")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// 开关开着才联网。单测宿主（就是 Dev 版）里一律不下：不往 Dev 版的数据目录里写、不联网
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
      && UserDefaults.standard.object(forKey: Prefs.emojiPackDownloads) as? Bool ?? true
  }

  /// 下载用的会话：不进系统的网址缓存（文件自己存一份就够了）
  private static let session = URLSession(configuration: .ephemeral)

  /// 这个表情要用到了：是动画表情包里的（「pack:编号」）、不是自带的、还没下好、开关开着，就下它。下好了（或本来就有）是 true
  @discardableResult func fetch(_ symbol: String) async -> Bool {
    guard let catalog = Self.catalog, let id = StatusEmoji.packID(symbol),
      Self.bundledFile(for: id) == nil
    else { return false }
    if let url = Self.cachedURL(id) {
      try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
      return true
    }
    guard Self.isEnabled else { return false }
    if let failed = failedAt[id], Date.now.timeIntervalSince(failed) < Self.retryAfter {
      return false
    }
    if let running = loading[id] { return await running.value }
    let task = Task { await Self.download(id, tag: catalog.tag) }
    loading[id] = task
    let done = await task.value
    loading[id] = nil
    if done {
      generation += 1
      await Self.trim()
    } else {
      failedAt[id] = .now
    }
    return done
  }

  /// 本仓库那个 release 里的文件；设了本机测试服务器（Prefs.emojiPackTestServer，发表情包之前试用）时是那里的
  nonisolated static func remoteURL(
    _ id: String, tag: String,
    testServer: String? = UserDefaults.standard.string(forKey: Prefs.emojiPackTestServer)
  ) -> URL? {
    if let testServer, let base = URL(string: testServer), base.scheme == "http",
      ["127.0.0.1", "localhost"].contains(base.host())
    {
      return base.appending(path: id + ".heics")
    }
    return URL(
      string: "https://github.com/YyAdnBug/kitty-tools/releases/download/\(tag)/\(id).heics")
  }

  private static func download(_ id: String, tag: String) async -> Bool {
    guard let url = remoteURL(id, tag: tag) else { return false }
    let request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    guard let (data, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      response.expectedContentLength <= Int64(maxFileBytes)
    else {
      Log.storage.error("动画表情没下成：\(id, privacy: .public)")
      return false
    }
    return await store(data, as: id)
  }

  /// 查过再存（先写临时名再换过去：写到一半的不会被当成好的）
  @concurrent nonisolated static func store(_ data: Data, as id: String) async -> Bool {
    guard isPlayable(data) else { return false }
    let target = folder.appending(path: id + ".heics")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// 下下来的是不是能放的动画（纯函数）：不太大、两帧以上、256 × 256
  nonisolated static func isPlayable(_ data: Data) -> Bool {
    guard data.count <= maxFileBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return false }
    return properties[kCGImagePropertyPixelWidth] as? Int == 256
      && properties[kCGImagePropertyPixelHeight] as? Int == 256
  }

  // MARK: 缓存上限

  nonisolated struct CachedFile: Equatable, Sendable {
    let name: String
    let bytes: Int
    let usedAt: Date
  }

  /// 超过上限时删哪些（纯函数）：从最久没用的删起，删到不超过为止
  nonisolated static func overflow(_ files: [CachedFile], limit: Int) -> [String] {
    var total = files.reduce(0) { $0 + $1.bytes }
    var doomed: [String] = []
    for file in files.sorted(by: { $0.usedAt < $1.usedAt }) where total > limit {
      doomed.append(file.name)
      total -= file.bytes
    }
    return doomed
  }

  /// 把缓存收到上限以内（启动时、每下好一个之后；主线程外列目录、删文件）
  @concurrent nonisolated static func trim() async {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
    let files = urls.filter { $0.pathExtension == "heics" }.compactMap { url -> CachedFile? in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return CachedFile(
        name: url.lastPathComponent, bytes: values.fileSize ?? 0,
        usedAt: values.contentModificationDate ?? .distantPast)
    }
    for name in overflow(files, limit: maxCacheBytes) {
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
  }
}
