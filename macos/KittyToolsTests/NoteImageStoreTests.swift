// 便签的图片目录（Notes/NoteImageStore.swift，第 7 批）单测：存文件（原字节原扩展名）、存数据（PNG / JPEG / HEIC / GIF
// 原样，TIFF 转 PNG）、拒收（超 20 MB、超 4000 万像素、读不出来）、宽高（DPI、EXIF 方向）、缩略图的长边、
// 30 天清理的纯函数（刚孤儿 / 29 天 / 31 天 / 又被引用 / 文件不在 / 账文件坏了都不删）和真删一条、记账文件往返。
// 图片都在测试里现画（CoreGraphics），不进仓库；目录全是临时的，不碰真实数据目录。

import AppKit
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

/// 测试用的图片：现画现编（PNG / JPEG / TIFF），可以指定 DPI 和 EXIF 方向
enum NoteImageFixture {
  nonisolated static func image(width: Int, height: Int, color: NSColor = .systemTeal) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: max(width / 4, 1), height: max(height / 4, 1)))
    return context.makeImage()!
  }

  nonisolated static func data(
    type: UTType, width: Int, height: Int, dpi: CGFloat? = nil, orientation: Int? = nil
  ) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      output, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if let dpi {
      properties[kCGImagePropertyDPIWidth] = dpi
      properties[kCGImagePropertyDPIHeight] = dpi
    }
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if !properties.isEmpty {
      CGImageDestinationSetProperties(destination, properties as CFDictionary)
    }
    CGImageDestinationAddImage(
      destination, image(width: width, height: height), properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
  }
}

struct NoteImageStoreTests {
  private let directory = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-image-tests-\(UUID().uuidString)")
  private let manager = FileManager.default

  private var store: NoteImageStore { NoteImageStore(directory: directory) }

  private func write(_ data: Data, name: String) throws -> URL {
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try data.write(to: url)
    return url
  }

  // MARK: 存文件

  @Test func storesAFileAsIs() async throws {
    let png = NoteImageFixture.data(type: .png, width: 200, height: 100)
    let file = try write(png, name: "一张图.png")
    let result = await NoteImageStore.store(fileAt: file, in: directory)
    let stored = try #require(try? result.get())
    #expect(stored.image.ext == "png")
    #expect(stored.size.pixelWidth == 200)
    #expect(stored.size.pointSize == CGSize(width: 200, height: 100))
    let written = directory.appending(path: "\(stored.image.id.uuidString).png")
    #expect(try Data(contentsOf: written) == png, "文件 URL 存进来的应该是原字节")
    // 主线程这层把宽高记进缓存（令牌记的是编号）
    store.remember(stored)
    #expect(store.size(of: stored.image.id, ext: "png")?.pixelHeight == 100)
  }

  @Test func keepsTheFilesOwnExtension() async throws {
    let jpeg = NoteImageFixture.data(type: .jpeg, width: 60, height: 40)
    let file = try write(jpeg, name: "照片.jpeg")
    let result = await NoteImageStore.store(fileAt: file, in: directory)
    let stored = try #require(try? result.get())
    #expect(stored.image.ext == "jpeg")
    #expect(
      try Data(contentsOf: directory.appending(path: "\(stored.image.id.uuidString).jpeg"))
        == jpeg)
  }

  @Test func transcodesTIFFDataToPNG() async throws {
    let tiff = NoteImageFixture.data(type: .tiff, width: 80, height: 60)
    let stored = try #require(try? await NoteImageStore.store(data: tiff, in: directory).get())
    #expect(stored.image.ext == "png")
    let written = try Data(
      contentsOf: directory.appending(path: "\(stored.image.id.uuidString).png"))
    let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
  }

  @Test func keepsPNGAndJPEGDataAsIs() async throws {
    for (type, ext) in [(UTType.png, "png"), (UTType.jpeg, "jpg")] {
      let data = NoteImageFixture.data(type: type, width: 30, height: 20)
      let stored = try #require(try? await NoteImageStore.store(data: data, in: directory).get())
      #expect(stored.image.ext == ext)
      #expect(
        try Data(contentsOf: directory.appending(path: "\(stored.image.id.uuidString).\(ext)"))
          == data)
    }
  }

  // MARK: 拒收

  /// F14：太大按**原始输入的保险上限**判（存下去的那份另有 20 MB 的线，见下一条）；
  /// 一个 20 MB 的字节流不是图片：说的是「读不出来」，不再一律说「太大」
  @Test func rejectsTooLargeFile() async throws {
    // 稀疏文件：逻辑大小超过输入上限，不占磁盘
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let huge = directory.appending(path: "太大.png")
    manager.createFile(atPath: huge.path, contents: nil)
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: UInt64(NoteImageStore.maxInputBytes + 1))
    try handle.close()
    let result = await NoteImageStore.store(fileAt: huge, in: directory)
    if case .failure(let reason) = result {
      #expect(reason == .tooLarge)
    } else {
      Issue.record("超过输入上限的文件该被拦下")
    }
    // 读不出属性的路径（文件不在）说「读不出来」，不说「太大」
    let missing = await NoteImageStore.store(
      fileAt: directory.appending(path: "没有这个.png"), in: directory)
    if case .failure(let reason) = missing {
      #expect(reason == .unreadable)
    } else {
      Issue.record("文件不在该是读不出来")
    }
    // 20 MB 的零字节：不是图片 → 读不出来
    let notAnImage = try write(Data(count: NoteImageStore.maxFileBytes + 1), name: "不是图.png")
    let unreadable = await NoteImageStore.store(fileAt: notAnImage, in: directory)
    if case .failure(let reason) = unreadable {
      #expect(reason == .unreadable)
    } else {
      Issue.record("一堆零字节不该被当成图片")
    }
  }

  /// F14：20 MB 按**存下去的那份**算——27 MB 的 BMP（未压缩，超过 20 MB）转成 PNG 只有几十 KB，该收
  @Test func bigInputThatShrinksOnTranscodeIsAccepted() async throws {
    let bmp = NoteImageFixture.data(type: .bmp, width: 3000, height: 3000)
    #expect(bmp.count > NoteImageStore.maxFileBytes, "输入本身超过 20 MB")
    let file = try write(bmp, name: "大图.bmp")
    let stored = try #require(try? await NoteImageStore.store(fileAt: file, in: directory).get())
    #expect(stored.image.ext == "png")
    let written = try Data(
      contentsOf: directory.appending(path: "\(stored.image.id.uuidString).png"))
    #expect(written.count <= NoteImageStore.maxFileBytes, "存下去的那份在 20 MB 以内")
    #expect(NoteImageStore.maxInputBytes > NoteImageStore.maxFileBytes)
  }

  @Test func rejectsTooManyPixels() async throws {
    // 6400 × 6400 = 4096 万像素（灰度：位图 41 MB，编出来是纯色、很快）
    let context = CGContext(
      data: nil, width: 6400, height: 6400, bitsPerComponent: 8, bytesPerRow: 6400,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 6400, height: 6400))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    let result = await NoteImageStore.store(data: output as Data, in: directory)
    if case .failure(let reason) = result {
      #expect(reason == .tooManyPixels)
    } else {
      Issue.record("6400 × 6400 应该被像素上限拦下")
    }
  }

  @Test func rejectsUnreadableData() async throws {
    let result = await NoteImageStore.store(data: Data("这不是图片".utf8), in: directory)
    if case .failure(let reason) = result {
      #expect(reason == .unreadable)
    } else {
      Issue.record("一段文字不该被当成图片")
    }
    let file = try write(Data("也不是图片".utf8), name: "假的.png")
    let fromFile = await NoteImageStore.store(fileAt: file, in: directory)
    if case .failure(let reason) = fromFile {
      #expect(reason == .unreadable)
    } else {
      Issue.record("读不出来的文件不该收")
    }
  }

  // MARK: 宽高

  @Test func sizeUsesDPIAndOrientation() async throws {
    // Retina 截图那样的：144 DPI 的 200 × 100 像素 → 100 × 50 点
    let retina = NoteImageFixture.data(type: .png, width: 200, height: 100, dpi: 144)
    let file = try write(retina, name: "retina.png")
    let size = try #require(NoteImageStore.readSize(at: file))
    #expect(size.dpi == 144)
    #expect(size.orientation == 1)
    #expect(size.pointSize == CGSize(width: 100, height: 50))
    // 没有 DPI 的按 72：像素就是点
    let plain = NoteImageFixture.data(type: .png, width: 90, height: 30)
    let plainFile = try write(plain, name: "plain.png")
    #expect(NoteImageStore.readSize(at: plainFile)?.pointSize == CGSize(width: 90, height: 30))
    // EXIF 方向 6（转了 90°）：宽高互换
    let rotated = NoteImageFixture.data(type: .jpeg, width: 200, height: 100, orientation: 6)
    let rotatedFile = try write(rotated, name: "rotated.jpg")
    let rotatedSize = try #require(NoteImageStore.readSize(at: rotatedFile))
    #expect(rotatedSize.orientation == 6)
    #expect(rotatedSize.pointSize == CGSize(width: 100, height: 200))
    // 文件不在 / 不是图片
    #expect(NoteImageStore.readSize(at: directory.appending(path: "没有这个.png")) == nil)
  }

  /// F9：拒收的文案拆成标题 + 说明（刘海岛上两行）
  @Test func rejectionNoticesAreSplit() {
    #expect(NoteImageStore.Rejection.tooLarge.noticeTitle == "图片太大了")
    #expect(NoteImageStore.Rejection.tooLarge.noticeDetail == "单张最多 20 MB")
    #expect(NoteImageStore.Rejection.tooManyPixels.noticeTitle == "图片太大了")
    #expect(NoteImageStore.Rejection.tooManyPixels.noticeDetail == "像素太多")
    #expect(NoteImageStore.Rejection.unreadable.noticeTitle == "读不出这张图片")
  }

  /// F22：JFIF 的密度单位只有 1（每英寸）才是 DPI；2（每厘米）× 2.54；**0（只表示宽高比，libjpeg 默认）
  /// 当没有 DPI**——不然 200×150 的网图会被撑满正文宽
  @Test func jfifDensityUnitDecidesWhetherItIsDPI() throws {
    /// ImageIO 写的 JPEG 连着 JFIF 的头（FF D8 FF E0 00 10 "JFIF\0" 版本 2 字节 单位 1 字节 密度 4 字节）：
    /// 直接把单位 / 密度那 5 个字节改成要测的（ImageIO 不认我们传的 JFIF 字典）
    func jpeg(unit: UInt8, density: UInt16, name: String) throws -> NoteImageSize? {
      let output = NSMutableData()
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(
        destination, NoteImageFixture.image(width: 200, height: 150), nil)
      CGImageDestinationFinalize(destination)
      var bytes = [UInt8](output as Data)
      try #require(
        bytes.count > 18 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
          && bytes[3] == 0xE0
          && String(bytes: bytes[6..<10], encoding: .ascii) == "JFIF")
      bytes[13] = unit
      bytes[14] = UInt8(density >> 8)
      bytes[15] = UInt8(density & 0xFF)
      bytes[16] = UInt8(density >> 8)
      bytes[17] = UInt8(density & 0xFF)
      let file = try write(Data(bytes), name: name)
      return NoteImageStore.readSize(at: file)
    }
    // 单位 0（libjpeg 默认）：XDensity = 1 只表示宽高比，ImageIO 也不给 DPIWidth → 按 72，像素就是点。
    // 不这么判的话 200×150 的网图会被撑满正文宽
    let zero = try #require(try jpeg(unit: 0, density: 1, name: "jfif-unit0.jpg"))
    #expect(zero.dpi == 72)
    #expect(zero.pointSize == CGSize(width: 200, height: 150))
    // 单位 1：每英寸，144 DPI → 一半的点
    let inch = try #require(try jpeg(unit: 1, density: 144, name: "jfif-unit1.jpg"))
    #expect(inch.dpi == 144)
    #expect(inch.pointSize == CGSize(width: 100, height: 75))
    // 单位 2：每厘米，× 2.54
    let cm = try #require(try jpeg(unit: 2, density: 100, name: "jfif-unit2.jpg"))
    #expect(abs(cm.dpi - 254) < 0.01)
    #expect(cm.pointSize == CGSize(width: 57, height: 43))
  }

  @Test func thumbnailKeepsTheLongEdge() async throws {
    let png = NoteImageFixture.data(type: .png, width: 800, height: 400)
    let file = try write(png, name: "wide.png")
    let image = try #require(await NoteImageStore.decodeThumbnail(at: file, maxPixel: 200))
    #expect(max(image.width, image.height) == 200)
    #expect(image.width == 200)
    #expect(image.height == 100)
    #expect(await NoteImageStore.decodeThumbnail(at: file, maxPixel: 0) == nil)
    #expect(
      await NoteImageStore.decodeThumbnail(
        at: directory.appending(path: "没有这个.png"), maxPixel: 100) == nil)
  }

  // MARK: 文件名

  @Test func fileNamesAreIdentifiers() {
    let id = UUID()
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).png") == id)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).heic") == id)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString)") == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).p n g") == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).PNG") == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).abcdefghijk") == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: NoteImageStore.ledgerName) == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: "notes.sqlite3") == nil)
    #expect(NoteImageStore.identifier(ofFileNamed: "\(id.uuidString).png.bak") == nil)
  }

  // MARK: 30 天清理

  @Test func orphanPlanPure() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let d = UUID()
    let gone = UUID()
    let files: Set<UUID> = [a, b, c, d]
    let ledger: [UUID: Date] = [
      // a：刚发现没人引用（没记账）→ 记上「现在」
      b: now.addingTimeInterval(-29 * day),  // 29 天 → 留着
      c: now.addingTimeInterval(-31 * day),  // 31 天 → 删
      gone: now.addingTimeInterval(-100 * day),  // 文件早不在了 → 账上去掉、不删东西
    ]
    let plan = NoteImageStore.orphanPlan(
      files: files, referenced: [d], ledger: ledger, now: now)
    #expect(plan.remove == [c])
    #expect(plan.ledger[a] == now, "刚发现没人引用：从这一刻算起")
    #expect(plan.ledger[b] == ledger[b], "29 天：留着，时刻不变")
    #expect(plan.ledger[c] == nil)
    #expect(plan.ledger[gone] == nil, "文件不在的条目去掉")
    #expect(plan.ledger[d] == nil, "还被引用：账上去掉")
    #expect(plan.ledger.count == 2)
    // 又被引用：记账清掉（下次再没人引用重新算 30 天）
    let again = NoteImageStore.orphanPlan(
      files: [c], referenced: [c], ledger: [c: now.addingTimeInterval(-31 * day)], now: now)
    #expect(again.remove.isEmpty)
    #expect(again.ledger.isEmpty)
    // 正好满 30 天：删
    let exact = NoteImageStore.orphanPlan(
      files: [a], referenced: [], ledger: [a: now.addingTimeInterval(-30 * day)], now: now)
    #expect(exact.remove == [a])
  }

  @Test func purgeDeletesOnlyExpiredOrphans() throws {
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let referenced = UUID()
    let fresh = UUID()
    let stale = UUID()
    for (id, ext) in [(referenced, "png"), (fresh, "png"), (stale, "jpg")] {
      try Data(count: 8).write(to: store.url(for: id, ext: ext))
    }
    // 记账：referenced 也在账上（该去掉）、fresh 记账不到 30 天、stale 31 天
    NoteImageStore.writeLedger(
      [
        referenced: now.addingTimeInterval(-100 * day),
        fresh: now.addingTimeInterval(-2 * day),
        stale: now.addingTimeInterval(-31 * day),
      ], in: directory)
    let removed = store.purge(referenced: [referenced], now: now)
    #expect(removed == 1)
    #expect(manager.fileExists(atPath: store.url(for: referenced, ext: "png").path))
    #expect(manager.fileExists(atPath: store.url(for: fresh, ext: "png").path))
    #expect(!manager.fileExists(atPath: store.url(for: stale, ext: "jpg").path))
    // 新账：referenced 去掉、fresh 留着、stale 去掉
    let ledger = NoteImageStore.ledger(in: directory)
    #expect(ledger[referenced] == nil)
    #expect(ledger[stale] == nil)
    #expect(ledger[fresh] != nil)
    // 记账文件不像图片，不算图片文件
    #expect(
      store.files().sorted(by: { $0.uuidString < $1.uuidString })
        == [referenced, fresh].sorted(by: { $0.uuidString < $1.uuidString }))
    // 再清一遍：账上 fresh 才 2 天，什么都不删
    #expect(store.purge(referenced: [referenced], now: now) == 0)
  }

  @Test func ledgerSurvivesRoundTripAndCorruptIsEmpty() throws {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_799_000_000)
    NoteImageStore.writeLedger([id: date], in: directory)
    #expect(NoteImageStore.ledger(in: directory) == [id: date])
    // 坏了（不是 plist）当空账：不删任何东西
    try Data("坏掉的账".utf8).write(to: directory.appending(path: NoteImageStore.ledgerName))
    #expect(NoteImageStore.ledger(in: directory).isEmpty)
    let plan = NoteImageStore.orphanPlan(
      files: [id], referenced: [], ledger: NoteImageStore.ledger(in: directory),
      now: date.addingTimeInterval(100 * 86_400))
    #expect(plan.remove.isEmpty, "账文件坏了：当空账，不删")
    #expect(plan.ledger[id] != nil, "重新记上「现在」")
  }
}

/// 缩略图缓存（NoteImageThumbnails，F7）：命中 / 已在解 / 失败三态、失败不重解也不重画、超上限的一张留得住、
/// LRU、maxPixel 按长边、换宽度时先拿旧的那张缩放着画。
/// **串行跑**：缓存和注入的解码器都是进程里一份（`NoteImageThumbnails`），并行跑会互相踩
/// （全量第一遍里 `failedDecodesAreNotRetriedAndDoNotInvalidate` 就这么假红过一次）
@Suite(.serialized)
struct NoteImageThumbnailTests {
  private let directory = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-thumbs-\(UUID().uuidString)")

  /// maxPixel 按**长边**算（`kCGImageSourceThumbnailMaxPixelSize` 限的是长边）：竖图不会只解出一半多的分辨率；
  /// 按 256 一档往上取整（拖把手、拉窗口时宽度每变 1 pt 不该换一个键）
  @Test func thumbnailPixelUsesTheLongEdge() {
    #expect(NoteImageThumbnails.pixel(for: CGSize(width: 100, height: 300), scale: 1) == 512)
    #expect(NoteImageThumbnails.pixel(for: CGSize(width: 300, height: 100), scale: 1) == 512)
    #expect(NoteImageThumbnails.pixel(for: CGSize(width: 100, height: 100), scale: 2) == 256)
    #expect(NoteImageThumbnails.pixel(for: CGSize(width: 600, height: 10), scale: 1) == 768)
    #expect(NoteImageThumbnails.pixel(for: .zero, scale: 2) == 256)
  }

  /// 解不出来的（文件坏了 / 被删了）：不调 ready（不失效重画，不然「重画 → 再解 → 再失败」一直占 CPU）、
  /// 第二次取不再起解码（负缓存）
  @Test func failedDecodesAreNotRetriedAndDoNotInvalidate() async throws {
    NoteImageThumbnails.discard()
    let decodes = Mutex(0)
    let readies = Mutex(0)
    NoteImageThumbnails.setDecoder { _, _ in
      decodes.withLock { $0 += 1 }
      return nil
    }
    defer {
      NoteImageThumbnails.resetDecoder()
      NoteImageThumbnails.discard()
    }
    let id = UUID()
    let url = directory.appending(path: "\(id.uuidString).png")
    _ = NoteImageThumbnails.image(for: url, id: id, maxPixel: 256) {
      readies.withLock { $0 += 1 }
    }
    for _ in 0..<200 where decodes.withLock({ $0 }) < 1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(decodes.withLock { $0 } == 1)
    #expect(readies.withLock { $0 } == 0, "解不出来不调 ready")
    _ = NoteImageThumbnails.image(for: url, id: id, maxPixel: 256) {
      readies.withLock { $0 += 1 }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(decodes.withLock { $0 } == 1, "第二次取不再起解码")
    #expect(readies.withLock { $0 } == 0)
  }

  /// 空闲回收清缓存时留下浮在屏幕上的那张便签里的图（各档都留，像素数跟着减）；不给就全清（调优 T2）
  @Test func discardKeepsTheFloatingNotesImages() {
    NoteImageThumbnails.discard()
    defer { NoteImageThumbnails.discard() }
    let (kept, dropped) = (UUID(), UUID())
    for id in [kept, dropped] {
      for pixel in [256, 512] {
        NoteImageThumbnails.store(
          NoteImageFixture.image(width: 10, height: 10),
          key: NoteImageThumbnails.key(id, pixel: pixel))
      }
    }
    #expect(NoteImageThumbnails.count == 4 && NoteImageThumbnails.cost == 400)
    NoteImageThumbnails.discard(keeping: [kept])
    #expect(NoteImageThumbnails.count == 2 && NoteImageThumbnails.cost == 200)
    #expect(NoteImageThumbnails.peek(key: NoteImageThumbnails.key(kept, pixel: 256)) != nil)
    #expect(NoteImageThumbnails.peek(key: NoteImageThumbnails.key(kept, pixel: 512)) != nil)
    #expect(NoteImageThumbnails.peek(key: NoteImageThumbnails.key(dropped, pixel: 256)) == nil)
    NoteImageThumbnails.discard()
    #expect(NoteImageThumbnails.count == 0 && NoteImageThumbnails.cost == 0)
  }

  /// 单张比上限还大的缩略图放进去**不淘汰自己**（不然画一次解一次）
  @Test func anOversizedThumbnailStaysInTheCache() {
    NoteImageThumbnails.discard()
    NoteImageThumbnails.setMaxCost(100)
    defer {
      NoteImageThumbnails.setMaxCost(nil)
      NoteImageThumbnails.discard()
    }
    let id = UUID()
    NoteImageThumbnails.store(
      NoteImageFixture.image(width: 20, height: 20),
      key: NoteImageThumbnails.key(id, pixel: 256))
    #expect(NoteImageThumbnails.count == 1)
    #expect(NoteImageThumbnails.cost == 400)
  }

  /// LRU：超过上限丢最久没用的，**读到就挪到队尾**
  @Test func cacheEvictsTheLeastRecentlyUsed() {
    NoteImageThumbnails.discard()
    NoteImageThumbnails.setMaxCost(1000)
    defer {
      NoteImageThumbnails.setMaxCost(nil)
      NoteImageThumbnails.discard()
    }
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let d = UUID()
    func put(_ id: UUID) {
      NoteImageThumbnails.store(
        NoteImageFixture.image(width: 20, height: 20),
        key: NoteImageThumbnails.key(id, pixel: 256))
    }
    func has(_ id: UUID) -> Bool {
      NoteImageThumbnails.peek(key: NoteImageThumbnails.key(id, pixel: 256)) != nil
    }
    put(a)
    put(b)
    put(c)
    #expect(!has(a), "三张 400 放不下：丢最久没用的 A")
    #expect(has(b) && has(c))
    _ = NoteImageThumbnails.peek(key: NoteImageThumbnails.key(b, pixel: 256))
    put(d)
    #expect(!has(c), "B 刚读过、挪到了队尾：这次丢 C")
    #expect(has(b) && has(d))
    #expect(NoteImageThumbnails.count == 2)
  }

  /// 换宽度（拖把手、拉窗口）：同一个编号已经有别的档的缩略图时先拿它缩放着画，同时后台解新的那一档
  @Test func widthChangeReusesAnExistingThumbnail() async throws {
    NoteImageThumbnails.discard()
    let decodes = Mutex(0)
    NoteImageThumbnails.setDecoder { _, _ in
      decodes.withLock { $0 += 1 }
      return NoteImageFixture.image(width: 10, height: 10)
    }
    defer {
      NoteImageThumbnails.resetDecoder()
      NoteImageThumbnails.discard()
    }
    let id = UUID()
    let url = directory.appending(path: "\(id.uuidString).png")
    NoteImageThumbnails.store(
      NoteImageFixture.image(width: 8, height: 8), key: NoteImageThumbnails.key(id, pixel: 256))
    let reused = NoteImageThumbnails.image(for: url, id: id, maxPixel: 1024, ready: {})
    #expect(reused != nil, "换宽度时先拿旧的那张缩放着画，不闪纸色")
    #expect(reused?.width == 8)
    for _ in 0..<200 where decodes.withLock({ $0 }) < 1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(decodes.withLock { $0 } == 1, "同时也在解新的那一档")
    let key = NoteImageThumbnails.key(id, pixel: 1024)
    for _ in 0..<200 where NoteImageThumbnails.peek(key: key) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(NoteImageThumbnails.peek(key: key)?.width == 10)
  }
}
