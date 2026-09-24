// ClipboardStore / ImageStore 单测：去重置顶、各项上限只动普通历史、清空、落库往返、图片编码。
// 用内存库 + 临时目录，不碰真实数据。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct ClipboardStoreTests {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  private func makeStore(_ db: Database? = nil) throws -> (ClipboardStore, Database) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let db = try db ?? Database(path: ":memory:")
    return (try ClipboardStore(db: db, images: ImageStore(directory: directory)), db)
  }

  private func text(_ text: String, ago seconds: TimeInterval = 0) -> ClipItem {
    var item = ClipItem(kind: .text, copiedAt: Date.now.addingTimeInterval(-seconds))
    item.text = text
    return item
  }

  @Test func duplicateMovesExistingToTop() throws {
    let (store, _) = try makeStore()
    var first = text("a")
    first.favorite = true
    first.note = "备注"
    store.record(first)
    store.record(text("b"))
    store.record(text("a"))
    #expect(store.items.map(\.text) == ["a", "b"])
    #expect(store.items[0].id == first.id)  // 保留原 id、收藏、备注
    #expect(store.items[0].favorite && store.items[0].note == "备注")
  }

  @Test func limitsOnlyTouchOrdinaryItems() throws {
    let (store, _) = try makeStore()
    var favorite = text("fav", ago: 100 * 86_400)
    favorite.favorite = true
    var snippet = text("snippet", ago: 100 * 86_400)
    snippet.isSnippet = true
    var grouped = text("grouped", ago: 100 * 86_400)
    grouped.groupID = UUID()
    for item in [
      favorite, snippet, grouped, text("old", ago: 10 * 86_400), text("x", ago: 2),
      text("y", ago: 1),
    ] {
      store.record(item)
    }
    store.enforceLimits(.init(maxCount: 1, maxAge: 7 * 86_400))
    #expect(Set(store.items.compactMap(\.text)) == ["fav", "snippet", "grouped", "y"])
  }

  @Test func imageBudgetEvictsOldestOrdinaryImages() throws {
    let (store, _) = try makeStore()
    for (index, age) in [30.0, 20, 10].enumerated() {
      var item = ClipItem(kind: .image, copiedAt: Date.now.addingTimeInterval(-age))
      item.image = .init(width: 1, height: 1, byteCount: 100, sha256: "hash\(index)")
      item.favorite = index == 0  // 最旧的那张是收藏，不能删
      store.record(item)
    }
    store.enforceLimits(.init(imageBytes: 250))
    #expect(Set(store.items.compactMap(\.image?.sha256)) == ["hash0", "hash2"])
  }

  @Test func clearOrdinaryKeepsRetained() throws {
    let (store, _) = try makeStore()
    var favorite = text("fav")
    favorite.favorite = true
    store.record(favorite)
    store.record(text("temp"))
    store.clearOrdinary()
    #expect(store.items.map(\.text) == ["fav"])
  }

  @Test func persistsAndReloads() throws {
    let (store, db) = try makeStore()
    var file = ClipItem(
      kind: .file, sourceName: "Finder", sourceBundleID: "com.apple.finder",
      copiedAt: Date.now.addingTimeInterval(-1))
    file.filePaths = ["/tmp/a b.txt", "/tmp/中文.png"]
    var rich = text("富文本")
    rich.richType = .rtf
    store.record(file)
    store.record(rich, rich: Data("{\\rtf1 x}".utf8))
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items == store.items)
    let pasteboardItem = try #require(reloaded.pasteboardItems(for: reloaded.items[0]).first)
    #expect(pasteboardItem.string(forType: .string) == "富文本")
    #expect(pasteboardItem.data(forType: .rtf) == Data("{\\rtf1 x}".utf8))
    #expect(reloaded.pasteboardItems(for: reloaded.items[1]).count == 2)
  }

  @Test func imageStoreEncodesTIFFAndHashesPNG() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let images = ImageStore(directory: directory)
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let tiff = try #require(bitmap.tiffRepresentation)
    let first = try #require(await images.save(tiff, isPNG: false, id: UUID()))
    let second = try #require(await images.save(tiff, isPNG: false, id: UUID()))
    #expect(first.width == 3 && first.height == 2)
    #expect(first.sha256 == second.sha256)  // 同一份数据编码结果稳定，去重靠它
    #expect(await images.save(Data("not an image".utf8), isPNG: true, id: UUID()) == nil)
  }
}
