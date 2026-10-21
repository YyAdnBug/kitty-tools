// 四批评审（2026-10-18）修完后的锁定测试：照 SPEC §10 和 FIXES §4 的探针改写成修好后的期望。
// 屏外建 model / 窗口，不 makeKey、不扫用户目录、不碰真实废纸篓、不打开系统旧库（导入用小库）。
// 每条对应清单里的一项（测试名后的 F 编号）。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadReviewTests {
  private func ref(_ name: String) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.\(name)", path: "/Applications/\(name).app")
  }

  private func app(_ ref: LaunchpadAppRef, category: String? = nil) -> LaunchpadProjectApp {
    let name = ref.bundleID ?? ref.path
    return LaunchpadProjectApp(
      id: ref.id, ref: ref,
      item: LauncherItem(
        kind: .app, target: ref.path, title: name, subtitle: "应用程序",
        names: [LauncherMatch.fold(name)], initials: [LauncherMatch.initials(name)]),
      url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
      category: category)
  }

  private func model(
    _ layout: LaunchpadLayout, columns: Int = 3, rows: Int = 2, startPage: Int = 0
  ) -> LaunchpadModel {
    LaunchpadModel(
      layout: layout, catalog: layout.apps.map { app($0) }, icons: LaunchpadIcons(),
      columns: columns, rows: rows, screenSize: CGSize(width: 900, height: 600),
      startPage: startPage, dragTiming: .immediate)
  }

  private func grid(_ model: LaunchpadModel, page: Int) -> CGRect {
    let metrics = model.metrics
    let frame = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    model.gridFrames[page] = frame
    return frame
  }

  private func center(_ index: Int, in frame: CGRect, metrics: LaunchpadMetrics) -> CGPoint {
    let column = index % metrics.columns
    let row = index / metrics.columns
    return CGPoint(
      x: frame.minX + (CGFloat(column) + 0.5) * metrics.cellWidth,
      y: frame.minY + (CGFloat(row) + 0.5) * metrics.cellHeight)
  }

  private func waitForCombine(_ model: LaunchpadModel) async {
    for _ in 0..<40 where model.drag?.combineTileID == nil {
      try? await Task.sleep(for: .milliseconds(30))
    }
  }

  // MARK: F1 / F3 拖动

  /// 满的一页里把 a 拖到 e 那一格的左边沿松手：挪位置，不是建文件夹
  @Test func dropOnOccupiedCellEdgeReorders() {
    let refs = ["a", "b", "c", "d", "e", "f"].map(ref)
    let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
    let frame = grid(model, page: 0)
    model.beginDrag(
      tile: .app(refs[0]), appID: refs[0].id, folder: nil,
      at: center(0, in: frame, metrics: model.metrics))
    // e 那一格（index 4）的左边沿
    let metrics = model.metrics
    let edge = CGPoint(
      x: frame.minX + 1 * metrics.cellWidth + 12,
      y: frame.minY + 1.5 * metrics.cellHeight)
    model.updateDrag(location: edge, pageWidth: 900)
    model.endDrag()
    #expect(model.layout.tiles.allSatisfy { $0.folder == nil })
    #expect(model.layout.tiles.count == 6)
  }

  /// 停不到 0.4 秒就松手：挪位置
  @Test func quickStopInIconCenterStillReorders() {
    let a = ref("a")
    let b = ref("b")
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(b)]]))
    let frame = grid(model, page: 0)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 700, y: 100))
    model.updateDrag(location: center(0, in: frame, metrics: model.metrics), pageWidth: 900)
    model.endDrag()
    #expect(model.layout.tiles.allSatisfy { $0.folder == nil })
    #expect(model.layout.tiles.count == 2)
  }

  /// 第 2 页、第 3 行的格子：停在中心够久才建文件夹
  @Test func dwellCentersOnSecondPageThirdRow() async {
    let a = ref("a")
    let b = ref("b")
    let targets = (0..<9).map { ref("t\($0)") }
    let layout = LaunchpadLayout(pages: [
      [.app(a)], [.app(b)], targets.map { LaunchpadTile.app($0) },
    ])
    let model = model(layout, columns: 3, rows: 3)
    let frame = grid(model, page: 2)
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.go(to: 2)
    model.updateDrag(location: center(7, in: frame, metrics: model.metrics), pageWidth: 900)
    await waitForCombine(model)
    #expect(model.drag?.combineTileID == LaunchpadTile.app(targets[7]).id)
    model.endDrag()
    // 源页空了会被去掉，页号会往前挪；按文件夹认，不按页下标
    let folded = model.layout.tiles.compactMap(\.folder).first
    #expect(folded?.apps.map(\.id) == [targets[7].id, a.id])
  }

  /// 屏外真画 LaunchpadView：界面自己喂 gridFrames，拖到文件夹那一格的中心加得进去（F3）
  @Test func viewDrawsGridAndDropsIntoFolder() async {
    let a = ref("a")
    let b = ref("b")
    let c = ref("c")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder), .app(c)]]))
    let size = NSSize(width: 900, height: 600)
    let host = NSHostingView(
      rootView: LaunchpadView(model: model).frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(100)) }
    #expect(model.gridFrames[0] != nil)
    let frame = try! #require(model.gridFrames[0])
    model.beginDrag(tile: .app(c), appID: c.id, folder: nil, at: CGPoint(x: 800, y: 100))
    // 真界面量出来的是全宽的页容器：格子中心要按 cellRect 算（含两边的 side，G19）
    let cell = LaunchpadModel.cellRect(0, in: frame, metrics: model.metrics)
    model.updateDrag(location: CGPoint(x: cell.midX, y: cell.midY), pageWidth: 900)
    await waitForCombine(model)
    #expect(model.drag?.combineTileID == LaunchpadTile.folder(folder).id)
    model.endDrag()
    #expect(model.layout.tiles[0].folder?.apps.map(\.id) == [a.id, b.id, c.id])
    window.orderOut(nil)
  }

  // MARK: F2 落点

  @Test func cellIndexSubtractsSideAndUsesVisualCenter() {
    let model = model(LaunchpadLayout(pages: [[]]), columns: 3, rows: 3)
    let metrics = model.metrics
    let frame = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    // 第 3 行第 3 格视觉中心偏右 40%
    let point = CGPoint(
      x: frame.minX + 2 * metrics.cellWidth + metrics.cellWidth * 0.9,
      y: frame.minY + 2.5 * metrics.cellHeight)
    #expect(
      LaunchpadModel.cellIndex(at: point, in: frame, metrics: metrics) == 8)
  }

  /// [A, B, C] 把 B 挪到预览空位 2 = [A, C, B]
  @Test func movingUsesPostRemovalSlot() {
    let a = ref("a")
    let b = ref("b")
    let c = ref("c")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b), .app(c)]])
    let moved = layout.moving(LaunchpadTile.app(b).id, toPage: 0, slot: 2, capacity: 6)
    #expect(moved.tiles.compactMap { $0.app?.id } == [a.id, c.id, b.id])
  }

  // MARK: F4 长按

  @Test func longPressThenReleaseDoesNotOpen() async {
    let a = ref("a")
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(ref("b"))]]))
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 100, y: 100))
    for _ in 0..<100 where !model.jiggling {
      try? await Task.sleep(for: .milliseconds(30))
    }
    #expect(model.jiggling)
    model.endDrag()
    #expect(opened == nil)
  }

  @Test func clickInJiggleModeOpens() {
    let a = ref("a")
    let model = model(LaunchpadLayout(pages: [[.app(a)]]))
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    model.enterJiggle()
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.endDrag()
    #expect(opened == a.id)
  }

  // MARK: F5 搜索

  @Test func searchResultClickOpensEvenAfterMoving() {
    let refs = (0..<7).map { ref("word\($0)") }
    let layout = LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }])
    let model = model(layout)
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    model.query = "word"
    model.go(to: 1)
    let result = model.displayPages[1][0]
    model.beginDrag(tile: result, appID: result.app?.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.updateDrag(location: CGPoint(x: 150, y: 100), pageWidth: 900)
    model.endDrag()
    #expect(opened == result.app?.id)
    #expect(model.layout.tiles.count == 7)
  }

  // MARK: F6 触点布局

  @Test func fingerStrideMatchesFramework() {
    #expect(MemoryLayout<MTFinger>.stride == 96)
    #expect(MemoryLayout<MTFinger>.offset(of: \.identifier) == 16)
    #expect(MemoryLayout<MTFinger>.offset(of: \.state) == 20)
    #expect(MemoryLayout<MTFinger>.offset(of: \.normalizedX) == 32)
    #expect(MemoryLayout<MTFinger>.offset(of: \.normalizedY) == 36)
  }

  @Test func fingerArrayIsReadWithNinetySixByteStride() {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4 * 96, alignment: 8)
    defer { buffer.deallocate() }
    for index in 0..<4 {
      let finger = buffer.advanced(by: index * 96).assumingMemoryBound(to: MTFinger.self)
      finger.pointee.identifier = Int32(index)
      finger.pointee.state = 4
      finger.pointee.normalizedX = Float(index) * 0.1
      finger.pointee.normalizedY = Float(index) * 0.2
    }
    let touches = TouchpadWatcher.touches(from: buffer, count: 4)
    #expect(touches.map(\.id) == [0, 1, 2, 3])
    let xs = touches.map(\.x)
    #expect(abs(xs[1] - 0.1) < 0.0001 && abs(xs[2] - 0.2) < 0.0001 && abs(xs[3] - 0.3) < 0.0001)
  }

  // MARK: F7 页边界

  @Test func openingAndMergingKeepPageBoundaries() {
    let a = ref("a")
    let b = ref("b")
    let c = ref("c")
    let layout = LaunchpadLayout(pages: [[.app(a)], [.app(b), .app(c)]])
    #expect(layout.tidied(capacity: 35) == layout)
    let merged = layout.merged(apps: [a, b, c], capacity: 35)
    #expect(merged == layout)
    // 从第 1 页挪走一个：第 1 页空了就去掉，只让第 2 页多一格，不往前补
    let moved = layout.moving(LaunchpadTile.app(a).id, toPage: 1, slot: 1, capacity: 35)
    #expect(moved.pages.count == 1)
    #expect(moved.pages[0].compactMap { $0.app?.id } == [b.id, a.id, c.id])
  }

  /// 一页只有一个图标，拖起再落回本页 = 没挪（F7：不能因为源页被删掉就顺到下一页）
  @Test func movingTheOnlyTileOnAPageBackKeepsIt() {
    let layout = LaunchpadLayout(pages: [[.app(ref("a"))], [.app(ref("b"))]])
    // 用真的格子 id（G18：原来写的是 "b"，locate 找不到、原样返回，怎么都过）
    let moved = layout.moving(LaunchpadTile.app(ref("b")).id, toPage: 1, slot: 0, capacity: 35)
    #expect(moved == layout)
    // 对照：挪到第 1 页确实会变（证明上面那条不是因为找不到）
    #expect(
      layout.moving(LaunchpadTile.app(ref("b")).id, toPage: 0, slot: 1, capacity: 35) != layout)
  }

  // MARK: F8 WAL

  @Test func importReadsUncheckpointedWAL() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "launchpad-wal-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "db").path
    let writer = try Database(path: path)
    try writer.execute("PRAGMA wal_autocheckpoint=0")
    try writer.execute(
      "CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid TEXT, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER)"
    )
    try writer.execute(
      "CREATE TABLE apps (item_id INTEGER, title TEXT, bundleid TEXT, storeid TEXT, category_id INTEGER, moddate REAL, bookmark BLOB)"
    )
    try writer.execute("CREATE TABLE groups (item_id INTEGER, category_id INTEGER, title TEXT)")
    try writer.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (1, 1, 0, 0), (2, 3, 1, 1), (3, 4, 2, 1)"
    )
    try writer.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (3, 'Alpha', 'com.example.a')")
    let local = [LaunchpadImport.LocalApp(ref: ref("a"), name: "Alpha")]
    let result = withExtendedLifetime(writer) {
      LaunchpadImport.readLayout(at: path, local: local, capacity: 35)
    }
    #expect(result?.layout.apps.map(\.id) == ["com.example.a"])
  }

  @Test func importReadsWALDelete() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "launchpad-wal-delete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "db").path
    let writer = try Database(path: path)
    try writer.execute("PRAGMA wal_autocheckpoint=0")
    try writer.execute(
      "CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid TEXT, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER)"
    )
    try writer.execute(
      "CREATE TABLE apps (item_id INTEGER, title TEXT, bundleid TEXT, storeid TEXT, category_id INTEGER, moddate REAL, bookmark BLOB)"
    )
    try writer.execute("CREATE TABLE groups (item_id INTEGER, category_id INTEGER, title TEXT)")
    try writer.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (1, 1, 0, 0), (2, 3, 1, 1), (3, 4, 2, 1), (4, 4, 2, 2)"
    )
    try writer.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (3, 'Alpha', 'com.example.a'), (4, 'Beta', 'com.example.b')"
    )
    // 先把 Beta 合并进主文件，再只在 WAL 里删掉它：这样才是在测「WAL 里的删除生效」，不只是「读了 WAL」（G21）
    try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    try writer.execute("DELETE FROM apps WHERE item_id = 4")
    try writer.execute("DELETE FROM items WHERE rowid = 4")
    let local = [
      LaunchpadImport.LocalApp(ref: ref("a"), name: "Alpha"),
      LaunchpadImport.LocalApp(ref: ref("b"), name: "Beta"),
    ]
    let result = withExtendedLifetime(writer) {
      LaunchpadImport.readLayout(at: path, local: local, capacity: 35)
    }
    #expect(result?.layout.apps.map(\.id) == ["com.example.a"])
  }

  // MARK: F10 文件夹

  @Test func oversizedFolderPageIsRepaginated() {
    let refs = (0..<40).map { ref("f\($0)") }
    let folder = LaunchpadFolder(name: "X", pages: [refs])
    let clean = LaunchpadLayout.sanitized([[.folder(folder)]])
    #expect(clean.first?.first?.folder?.pages.map(\.count) == [35, 5])
  }

  // MARK: F12 / F13 捏合开关

  /// 不看系统手势开没开（2026-10-19：系统设置改了收不到，Kitty 启动时开着、之后关掉就一直接不上；开始捏的那一刻再读）
  @Test func pinchShouldRunCombinations() {
    #expect(Launchpad.pinchShouldRun(enabled: true, usePinch: true, available: true))
    #expect(!Launchpad.pinchShouldRun(enabled: false, usePinch: true, available: true))
    #expect(!Launchpad.pinchShouldRun(enabled: true, usePinch: false, available: true))
    #expect(!Launchpad.pinchShouldRun(enabled: true, usePinch: true, available: false))
  }

  // MARK: F14 先面板后岛

  @Test func panelComesUpBeforeNotice() {
    var order: [String] = []
    LaunchpadOpenSequence.run(
      present: { order.append("panel") }, notice: { order.append("notice") })
    #expect(order == ["panel", "notice"])
    order = []
    LaunchpadOpenSequence.run(present: { order.append("panel") }, notice: nil)
    #expect(order == ["panel"])
  }

  // MARK: F16 深色

  @Test func panelIsDarkAndDoesNotBecomeKey() {
    let model = model(LaunchpadLayout(pages: [[.app(ref("a"))]]))
    let panel = LaunchpadPanel(
      frame: NSRect(x: -20000, y: -20000, width: 900, height: 600), model: model)
    #expect(panel.appearance?.name == .darkAqua)
    #expect(!panel.isKeyWindow)
    let weakPanel = panel
    panel.orderOut(nil)
    panel.contentView = nil
    #expect(weakPanel != nil)
    _ = panel
  }

  /// 面板的按键分派（F30）：⌘← / ⌘→ / ⌘W 和方向键 / ↩ / Esc 都到 model 的回调，不 makeKey
  @Test func panelDispatchesKeysWithoutBecomingKey() throws {
    let model = model(LaunchpadLayout(pages: [[.app(ref("a")), .app(ref("b"))]]))
    let panel = LaunchpadPanel(
      frame: NSRect(x: -20000, y: -20000, width: 900, height: 600), model: model)
    var seen: [String] = []
    panel.onFirstPage = { seen.append("first") }
    panel.onLastPage = { seen.append("last") }
    panel.onCloseRequest = { seen.append("close") }
    panel.onNavigate = { seen.append("nav-\($0)") }
    panel.onReturn = { seen.append("return") }
    panel.onCancel = { seen.append("cancel") }
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ text: String = "") -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
        keyCode: code)!
    }
    #expect(panel.performKeyEquivalent(with: key(123, .command)))
    #expect(panel.performKeyEquivalent(with: key(124, .command)))
    #expect(panel.performKeyEquivalent(with: key(13, .command, "w")))
    panel.keyDown(with: key(125))
    panel.keyDown(with: key(36, [], "\r"))
    panel.keyDown(with: key(53))
    #expect(seen == ["first", "last", "close", "nav-down", "return", "cancel"])
    #expect(!panel.isKeyWindow)
    panel.orderOut(nil)
    panel.contentView = nil
  }

  // MARK: F17 翻页

  @Test func pagerFlipsByDistanceAndFlick() {
    var pager = LaunchpadPager()
    // 慢慢拖过翻页门槛（2026-10-18 起是页宽的 20%，900 的 20% 是 180；G13：别靠第一帧的速度虚高）
    _ = pager.feed(delta: -180, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = pager.feed(delta: -180, time: 2, pageWidth: 900, canBack: true, canForward: true)
    #expect(pager.finish(canBack: true, canForward: true, pageWidth: 900) == 1)
    // 快甩一小段（几帧、每帧 10 ms；原来这里只喂两帧、靠第一帧的速度虚高才算快甩，那正是 G13 的错）
    var flick = LaunchpadPager()
    _ = flick.feed(delta: -30, time: 10, pageWidth: 900, canBack: true, canForward: true)
    _ = flick.feed(delta: -30, time: 10.01, pageWidth: 900, canBack: true, canForward: true)
    _ = flick.feed(delta: -30, time: 10.02, pageWidth: 900, canBack: true, canForward: true)
    #expect(flick.finish(canBack: true, canForward: true, pageWidth: 900, time: 10.025) == 1)
    // 拖回来、到头不翻
    var back = LaunchpadPager()
    _ = back.feed(delta: -100, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = back.feed(delta: 100, time: 1.4, pageWidth: 900, canBack: true, canForward: true)
    #expect(back.finish(canBack: true, canForward: true, pageWidth: 900) == 0)
    var first = LaunchpadPager()
    _ = first.feed(delta: 300, time: 1, pageWidth: 900, canBack: false, canForward: true)
    #expect(first.finish(canBack: false, canForward: true, pageWidth: 900) == 0)
  }

  // MARK: F18 跨页空位

  @Test func previewShowsGapOnTargetPageAcrossPages() {
    let a = ref("a")
    let b = ref("b")
    let c = ref("c")
    let model = model(LaunchpadLayout(pages: [[.app(a)], [.app(b), .app(c)]]))
    let frame = grid(model, page: 1)
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.go(to: 1)
    // 停在 c 那一格的左边沿 = 插到 c 前面（停在 c 的中心是合成候选、空位不动，G3）
    let edge = CGPoint(
      x: frame.minX + model.metrics.cellWidth + 6, y: frame.minY + model.metrics.cellHeight / 2)
    model.updateDrag(location: edge, pageWidth: 900)
    let slots = model.previewTiles(page: 1)
    #expect(slots.count == 3)
    #expect(slots[1] == nil)
    #expect(model.gapIndex(page: 1) == 1)
  }

  // MARK: F19 Esc

  @Test func escapeCancelsDragUntilRelease() {
    let a = ref("a")
    let b = ref("b")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b)]])
    let model = model(layout)
    let frame = grid(model, page: 0)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 700, y: 100))
    model.updateDrag(location: center(0, in: frame, metrics: model.metrics), pageWidth: 900)
    model.cancel()
    model.updateDrag(location: center(1, in: frame, metrics: model.metrics), pageWidth: 900)
    model.endDrag()
    #expect(model.layout == layout)
  }

  // MARK: F20 / F23 面板簿记

  @Test func windowBookClosesEveryPanel() {
    let book = LaunchpadWindowBook()
    let first = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let second = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    book.adopt(first)
    #expect(book.beginClose() === first)
    book.adopt(second)
    #expect(book.beginClose() === second)
    #expect(book.panel == nil)
    #expect(!book.isOpen)
    first.orderOut(nil)
    second.orderOut(nil)
  }

  @Test func resignKeyDoesNotCloseForOwnChild() {
    let own = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let child = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    own.addChildWindow(child, ordered: .above)
    #expect(!LaunchpadPanelShouldClose.onResign(key: child, own: own))
    #expect(!LaunchpadPanelShouldClose.onResign(key: own, own: own))
    let other = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    #expect(LaunchpadPanelShouldClose.onResign(key: other, own: own))
    own.removeChildWindow(child)
    child.orderOut(nil)
    other.orderOut(nil)
  }

  // MARK: F24 页恢复

  @Test func reopeningStartsOnLastPage() {
    let refs = (0..<9).map { ref("p\($0)") }
    let layout = LaunchpadLayout(pages: [
      refs[0..<3].map { LaunchpadTile.app($0) },
      refs[3..<6].map { LaunchpadTile.app($0) },
      refs[6..<9].map { LaunchpadTile.app($0) },
    ])
    let board = model(layout, startPage: 2)
    #expect(board.page == 2)
    board.go(to: 1)
    board.query = "p"
    board.query = ""
    #expect(board.page == 1)
  }

  // MARK: F25 识别器

  @Test func pinchRecognizerResetsOnEmptyFrameAndIgnoresHover() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    func frame(_ time: Double, _ radius: Double) -> TouchFrame {
      TouchFrame(
        time: time,
        touches: (0..<4).map { index in
          let angle = Double(index) * .pi / 2
          return TouchPoint(
            id: Int32(index), x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius,
            state: 4)
        })
    }
    #expect(recognizer.feed(frame(0, 0.2)) == nil)
    #expect(recognizer.feed(frame(0.1, 0.1)) == .began(.pinch))
    // 空帧 = 全抬起来了：松手（开始那一帧就捏过了满格，之后没再动，速度 0）
    #expect(
      recognizer.feed(TouchFrame(time: 0.2, touches: []))
        == .ended(.pinch, progress: 1, velocity: 0))
    #expect(recognizer.feed(frame(0.3, 0.2)) == nil)
    #expect(recognizer.feed(frame(0.4, 0.1)) == .began(.pinch))
    // 悬停（state 1）不算在面上
    var hover = PinchRecognizer()
    let hovering = TouchFrame(
      time: 0, touches: (0..<4).map { TouchPoint(id: Int32($0), x: 0.2, y: 0.2, state: 1) })
    #expect(hover.feed(hovering) == nil)
  }

  // MARK: F26 / F43 目录

  @Test func duplicateBundleIDsStayTwoEntries() {
    let one = LaunchpadProjectApp(
      id: "com.example.xcode",
      ref: LaunchpadAppRef(bundleID: "com.example.xcode", path: "/Applications/Xcode.app"),
      item: LauncherItem(
        kind: .app, target: "/Applications/Xcode.app", title: "Xcode", subtitle: "应用程序"),
      url: URL(filePath: "/Applications/Xcode.app"), isSystem: false, inUtilities: false,
      isAppStore: false, category: nil)
    let two = LaunchpadProjectApp(
      id: "com.example.xcode",
      ref: LaunchpadAppRef(bundleID: "com.example.xcode", path: "/Applications/Xcode-beta.app"),
      item: LauncherItem(
        kind: .app, target: "/Applications/Xcode-beta.app", title: "Xcode beta", subtitle: "应用程序"),
      url: URL(filePath: "/Applications/Xcode-beta.app"), isSystem: false, inUtilities: false,
      isAppStore: false, category: nil)
    let clean = LaunchpadCatalog.disambiguated([one, two])
    #expect(clean.count == 2)
    #expect(clean[0].id == "com.example.xcode")
    #expect(clean[1].id == "/Applications/Xcode-beta.app")
    #expect(clean[1].ref.bundleID == nil)
  }

  @Test func safariSymlinkCountsAsSystemAndGameSubcategories() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "launchpad-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appending(path: "Finder.app")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(filePath: "/System/Library/CoreServices/Finder.app"))
    let project = LaunchpadCatalog.app(
      LauncherItem(kind: .app, target: link.path, title: "Finder", subtitle: "应用程序"))
    #expect(project.isSystem)
    #expect(LaunchpadCatalog.categoryName("public.app-category.action-games") == "游戏")
    #expect(LaunchpadCatalog.categoryName("public.app-category.strategy-games") == "游戏")
  }

  // MARK: F27 读不出来的布局

  @Test func unreadableLayoutIsKeptAndNotRewritten() throws {
    let suite = "launchpad.review.unreadable.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let broken = "{\"format\":99,\"pages\":[]}"
    defaults.set(broken, forKey: Prefs.launchpadLayout)
    let stored = LaunchpadLayout.stored(in: defaults, domainName: suite)
    #expect(stored == .unreadable(broken))
    let plan = LaunchpadLayout.openingPlan(
      stored: stored, apps: [], defaults: [], capacity: 35)
    #expect(!plan.shouldSave)
    #expect(plan.layout.tiles.isEmpty)
    #expect(defaults.string(forKey: Prefs.launchpadLayout) == broken)
    // 一格坏了只丢那一格
    let oneBad =
      "{\"format\":1,\"pages\":[[{\"kind\":\"app\",\"app\":{\"path\":\"/Applications/A.app\"}},{\"kind\":\"nope\"}]]}"
    defaults.set(oneBad, forKey: Prefs.launchpadLayout)
    guard case .loaded(let layout) = LaunchpadLayout.stored(in: defaults, domainName: suite) else {
      Issue.record("应当读出一格")
      return
    }
    #expect(layout.apps.count == 1)
  }

  // MARK: F32 文件夹名字

  @Test func folderNameUsesTargetCategory() async {
    let a = ref("a")
    let b = ref("b")
    let model = LaunchpadModel(
      layout: LaunchpadLayout(pages: [[.app(a), .app(b)]]),
      catalog: [app(a, category: nil), app(b, category: "效率")], icons: LaunchpadIcons(),
      columns: 3, rows: 2, screenSize: CGSize(width: 900, height: 600), dragTiming: .immediate)
    // 用和 Launchpad.open() 接的同一个取名函数（G12：原来这里注入了自己写的闭包，真代码没改也绿）
    model.folderName = { first, second in
      LaunchpadCatalog.folderName(first: first, second: second)
    }
    let frame = grid(model, page: 0)
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 700, y: 100))
    model.updateDrag(location: center(1, in: frame, metrics: model.metrics), pageWidth: 900)
    await waitForCombine(model)
    model.endDrag()
    #expect(model.layout.tiles.first?.folder?.name == "效率")
  }

  // MARK: F34 文件夹面板

  /// 面板高度跟着内容行数走；2026-10-18 起照 macOS 15 在屏幕中间展开（不再从文件夹那一格长出来，位置归界面）
  @Test func folderRowsFollowContent() {
    let a = ref("a")
    let b = ref("b")
    let refs = (0..<3).map { ref("g\($0)") }
    let folder = LaunchpadFolder(name: "X", pages: [refs])
    let model = model(LaunchpadLayout(pages: [[.app(a), .folder(folder)], [.app(b)]]))
    model.openFolder(folder.id)
    #expect(model.folderRows == 1)
  }

  // MARK: F37 键盘

  @Test func firstArrowSelectsFirstAndLastRowClamps() {
    let refs = (0..<6).map { ref("k\($0)") }
    let layout = LaunchpadLayout(pages: [
      [.app(refs[0]), .app(refs[1])], refs[2..<6].map { LaunchpadTile.app($0) },
    ])
    let model = model(layout)
    model.navigate(.down)
    #expect(model.selected == 0)
    model.go(to: 1)
    model.selected = 1
    model.navigate(.down)
    // 最后一行不满：夹到这一页最后一个（不越过 count）
    #expect(model.selected == 3)
  }

  // MARK: F44 滚轮

  @Test func mouseWheelNotchTurnsOnePage() {
    let refs = (0..<7).map { ref("w\($0)") }
    let layout = LaunchpadLayout(pages: [
      Array(refs[0..<6].map { LaunchpadTile.app($0) }), [.app(refs[6])],
    ])
    let model = model(layout)
    model.scroll(
      deltaX: 0, deltaY: -1, precise: false, phase: [], momentum: [], time: 1, inverted: false)
    #expect(model.page == 1)
    model.scroll(
      deltaX: 0, deltaY: 1, precise: false, phase: [], momentum: [], time: 2, inverted: false)
    #expect(model.page == 0)
  }

  // MARK: F45 搜索时 ⌥

  @Test func optionDoesNotJiggleWhileSearching() {
    let model = model(LaunchpadLayout(pages: [[.app(ref("a"))]]))
    model.query = "a"
    model.optionChanged(true)
    #expect(!model.jiggling)
  }
  // MARK: F41 撤销

  @Test func undoLayoutSurvivesRestart() throws {
    let suite = "launchpad.review.undo.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let layout = LaunchpadLayout(pages: [[.app(ref("a")), .app(ref("b"))]])
    LaunchpadUndo.save(layout, to: defaults)
    #expect(LaunchpadUndo.load(from: defaults) == layout)
    LaunchpadUndo.save(nil, to: defaults)
    #expect(LaunchpadUndo.load(from: defaults) == nil)
  }

  // MARK: F15 触发角

  @Test func cornerArmsAgainOnlyAfterLeaving() {
    var arm = CornerArm()
    let first = arm.trigger()
    let second = arm.trigger()
    #expect(first)
    #expect(!second)
    #expect(!arm.armed)
    arm.mouseExited()
    let third = arm.trigger()
    #expect(third)
  }

  @Test func systemCornerReadsDockDomain() {
    let dock: [String: Any] = ["wvous-tl-corner": 4, "wvous-br-corner": 0]
    #expect(LaunchpadCorner.systemCornerIsOn(.topLeft, dock: dock))
    #expect(!LaunchpadCorner.systemCornerIsOn(.topRight, dock: dock))
    #expect(!LaunchpadCorner.systemCornerIsOn(.bottomRight, dock: dock))
    #expect(!LaunchpadCorner.systemCornerIsOn(.off, dock: dock))
  }

  // MARK: F22 删 App

  @Test func recycleReportsResultAndCanDeleteOnlyAppStore() async {
    let store = LaunchpadProjectApp(
      id: "com.example.store", ref: ref("store"),
      item: LauncherItem(
        kind: .app, target: "/Applications/store.app", title: "Store", subtitle: "应用程序"),
      url: URL(filePath: "/Applications/store.app"), isSystem: false, inUtilities: false,
      isAppStore: true, category: nil)
    let system = LaunchpadProjectApp(
      id: "com.example.system", ref: ref("system"),
      item: LauncherItem(
        kind: .app, target: "/System/Applications/system.app", title: "System", subtitle: "系统"),
      url: URL(filePath: "/System/Applications/system.app"), isSystem: true, inUtilities: false,
      isAppStore: false, category: nil)
    #expect(LaunchpadCatalog.canDelete(store))
    #expect(!LaunchpadCatalog.canDelete(system))
    var result: Bool?
    LaunchpadRecycle.moveToTrash(
      store,
      using: { _, done in done(nil) },
      completion: { result = $0 })
    #expect(result == true)
    result = nil
    LaunchpadRecycle.moveToTrash(
      store,
      using: { _, done in done(CocoaError(.fileWriteNoPermission)) },
      completion: { result = $0 })
    #expect(result == false)
  }

}
