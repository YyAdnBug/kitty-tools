// 启动台一块屏的状态（界面读它、面板按键调它）：布局、本机 App、当前页、键盘选中的格子、搜索词、翻页的跟手偏移、
// 拖动 / 抖动 / 文件夹展开这些编辑状态，以及「打开一个 App」「收起」这些往上抛的回调。
// 网格尺寸在 LaunchpadMetrics，翻页状态机在 LaunchpadPager，拖动的值类型和纯函数在 LaunchpadDrag；
// 布局的增删挪在 LaunchpadLayout，窗口和持久化在 Launchpad（总控）。
// 键盘选中的口径照 macOS 15：一开始没有选中（鼠标指着不高亮），按一下方向键才出现；到页边接着翻页；搜索结果也按页排。
// 拖动（2026-10-18 四批评审后的口径，照 macOS 15；复查后 G3 再改）：
// - 落点按**拿掉被拖那格之后**的插入位置算（slot 不再减 1），页容器居中、两边有留白，算落点先减掉；
// - 拿起时空位留在原处；指针在某个**画出来的**图标的左 / 右边沿 = 插到它前 / 后，在它的中心区 = 合成候选、空位不动，
//   在空位上什么都不变——图标不会被空位挤走，也不会追着指针跑（G3）；
// - 建文件夹 / 加进文件夹 = 拖的是 App、指针停在目标图标中心区**并停够约 0.4 秒**；其余情况一律落进空位，
//   满页也能排序；拖文件夹不合成（G11）；
// - 按下 1 秒进抖动的那一次松手不算点击（不会打开 App）；抖动中单击照 macOS 15 打开 App；
// - Esc 取消要记到这次手势结束，不能下一次 onChanged 又把手势捡回来；
// - 搜索时照样记下按下和松开（单击打开结果），但不激活拖动，结果不会被拖进真布局。
// 2026-10-18 交互对齐（方案 build/research/launchpad/INTERACT.md，数字借同类里最像的那个，时长都在 LaunchpadDragTiming）：
// - 让位停 0.15 s 才动（指针扫过去不乱跳）；松手执行**屏上正显示的**排法，不再按松手那一刻的指针重算；
// - 一拖起来就进抖动，松手后接着抖；停在文件夹上约 1 s 它自己打开，可以放进里面任意一格、文件夹里也能挪；
// - 拖出文件夹面板 14 pt 就关文件夹、接着在主网格里拖；边上 60 pt 停 0.4 s 翻页，一直停着每 0.6 s 再翻；
// - 松手 / 取消时那份跟手的滑进落点 / 滑回原位（`landing`）；空白处按住左右拖也能翻页。

import AppKit
import Observation
import SwiftUI

nonisolated enum LaunchpadDirection {
  case left, right, up, down
}

@Observable
@MainActor
final class LaunchpadModel {
  private(set) var layout: LaunchpadLayout
  private(set) var catalog: [LaunchpadProjectApp]
  /// 按 id 找 App 的字典（每格每次 body 里 `catalog.first {}` 线性找几次，拖动时每个指针事件都触发，F42）
  @ObservationIgnored private var catalogByID: [String: LaunchpadProjectApp]
  let icons: LaunchpadIcons
  let columns: Int
  let rows: Int
  let screenSize: CGSize

  var query = "" {
    didSet {
      guard query != oldValue else { return }
      let wasSearching = !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let nowSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      // 删光字回到搜索之前那一页（R3，F24）；搜索中换字仍回到第一页
      if !wasSearching, nowSearching { pageBeforeSearch = page }
      if !query.isEmpty { searchEngaged = true }
      selected = nil
      page = wasSearching && !nowSearching ? min(pageBeforeSearch ?? 0, pageCount - 1) : 0
      pageOffset = 0
      pager.reset()
      scroll = 0
      searchCache = nil
      // 搜索期间扫完的新目录压着没并进布局：清空搜索时接上（G14）
      if wasSearching, !nowSearching { onSettled() }
    }
  }
  /// 用户点过搜索框（或打过字）：「放大镜 + 搜索」从正中滑到左边、插入点亮起来（照系统的搜索框获得焦点）。
  /// 一打开焦点就在搜索框里、但插入点藏着、占位居中（照 macOS 15）；点一下要有反应，不然看着像没点中（2026-10-19 真机反馈）。
  /// 搜索框交出焦点（开文件夹、进抖动）时复位
  private(set) var searchEngaged = false
  /// 当前页（0 起）
  private(set) var page = 0
  /// 搜索开始时那一页（删光搜索字回到它）
  private var pageBeforeSearch: Int?
  /// 键盘选中的格子在当前页里的下标；nil = 还没按方向键（鼠标指着不高亮）
  var selected: Int?
  /// 翻页跟手的横向偏移（点）
  private(set) var pageOffset: CGFloat = 0
  /// 文件夹里那一页的横向偏移（F17：文件夹里也能跟手翻页）
  private(set) var folderPageOffset: CGFloat = 0
  /// 收起已经定了（再点空白 / Esc 不会收第二次）
  private(set) var isClosing = false
  /// 打开 / 收起走到哪了（0 = 收着、1 = 摆好）：总控那块面板的 `LaunchpadZoom` 每帧设，**不带动画**（跟手时由手指决定，
  /// 松手后、按键开关时由它的弹簧走）。单测和截图自检不经过总控，直接是摆好的样子
  var zoom: Double = 1
  /// 上面那层按收起的走法缩放（1 → 1.08，往前冲出去：张开手指、按键 / 点空白收起），还是按打开的走法倒着走
  /// （1 → 1.1，退回去：捏到一半松手缩回）
  var zoomForward = false
  /// 背景：那块屏的壁纸模糊后的样子（总控在后台做好喂进来；nil = 系统毛玻璃）
  var wallpaper: CGImage?

  // MARK: 编辑（R4–R6）
  /// 开着的文件夹（nil = 没开）
  private(set) var openFolderID: UUID?
  /// 文件夹里看的是第几页
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
  /// 搜索框要拿 / 放焦点（G9：开文件夹、进抖动时放掉，关掉 / 退出时还回去；面板接）
  var onSearchFocus: (Bool) -> Void = { _ in }
  /// 手上的事停下来了（松手、清空搜索）：总控把这期间压着没换的布局 / 目录接上（G14 / G26）
  var onSettled: () -> Void = {}

  @ObservationIgnored private var scroll: CGFloat = 0
  @ObservationIgnored private var scrollTask: Task<Void, Never>?
  @ObservationIgnored private var pager = LaunchpadPager()
  @ObservationIgnored private var folderPager = LaunchpadPager()
  @ObservationIgnored private var searchCache: (query: String, apps: [LaunchpadProjectApp])?
  @ObservationIgnored private var jiggleTask: Task<Void, Never>?
  @ObservationIgnored private var combineTask: Task<Void, Never>?
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  /// 这次按下进了抖动（松手不算点击）
  @ObservationIgnored private var pressEnteredJiggle = false
  /// Esc 取消了这一次手势：直到 onEnded 之前都不许再 beginDrag
  @ObservationIgnored private var gestureCancelled = false
  /// 指针正停在哪个图标的中心上（0.4 秒的计时按它认）
  @ObservationIgnored private var combineCandidate: String?
  /// 界面每次布局后喂进来的网格 / 文件夹面板位置（命名坐标空间里），算落点和「拖出去了没有」
  @ObservationIgnored var gridFrames: [Int: CGRect] = [:]
  /// 拖动的几个时长（单测可以换成不等的）
  @ObservationIgnored var dragTiming = LaunchpadDragTiming.macOS15
  /// 松手 / 取消之后滑进落点（滑回原位）的那一份；界面画它，这期间落点上那一格先不画
  private(set) var landing: LaunchpadLanding?
  @ObservationIgnored private var landingID = 0
  /// 等着让位的落点：停够 `dragTiming.reflow` 才换上去
  @ObservationIgnored private var pendingTarget: (folder: Bool, index: Int)?
  @ObservationIgnored private var reflowTask: Task<Void, Never>?
  /// 拖动时指针最后在哪、页多宽（松手、边上连续翻页用）
  @ObservationIgnored private var lastDragLocation: CGPoint = .zero
  @ObservationIgnored private var lastPageWidth: CGFloat = 0
  /// 空白处按住拖着翻页：上一次的横向位移（nil = 还没挪够 5 pt，松手算点了空白）
  @ObservationIgnored private var backgroundTravel: CGFloat?

  init(
    layout: LaunchpadLayout, catalog: [LaunchpadProjectApp], icons: LaunchpadIcons,
    columns: Int, rows: Int, screenSize: CGSize, startPage: Int = 0,
    dragTiming: LaunchpadDragTiming = .macOS15
  ) {
    self.dragTiming = dragTiming
    self.layout = layout
    self.catalog = catalog
    self.catalogByID = Dictionary(
      catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.icons = icons
    self.columns = columns
    self.rows = rows
    self.screenSize = screenSize
    // 重新打开回到上次那一页（F24；夹在页数里）
    page = min(max(startPage, 0), max(layout.pageCount - 1, 0))
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
  /// 目标页不管是不是源页都插空位（F18）；拖到空白处时空位画在末尾。搜索时不许拖。
  func previewTiles(page pageIndex: Int) -> [LaunchpadTile?] {
    let pages = displayPages
    guard pages.indices.contains(pageIndex) else { return [] }
    var tiles: [LaunchpadTile?] = pages[pageIndex]
    guard let drag, drag.isDragging, !isSearching, !gestureCancelled else { return tiles }
    if let from = tiles.firstIndex(where: { $0?.id == drag.tileID }) {
      tiles.remove(at: from)
    }
    if pageIndex == page {
      let target = drag.targetIndex ?? tiles.count
      tiles.insert(nil, at: min(max(target, 0), tiles.count))
    }
    return tiles
  }

  /// 打开的文件夹这一页给界面画的格子：拖动时把手里的那个拿掉、落点处插一个空位（文件夹里也让位）
  func folderPreview(page pageIndex: Int) -> [LaunchpadAppRef?] {
    var apps: [LaunchpadAppRef?] = openFolder?.pages[safe: pageIndex] ?? []
    guard let drag, drag.isDragging, !gestureCancelled, pageIndex == folderPage else { return apps }
    apps.removeAll { $0?.id == drag.appID }
    let target = drag.folderTarget ?? apps.count
    apps.insert(nil, at: min(max(target, 0), apps.count))
    return apps
  }

  /// 空位画在第几格（界面里 `previewTiles` 的 nil 已经在，这里给位置校验用）
  func gapIndex(page pageIndex: Int) -> Int? {
    guard let drag, drag.isDragging, !isSearching, !gestureCancelled, pageIndex == page else {
      return nil
    }
    let tiles = previewTiles(page: pageIndex)
    return tiles.firstIndex { $0 == nil }
  }

  /// 目录扫完 / 删掉一个 App 之后接上（F31：面板先出，扫完再把新目录喂进来）
  func adopt(catalog apps: [LaunchpadProjectApp]) {
    catalog = apps
    catalogByID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    searchCache = nil
  }

  /// 按 id 找本机 App（布局里存的只有身份）
  func app(_ ref: LaunchpadAppRef) -> LaunchpadProjectApp? {
    catalogByID[ref.id]
  }

  func app(id: String) -> LaunchpadProjectApp? {
    catalogByID[id]
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

  /// 正在按下的那一格（R2：按下变暗；拖动开始后就不再算按下）
  var pressedTileID: String? {
    guard let drag, !drag.isDragging, !gestureCancelled, !isSearching else { return nil }
    return drag.tileID
  }

  // MARK: 键盘

  func go(to page: Int) {
    let target = min(max(page, 0), pageCount - 1)
    guard target != self.page else { return }
    withAnimation(pageMotion) {
      self.page = target
      pageOffset = 0
      pager.reset()
      selected = nil
    }
  }

  /// 翻页的动画（键盘、点页点、拖到边上、文件夹里翻页；松手那一下另按手指的速度给，见 `finishScroll`）。
  /// 界面上不挂按页号的隐式动画：那会盖掉这里给的动画（松手的速度就丢了）
  private var pageMotion: Animation? {
    Style.reduceMotion ? nil : LaunchpadPager.animation()
  }

  /// 布局变了（拖完、删 App、换布局）页数变少：当前页夹回去，滑过去
  private func clampPage() {
    let clamped = min(page, max(layout.pageCount - 1, 0))
    guard clamped != page else { return }
    withAnimation(pageMotion) { page = clamped }
  }

  func firstPage() { go(to: 0) }
  func lastPage() { go(to: pageCount - 1) }

  /// 方向键：格子里挪；到页边接着翻页（↑↓ 还保持列）。文件夹开着时在文件夹的 7 × 5 里挪。
  /// 第一下方向键先选中第 0 格（F37：原来第一下按 ↓ 会跳到第二行）。
  func navigate(_ direction: LaunchpadDirection) {
    if openFolder != nil {
      navigateFolder(direction)
      return
    }
    guard !currentTiles.isEmpty else { return }
    if selected == nil {
      withAnimation(Style.Motion.snap.animation()) { selected = 0 }
      return
    }
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
        withAnimation(pageMotion) { self.page = page - 1 }
        withAnimation(Style.Motion.snap.animation()) {
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
        withAnimation(pageMotion) { self.page = page + 1 }
        withAnimation(Style.Motion.snap.animation()) { selected = 0 }
      } else {
        withAnimation(Style.Motion.snap.animation()) { selected = index + 1 }
      }
    case .up:
      if index / columns == 0 {
        guard page > 0 else {
          NSSound.beep()
          return
        }
        withAnimation(pageMotion) { self.page = page - 1 }
        withAnimation(Style.Motion.snap.animation()) {
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
        withAnimation(pageMotion) { self.page = page + 1 }
        withAnimation(Style.Motion.snap.animation()) {
          selected = Self.columnClamped(index % columns, in: tiles[page + 1].count)
        }
      } else {
        // 最后一行不满时别越过 count（F37：原来选中框会消失、回车没反应）
        withAnimation(Style.Motion.snap.animation()) { selected = min(index + columns, count - 1) }
      }
    }
  }

  /// 目标页同一列的第一个格子（目标页短、没有这一列时用最后一个）
  nonisolated static func columnClamped(_ column: Int, in count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(column, count - 1)
  }

  // MARK: 搜索框

  /// 面板收到点在搜索框上的按下（`LaunchpadPanel.sendEvent`）：占位滑到左边、插入点亮起来
  func searchClicked() {
    guard !searchEngaged else { return }
    withAnimation(Style.Motion.glide.animation()) { searchEngaged = true }
  }

  /// 搜索框拿 / 放焦点都走这里：放掉时一起复位「点过搜索框」（占位回到正中、插入点藏起来）
  private func setSearchFocus(_ focused: Bool) {
    if !focused, searchEngaged, query.isEmpty {
      withAnimation(Style.Motion.glide.animation()) { searchEngaged = false }
    }
    onSearchFocus(focused)
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

  /// 空白处按住拖（鼠标翻页，照 macOS 15）：挪够 5 pt 才算拖，之后和两指滑同一套跟手翻页；没挪够就松手 = 点了空白
  func backgroundDragChanged(translation: CGSize, time: TimeInterval) {
    guard drag == nil, openFolderID == nil else { return }
    if backgroundTravel == nil {
      guard hypot(translation.width, translation.height) >= 5 else { return }
      backgroundTravel = 0
      pager.reset()
      scrollTask?.cancel()
    }
    let delta = translation.width - (backgroundTravel ?? 0)
    backgroundTravel = translation.width
    let offset = pager.feed(
      delta: delta, time: time, pageWidth: metrics.size.width, canBack: page > 0,
      canForward: page < pageCount - 1)
    withAnimation(Style.Motion.instant.animation()) {
      pageOffset = Style.reduceMotion ? 0 : offset
    }
  }

  func backgroundDragEnded(time: TimeInterval) {
    guard backgroundTravel != nil else {
      backgroundClicked()
      return
    }
    backgroundTravel = nil
    finishScroll(time: time)
  }

  /// 面板开始收（总控在淡出前调）：`forward` = 往前冲出去（收起），false = 倒着走打开那一段（捏到一半松手）
  func beginClosing(forward: Bool = true) {
    isClosing = true
    zoomForward = forward
  }

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

  /// 文件夹面板画几行：按最多的一页（7 列，最多 5 行 = 35 个）；面板高度跟着它走（F34）
  var folderRows: Int {
    var maxCount = openFolder?.pages.map(\.count).max() ?? 0
    // 从外面拖进开着的文件夹：多出来的那个空位也要有地方画（不然一行满了时最后一个被挤得看不见）
    if let drag, drag.isDragging, let folder = openFolder,
      !folder.apps.contains(where: { $0.id == drag.appID })
    {
      maxCount = max(maxCount, (folder.pages[safe: folderPage]?.count ?? 0) + 1)
    }
    return max(
      1, min(5, Int((Double(maxCount) / Double(LaunchpadLayout.folderColumns)).rounded(.up))))
  }

  func openFolder(_ id: UUID) {
    guard folder(id) != nil else { return }
    folderNameDraft = folder(id)?.name ?? ""
    // 面板从文件夹方块那儿长到屏幕中间、关的时候缩回去：动的是界面里那块「纸」（LaunchpadView 的 FolderPaper，同便签墙的编辑卡）
    withAnimation(LaunchpadView.folderGrow) {
      openFolderID = id
      folderPage = 0
      folderPageOffset = 0
      selected = nil
    }
    // 打开文件夹后接着打字不进背后的搜索框（F34）
    setSearchFocus(false)
  }

  func closeFolder() {
    let wasOpen = openFolderID != nil
    // 后面那层淡掉、里面的图标先淡掉；面板那块纸缩回文件夹方块由界面做（settle，同便签墙编辑卡收回）
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = nil
      folderPage = 0
      folderPageOffset = 0
      selected = nil
      drag = nil
    }
    cancelTurn()
    // 焦点还给搜索框：关掉文件夹后「一打字就进搜索」照常（G9）
    if wasOpen, !jiggling { setSearchFocus(true) }
  }

  /// 打开的文件夹面板在屏上的位置（和界面同一个算式：名字一行、隔 18、面板四边 28、里面网格 + 10 + 页点 7，整组在屏幕正中）。
  /// 按算式、不按量出来的：面板长出来的那一下量到的是缩着的框
  var folderPanelRect: CGRect {
    let metrics = metrics
    let pad = LaunchpadMetrics.folderPadding
    let width = metrics.folderGridWidth + pad * 2
    let height = metrics.folderCellHeight * CGFloat(folderRows) + 10 + 7 + pad * 2
    let title = LaunchpadMetrics.folderTitleHeight + LaunchpadMetrics.folderTitleSpacing
    return CGRect(
      x: (screenSize.width - width) / 2, y: (screenSize.height - title - height) / 2 + title,
      width: width, height: height)
  }

  /// 文件夹面板里第 `index` 格的中心（屏上）；格子里那一组（图标 + 名字）竖着居中，图标中心比它高 `iconLift`
  func folderCellCenter(_ index: Int) -> CGPoint {
    let rect = folderPanelRect
    let metrics = metrics
    let columns = LaunchpadLayout.folderColumns
    return CGPoint(
      x: rect.minX + LaunchpadMetrics.folderPadding
        + (CGFloat(index % columns) + 0.5) * metrics.folderCellWidth,
      y: rect.minY + LaunchpadMetrics.folderPadding
        + (CGFloat(index / columns) + 0.5) * metrics.folderCellHeight)
  }

  /// 指针在文件夹面板网格的第几格（网格外 nil）
  func folderCell(at location: CGPoint) -> Int? {
    let rect = folderPanelRect
    let metrics = metrics
    let x = location.x - rect.minX - LaunchpadMetrics.folderPadding
    let y = location.y - rect.minY - LaunchpadMetrics.folderPadding
    guard x >= 0, y >= 0, metrics.folderCellWidth > 0, metrics.folderCellHeight > 0 else {
      return nil
    }
    let column = Int(x / metrics.folderCellWidth)
    let row = Int(y / metrics.folderCellHeight)
    guard column < LaunchpadLayout.folderColumns, row < folderRows else { return nil }
    return row * LaunchpadLayout.folderColumns + column
  }

  /// 主网格第 `page` 页第 `index` 格的中心（屏上；那一页还没画出来时 nil）
  func cellCenter(page: Int, index: Int) -> CGPoint? {
    guard let frame = gridFrames[page] else { return nil }
    let rect = Self.cellRect(index, in: frame, metrics: metrics)
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  /// 当前页上某个文件夹那一格图标的中心（文件夹从这儿长出来）
  func folderTileCenter(_ id: UUID) -> CGPoint? {
    guard let index = currentTiles.firstIndex(where: { $0.folder?.id == id }),
      let center = cellCenter(page: page, index: index)
    else { return nil }
    return CGPoint(x: center.x, y: center.y - LaunchpadMetrics.iconLift)
  }

  /// 当前页上某个文件夹那一格的方块在屏上的框（方块是图标的 0.8 倍）：面板从这儿长出来、缩回这儿；不在这一页时 nil
  func folderGlyphRect(_ id: UUID) -> CGRect? {
    guard let center = folderTileCenter(id) else { return nil }
    let side = metrics.icon * 0.8
    return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
  }

  func goToFolderPage(_ page: Int, velocity: CGFloat = 0) {
    let target = min(max(page, 0), folderPageCount - 1)
    let width = metrics.folderGridWidth
    let distance = -CGFloat(target - folderPage) * width - folderPageOffset
    withAnimation(
      Style.reduceMotion ? nil : LaunchpadPager.animation(velocity: velocity, distance: distance)
    ) {
      folderPage = target
      folderPageOffset = 0
    }
  }

  private func navigateFolder(_ direction: LaunchpadDirection) {
    let count = folderApps.count
    guard count > 0 else { return }
    if selected == nil {
      selected = 0
      return
    }
    let index = selected ?? 0
    let columns = LaunchpadLayout.folderColumns
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
      selected = min(index + columns, count - 1)
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
    setSearchFocus(false)
  }

  func exitJiggle() {
    guard jiggling else { return }
    withAnimation(Style.Motion.settle.animation()) { jiggling = false }
    jiggleByOption = false
    deleteCandidate = nil
    // 退出抖动后焦点还给搜索框（G9）
    if openFolderID == nil { setSearchFocus(true) }
  }

  /// 面板的 flagsChanged 喂进来：⌥ 按下进抖动、松开退出（按住图标进的那种不受影响）。
  /// 正在搜索 / 搜索框有字时按 ⌥ 是打特殊字符，不进抖动（F45）
  func optionChanged(_ held: Bool) {
    optionHeld = held
    if held {
      guard drag == nil, !isSearching else { return }
      enterJiggle(byOption: true)
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

  /// 按下：`origin` 是这一格图标在屏上的中心（跟手那一份按它摆，指针在图标哪儿就一直在哪儿）
  func beginDrag(
    tile: LaunchpadTile, appID: String?, folder: UUID?, at point: CGPoint, origin: CGPoint? = nil
  ) {
    guard !gestureCancelled else { return }
    var drag = LaunchpadDrag(tileID: tile.id, appID: appID, sourceFolder: folder, start: point)
    if let origin {
      drag.grabOffset = CGSize(width: origin.x - point.x, height: origin.y - point.y)
    }
    // 从开着的文件夹里按下：指针本来就在面板里
    drag.enteredFolder = folder != nil
    drag.startPage = page
    self.drag = drag
    lastDragLocation = point
    pressEnteredJiggle = false
    combineCandidate = nil
    combineTask?.cancel()
    cancelReflow()
    jiggleTask?.cancel()
    // 搜索时不许拖（结果的位置不是布局的位置），但按下 / 松手照记：单击照样打开结果（F5）
    guard !isSearching else { return }
    // 按住不动 1 秒 = 进抖动模式；这一次松手不算点击（F4）
    jiggleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self, self.drag?.tileID == tile.id,
        self.drag?.isDragging != true
      else { return }
      self.pressEnteredJiggle = true
      self.enterJiggle()
    }
  }

  /// 指针动了：算落点、停在哪个图标中心、要不要翻页（view 传的是命名坐标空间里的位置）
  func updateDrag(location: CGPoint, pageWidth: CGFloat) {
    guard !gestureCancelled, var drag else { return }
    lastDragLocation = location
    lastPageWidth = pageWidth
    if isSearching {
      // 记下位移但不激活拖动：搜到结果后按着挪一下再松手也只是打开（F5）
      drag.translation = CGSize(
        width: location.x - drag.start.x, height: location.y - drag.start.y)
      self.drag = drag
      return
    }
    let moved = hypot(location.x - drag.start.x, location.y - drag.start.y)
    var activated = false
    if !drag.active, moved >= 4 {
      drag.active = true
      activated = true
      jiggleTask?.cancel()
      pressEnteredJiggle = false
      // 拿起时空位留在原处（G3）：别的图标先不动，等指针挪到某个图标的边上才让位
      if drag.sourceFolder == nil,
        let source = currentTiles.firstIndex(where: { $0.id == drag.tileID })
      {
        drag.targetIndex = source
      }
      if drag.sourceFolder != nil,
        let source = folderApps.firstIndex(where: { $0.id == drag.appID })
      {
        drag.folderTarget = source
      }
    }
    drag.translation = CGSize(
      width: location.x - drag.start.x, height: location.y - drag.start.y)
    guard drag.active else {
      self.drag = drag
      return
    }
    // 照 macOS 15：一拖起来所有图标就抖，松手后接着抖（点空白 / Esc 停）
    if activated { enterJiggle() }
    if openFolderID != nil {
      let panel = folderPanelRect.insetBy(dx: -Self.folderHandoff, dy: -Self.folderHandoff)
      if folderPanelRect.contains(location) { drag.enteredFolder = true }
      self.drag = drag
      if drag.enteredFolder, !panel.contains(location) {
        // 进过面板、又拖出去 14 pt：文件夹关上，接着在主网格里拖
        handOffToGrid(location)
      } else {
        scheduleReflow(folderHit(at: location, drag: drag), folder: true)
        updateFolderEdge(location, delay: dragTiming.edgeDwell)
      }
      return
    }
    let hit = dropHit(at: location, drag: drag)
    updateCombine(&drag, candidate: hit.combine)
    self.drag = drag
    scheduleReflow(hit.target, folder: false)
    updateEdge(location, pageWidth: pageWidth, delay: dragTiming.edgeDwell)
  }

  /// 拖出文件夹面板多少就算拖出去
  static let folderHandoff: CGFloat = 14
  /// 文件夹面板里左右边上多宽算「停在边上」（翻文件夹的页；在面板里面，和拖出去的那 14 pt 不撞）
  static let folderEdgeZone: CGFloat = 40
  /// 屏幕左右边上多宽算「停在边上」（要翻页）
  static let edgeZone: CGFloat = 60

  /// 停在左右边缘：停够就翻页（同 macOS 15 的拖到边上翻）；最后一页再往右 = 新开一页（G10）。同一个边缘上挪动不重新计时
  private func updateEdge(_ location: CGPoint, pageWidth: CGFloat, delay: Duration) {
    guard drag?.isDragging == true, openFolderID == nil else { return }
    let edge: Int? =
      location.x < Self.edgeZone
      ? page - 1 : (location.x > pageWidth - Self.edgeZone ? page + 1 : nil)
    guard edge != drag?.turnPage else { return }
    cancelTurn()
    if let edge { scheduleTurn(to: edge, after: delay) }
  }

  /// 文件夹开着、拖到面板左右边上：停够就翻文件夹的页，一直停着接着翻（同主网格；只翻到已有的页，2026-10-18）
  private func updateFolderEdge(_ location: CGPoint, delay: Duration) {
    guard drag?.isDragging == true, openFolderID != nil else { return }
    let rect = folderPanelRect
    var edge: Int?
    if location.y >= rect.minY, location.y <= rect.maxY {
      if location.x < rect.minX + Self.folderEdgeZone {
        edge = folderPage - 1
      } else if location.x > rect.maxX - Self.folderEdgeZone {
        edge = folderPage + 1
      }
    }
    if let target = edge, !(0..<folderPageCount).contains(target) { edge = nil }
    guard edge != drag?.turnPage else { return }
    cancelTurn()
    guard let target = edge else { return }
    drag?.turnPage = target
    let repeatDelay = dragTiming.edgeRepeat
    turnTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.drag?.turnPage == target, self.openFolderID != nil
      else { return }
      withAnimation(self.pageMotion) {
        self.folderPage = target
        self.folderPageOffset = 0
      }
      // 翻过去以后落点按新的一页重新算（指针没动）
      self.cancelReflow()
      self.drag?.folderTarget = nil
      self.drag?.turnPage = nil
      self.updateFolderEdge(self.lastDragLocation, delay: repeatDelay)
    }
  }

  /// 让位：落点要变时先等 `dragTiming.reflow`，指针在这期间又挪到别处就重新等；挪回空位上 / 停到中心区就不变了
  private func scheduleReflow(_ target: Int?, folder: Bool) {
    let current = folder ? drag?.folderTarget : drag?.targetIndex
    guard let target, target != current else {
      cancelReflow()
      return
    }
    if let pendingTarget, pendingTarget.folder == folder, pendingTarget.index == target { return }
    pendingTarget = (folder, target)
    reflowTask?.cancel()
    guard dragTiming.reflow > .zero else {
      applyReflow()
      return
    }
    let delay = dragTiming.reflow
    reflowTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.applyReflow()
    }
  }

  private func applyReflow() {
    guard let pending = pendingTarget, drag?.isDragging == true else { return }
    pendingTarget = nil
    if pending.folder {
      drag?.folderTarget = pending.index
    } else {
      drag?.targetIndex = pending.index
    }
  }

  private func cancelReflow() {
    reflowTask?.cancel()
    reflowTask = nil
    pendingTarget = nil
  }

  /// 文件夹开着时指针在面板网格的哪儿：照主网格的口径（左 / 右半边插前 / 后，空位上不变），文件夹里不合成
  private func folderHit(at location: CGPoint, drag: LaunchpadDrag) -> Int? {
    guard let cell = folderCell(at: location) else { return nil }
    let apps = folderApps.filter { $0.id != drag.appID }
    let gap = min(max(drag.folderTarget ?? apps.count, 0), apps.count)
    let center = folderCellCenter(cell)
    let zone: DropZone = location.x < center.x ? .before : .after
    return Self.dropTarget(cell: cell, zone: zone, gap: gap, count: apps.count).target
  }

  /// 拖出了文件夹面板：文件夹关上，手里的接着在主网格里拖（照 macOS 15）。落点马上按指针算，不等防抖
  private func handOffToGrid(_ location: CGPoint) {
    cancelReflow()
    combineTask?.cancel()
    combineCandidate = nil
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = nil
      folderPage = 0
      folderPageOffset = 0
      selected = nil
    }
    guard var drag else { return }
    drag.folderTarget = nil
    drag.enteredFolder = false
    let removed = currentTiles.filter { $0.id != drag.tileID }
    drag.targetIndex = removed.count
    drag.targetIndex = dropHit(at: location, drag: drag).target ?? removed.count
    self.drag = drag
  }

  /// 停在文件夹上（合成底板出来以后）再停一会儿：打开它，手里的接着拖，能放进里面任意一格
  private func openFolderForDrag(_ id: UUID) {
    guard var drag, drag.isDragging, drag.appID != nil, folder(id) != nil else { return }
    cancelTurn()
    cancelReflow()
    combineCandidate = nil
    drag.combineTileID = nil
    drag.enteredFolder = false
    folderNameDraft = folder(id)?.name ?? ""
    self.drag = drag
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = id
      folderPage = 0
      folderPageOffset = 0
      selected = nil
    }
    self.drag?.folderTarget = folderApps.filter { $0.id != drag.appID }.count
    setSearchFocus(false)
  }

  /// 指针落在网格的哪儿（G3 的判定，纯逻辑在 `dropTarget`）：返回新的落点（nil = 不变）和合成候选（格子的 id）
  private func dropHit(at location: CGPoint, drag: LaunchpadDrag) -> (
    target: Int?, combine: String?
  ) {
    guard let frame = gridFrames[page],
      let cell = Self.cellIndex(at: location, in: frame, metrics: metrics)
    else { return (nil, nil) }
    let removed = currentTiles.filter { $0.id != drag.tileID }
    let gap = min(max(drag.targetIndex ?? removed.count, 0), removed.count)
    // 只有拖的是 App 才能合成（G11：拖文件夹停在别的图标上照常挪）
    let canCombine = drag.appID != nil && drag.sourceFolder == nil
    let zone = Self.zone(of: location, cell: cell, in: frame, metrics: metrics, center: canCombine)
    let result = Self.dropTarget(cell: cell, zone: zone, gap: gap, count: removed.count)
    return (result.target, result.combine.flatMap { removed[safe: $0]?.id })
  }

  /// 松手：执行**屏上正显示的**排法（落点、合成底板都是停够了才换上去的，不按松手那一刻的指针重算，LaunchNext 的做法）。
  /// 文件夹开着、指针在面板里 = 放进文件夹那一格；停在图标中心够久 = 建文件夹 / 加进文件夹；其余按落点挪。
  /// 从文件夹里拖出来的先拿出来再挪。跟手的那一份随后滑进落点（`landing`）
  func endDrag() {
    defer { gestureCancelled = false }
    // 松手了：这期间压着没换的布局 / 目录接上（G14 / G26）。放在最前面，任何一条返回路径都会走到
    defer { onSettled() }
    guard let drag, !gestureCancelled else { return }
    jiggleTask?.cancel()
    combineTask?.cancel()
    combineCandidate = nil
    cancelReflow()
    defer { cancelTurn() }
    self.drag = nil
    if !drag.active {
      // 长按进抖动的那一次松手不算点击（F4）；抖动中单击照 macOS 15 打开 App
      if pressEnteredJiggle {
        pressEnteredJiggle = false
        return
      }
      // 没挪动 = 点了一下：App 按目录打开（搜索结果里刚装、布局里还没有的也开得了，G14），文件夹就展开
      if let appID = drag.appID {
        if let app = app(id: appID) {
          onOpenApp(app)
        } else {
          NSSound.beep()
        }
      } else if let tile = layout.tiles.first(where: { $0.id == drag.tileID }) {
        open(tile)
      }
      return
    }
    pressEnteredJiggle = false
    let capacity = capacity
    let ghost = ghostCenter(drag)
    let tile = ghostTile(drag)
    if let folderID = openFolderID {
      let inside = folderPanelRect.insetBy(dx: -Self.folderHandoff, dy: -Self.folderHandoff)
        .contains(lastDragLocation)
      if inside, let appID = drag.appID {
        let index = drag.folderTarget ?? folderApps.filter { $0.id != appID }.count
        commit(
          layout.placing(
            appID, inFolder: folderID, page: folderPage, index: index, capacity: capacity))
        let final = folderApps.firstIndex { $0.id == appID }
        land(tile, from: ghost, to: final.map { folderCellCenter($0) })
        return
      }
      // 停在文件夹上打开了、没进面板就松手：关上文件夹，按主网格上原来的落点放
      closeFolder()
    }
    // 从文件夹里拖出来的：先拿出来（放在文件夹后面），再按主网格的落点挪
    var base = layout
    if let appID = drag.appID, drag.sourceFolder != nil,
      let source = layout.locateAnyApp(appID)?.folder
    {
      base = layout.draggingOut(appID, from: source, capacity: capacity)
    }
    // 停在图标中心够久（只有拖 App 才会有，G11）：目标格是文件夹就加进去，是 App 就建文件夹（F1 / F3）
    if let combine = drag.combineTileID, let appID = drag.appID,
      let targetTile = layout.tiles.first(where: { $0.id == combine })
    {
      let into = currentTiles.firstIndex { $0.id == combine }.flatMap {
        cellCenter(page: page, index: $0)
      }
      if let folder = targetTile.folder {
        commit(layout.adding(appID, to: folder.id, capacity: capacity))
        land(tile, from: ghost, to: into, shrink: true)
        return
      }
      if targetTile.app != nil {
        commit(
          base.folding(
            drag.tileID, onto: combine, name: folderNameFor(drag.tileID, target: targetTile),
            capacity: capacity))
        land(tile, from: ghost, to: into, shrink: true)
        return
      }
    }
    // 在最后一页的右边缘停够了：新开一页放它（G10）
    if drag.appendsPage {
      commit(base.moving(drag.tileID, toPage: base.pageCount, slot: 0, capacity: capacity))
      landing = nil
      return
    }
    let slot: Int
    if let target = drag.targetIndex {
      slot = target
    } else {
      slot = currentTiles.count - (currentTiles.contains { $0.id == drag.tileID } ? 1 : 0)
    }
    commit(base.moving(drag.tileID, toPage: page, slot: slot, capacity: capacity))
    let final = layout.locate(drag.tileID)
    land(
      tile, from: ghost,
      to: final.flatMap { $0.page == page ? cellCenter(page: page, index: $0.index) : nil })
  }

  /// Esc / 点空白取消：跟手的那一份滑回原位（还在原来那一页的话）
  func cancelDrag() {
    jiggleTask?.cancel()
    combineTask?.cancel()
    combineCandidate = nil
    cancelReflow()
    cancelTurn()
    gestureCancelled = true
    if let drag, drag.isDragging {
      // 原位还在屏上（没翻到别的页、从文件夹里拿的文件夹还开着）才滑回去
      let stillThere = drag.startPage == page && drag.sourceFolder == openFolderID
      let origin = CGPoint(
        x: drag.start.x + drag.grabOffset.width, y: drag.start.y + drag.grabOffset.height)
      land(ghostTile(drag), from: ghostCenter(drag), to: stillThere ? origin : nil, duration: 0.3)
    }
    withAnimation(Style.Motion.glide.animation()) { drag = nil }
  }

  /// 跟手那一份现在的中心（屏上）
  func ghostCenter(_ drag: LaunchpadDrag) -> CGPoint {
    CGPoint(
      x: drag.start.x + drag.translation.width + drag.grabOffset.width,
      y: drag.start.y + drag.translation.height + drag.grabOffset.height)
  }

  /// 手里拿的是哪一格（顶层的格子，或文件夹里的 App）
  func ghostTile(_ drag: LaunchpadDrag) -> LaunchpadTile? {
    if let tile = layout.tiles.first(where: { $0.id == drag.tileID }) { return tile }
    if let appID = drag.appID, let ref = layout.appRef(appID) { return .app(ref) }
    return nil
  }

  /// 那一份从 `from` 滑到 `to`（0.2 s，不弹；建文件夹时边滑边缩小淡掉）；`to` 为 nil（落到别的页）或减弱动态效果时不滑
  private func land(
    _ tile: LaunchpadTile?, from: CGPoint, to: CGPoint?, shrink: Bool = false,
    duration: Double = 0.2
  ) {
    landingID += 1
    guard let tile, let to, !Style.reduceMotion else {
      landing = nil
      return
    }
    let id = landingID
    landing = LaunchpadLanding(tile: tile, position: from, scale: 1.1, opacity: 1)
    // 先让界面按起点画一帧，再动
    Task { [weak self] in
      await Task.yield()
      guard let self, self.landingID == id else { return }
      withAnimation(.spring(duration: duration, bounce: 0)) {
        self.landing?.position = to
        self.landing?.scale = shrink ? 0.3 : 1
        if shrink { self.landing?.opacity = 0 }
      }
      // 到了就收掉（按时长等，不靠动画的完成回调：界面不在的时候它不一定来）
      try? await Task.sleep(for: .seconds(duration))
      guard self.landingID == id else { return }
      self.landing = nil
    }
  }

  /// 指针正停在哪个图标的中心上（`candidate` 是画在指针下面的那一格，G3）：停够 `dragTiming.combine` 出合成底板；
  /// 是文件夹的话再停 `dragTiming.folderOpen` 就打开它
  private func updateCombine(_ drag: inout LaunchpadDrag, candidate: String?) {
    guard candidate != combineCandidate else { return }
    combineCandidate = candidate
    combineTask?.cancel()
    drag.combineTileID = nil
    guard let candidate else { return }
    let timing = dragTiming
    combineTask = Task { [weak self] in
      try? await Task.sleep(for: timing.combine)
      guard !Task.isCancelled, let self, self.combineCandidate == candidate,
        self.drag?.isDragging == true
      else { return }
      self.drag?.combineTileID = candidate
      guard let folder = self.layout.tiles.first(where: { $0.id == candidate })?.folder else {
        return
      }
      try? await Task.sleep(for: timing.folderOpen)
      guard !Task.isCancelled, self.combineCandidate == candidate, self.drag?.isDragging == true
      else { return }
      self.openFolderForDrag(folder.id)
    }
  }

  private func scheduleTurn(to target: Int, after delay: Duration) {
    // 最后一页再往右：target == pageCount（新开一页），正常翻到前一页则要 >= 0
    guard target >= 0, target <= pageCount else { return }
    guard drag?.turnPage != target else { return }
    drag?.turnPage = target
    turnTask?.cancel()
    let repeatDelay = dragTiming.edgeRepeat
    turnTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, let drag, drag.turnPage == target else { return }
      guard target < pageCount else {
        // 最后一页的右边缘停够了：松手新开一页（G10；页点多出一个空的）
        self.drag?.appendsPage = true
        return
      }
      withAnimation(self.pageMotion) {
        page = target
        pageOffset = 0
      }
      // 翻页后落点按新页重新算（指针没动，落点变成新页的格子）
      self.cancelReflow()
      self.drag?.targetIndex = nil
      self.drag?.turnPage = nil
      self.combineCandidate = nil
      self.combineTask?.cancel()
      self.drag?.combineTileID = nil
      // 还停在边上：每隔一会儿接着翻（照 macOS 15，不用挪一下）
      self.updateEdge(self.lastDragLocation, pageWidth: self.lastPageWidth, delay: repeatDelay)
    }
  }

  private func cancelTurn() {
    turnTask?.cancel()
    turnTask = nil
    drag?.turnPage = nil
    drag?.appendsPage = false
  }

  /// 单测 / 随机测试用：把正停着的合成候选当成已经停够 0.4 秒（不等计时器）
  func armCombineForTesting() {
    guard let candidate = combineCandidate else { return }
    combineTask?.cancel()
    drag?.combineTileID = candidate
  }

  /// 建文件夹时的名字：两个 App 的分类（SPEC R4；第一个没分类时用目标那个的，F32）
  private func folderNameFor(_ tileID: String, target: LaunchpadTile?) -> String {
    let source = layout.tiles.first { $0.id == tileID }?.app.flatMap { app($0) }
    let targetApp = target?.app.flatMap { app($0) }
    guard let first = source ?? targetApp else { return LaunchpadLayout.untitledFolder }
    return folderName(first, targetApp ?? first)
  }

  // MARK: 布局

  /// 换一份布局（设置里恢复默认、撤销导入、删 App 之后）：当前页收回第一页，选中清掉
  func replace(layout: LaunchpadLayout) {
    self.layout = layout
    clampPage()
    selected = nil
    openFolderID = nil
    drag = nil
    deleteCandidate = nil
  }

  /// 布局变了（拖格子、建文件夹）：马上交给总控存盘（R5）
  func commit(_ layout: LaunchpadLayout) {
    self.layout = layout
    clampPage()
    selected = nil
    onLayoutChange(layout)
  }

  // MARK: 翻页手势

  /// 触控板两指左右滑、鼠标滚轮上下滚（SPEC R2，F17）：跟手 1:1、松手按位移和速度决定。
  /// 入口是面板的 sendEvent（不装全局 / 本地事件监听），phase / momentum 直接从 NSEvent 来。
  /// `time` 用 NSEvent.timestamp（单测自己给）；`inverted` 是系统「自然滚动」，事件的 delta 已经按它给了方向，
  /// 这里只收着（真机两种设置各验一次，见 HANDTEST）。
  func scroll(
    deltaX: CGFloat, deltaY: CGFloat, precise: Bool, phase: NSEvent.Phase,
    momentum: NSEvent.Phase, time: TimeInterval = ProcessInfo.processInfo.systemUptime,
    inverted: Bool = false
  ) {
    guard drag == nil else { return }
    // `scrollingDeltaY` 已经按系统「自然滚动」翻好了；`inverted` 只留作事件口径，不再翻一次（F44）
    // 触控板横向为主时按横向，鼠标滚轮按纵向
    let primary = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY
    if openFolderID != nil {
      scrollFolder(primary: primary, precise: precise, phase: phase, momentum: momentum, time: time)
      return
    }
    guard !displayPages.isEmpty, pageCount > 1 else { return }
    if phase == .began {
      scroll = 0
      pager.reset()
      scrollTask?.cancel()
    }
    // 惯性阶段不再跟手（松手那次已经决定了），只让它自然停
    if momentum != [] { return }
    if phase == .ended || phase == .cancelled {
      finishScroll(time: time)
      return
    }
    if !precise, phase == [] {
      // 鼠标滚轮：一格一页（F44；普通滚轮一格是 ±1）
      guard abs(primary) >= 0.5 else { return }
      // 普通滚轮一格 = 一页（F44）：content 向上（primary > 0）看下一页
      turn(primary > 0 ? 1 : -1)
      return
    }
    scroll += primary
    let offset = pager.feed(
      delta: primary, time: time, pageWidth: metrics.size.width,
      canBack: page > 0, canForward: page < pageCount - 1)
    withAnimation(Style.Motion.instant.animation()) {
      pageOffset = Style.reduceMotion ? 0 : offset
    }
    if phase == [] {
      scrollTask?.cancel()
      scrollTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        self?.finishScroll(time: ProcessInfo.processInfo.systemUptime)
      }
    }
  }

  private func scrollFolder(
    primary: CGFloat, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
    time: TimeInterval
  ) {
    guard folderPageCount > 1 else { return }
    if phase == .began { folderPager.reset() }
    if momentum != [] { return }
    if phase == .ended || phase == .cancelled {
      // 页宽用文件夹网格自己的宽（G28：原来用主网格的格宽 × 7，要拖满一整块屏才翻）。松手接着手指的速度滑到位
      let velocity = folderPager.screenVelocity(time: time)
      let step = folderPager.finish(
        canBack: folderPage > 0, canForward: folderPage < folderPageCount - 1,
        pageWidth: metrics.folderGridWidth, time: time)
      goToFolderPage(folderPage + step, velocity: velocity)
      return
    }
    if !precise, phase == [] {
      guard abs(primary) >= 0.5 else { return }
      goToFolderPage(folderPage + (primary > 0 ? 1 : -1))
      return
    }
    let offset = folderPager.feed(
      delta: primary, time: time,
      pageWidth: metrics.folderGridWidth,
      canBack: folderPage > 0, canForward: folderPage < folderPageCount - 1)
    withAnimation(Style.Motion.instant.animation()) {
      folderPageOffset = Style.reduceMotion ? 0 : offset
    }
  }

  /// 松手：翻过去或弹回来，都接着手指的速度滑到位（不是停一下再从静止起步）
  private func finishScroll(time: TimeInterval) {
    let velocity = pager.screenVelocity(time: time)
    let step = pager.finish(
      canBack: page > 0, canForward: page < pageCount - 1, pageWidth: metrics.size.width,
      time: time)
    turn(step, velocity: velocity)
    scroll = 0
  }

  /// 翻 `direction` 页（0 = 弹回这一页）；`velocity` 是松手时手指的速度（点 / 秒，和 pageOffset 同向），滚轮、键盘给 0
  private func turn(_ direction: Int, velocity: CGFloat = 0) {
    let target = min(max(page + direction, 0), pageCount - 1)
    // 屏上这一刻的位置是 -page × 页宽 + pageOffset，要滑到 -target × 页宽
    let distance = -CGFloat(target - page) * metrics.size.width - pageOffset
    let changed = target != page
    withAnimation(
      Style.reduceMotion ? nil : LaunchpadPager.animation(velocity: velocity, distance: distance)
    ) {
      page = target
      pageOffset = 0
      pager.reset()
      if changed { selected = nil }
    }
  }
}
