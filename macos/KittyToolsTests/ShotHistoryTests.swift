// 截图历史（第 1 批）的单测：标注的编解码（十种工具一条不漏地回来）、记一条 / 读回来 / 改标注 / 删、
// 过期和超总量的清理、开关关掉时不记。都在临时目录里跑，不碰用户的数据目录。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct ShotHistoryTests {
  /// 临时目录里的一套库（用完删掉）
  private func makeHistory() throws -> (history: ShotHistory, directory: URL) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try Database(path: root.appending(path: "test.sqlite").path)
    let history = try ShotHistory(db: db, directory: root.appending(path: "shots"))
    let defaults = try #require(UserDefaults(suiteName: "shot-history-tests-\(UUID().uuidString)"))
    defaults.set(true, forKey: Prefs.shotHistory)
    history.defaults = defaults
    return (history, root)
  }

  private func image(width: Int = 400, height: Int = 300) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(gray: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  /// 十种工具存成 JSON 再读回来，一模一样（拍板 A1 的根基；这些 case 名进了磁盘）
  @Test func annotationsSurviveJSON() throws {
    let all: [Annotation] = [
      Annotation(
        shape: .rectangle(CGRect(x: 1, y: 2, width: 30, height: 40)),
        style: Annotation.Style(color: .red, weight: .small, option: 1)),
      Annotation(shape: .ellipse(CGRect(x: 5, y: 6, width: 70, height: 80))),
      Annotation(
        shape: .arrow(
          from: CGPoint(x: 1, y: 2), to: CGPoint(x: 9, y: 9), bend: CGVector(dx: 0.1, dy: -0.2))),
      Annotation(shape: .line(from: CGPoint(x: 3, y: 4), to: CGPoint(x: 5, y: 6))),
      Annotation(shape: .pen([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 1)])),
      Annotation(shape: .highlighter(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0))),
      Annotation(
        shape: .text("注意这里 · emoji 🐱", origin: CGPoint(x: 7, y: 8)),
        style: Annotation.Style(color: .blue, weight: .large, option: 2)),
      Annotation(shape: .counter(3, center: CGPoint(x: 12, y: 13))),
      Annotation(shape: .mosaic(CGRect(x: 2, y: 2, width: 20, height: 20))),
      Annotation(shape: .spotlight(CGRect(x: 4, y: 4, width: 44, height: 44))),
    ]
    #expect(all.count == Annotation.Tool.allCases.count)
    let json = try #require(ShotHistory.encode(all))
    #expect(ShotHistory.decode(json) == all)
    // 空的不占地方；读不懂的不崩
    #expect(ShotHistory.encode([]) == nil)
    #expect(ShotHistory.decode("{坏掉的") == nil)
  }

  /// 记一条：图和缩略图写在自己的目录里，读回来是同一条；改标注、记存到哪、钉过都落库
  @Test func recordsAndUpdates() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(
      await history.record(image(), scale: 2, source: "Safari"))
    #expect(history.items.count == 1)
    let item = try #require(history.items.first)
    #expect(item.kind == .shot && item.source == "Safari" && item.scale == 2)
    #expect(item.pixelSize == CGSize(width: 400, height: 300))
    #expect(item.bytes > 0 && item.annotations.isEmpty && item.pinnedAt == nil)
    #expect(FileManager.default.fileExists(atPath: history.url(for: id).path))
    #expect(FileManager.default.fileExists(atPath: history.thumbnailURL(for: id).path))
    #expect(history.image(for: id)?.width == 400)
    let drawn = [Annotation(shape: .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4)))]
    history.update(id, annotations: drawn)
    #expect(history.items.first?.annotations == drawn)
    history.markSaved(id, to: URL(filePath: "/tmp/a.png"))
    history.markPinned(id)
    #expect(history.items.first?.savedPath == "/tmp/a.png")
    #expect(history.items.first?.pinnedAt != nil)
  }

  /// 删一条连图一起删；清空之后目录里什么都不剩
  @Test func removesFiles() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(), scale: 2))
    history.remove([id])
    #expect(history.items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: history.url(for: id).path))
    #expect(!FileManager.default.fileExists(atPath: history.thumbnailURL(for: id).path))
    _ = await history.record(image(), scale: 2)
    _ = await history.record(image(), scale: 2)
    history.clear()
    #expect(history.items.isEmpty)
  }

  /// 录屏 / 录音：只记文件路径和封面（拍板 B1）
  @Test func recordsFiles() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = URL(filePath: "/tmp/kitty-test.mp4")
    let id = try #require(
      await history.record(file: file, poster: image(), kind: .video))
    let item = try #require(history.items.first)
    #expect(item.kind == .video && item.filePath == file.path && item.id == id)
    #expect(history.thumbnail(for: id) != nil)
  }

  /// 「保留截图历史」关掉之后不再记，已经记下的留着（拍板 B3）
  @Test func offKeepsWhatIsThere() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = await history.record(image(), scale: 2)
    history.defaults.set(false, forKey: Prefs.shotHistory)
    #expect(!history.isOn)
    #expect(await history.record(image(), scale: 2) == nil)
    #expect(history.items.count == 1)
  }

  /// 清理：过期的删掉，从新到旧累计超过上限的删掉；两个上限给 0 就都不清（拍板 A3）
  @Test func staleByAgeAndSize() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func item(_ daysAgo: Double, _ bytes: Int) -> ShotHistory.Item {
      ShotHistory.Item(
        id: UUID(), kind: .shot, createdAt: now.addingTimeInterval(-daysAgo * 86400),
        pixelSize: CGSize(width: 10, height: 10), scale: 2, bytes: bytes)
    }
    let fresh = item(1, 100)
    let old = item(40, 100)
    let middle = item(10, 100)
    let byAge = ShotHistory.stale([fresh, old, middle], now: now, days: 30, limit: 0)
    #expect(byAge == [old.id])
    // 上限 250：从新到旧第三条就超了
    let bySize = ShotHistory.stale([fresh, middle, item(20, 100)], now: now, days: 0, limit: 250)
    #expect(bySize.count == 1)
    // 上限比一张图还小：最新那条照样留着（刚截完的不能当场没了）
    let tiny = ShotHistory.stale([fresh, middle], now: now, days: 0, limit: 1)
    #expect(tiny == [middle.id])
    #expect(ShotHistory.stale([fresh, old, middle], now: now, days: 0, limit: 0).isEmpty)
  }

  /// 记一条之后自己清一遍：上限设得很小时旧的当场被删掉（连图一起）
  @Test func prunesAfterRecording() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try #require(await history.record(image(), scale: 2))
    history.defaults.set(1, forKey: Prefs.shotHistoryBytes)  // 1 字节：只留最新那条
    _ = await history.record(image(), scale: 2)
    #expect(history.items.count == 1)
    #expect(!FileManager.default.fileExists(atPath: history.url(for: first).path))
  }
}
