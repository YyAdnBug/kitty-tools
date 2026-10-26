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
        pinned_at REAL, bytes INTEGER NOT NULL DEFAULT 0)
      """)
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
    source: String? = nil, saved: URL? = nil, pinned: Bool = false
  ) async -> UUID? {
    guard isOn else { return nil }
    let id = UUID()
    guard let bytes = await write(image, id: id) else { return nil }
    add(
      Item(
        id: id, kind: kind, createdAt: .now,
        pixelSize: CGSize(width: image.width, height: image.height), scale: scale, source: source,
        savedPath: saved?.path, filePath: nil, annotations: annotations,
        pinnedAt: pinned ? .now : nil, bytes: bytes))
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

  /// 改完标注回写（拍板 C4：更新同一条，原图不动）
  func update(_ id: UUID, annotations: [Annotation]) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].annotations = annotations
    try? db.execute(
      "UPDATE shots SET annotations = ? WHERE id = ?",
      [Self.encode(annotations), id.uuidString])
  }

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

  /// 原图（用时才读盘；录制的那几条没有原图）
  func image(for id: UUID) -> CGImage? { Self.decode(url(for: id)) }

  func thumbnail(for id: UUID) -> CGImage? { Self.decode(thumbnailURL(for: id)) }

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

  // MARK: 库

  private func add(_ item: Item) {
    items.insert(item, at: 0)
    try? db.execute(
      """
      INSERT INTO shots(id, kind, created_at, pixel_width, pixel_height, scale, source_name,
        saved_path, file_path, annotations, pinned_at, bytes)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        item.id.uuidString, item.kind.rawValue, item.createdAt.timeIntervalSinceReferenceDate,
        Int(item.pixelSize.width), Int(item.pixelSize.height), Double(item.scale), item.source,
        item.savedPath, item.filePath, Self.encode(item.annotations),
        item.pinnedAt?.timeIntervalSinceReferenceDate, item.bytes,
      ])
    prune()
  }

  private func reload() throws {
    items = try db.query(
      """
      SELECT id, kind, created_at, pixel_width, pixel_height, scale, source_name, saved_path,
        file_path, annotations, pinned_at, bytes FROM shots ORDER BY created_at DESC
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
        bytes: Int(row.int(11) ?? 0))
    }.compactMap { $0 }
  }

  // MARK: 图和 JSON

  /// 原图 + 缩略图写盘，返回一共多少字节（写不成返回 nil）
  private func write(_ image: CGImage, id: UUID) async -> Int? {
    let full = url(for: id)
    let thumb = thumbnailURL(for: id)
    guard let png = await ScreenshotOutput.png(image, scale: 1) else { return nil }
    let small = await Self.thumbnail(of: image)
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
