// 动画表情包（2026-11-05 用户「所有图标按 URL 加载、缓存在本地」；PLAN §10「功能管理」下的记录）：挑的系统表情
// （StatusEmoji.isCustom）在 Microsoft Fluent Emoji Animated 里有动画版（746 个，默认肤色），用到时下载那个动画、缓存在本机，
// 之后就是动的。对标 Teams、Telegram：动画表情用到时从自己的服务器下载、存在本机。
// - 对照表 Resources/emoji-pack.json（表情字 → 编号，去掉 U+FE0F；macos/emoji-pack.swift 生成）打进包里；文件在本仓库一个单独
//   的 release（tag 写在对照表里，不标 latest：App 内更新只认 macos-v*），一个约 0.2 MB。包里自带的 28 个不下载（bundledID）。
// - 缓存在数据目录的 emoji-pack/（<编号>.heics），不备份、不导出、不同步（另一台用到时自己下）；用一次把文件的修改时间碰成现在，
//   超过 50 MB 删最久没用的（启动时、每下好一个之后）。
// - 什么时候下：显示到它的时候（设置的图标格子、列表行、进入状态屏、全屏提醒）——还没下好、没联网时先画系统表情字（静态），
//   下好了 generation 加一，画它的视图跟着换成动画的静止画面 / 帧。同一个同时只下一次；下不成的这次运行里 10 分钟内不再试。
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

  nonisolated struct Catalog: Decodable, Sendable {
    let tag: String
    let emoji: [String: String]
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

  /// 表情字 → 动画包里的编号（纯函数；去掉表情变体符再查）。没有动画版是 nil
  nonisolated static func id(for glyph: String, in catalog: Catalog? = catalog) -> String? {
    catalog?.emoji[glyph.replacingOccurrences(of: "\u{FE0F}", with: "")]
  }

  /// 对照表里有的全部编号
  nonisolated static let ids: Set<String> = Set(catalog?.emoji.values ?? [:].values)

  nonisolated static func contains(_ id: String) -> Bool { ids.contains(id) }

  /// 一个编号的名字（第 2 批换成中文名）
  nonisolated static func name(_ id: String) -> String? {
    contains(id) ? id.replacingOccurrences(of: "-", with: " ") : nil
  }

  /// 动画包的编号如果是包里自带的那 28 个之一，自带的 id（不下载）
  nonisolated static func bundledID(for packID: String) -> String? {
    let id = bundledAliases[packID] ?? packID
    return StatusEmoji.ids.contains(id) ? id : nil
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
      Self.bundledID(for: id) == nil
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
