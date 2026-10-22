// 屏幕边缘那叠的界面读的状态（一块屏一份；PLAN §10「便签」第 3 批，规矩在 mac-overlay-panel §12）：
// 状态机 NoteDeckState、这一列画哪些标签和怎么排、哪张标签上停着鼠标、预览卡、拖动排序、打开的便签摆在哪。
// 不碰窗口：状态变了报给 NoteDeck（onChange），它去露出 / 收起面板、当 key、落盘。
// 打开着的那条便签自己的那一半——操作菜单、按键、对这条便签做的事、焦点、撤销栈、写入按编号落——在基类
// NoteSheetModel 里（浮动便签的 NoteFloatModel 是同一套）；这里只说那叠里的关法和把手：
// - 用键盘关（Esc、⌘W）= dismiss，连那一列一起收回；用鼠标关（关闭钮、它带着的标签）= close，回到那一列。
// - 悬停出的预览卡、悬停即打开，都先问一句「现在能不能扇出」（「一直展开」时那一列一直在，叫停靠的就是这一问）；
//   悬停打开的不抢键盘（takesKey 是 false：停着不动的鼠标不该把键盘拿走，点进正文才当 key）。
// - 「新建便签」落在已经开着的那条上时照样再要一次焦点（open(created:)）。
// - **浮动便签**（第 4 批）：按着打开的便签的把手（它带着的那张标签、头部的空白处）往外拖，过了阈值它就脱出来、
//   变成跟着鼠标走的浮动面板（onDetach → NoteFloat）。**鼠标松开之前，它在这叠里的那一份留着不拆**（拆了正在拖的
//   手势就断了），只是看不见（liftedID）；松手才从这叠里收掉。不靠拖的路是操作菜单的「浮在屏幕上」（toggleFloating）。
//   已经浮着的那条（floatingID）点它的标签是把浮着的叫到前面，不在这叠里再开一份。
// - **右键菜单**（手测反馈第 3 批）：右键一张标签是这条便签的操作（tabItems：固定、颜色、浮在屏幕上、归档、删除，
//   不用先打开它）；右键标签列的空白处、「+」、药丸是同一份三项（edgeItems：新建便签、全部便签、设置…）。都是系统菜单；
//   菜单开着时这一列不收（isShowingMenu：不算「4 秒没动静」、鼠标出了热区也不算走了、点别处也不算），关了照常。

import AppKit
import Observation
import SwiftUI

@Observable final class NoteDeckModel: NoteSheetModel {
  /// 正拖着的那张标签：从第几格拖起、拖了多远（往下为正）、现在落在第几格
  struct Drag: Equatable {
    var id: String
    var from: Int
    var offset: CGFloat
    var target: Int
  }

  /// 鼠标停在标签上多久出预览卡、离开多久收、「悬停即打开」要停多久
  static let previewDelay: Duration = .milliseconds(180)
  static let previewLinger: Duration = .milliseconds(150)
  static let hoverOpenDelay: Duration = .milliseconds(400)

  private(set) var state = NoteDeckState()
  var options = NoteDeckOptions() {
    didSet {
      guard options.alwaysFanned != state.alwaysFanned else { return }
      let old = state
      state.setAlwaysFanned(options.alwaysFanned)
      transitioned(from: old)
    }
  }
  var edge = NoteDeckOptions.Edge.right
  /// 面板多大、药丸的中线离面板顶多远（NoteDeck 摆窗口时给）
  var panelSize = CGSize.zero
  var pillCenter: CGFloat = 0
  /// 标签露出来了（出场是一张接一张滑出来：面板先露出、下一拍才置真）
  private(set) var isRevealed = false
  /// 鼠标停在哪张标签上、出着谁的预览卡
  private(set) var hovered: String?
  private(set) var preview: String?
  private(set) var drag: Drag?
  /// 打开的便签的顶离面板顶多远：**打开那一刻定住**（它对着自己那张标签，而标签露出多长跟着最长的标题实时变——
  /// 不定住的话打第一行字时便签自己一跳一跳地上下挪）。关掉再开、面板大小变了才重算
  private(set) var openTop: CGFloat?
  /// 浮在屏幕上的那条便签（NoteEdge 跟着浮动便签的状态设，floated）：它的标签上有记号，点它是把浮着的那张叫到前面
  private(set) var floatingID: String?
  /// 被拖出去的那条：鼠标还按着时，它在这叠里的那一份留着不拆、只是看不见；松手后那一份淡出的 0.1 秒里也不露出来。
  /// 下次在这叠里打开便签时清掉
  private(set) var liftedID: String?

  /// 状态变了（NoteDeck 据此动窗口）；有动静（4 秒没动静才收回，热区也跟着重算）
  @ObservationIgnored var onChange: (NoteDeckState, NoteDeckState) -> Void = { _, _ in }
  @ObservationIgnored var onActivity: () -> Void = {}
  /// 现在能不能扇出（没在截图框选 / 长截图 / 录屏选区和倒数 / 状态屏）：悬停出预览卡、悬停即打开之前问
  @ObservationIgnored var canFan: () -> Bool = { true }
  /// 右键菜单里的「全部便签」（「设置…」是基类的 showSettings）
  @ObservationIgnored var showNotes: () -> Void = {}
  /// 标签右键菜单里的「浮在屏幕上 / 收回边缘」（没打开的那条；NoteEdge 接到 NoteFloat.toggle）
  @ObservationIgnored var toggleFloat: (String) -> Void = { _ in }
  /// 右键菜单（标签的、空白处的、「+」的）正开着：这时这一列不收
  @ObservationIgnored private(set) var isShowingMenu = false
  /// 浮动便签那边的事（NoteDeck / NoteEdge 接到 NoteFloat）：把浮着的那张叫到前面；把开着的这条浮到屏幕上（不靠拖）；
  /// 拖出来的三步——脱出来了（哪条、鼠标在哪）、跟着走、松手
  @ObservationIgnored var focusFloat: () -> Void = {}
  @ObservationIgnored var onFloat: (String) -> Void = { _ in }
  @ObservationIgnored var onDetach: (String, CGPoint) -> Void = { _, _ in }
  @ObservationIgnored var onDetachDrag: (CGPoint) -> Void = { _ in }
  @ObservationIgnored var onDetachDrop: (CGPoint) -> Void = { _ in }
  /// 这一次打开要不要当 key、把焦点放进正文：点开的要，悬停打开的不要（NoteDeck 在状态变了的那一下读）
  @ObservationIgnored private(set) var takesKey = true
  /// 悬停的那一下（出预览卡、收预览卡、悬停即打开）：一次只等一件
  @ObservationIgnored private var hoverTask: Task<Void, Never>?
  /// 正按着打开的便签的把手：按下的地方、鼠标最后在哪（都是全局坐标）、脱没脱出来
  @ObservationIgnored private var grip: (start: CGPoint, last: CGPoint, isDetached: Bool)?

  /// 正把一条便签往外拖、还没松手（它在这叠里的那一份这时不能拆）
  var isDetaching: Bool { grip?.isDetached == true }

  // MARK: 打开的便签（NoteSheetModel 问的）

  override var noteID: String? { state.openID }
  /// ⌘W 在只扇着时也管用（收回那一列）
  override var isShown: Bool { state.phase != .rest }
  override func close() { send(.close) }
  override func dismiss() { send(.dismiss) }

  /// 操作菜单的「浮在屏幕上」：不靠拖的那条路（键盘、旁白用户）。它在这叠里的那一份由 NoteEdge 跟着收掉
  override func toggleFloating() {
    guard let note = current else { return }
    closeMenu()
    onFloat(note.id)
  }

  /// 按着把手拖：没过阈值什么都不动；过了，这条便签脱出来（之后每一下都是让浮动面板跟着走）。脱出来之后它在这叠里
  /// 的那一份不拆——手势是从那一份上开始的，拆了就断——只是看不见（liftedID）
  override func gripChanged(at pointer: CGPoint) {
    guard let id = state.openID else { return }
    guard let held = grip else {
      // 第一下：按下的地方
      grip = (pointer, pointer, false)
      return
    }
    grip?.last = pointer
    if held.isDetached { return onDetachDrag(pointer) }
    guard NoteFloatLayout.detaches(from: held.start, to: pointer) else { return }
    grip?.isDetached = true
    closeMenu()
    liftedID = id
    onDetach(id, pointer)
  }

  /// 手还按着拖出去的那条，它在这叠里的那一份却要没了（这边被关了、这块屏的那叠不放了）：拖着的手势跟着断，
  /// 不会再有「松手」——当成在鼠标最后的位置松了手，浮动面板落在那里，不卡在「拖着」。
  /// pointer：鼠标其实已经松开了、手势却没报（NoteDeck 的松开监听兜底）——在松开的地方落
  func releaseGrip(at pointer: CGPoint? = nil) {
    guard let held = grip, held.isDetached else { return }
    grip = nil
    onDetachDrop(pointer ?? held.last)
  }

  /// 松手：脱出来了的落在这里，这叠里它原来的位置收掉；没过阈值 = 没拖——按在标签上、没挪开的是点了一下（关便签）
  override func gripEnded(_ part: Grip, at pointer: CGPoint) {
    let held = grip
    grip = nil
    if let held, held.isDetached {
      onDetachDrop(pointer)
      send(.close)
    } else if part == .tab, !NoteFloatLayout.moved(from: held?.start ?? pointer, to: pointer) {
      close()
    }
  }

  // MARK: 状态

  func send(_ event: NoteDeckState.Event) {
    let old = state
    if state.handle(event) { transitioned(from: old) }
  }

  private func transitioned(from old: NoteDeckState) {
    if old.openID != state.openID {
      // 正往外拖着的那条在这边被关了（Esc、被叫停）：它那一份要拆了、手势跟着断。没脱出来、只是按着的也清掉——
      // 视图拆了 SwiftUI 不报 onEnded，留着旧的起点，下一条便签的第一下按住就被当成拖了很远
      releaseGrip()
      grip = nil
      sheetChanged(to: state.openID)
      // 先清再算：算的时候要按「标签现在排在哪」重新来
      openTop = nil
      if state.openID != nil {
        openTop = noteTop(layout)
        liftedID = nil
      }
    }
    if state.phase != .fanned { clearHover() }
    if !state.isDragging, drag != nil { drag = nil }
    onChange(old, state)
  }

  func setRevealed(_ revealed: Bool) {
    if isRevealed != revealed { isRevealed = revealed }
  }

  /// 仓库里的便签变了：打开着的那条被别处删了、归档了就关掉；预览卡指着的那条没了也收
  func reconcile() {
    if state.openID != nil, current == nil { send(.close) }
    if let preview, !tabs.contains(where: { $0.id == preview }) { setPreview(nil) }
  }

  /// 别的屏的那叠要展开了：这块屏扇着的收起，打开的只收没固定的
  func yield() {
    send(.yield(pinned: current?.isPinned ?? false))
  }

  /// 浮在屏幕上的换了一条 / 没有了（NoteEdge 转过来）。刚浮出去的那条还开在这叠里就从这叠里收掉——同一条便签不留
  /// 两个正文框；**正被拖着的不收**：它在这叠里的那一份要留到松手（拆了拖着的手势就断了），松手时自己收（gripEnded）
  func floated(_ id: String?) {
    if floatingID != id { floatingID = id }
    if let id, state.openID == id, !isDetaching { send(.close) }
  }

  // MARK: 这一列

  /// 没归档、没删的全部，按顺序
  var notes: [Note] { store.active }

  /// 画出来的标签：平时最多 fanLimit 张，点了「+N」是全部。
  /// ponytail: 展开后一次画全部（每张一个悬停追踪区），在视口里滚；便签上限 5000 条，几百条以内没事，卡了换成只画
  /// 可见区附近的那些（Shell/ListReveal 的 ListWindow，剪贴板列表的做法）。拖动排序拖到视口外也不自动滚
  var tabs: [Note] {
    state.showsAll ? notes : Array(notes.prefix(NoteDeckLayout.fanLimit))
  }

  var previewNote: Note? { preview.flatMap { id in tabs.first { $0.id == id } } }

  /// 一列的排法。露出的一截跟着最长的标题走：标题取仓库的缓存（NoteStore.summary），量出来的最长那一截按「这一列的
  /// 标题 + 大小档」记下来（longestMemo）——「+N」展开成几百张时，每次状态变化都要把几百个标题量好几遍
  /// （手测反馈第 3 批屏外量的）
  var layout: NoteDeckLayout {
    let tabs = tabs
    let metrics = NoteDeckMetrics(scale: options.size.scale)
    var longest: CGFloat = 0
    if options.style == .tabs {
      let titles = tabs.map { store.summary(of: $0).title }
      if let memo = longestMemo, memo.scale == metrics.scale, memo.titles == titles {
        longest = memo.longest
      } else {
        longest = titles.map { NoteDeckLabel.length($0, metrics: metrics) }.max() ?? 0
        longestMemo = (titles, metrics.scale, longest)
      }
    }
    return NoteDeckLayout(
      count: tabs.count, hidden: notes.count - tabs.count, longestLabel: longest,
      height: panelSize.height, options: options)
  }

  /// 上次量过的：那一列的标题、大小档、最长的一截
  @ObservationIgnored private var longestMemo: (titles: [String], scale: CGFloat, longest: CGFloat)?

  /// 标签列的顶离面板顶多远
  func columnTop(_ layout: NoteDeckLayout) -> CGFloat {
    NoteDeckLayout.columnTop(
      pillCenter: pillCenter, columnHeight: layout.columnHeight, panelHeight: panelSize.height)
  }

  /// 打开的便签多大
  func noteSize(_ layout: NoteDeckLayout) -> CGSize {
    NoteDeckLayout.noteSize(options.noteSize.size, in: panelSize, tabWidth: layout.tabWidth)
  }

  /// 打开的便签的顶离面板顶多远：打开那一刻定住的（openTop）；还没定就现算——对着它自己那张标签，它不在这一列里
  /// 就对着药丸
  func noteTop(_ layout: NoteDeckLayout) -> CGFloat {
    if let openTop { return openTop }
    let index = tabs.firstIndex { $0.id == state.openID }
    return NoteDeckLayout.noteTop(
      tabCenter: index.map { columnTop(layout) + layout.tabCenter($0) } ?? pillCenter,
      noteHeight: noteSize(layout).height, panelHeight: panelSize.height)
  }

  /// 面板大小、便签大小变了（换了设置、屏幕变了）：定住的位置按新的重算一次
  func relayout() {
    guard state.openID != nil else { return }
    openTop = nil
    openTop = noteTop(layout)
  }

  /// 面板里真有东西的那一块（全局坐标；panel 是面板在屏幕上的位置）：打开着便签就是那张便签，扇着是标签列，
  /// 静置（面板收着、或正在收）是 .zero——截图的悬停列表按它算（ScreenCapture.OwnWindow.content：.zero 的不进列表，
  /// nil 才是「整个窗口」）
  func contentFrame(in panel: CGRect) -> CGRect {
    guard state.phase != .rest else { return .zero }
    let layout = layout
    if current != nil {
      return NoteDeckLayout.noteFrame(
        panel: panel, edge: edge, top: noteTop(layout), size: noteSize(layout),
        tabWidth: layout.tabWidth)
    }
    return NoteDeckLayout.columnFrame(
      panel: panel, edge: edge, top: columnTop(layout), height: layout.columnHeight,
      width: layout.tabWidth)
  }

  /// 热区（全局坐标）：标签列四周 20 pt，预览卡出着时连它
  func hotZone(in panel: CGRect) -> CGRect {
    let layout = layout
    return NoteDeckLayout.hotZone(
      panel: panel, edge: edge, columnTop: columnTop(layout), columnHeight: layout.columnHeight,
      tabWidth: layout.tabWidth, showsPreview: preview != nil)
  }

  // MARK: 标签

  /// 点了一张标签：打开它（当 key、焦点进正文）；打开着的就是它 = 关（回到扇出）。它正浮在屏幕上：把浮着的那张
  /// 叫到前面、给它键盘，不在这叠里再开一份（同一条便签两个正文框）
  func tapTab(_ id: String) {
    onActivity()
    if id == floatingID { return focusFloat() }
    send(.tab(id))
  }

  /// 鼠标进出一张标签：停一会儿出预览卡（「悬停即打开」开着时是打开，不出预览卡），离开一会儿收。
  /// 这时不许扇出（截图框选、录屏倒数、状态屏）就都不做。不是扇着的时候什么都不做、也不算动静——面板被放掉、
  /// 标签的视图移出窗口时 HoverTracker 还会补报一个「移出」（NoteDeck.releasePanel）
  func hover(_ id: String, _ inside: Bool) {
    guard state.phase == .fanned else { return }
    onActivity()
    guard drag == nil else { return }
    guard inside else {
      // 从一张挪到下一张，系统可能先报「进了下一张」再报「出了这一张」：出的不是现在停着的那张就不管，
      // 别把刚给下一张排的预览卡 / 悬停打开取消掉
      guard hovered == id else { return }
      hovered = nil
      hoverTask?.cancel()
      if preview != nil { hoverTask = after(Self.previewLinger) { $0.setPreview(nil) } }
      return
    }
    guard canFan() else { return }
    hoverTask?.cancel()
    hovered = id
    if options.opensOnHover {
      hoverTask = after(Self.hoverOpenDelay) { $0.openFromHover(id) }
    } else if options.showsPreview, preview != id {
      hoverTask = after(Self.previewDelay) { $0.setPreview(id) }
    }
  }

  /// 悬停够久了：打开，但不抢键盘（这时还得能扇出才开）。浮在屏幕上的那条不开（鼠标停一下不该把它叫过来）
  func openFromHover(_ id: String) {
    guard canFan(), state.phase == .fanned, id != floatingID else { return }
    takesKey = false
    defer { takesKey = true }
    send(.tab(id))
  }

  /// 鼠标进出预览卡：停在卡上就不收
  func hoverPreview(_ inside: Bool) {
    onActivity()
    hoverTask?.cancel()
    if !inside, preview != nil { hoverTask = after(Self.previewLinger) { $0.setPreview(nil) } }
  }

  /// 出 / 收预览卡（停够久了、离开够久了；截图自检直接摆）。热区跟着变（连不连预览卡）
  func setPreview(_ id: String?) {
    guard preview != id else { return }
    preview = id
    onActivity()
  }

  private func clearHover() {
    hoverTask?.cancel()
    hoverTask = nil
    if hovered != nil { hovered = nil }
    if preview != nil { preview = nil }
  }

  private func after(
    _ delay: Duration, _ work: @escaping (NoteDeckModel) -> Void
  ) -> Task<Void, Never> {
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, state.phase == .fanned else { return }
      work(self)
    }
  }

  /// 按着标签挪：过了 dragSlop 才算拖动排序，之后别的标签给它让位
  func dragChanged(_ id: String, by offset: CGFloat) {
    onActivity()
    if drag == nil {
      guard abs(offset) > NoteDeckLayout.dragSlop, state.phase == .fanned,
        let from = tabs.firstIndex(where: { $0.id == id })
      else { return }
      clearHover()
      drag = Drag(id: id, from: from, offset: offset, target: from)
      send(.dragBegan)
    }
    guard var current = drag, current.id == id else { return }
    current.offset = offset
    current.target = NoteDeckLayout.dragTarget(
      from: current.from, offset: offset, step: layout.step, count: tabs.count)
    drag = current
  }

  /// 松手：拖过的落到目标格（NoteStore.move），没挪开的就是点了一下
  func dragEnded(_ id: String, by offset: CGFloat) {
    guard let current = drag, current.id == id else {
      if abs(offset) <= NoteDeckLayout.dragSlop { tapTab(id) }
      return
    }
    drag = nil
    send(.dragEnded)
    if current.target != current.from { store.move(id, to: current.target) }
  }

  // MARK: 右键菜单

  /// 右键标签列的空白处、「+」、药丸（三处同一份）：新建便签（就在这一叠里打开）、全部便签、设置…（落在设置的
  /// 「便签」页）。前面是家族色的符号（系统菜单，非模板图）
  var edgeItems: [ActionMenu.Item] {
    func icon(_ symbol: String, _ color: Color) -> NSImage? {
      NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(hierarchicalColor: NSColor(color)))
    }
    return [
      ActionMenu.Item(
        title: HotKeyAction.noteNew.title,
        image: icon(HotKeyAction.noteNew.symbol, Style.Family.notes)
      ) { [unowned self] in create() },
      ActionMenu.Item(
        title: HotKeyAction.noteAll.title,
        image: icon(HotKeyAction.noteAll.symbol, Style.Family.notes)
      ) { [unowned self] in showNotes() },
      ActionMenu.Item(
        title: "设置…", image: icon("gearshape", Style.Family.general), section: 1
      ) { [unowned self] in showSettings() },
    ]
  }

  /// 右键一张标签：这条便签的操作，不用先打开它——固定、颜色 ›、浮在屏幕上（它正浮着时是收回边缘）｜归档、删除
  /// （危险色）。名字取自 NotesWindowModel 的那一份（同操作菜单、全部便签窗口）；任务、查找这类要正文光标的不放。
  /// 反馈同操作菜单（固定、换色、归档只播报，删除弹岛）。只用传进来的值（标签的界面拿它挂旁白的自定义动作，
  /// 别让每张标签都盯着仓库）
  /// colors 是 false 时不带「颜色」那一级（标签的旁白「更多动作」：每次重画都要，色点的图和最近用过不白建）
  func tabItems(_ note: Note, isFloating: Bool, colors: Bool = true) -> [ActionMenu.Item] {
    typealias Names = NotesWindowModel
    let id = note.id
    let palette =
      colors
      ? NotePaper.colorItems(
        current: note.color, recent: recentColors(),
        choose: { [unowned self] in setColor($0, of: id) },
        other: { [unowned self] in pickColor(id) }) : []
    return [
      ActionMenu.Item(title: Names.pinTitle(note)) { [unowned self] in togglePinned(id) },
      ActionMenu.Item(title: Names.colorTitle, submenu: palette),
      ActionMenu.Item(title: Names.floatTitle(isFloating: isFloating)) { [unowned self] in
        floatFromTab(id)
      },
      ActionMenu.Item(title: Names.archiveTitle(note), section: 1) { [unowned self] in archive(id)
      },
      ActionMenu.Item(title: Names.deleteTitle, section: 1, isDestructive: true) {
        [unowned self] in delete(id)
      },
    ]
  }

  /// 右键时用的那一份：按仓库里这条现在的样子（没了、归档了、删了就没有菜单）
  func tabItems(_ id: String) -> [ActionMenu.Item] {
    guard let note = target(id) else { return [] }
    return tabItems(note, isFloating: id == floatingID)
  }

  /// 标签右键菜单里的「浮在屏幕上 / 收回边缘」：开着的这条走操作菜单那条路（从它现在的位置浮出去），别的交给浮动便签
  /// （浮着的就收回，没浮着的在鼠标所在屏的正中淡入）
  private func floatFromTab(_ id: String) {
    if id == state.openID { toggleFloating() } else { toggleFloat(id) }
  }

  /// 右键菜单开了 / 关了（ActionSystemMenu 弹出时同步报）：开着时这一列不收；关了算一次动静，之后照常
  func menuShown(_ shown: Bool) {
    isShowingMenu = shown
    if !shown { onActivity() }
  }

  /// 标签列下的「+」：建一条（最前面那条还是空白的就用它）并在这叠里打开
  func create() {
    open(created: store.blankOrNew().id)
  }

  /// 在这叠里打开刚建的那条（全局动作「新建便签」也走这里）。它本来就开着（复用的空白便签）时状态没变、
  /// 面板却可能不是 key（人在别的 App 里按的快捷键）：照样把焦点放进正文。复用的那条空白便签正浮在屏幕上：
  /// 叫到前面就行
  func open(created id: String) {
    if id == floatingID { return focusFloat() }
    let wasOpen = state.openID == id
    send(.created(id))
    if wasOpen { requestFocus() }
  }
}
