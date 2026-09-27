// ClipboardStore / ImageStore 单测：去重置顶、各项上限只动普通历史、清空、落库往返、图片编码；
// 剪贴板面板（Lens Bar）的纯逻辑：高度与透镜预留、列表前缀和、筛选标签与 Tab / ⇧Tab / ⌫ / Esc。
// 用内存库 + 临时目录，不碰真实数据。

import AppKit
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
    grouped.groupID = UUID()
    // record 末尾按偏好（Limits.current，读宿主的 UserDefaults，别的测试可能 registerDefaults）先裁一次：
    // 普通条目都记成「此刻或以后」，再把 now 拨后 10 天造出超期，偏好怎么设（最少 1 天 / 50 条）都裁不到
    let later = Date.now.addingTimeInterval(10 * 86_400)
    for item in [
      favorite, snippet, grouped, text("old"), text("x", ago: -9 * 86_400),
      text("y", ago: -9 * 86_400),
    ] {
      store.record(item)
    }
    // 删了几条要报给设置页的刘海提示：old（超天数）+ x（超条数）
    #expect(store.enforceLimits(.init(maxCount: 1, maxAge: 7 * 86_400), now: later) == 2)
    #expect(Set(store.items.compactMap(\.text)) == ["fav", "snippet", "grouped", "y"])
    #expect(store.enforceLimits(.init(maxCount: 1, maxAge: 7 * 86_400), now: later) == 0)
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
    #expect(store.clearOrdinary() == 1)
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

  @Test func favoriteToggleClearsNoteOfOrdinaryItemsOnly() throws {
    let (store, _) = try makeStore()
    var snippet = text("s")
    snippet.isSnippet = true
    store.record(snippet)
    store.record(text("h"))
    let ids = Set(store.items.map(\.id))
    store.toggleFavorite(ids)
    #expect(store.items.allSatisfy { $0.favorite })
    store.update(ids) { $0.note = "备注" }
    store.toggleFavorite(ids)
    #expect(store.items.first { $0.isSnippet }?.note == "备注")
    #expect(store.items.first { !$0.isSnippet }?.note == nil)
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

  @Test func undoDeletionRestoresPositionAndCommitPurges() throws {
    let (store, db) = try makeStore()
    for (name, age) in [("c", 3.0), ("b", 2), ("a", 1)] { store.record(text(name, ago: age)) }
    let b = try #require(store.items.first { $0.text == "b" })
    store.deleteWithUndo([b.id])
    #expect(store.items.map(\.text) == ["a", "c"])
    store.undoDeletion()
    #expect(store.items.map(\.text) == ["a", "b", "c"])
    store.deleteWithUndo([b.id])
    store.commitDeletion()
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items.map(\.text) == ["a", "c"])
  }

  @Test func snippetsMergeWithSameText() throws {
    let (store, _) = try makeStore()
    store.record(text("常用"))
    store.saveSnippet("常用")
    store.saveSnippet("新的")
    #expect(store.items.count == 2)
    #expect(store.items.allSatisfy { $0.isSnippet })
  }

  @Test func groups() throws {
    let (store, db) = try makeStore()
    let work = try #require(store.createGroup(named: "  工作  "))
    #expect(work.name == "工作")
    #expect(store.createGroup(named: "工作") == nil)  // 重名
    #expect(store.createGroup(named: "   ") == nil)
    #expect(store.createGroup(named: String(repeating: "长", count: 30))?.name.count == 24)
    store.record(text("x"))
    store.update([store.items[0].id]) { $0.groupID = work.id }
    #expect(store.renameGroup(work.id, to: "项目"))
    store.deleteGroup(work.id)
    let (reloaded, _) = try makeStore(db)
    #expect(reloaded.items[0].groupID == nil)
    #expect(reloaded.groups.map(\.name) == [String(repeating: "长", count: 24)])
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
    let layout = ListLayout(sections: sections, items: [a, b, c], lens: (b.id, 198))
    #expect(layout.offset(of: a.id) == 24)
    #expect(layout.offset(of: b.id) == 64)
    #expect(layout.offset(of: c.id) == 286)  // 24 + 40 + 198 + 24
    #expect(layout.sectionTops == [0, 262])
    #expect(layout.height(of: b.id) == 198 && layout.height(of: a.id) == 40)
    let flat = ListLayout(leading: 40, items: [a, b, c], lens: nil)
    #expect(flat.offset(of: c.id) == 120)
    #expect(flat.sectionTops.isEmpty)
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

  /// 选中行换了所在分组（有没有搜索词在分组 / 平铺间切换、昨天的条目再复制挪进「今天」）后照样按透镜高度展开、跟着选中走：
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
        sections: model.query.isEmpty ? ClipboardPanelView.daySections(items) : nil, items: items,
        lens: (item.id, row.height))
      let offset = try #require(layout.offset(of: item.id)) - (layout.offset(of: items[0].id) ?? 0)
      #expect(abs((drawn.first?.maxY ?? 0) - row.maxY - offset) < 0.5, step)
    }
    let down = { _ = model.handleCommand(#selector(NSResponder.moveDown(_:))) }
    try check("分组")
    model.query = "kitty"
    try check("分组 → 平铺")
    down()
    try check("平铺里 ↓")
    model.query = ""
    try check("平铺 → 分组")
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

  /// ⌘K 里的分组操作和右键菜单一样全：移到已有分组（已在里面的那组不列）、移出分组、放进新分组
  @Test func actionsMoveBetweenGroups() throws {
    let (store, _) = try makeStore()
    store.record(text("a", ago: 2))
    store.record(text("b", ago: 1))
    let work = try #require(store.createGroup(named: "工作"))
    let home = try #require(store.createGroup(named: "生活"))
    let model = ClipboardPanelModel(store: store)
    let groupActions = { model.actions.filter { $0.detail == "分组" }.map(\.title) }
    #expect(groupActions() == ["移到「工作」", "移到「生活」", "放进新分组…"])
    model.actions.first { $0.title == "移到「工作」" }?.run()
    #expect(store.items[0].groupID == work.id)
    #expect(groupActions() == ["移到「生活」", "移出分组", "放进新分组…"])
    // 多选：都在「工作」里才不列它；有一条在分组里就给「移出分组」
    model.multiSelection = Set(store.items.map(\.id))
    #expect(groupActions() == ["移到「工作」", "移到「生活」", "移出分组", "放进新分组…"])
    model.actions.first { $0.title == "移到「生活」" }?.run()
    #expect(store.items.allSatisfy { $0.groupID == home.id })
    model.actions.first { $0.title == "移出分组" }?.run()
    #expect(store.items.allSatisfy { $0.groupID == nil })
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
