// 启动台一块屏的状态（界面读它、面板按键调它）：布局、本机 App、当前页、键盘选中的格子、搜索词、翻页的跟手偏移、
// 拖动 / 抖动 / 文件夹展开这些编辑状态，以及「打开一个 App」「收起」这些往上抛的回调。
// 纯展示状态和几何的常量在这里；布局的增删挪在 LaunchpadLayout，窗口和持久化在 Launchpad（总控）。
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

/// 一块屏上的网格尺寸（按屏幕大小算；SPEC R2）。比例照 macOS 15 的官方截图量（2026-10-18 真机反馈「和 macOS 15 差很多」）：
/// 7 × 5 时网格占屏宽 80%、屏高 79%，从 8% 屏高处开始（第一行图标中心约在 15%）；图标约屏宽的 5.4%；
/// 搜索框中心在 6.7% 屏高、宽约 1/6 屏宽；页点在 90.5%。行列数改了网格总面积不变，格子跟着缩放。
nonisolated struct LaunchpadMetrics {
  let size: CGSize
  let columns: Int
  let rows: Int

  var gridWidth: CGFloat { size.width * 0.80 }
  var gridHeight: CGFloat { size.height * 0.79 }
  /// 网格左右各留多少（网格在页容器里居中）
  var side: CGFloat { (size.width - gridWidth) / 2 }
  var cellWidth: CGFloat { gridWidth / CGFloat(max(columns, 1)) }
  var cellHeight: CGFloat { gridHeight / CGFloat(max(rows, 1)) }
  /// 图标边长：约屏宽的 5.4%，受格子限制（放得下图标 + 一行名字），最小 40、最大 140
  var icon: CGFloat {
    max(40, min(140, size.width * 0.054, cellWidth * 0.62, (cellHeight - 30) * 0.86))
  }
  var labelWidth: CGFloat { cellWidth - 14 }
  /// 名字的字号（macOS 15 是白色小字）
  static let labelSize: CGFloat = 11

  static let searchHeight: CGFloat = 28
  var searchWidth: CGFloat { max(200, size.width / 6) }
  /// 搜索框上沿
  var searchTop: CGFloat { max(12, size.height * 0.067 - Self.searchHeight / 2) }
  /// 网格上沿（矮屏上让开搜索框）
  var gridTop: CGFloat { max(size.height * 0.08, searchTop + Self.searchHeight + 8) }
  /// 页点的中心
  var dotsY: CGFloat { max(size.height * 0.905, gridTop + gridHeight + 8) }

  // 文件夹面板（照 macOS 15：在屏幕中间展开，图标和主网格一样大，G4 起格子宽高分开算）
  var folderIcon: CGFloat { icon }
  /// 名字那一行的高（11 pt 字）
  static let folderLabelHeight: CGFloat = 15
  /// 图标和名字之间
  static let folderLabelSpacing: CGFloat = 5
  /// 面板四边的留白
  static let folderPadding: CGFloat = 28
  /// 文件夹名那一行的高、和面板隔多少
  static let folderTitleHeight: CGFloat = 38
  static let folderTitleSpacing: CGFloat = 18
  /// 格子里那一组（选中底 1.22 倍 + 间距 + 一行字）竖着居中：图标中心比格子中心高多少（主网格和文件夹里都是 (6 + 14) / 2）
  static let iconLift: CGFloat = 10
  /// 格子宽：和主网格一样，屏太窄时收到面板放得下
  var folderCellWidth: CGFloat {
    min(
      cellWidth, (size.width - 48 - Self.folderPadding * 2) / CGFloat(LaunchpadLayout.folderColumns)
    )
  }
  var folderCellHeight: CGFloat {
    folderIcon * 1.22 + Self.folderLabelSpacing + Self.folderLabelHeight + 12
  }
  /// 名字最宽多少（比格子窄一点，两格的名字中间留缝）
  var folderLabelWidth: CGFloat { folderCellWidth - 14 }
  var folderGridWidth: CGFloat { folderCellWidth * CGFloat(LaunchpadLayout.folderColumns) }
}

/// 拖动的几个时长（照同类里最像 macOS 15 的那个取的数，2026-10-18；真值拿不到，真机手感不对就改这里）
nonisolated struct LaunchpadDragTiming: Sendable {
  /// 指针停多久别的图标才让位
  var reflow: Duration = .milliseconds(150)
  /// 停在图标中心多久算要合成（出底板）
  var combine: Duration = .milliseconds(400)
  /// 合成底板出来以后，停在文件夹上再过多久打开它（合起来约 1 s）
  var folderOpen: Duration = .milliseconds(600)
  /// 停在屏幕边上多久翻页
  var edgeDwell: Duration = .milliseconds(400)
  /// 一直停在边上，之后每隔多久再翻一页
  var edgeRepeat: Duration = .milliseconds(600)

  static let macOS15 = LaunchpadDragTiming()
  /// 单测：让位不等（指针一到落点就换上去），别的照旧
  static let immediate = LaunchpadDragTiming(reflow: .zero)
}

/// 松手 / 取消之后那份跟手的滑进落点（滑回原位）：界面按它画，到了就清掉
nonisolated struct LaunchpadLanding: Equatable {
  var tile: LaunchpadTile
  var position: CGPoint
  var scale: CGFloat
  var opacity: Double
}

nonisolated enum LaunchpadDirection {
  case left, right, up, down
}

/// 正在拖的那一格（R5）：起点、跟手的位移、算出来的落点、停在哪个图标中心上、要不要在边缘停着翻页。
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
  /// 当前页里的落点（拿掉这一格之后的插入位置；nil = 拖到空白处，放这一页末尾）
  var targetIndex: Int?
  /// 指针在某个图标的图标区中心停够了（要合成）：那一格的 id
  var combineTileID: String?
  /// 文件夹开着时（从里面拖出来的、或停在文件夹上打开的）落点：这一页里的第几格（nil = 末尾）
  var folderTarget: Int?
  /// 指针进过开着的文件夹面板没有（停在文件夹上打开时指针可能还在面板外：进去过再出来才算拖出去）
  var enteredFolder = false
  /// 跟手那一份的中心比指针偏多少（按下时指针在图标哪儿就一直在哪儿，不跳到中心）
  var grabOffset: CGSize = .zero
  /// 按下时在第几页（取消时只有还在这一页才滑回原位）
  var startPage = 0
  /// 停在左右边缘时准备翻到哪一页（== 页数 = 最后一页再往右）
  var turnPage: Int?
  /// 在最后一页的右边缘停够了：松手新开一页放它（G10）
  var appendsPage = false

  var offset: CGSize { translation }
  var isDragging: Bool { active }
}

/// 翻页的纯状态机（F17）：跟手 1:1、两头橡皮筋，松手按位移（页宽 1/3）或最后几帧的速度决定。
/// `travel` 向右为正（看上一页），向左为负（看下一页）；和页面的 `pageOffset` 同一个方向。
nonisolated struct LaunchpadPager: Equatable {
  private(set) var offset: CGFloat = 0
  private var travel: CGFloat = 0
  private var lastTime: TimeInterval = 0
  private var velocity: CGFloat = 0

  /// 快甩的阈值（点 / 秒）：真机上一段很短但很快的甩动也能翻
  static let flickVelocity: CGFloat = 650
  /// 到头那侧的橡皮筋最多露出页宽的多少
  static let resistance: CGFloat = 0.18

  mutating func reset() {
    offset = 0
    travel = 0
    lastTime = 0
    velocity = 0
  }

  /// 喂这一帧的横向位移（点）；返回跟手的偏移
  mutating func feed(
    delta: CGFloat, time: TimeInterval, pageWidth: CGFloat, canBack: Bool, canForward: Bool
  ) -> CGFloat {
    let width = max(pageWidth, 1)
    if lastTime == 0 {
      // 第一帧只记时间、不算速度：dt 夹成 4 ms 时一帧 6 pt 就是快甩，轻碰一下就翻页（G13）
      lastTime = time
    } else {
      let dt = max(time - lastTime, 0.004)
      lastTime = time
      velocity = velocity * 0.55 + (delta / CGFloat(dt)) * 0.45
    }
    travel += delta
    let allowed = travel < 0 ? canForward : canBack
    if !allowed {
      offset = (travel < 0 ? -1 : 1) * min(abs(travel) * Self.resistance, width * Self.resistance)
    } else if abs(travel) <= width {
      offset = travel
    } else {
      offset = (travel < 0 ? -1 : 1) * (width + (abs(travel) - width) * Self.resistance)
    }
    return offset
  }

  /// 手指停住多久以后，松手时不再算快甩（停住再抬 = 慢慢放，G13）
  static let flickWindow: TimeInterval = 0.08

  /// 位移过页宽的多少算翻（2026-10-18 交互对齐：轻轻一滑就翻；原来是 1/3）
  static let flipFraction: CGFloat = 0.2

  /// 松手：位移超过页宽 `flipFraction`、或者最后几帧够快就翻；返回 -1 上一页 / +1 下一页 / 0 回弹。
  /// 快甩按**速度**的方向：和位移方向相反（拖过去又往回甩）就回弹，不翻过去（G13）。`time` 是松手那一刻（nil = 最后一帧）
  mutating func finish(
    canBack: Bool, canForward: Bool, pageWidth: CGFloat, time: TimeInterval? = nil
  ) -> Int {
    let width = max(pageWidth, 1)
    let distance = abs(travel)
    let idle = time.map { $0 - lastTime } ?? 0
    let speed = idle > Self.flickWindow ? 0 : velocity
    let fast = abs(speed) >= Self.flickVelocity && distance > 4
    defer { reset() }
    guard distance > width * Self.flipFraction || fast else { return 0 }
    let byTravel = travel < 0 ? 1 : -1
    if fast, (speed < 0 ? 1 : -1) != byTravel { return 0 }
    let direction = byTravel
    if direction > 0, canForward { return 1 }
    if direction < 0, canBack { return -1 }
    return 0
  }
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
  /// 正在收起（界面据此缩回去）
  private(set) var isClosing = false
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
  /// 打开的文件夹从哪儿长出来：文件夹那一格图标的中心（不在这一页时 nil，界面就从中间淡入）
  private(set) var folderAnchor: CGPoint?

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
    withAnimation(Style.Motion.glide.animation()) {
      self.page = target
      pageOffset = 0
      pager.reset()
      selected = nil
    }
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
    folderAnchor = folderTileCenter(id)
    // 照 macOS 15 从文件夹图标那儿长到屏幕中间：0.24 s、不弹（关的时候同一条缩回去）
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = id
      folderPage = 0
      folderPageOffset = 0
      selected = nil
    }
    // 打开文件夹后接着打字不进背后的搜索框（F34）
    onSearchFocus(false)
  }

  func closeFolder() {
    let wasOpen = openFolderID != nil
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = nil
      folderPage = 0
      folderPageOffset = 0
      selected = nil
      drag = nil
    }
    cancelTurn()
    // 焦点还给搜索框：关掉文件夹后「一打字就进搜索」照常（G9）
    if wasOpen, !jiggling { onSearchFocus(true) }
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

  func goToFolderPage(_ page: Int) {
    folderPage = min(max(page, 0), folderPageCount - 1)
    folderPageOffset = 0
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
    onSearchFocus(false)
  }

  func exitJiggle() {
    guard jiggling else { return }
    withAnimation(Style.Motion.settle.animation()) { jiggling = false }
    jiggleByOption = false
    deleteCandidate = nil
    // 退出抖动后焦点还给搜索框（G9）
    if openFolderID == nil { onSearchFocus(true) }
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
    folderAnchor = folderTileCenter(id)
    folderNameDraft = folder(id)?.name ?? ""
    self.drag = drag
    withAnimation(Style.Motion.settle.animation()) {
      openFolderID = id
      folderPage = 0
      folderPageOffset = 0
      selected = nil
    }
    self.drag?.folderTarget = folderApps.filter { $0.id != drag.appID }.count
    onSearchFocus(false)
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

  /// 指针在一格里的哪一块：中心区（内缩 20%，合成用）/ 左半 / 右半
  nonisolated enum DropZone: Equatable {
    case before, center, after
  }

  nonisolated static func zone(
    of location: CGPoint, cell: Int, in frame: CGRect, metrics: LaunchpadMetrics, center: Bool
  ) -> DropZone {
    let rect = cellRect(cell, in: frame, metrics: metrics)
    if center, rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2).contains(location) {
      return .center
    }
    return location.x < rect.midX ? .before : .after
  }

  /// 指针在第 `cell` 格（画出来的位置）的 `zone` 里时，落点和合成候选怎么变（G3，纯函数）。
  /// 画出来的格子 = 拿掉被拖那格后的列表在 `gap` 处插了一个空位：空位前面第 c 格是列表的第 c 个，空位后面是第 c − 1 个。
  /// - 指针在空位上：都不变；
  /// - 在某个图标的左 / 右边上：插到它前 / 后（它自己不挪，指针下面的还是它，不会追着跑）；
  /// - 在它的中心区：它是合成候选，空位不动；
  /// - 在最后一个后面的空格子里：放到末尾。
  nonisolated static func dropTarget(cell: Int, zone: DropZone, gap: Int, count: Int) -> (
    target: Int?, combine: Int?
  ) {
    if cell == gap { return (nil, nil) }
    let index = cell < gap ? cell : cell - 1
    guard index < count else { return (count, nil) }
    switch zone {
    case .center: return (nil, index)
    case .before: return (index, nil)
    case .after: return (index + 1, nil)
    }
  }

  /// 第几格在页容器里的矩形（网格居中、两边各留 side）
  nonisolated static func cellRect(_ index: Int, in frame: CGRect, metrics: LaunchpadMetrics)
    -> CGRect
  {
    let insetX = max(0, (frame.width - metrics.gridWidth) / 2)
    let column = index % max(metrics.columns, 1)
    let row = index / max(metrics.columns, 1)
    return CGRect(
      x: frame.minX + insetX + CGFloat(column) * metrics.cellWidth,
      y: frame.minY + CGFloat(row) * metrics.cellHeight,
      width: metrics.cellWidth, height: metrics.cellHeight)
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

  /// 页容器里的坐标 → 第几格（纯函数，单测直接喂）。页容器是全宽的，网格居中、两边各留 side（F2）
  nonisolated static func cellIndex(
    at location: CGPoint, in frame: CGRect, metrics: LaunchpadMetrics
  ) -> Int? {
    let insetX = max(0, (frame.width - metrics.gridWidth) / 2)
    let x = location.x - frame.minX - insetX
    let y = location.y - frame.minY
    guard x >= 0, y >= 0, metrics.cellWidth > 0, metrics.cellHeight > 0 else { return nil }
    let column = Int(x / metrics.cellWidth)
    let row = Int(y / metrics.cellHeight)
    guard (0..<metrics.columns).contains(column), (0..<metrics.rows).contains(row) else {
      return nil
    }
    return row * metrics.columns + column
  }

  /// 指针是不是停在那一格的图标区中心附近（内缩 20%）。居中是「要合成」的判定之一（F1）
  nonisolated static func isInIconCenter(
    _ location: CGPoint, cell index: Int, in frame: CGRect, metrics: LaunchpadMetrics
  ) -> Bool {
    zone(of: location, cell: index, in: frame, metrics: metrics, center: true) == .center
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
      withAnimation(Style.Motion.glide.animation()) {
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
      // 页宽用文件夹网格自己的宽（G28：原来用主网格的格宽 × 7，要拖满一整块屏才翻）
      let step = folderPager.finish(
        canBack: folderPage > 0, canForward: folderPage < folderPageCount - 1,
        pageWidth: metrics.folderGridWidth, time: time)
      if step != 0 {
        goToFolderPage(folderPage + step)
      } else {
        withAnimation(Style.Motion.glide.animation()) { folderPageOffset = 0 }
      }
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

  private func finishScroll(time: TimeInterval) {
    let step = pager.finish(
      canBack: page > 0, canForward: page < pageCount - 1, pageWidth: metrics.size.width,
      time: time)
    if step != 0 {
      turn(step)
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
      pager.reset()
      selected = nil
    }
  }
}
