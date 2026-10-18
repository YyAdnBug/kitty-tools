// 启动台一块屏的状态（界面读它、面板按键调它）：布局、本机 App、当前页、键盘选中的格子、搜索词、翻页的跟手偏移，
// 以及「打开一个 App」「收起」这些往上抛的回调。纯展示状态和几何的常量在这里；布局的增删挪在 LaunchpadLayout，
// 窗口和持久化在 Launchpad（总控）。
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
  var icon: CGFloat {
    max(40, min(104, min(cellWidth * 0.56, cellHeight * 0.58)))
  }
  var labelWidth: CGFloat { icon + 36 }
  var gridWidth: CGFloat { cellWidth * CGFloat(columns) }
  var gridHeight: CGFloat { cellHeight * CGFloat(rows) }
  /// 搜索框上沿
  var searchTop: CGFloat { max(16, size.height * 0.03) }
  var epsilon: CGFloat { 1 }
}

nonisolated enum LaunchpadDirection {
  case left, right, up, down
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
  /// 开着的文件夹（batch 2）
  var openFolderID: UUID?
  /// 抖动模式（batch 2）
  var jiggling = false
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
  /// 删 App（batch 2；总控做确认和 recycle）
  var onDeleteApp: (LaunchpadProjectApp) -> Void = { _ in }

  @ObservationIgnored private var scroll: CGFloat = 0
  @ObservationIgnored private var scrollTask: Task<Void, Never>?
  @ObservationIgnored private var searchCache: (query: String, apps: [LaunchpadProjectApp])?
  @ObservationIgnored private var buttons: [String: CGFloat] = [:]

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

  /// 换一份布局（设置里恢复默认、撤销导入、删 App 之后）：当前页收回第一页，选中清掉
  func replace(layout: LaunchpadLayout) {
    self.layout = layout
    page = min(page, max(layout.pageCount - 1, 0))
    selected = nil
    openFolderID = nil
  }

  /// 布局变了（拖格子、建文件夹）：马上交给总控存盘（R5）
  func commit(_ layout: LaunchpadLayout) {
    self.layout = layout
    page = min(page, max(layout.pageCount - 1, 0))
    selected = nil
    onLayoutChange(layout)
  }

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

  var currentPage: [[LaunchpadTile]] { [currentTiles] }

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

  /// 当前页第 index 格的那个 App / 文件夹
  func tile(at index: Int) -> LaunchpadTile? { currentTiles[safe: index] }

  func app(at index: Int) -> LaunchpadProjectApp? {
    guard let tile = tile(at: index) else { return nil }
    switch tile {
    case .app(let ref): return app(ref)
    case .folder: return nil
    }
  }

  /// 第 index 格的显示名（文件夹用文件夹名）
  func title(of tile: LaunchpadTile) -> String {
    switch tile {
    case .app(let ref):
      return app(ref)?.name
        ?? URL(filePath: ref.path).deletingPathExtension()
        .lastPathComponent
    case .folder(let folder): return folder.name
    }
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

  /// 方向键：格子里挪；到页边接着翻页（↑↓ 还保持列）
  func navigate(_ direction: LaunchpadDirection) {
    guard !currentTiles.isEmpty else { return }
    let count = currentTiles.count
    let index = selected ?? (direction == .left || direction == .up ? 0 : 0)
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
          selected = Self.rowClamped(index % columns, in: tiles[page - 1].count, columns: columns)
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
          selected = Self.rowClamped(index % columns, in: tiles[page + 1].count, columns: columns)
        }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index + columns }
      }
    }
  }

  /// 目标页同一列的第一个格子（目标页短、没有这一列时用最后一个）
  nonisolated static func rowClamped(_ column: Int, in count: Int, columns: Int) -> Int {
    guard count > 0 else { return 0 }
    let candidate = column
    return min(candidate, count - 1)
  }

  // MARK: 回车 / Esc / 点空白

  /// ↩：打开选中的；搜索时没有选中就打开第一个结果（SPEC R3）
  func returnPressed() {
    if let selected, let tile = tile(at: selected) {
      open(tile)
      return
    }
    if isSearching, let first = currentTiles.first {
      open(first)
    }
  }

  /// Esc：先清空搜索，再关文件夹、最后收起（SPEC R1/R3）
  func cancel() {
    if isSearching {
      query = ""
      return
    }
    if openFolderID != nil {
      withAnimation(Style.Motion.settle.animation()) { openFolderID = nil }
      return
    }
    requestClose()
  }

  /// 点空白处：文件夹开着时只收文件夹，否则收起启动台
  func backgroundClicked() {
    if openFolderID != nil {
      withAnimation(Style.Motion.settle.animation()) { openFolderID = nil }
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
      guard let app = app(ref) else {
        NSSound.beep()
        return
      }
      onOpenApp(app)
    case .folder(let folder):
      withAnimation(Style.Motion.pop.animation()) { openFolderID = folder.id }
    }
  }

  func open(at index: Int) {
    guard let tile = tile(at: index) else { return }
    open(tile)
  }

  /// 打开文件夹里的一个 App
  func open(app ref: LaunchpadAppRef) {
    guard let app = app(ref) else { return }
    onOpenApp(app)
  }

  // MARK: 翻页手势

  /// 触控板两指左右滑、鼠标滚轮上下滚（SPEC R2）：跟手时挪页面，松手按位移和速度决定翻不翻。
  /// 入口是面板的 sendEvent（不装全局 / 本地事件监听），phase / momentum 直接从 NSEvent 来。
  func scroll(
    deltaX: CGFloat, deltaY: CGFloat, precise: Bool, phase: NSEvent.Phase,
    momentum: NSEvent.Phase
  ) {
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
