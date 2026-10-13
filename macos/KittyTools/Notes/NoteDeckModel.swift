// 屏幕边缘那叠的界面读的状态（一块屏一份；PLAN §10「便签」第 3 批，规矩在 mac-overlay-panel §12）：
// 状态机 NoteDeckState、这一列画哪些标签和怎么排、哪张标签上停着鼠标、预览卡、拖动排序、打开的便签摆在哪、
// 操作菜单、按键、对这条便签做的事。不碰窗口：状态变了报给 NoteDeck（onChange），它去露出 / 收起面板、当 key、落盘。
// - **写标题、正文按传进来的编号落**（setTitle / setBody 的 of:），不按「现在开着哪条」：换一条时旧的输入框还在视图树里
//   留一小会儿，它晚到的那一下得落回它自己那条。
// - 用键盘关（Esc、⌘W）= dismiss，连那一列一起收回；用鼠标关（关闭钮、它带着的标签）= close，回到那一列。
// - 悬停出的预览卡、悬停即打开，都先问一句「现在能不能扇出」（「一直展开」时那一列一直在，叫停靠的就是这一问）；
//   悬停打开的不抢键盘（takesKey 是 false：停着不动的鼠标不该把键盘拿走，点进正文才当 key）。
// - 每条便签一个撤销栈（textUndo，面板的 undoManager 就是它）：换一条换一个新的。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@Observable final class NoteDeckModel {
  /// 开着的操作菜单（⌘K、「⋯」、纸色圆点；画的是 Shell/ActionMenu）
  struct Menu: Equatable {
    /// 在「颜色」那一级
    var inColors = false
    var selection = 0
    /// 从纸色圆点点开的：直接是颜色那一级，长在圆点下面（否则长在「⋯」下面）
    var fromDot = false
  }

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

  let store: NoteStore
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
  private(set) var menu: Menu?
  /// 正文打到上限了、这一次输入没进（底下那行小字换成警告）
  private(set) var isOverLimit = false
  /// 打开的便签的顶离面板顶多远：**打开那一刻定住**（它对着自己那张标签，而标签露出多长跟着最长的标题实时变——
  /// 不定住的话打第一行字时便签自己一跳一跳地上下挪）。关掉再开、面板大小变了才重算
  private(set) var openTop: CGFloat?

  @ObservationIgnored var island: Island?
  /// 状态变了（NoteDeck 据此动窗口）；有动静（4 秒没动静才收回，热区也跟着重算）；把焦点放进正文；操作菜单开关了
  @ObservationIgnored var onChange: (NoteDeckState, NoteDeckState) -> Void = { _, _ in }
  @ObservationIgnored var onActivity: () -> Void = {}
  @ObservationIgnored var focusBody: () -> Void = {}
  @ObservationIgnored var onMenu: (Bool) -> Void = { _ in }
  /// 现在能不能扇出（没在截图框选 / 长截图 / 录屏选区和倒数 / 状态屏）：悬停出预览卡、悬停即打开之前问
  @ObservationIgnored var canFan: () -> Bool = { true }
  /// 在「全部便签」里打开这条；「+」右键菜单里的「全部便签」「设置…」
  @ObservationIgnored var showInWindow: (String) -> Void = { _ in }
  @ObservationIgnored var showNotes: () -> Void = {}
  @ObservationIgnored var showSettings: () -> Void = {}
  /// 这一次打开要不要当 key、把焦点放进正文：点开的要，悬停打开的不要（NoteDeck 在状态变了的那一下读）
  @ObservationIgnored private(set) var takesKey = true
  /// 打开着的这条便签的撤销栈（标题框和正文框共用，面板的 undoManager 就是它）。换一条换一个新的：上一条里打的字
  /// 不能在这一条里被 ⌘Z 撤到（同 NotesWindowModel.textUndo）
  @ObservationIgnored private(set) var textUndo = UndoManager()
  /// 悬停的那一下（出预览卡、收预览卡、悬停即打开）：一次只等一件
  @ObservationIgnored private var hoverTask: Task<Void, Never>?

  init(store: NoteStore) { self.store = store }

  // MARK: 状态

  func send(_ event: NoteDeckState.Event) {
    let old = state
    if state.handle(event) { transitioned(from: old) }
  }

  private func transitioned(from old: NoteDeckState) {
    if old.openID != state.openID {
      if menu != nil { closeMenu() }
      if isOverLimit { isOverLimit = false }
      textUndo = UndoManager()
      // 先清再算：算的时候要按「标签现在排在哪」重新来
      openTop = nil
      if state.openID != nil { openTop = noteTop(layout) }
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

  // MARK: 这一列

  /// 没归档、没删的全部，按顺序
  var notes: [Note] { store.active }

  /// 画出来的标签：平时最多 fanLimit 张，点了「+N」是全部。
  /// ponytail: 展开后一次画全部（每张一个悬停追踪区），在视口里滚；便签上限 5000 条，几百条以内没事，卡了换成只画
  /// 可见区附近的那些（Shell/ListReveal 的 ListWindow，剪贴板列表的做法）。拖动排序拖到视口外也不自动滚
  var tabs: [Note] {
    state.showsAll ? notes : Array(notes.prefix(NoteDeckLayout.fanLimit))
  }

  /// 打开着的那条（已经不是「没归档没删的」就不算）
  var current: Note? {
    state.openID.flatMap(store.note).flatMap { $0.deletedAt == nil && !$0.isArchived ? $0 : nil }
  }

  var previewNote: Note? { preview.flatMap { id in tabs.first { $0.id == id } } }

  /// ponytail: 每次都把这几张的标题量一遍（十来次文字测量，微秒级）；标签上百张、卡了再按「编号 + 修订号」存下来
  var layout: NoteDeckLayout {
    let tabs = tabs
    let metrics = NoteDeckMetrics(scale: options.size.scale)
    let longest =
      options.style == .tabs
      ? tabs.map { NoteDeckLabel.length($0.displayTitle, metrics: metrics) }.max() ?? 0 : 0
    return NoteDeckLayout(
      count: tabs.count, hidden: notes.count - tabs.count, longestLabel: longest,
      height: panelSize.height, options: options)
  }

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

  /// 点了一张标签：打开它（当 key、焦点进正文）；打开着的就是它 = 关（回到扇出）
  func tapTab(_ id: String) {
    onActivity()
    send(.tab(id))
  }

  /// 鼠标进出一张标签：停一会儿出预览卡（「悬停即打开」开着时是打开，不出预览卡），离开一会儿收。
  /// 这时不许扇出（截图框选、录屏倒数、状态屏）就都不做
  func hover(_ id: String, _ inside: Bool) {
    onActivity()
    guard state.phase == .fanned, drag == nil else { return }
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

  /// 悬停够久了：打开，但不抢键盘（这时还得能扇出才开）
  func openFromHover(_ id: String) {
    guard canFan(), state.phase == .fanned else { return }
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

  /// 标签列下的「+」：建一条（最前面那条还是空白的就用它）并在这叠里打开
  func create() {
    open(created: store.blankOrNew().id)
  }

  /// 在这叠里打开刚建的那条（全局动作「新建便签」也走这里）。它本来就开着（复用的空白便签）时状态没变、
  /// 面板却可能不是 key（人在别的 App 里按的快捷键）：照样把焦点放进正文
  func open(created id: String) {
    let wasOpen = state.openID == id
    send(.created(id))
    if wasOpen { focusBody() }
  }

  // MARK: 打开的便签

  /// 标题、正文的每一次改动。**按传进来的编号写**（哪个输入框的就落哪条），那条已经不在了就不写（仓库自己不认）
  func setTitle(_ title: String, of id: String) {
    store.setTitle(title, of: id)
  }

  func setBody(_ body: String, of id: String) {
    if isOverLimit, id == state.openID { isOverLimit = false }
    store.setBody(body, of: id)
  }

  /// 正文框拦下了会超上限的一次输入
  func overflowed() {
    isOverLimit = true
    Island.announce(NotesWindowModel.overLimitText)
  }

  /// Esc：操作菜单开着先退它（颜色那一级退回上一级），再按才关——用键盘关的连那一列一起收回，键盘当场回原来的 App
  func cancel() {
    if menu != nil { menuBack() } else { send(.dismiss) }
  }

  /// ⌘P：固定 / 取消固定（固定的点别处不收、别的屏展开时也不收）
  func togglePinned() {
    guard let note = current else { return }
    store.setPinned(!note.isPinned, of: note.id)
    Island.announce(note.isPinned ? "已取消固定" : "已固定")
  }

  /// ⌘.：换下一种纸色
  func cycleColor() {
    if let note = current { setColor(NotesWindowModel.nextColor(after: note.color)) }
  }

  func setColor(_ color: Int) {
    guard let note = current else { return }
    store.setColor(color, of: note.id)
    Island.announce(NotePaper.all[Note.clamped(color: color)].name)
  }

  /// ⇧⌘A：归档（回到扇出；要找回到「全部便签」的「归档」里）
  func archive() {
    guard let note = current else { return }
    send(.close)
    store.setArchived(true, of: note.id)
    Island.announce("已归档")
  }

  /// 删除：进「最近删除」。这里没有列表、也没有 ⌘Z，放回的路由岛说
  func delete() {
    guard let note = current else { return }
    send(.close)
    store.delete(note.id)
    island?.show("已删除", detail: "到「全部便签」的「最近删除」里放回", symbol: "trash.circle.fill")
  }

  func openInWindow() {
    guard let note = current else { return }
    send(.close)
    showInWindow(note.id)
  }

  // MARK: 操作菜单

  static let openInWindowTitle = "在「全部便签」里打开"

  /// 菜单里现在列的（名字和全部便签窗口的工具栏、右键菜单同一份）
  var menuItems: [ActionMenu.Item] {
    guard let note = current, let menu else { return [] }
    return menu.inColors ? colorItems(note) : actionItems(note)
  }

  func actionItems(_ note: Note) -> [ActionMenu.Item] {
    typealias Names = NotesWindowModel
    return [
      ActionMenu.Item(
        title: Names.pinTitle(note), symbol: note.isPinned ? "pin.slash" : "pin", shortcut: "⌘P"
      ) { [unowned self] in togglePinned() },
      ActionMenu.Item(
        title: Names.colorTitle, symbol: "paintpalette", submenu: colorItems(note)),
      ActionMenu.Item(
        title: Names.archiveTitle(note), symbol: "archivebox", shortcut: "⇧⌘A", section: 1
      ) { [unowned self] in archive() },
      ActionMenu.Item(
        title: Names.deleteTitle, symbol: "trash", section: 1, isDestructive: true
      ) { [unowned self] in delete() },
      ActionMenu.Item(
        title: Self.openInWindowTitle, symbol: HotKeyAction.noteAll.symbol, section: 2
      ) { [unowned self] in openInWindow() },
    ]
  }

  private func colorItems(_ note: Note) -> [ActionMenu.Item] {
    NotePaper.all.enumerated().map { index, paper in
      ActionMenu.Item(
        title: paper.name, image: paper.swatch(side: 16), isChecked: index == note.color,
        id: "color-\(index)"
      ) { [unowned self] in setColor(index) }
    }
  }

  /// ⌘K、「⋯」开关菜单；fromDot：点纸色圆点，直接是颜色那一级
  func toggleMenu(fromDot: Bool = false) {
    guard menu == nil else { return closeMenu() }
    guard let note = current else { return }
    menu = Menu(inColors: fromDot, selection: fromDot ? note.color : 0, fromDot: fromDot)
    onMenu(true)
  }

  func closeMenu() {
    guard menu != nil else { return }
    menu = nil
    onMenu(false)
  }

  /// 执行一行：带子列表的进去（选中现在的颜色），别的先关菜单再做
  func run(_ item: ActionMenu.Item) {
    if item.submenu != nil {
      menu?.inColors = true
      menu?.selection = current?.color ?? 0
    } else {
      closeMenu()
      item.run()
    }
  }

  /// ← / Esc / 点「‹ 颜色」：颜色那一级回上一级（从圆点点开的没有上一级，直接关）
  func menuBack() {
    if let menu, menu.inColors, !menu.fromDot {
      self.menu = Menu(inColors: false, selection: 1)
    } else {
      closeMenu()
    }
  }

  /// 操作菜单开着时的按键（这时焦点在面板自己身上，不在输入框里）：↑↓ 选、↩ / → 执行或进子列表、← 回上一级；
  /// 别的键吞掉。菜单没开着不接。
  /// ponytail: 不能打字过滤（别处的 ⌘K 菜单拿搜索框当过滤框，这里没有输入框；一共 5 项 + 8 种颜色，方向键够用）。
  /// 以后项多了：菜单顶上加一行 CommandTextField，过滤走现成的 ActionMenu.filter
  func handleMenuKey(_ event: NSEvent) -> Bool {
    guard let menu else { return false }
    let items = menuItems
    guard !items.isEmpty else { return true }
    let selected = items.indices.contains(menu.selection) ? items[menu.selection] : nil
    switch Int(event.keyCode) {
    case kVK_UpArrow: self.menu?.selection = (menu.selection - 1 + items.count) % items.count
    case kVK_DownArrow: self.menu?.selection = (menu.selection + 1) % items.count
    case kVK_Return, kVK_ANSI_KeypadEnter: if let selected { run(selected) }
    case kVK_RightArrow: if let selected, selected.submenu != nil { run(selected) }
    case kVK_LeftArrow: menuBack()
    default: break
    }
    return true
  }

  /// 面板的 ⌘ 组合键：⌘W 关（连那一列一起收回，同 Esc）；便签开着时 ⌘P 固定、⌘K 操作菜单、⌘. 换下一种纸色、
  /// ⇧⌘A 归档。⌘⌫ 不接：光标在标题、正文里时它是输入框的「删到行首」，删整条便签走 ⌘K 和「⋯」
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = Int(event.keyCode)
    if flags == .command, key == kVK_ANSI_W, state.phase != .rest {
      closeMenu()
      send(.dismiss)
      return true
    }
    guard current != nil else { return false }
    if flags == [.command, .shift], key == kVK_ANSI_A {
      archive()
      return true
    }
    guard flags == .command else { return false }
    switch key {
    case kVK_ANSI_P: togglePinned()
    case kVK_ANSI_K: toggleMenu()
    case kVK_ANSI_Period: cycleColor()
    default: return false
    }
    return true
  }
}
