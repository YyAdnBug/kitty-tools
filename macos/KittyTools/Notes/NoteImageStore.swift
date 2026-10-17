// 便签的图片目录（第 7 批；令牌的格式在 NoteImages.swift，编辑器里的附件在 NoteImageAttachment.swift）：
// 数据目录下的 notes-images/（和 notes.sqlite3 放一起，**不和剪贴板共用**），文件名 `<编号>.<扩展名>`，编号是大写 UUID。
// - 存：PNG / JPEG / HEIC / GIF 原样（文件 URL 进来的连扩展名也照文件自己的）；**TIFF、WebP、BMP、RAW 等一律转 PNG**
//   （别的格式不一定画得出来、体积也大）——SPEC §5.2 写的「原字节原扩展名」只对这几种成立，2026-10-16 评审后记为偏离（F27）。
//   大小：原始输入按 `maxInputBytes`（160 MB，TIFF 是未压缩的，1200 万像素约 48 MB）的保险上限，**存下去的那份**按
//   20 MB 卡（F14）。转码和写盘都在 @concurrent 里做（不卡主线程）；存之前先写文件、调用方再改正文——崩在中间留下的
//   文件就是孤儿，30 天后清掉。
// - 宽高只读文件头（CGImageSourceCopyPropertiesAtIndex），按编号缓存在内存里（几十字节一张）；排版要用的尺寸只来自
//   这个缓存，布局回调里不读盘。缓存里没有时在**主线程、载入 / 插入那一刻**读好（读文件头很快）。
// - 缩略图：@concurrent 里用 ImageIO 解（带 EXIF 方向），显示那么大的像素。
// - **不在启动时删孤儿**（和备份恢复冲突）：一个文件没被任何便签引用（归档的、「最近删除」里的便签都算引用）满
//   30 天才删；「满 30 天」从**第一次发现它没人引用**算起（不是文件时间：很早插入的图今天刚被删掉也要再留 30 天，
//   ⌘Z、从 7 天内的备份恢复才找得回来）。账记在目录里的 .orphans.plist（名字不像图片）。
//   orphanPlan 是纯函数（单测锁住：刚孤儿 / 29 天 / 31 天 / 又被引用 / 文件不在 / 账文件坏了）。
// - 目录由外面给（App 给数据目录下的 notes-images/，单测给临时目录）；init 里不做任何删除。
// ponytail: 清点是「列一遍目录 + 每个文件名解一个 UUID」，几千张以内很快（主线程做）；几万张再挪后台。
// 扩展名按文件自己的来（原字节原扩展名），只有没扩展名 / 扩展名不像样时才按 ImageIO 认出来的类型补一个。

import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// 一张图片的尺寸信息（文件头里读出来的）
nonisolated struct NoteImageSize: Equatable, Sendable {
  var pixelWidth: Int
  var pixelHeight: Int
  /// 元数据里的 DPI（没有按 72；Retina 截图是 144）
  var dpi: CGFloat
  /// EXIF 方向（1–8；5–8 是转过 90° 的）
  var orientation: Int
  /// 转正之后的点宽高（像素 × 72 ÷ DPI）
  var pointSize: CGSize
}

@MainActor
final class NoteImageStore {
  /// 像素超过这个数的不收（同剪贴板 ImageStore.maxPixels）
  nonisolated static let maxPixels = 40_000_000
  /// **存下去的那份**超过这么大不收（20 MB）
  nonisolated static let maxFileBytes = 20 * 1024 * 1024
  /// 原始输入（转码前）的保险上限：比存下去的那份宽一截——剪贴板里的 TIFF 是未压缩的，一张 1200 万像素的照片约 48 MB，
  /// 而它的 PNG / 原图只有几 MB。只挡真正离谱的输入（F14）
  nonisolated static let maxInputBytes = 160 * 1024 * 1024
  /// 没人引用满这么多天才删（同「最近删除」的 30 天）
  nonisolated static let orphanDays = 30
  /// 清理的记账文件（名字不像图片，绝不当图片读）
  nonisolated static let ledgerName = ".orphans.plist"
  /// 图片数据里按原样存的这几种类型（别的转 PNG）
  nonisolated static let keptTypes: [String: String] = [
    "public.png": "png", "public.jpeg": "jpg", "public.heic": "heic", "public.heif": "heic",
    "com.compuserve.gif": "gif",
  ]

  let directory: URL
  /// 宽高缓存：编号 → 读过的大小（布局回调里只查它，不读盘）。**只缓存读到了的**：文件不在时每次都再看一眼
  /// （读文件头很快），这样「文件回来了（恢复备份、⌘Z 之后把文件放回去）」下次画就是图，不用重启
  private var sizes: [UUID: NoteImageSize] = [:]

  init(directory: URL) {
    self.directory = directory
  }

  /// 一个文件读不出来（或者超上限）时为什么没收
  enum Rejection: Error, Equatable, Sendable {
    case tooLarge
    case tooManyPixels
    case unreadable

    /// 刘海岛的标题和说明分开（岛上是标题一行、说明一行，同别处的写法）
    var noticeTitle: String {
      switch self {
      case .tooLarge, .tooManyPixels: "图片太大了"
      case .unreadable: "读不出这张图片"
      }
    }

    var noticeDetail: String {
      switch self {
      case .tooLarge: "单张最多 20 MB"
      case .tooManyPixels: "像素太多"
      case .unreadable: "换个文件试试"
      }
    }
  }

  /// 转好码、写下去的一张图：编号、扩展名、文件头读出来的尺寸
  struct Stored: Sendable {
    var image: NoteImages.Image
    var size: NoteImageSize
  }

  // MARK: 文件

  func url(for id: UUID, ext: String) -> URL {
    directory.appending(path: "\(id.uuidString).\(ext)")
  }

  /// 这条便签正文里的令牌指向的文件在不在、多大（读文件头，结果按编号缓存）
  func size(of id: UUID, ext: String) -> NoteImageSize? {
    if let found = sizes[id] { return found }
    guard let found = Self.readSize(at: url(for: id, ext: ext)) else { return nil }
    sizes[id] = found
    return found
  }

  /// 显示要用的点宽高（转正之后的）
  func pointSize(of id: UUID, ext: String) -> CGSize? {
    size(of: id, ext: ext)?.pointSize
  }

  /// 主线程外存好的一张图：记进宽高缓存（写盘和转码在 @concurrent 里已经做完了）
  func remember(_ stored: Stored) {
    sizes[stored.image.id] = stored.size
  }

  /// 目录里像图片的文件（文件名 `<UUID>.<扩展名>` 的；记账文件、别的东西都不算）
  func files() -> [UUID] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap(Self.identifier(ofFileNamed:))
  }

  /// 文件名 → 编号；不像 `<UUID>.<ext>` 的给 nil
  nonisolated static func identifier(ofFileNamed name: String) -> UUID? {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
    let ext = parts[1]
    guard (1...NoteImages.maxExtension).contains(ext.count),
      ext.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
    else { return nil }
    return id
  }

  // MARK: 存（转码、写盘都在主线程外）

  /// 从访达 / 别处拖进来的文件：原字节原扩展名（只读一遍、看一眼文件头），编号和写盘都在这里做。
  /// 文件属性读不到说「读不出来」（不说太大）；太大按**原始输入**的保险上限判，20 MB 按存下去的那份算（F14）
  @concurrent static func store(fileAt url: URL, in directory: URL) async -> Result<
    Stored, Rejection
  > {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return .failure(.unreadable)
    }
    if let size = attributes[.size] as? Int, size > maxInputBytes { return .failure(.tooLarge) }
    guard let bytes = try? Data(contentsOf: url) else { return .failure(.unreadable) }
    return write(bytes: bytes, preferredExtension: extensionForFile(url), in: directory)
  }

  /// 剪贴板里的图片数据：PNG / JPEG / HEIC / GIF 原样，别的转 PNG
  @concurrent static func store(data: Data, in directory: URL) async -> Result<Stored, Rejection> {
    write(bytes: data, preferredExtension: nil, in: directory)
  }

  /// 看一眼类型、像素数和 DPI，该转 PNG 的转好，再写进目录（都在这个 @concurrent 里做）。
  /// 大小：先按原始输入的保险上限（TIFF 是未压缩的，很大），转完再按**存下去的那份**卡 20 MB（F14）
  private nonisolated static func write(
    bytes: Data, preferredExtension: String?, in directory: URL
  ) -> Result<Stored, Rejection> {
    guard bytes.count <= maxInputBytes else { return .failure(.tooLarge) }
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      let size = size(of: source)
    else { return .failure(.unreadable) }
    guard size.pixelWidth * size.pixelHeight <= maxPixels else { return .failure(.tooManyPixels) }
    let type = CGImageSourceGetType(source) as String?
    let kept = type.flatMap { keptTypes[$0] }
    let ext: String
    let output: Data
    if let kept {
      ext = preferredExtension ?? kept
      output = bytes
    } else {
      // TIFF 和别的：转 PNG
      guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return .failure(.unreadable)
      }
      let encoded = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          encoded, UTType.png.identifier as CFString, 1, nil)
      else { return .failure(.unreadable) }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return .failure(.unreadable) }
      ext = "png"
      output = encoded as Data
    }
    guard output.count <= maxFileBytes else { return .failure(.tooLarge) }
    let id = UUID()
    let url = directory.appending(path: "\(id.uuidString).\(ext)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try output.write(to: url, options: .atomic)
    } catch {
      return .failure(.unreadable)
    }
    return .success(
      Stored(image: NoteImages.Image(id: id, ext: ext, width: nil), size: size))
  }

  /// 文件自己的扩展名（小写字母数字 1–10 位）；不像样时按 ImageIO 认出来的类型补一个
  private nonisolated static func extensionForFile(_ url: URL) -> String? {
    let raw = url.pathExtension.lowercased()
    if (1...NoteImages.maxExtension).contains(raw.count),
      raw.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
    {
      return raw
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let type = CGImageSourceGetType(source) as String?
    else { return nil }
    return keptTypes[type] ?? UTType(type)?.preferredFilenameExtension
  }

  // MARK: 读宽高（只读文件头，主线程上做）

  /// 文件头里读一张图的宽高 / DPI / 方向；文件不在、读不出来给 nil
  nonisolated static func readSize(at url: URL) -> NoteImageSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return size(of: source)
  }

  private nonisolated static func size(of source: CGImageSource) -> NoteImageSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      pixelWidth > 0, pixelHeight > 0
    else { return nil }
    // 有的格式把 DPI / 方向放在子字典里（JPEG 的 JFIF / EXIF 都可能有）：顶层没有再看那里
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
    var dpi: CGFloat = 72
    if let raw = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, raw > 0 {
      dpi = CGFloat(raw)
    } else if let raw = (jfif?[kCGImagePropertyJFIFXDensity] as? NSNumber)?.doubleValue, raw > 0 {
      // JFIF 的密度单位：1 = 每英寸（就是 DPI）、2 = 每厘米（× 2.54）、**0 = 只表示宽高比**（libjpeg 默认写 1，
      // 不是 DPI）——单位 0 时 ImageIO 不给 DPIWidth，照 72 算，不然 200×150 的网图会被撑满正文宽（F22）
      switch (jfif?[kCGImagePropertyJFIFDensityUnit] as? NSNumber)?.intValue ?? 0 {
      case 1: dpi = CGFloat(raw)
      case 2: dpi = CGFloat(raw * 2.54)
      default: dpi = 72
      }
    }
    let orientation =
      (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
      ?? (exif?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    // EXIF 方向 5–8：转正之后宽高互换
    let rotated = (5...8).contains(orientation)
    let width = rotated ? pixelHeight : pixelWidth
    let height = rotated ? pixelWidth : pixelHeight
    let scale = 72 / dpi
    return NoteImageSize(
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, dpi: dpi, orientation: orientation,
      pointSize: CGSize(
        width: (CGFloat(width) * scale).rounded(), height: (CGFloat(height) * scale).rounded()))
  }

  /// 缩略图：显示那么大的像素（乘屏幕倍数），带 EXIF 方向；在 @concurrent 里解
  @concurrent static func decodeThumbnail(at url: URL, maxPixel: Int) async -> CGImage? {
    guard maxPixel > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  // MARK: 清理（30 天）

  /// 清理要做的两件事：删哪些文件、新的账
  struct OrphanPlan: Equatable, Sendable {
    var remove: [UUID] = []
    var ledger: [UUID: Date] = [:]
  }

  /// 清理的规则（纯函数）：
  /// - 还被引用 → 从账上去掉；
  /// - 没被引用、账上没有 → 记上「现在」（从**第一次发现**没人引用算起，不是文件时间）；
  /// - 没被引用、账上记的早于 keep 之前 → 删；
  /// - 文件已经不在的条目去掉。
  nonisolated static func orphanPlan(
    files: Set<UUID>, referenced: Set<UUID>, ledger: [UUID: Date], now: Date,
    keep: TimeInterval = Double(orphanDays) * 86_400
  ) -> OrphanPlan {
    var plan = OrphanPlan()
    for id in files.sorted(by: { $0.uuidString < $1.uuidString }) {
      if referenced.contains(id) { continue }
      guard let since = ledger[id] else {
        plan.ledger[id] = now
        continue
      }
      if now.timeIntervalSince(since) >= keep {
        plan.remove.append(id)
      } else {
        plan.ledger[id] = since
      }
    }
    return plan
  }

  /// 现在清一遍：引用集合 = 便签仓库里所有便签（含归档、最近删除）正文里的编号。
  /// 返回删了几个文件
  @discardableResult
  func purge(referenced: Set<UUID>, now: Date = .now) -> Int {
    let files = Set(files())
    let plan = Self.orphanPlan(
      files: files, referenced: referenced, ledger: Self.ledger(in: directory), now: now)
    for id in plan.remove {
      // 文件已经不在（列表和删之间被别的东西删了）也不算错
      for ext in extensions(of: id) {
        try? FileManager.default.removeItem(at: url(for: id, ext: ext))
        sizes[id] = nil
      }
    }
    Self.writeLedger(plan.ledger, in: directory)
    if !plan.remove.isEmpty {
      Log.storage.info("便签的图片目录清掉了 \(plan.remove.count) 个没人引用满 30 天的文件")
    }
    return plan.remove.count
  }

  /// 编号对应的文件都在目录里（清理时按编号删，扩展名从文件名里取回来）
  private func extensions(of id: UUID) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name in
      guard Self.identifier(ofFileNamed: name) == id else { return nil }
      return name.split(separator: ".").last.map(String.init)
    }
  }

  /// 账文件（编号 → 第一次发现没人引用的时刻）；没有、读不出来（坏了）当空账——**不删任何东西**
  nonisolated static func ledger(in directory: URL) -> [UUID: Date] {
    let url = directory.appending(path: ledgerName)
    guard let data = try? Data(contentsOf: url),
      let raw = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Double]
    else { return [:] }
    var found: [UUID: Date] = [:]
    for (key, milliseconds) in raw {
      guard let id = UUID(uuidString: key) else { continue }
      found[id] = Note.date(milliseconds: Int64(milliseconds))
    }
    return found
  }

  /// 写账（写成毫秒，和库里别的时刻一个口径）
  nonisolated static func writeLedger(_ ledger: [UUID: Date], in directory: URL) {
    var raw: [String: Double] = [:]
    for (id, date) in ledger { raw[id.uuidString] = Double(Note.milliseconds(date)) }
    guard
      let data = try? PropertyListSerialization.data(
        fromPropertyList: raw, format: .xml, options: 0)
    else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appending(path: ledgerName), options: .atomic)
  }
}
