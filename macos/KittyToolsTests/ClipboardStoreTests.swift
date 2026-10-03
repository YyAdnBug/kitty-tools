// ClipboardStore / ImageStore 单测：去重置顶、各项上限只动普通历史、清空、落库往返、图片编码、旧库迁移、
// 收藏夹（归进去就是收藏、删了留在收藏、拖动排序）、撤销栈（连撤、收起时提交、再复制拿回来）、取消收藏后超期的提示与保护；
// 剪贴板面板（Lens Bar）的纯逻辑：高度与透镜预留、列表前缀和、筛选标签与 Tab / ⇧Tab / ⌫ / Esc、粘贴动词与写进剪贴板的内容、
// ⌘C 后收起才置顶。
// 用内存库 + 临时目录，不碰真实数据。

import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
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
    grouped.favorite = true  // 收藏夹里的都是收藏
    grouped.groupID = UUID()
    var noted = text("noted")
    noted.note = "备注不算留下"
    // record 末尾按偏好（Limits.current，读宿主的 UserDefaults，别的测试可能 registerDefaults）先裁一次：
    // 普通条目都记成「此刻或以后」，再把 now 拨后 10 天造出超期，偏好怎么设（最少 1 天）都裁不到
    let later = Date.now.addingTimeInterval(10 * 86_400)
    for item in [favorite, snippet, grouped, noted, text("old"), text("x", ago: -9 * 86_400)] {
      store.record(item)
    }
    // 删了几条要报给设置页的刘海提示：old、noted（超天数；条数不再限制）
    #expect(store.enforceLimits(.init(maxAge: 7 * 86_400), now: later) == 2)
    #expect(Set(store.items.compactMap(\.text)) == ["fav", "snippet", "grouped", "x"])
    #expect(store.enforceLimits(.init(maxAge: 7 * 86_400), now: later) == 0)
  }

  /// 图片预算只算普通图片（体检 B2）：收藏的大图不占额度；超了从最旧的普通图片删起，最新的一张（刚复制的）这一轮不删
  @Test func imageBudgetCountsOnlyOrdinaryImages() throws {
    let (store, _) = try makeStore()
    var favorite = ClipItem(kind: .image, copiedAt: Date.now.addingTimeInterval(-40))
    favorite.image = .init(width: 1, height: 1, byteCount: 1000, sha256: "fav")
    favorite.favorite = true
    store.record(favorite)
    for (index, age) in [30.0, 20, 10].enumerated() {
      var item = ClipItem(kind: .image, copiedAt: Date.now.addingTimeInterval(-age))
      item.image = .init(width: 1, height: 1, byteCount: 100, sha256: "hash\(index)")
      store.record(item)
    }
    #expect(store.imageUsage == (ordinary: 300, retained: 1000))
    store.enforceLimits(.init(imageBytes: 250))
    #expect(Set(store.items.compactMap(\.image?.sha256)) == ["fav", "hash1", "hash2"])
    // 预算比一张还小：普通图片里最新的一张还在
    store.enforceLimits(.init(imageBytes: 50))
    #expect(Set(store.items.compactMap(\.image?.sha256)) == ["fav", "hash2"])
  }

  /// 清空（锁屏 / 设置里立即清空）先提交撤销栈：删掉的普通条目清空后不能再 ⌘Z 回来
  @Test func clearOrdinaryKeepsRetained() throws {
    let (store, _) = try makeStore()
    var favorite = text("fav")
    favorite.favorite = true
    store.record(favorite)
    store.record(text("temp"))
    store.record(text("deleted"))
    store.deleteWithUndo([store.items[0].id])
    #expect(store.clearOrdinary() == 1)
    #expect(store.items.map(\.text) == ["fav"])
    store.undo()
    #expect(store.items.map(\.text) == ["fav"])
    #expect(store.clearOrdinary() == 0)
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

  /// 取消收藏 = 同时移出收藏夹，备注不动（体检 A1 A3）
  @Test func unfavoriteLeavesFolderAndKeepsNote() throws {
    let (store, _) = try makeStore()
    var snippet = text("s")
    snippet.isSnippet = true
    store.record(snippet)
    store.record(text("h"))
    let ids = Set(store.items.map(\.id))
    let work = try #require(store.createGroup(named: "工作"))
    store.assign(ids, to: work.id)
    #expect(store.items.allSatisfy { $0.favorite && $0.groupID == work.id })
    store.update(ids) { $0.note = "备注" }
    store.toggleFavorite(ids)
    #expect(store.items.allSatisfy { !$0.favorite && $0.groupID == nil && $0.note == "备注" })
    // 移出收藏夹（没有取消收藏）：留在默认收藏
    store.assign(ids, to: work.id)
    store.assign(ids, to: nil)
    #expect(store.items.allSatisfy { $0.favorite && $0.groupID == nil })
  }

  /// 取消收藏 / 移出片段后已超过保留天数的：记进撤销栈、收起面板前不被清理，⌘Z 改回来；提交后下次清理才删（体检 A1）
  @Test func unretainedExpiredItemsWaitForCommit() throws {
    let (store, _) = try makeStore()
    let later = Date.now.addingTimeInterval(10 * 86_400)
    let week = ClipboardStore.Limits(maxAge: 7 * 86_400)
    var old = text("旧收藏")
    old.favorite = true
    var fresh = text("新收藏", ago: -9 * 86_400)
    fresh.favorite = true
    var snippet = text("旧片段")
    snippet.isSnippet = true
    for item in [old, fresh, snippet] { store.record(item) }
    let favorites = Set([old.id, fresh.id])
    #expect(store.changeRetention(favorites, limits: week, now: later) { $0.favorite = false } == 1)
    #expect(store.enforceLimits(week, now: later) == 0)  // 还能撤销：不删
    store.undo()
    #expect(store.items.first { $0.id == old.id }?.favorite == true)
    #expect(store.items.first { $0.id == fresh.id }?.favorite == false)  // 没超期的不进撤销栈
    #expect(
      store.changeRetention([snippet.id], limits: week, now: later) { $0.isSnippet = false } == 1)
    #expect(store.changeRetention([old.id], limits: week, now: later) { $0.favorite = false } == 1)
    store.commitDeletion()
    #expect(!store.canUndo)
    #expect(store.enforceLimits(week, now: later) == 2)
    #expect(store.items.map(\.text) == ["新收藏"])
  }

  @Test func editDropsRichFormat() throws {
    let (store, db) = try makeStore()
    var rich = text("原文")
    rich.richType = .html
    store.record(rich, rich: Data("<b>原文</b>".utf8))
    store.update([rich.id]) { $0.text = "改过" }
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items[0].text == "改过" && reloaded.items[0].richType == nil)
    #expect(reloaded.pasteboardItems(for: reloaded.items[0])[0].data(forType: .html) == nil)
  }

  /// 撤销栈（体检 A2）：两批连删、连撤两次按原位插回；新的删除不提交上一批；commitDeletion（面板收起、退出）才删库
  @Test func undoDeletionRestoresPositionAndCommitPurges() throws {
    let (store, db) = try makeStore()
    for (name, age) in [("d", 4.0), ("c", 3), ("b", 2), ("a", 1)] {
      store.record(text(name, ago: age))
    }
    let id = { (name: String) in store.items.first { $0.text == name }!.id }
    store.deleteWithUndo([id("b")])
    store.deleteWithUndo([id("a"), id("d")])
    #expect(store.items.map(\.text) == ["c"])
    guard case .deleted(let last) = store.undo() else {
      Issue.record("没撤到删除")
      return
    }
    #expect(last.count == 2 && store.items.map(\.text) == ["a", "c", "d"])
    store.undo()
    #expect(store.items.map(\.text) == ["a", "b", "c", "d"] && !store.canUndo)
    store.deleteWithUndo([id("b")])
    store.deleteWithUndo([id("c")])
    let (beforeCommit, _) = try makeStore(db)
    #expect(beforeCommit.items.count == 4)  // 没提交前库里还在
    store.commitDeletion()
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items.map(\.text) == ["a", "d"])
  }

  /// 删了还没提交时又复制了同样的内容：从撤销栈里拿回原条目挪到最前（保留收藏、备注），不新建一条，之后 ⌘Z 也不会出现两条
  @Test func recordReclaimsPendingDeletion() throws {
    let (store, db) = try makeStore()
    var noted = text("同一段", ago: 100)
    noted.favorite = true
    noted.note = "备注"
    store.record(noted)
    store.record(text("别的"))
    store.deleteWithUndo([noted.id])
    store.record(text("同一段"))
    #expect(store.items.map(\.text) == ["同一段", "别的"])
    #expect(store.items[0].id == noted.id && store.items[0].note == "备注" && store.items[0].favorite)
    #expect(!store.canUndo)
    store.commitDeletion()
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items.map(\.text) == ["同一段", "别的"])
  }

  @Test func snippetsMergeWithSameText() throws {
    let (store, _) = try makeStore()
    store.record(text("常用"))
    store.saveSnippet("常用")
    store.saveSnippet("新的")
    #expect(store.items.count == 2)
    #expect(store.items.allSatisfy { $0.isSnippet })
  }

  /// 收藏夹：名字去空白、不重名、超过 24 字不收（不截断）；拖动排序落库；删掉后条目留在收藏，⌘Z 连位置和归属一起回来
  @Test func groups() throws {
    let (store, db) = try makeStore()
    let work = try #require(store.createGroup(named: "  工作  "))
    #expect(work.name == "工作")
    #expect(store.createGroup(named: "工作") == nil)  // 重名
    #expect(store.createGroup(named: "   ") == nil)
    #expect(store.createGroup(named: String(repeating: "长", count: 25)) == nil)
    let long = try #require(store.createGroup(named: String(repeating: "长", count: 24)))
    let home = try #require(store.createGroup(named: "生活"))
    store.record(text("x"))
    store.assign([store.items[0].id], to: work.id)
    #expect(store.items[0].favorite)  // 归进收藏夹就是收藏
    #expect(store.renameGroup(work.id, to: "项目"))
    #expect(!store.renameGroup(work.id, to: "生活"))
    store.moveGroup(home.id, to: 0)
    #expect(try makeStore(db).0.groups.map(\.id) == [home.id, work.id, long.id])
    store.deleteGroup(work.id)
    #expect(store.items[0].groupID == nil && store.items[0].favorite)
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items[0].groupID == nil && reloaded.items[0].favorite)
    #expect(reloaded.groups.map(\.id) == [home.id, long.id])
    guard case .group(let restored, let index, _) = store.undo() else {
      Issue.record("没撤到删掉的收藏夹")
      return
    }
    #expect(restored.name == "项目" && index == 1)
    #expect(store.groups.map(\.id) == [home.id, work.id, long.id])
    #expect(store.items[0].groupID == work.id)
    let (again, _) = try makeStore(db)
    #expect(again.groups.map(\.id) == [home.id, work.id, long.id])
    #expect(again.items[0].groupID == work.id)
    // 连删两个再新建：排序号压实了，重新打开顺序不变（不压实的话新建的会和剩下的撞号、排到前面）
    store.deleteGroup(home.id)
    store.deleteGroup(work.id)
    store.commitDeletion()
    let added = try #require(store.createGroup(named: "新的"))
    #expect(try makeStore(db).0.groups.map(\.id) == [long.id, added.id])
  }

  /// 旧库升级（幂等）：clip_groups 补 position（按创建时间），已归组没收藏的条目置收藏；再开一次不出错、结果不变
  @Test func migratesOldDatabase() throws {
    let db = try Database(path: ":memory:")
    try db.execute(
      """
      CREATE TABLE clips(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT, file_paths TEXT,
        image_width INTEGER, image_height INTEGER, image_bytes INTEGER, image_sha256 TEXT,
        ocr_text TEXT, rich_type TEXT, rich_data BLOB, source_name TEXT, source_bundle_id TEXT,
        copied_at REAL NOT NULL, favorite INTEGER NOT NULL DEFAULT 0,
        snippet INTEGER NOT NULL DEFAULT 0, note TEXT, group_id TEXT)
      """)
    try db.execute(
      "CREATE TABLE clip_groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL)")
    let (early, late) = (UUID(), UUID())
    try db.execute(
      "INSERT INTO clip_groups VALUES (?, '后建的', 200), (?, '先建的', 100)",
      [late.uuidString, early.uuidString])
    let (grouped, plain) = (UUID(), UUID())
    try db.execute(
      "INSERT INTO clips(id, kind, text, copied_at, group_id) VALUES (?, 'text', 'a', 1, ?), (?, 'text', 'b', 2, NULL)",
      [grouped.uuidString, late.uuidString, plain.uuidString])
    for _ in 0..<2 {
      let (store, _) = try makeStore(db)
      #expect(store.groups.map(\.id) == [early, late])
      #expect(store.items.first { $0.id == grouped }?.favorite == true)
      #expect(store.items.first { $0.id == plain }?.favorite == false)
    }
  }

  // MARK: 面板（Lens Bar）

  @Test func panelHeightReservesLensAndCaps() throws {
    #expect(ClipboardPanelView.listHeight(rows: 0, sections: 0, reservesLens: true) == 140)
    // 上下内缩 12 + 分组标题 24 + 两行 80（+ 透镜预留 158）
    #expect(ClipboardPanelView.listHeight(rows: 2, sections: 1, reservesLens: true) == 274)
    #expect(ClipboardPanelView.listHeight(rows: 2, sections: 1, reservesLens: false) == 116)
    #expect(ClipboardPanelView.listHeight(rows: 50, sections: 3, reservesLens: true) == 427.5)
    let (store, _) = try makeStore()
    for index in 0..<3 { store.record(text("条目 \(index)", ago: Double(10 - index))) }
    let model = ClipboardPanelModel(store: store)
    let height = ClipboardPanelView.height(for: model, showsLens: true, banner: false)
    #expect(height == 406.5)  // 56 + 0.5 + (12 + 24 + 120 + 158) + 36
    // ↑↓ 换选中不改窗口高度（透镜预留是常数）
    model.select(store.items[2])
    #expect(ClipboardPanelView.height(for: model, showsLens: true, banner: false) == height)
    // 浮起的菜单要放得下 8.5 行、对话框给满
    model.palette = .filters
    #expect(ClipboardPanelView.height(for: model, showsLens: false, banner: false) == 356.5)
    model.palette = nil
    model.dialog = .newSnippet
    #expect(ClipboardPanelView.height(for: model, showsLens: true, banner: true) == 550)
    // 片段范围多一行「新建片段」，没有片段时也不是空态
    model.dialog = nil
    model.scope = .snippets
    #expect(ClipboardPanelView.height(for: model, showsLens: true, banner: false) == 144.5)
    // 片段范围里搜索没有结果：不画「新建片段」，给「没有匹配的条目」空态（高 140）
    model.query = "zzzz"
    #expect(model.isFiltered && !model.showsNewSnippetRow(in: model.visibleItems))
    #expect(ClipboardPanelView.height(for: model, showsLens: true, banner: false) == 232.5)
  }

  @Test func listLayoutPrefixSums() {
    let (a, b, c) = (text("a"), text("b"), text("c"))
    let sections: [ClipboardPanelView.DaySection] = [
      (.now, "今天", [(0, a), (1, b)]), (.distantPast, "昨天", [(2, c)]),
    ]
    let layout = ListLayout(sections: sections, lens: (b.id, 198))
    #expect(layout.offset(of: a.id) == 24)
    #expect(layout.offset(of: b.id) == 64)
    #expect(layout.offset(of: c.id) == 286)  // 24 + 40 + 198 + 24
    #expect(layout.sectionTops == [0, 262])
    #expect(layout.height(of: b.id) == 198 && layout.height(of: a.id) == 40)
    // 片段范围第一行「新建片段」
    let leading = ListLayout(leading: 40, sections: sections, lens: nil)
    #expect(leading.offset(of: c.id) == 168)  // 40 + 24 + 80 + 24
    #expect(leading.sectionTops == [40, 144])
  }

  /// 剪贴板面板挂进屏外窗口（不弹面板、不抢键盘）；「显示透镜」等用临时偏好域，不读 Dev 版里手测时改过的设置
  private func showPanel(_ model: ClipboardPanelModel) throws -> (
    window: NSWindow, close: () -> Void
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: ClipboardPanelView.width, height: 520),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let suite = "kitty-lens-test-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    window.contentView = NSHostingView(
      rootView: ClipboardPanelView(model: model).defaultAppStorage(prefs))
    window.orderFront(nil)
    return (
      window,
      {
        window.orderOut(nil)
        prefs.removePersistentDomain(forName: suite)
      }
    )
  }

  /// 每行背景里的 HoverTracker 是一个和整行（含透镜）一样大的 NSView：拿它的 frame（窗口坐标，原点左下）当行实际画在哪
  private func drawnRows(in view: NSView) -> [CGRect] {
    (String(describing: type(of: view)) == "TrackingView"
      ? [view.convert(view.bounds, to: nil)] : [])
      + view.subviews.flatMap(drawnRows(in:))
  }

  /// 实际画出来的行里正好一行展开成选中项的透镜，⌘Y 的起点（cardFrame，窗口坐标、原点左上）就是这一行；返回这一行
  @discardableResult
  private func expectLens(
    _ model: ClipboardPanelModel, in window: NSWindow, _ step: Comment
  ) throws -> (item: ClipItem, row: CGRect, drawn: [CGRect]) {
    let view = try #require(window.contentView)
    let item = try #require(model.selectedItem)
    let lens = Lens.height(for: item, form: model.contentForm(of: item))
    let drawn = drawnRows(in: view).sorted { $0.maxY > $1.maxY }
    let expanded = drawn.filter { $0.height > ClipRowView.height + 1 }
    #expect(expanded.count == 1 && abs(expanded[0].height - lens) < 0.5, step)
    let row = try #require(expanded.first, step)
    let card = try #require(model.cardFrame, step)
    #expect(card.id == item.id, step)
    #expect(
      abs(card.rect.minY - (view.bounds.height - row.maxY)) < 0.5
        && abs(card.rect.height - lens) < 0.5, step)
    return (item, row, drawn)
  }

  /// 选中行换了所在分组（搜索前后、昨天的条目再复制挪进「今天」）后照样按透镜高度展开、跟着选中走：
  /// 透镜那一行离第一行的距离 = 前缀和里的差（高亮按前缀和画）。行的身份只有条目 id 时这里失败：旧行被原样搬过去、
  /// 不再更新，透镜不展开，高亮盖住下面几行。昨天那条取昨天最后一秒，保留天数最短 1 天也不会被裁掉
  @Test func lensFollowsRowsAcrossSections() throws {
    let (store, _) = try makeStore()
    let sinceMidnight = Date.now.timeIntervalSince(Calendar.current.startOfDay(for: .now))
    store.record(text("昨天的一段文字", ago: sinceMidnight + 1))
    store.record(text("YyAdnBug/kitty-tools", ago: 600))
    store.record(text("https://github.com/YyAdnBug/kitty-tools.git", ago: 400))
    store.record(text("短文本", ago: 100))
    let model = ClipboardPanelModel(store: store)
    let (window, close) = try showPanel(model)
    defer { close() }
    func check(_ step: Comment) throws {
      let items = model.visibleItems
      // 至少等 0.5 s 让透镜动画走完；删掉的行还在播退场就再等（最多 2 s），一直多出来的行（搬走没清掉的旧行）照样失败
      for tick in 0..<25 {
        RunLoop.main.run(until: .now.addingTimeInterval(0.1))
        if tick >= 4, drawnRows(in: try #require(window.contentView)).count == items.count { break }
      }
      let (item, row, drawn) = try expectLens(model, in: window, step)
      #expect(drawn.count == items.count, step)
      let layout = ListLayout(
        sections: ClipboardPanelView.daySections(items), lens: (item.id, row.height))
      let offset = try #require(layout.offset(of: item.id)) - (layout.offset(of: items[0].id) ?? 0)
      #expect(abs((drawn.first?.maxY ?? 0) - row.maxY - offset) < 0.5, step)
    }
    let down = { _ = model.handleCommand(#selector(NSResponder.moveDown(_:))) }
    try check("没有搜索词")
    model.query = "kitty"
    try check("搜索（只过滤，照样按天分组）")
    down()
    try check("搜索结果里 ↓")
    model.query = ""
    try check("清掉搜索词")
    for _ in 0..<3 { down() }
    #expect(model.selectedItem?.text == "昨天的一段文字")
    store.record(text("昨天的一段文字"))
    try check("昨天的条目再复制，挪进「今天」")
    down()
    try check("挪完再 ↓")
  }

  /// ↓ 带着列表滚动时 ⌘Y 的起点照样是新的透镜：换下去的上报视图要是跟着选中动画淡出，滚动中它还会报旧 id，
  /// 拿掉时再把新的清成 nil，放大卡就从整个面板长出来
  @Test func lensOriginFollowsScrolling() throws {
    let (store, _) = try makeStore()
    for index in 0..<12 { store.record(text("第 \(index) 条", ago: Double(100 - index))) }
    let model = ClipboardPanelModel(store: store)
    let (window, close) = try showPanel(model)
    defer { close() }
    for step in 1...10 {
      _ = model.handleCommand(#selector(NSResponder.moveDown(_:)))
      for _ in 0..<6 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) }
      try expectLens(model, in: window, "↓ 第 \(step) 下")
    }
  }

  /// 条目多、一下跳得远（2026-10-03 用户报：数据多了高亮错位）：从第一条按 ↑ 绕到最后一条、再跳回中间，
  /// 透镜照样画在高亮（前缀和）的位置上。交给 LazyVStack 时这里失败：它没排过的行按已排过的平均高度估
  /// （分组标题、透镜混在里面），绕到最后时屏上是一百多行之前的那几条，选中的行根本没画出来
  @Test func lensStaysOnRowInLongList() throws {
    let (store, _) = try makeStore()
    // 600 条每 2 分钟一条（20 小时内：record 会按保留天数清掉过期的，最短 1 天；跨不跨午夜看跑的时候），
    // 文本长短混着：透镜高度不一（短文本 70、长文本 160）
    for index in (0..<600).reversed() {
      let body = index % 3 == 0 ? String(repeating: "一段比较长的文字，", count: 12) : "短"
      store.record(text("第 \(index) 条 " + body, ago: Double(index) * 120 + 60))
    }
    #expect(store.items.count == 600)
    let model = ClipboardPanelModel(store: store)
    let (window, close) = try showPanel(model)
    defer { close() }
    func settle() { for _ in 0..<8 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    settle()
    try expectLens(model, in: window, "第一条")
    _ = model.handleCommand(#selector(NSResponder.moveUp(_:)))
    settle()
    #expect(model.selectedItem?.id == model.visibleItems.last?.id)
    try expectLens(model, in: window, "↑ 绕到最后一条")
    _ = model.handleCommand(#selector(NSResponder.moveUp(_:)))
    settle()
    try expectLens(model, in: window, "再 ↑")
    model.select(model.visibleItems[310])
    settle()
    try expectLens(model, in: window, "跳回中间")
    _ = model.handleCommand(#selector(NSResponder.moveDown(_:)))
    settle()
    try expectLens(model, in: window, "中间 ↓")
  }

  /// 列表靠后时 ↑↓ 也快（2026-10-03 用户报卡顿）：找当前选中项时只搜一遍列表。原来在 firstIndex 的闭包里每比一条
  /// 都重新搜索、过滤整个列表，选中第 700 条时按一下要 300 ms
  @Test func movingDeepInLongListIsCheap() throws {
    let (store, _) = try makeStore()
    for index in (0..<600).reversed() { store.record(text("第 \(index) 条", ago: Double(index) + 1)) }
    let model = ClipboardPanelModel(store: store)
    model.select(model.visibleItems[550])
    let start = CACurrentMediaTime()
    for _ in 0..<5 { _ = model.handleCommand(#selector(NSResponder.moveDown(_:))) }
    #expect(model.selectedItem?.id == model.visibleItems[555].id)
    #expect(CACurrentMediaTime() - start < 0.15, "5 下 ↓ 用了 \(CACurrentMediaTime() - start) s")
  }

  /// ⌘W：对话框开着时只关对话框（同 Esc 逐级退，没保存的字不随面板一起丢；大写锁定开着也一样），
  /// 没有对话框时交给 OverlayPanel 收起面板
  @Test func commandWClosesDialogFirst() throws {
    let (store, _) = try makeStore()
    let model = ClipboardPanelModel(store: store)
    func commandW(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
          keyCode: UInt16(kVK_ANSI_W)))
    }
    model.dialog = .newSnippet
    #expect(model.handleKeyEquivalent(try commandW(.command)))
    #expect(model.dialog == nil)
    model.dialog = .newSnippet
    #expect(model.handleKeyEquivalent(try commandW([.command, .capsLock])))
    #expect(model.dialog == nil)
    #expect(!model.handleKeyEquivalent(try commandW(.command)))
  }

  /// ⌘K 的「移到收藏夹 ›」子列表（体检 C3，和右键子菜单、多选底栏「收藏夹…」同一份）：按拖动排的顺序，
  /// 都在里面的那个打 ✓、再选一次移出；有一条在收藏夹里就给「移出收藏夹」；最后「新建收藏夹…」。
  /// 放进去就是收藏，移出后留在默认收藏；一个收藏夹都没有时第一级直接是「放进新收藏夹…」
  @Test func actionsMoveBetweenGroups() throws {
    let (store, _) = try makeStore()
    store.record(text("a", ago: 2))
    store.record(text("b", ago: 1))
    let model = ClipboardPanelModel(store: store)
    #expect(model.actions.contains { $0.title == "放进新收藏夹…" && $0.submenu == nil })
    let work = try #require(store.createGroup(named: "工作"))
    let home = try #require(store.createGroup(named: "生活"))
    let submenu = { model.actions.first { $0.id == "groups" }?.submenu ?? [] }
    #expect(submenu().map(\.title) == ["工作", "生活", "新建收藏夹…"])
    #expect(submenu().allSatisfy { $0.isChecked != true })
    store.moveGroup(home.id, to: 0)
    #expect(submenu().map(\.title) == ["生活", "工作", "新建收藏夹…"])
    submenu().first { $0.title == "工作" }?.run()
    #expect(store.items[0].groupID == work.id && store.items[0].favorite)
    #expect(submenu().map(\.title) == ["生活", "工作", "移出收藏夹", "新建收藏夹…"])
    #expect(submenu().first { $0.title == "工作" }?.isChecked == true)
    // 再选一次打了 ✓ 的：移出，留在默认收藏
    submenu().first { $0.title == "工作" }?.run()
    #expect(store.items[0].groupID == nil && store.items[0].favorite)
    // 多选：都在「生活」里才打 ✓；有一条在收藏夹里就给「移出收藏夹」
    model.multiSelection = Set(store.items.map(\.id))
    submenu().first { $0.title == "生活" }?.run()
    #expect(store.items.allSatisfy { $0.groupID == home.id && $0.favorite })
    #expect(submenu().first { $0.title == "生活" }?.isChecked == true)
    submenu().first { $0.title == "移出收藏夹" }?.run()
    #expect(store.items.allSatisfy { $0.groupID == nil && $0.favorite })
    // 多选底栏「收藏夹…」是同一份列表
    model.palette = .groups
    #expect(model.filteredActions.map(\.title) == submenu().map(\.title))
    // 筛选面板：收藏夹紧跟在「收藏」下面，最后是「管理收藏夹…」；范围和收藏夹、类型和形态、来源、管理各是一节
    let filters = model.filterItems
    #expect(Array(filters.prefix(4).map(\.title)) == ["收藏", "生活", "工作", "片段"])
    #expect(filters.last?.title == "管理收藏夹…" && filters.last?.section == 3)
    #expect(filters.first { $0.title == "文本" }?.section == 1)
  }

  /// 粘贴动词（⌘K 首项、底栏同一个名字，体检 B3）；写进剪贴板的内容：多条文本按复制先后合成一段、片段展开占位符（B1），
  /// 全是文件一次写进去（同一个文件只写一次），其余逐条、文本后面补换行；动作菜单里备注对所有条目开放（A3）、片段能移出（C1）
  @Test func pastePayloads() throws {
    let (store, _) = try makeStore()
    var snippet = text("{date} 日报", ago: 5)
    snippet.isSnippet = true
    store.record(snippet)
    store.record(text("第二段", ago: 4))
    var fileA = ClipItem(kind: .file, copiedAt: Date.now.addingTimeInterval(-3))
    fileA.filePaths = ["/tmp/a.txt", "/tmp/b.txt"]
    var fileB = ClipItem(kind: .file, copiedAt: Date.now.addingTimeInterval(-2))
    fileB.filePaths = ["/tmp/b.txt", "/tmp/c.txt"]
    store.record(fileA)
    store.record(fileB)
    let model = ClipboardPanelModel(store: store)
    let (texts, files) = (store.items.filter { $0.kind == .text }, [fileB, fileA])
    typealias Mode = ClipboardPanelModel.PasteMode
    #expect(Mode([texts[0]]).verb == "粘贴" && Mode(texts).verb == "合并粘贴")
    #expect(Mode(files).verb == "一起粘贴" && Mode([texts[0], fileA]).verb == "依次粘贴")
    let today = Date.now.formatted(
      Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
    let merged = model.payload(for: texts, plainText: false)
    #expect(merged.writes.count == 1)
    #expect(merged.writes[0][0].string(forType: .string) == "\(today) 日报\n第二段")
    guard case .new(let entry) = merged.entry else {
      Issue.record("合并粘贴要记新历史")
      return
    }
    #expect(entry.text == "\(today) 日报\n第二段")
    let together = model.payload(for: [fileA, fileB], plainText: false)
    #expect(together.writes.count == 1)
    #expect(
      together.writes[0].compactMap { $0.string(forType: .fileURL) }
        == ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"].map { URL(filePath: $0).absoluteString })
    let sequential = model.payload(for: [texts[1], fileA], plainText: false)
    #expect(sequential.writes.count == 2 && sequential.entry == nil)
    #expect(sequential.writes[0][0].string(forType: .string) == "\(today) 日报\n")
    // 动作菜单：普通条目也有「备注…」；片段有「移出片段」
    model.select(texts[0])
    #expect(model.actions.contains { $0.title == "备注…" })
    #expect(!model.actions.contains { $0.title == "移出片段" })
    model.select(texts[1])
    #expect(model.actions.contains { $0.title == "移出片段" })
    // {clipboard:N} 跳过片段（A7）：刚粘过的片段排在最前，{clipboard:1} 取下一条复制来的文字，不是它自己的模板
    var reply = text("{clipboard:1} 已收到")
    reply.isSnippet = true
    store.record(reply)
    let replied = model.payload(for: [store.items[0]], plainText: false)
    #expect(replied.writes[0][0].string(forType: .string) == "第二段 已收到")
  }

  /// ⌘C 只写剪贴板，列表不动；收起面板（reset）时才把它挪到最前（体检 A8），剪贴板在这之后被换掉就不挪；
  /// 合成的新条目时间按收起那一刻、暂停记录时不记（D4）。含图片的多选只写第 1 条，橙色警告如实说
  @Test func copyBumpsWhenPanelHides() throws {
    let (store, _) = try makeStore()
    for (name, age) in [("旧的", 3.0), ("中间", 2), ("新的", 1)] { store.record(text(name, ago: age)) }
    let model = ClipboardPanelModel(store: store)
    var written: [[NSPasteboardItem]] = []
    var changeCount = 0
    model.writeClipboard = {
      written.append($0)
      changeCount += 1
    }
    model.clipboardChangeCount = { changeCount }
    model.select(try #require(store.items.last))
    model.copySelection()
    #expect(written.last?.first?.string(forType: .string) == "旧的")
    #expect(store.items.map(\.text) == ["新的", "中间", "旧的"])
    #expect(model.toast == .message("已复制"))
    model.reset()
    #expect(store.items.map(\.text) == ["旧的", "新的", "中间"])
    // ⌘C 之后剪贴板被别的内容换掉了（复制图中文字、色值块、固定着去别处复制）：收起时不挪
    model.select(try #require(store.items.last))
    model.copySelection()
    changeCount += 1
    model.reset()
    #expect(store.items.map(\.text) == ["旧的", "新的", "中间"])
    // 多条合成一段：收起时记成最新的一条；暂停记录时不记
    model.isRecordingPaused = true
    model.multiSelection = Set(store.items.prefix(2).map(\.id))
    model.copySelection()
    model.reset()
    #expect(store.items.count == 3)
    model.isRecordingPaused = false
    model.multiSelection = Set(store.items.prefix(2).map(\.id))
    model.copySelection()
    model.reset()
    #expect(store.items.map(\.text) == ["新的\n旧的", "旧的", "新的", "中间"])
    #expect(store.items[0].copiedAt >= store.items[1].copiedAt)
    // 文本 + 图片：剪贴板一次只能放一条，写按复制先后的第 1 条
    var image = ClipItem(kind: .image, copiedAt: Date.now.addingTimeInterval(1))
    image.image = .init(width: 1, height: 1, byteCount: 1, sha256: "x")
    try Data([0]).write(to: store.images.url(for: image.id))
    store.record(image)
    model.multiSelection = [image.id, store.items[1].id]
    model.copySelection()
    #expect(written.count == 5 && model.toast == .warning("只复制了第 1 条"))
    #expect(
      written.last?.count == 1 && written.last?.first?.string(forType: .string) == "新的\n旧的")
  }

  @Test func tokensAndKeys() throws {
    let (store, _) = try makeStore()
    var safari = text("s")
    safari.sourceBundleID = "com.apple.Safari"
    safari.sourceName = "Safari"
    safari.favorite = true
    store.record(safari)
    let model = ClipboardPanelModel(store: store)
    model.scope = .favorites
    model.sourceBundleID = "com.apple.Safari"
    #expect(model.tokens.map(\.title) == ["收藏", "Safari"])
    // ⌫（搜索为空）：第一下只待删，第二下删最后一个标签；Esc 取消待删
    #expect(model.handleCommand(#selector(NSResponder.deleteBackward(_:))))
    #expect(model.armsLastToken && model.sourceBundleID != nil)
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(!model.armsLastToken)
    _ = model.handleCommand(#selector(NSResponder.deleteBackward(_:)))
    _ = model.handleCommand(#selector(NSResponder.deleteBackward(_:)))
    #expect(model.sourceBundleID == nil && model.tokens.map(\.title) == ["收藏"])
    // 有搜索词时 ⌫ 交还输入框删字
    model.query = "x"
    #expect(!model.handleCommand(#selector(NSResponder.deleteBackward(_:))))
    model.query = ""
    // ⇧Tab 循环范围：收藏 → 片段 → 全部 → 收藏
    _ = model.handleCommand(#selector(NSResponder.insertBacktab(_:)))
    #expect(model.scope == .snippets)
    _ = model.handleCommand(#selector(NSResponder.insertBacktab(_:)))
    #expect(model.scope == .all && model.tokens.isEmpty)
    // Tab 开关筛选面板；开着时搜索框过滤条目，↩ 应用并关面板，再应用一次取消
    _ = model.handleCommand(#selector(NSResponder.insertTab(_:)))
    #expect(model.palette == .filters)
    model.actionQuery = "json"
    #expect(model.filteredActions.map(\.title) == ["JSON"])
    _ = model.handleCommand(#selector(NSResponder.insertNewline(_:)))
    #expect(model.palette == nil && model.form == .json && model.kind == .text)
    #expect(model.tokens.map(\.title) == ["JSON"])
    model.palette = .filters
    model.actionQuery = "来源"
    #expect(model.filteredActions.map(\.title) == ["Safari"])
    model.actionQuery = "json"
    #expect(model.filteredActions.first?.isChecked == true)
    model.runSelectedAction()
    #expect(model.form == nil && model.kind == nil)
    // Esc：先关面板，再清搜索词
    model.palette = .filters
    model.query = "abc"
    _ = model.handleCommand(#selector(NSResponder.cancelOperation(_:)))
    #expect(model.palette == nil && model.query == "abc")
    _ = model.handleCommand(#selector(NSResponder.cancelOperation(_:)))
    #expect(model.query.isEmpty)
    // ⌘K 开着、过滤词为空时 ← 关掉
    model.palette = .actions
    #expect(model.handleCommand(#selector(NSResponder.moveLeft(_:))))
    #expect(model.palette == nil)
    // reset 清掉标签、待删和面板
    model.scope = .favorites
    model.armsLastToken = true
    model.reset()
    #expect(model.tokens.isEmpty && !model.armsLastToken && model.palette == nil)
  }
}
