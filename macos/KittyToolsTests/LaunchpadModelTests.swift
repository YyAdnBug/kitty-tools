// 启动台界面状态机的单测（第八族，2026-10-18，SPEC R2–R6）：键盘导航到页边翻页、搜索分页、Esc / 点空白的逐层退出、
// 抖动模式进出、拖动落点（让位、建文件夹、拖出文件夹）、拖动没挪动 = 点一下打开。屏外建 model，不建窗口、不 makeKey。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadModelTests {
  private func ref(_ name: String) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.\(name)", path: "/Applications/\(name).app")
  }

  private func projectApp(_ ref: LaunchpadAppRef) -> LaunchpadProjectApp {
    let name = ref.bundleID ?? URL(filePath: ref.path).deletingPathExtension().lastPathComponent
    return LaunchpadProjectApp(
      id: ref.id, ref: ref,
      item: LauncherItem(
        kind: .app, target: ref.path, title: name, subtitle: "应用程序",
        names: [LauncherMatch.fold(name)], initials: [LauncherMatch.initials(name)]),
      url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
      category: nil)
  }

  private func model(_ layout: LaunchpadLayout, columns: Int = 3, rows: Int = 2) -> LaunchpadModel {
    let catalog = layout.apps.map(projectApp)
    return LaunchpadModel(
      layout: layout, catalog: catalog, icons: LaunchpadIcons(), columns: columns, rows: rows,
      screenSize: CGSize(width: 900, height: 600), dragTiming: .immediate)
  }

  @Test func keyboardNavigationTurnsPagesAtEdges() {
    let refs = (0..<8).map { ref("a\($0)") }
    let layout = LaunchpadLayout(
      pages: [
        (0..<6).map { LaunchpadTile.app(refs[$0]) },
        [.app(refs[6]), .app(refs[7])],
      ])
    let board = model(layout)
    board.selected = 0
    // 第一格往左 / 往上：到头，不动
    board.navigate(.left)
    #expect(board.page == 0 && board.selected == 0)
    board.navigate(.up)
    #expect(board.page == 0 && board.selected == 0)
    // 同一行往右
    board.navigate(.right)
    #expect(board.selected == 1 && board.page == 0)
    // 第一行最后一个再往右：翻到第 2 页第一格
    board.selected = 2
    board.navigate(.right)
    #expect(board.page == 1 && board.selected == 0)
    // 第 2 页往上：翻回上一页同一列（第 0 格）
    board.navigate(.up)
    #expect(board.page == 0 && board.selected == 0)
    // 第二行第一个往上：同一列第一行
    board.selected = 3
    board.navigate(.up)
    #expect(board.page == 0 && board.selected == 0)
    // 第二行最后一个往下：翻到第 2 页，列夹到最后一个
    board.selected = 5
    board.navigate(.down)
    #expect(board.page == 1 && board.selected == 1)
    // 最后一页再往右 / 往下：到头
    board.navigate(.right)
    #expect(board.page == 1 && board.selected == 1)
    board.navigate(.down)
    #expect(board.page == 1 && board.selected == 1)
    // ⌘← / ⌘→
    board.firstPage()
    #expect(board.page == 0)
    board.lastPage()
    #expect(board.page == 1)
  }

  @Test func searchPaginatesAndClearsFirst() {
    let refs = (0..<6).map { ref("word\($0)") }
    let layout = LaunchpadLayout(pages: [refs.map(LaunchpadTile.app)])
    let board = model(layout)
    board.query = "word"
    #expect(board.isSearching)
    #expect(board.pageCount == 1)  // 6 个结果、一页 6 格（3 × 2）
    // 改成 4 格一页看分页（columns 2）
    let narrow = model(layout, columns: 2, rows: 2)
    narrow.query = "word"
    #expect(narrow.searchResults.count == 6)
    #expect(narrow.pageCount == 2)
    #expect(narrow.displayPages[0].count == 4)
    // Esc 先清搜索
    narrow.cancel()
    #expect(narrow.query.isEmpty && !narrow.isClosing)
    // 再按一次才收起
    var closed = false
    narrow.onClose = { closed = true }
    narrow.cancel()
    #expect(closed)
  }

  @Test func escapeAndBlankClickGoThroughTheLayers() {
    let a = ref("a")
    let b = ref("b")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b)]])
    let model = model(layout)
    var closed = false
    model.onClose = { closed = true }
    // 抖动 → Esc 退抖动
    model.enterJiggle()
    #expect(model.jiggling)
    model.cancel()
    #expect(!model.jiggling && !closed)
    // 文件夹 → Esc 收文件夹
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    model.replace(layout: LaunchpadLayout(pages: [[.folder(folder)]]))
    model.openFolder(folder.id)
    #expect(model.openFolderID == folder.id)
    model.cancel()
    #expect(model.openFolderID == nil && !closed)
    // 点空白：先退抖动，再关文件夹，最后收起
    model.enterJiggle()
    model.backgroundClicked()
    #expect(!model.jiggling && !closed)
    model.openFolder(folder.id)
    model.backgroundClicked()
    #expect(model.openFolderID == nil && !closed)
    model.backgroundClicked()
    #expect(closed)
  }

  @Test func optionEntersAndExitsJiggle() {
    let model = model(LaunchpadLayout(pages: [[.app(ref("a"))]]))
    model.optionChanged(true)
    #expect(model.jiggling)
    model.optionChanged(false)
    #expect(!model.jiggling)
    // 按住图标进的那种不受松开 ⌥ 影响
    model.enterJiggle()
    model.optionChanged(false)
    #expect(model.jiggling)
  }

  @Test func dragWithoutMovingOpensTheApp() {
    let a = ref("a")
    let model = model(LaunchpadLayout(pages: [[.app(a)]]))
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    model.beginDrag(tile: .app(a), appID: a.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.endDrag()
    #expect(opened == a.id)
    #expect(model.drag == nil)
  }

  @Test func draggingOntoAnotherAppEdgeReorders() {
    let a = ref("a")
    let b = ref("b")
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(b)]]))
    // 屏外真画出来的网格框：整页 900 × 600、3 × 2，网格两边各留 48（F2/F30）
    let metrics = model.metrics
    model.gridFrames[0] = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 700, y: 100))
    // 落在 a 那一格的左边沿：按让位的空位挪，不建文件夹（F1）
    model.updateDrag(location: CGPoint(x: metrics.side + 20, y: 100), pageWidth: 900)
    #expect(model.drag?.targetIndex == 0)
    model.endDrag()
    #expect(model.layout.tiles.count == 2)
    #expect(model.layout.tiles.compactMap { $0.app?.id } == [b.id, a.id])
  }

  /// 拖着的时候导入完成（第三轮体检 B4）：导入的排法压到松手再换（G26），换上后最后存盘的是它——
  /// 松手那一挪先把「拖之前那份 + 这一挪」存了下去，不再存一次的话下次打开导入的就没了
  @Test func layoutArrivingMidDragIsSavedAfterDrop() {
    let (a, b, c) = (ref("a"), ref("b"), ref("c"))
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(b)]]))
    var saved: [LaunchpadLayout] = []
    model.onLayoutChange = { saved.append($0) }
    let metrics = model.metrics
    model.gridFrames[0] = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 700, y: 100))
    model.updateDrag(location: CGPoint(x: metrics.side + 20, y: 100), pageWidth: 900)
    let imported = LaunchpadLayout(pages: [[.app(c), .app(a), .app(b)]])
    model.replaceWhenIdle(imported)
    #expect(model.layout != imported)  // 拖着不换
    model.endDrag()
    #expect(model.layout == imported)
    #expect(saved.last == imported)
    // 没在拖：当场换，不另存（总控送来之前已经存过）
    saved = []
    model.replaceWhenIdle(LaunchpadLayout(pages: [[.app(a)]]))
    #expect(model.layout.apps.map(\.id) == [a.id] && saved.isEmpty)
  }

  @Test func dwellingInIconCenterMakesAFolder() async {
    let a = ref("a")
    let b = ref("b")
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(b)]]))
    let metrics = model.metrics
    model.gridFrames[0] = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    // a 那一格的中心
    let center = CGPoint(
      x: metrics.side + metrics.cellWidth / 2, y: metrics.cellHeight / 2)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 700, y: 100))
    model.updateDrag(location: center, pageWidth: 900)
    // 0.4 秒的停留：按轮数等，不赌一次 sleep（SPEC §8）
    for _ in 0..<40 where model.drag?.combineTileID == nil {
      try? await Task.sleep(for: .milliseconds(30))
    }
    #expect(model.drag?.combineTileID == LaunchpadTile.app(a).id)
    model.endDrag()
    #expect(model.layout.tiles.count == 1)
    #expect(model.layout.tiles[0].folder?.apps.map(\.id) == [a.id, b.id])
  }

  @Test func droppingOnAFolderCenterAddsToIt() async {
    let a = ref("a")
    let b = ref("b")
    let c = ref("c")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder), .app(c)]]))
    let metrics = model.metrics
    model.gridFrames[0] = CGRect(
      x: metrics.side, y: 0, width: metrics.gridWidth, height: metrics.gridHeight)
    model.beginDrag(tile: .app(c), appID: c.id, folder: nil, at: CGPoint(x: 700, y: 100))
    let center = CGPoint(
      x: metrics.side + metrics.cellWidth / 2, y: metrics.cellHeight / 2)
    model.updateDrag(location: center, pageWidth: 900)
    for _ in 0..<40 where model.drag?.combineTileID == nil {
      try? await Task.sleep(for: .milliseconds(30))
    }
    #expect(model.drag?.combineTileID == LaunchpadTile.folder(folder).id)
    model.endDrag()
    #expect(model.layout.tiles.count == 1)
    #expect(model.layout.tiles[0].folder?.apps.map(\.id) == [a.id, b.id, c.id])
  }

  /// 拖出文件夹面板 14 pt：文件夹马上关上、手里的接着在主网格里拖（2026-10-18 交互对齐；原来要松手才回主网格）
  @Test func draggingOutOfAFolderReturnsToTheGrid() {
    let a = ref("a")
    let b = ref("b")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder)]]))
    model.openFolder(folder.id)
    let start = model.folderCellCenter(1)
    model.beginDrag(tile: .app(b), appID: b.id, folder: folder.id, at: start, origin: start)
    let panel = model.folderPanelRect
    model.updateDrag(location: CGPoint(x: panel.midX, y: panel.maxY + 30), pageWidth: 900)
    #expect(model.openFolderID == nil)
    #expect(model.drag?.isDragging == true)
    model.endDrag()
    // 文件夹只剩一个 → 解散，两个都回到主网格
    #expect(model.layout.tiles.compactMap { $0.app?.id } == [a.id, b.id])
  }

  @Test func previewShowsPlaceholderWhileDragging() {
    let a = ref("a")
    let b = ref("b")
    let model = model(LaunchpadLayout(pages: [[.app(a), .app(b)]]))
    model.gridFrames[0] = CGRect(x: 0, y: 0, width: 300, height: 200)
    model.beginDrag(tile: .app(b), appID: b.id, folder: nil, at: CGPoint(x: 150, y: 50))
    model.updateDrag(location: CGPoint(x: 700, y: 50), pageWidth: 900)
    let slots = model.previewTiles(page: 0)
    // b 被拿掉、落点（第 3 格）插了空位：a、nil
    #expect(slots.count == 2)
    #expect(slots[0]?.app?.id == a.id)
    #expect(slots[1] == nil)
    model.cancelDrag()
    #expect(model.drag == nil)
  }

  @Test func folderRenameAndPages() {
    let refs = (0..<40).map { ref("f\($0)") }
    let folder = LaunchpadFolder(
      name: "X", pages: LaunchpadLayout.paginateFolder(refs))
    let model = model(LaunchpadLayout(pages: [[.folder(folder)]]))
    model.openFolder(folder.id)
    // 一页 35 个（7 × 5），40 个分两页（F10）
    #expect(model.folderPageCount == 2)
    #expect(model.folderRows == 5)
    #expect(model.folderApps.count == 35)
    model.goToFolderPage(1)
    #expect(model.folderApps.count == 5)
    model.renameFolder(folder.id, to: "  开发  ")
    #expect(model.openFolder?.name == "开发")
    model.renameFolder(folder.id, to: "  ")
    #expect(model.openFolder?.name == "未命名")
  }
}
