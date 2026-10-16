// 便签的图片目录（Notes/NoteImageStore.swift，第 7 批）单测：存文件（原字节原扩展名）、存数据（PNG / JPEG / HEIC / GIF
// 原样，TIFF 转 PNG）、拒收（超 20 MB、超 4000 万像素、读不出来）、宽高（DPI、EXIF 方向）、缩略图的长边、
// 30 天清理的纯函数（刚孤儿 / 29 天 / 31 天 / 又被引用 / 文件不在 / 账文件坏了都不删）和真删一条、记账文件往返。
// 图片都在测试里现画（CoreGraphics），不进仓库；目录全是临时的，不碰真实数据目录。

import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

/// 测试用的图片：现画现编（PNG / JPEG / TIFF），可以指定 DPI 和 EXIF 方向
enum NoteImageFixture {
  static func image(width: Int, height: Int, color: NSColor = .systemTeal) -> CGImage {
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

  static func data(
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

  @Test func rejectsTooLargeFile() async throws {
    let big = Data(count: NoteImageStore.maxFileBytes + 1)
    let file = try write(big, name: "太大.png")
    let result = await NoteImageStore.store(fileAt: file, in: directory)
    #expect((try? result.get()) == nil)
    if case .failure(let reason) = result { #expect(reason == .tooLarge) }
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
