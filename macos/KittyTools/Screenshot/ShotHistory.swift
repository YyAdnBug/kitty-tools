// 截图历史（2026-10-26 拍板，macos/build/research/shot-history-2026-10-26/decisions.html）：截图、长截图、钉过的、
// 录屏、录音、GIF 都进这一个历史（拍板 B1：识字和翻译不产出图，不进）。
// 每条存**原图 + 标注（JSON）+ 一张小缩略图**，拷贝 / 存储 / 钉图要的成品图用时再合成（拍板 A1）——标注和原图分开存
// 才能回头接着改，成品再存一份就是双倍磁盘。录制的只记文件路径和一张封面，不复制那个文件。
// 自己一个库（拍板 A2）：<数据目录>/shots/<id>.png 是原图、<id>-t.png 是缩略图，记录在主库的 shots 表，
// 和剪贴板的图片库各管各的（拷贝出去的截图照旧也进剪贴板历史）。
// 留 30 天、总共最多 2 GB，超了先删最旧的（拍板 A3，Prefs.shotHistoryDays / shotHistoryBytes）；
// 「保留截图历史」关掉后不再记、已记的留着（拍板 B3，Prefs.shotHistory）。历史不进全局同步（图太大）。
// 写图、编码都在 @concurrent 里做，主线程只写一行库。

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// 历史里一条的那几样操作（AppDelegate 接到截图那条路上：拷贝、快速保存、另存为、钉到屏幕、识字并拷贝、改标注）。
/// 截图历史窗口（ShotHistoryModel）和晾衣绳（Clothesline）共用一份，不各接一遍
@MainActor struct ShotActions {
  var copy: @MainActor (ShotHistory.Item) -> Void = { _ in }
  var save: @MainActor (ShotHistory.Item) -> Void = { _ in }
  var saveAs: @MainActor (ShotHistory.Item) -> Void = { _ in }
  var pin: @MainActor (ShotHistory.Item) -> Void = { _ in }
  var recognize: @MainActor (ShotHistory.Item) -> Void = { _ in }
  var edit: @MainActor (ShotHistory.Item) -> Void = { _ in }
  /// 「从历史里删掉」：照历史的规矩问一次（AppDelegate 打开历史窗口、在那里问，拍板 D2）
  var forget: @MainActor (ShotHistory.Item) -> Void = { _ in }
  /// 「在历史里看」：打开截图历史窗口
  var openHistory: @MainActor () -> Void = {}
  /// 说一句（接到刘海岛上，第二个参数是警告不警告）：Island.announce 只给读屏，用户看不见
  var notice: @MainActor (String, Bool) -> Void = { _, _ in }
}

@MainActor @Observable final class ShotHistory {
  /// 这一条是什么（录制的三种只记文件）
  enum Kind: String, Codable, CaseIterable, Sendable {
    case shot, scroll, video, audio, gif

    var title: String {
      switch self {
      case .shot: "截图"
      case .scroll: "长截图"
      case .video: "录屏"
      case .audio: "录音"
      case .gif: "GIF"
      }
    }
  }

  struct Item: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: Kind
    var createdAt: Date
    /// 原图的像素尺寸（录制的是封面的）
    var pixelSize: CGSize
    /// 像素 / 点
    var scale: CGFloat
    /// 截的时候前台是哪个 App
    var source: String?
    /// 存过盘的话存到哪了（文件可能被挪走、删掉，拍板 D2：那一条照常能看能改）
    var savedPath: String?
    /// 录制的那个文件
    var filePath: String?
    /// 当初画的标注（拍板 A1：回头接着改用的）
    var annotations: [Annotation] = []
    /// 钉过的时间（拍板 B2：历史里能再钉出来）
    var pinnedAt: Date?
    /// 当初在屏幕上框的那一块（点，全局坐标）：钉回原来的位置用（拍板 B2）；录制的没有
    var frame: CGRect?
    /// 原图 + 缩略图占多少字节（算总量上限用）
    var bytes: Int = 0
  }

  /// 新的在前
  private(set) var items: [Item] = []
  private let db: Database
  private let directory: URL
  /// 开关和上限读哪儿（单测注入临时域）
  var defaults = UserDefaults.standard

  /// 缩略图最长边（历史窗口的网格用，第 2 批）
  nonisolated static let thumbnailSide = 480

  init(db: Database, directory: URL) throws {
    self.db = db
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS shots(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL,
        created_at REAL NOT NULL, -- Date.timeIntervalSinceReferenceDate，读写无精度损失
        pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL, scale REAL NOT NULL,
        source_name TEXT, saved_path TEXT, file_path TEXT,
        annotations TEXT, -- [Annotation] 的 JSON（拍板 A1）
        pinned_at REAL, bytes INTEGER NOT NULL DEFAULT 0,
        frame TEXT) -- 当初框的那一块（NSStringFromRect），钉回原位用
      """)
    // 旧库补列（幂等，每次启动都跑）
    if try !db.query("PRAGMA table_info(shots)", row: { $0.text(1) }).contains("frame") {
      try db.execute("ALTER TABLE shots ADD COLUMN frame TEXT")
    }
    try db.execute("CREATE INDEX IF NOT EXISTS shots_created_at ON shots(created_at DESC)")
    try reload()
    prune()  // 关了几天再开：过期的这时就清掉，不等下一次截图
  }

  /// 记不记（功能关着、「保留截图历史」关掉时整个不记）
  var isOn: Bool { Feature.screenshot.isOn && defaults.bool(forKey: Prefs.shotHistory) }

  // MARK: 记一条

  /// 截图 / 长截图：原图和缩略图写盘、入库。返回这一条的 id（没记返回 nil）
  @discardableResult func record(
    _ image: CGImage, scale: CGFloat, kind: Kind = .shot, annotations: [Annotation] = [],
    source: String? = nil, saved: URL? = nil, pinned: Bool = false, frame: CGRect? = nil
  ) async -> UUID? {
    guard isOn else { return nil }
    let id = UUID()
    guard let bytes = await write(image, id: id, annotations: annotations, scale: scale) else {
      return nil
    }
    add(
      Item(
        id: id, kind: kind, createdAt: .now,
        pixelSize: CGSize(width: image.width, height: image.height), scale: scale, source: source,
        savedPath: saved?.path, filePath: nil, annotations: annotations,
        pinnedAt: pinned ? .now : nil, frame: frame, bytes: bytes))
    return id
  }

  /// 录屏 / 录音 / GIF：文件归快速保存的文件夹管，这里只记路径和一张封面（拍板 B1）
  @discardableResult func record(
    file: URL, poster: CGImage?, kind: Kind, scale: CGFloat = 2, source: String? = nil
  ) async -> UUID? {
    guard isOn else { return nil }
    let id = UUID()
    let bytes = poster == nil ? 0 : await write(poster!, id: id)
    add(
      Item(
        id: id, kind: kind, createdAt: .now,
        pixelSize: poster.map { CGSize(width: $0.width, height: $0.height) } ?? .zero, scale: scale,
        source: source, savedPath: file.path, filePath: file.path, bytes: bytes ?? 0))
    return id
  }

  /// 改完标注回写（拍板 C4：更新同一条，原图不动）。
  /// **缩略图跟着重做**：它画的是成品（原图 + 标注），不重做的话历史里看着像没改过
  /// （2026-10-26 用户手测报的）
  func update(_ id: UUID, annotations: [Annotation]) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].annotations = annotations
    try? db.execute(
      "UPDATE shots SET annotations = ? WHERE id = ?",
      [Self.encode(annotations), id.uuidString])
    let item = items[index]
    Task {
      guard let original = image(for: id) else { return }
      let composed = Self.compose(original, annotations: annotations, scale: item.scale)
      guard let small = await Self.thumbnail(of: composed) else { return }
      try? small.write(to: thumbnailURL(for: id), options: .atomic)
      onThumbnailChanged(id)
    }
  }

  /// 某一条的缩略图重做好了（历史窗口清掉它的缓存、重画那张卡）
  @ObservationIgnored var onThumbnailChanged: (UUID) -> Void = { _ in }

  /// 存过盘了 / 又钉了一次：历史里那条跟着记上
  func markSaved(_ id: UUID, to url: URL) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].savedPath = url.path
    try? db.execute(
      "UPDATE shots SET saved_path = ? WHERE id = ?", [url.path, id.uuidString])
  }

  func markPinned(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let now = Date.now
    items[index].pinnedAt = now
    try? db.execute(
      "UPDATE shots SET pinned_at = ? WHERE id = ?",
      [now.timeIntervalSinceReferenceDate, id.uuidString])
  }

  // MARK: 读

  // MARK: 拖出去

  /// 拖出去的那一份：存过的就是存的那个文件、录制的就是那段录像（名字是用户自己的），别的在临时目录里写一份
  /// 成品 PNG（原图 + 标注），名字同快速保存。写过的留着，同一条再拖不重写；那个目录启动时清空
  /// （ShotShelf.dragDirectory）
  func dragFile(for item: Item) async -> URL? {
    if let path = item.filePath ?? item.savedPath, FileManager.default.fileExists(atPath: path) {
      return URL(filePath: path)
    }
    if let made = dragFiles[item.id], FileManager.default.fileExists(atPath: made.path) {
      return made
    }
    guard let image = composed(item), let png = await ScreenshotOutput.png(image, scale: item.scale)
    else { return nil }
    let url = ScreenshotOutput.availableURL(in: ShotShelf.dragDirectory, date: item.createdAt)
    guard await Self.write(png, to: url) else { return nil }
    dragFiles[item.id] = url
    return url
  }

  /// 写临时文件（几 MB 到几十 MB，不在主线程写）
  @concurrent nonisolated static func write(_ png: Data, to url: URL) async -> Bool {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? png.write(to: url)) != nil
  }

  /// 拖出去给别的 App 的那一份（历史窗口、晾衣绳都用这个文件，见 dragFile）。
  /// **成品 PNG 是落到别人手上那一刻才合成写盘的**：历史里成百上千条，不像绳子上那 8 张能先备好
  func dragProvider(for item: Item) -> NSItemProvider {
    if let path = item.filePath ?? item.savedPath, FileManager.default.fileExists(atPath: path),
      let provider = NSItemProvider(contentsOf: URL(filePath: path))
    {
      provider.suggestedName = (path as NSString).lastPathComponent  // 自己写上，不是每次都有
      return provider
    }
    let provider = NSItemProvider()
    provider.registerFileRepresentation(
      for: .png, visibility: .all, openInPlace: false
    ) { [weak self] completion in
      // 系统给的回调没标 sending，挪进 Task 里编译器拦；只在主 actor 上调一次，安全
      nonisolated(unsafe) let finish = completion
      Task { @MainActor in
        guard let url = await self?.dragFile(for: item) else {
          return finish(nil, false, CocoaError(.fileNoSuchFile))
        }
        finish(url, false, nil)
      }
      return nil
    }
    return provider
  }

  /// 已经写好的那几份（按 id）：同一条拖第二次不重写
  @ObservationIgnored private var dragFiles: [UUID: URL] = [:]

  /// 原图（用时才读盘；录制的那几条没有原图）
  func image(for id: UUID) -> CGImage? { Self.decode(url(for: id)) }

  /// 成品图（原图 + 标注）：没画标注就是原图本身，不白渲一遍（拍板 A1、C2）。
  /// 拷贝 / 存储 / 钉图、缩略图都走它
  func composed(_ item: Item) -> CGImage? {
    guard let original = image(for: item.id) else { return nil }
    return Self.compose(original, annotations: item.annotations, scale: item.scale)
  }

  /// 纯函数：把标注画到原图上（标注的坐标是这张图的点坐标）。
  /// Annotation.render 是 MainActor 的（它只碰图和路径，没有共享状态）：这里留在主 actor 上
  static func compose(
    _ original: CGImage, annotations: [Annotation], scale: CGFloat
  ) -> CGImage {
    guard !annotations.isEmpty else { return original }
    let pixels = CGRect(x: 0, y: 0, width: original.width, height: original.height)
    let points = CGSize(
      width: CGFloat(original.width) / scale, height: CGFloat(original.height) / scale)
    return Annotation.render(annotations, over: original, pixelRect: pixels, viewSize: points)
      ?? original
  }

  func thumbnail(for id: UUID) -> CGImage? { Self.decode(thumbnailURL(for: id)) }

  /// 这一条存过 / 录下来的那个文件还在不在（拍板 D2：不在了那一条照常能看能改）
  static func fileExists(_ item: Item) -> Bool {
    guard let path = item.filePath ?? item.savedPath else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  /// 在访达中显示（历史窗口、晾衣绳共用）：只有存过盘（或录制的那几条）才有文件；没存过的那条
  /// 历史窗口里那一项是灰的，真点到了也说一声——只调 Island.announce（读屏播报）的话，看着就是
  /// 「点了没反应」（2026-10-26 用户手测报的）
  static func reveal(_ item: Item, notice: (String, Bool) -> Void) {
    guard let path = item.filePath ?? item.savedPath else {
      return notice("这张还没存成文件，先「存储到…」", false)
    }
    guard fileExists(item) else { return notice("文件已经不在了", true) }
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
  }

  /// 用默认 App 打开（录制的那几条）
  static func open(_ item: Item, notice: (String, Bool) -> Void) {
    guard let path = item.filePath, fileExists(item) else {
      return notice("文件已经不在了", true)
    }
    NSWorkspace.shared.open(URL(filePath: path))
  }

  func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).png") }

  func thumbnailURL(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString)-t.png") }

  // MARK: 删

  func remove(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    let doomed = Set(ids)
    items.removeAll { doomed.contains($0.id) }
    for id in ids {
      try? db.execute("DELETE FROM shots WHERE id = ?", [id.uuidString])
      try? FileManager.default.removeItem(at: url(for: id))
      try? FileManager.default.removeItem(at: thumbnailURL(for: id))
    }
  }

  /// 设置里的「现在清空」（第 4 批）：记录和图都删掉，录制的文件不动（它归快速保存的文件夹管）
  func clear() { remove(items.map(\.id)) }

  /// 过期的、超总量的清掉（每次记一条之后跑一遍）
  func prune() {
    remove(
      Self.stale(
        items, now: .now, days: defaults.integer(forKey: Prefs.shotHistoryDays),
        limit: defaults.integer(forKey: Prefs.shotHistoryBytes)))
  }

  /// 该删哪些：过期的（days > 0 时），以及从新到旧累计超过 limit 之后的那些（limit > 0 时）。
  /// 最新那条不按总量删——上限设得比一张图还小的话，刚截完就没了。纯函数，配单测
  static func stale(_ items: [Item], now: Date, days: Int, limit: Int) -> [UUID] {
    var doomed: [UUID] = []
    var total = 0
    let cutoff = days > 0 ? now.addingTimeInterval(-Double(days) * 86400) : .distantPast
    for (index, item) in items.sorted(by: { $0.createdAt > $1.createdAt }).enumerated() {
      if item.createdAt < cutoff {
        doomed.append(item.id)
        continue
      }
      total += item.bytes
      if limit > 0, total > limit, index > 0 { doomed.append(item.id) }
    }
    return doomed
  }

  /// 截图自检直接摆几条（不写盘、不入库）
  func seed(_ items: [Item]) { self.items = items }

  // MARK: 库

  private func add(_ item: Item) {
    items.insert(item, at: 0)
    try? db.execute(
      """
      INSERT INTO shots(id, kind, created_at, pixel_width, pixel_height, scale, source_name,
        saved_path, file_path, annotations, pinned_at, bytes, frame)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        item.id.uuidString, item.kind.rawValue, item.createdAt.timeIntervalSinceReferenceDate,
        Int(item.pixelSize.width), Int(item.pixelSize.height), Double(item.scale), item.source,
        item.savedPath, item.filePath, Self.encode(item.annotations),
        item.pinnedAt?.timeIntervalSinceReferenceDate, item.bytes,
        item.frame.map(NSStringFromRect),
      ])
    prune()
  }

  private func reload() throws {
    items = try db.query(
      """
      SELECT id, kind, created_at, pixel_width, pixel_height, scale, source_name, saved_path,
        file_path, annotations, pinned_at, bytes, frame FROM shots ORDER BY created_at DESC
      """
    ) { row -> Item? in
      guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
        let kind = row.text(1).flatMap(Kind.init(rawValue:)), let created = row.double(2)
      else { return nil }
      return Item(
        id: id, kind: kind, createdAt: Date(timeIntervalSinceReferenceDate: created),
        pixelSize: CGSize(width: Int(row.int(3) ?? 0), height: Int(row.int(4) ?? 0)),
        scale: CGFloat(row.double(5) ?? 2), source: row.text(6), savedPath: row.text(7),
        filePath: row.text(8), annotations: row.text(9).flatMap(Self.decode) ?? [],
        pinnedAt: row.double(10).map(Date.init(timeIntervalSinceReferenceDate:)),
        frame: row.text(12).map(NSRectFromString), bytes: Int(row.int(11) ?? 0))
    }.compactMap { $0 }
  }

  // MARK: 图和 JSON

  /// 原图 + 缩略图写盘，返回一共多少字节（写不成返回 nil）
  /// 原图写 <id>.png，缩略图写 <id>-t.png——**缩略图画的是成品**（原图 + 标注），
  /// 历史里一眼看到的就是最后那张的样子
  private func write(_ image: CGImage, id: UUID, annotations: [Annotation] = [], scale: CGFloat = 2)
    async -> Int?
  {
    let full = url(for: id)
    let thumb = thumbnailURL(for: id)
    guard let png = await ScreenshotOutput.png(image, scale: 1) else { return nil }
    let small = await Self.thumbnail(
      of: Self.compose(image, annotations: annotations, scale: scale))
    return await Self.writeFiles(png: png, to: full, thumbnail: small, to: thumb)
  }

  nonisolated private static func writeFiles(
    png: Data, to full: URL, thumbnail: Data?, to thumb: URL
  ) async -> Int? {
    do {
      try png.write(to: full, options: .atomic)
      try thumbnail?.write(to: thumb, options: .atomic)
      return png.count + (thumbnail?.count ?? 0)
    } catch {
      return nil
    }
  }

  /// 缩略图：最长边 thumbnailSide（本来就小的不放大）
  nonisolated private static func thumbnail(of image: CGImage) async -> Data? {
    let side = max(image.width, image.height)
    guard side > thumbnailSide else { return await ScreenshotOutput.png(image, scale: 1) }
    let ratio = Double(thumbnailSide) / Double(side)
    let size = CGSize(
      width: max(Int(Double(image.width) * ratio), 1),
      height: max(Int(Double(image.height) * ratio), 1))
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(origin: .zero, size: size))
    guard let small = context.makeImage() else { return nil }
    return await ScreenshotOutput.png(small, scale: 1)
  }

  nonisolated private static func decode(_ url: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: url),
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// 标注 ↔ JSON（拍板 A1）。纯函数，配单测
  nonisolated static func encode(_ annotations: [Annotation]) -> String? {
    guard !annotations.isEmpty, let data = try? JSONEncoder().encode(annotations) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  nonisolated static func decode(_ json: String) -> [Annotation]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([Annotation].self, from: data)
  }
}
