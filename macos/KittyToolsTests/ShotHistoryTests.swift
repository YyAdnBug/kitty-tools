// 截图历史（第 1 批）的单测：标注的编解码（十种工具一条不漏地回来）、记一条 / 读回来 / 改标注 / 删、
// 过期和超总量的清理、开关关掉时不记。都在临时目录里跑，不碰用户的数据目录。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import UniformTypeIdentifiers

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

  /// 等到 done 成立（主线程外删文件、写缩略图都是异步的；最多等一秒）
  private func waitUntil(_ done: () -> Bool) async throws {
    for _ in 0..<40 where !done() {
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  /// 改标注：成品照标注窗口那样合成好了再给（update 不再自己读原图重合成）
  private func update(
    _ history: ShotHistory, _ id: UUID, _ annotations: [Annotation]
  ) async throws {
    let original = try #require(await history.image(for: id))
    let item = try #require(history.item(id))
    history.update(
      id, annotations: annotations,
      composed: ShotHistory.compose(original, annotations: annotations, scale: item.scale))
  }

  private func image(
    width: Int = 400, height: Int = 300, tint: CGColor = CGColor(gray: 0.6, alpha: 1)
  ) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(tint)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  /// 整张图平均下来有多红（0…1：红减去绿蓝的平均）
  private static func redness(of image: CGImage) -> Double {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Double(pixel[0]) - (Double(pixel[1]) + Double(pixel[2])) / 2) / 255
  }

  /// 拖出去的那份读回来
  private func dragged(_ history: ShotHistory, _ id: UUID) async throws -> (URL, CGImage) {
    let item = try #require(history.item(id))
    let url = try #require(await history.dragFile(for: item))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return (url, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
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
    #expect(await history.image(for: id)?.width == 400)
    #expect(history.item(id)?.source == "Safari")
    let drawn = [Annotation(shape: .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4)))]
    try await update(history, id, drawn)
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
    var removed: [UUID] = []
    history.onRemoved = { removed += $0 }
    history.remove([id])
    #expect(history.items.isEmpty && history.item(id) == nil)
    #expect(removed == [id])
    // 文件在主线程外删
    func gone(_ id: UUID) -> Bool {
      !FileManager.default.fileExists(atPath: history.url(for: id).path)
        && !FileManager.default.fileExists(atPath: history.thumbnailURL(for: id).path)
    }
    try await waitUntil { gone(id) }
    #expect(gone(id))
    let a = try #require(await history.record(image(), scale: 2))
    let b = try #require(await history.record(image(), scale: 2))
    history.clear()
    #expect(history.items.isEmpty)
    try await waitUntil { gone(a) && gone(b) }
    #expect(gone(a) && gone(b))
  }

  /// 删了的重开库也不回来（一次删几条）
  @Test func removalSurvivesReopen() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    var ids: [UUID] = []
    for _ in 0..<3 { ids.append(try #require(await history.record(image(), scale: 2))) }
    history.remove([ids[0], ids[2]])
    let reopened = try ShotHistory(
      db: Database(path: root.appending(path: "test.sqlite").path),
      directory: root.appending(path: "shots"))
    #expect(reopened.items.map(\.id) == [ids[1]])
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
    #expect(await history.thumbnail(for: id) != nil)
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

  // MARK: 历史窗口（第 2 批）

  private func item(
    _ kind: ShotHistory.Kind, _ daysAgo: Double, source: String? = nil, now: Date = .now
  ) -> ShotHistory.Item {
    ShotHistory.Item(
      id: UUID(), kind: kind, createdAt: now.addingTimeInterval(-daysAgo * 86400),
      pixelSize: CGSize(width: 1200, height: 800), scale: 2, source: source)
  }

  /// 筛选和搜索：按种类分「全部 / 截图 / 长截图 / 录制」，搜的是来源和种类
  @Test func filtersAndSearches() {
    let items = [
      item(.shot, 0, source: "Safari"), item(.scroll, 0, source: "Chrome"),
      item(.video, 0, source: "Xcode"), item(.audio, 0), item(.gif, 0),
    ]
    func shown(_ filter: ShotHistoryModel.Filter, _ search: String = "") -> Int {
      ShotHistoryModel.filtered(items, search: search, filter: filter).count
    }
    #expect(shown(.all) == 5)
    #expect(shown(.shot) == 1)
    #expect(shown(.scroll) == 1)
    #expect(shown(.recording) == 3)  // 录屏 + 录音 + GIF
    #expect(shown(.all, "safari") == 1)  // 不分大小写
    #expect(shown(.all, "长截图") == 1)  // 种类名也搜得到
    #expect(shown(.recording, "safari") == 0)  // 筛选和搜索一起生效
    #expect(shown(.all, "  ") == 5)  // 只有空格不算搜
  }

  /// 按天分组：今天、昨天写成字，更早的写日期；每组内部新的在前
  @Test func groupsByDay() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let today = [item(.shot, 0, now: now), item(.shot, 0.2, now: now)]
    let groups = ShotHistoryModel.group(today + [item(.shot, 1, now: now)], now: now)
    #expect(groups.count == 2)
    #expect(groups.first?.title == "今天" && groups.first?.items.count == 2)
    #expect(groups.first?.items.first?.id == today[0].id)  // 新的在前
    #expect(groups.last?.title == "昨天")
    #expect(ShotHistoryModel.group([], now: now).isEmpty)
    // 更早的写日期、不带时间（原来会跟出个 0:00）；写法跟系统语言走，这里只锁「没有时间」
    let older = ShotHistoryModel.group([item(.shot, 9, now: now)], now: now)
    let title = try #require(older.first?.title)
    #expect(!title.isEmpty && !title.contains(":") && title != "今天" && title != "昨天")
  }

  /// 分组记了一份（P2）：历史变了、搜索词 / 筛选换了都跟着重算，没变时给的是同一份
  @Test func groupsFollowChanges() throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let items = [item(.shot, 0, source: "Safari"), item(.video, 1, source: "Xcode")]
    history.seed(items)
    let model = ShotHistoryModel(history: history)
    #expect(model.groups.flatMap(\.items).map(\.id) == items.map(\.id))
    model.search = "xcode"
    #expect(model.shown.map(\.id) == [items[1].id])
    model.search = ""
    model.filter = .shot
    #expect(model.shown.map(\.id) == [items[0].id])
    model.filter = .all
    var saved = items[0]
    saved.savedPath = "/tmp/存过.png"
    history.seed([saved, items[1]])
    #expect(model.groups.first?.items.first?.savedPath == "/tmp/存过.png")
    history.remove([items[1].id])
    #expect(model.shown.map(\.id) == [items[0].id])
  }

  /// 说明那两行：时间 · 尺寸 · 来源；第二行写存到哪、几条标注、钉过没有
  @Test func captions() {
    var shot = item(.shot, 0, source: "Safari")
    #expect(ShotHistoryModel.caption(shot).contains("1200 × 800"))
    #expect(ShotHistoryModel.caption(shot).hasSuffix("Safari"))
    #expect(ShotHistoryModel.details(shot).isEmpty)
    shot.savedPath = "/tmp/a.png"
    shot.annotations = [Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 2, height: 2)))]
    shot.pinnedAt = .now
    let details = ShotHistoryModel.details(shot)
    #expect(details.contains("1 条标注") && details.contains("钉过") && details.contains("已存到"))
  }

  /// 成品图：没标注就是原图本身，有标注才合成一张新的（拍板 A1、C2）
  @Test func composesOnlyWithAnnotations() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(), scale: 2))
    let plain = try #require(history.items.first)
    let original = try #require(await history.composed(plain))
    #expect(original.width == 400)
    try await update(
      history, id, [Annotation(shape: .rectangle(CGRect(x: 1, y: 1, width: 9, height: 9)))])
    let drawn = try #require(history.items.first)
    let composed = try #require(await history.composed(drawn))
    #expect(composed.width == 400 && composed.height == 300)
  }

  /// 拷贝 / 存储编好的那份 PNG 直接当原图（R6：不再编第二遍），成品图给了就照它缩缩略图（不再合成）
  @Test func recordsWithTheSharedPNG() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = image()
    let png = try #require(await ScreenshotOutput.png(original, scale: 2))
    // 成品给一张不一样的（全红）：缩略图该照它，不是照原图
    let red = image(tint: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let id = try #require(
      await history.record(original, png: png, composed: red, scale: 2))
    #expect(try Data(contentsOf: history.url(for: id)) == png)
    let thumbnail = try #require(await history.thumbnail(for: id))
    #expect(Self.redness(of: thumbnail) > 0.9, "缩略图没照给的成品图缩")
  }

  /// 标注没变就不重做缩略图（R6：原来每次出图都在主线程上读原图重合成）
  @Test func updateWithSameAnnotationsDoesNothing() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drawn = [Annotation(shape: .rectangle(CGRect(x: 1, y: 1, width: 9, height: 9)))]
    let id = try #require(await history.record(image(), scale: 2, annotations: drawn))
    var redrawn = 0
    history.onThumbnailChanged = { _ in redrawn += 1 }
    history.update(id, annotations: drawn, composed: image())
    try await Task.sleep(for: .milliseconds(200))
    #expect(redrawn == 0)
  }

  /// 缩略图还在重做时整条删了：不留孤儿缩略图（B9）
  @Test func updateThenRemoveLeavesNoThumbnail() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(), scale: 2))
    let big = image(width: 3000, height: 3000)
    history.update(
      id, annotations: [Annotation(shape: .rectangle(CGRect(x: 1, y: 1, width: 9, height: 9)))],
      composed: big)
    history.remove([id])
    try await Task.sleep(for: .milliseconds(400))
    #expect(!FileManager.default.fileExists(atPath: history.thumbnailURL(for: id).path))
  }

  /// 改完标注之后缩略图跟着重做（2026-10-26 手测：历史里看着像没改过）
  @Test func updateRedrawsThumbnail() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(), scale: 2))
    let before = try Data(contentsOf: history.thumbnailURL(for: id))
    var redrawn: UUID?
    history.onThumbnailChanged = { redrawn = $0 }
    try await update(
      history, id,
      [
        Annotation(
          shape: .rectangle(CGRect(x: 10, y: 10, width: 120, height: 80)),
          style: Annotation.Style(color: .red, weight: .large))
      ])
    // 重做是异步的：等它写完
    for _ in 0..<40 where redrawn == nil {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(redrawn == id)
    let after = try Data(contentsOf: history.thumbnailURL(for: id))
    #expect(after != before, "缩略图没跟着标注变")
  }

  /// 记一条时缩略图画的就是成品：框选里画过标注的，历史里一眼就看得见
  @Test func thumbnailShowsAnnotations() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = try #require(await history.record(image(), scale: 2))
    let drawn = try #require(
      await history.record(
        image(), scale: 2,
        annotations: [
          Annotation(
            shape: .rectangle(CGRect(x: 10, y: 10, width: 120, height: 80)),
            style: Annotation.Style(color: .red, weight: .large))
        ]))
    let a = try Data(contentsOf: history.thumbnailURL(for: plain))
    let b = try Data(contentsOf: history.thumbnailURL(for: drawn))
    #expect(a != b)
    // 原图那份不带标注（回头还能接着改）
    #expect(
      try Data(contentsOf: history.url(for: plain)) == Data(contentsOf: history.url(for: drawn)))
  }

  /// 改完标注，**左边那片网格**里那张卡也跟着变（2026-10-26 用户手测：右边的预览变了、左边的列表没变）。
  /// 上面两个测只管到磁盘和缓存——缓存失效了和 SwiftUI 重不重画是两回事，所以这里把整扇窗摆到屏幕外
  /// 渲染出来、只比左边网格那一块的像素
  @Test func gridRedrawsAfterUpdate() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(width: 800, height: 600), scale: 2))
    ShotThumbnails.shared.clear()
    let model = ShotHistoryModel(history: history)
    var redrawn: UUID?
    history.onThumbnailChanged = { changed in  // 同 AppDelegate 的接法
      ShotThumbnails.shared.forget(changed)
      model.touch()
      redrawn = changed
    }
    let window = stage(ShotHistoryView(model: model))
    defer { window.orderOut(nil) }
    let settle = { for _ in 0..<4 { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) } }
    settle()
    let content = try #require(window.contentView)
    // 左边网格那一块（卡片在左上角那一片；右边的预览不算）
    let grid = CGRect(x: 0, y: content.bounds.height - 320, width: 400, height: 300)
    func shot() throws -> Data {
      content.layoutSubtreeIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: grid))
      content.cacheDisplay(in: grid, to: bitmap)
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let before = try shot()
    #expect(before.count > 2000, "网格那一块没画出东西，这个测就白跑了")
    try await update(
      history, id,
      [
        Annotation(
          shape: .rectangle(CGRect(x: 20, y: 20, width: 360, height: 260)),
          style: Annotation.Style(color: .red, weight: .large))
      ])
    for _ in 0..<40 where redrawn == nil {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(redrawn == id)
    settle()
    #expect(try shot() != before, "改完标注，左边那张卡没跟着变")
  }

  /// 拖到别的 App 里去：没存过盘的拖一份**现合成**的成品 PNG（带标注，落到别人手上那一刻才写盘），
  /// 存过盘的就拖存的那个文件（名字是用户自己的）
  @Test func dragProvidesFile() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(
      await history.record(
        image(), scale: 2,
        annotations: [
          Annotation(
            shape: .rectangle(CGRect(x: 10, y: 10, width: 120, height: 80)),
            style: Annotation.Style(color: .red, weight: .large))
        ]))
    let item = try #require(history.items.first { $0.id == id })
    let png = UTType.png.identifier
    let provider = history.dragProvider(for: item)
    #expect(provider.registeredTypeIdentifiers.contains(png))
    // 真的去拿一次（这一下才会合成 + 写盘）
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: png) { url, error in
        if let url {
          continuation.resume(returning: (try? Data(contentsOf: url)) ?? Data())
        } else {
          continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
        }
      }
    }
    #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "拿到的不是 PNG")
    #expect(try data != Data(contentsOf: history.url(for: id)), "拖出去的那份要带标注，不是原图")

    // 存过盘之后：名字借存的那个文件的（内容照旧是历史里的成品，见 dragFollowsAnnotations）
    let saved = root.appending(path: "我自己命的名.png")
    try data.write(to: saved)
    history.markSaved(id, to: saved)
    let after = try #require(history.items.first { $0.id == id })
    #expect(history.dragProvider(for: after).suggestedName == "我自己命的名.png")
  }

  /// 改完标注拖出去的是新的那张（第三轮体检 R2）：存过盘的也不拖存的那个旧文件，拖历史里的原图 + 现在的标注；
  /// 旧的那份不再给（文件留着：拖进聊天的附件可能还在读，启动时整个目录清空）
  @Test func dragFollowsAnnotations() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try #require(await history.record(image(), scale: 2))
    let saved = root.appending(path: "我存过的.png")
    try Data(contentsOf: history.url(for: id)).write(to: saved)
    history.markSaved(id, to: saved)
    let (first, plain) = try await dragged(history, id)
    #expect(ShotHistory.isDisposable(first) && first.path != saved.path)
    #expect(first.lastPathComponent == "我存过的.png")  // 名字借存的那个
    #expect(Self.redness(of: plain) < 0.1)
    // 盖一块整张大的实心红矩形（option 1 = 实心），改完再拖
    try await update(
      history, id,
      [
        Annotation(
          shape: .rectangle(CGRect(x: 0, y: 0, width: 200, height: 150)),
          style: Annotation.Style(color: .red, weight: .large, option: 1))
      ])
    #expect(history.dragFileNow(for: try #require(history.item(id))) == nil)  // 旧的不再给
    let (second, drawn) = try await dragged(history, id)
    #expect(second != first && ShotHistory.isDisposable(second))
    #expect(FileManager.default.fileExists(atPath: first.path))  // 旧的那份不删
    #expect(Self.redness(of: drawn) > Self.redness(of: plain) + 0.1, "拖出去的还是旧图")
    // 存的那个文件不动
    #expect(FileManager.default.fileExists(atPath: saved.path))
    for made in [first, second] {
      try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
    }
  }

  /// 录制的拖的那一下才克隆一份（第三轮体检 R3：晾衣绳允许拖进废纸篓，扔掉的得是这份、不是用户的录像；
  /// 不先备着：克隆和原文件共用数据块，用户删了原录像空间回不来）
  @Test func dragClonesUserFiles() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "录屏 2026-10-27.mov")
    try Data("假的录像".utf8).write(to: file)
    let id = try #require(await history.record(file: file, poster: image(), kind: .video))
    let item = try #require(history.item(id))
    let url = try #require(history.dragFileNow(for: item))  // 同步：晾衣绳在鼠标拖动里调
    #expect(url != file && ShotHistory.isDisposable(url))
    #expect(url.lastPathComponent == file.lastPathComponent)
    #expect(try Data(contentsOf: url) == Data(contentsOf: file))
    // 拖进废纸篓扔的是克隆：用户的文件还在
    try FileManager.default.removeItem(at: url)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(!ShotHistory.isDisposable(file))
    // 每拖一次现克隆一份（不记着），历史窗口那条路也一样
    let again = try #require(await history.dragFile(for: item))
    #expect(again != url && ShotHistory.isDisposable(again))
    // 删掉这一条：录制的原文件不动，拖出去的克隆也不删（启动时清空）
    history.remove([id])
    try await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: again.path))
    for made in [url, again] {
      try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
    }
  }

  /// 缩略图缓存（P2）：读不到的记下、不再读盘；读的途中被 forget（改完标注）的那份不进缓存；
  /// keep(only:) 只留给的那几张。用自己的一份缓存（共用的那份别的测会清）
  @Test func thumbnailCache() async throws {
    let cache = ShotThumbnails()
    let tiny = image(width: 40, height: 30)
    let a = item(.shot, 0)
    let b = item(.shot, 0)
    var reads = 0
    // 读不到：记下，第二次不再读
    #expect(
      await cache.image(for: a) {
        reads += 1
        return nil
      } == nil)
    #expect(
      await cache.image(for: a) {
        reads += 1
        return tiny
      } == nil)
    #expect(reads == 1)
    // forget 之后重新读。「还在缓存里」不断言：系统内存紧时 NSCache 会整个清掉（全量并行跑时见过），只测清不清
    cache.forget(a.id)
    #expect(await cache.image(for: a) { tiny } != nil)
    // 读的途中 forget：读回来的照样给调用方，但不进缓存
    cache.forget(a.id)
    let (gate, open) = AsyncStream<Void>.makeStream()
    var begun = false
    let loading = Task {
      await cache.image(for: a) {
        begun = true
        for await _ in gate {}
        return tiny
      }
    }
    while !begun { await Task.yield() }
    cache.forget(a.id)
    open.finish()
    #expect(await loading.value != nil)
    #expect(cache.cached(a.id) == nil, "forget 之前开始读的那份进了缓存")
    // keep(only:)：只留给的那几张
    _ = await cache.image(for: a) { tiny }
    _ = await cache.image(for: b) { tiny }
    cache.keep(only: [b.id])
    #expect(cache.cached(a.id) == nil)
  }

  /// 摆一扇屏幕外的窗口（同全部便签窗口的那几扇：不激活、不会被 AppKit 拽回屏幕里）
  private func stage(_ view: some View) -> NSWindow {
    let window = Offscreen(contentViewController: .windowContent(view))
    window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 960, height: 620))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    return window
  }

  /// 窗口里的快捷键真按一遍（屏幕外的窗口、不激活，事件直接交给 performKeyEquivalent）：
  /// 挂在看不见的按钮上的键最容易「挂上了却不灵」，光看代码看不出来
  @Test func shortcutsReachTheActions() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    var ids: [UUID] = []
    for _ in 0..<3 { ids.append(try #require(await history.record(image(), scale: 2))) }
    let model = ShotHistoryModel(history: history)
    var done: [String] = []
    model.actions.copy = { _ in done.append("拷贝") }
    model.actions.save = { _ in done.append("存储") }
    model.actions.saveAs = { _ in done.append("另存为") }
    model.actions.pin = { _ in done.append("钉图") }
    model.actions.recognize = { _ in done.append("识字") }
    model.actions.edit = { _ in done.append("改标注") }
    let window = stage(ShotHistoryView(model: model))
    defer { window.orderOut(nil) }
    #expect(window.screen == nil)  // 没被挪进屏幕里（跑测试时不闪窗口）
    let settle = { for _ in 0..<4 { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) } }
    func press(
      _ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags = .command,
      plain: String? = nil
    ) throws -> Bool {
      defer { settle() }
      return window.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: plain ?? characters, isARepeat: false,
            keyCode: UInt16(keyCode))))
    }
    func arrow(_ scalar: Int, _ keyCode: Int) throws -> Bool {
      let text = String(UnicodeScalar(UInt32(scalar))!)
      return try press(text, keyCode, [], plain: text)
    }
    settle()

    // 没选中的时候：⌘C 不接（那颗按钮是灰的），事件让给别人
    #expect(try !press("c", kVK_ANSI_C))
    #expect(done.isEmpty)

    // 方向键挑：最新的在最前
    #expect(try arrow(NSRightArrowFunctionKey, kVK_RightArrow))
    #expect(model.selection == ids[2])
    #expect(try arrow(NSRightArrowFunctionKey, kVK_RightArrow))
    #expect(model.selection == ids[1])
    // ↓ 跳一行（一行几张由窗口宽度量出来，少于一行时落到最后一张）
    let columns = model.columnsPerRow
    #expect(columns >= 1)
    #expect(try arrow(NSDownArrowFunctionKey, kVK_DownArrow))
    #expect(model.selection == ids[0])
    #expect(try arrow(NSUpArrowFunctionKey, kVK_UpArrow))
    #expect(model.selection == ids[min(2, columns)])
    #expect(try arrow(NSLeftArrowFunctionKey, kVK_LeftArrow))

    // 选中了：每个键落到对应的动作上
    model.selection = ids[1]
    settle()
    #expect(try press("c", kVK_ANSI_C))
    #expect(try press("s", kVK_ANSI_S))
    // ⇧⌘S 是窗口自己认的（本地按键监听在 performKeyEquivalent 之前，屏外发事件走不到那条路）
    #expect(
      ShotHistoryWindow.handlesKeyDown(
        try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "S",
            charactersIgnoringModifiers: "S", isARepeat: false, keyCode: UInt16(kVK_ANSI_S))),
        in: window, model: model))
    #expect(try press("p", kVK_ANSI_P))
    #expect(try press("o", kVK_ANSI_O))
    #expect(try press("\r", kVK_Return, []))
    #expect(done == ["拷贝", "存储", "另存为", "钉图", "识字", "改标注"], "实际：\(done)")

    // ⌘1…⌘4 换筛选
    #expect(try press("3", kVK_ANSI_3) && model.filter == .scroll)
    #expect(try press("1", kVK_ANSI_1) && model.filter == .all)
  }

  /// 方向键挑到看不见的那一行时，内容区跟着滚（2026-10-27 用户手测报的）。
  /// 真量滚动视图的位置：光看代码看不出 ScrollViewReader 接没接上
  @Test func arrowKeysScrollIntoView() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    // 够滚起来的条数（窗口 620 高，一行约 150）
    for _ in 0..<30 { _ = await history.record(image(width: 200, height: 150), scale: 2) }
    let model = ShotHistoryModel(history: history)
    let window = stage(ShotHistoryView(model: model))
    defer { window.orderOut(nil) }
    let settle = { for _ in 0..<4 { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) } }
    settle()
    // 窗口里内容最高的那个滚动视图就是左边的网格
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
    }
    let content = try #require(window.contentView)
    let grid = try #require(
      scrollViews(content).max {
        ($0.documentView?.frame.height ?? 0)
          < ($1.documentView?.frame.height ?? 0)
      })
    #expect(
      (grid.documentView?.frame.height ?? 0) > grid.contentSize.height + 50, "没撑出可滚的内容")
    let before = grid.documentVisibleRect.origin.y

    // 一路按 ↓ 到最后一张
    let down = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
    for _ in 0..<12 {
      _ = window.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: down,
            charactersIgnoringModifiers: down, isARepeat: false, keyCode: UInt16(kVK_DownArrow))))
      settle()
    }
    #expect(model.selection == history.items.last?.id, "没走到最后一张")
    #expect(grid.documentVisibleRect.origin.y != before, "选中挪到看不见的那行，内容区没跟着滚")
  }

  /// 一行几张、方向键挪到第几张（纯函数）
  @Test func gridStepping() {
    // .adaptive(minimum: 168)、间距 12、两边各留 16
    #expect(ShotHistoryModel.columns(width: 420, card: 168, spacing: 12, padding: 16) == 2)
    #expect(ShotHistoryModel.columns(width: 680, card: 168, spacing: 12, padding: 16) == 3)
    #expect(ShotHistoryModel.columns(width: 100, card: 168, spacing: 12, padding: 16) == 1)
    // 夹在两头、不绕圈
    #expect(ShotHistoryModel.stepped(from: 0, by: -1, count: 5) == 0)
    #expect(ShotHistoryModel.stepped(from: 4, by: 1, count: 5) == 4)
    #expect(ShotHistoryModel.stepped(from: 1, by: 3, count: 5) == 4)
    #expect(ShotHistoryModel.stepped(from: 0, by: 1, count: 0) == 0)
  }

  /// 窗口建得出来、标题对，关掉之后不再可见
  @Test func windowOpens() throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let window = ShotHistoryWindow(model: ShotHistoryModel(history: history), frameName: nil)
    #expect(window.window.title == "截图历史")
    #expect(window.window.contentMinSize.width >= 720)
    window.window.close()
    #expect(!window.isVisible)
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

  /// 记一条之后自己清一遍，上限按 MB 算（第三轮体检 R9）：两条各约 0.4 MB、上限 1 MB 都留着（当成字节的话会删到只剩
  /// 一条）；头一条长到 2 MB 后再记一条，它当场被删掉（连图一起）
  @Test func prunesAfterRecording() async throws {
    let (history, root) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    history.defaults.set(1, forKey: Prefs.shotHistoryMegabytes)
    let first = try #require(await history.record(image(), scale: 2))
    _ = await history.record(image(), scale: 2)
    history.seed(history.items.map { modified($0, bytes: 400_000) })
    history.prune()
    #expect(history.items.count == 2)
    history.seed(history.items.map { $0.id == first ? modified($0, bytes: 2 * 1024 * 1024) : $0 })
    _ = await history.record(image(), scale: 2)
    #expect(history.items.count == 2 && !history.items.contains { $0.id == first })
    try await waitUntil { !FileManager.default.fileExists(atPath: history.url(for: first).path) }
    #expect(!FileManager.default.fileExists(atPath: history.url(for: first).path))
  }

  private func modified(_ item: ShotHistory.Item, bytes: Int) -> ShotHistory.Item {
    var item = item
    item.bytes = bytes
    return item
  }
}

/// 屏幕外的窗口：不让 AppKit 把它拽回屏幕里（同 NotesWindowTests）
private final class Offscreen: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
