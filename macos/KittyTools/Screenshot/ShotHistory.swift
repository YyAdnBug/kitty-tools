// 截图历史（2026-10-26 拍板，macos/build/research/shot-history-2026-10-26/decisions.html）：截图、长截图、钉过的、
// 录屏、录音、GIF 都进这一个历史（拍板 B1：识字和翻译不产出图，不进）。
// 每条存**原图 + 标注（JSON）+ 一张小缩略图**，拷贝 / 存储 / 钉图要的成品图用时再合成（拍板 A1）——标注和原图分开存
// 才能回头接着改，成品再存一份就是双倍磁盘。录制的只记文件路径和一张封面，不复制那个文件。
// 自己一个库（拍板 A2）：<数据目录>/shots/<id>.png 是原图、<id>-t.png 是缩略图，记录在主库的 shots 表，
// 和剪贴板的图片库各管各的（拷贝出去的截图照旧也进剪贴板历史）。
// 留 30 天、总共最多 2 GB，超了先删最旧的（拍板 A3，Prefs.shotHistoryDays / shotHistoryMegabytes）；
// 「保留截图历史」关掉后不再记、已记的留着（拍板 B3，Prefs.shotHistory）。历史不进全局同步（图太大）。
// 写图、编码、读原图、删掉的那几条的原图和缩略图都在 @concurrent 里做，主线程只写库（第三轮体检 R6 B9：原来
// writeFiles / thumbnail 没标 @concurrent，其实在主线程上跑）；拖出去用的临时文件一个都不删（见 dragFile）。
// **记历史不挡出图**：截图那条路先拷贝 / 存储 / 钉图，这里在后面并行记，拷贝 / 存储编好的那份 PNG 直接拿来当原图
// （历史也按 72 × 倍率的 DPI 编，没画标注时两份一模一样），缩略图用现成的成品图做。

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
  /// 多选时一起做（2026-10-27）：拷贝写成几个文件进剪贴板（剪贴板只装得下一张图），存储一次说一句话
  var copyMany: @MainActor ([ShotHistory.Item]) -> Void = { _ in }
  var saveMany: @MainActor ([ShotHistory.Item]) -> Void = { _ in }
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
  private(set) var items: [Item] = [] {
    didSet {
      positions = Dictionary(
        items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
      revision &+= 1
    }
  }
  /// 按编号找在第几条（晾衣绳每帧要找挂着的那几条，P2：原来每张卡都在整个历史里线性找一遍）
  @ObservationIgnored private var positions: [UUID: Int] = [:]
  /// items 变一次加一（历史窗口按它缓存分组，不用每次比整个数组）
  private(set) var revision = 0
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

  /// 这一条（按编号，O(1)）
  func item(_ id: UUID) -> Item? { positions[id].map { items[$0] } }

  /// 截图 / 长截图：原图和缩略图写盘、入库。返回这一条的 id（没记返回 nil）。
  /// png：拷贝 / 存储时已经编好的原图（R6：同一张图不再编第二遍；nil 就在这里编）；
  /// composed：成品图（原图 + 标注），缩略图照它缩（nil 就在这里合成）
  @discardableResult func record(
    _ image: CGImage, png: Data? = nil, composed: CGImage? = nil, scale: CGFloat,
    kind: Kind = .shot, annotations: [Annotation] = [], source: String? = nil, saved: URL? = nil,
    pinned: Bool = false, frame: CGRect? = nil
  ) async -> UUID? {
    guard isOn else { return nil }
    let id = UUID()
    let shown = composed ?? Self.compose(image, annotations: annotations, scale: scale)
    guard let bytes = await write(image, png: png, thumbnailOf: shown, scale: scale, id: id) else {
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
    let bytes = poster == nil ? 0 : await write(poster!, thumbnailOf: poster!, scale: 1, id: id)
    add(
      Item(
        id: id, kind: kind, createdAt: .now,
        pixelSize: poster.map { CGSize(width: $0.width, height: $0.height) } ?? .zero, scale: scale,
        source: source, savedPath: file.path, filePath: file.path, bytes: bytes ?? 0))
    return id
  }

  /// 改完标注回写（拍板 C4：更新同一条，原图不动）。
  /// **缩略图跟着重做**：它画的是成品（原图 + 标注），不重做的话历史里看着像没改过
  /// （2026-10-26 用户手测报的）。composed 是标注窗口出图时那张成品，缩略图直接照它缩——原来在主线程上读整张原图、
  /// 全分辨率再合成一遍（长截图 3000 × 30000 时内存翻几倍，第三轮体检 R6）。标注没变就什么都不做。
  /// 拖出去的那份旧的不再用（R2：原来照旧拖它，改完标注拖出去的还是旧图）
  func update(_ id: UUID, annotations: [Annotation], composed: CGImage) {
    guard let index = items.firstIndex(where: { $0.id == id }),
      items[index].annotations != annotations
    else { return }
    items[index].annotations = annotations
    try? db.execute(
      "UPDATE shots SET annotations = ? WHERE id = ?",
      [Self.encode(annotations), id.uuidString])
    // 拖出去的那份不再用（下次重做）；文件不删，见 dragFile
    dragFiles[id] = nil
    Task {
      // 这几步之间可能又改了一回（识字不关窗口，接着改再拷贝）、或者整条删了：只认最后那次，删了的别留孤儿缩略图
      guard let small = await Self.thumbnail(of: composed),
        item(id)?.annotations == annotations,
        await Self.write(small, to: thumbnailURL(for: id))
      else { return }
      guard let now = item(id) else {
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
        return
      }
      if now.annotations == annotations { onThumbnailChanged(id) }
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

  // MARK: 拖出去

  /// 拖出去的那一份（历史窗口用它；晾衣绳先 await 它把截图那份备好，拖的那一下用 dragFileNow）。
  /// 都放在拖出目录里、每次一个新文件夹（ShotShelf.dragDirectory）。**一个都不删**：拖进邮件、聊天的附件可能还在读
  /// （ShotShelf 的老规矩），留给下次启动时清空整个目录——改完标注、删掉一条只是不再用旧的那份。
  /// - 截图 / 长截图：**一律是历史里的原图 + 现在的标注**（第三轮体检 R2：原来存过的就拖存的那个文件，改完标注
  ///   拖出去的还是旧图）。存过的只借它的文件名。没画标注的直接克隆那张原图（不解码再编码：长截图整张解开要几百 MB）。
  ///   做好的记着，同一条再拖不重做。
  /// - 录屏 / 录音 / GIF：拖的那一下才克隆（dragFileNow；R3：晾衣绳允许拖进废纸篓，拖原文件的话扔掉的就是用户的录像）。
  ///   不先备着：克隆和原文件共用数据块，用户删了原录像、空间要等克隆也没了才回来
  func dragFile(for item: Item) async -> URL? {
    if item.filePath != nil { return dragFileNow(for: item) }
    if let made = dragFileNow(for: item) { return made }
    let target = Self.freshFolder().appending(path: dragName(for: item))
    var cloned = false
    if item.annotations.isEmpty {
      cloned = await Self.cloneOriginal(url(for: item.id), scale: item.scale, to: target)
    }
    if !cloned {
      guard let image = await composed(item),
        let png = await ScreenshotOutput.png(image, scale: item.scale),
        await Self.write(png, to: target)
      else { return nil }
    }
    // 做的这一会儿删了、又改了标注：这份是旧的，不记（文件照旧不删）；改了的照新标注重做
    guard let now = self.item(item.id) else { return nil }
    guard now.annotations == item.annotations else { return await dragFile(for: now) }
    dragFiles[item.id] = target
    return target
  }

  /// 拖的那一下要的文件（同步：晾衣绳在鼠标拖动里调）。录制的当场克隆一份——克隆是常数时间；和拖出目录（临时目录）
  /// 不在同一块卷上、或者那块卷不能克隆时（录制存在外接盘 / U 盘上：设置 › 截图「快速保存到」选了它）给原文件，
  /// 调用方看 isDisposable 不许拖进废纸篓。
  /// 截图给已经做好的那份，还没做好（刚改完标注、还在做）是 nil
  func dragFileNow(for item: Item) -> URL? {
    if let path = item.filePath {
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      let file = URL(filePath: path)
      return Self.clone(file, to: Self.freshFolder().appending(path: file.lastPathComponent))
        ?? file
    }
    guard let made = dragFiles[item.id], FileManager.default.fileExists(atPath: made.path) else {
      return nil
    }
    return made
  }

  /// 截图拖出去叫什么：存过的借它的文件名，没存过的照快速保存起
  func dragName(for item: Item) -> String {
    item.savedPath.map { ($0 as NSString).lastPathComponent }
      ?? ScreenshotOutput.availableURL(in: ShotShelf.dragDirectory, date: item.createdAt)
      .lastPathComponent
  }

  /// 历史窗口网格里拖的那一下，每条一份（多选时整批一起拖，ShotHistoryModel.beginDrag 起 AppKit 拖放会话）：
  /// 手头有文件的直接给文件——录制的当场克隆、拖过的那份、没画标注的截图当场克隆原图，都是常数时间；
  /// 有标注、还没合成过的给一个文件承诺，放下那一刻才合成（同 dragProvider：不在按下去拖的那一下卡住）。
  /// 录制的文件已经不在了给 nil
  func dragWriter(for item: Item) -> (any NSPasteboardWriting)? {
    if let url = dragFileNow(for: item) { return url as NSURL }
    guard item.filePath == nil else { return nil }
    if item.annotations.isEmpty {
      let target = Self.freshFolder().appending(path: dragName(for: item))
      if Self.cloneOriginalNow(url(for: item.id), scale: item.scale, to: target) {
        dragFiles[item.id] = target
        return target as NSURL
      }
    }
    let promise = ShotPromise(item: item, history: self)
    let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promise)
    provider.userInfo = promise  // 代理是弱引用，靠它留住
    return provider
  }

  /// 拖出目录里一个新文件夹（还没建，写的时候建）：名字照用户的 / 照快速保存，各放各的不撞名
  nonisolated private static func freshFolder() -> URL {
    ShotShelf.dragDirectory.appending(path: UUID().uuidString)
  }

  /// 是拖出目录里的那一份（克隆、现合成的），不是用户自己的文件：只有它许拖进废纸篓（R3）
  nonisolated static func isDisposable(_ url: URL) -> Bool {
    url.standardizedFileURL.path.hasPrefix(ShotShelf.dragDirectory.standardizedFileURL.path + "/")
  }

  /// 写临时文件、缩略图（几 MB 到几十 MB，不在主线程写）
  @concurrent nonisolated static func write(_ png: Data, to url: URL) async -> Bool {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? png.write(to: url, options: .atomic)) != nil
  }

  /// 用户自己的文件克隆到拖出目录（R3）。只在和拖出目录同一块、能克隆的卷上做：APFS 上 copyItem 就是克隆，常数时间、
  /// 不占地方；别的卷上它会整个拷一遍（几个 GB 的录像拖一下要等很久），这时给 nil
  nonisolated static func clone(_ file: URL, to target: URL) -> URL? {
    let root = ShotShelf.dragDirectory
    guard
      (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true))
        != nil,
      let source = try? file.resourceValues(forKeys: [
        .volumeIdentifierKey, .volumeSupportsFileCloningKey,
      ]),
      source.volumeSupportsFileCloning == true,
      let volume = source.volumeIdentifier,
      volume.isEqual((try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier),
      (try? FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
      (try? FileManager.default.copyItem(at: file, to: target)) != nil
    else { return nil }
    return target
  }

  /// 没画标注的截图：历史里那张原图就是成品，克隆过去。这一版之前记的原图按 72 DPI 存的（拷贝 / 存储的那份是
  /// 72 × 倍率），克隆过去别的 App 会按两倍大显示——DPI 对不上的返回 false，调用方照旧重编
  @concurrent nonisolated static func cloneOriginal(_ source: URL, scale: CGFloat, to target: URL)
    async -> Bool
  {
    cloneOriginalNow(source, scale: scale, to: target)
  }

  /// 同上，当场做（只读文件头再克隆，常数时间：拖的那一下用）
  nonisolated static func cloneOriginalNow(_ source: URL, scale: CGFloat, to target: URL) -> Bool {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let dpi = properties[kCGImagePropertyDPIWidth] as? Double, abs(dpi - 72 * scale) < 0.5
    else { return false }
    return clone(source, to: target) != nil
  }

  /// 拖出去给别的 App 的那一份（历史窗口用；晾衣绳走 AppKit 的拖拽会话，直接用 dragFile）。
  /// **文件是落到别人手上那一刻才做的**：历史里成百上千条，不像绳子上那 8 张能先备好
  func dragProvider(for item: Item) -> NSItemProvider {
    let provider = NSItemProvider()
    let path = item.filePath ?? item.savedPath
    provider.suggestedName = path.map { ($0 as NSString).lastPathComponent }  // 自己写上，不是每次都有
    let type =
      item.filePath.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .png
    provider.registerFileRepresentation(
      for: type, visibility: .all, openInPlace: false
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

  /// 已经做好的截图那几份（按 id，都在拖出目录里）：同一条拖第二次不重做
  @ObservationIgnored private var dragFiles: [UUID: URL] = [:]

  // MARK: 读

  /// 原图（用时才读盘，解码在主线程外；录制的那几条没有原图）
  func image(for id: UUID) async -> CGImage? { await Self.decode(url(for: id)) }

  /// 成品图（原图 + 标注）：没画标注就是原图本身，不白渲一遍（拍板 A1、C2）。
  /// 拷贝 / 存储 / 钉图、拖出去都走它。读原图在主线程外，合成在主线程（Annotation.render 是 MainActor 的）
  func composed(_ item: Item) async -> CGImage? {
    guard let original = await image(for: item.id) else { return nil }
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

  /// 缩略图（读盘解码在主线程外）
  func thumbnail(for id: UUID) async -> CGImage? { await Self.decode(thumbnailURL(for: id)) }

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

  /// 多选「在访达中显示」：存过文件的那几条一起选中（一条都没有时说一声，同单条）
  static func reveal(_ items: [Item], notice: (String, Bool) -> Void) {
    guard items.count > 1 else {
      return items.first.map { reveal($0, notice: notice) } ?? ()
    }
    let urls =
      items
      .compactMap { $0.filePath ?? $0.savedPath }
      .filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(filePath: $0) }
    guard !urls.isEmpty else { return notice("这几条都还没存成文件，先「存储到…」", false) }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
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

  /// 删掉这几条：一个事务里删记录（第三轮体检 B9：原来每条各自提交），原图、缩略图在主线程外删
  func remove(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    let doomed = Set(ids)
    items.removeAll { doomed.contains($0.id) }
    try? db.transaction {
      for id in ids { try? db.execute("DELETE FROM shots WHERE id = ?", [id.uuidString]) }
    }
    for id in ids {
      ShotThumbnails.shared.forget(id)
      dragFiles[id] = nil  // 拖出去的那份不删（见 dragFile）
    }
    let files = ids.flatMap { [url(for: $0), thumbnailURL(for: $0)] }
    Task { await Self.delete(files) }
    onRemoved(ids)
  }

  /// 删掉了几条（晾衣绳把挂着的这几条取下，R10）
  @ObservationIgnored var onRemoved: ([UUID]) -> Void = { _ in }

  @concurrent nonisolated private static func delete(_ files: [URL]) async {
    for file in files { try? FileManager.default.removeItem(at: file) }
  }

  /// 设置里的「现在清空」（第 4 批）：记录和图都删掉，录制的文件不动（它归快速保存的文件夹管）
  func clear() { remove(items.map(\.id)) }

  /// 过期的、超总量的清掉（每次记一条之后跑一遍）
  func prune() {
    remove(
      Self.stale(
        items, now: .now, days: defaults.integer(forKey: Prefs.shotHistoryDays),
        limit: defaults.integer(forKey: Prefs.shotHistoryMegabytes) * 1024 * 1024))
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
  /// 原图写 <id>.png（png 是现成的就直接用），缩略图写 <id>-t.png——**缩略图画的是成品**（shown：原图 + 标注），
  /// 历史里一眼看到的就是最后那张的样子
  private func write(
    _ image: CGImage, png: Data? = nil, thumbnailOf shown: CGImage, scale: CGFloat, id: UUID
  ) async -> Int? {
    var encoded = png
    if encoded == nil { encoded = await ScreenshotOutput.png(image, scale: scale) }
    guard let encoded else { return nil }
    let small = await Self.thumbnail(of: shown)
    return await Self.writeFiles(
      png: encoded, to: url(for: id), thumbnail: small, to: thumbnailURL(for: id))
  }

  @concurrent nonisolated private static func writeFiles(
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
  @concurrent nonisolated private static func thumbnail(of image: CGImage) async -> Data? {
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

  /// 读盘、当场解码（kCGImageSourceShouldCacheImmediately：不然解码拖到第一次画的时候、又回到主线程上，同
  /// PinPanel.decode）
  @concurrent nonisolated private static func decode(_ url: URL) async -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
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

/// 有标注、还没合成过的那条拖出去时的文件承诺（ShotHistory.dragWriter）：对方放下时给个位置，这里现合成
/// （dragFile，做好的记着），再拷到那个位置——同一块 APFS 卷上是克隆。拷贝在主线程外做
private final class ShotPromise: NSObject, NSFilePromiseProviderDelegate {
  let item: ShotHistory.Item
  weak var history: ShotHistory?

  init(item: ShotHistory.Item, history: ShotHistory) {
    self.item = item
    self.history = history
  }

  func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String)
    -> String
  {
    history?.dragName(for: item) ?? "截图.png"
  }

  nonisolated func filePromiseProvider(
    _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // 同 dragProvider：系统给的回调没标 sending，只在主 actor 上调一次
    nonisolated(unsafe) let finish = completionHandler
    Task { @MainActor in
      guard let made = await history?.dragFile(for: item) else {
        return finish(CocoaError(.fileNoSuchFile))
      }
      finish(await Self.copy(made, to: url))
    }
  }

  @concurrent nonisolated private static func copy(_ file: URL, to target: URL) async -> Error? {
    do {
      try FileManager.default.copyItem(at: file, to: target)
      return nil
    } catch {
      return error
    }
  }
}
