// 启动台一块屏的状态（界面读它、面板按键调它）：布局、本机 App、当前页、键盘选中的格子、搜索词、翻页的跟手偏移、
// 拖动 / 抖动 / 文件夹展开这些编辑状态，以及「打开一个 App」「收起」这些往上抛的回调。
// 纯展示状态和几何的常量在这里；布局的增删挪在 LaunchpadLayout，窗口和持久化在 Launchpad（总控）。
// 键盘选中的口径照 macOS 15：一开始没有选中（鼠标指着不高亮），按方向键才出现；到页边接着翻页；搜索结果也按页排。

import AppKit
import Observation
import SwiftUI

/// 一块屏上的网格尺寸（按屏幕大小算，大屏大一点；SPEC R2）
nonisolated struct LaunchpadMetrics {
  let size: CGSize
  let columns: Int
  let rows: Int

  /// 左右留白（按屏宽的比例，最少 48）
  var side: CGFloat { max(48, size.width * 0.045) }
  var cellWidth: CGFloat { (size.width - side * 2) / CGFloat(max(columns, 1)) }
  /// 顶上搜索框、底下圆点之外留给网格的高度
  var cellHeight: CGFloat { (size.height - 190) / CGFloat(max(rows, 1)) }
  /// 图标边长：受格子宽高限制，最小 40、最大 104
  var icon: CGFloat { max(40, min(104, min(cellWidth * 0.56, cellHeight * 0.58))) }
  var labelWidth: CGFloat { icon + 36 }
  var gridWidth: CGFloat { cellWidth * CGFloat(columns) }
  var gridHeight: CGFloat { cellHeight * CGFloat(rows) }
  /// 搜索框上沿
  var searchTop: CGFloat { max(16, size.height * 0.03) }
}

nonisolated enum LaunchpadDirection {
  case left, right, up, down
}

/// 正在拖的那一格（R5）：起点、跟手的位移、算出来的落点、正悬在哪个文件夹上、要不要在边缘停着翻页。
nonisolated struct LaunchpadDrag: Equatable {
  var tileID: String
  /// 拖的是 App 时它的 id（拖出文件夹、删 App 要）
  var appID: String?
  /// 从打开的文件夹里拖出来时是那个文件夹
  var sourceFolder: UUID?
  /// 按下时指针在面板里的位置
  var start: CGPoint
  var translation: CGSize = .zero
  /// 挪过阈值才算拖（没到松手 = 点了一下）
  var active = false
  /// 当前页里的落点（nil = 拖到空白处，放这一页末尾）
  var targetIndex: Int?
  /// 正悬在哪个文件夹上（松手加进去）
  var hoverFolderID: UUID?
  /// 指针已经拖出打开的文件夹面板（松手 = 拖回主网格）
  var outsideFolder = false
  /// 停在左右边缘时准备翻到哪一页
  var turnPage: Int?

  var offset: CGSize { translation }
  var isDragging: Bool { active }
}

@Observable
@MainActor
final class LaunchpadModel {
  private(set) var layout: LaunchpadLayout
  let catalog: [LaunchpadProjectApp]
  let icons: LaunchpadIcons
  let columns: Int
  let rows: Int
  let screenSize: CGSize

  var query = "" {
    didSet {
      guard query != oldValue else { return }
      selected = nil
      page = 0
      pageOffset = 0
      scroll = 0
      searchCache = nil
    }
  }
  /// 当前页（0 起）
  private(set) var page = 0
  /// 键盘选中的格子在当前页里的下标；nil = 还没按方向键（鼠标指着不高亮）
  var selected: Int?
  /// 翻页跟手的横向偏移（点）
  private(set) var pageOffset: CGFloat = 0
  /// 正在收起（界面据此缩回去）
  private(set) var isClosing = false

  // MARK: 编辑（R4–R6）
  /// 开着的文件夹（nil = 没开）
  private(set) var openFolderID: UUID?
  /// 文件夹里看的是第几页（3 × 3 一页）
  private(set) var folderPage = 0
  /// 抖动模式（所有图标轻轻晃、App Store 装的出 ✕）
  private(set) var jiggling = false
  /// 抖动是按着 ⌥ 进的：松开 ⌥ 就退出（按住图标 1 秒进的那种要点空白 / Esc）
  private var jiggleByOption = false
  /// 正在拖
  private(set) var drag: LaunchpadDrag?
  /// 等确认删除的 App（确认框在界面里）
  var deleteCandidate: LaunchpadProjectApp?
  /// ⌥ 现在按着没有（面板的 flagsChanged 喂进来）
  var optionHeld = false
  /// 要重命名文件夹时的草稿（界面绑它）
  var folderNameDraft = ""

  /// 收起（点空白、Esc 到底、打开 App 之后）
  var onClose: () -> Void = {}
  /// 打开一个 App（总控负责 NSWorkspace 和收起）
  var onOpenApp: (LaunchpadProjectApp) -> Void = { _ in }
  /// 布局变了（每次挪动、建文件夹、删 App 都马上存；SPEC R5）
  var onLayoutChange: (LaunchpadLayout) -> Void = { _ in }
  /// 建文件夹时的名字（分类本地化名，SPEC R4）
  var folderName: (LaunchpadProjectApp, LaunchpadProjectApp) -> String = { first, _ in
    first.category ?? LaunchpadLayout.untitledFolder
  }
  /// 删 App（确认之后；总控做废纸篓和布局）
  var onDeleteApp: (LaunchpadProjectApp) -> Void = { _ in }

  @ObservationIgnored private var scroll: CGFloat = 0
  @ObservationIgnored private var scrollTask: Task<Void, Never>?
  @ObservationIgnored private var searchCache: (query: String, apps: [LaunchpadProjectApp])?
  @ObservationIgnored private var jiggleTask: Task<Void, Never>?
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  /// 界面每次布局后喂进来的网格 / 文件夹面板位置（命名坐标空间里），算落点和「拖出去了没有」
  @ObservationIgnored var gridFrames: [Int: CGRect] = [:]
  @ObservationIgnored var folderFrames: [UUID: CGRect] = [:]
  @ObservationIgnored var folderPanelFrame: CGRect = .zero

  init(
    layout: LaunchpadLayout, catalog: [LaunchpadProjectApp], icons: LaunchpadIcons,
    columns: Int, rows: Int, screenSize: CGSize
  ) {
    self.layout = layout
    self.catalog = catalog
    self.icons = icons
    self.columns = columns
    self.rows = rows
    self.screenSize = screenSize
  }

  var metrics: LaunchpadMetrics {
    LaunchpadMetrics(size: screenSize, columns: columns, rows: rows)
  }

  var capacity: Int { max(1, columns * rows) }

  // MARK: 搜索和分页

  var isSearching: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// 搜索到的 App（复用启动器的匹配：中文名、拼音全拼、首字母、英文名都算，SPEC R3）
  var searchResults: [LaunchpadProjectApp] {
    guard isSearching else { return [] }
    if let searchCache, searchCache.query == query { return searchCache.apps }
    let items = LauncherMatch.rank(catalog.map(\.item), query: query) { _ in (0, 0) }
    let byPath = Dictionary(catalog.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let apps = items.compactMap { byPath[$0.target] }
    searchCache = (query, apps)
    return apps
  }

  /// 界面上现在的格子页：搜索时结果是 App，不搜索时是布局的页
  var displayPages: [[LaunchpadTile]] {
    if isSearching {
      let tiles = searchResults.map { LaunchpadTile.app($0.ref) }
      let pages = LaunchpadLayout.paginate(tiles, capacity: capacity)
      return pages.isEmpty ? [[]] : pages
    }
    return layout.pages.isEmpty ? [[]] : layout.pages
  }

  var pageCount: Int { max(displayPages.count, 1) }

  var currentTiles: [LaunchpadTile] {
    let pages = displayPages
    return pages.indices.contains(page) ? pages[page] : []
  }

  /// 这一页给界面画的格子：拖动时把被拖的那一格拿掉、落点处插一个空位（别的图标让位）。
  /// 搜索时不许拖（结果的位置不是布局的位置）。
  func previewTiles(page pageIndex: Int) -> [LaunchpadTile?] {
    let pages = displayPages
    guard pages.indices.contains(pageIndex) else { return [] }
    var tiles: [LaunchpadTile?] = pages[pageIndex]
    guard let drag, drag.isDragging, !isSearching else { return tiles }
    if let from = tiles.firstIndex(where: { $0?.id == drag.tileID }) {
      tiles.remove(at: from)
      if let target = drag.targetIndex, drag.turnPage == nil || drag.turnPage == pageIndex {
        tiles.insert(nil, at: min(target, tiles.count))
      }
    }
    return tiles
  }

  /// 按 id 找本机 App（布局里存的只有身份）
  func app(_ ref: LaunchpadAppRef) -> LaunchpadProjectApp? {
    catalog.first { $0.id == ref.id }
  }

  func app(id: String) -> LaunchpadProjectApp? {
    catalog.first { $0.id == id }
  }

  func folder(_ id: UUID) -> LaunchpadFolder? {
    layout.tiles.compactMap(\.folder).first { $0.id == id }
  }

  var openFolder: LaunchpadFolder? { openFolderID.flatMap(folder) }

  func tile(at index: Int) -> LaunchpadTile? { currentTiles[safe: index] }

  /// 第 index 格的显示名（文件夹用文件夹名）
  func title(of tile: LaunchpadTile) -> String {
    switch tile {
    case .app(let ref):
      return app(ref)?.name ?? URL(filePath: ref.path).deletingPathExtension().lastPathComponent
    case .folder(let folder): return folder.name
    }
  }

  func symbol(of tile: LaunchpadTile) -> String {
    tile.folder == nil ? "app" : "folder"
  }

  // MARK: 键盘

  func go(to page: Int) {
    let target = min(max(page, 0), pageCount - 1)
    guard target != self.page else { return }
    withAnimation(Style.Motion.glide.animation()) {
      self.page = target
      pageOffset = 0
      selected = nil
    }
  }

  func firstPage() { go(to: 0) }
  func lastPage() { go(to: pageCount - 1) }

  /// 方向键：格子里挪；到页边接着翻页（↑↓ 还保持列）。文件夹开着时在文件夹的 3 × 3 里挪。
  func navigate(_ direction: LaunchpadDirection) {
    if openFolder != nil {
      navigateFolder(direction)
      return
    }
    guard !currentTiles.isEmpty else { return }
    let count = currentTiles.count
    let index = selected ?? 0
    let (page, tiles) = (self.page, displayPages)
    switch direction {
    case .left:
      if index % columns == 0 {
        guard page > 0 else {
          NSSound.beep()
          return
        }
        withAnimation(Style.Motion.snap.animation()) {
          self.page = page - 1
          selected = max((tiles[page - 1].count) - 1, 0)
        }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index - 1 }
      }
    case .right:
      if index % columns == columns - 1 || index == count - 1 {
        guard page < pageCount - 1 else {
          NSSound.beep()
          return
        }
        withAnimation(Style.Motion.snap.animation()) {
          self.page = page + 1
          selected = 0
        }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index + 1 }
      }
    case .up:
      if index / columns == 0 {
        guard page > 0 else {
          NSSound.beep()
          return
        }
        withAnimation(Style.Motion.snap.animation()) {
          self.page = page - 1
          selected = Self.columnClamped(index % columns, in: tiles[page - 1].count)
        }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index - columns }
      }
    case .down:
      if index / columns >= (count - 1) / columns {
        guard page < pageCount - 1 else {
          NSSound.beep()
          return
        }
        withAnimation(Style.Motion.snap.animation()) {
          self.page = page + 1
          selected = Self.columnClamped(index % columns, in: tiles[page + 1].count)
        }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index + columns }
      }
    }
  }

  /// 目标页同一列的第一个格子（目标页短、没有这一列时用最后一个）
  nonisolated static func columnClamped(_ column: Int, in count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(column, count - 1)
  }

  // MARK: 回车 / Esc / 点空白

  /// ↩：打开选中的；搜索时没有选中就打开第一个结果（SPEC R3）；文件夹里打开选中的那个
  func returnPressed() {
    if openFolder != nil {
      if let selected, let ref = folderApps[safe: selected] { open(app: ref) }
      return
    }
    if let selected, let tile = tile(at: selected) {
      open(tile)
      return
    }
    if isSearching, let first = currentTiles.first {
      open(first)
    }
  }

  /// Esc：拖动态先取消拖动，再退抖动、关文件夹、清搜索，最后收起（SPEC R1/R3/R5/R6）
  func cancel() {
    if drag != nil {
      cancelDrag()
      return
    }
    if jiggling {
      exitJiggle()
      return
    }
    if isSearching {
      query = ""
      return
    }
    if openFolderID != nil {
      closeFolder()
      return
    }
    requestClose()
  }

  /// 点空白处：文件夹开着时只收文件夹，抖动模式里退出抖动，否则收起启动台
  func backgroundClicked() {
    if drag != nil {
      cancelDrag()
    } else if openFolderID != nil {
      closeFolder()
    } else if jiggling {
      exitJiggle()
    } else {
      requestClose()
    }
  }

  /// 面板开始收（总控在淡出前调；界面据此缩回去）
  func beginClosing() { isClosing = true }

  func requestClose() {
    guard !isClosing else { return }
    isClosing = true
    onClose()
  }

  // MARK: 打开

  func open(_ tile: LaunchpadTile) {
    switch tile {
    case .app(let ref):
      open(app: ref)
    case .folder(let folder):
      openFolder(folder.id)
    }
  }

  func open(at index: Int) {
    guard let tile = tile(at: index) else { return }
    open(tile)
  }

  /// 打开一个 App（主网格和文件夹里共用）
  func open(app ref: LaunchpadAppRef) {
    guard let app = app(ref) else {
      NSSound.beep()
      return
    }
    onOpenApp(app)
  }

  // MARK: 文件夹（R4）

  var folderApps: [LaunchpadAppRef] {
    openFolder?.pages[safe: folderPage] ?? []
  }

  var folderPageCount: Int { max(openFolder?.pages.count ?? 1, 1) }

  func openFolder(_ id: UUID) {
    guard folder(id) != nil else { return }
    folderNameDraft = folder(id)?.name ?? ""
    withAnimation(Style.Motion.pop.animation()) {
      openFolderID = id
      folderPage = 0
      selected = nil
    }
  }

  func closeFolder() {
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = nil
      folderPage = 0
      selected = nil
      drag = nil
    }
    cancelTurn()
  }

  func goToFolderPage(_ page: Int) {
    folderPage = min(max(page, 0), folderPageCount - 1)
  }

  private func navigateFolder(_ direction: LaunchpadDirection) {
    let count = folderApps.count
    guard count > 0 else { return }
    let index = selected ?? 0
    let columns = 3
    switch direction {
    case .left:
      if index % columns == 0 {
        guard folderPage > 0 else {
          NSSound.beep()
          return
        }
        folderPage -= 1
        selected = max((openFolder?.pages[safe: folderPage]?.count ?? 1) - 1, 0)
      } else {
        selected = index - 1
      }
    case .right:
      if index % columns == columns - 1 || index == count - 1 {
        guard folderPage < folderPageCount - 1 else {
          NSSound.beep()
          return
        }
        folderPage += 1
        selected = 0
      } else {
        selected = index + 1
      }
    case .up:
      selected = index < columns ? index : index - columns
    case .down:
      selected = index + columns < count ? index + columns : index
    }
  }

  /// 文件夹改名（回车确认；空了回到「未命名」）
  func renameFolder(_ id: UUID, to name: String) {
    let updated = layout.renaming(id, to: name)
    commit(updated)
    folderNameDraft = folder(id)?.name ?? ""
  }

  // MARK: 抖动（R6）

  /// 按住 ⌥ 或按住图标约 1 秒进来；只有 App Store 装的出 ✕
  func enterJiggle(byOption: Bool = false) {
    guard !jiggling else { return }
    withAnimation(Style.Motion.pop.animation()) { jiggling = true }
    jiggleByOption = byOption
  }

  func exitJiggle() {
    guard jiggling else { return }
    withAnimation(Style.Motion.settle.animation()) { jiggling = false }
    jiggleByOption = false
    deleteCandidate = nil
  }

  /// 面板的 flagsChanged 喂进来：⌥ 按下进抖动、松开退出（按住图标进的那种不受影响）
  func optionChanged(_ held: Bool) {
    optionHeld = held
    if held {
      if drag == nil { enterJiggle(byOption: true) }
    } else if jiggleByOption {
      exitJiggle()
    }
  }

  func requestDelete(_ app: LaunchpadProjectApp) {
    guard LaunchpadCatalog.canDelete(app) else { return }
    deleteCandidate = app
  }

  func confirmDelete() {
    guard let app = deleteCandidate else { return }
    deleteCandidate = nil
    onDeleteApp(app)
  }

  // MARK: 拖动（R5）

  func beginDrag(tile: LaunchpadTile, appID: String?, folder: UUID?, at point: CGPoint) {
    drag = LaunchpadDrag(tileID: tile.id, appID: appID, sourceFolder: folder, start: point)
    jiggleTask?.cancel()
    // 按住不动 1 秒 = 进抖动模式
    jiggleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self, drag?.isDragging != true else { return }
      enterJiggle()
    }
  }

  /// 指针动了：算落点、悬着的文件夹、要不要翻页（view 传的是命名坐标空间里的位置）
  func updateDrag(location: CGPoint, pageWidth: CGFloat) {
    guard var drag else { return }
    let moved = hypot(location.x - drag.start.x, location.y - drag.start.y)
    if !drag.active, moved >= 4 {
      drag.active = true
      jiggleTask?.cancel()
    }
    drag.translation = CGSize(
      width: location.x - drag.start.x, height: location.y - drag.start.y)
    guard drag.active else {
      self.drag = drag
      return
    }
    if drag.sourceFolder != nil {
      // 从文件夹里拖：指针出了文件夹面板就算拖回主网格
      drag.outsideFolder = !folderPanelFrame.isEmpty && !folderPanelFrame.contains(location)
      self.drag = drag
      return
    }
    drag.hoverFolderID = hoveredFolder(at: location, excluding: drag.tileID)
    drag.targetIndex = targetIndex(at: location)
    drag.turnPage = nil
    self.drag = drag
    // 停在左右边缘：0.45 秒后翻页（同 macOS 15 的拖到边上翻）
    if location.x < 28 {
      scheduleTurn(to: page - 1)
    } else if location.x > pageWidth - 28 {
      scheduleTurn(to: page + 1)
    } else {
      cancelTurn()
    }
  }

  /// 松手：落在文件夹上就加进去 / 建文件夹，否则按落点挪；从文件夹拖出去就放回主网格
  func endDrag() {
    guard let drag else { return }
    jiggleTask?.cancel()
    defer { cancelTurn() }
    self.drag = nil
    guard drag.active else {
      // 没挪动 = 点了一下：打开它（文件夹里是打开那个 App）
      if let tile = layout.tiles.first(where: { $0.id == drag.tileID }) {
        open(tile)
      } else if let appID = drag.appID, let ref = layout.appRef(appID) {
        open(app: ref)
      }
      return
    }
    let capacity = capacity
    if let folderID = drag.sourceFolder {
      if drag.outsideFolder {
        commit(layout.draggingOut(drag.appID ?? "", from: folderID, capacity: capacity))
        closeFolder()
      }
      return
    }
    if let hovered = drag.hoverFolderID {
      commit(
        layout.folding(
          drag.tileID, onto: "folder\n" + hovered.uuidString,
          name: folderNameFor(drag.tileID), capacity: capacity))
      return
    }
    // 落在另一个 App 那一格上 = 建文件夹
    if let target = drag.targetIndex, let targetTile = currentTiles[safe: target],
      targetTile.app != nil, targetTile.id != drag.tileID
    {
      commit(
        layout.folding(
          drag.tileID, onto: targetTile.id,
          name: folderNameFor(drag.tileID), capacity: capacity))
      return
    }
    let slot = drag.targetIndex ?? currentTiles.count
    commit(layout.moving(drag.tileID, toPage: page, slot: slot, capacity: capacity))
  }

  func cancelDrag() {
    jiggleTask?.cancel()
    cancelTurn()
    withAnimation(Style.Motion.glide.animation()) { drag = nil }
  }

  /// 拖到打开着的文件夹面板里（松手加进去）
  func dropIntoOpenFolder() {
    guard let drag, let appID = drag.appID, let folderID = openFolderID else { return }
    jiggleTask?.cancel()
    cancelTurn()
    self.drag = nil
    commit(layout.adding(appID, to: folderID, capacity: capacity))
  }

  /// 悬在哪个文件夹上（主网格里的文件夹格）
  private func hoveredFolder(at location: CGPoint, excluding tileID: String) -> UUID? {
    for (id, frame) in folderFrames where frame.contains(location) {
      if "folder\n" + id.uuidString == tileID { continue }
      return id
    }
    return nil
  }

  /// 落点：当前页第几格（在网格框里按格子算；不在网格里返回 nil = 拖到空白处放末尾）
  private func targetIndex(at location: CGPoint) -> Int? {
    guard let frame = gridFrames[page] else { return nil }
    let metrics = metrics
    let column = Int((location.x - frame.minX) / max(metrics.cellWidth, 1))
    let row = Int((location.y - frame.minY) / max(metrics.cellHeight, 1))
    guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
    return row * columns + column
  }

  private func scheduleTurn(to target: Int) {
    guard target >= 0, target < pageCount else { return }
    guard drag?.turnPage != target else { return }
    drag?.turnPage = target
    turnTask?.cancel()
    turnTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled, let self, let drag, drag.turnPage == target else { return }
      withAnimation(Style.Motion.glide.animation()) {
        page = target
        pageOffset = 0
      }
      // 翻页后落点按新页重新算（指针没动，落点变成新页的格子）
      self.drag?.targetIndex = nil
    }
  }

  private func cancelTurn() {
    turnTask?.cancel()
    turnTask = nil
    drag?.turnPage = nil
  }

  /// 建文件夹时的名字：两个 App 的分类（SPEC R4）
  private func folderNameFor(_ tileID: String) -> String {
    let source = layout.tiles.first { $0.id == tileID }?.app.flatMap { app($0) }
    let targetRef = drag?.targetIndex.flatMap { currentTiles[safe: $0]?.app }
    let target = targetRef.flatMap { app($0) }
    guard let first = source ?? target else { return LaunchpadLayout.untitledFolder }
    return folderName(first, target ?? first)
  }

  // MARK: 布局

  /// 换一份布局（设置里恢复默认、撤销导入、删 App 之后）：当前页收回第一页，选中清掉
  func replace(layout: LaunchpadLayout) {
    self.layout = layout
    page = min(page, max(layout.pageCount - 1, 0))
    selected = nil
    openFolderID = nil
    drag = nil
    deleteCandidate = nil
  }

  /// 布局变了（拖格子、建文件夹）：马上交给总控存盘（R5）
  func commit(_ layout: LaunchpadLayout) {
    self.layout = layout
    page = min(page, max(layout.pageCount - 1, 0))
    selected = nil
    onLayoutChange(layout)
  }

  // MARK: 翻页手势

  /// 触控板两指左右滑、鼠标滚轮上下滚（SPEC R2）：跟手时挪页面，松手按位移和速度决定翻不翻。
  /// 入口是面板的 sendEvent（不装全局 / 本地事件监听），phase / momentum 直接从 NSEvent 来。
  func scroll(
    deltaX: CGFloat, deltaY: CGFloat, precise: Bool, phase: NSEvent.Phase,
    momentum: NSEvent.Phase
  ) {
    guard drag == nil, openFolderID == nil else { return }
    guard !displayPages.isEmpty, pageCount > 1 else { return }
    // 触控板横向为主时按横向，鼠标滚轮按纵向
    let primary = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY
    if phase == .began {
      scroll = 0
      scrollTask?.cancel()
    }
    // 惯性阶段不再跟手（松手那次已经决定了），只让它自然停
    if momentum != [] { return }
    if phase == .ended || phase == .cancelled {
      finishScroll()
      return
    }
    if !precise, phase == [] {
      // 鼠标滚轮：一格一格翻，不跟手
      scroll += primary
      if abs(scroll) >= 3 {
        turn(scroll < 0 ? 1 : -1)
        scroll = 0
      }
      return
    }
    scroll += primary
    let canForward = page < pageCount - 1
    let canBack = page > 0
    let wanted = scroll < 0 ? canForward : canBack
    withAnimation(Style.Motion.instant.animation()) {
      pageOffset = wanted ? clampOffset(scroll * 0.55) : clampOffset(scroll * 0.12)
    }
    if phase == [] {
      scrollTask?.cancel()
      scrollTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        self?.finishScroll()
      }
    }
  }

  private func clampOffset(_ value: CGFloat) -> CGFloat {
    min(max(value, -140), 140)
  }

  private func finishScroll() {
    let threshold: CGFloat = 56
    if abs(scroll) >= threshold {
      turn(scroll < 0 ? 1 : -1)
    } else {
      withAnimation(Style.Motion.glide.animation()) { pageOffset = 0 }
    }
    scroll = 0
  }

  private func turn(_ direction: Int) {
    let target = min(max(page + direction, 0), pageCount - 1)
    guard target != page else {
      withAnimation(Style.Motion.glide.animation()) { pageOffset = 0 }
      return
    }
    withAnimation(Style.Motion.glide.animation()) {
      page = target
      pageOffset = 0
      selected = nil
    }
  }
}
