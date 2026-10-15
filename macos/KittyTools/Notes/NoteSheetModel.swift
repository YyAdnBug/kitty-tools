// 一条打开着的便签的状态（界面读的）。屏幕边缘那叠里打开的那条（NoteDeckModel）和浮动便签（NoteFloatModel）是
// 同一套：两个模型都从这里继承，画的是同一个视图（Notes/NoteSheet.swift），不各写一份（PLAN §10「便签」第 4 批）。
// 这里有：操作菜单（⌘K、「⋯」、纸色圆点；画的是 Shell/ActionMenu）、对这条便签做的事（固定、换色、任务、查找、
// 归档、删除、在全部便签里打开、浮到屏幕上 / 收回来、打开设置的「便签」页）、⌘ 组合键和菜单开着时的方向键、
// 正文打到上限的标记、该哪条便签的正文拿焦点、这条便签的撤销栈。固定、换色、归档、删除也能指定别的便签
// （那叠里右键一张没打开的标签，NoteDeckModel.tabItems）。
// 子类说的几件事：开着的是哪条（noteID）、怎么个关法（close：用鼠标关的；dismiss：用键盘关的；retire：这条便签要
// 归档 / 删除了）、浮出去还是收回来（toggleFloating）、按着把手拖是在干什么（gripChanged / gripEnded：在那叠里是把
// 它拖出来，浮着时是挪窗口）。
// - **写标题、正文按传进来的编号落**（setTitle / setBody 的 of:），不按「现在开着哪条」：换一条、浮出去 / 收回来的
//   那一下，旧的输入框还在视图树里留一小会儿，它晚到的那一下得落回它自己那条。
// - 每条便签一个撤销栈（textUndo）：正文框建出来时拿到它（NoteTextView.noteUndo），换一条换一个新的（sheetChanged）。
// - 焦点：打开 / 换一条、标题框里 ↩ / Tab、操作菜单关了，都记一次「该这条便签的正文拿焦点」（focus：编号 + 第几次）；
//   正文框自己认（NoteBodyField），拿着窗口的那边（NoteDeck / NoteFloat）另有兜底。
// - 对正文编辑器做的事（⌘T 任务、⌘F 便签内查找、Esc 先关查找条）经 withEditor：这里不拿视图，拿着窗口的那边按编号
//   找到这条便签的正文框再交过来。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable class NoteSheetModel {
  /// 开着的操作菜单
  struct Menu: Equatable {
    /// 在「颜色」那一级
    var inColors = false
    var selection = 0
    /// 从纸色圆点点开的：直接是颜色那一级，长在圆点下面（否则长在「⋯」下面）
    var fromDot = false
  }

  /// 该拿焦点的那条便签、第几次要
  struct Focus: Equatable {
    var id: String
    var count: Int
  }

  /// 把手的哪一块：便签带着的那张标签（没挪开就松手 = 点了一下 = 关掉 / 收回）、头部的空白处
  enum Grip: Sendable {
    case tab, header
  }

  let store: NoteStore
  private(set) var menu: Menu?
  /// 正文打到上限了、这一次输入没进（底下那行小字换成警告）
  private(set) var isOverLimit = false
  /// 该哪条便签的正文拿焦点（见文件头）。便签关了不清：再开又是新的一次
  private(set) var focus: Focus?

  @ObservationIgnored var island: Island?
  /// 窗口当 key 并兜底把焦点放进正文（界面不直接调它，调 requestFocus）；操作菜单开关了
  @ObservationIgnored var focusBody: () -> Void = {}
  @ObservationIgnored var onMenu: (Bool) -> Void = { _ in }
  /// 在「全部便签」里打开这条
  @ObservationIgnored var showInWindow: (String) -> Void = { _ in }
  /// 打开设置窗、落在「便签」那一页（⌘,、操作菜单的「便签设置…」；那叠还有「+」等处右键菜单里的「设置…」）
  @ObservationIgnored var showSettings: () -> Void = {}
  /// 拿这条便签的正文编辑器做一件事（拿着窗口的那边按编号找到它；没开着、还没建出来就不做）
  @ObservationIgnored var withEditor: ((NoteTextView) -> Void) -> Void = { _ in }
  /// 这条便签的正文的撤销栈（正文框建出来时拿到它，NoteTextView.noteUndo；标题框用的是它的字段编辑器自己的栈）。
  /// 换一条换一个新的：上一条里打的字不能在这一条里被 ⌘Z 撤到（同 NotesWindowModel.textUndo）
  @ObservationIgnored private(set) var textUndo = UndoManager()

  init(store: NoteStore) { self.store = store }

  // MARK: 子类说的

  /// 开着的是哪条便签
  var noteID: String? { nil }
  /// ⌘W 这时接不接（那叠扇着没开便签时也接：收回那一列）
  var isShown: Bool { noteID != nil }
  /// 是不是浮在屏幕上的那一张；屏幕边缘现在有没有那叠（操作菜单里那一项叫什么）；浮着的收回去朝哪条边（那一叠实际
  /// 在的那条，「收回边缘」的符号朝它）
  var isFloating: Bool { false }
  var hasEdge: Bool { true }
  var tuckEdge: NoteDeckOptions.Edge { .right }

  /// 用鼠标关（关闭钮、它带着的那张标签）；用键盘关（Esc、⌘W）
  func close() {}
  func dismiss() {}
  /// 这条便签要归档 / 删除了：先从界面上拿走
  func retire() { close() }
  /// 操作菜单的「浮在屏幕上」/「收回边缘」
  func toggleFloating() {}
  /// 按着把手拖（pointer 是鼠标在屏幕上的位置，全局坐标；第一下是按下的地方）、松手（按的是哪一块到松手才要看：
  /// 标签上没挪开 = 点了一下）
  func gripChanged(at pointer: CGPoint) {}
  func gripEnded(_ part: Grip, at pointer: CGPoint) {}

  // MARK: 这条便签

  /// 开着的那条（已经不是「没归档没删的」就不算）
  var current: Note? { target(nil) }

  /// 要做事的那条：给了编号就是那条（那叠里右键的那张标签），没给是开着的那条；已经不是「没归档没删的」就不算
  func target(_ id: String?) -> Note? {
    (id ?? noteID).flatMap(store.note).flatMap { $0.isActive ? $0 : nil }
  }

  /// 开着的换了一条（或者关了）：菜单关掉、上限的标记收掉、换一个新的撤销栈；新的那条记一次「该它拿焦点」
  /// （悬停打开的、重启后恢复的也记：不当 key，但第一响应者照样落在正文上，点进去当了 key 就能直接打字）
  func sheetChanged(to id: String?) {
    if menu != nil { closeMenu() }
    if isOverLimit { isOverLimit = false }
    textUndo = UndoManager()
    if let id { focus = Focus(id: id, count: (focus?.count ?? 0) + 1) }
  }

  /// 浮着时关闭钮、它带着的那张标签叫什么：同操作菜单里那一项（收回边缘；屏幕边缘没有那叠时取消浮动）。那叠里是 nil
  /// （关闭钮叫「关闭」，标签读「关闭便签」）
  var tuckTitle: String? {
    isFloating ? NotesWindowModel.floatTitle(isFloating: true, hasEdge: hasEdge) : nil
  }

  /// 这条便签的正文框该不该拿焦点：是「该拿焦点的那条」就给第几次要，不是给 nil（NoteBodyField.focusRequest）
  func focusRequest(for id: String) -> Int? { focus?.id == id ? focus?.count : nil }

  /// 再要一次焦点（开着的那条的正文；标题框里 ↩ / Tab、复用的空白便签）：记一次，再叫拿着窗口的那边当 key、兜底去找
  func requestFocus() {
    guard let id = noteID else { return }
    focus = Focus(id: id, count: (focus?.count ?? 0) + 1)
    focusBody()
  }

  /// 标题、正文的每一次改动。**按传进来的编号写**（哪个输入框的就落哪条），那条已经不在了就不写（仓库自己不认）
  func setTitle(_ title: String, of id: String) {
    store.setTitle(title, of: id)
  }

  func setBody(_ body: String, of id: String) {
    if isOverLimit, id == noteID { isOverLimit = false }
    store.setBody(body, of: id)
  }

  /// 正文框拦下了会超上限的一次输入
  func overflowed() {
    isOverLimit = true
    Island.announce(NotesWindowModel.overLimitText)
  }

  /// Esc：操作菜单开着先退它（颜色那一级退回上一级），查找条开着先关它，再按才关——用键盘关的，键盘当场回原来的 App
  func cancel() {
    if menu != nil {
      menuBack()
    } else if !closesFindBar() {
      dismiss()
    }
  }

  /// 正文的查找条开着就关掉，返回关没关
  private func closesFindBar() -> Bool {
    var closed = false
    withEditor { closed = $0.dismissFindBar() }
    return closed
  }

  /// ⌘T、头部的「任务」钮、操作菜单：光标所在行（有选区时是选区碰到的每一行）在普通行和任务之间切换，焦点回正文
  /// （接着就能打这条任务的字）
  func toggleTask() {
    guard current != nil else { return }
    closeMenu()
    withEditor { $0.toggleTask() }
    requestFocus()
  }

  /// ⌘F：便签内查找（系统的查找条，长在正文顶上）
  func find() {
    guard current != nil else { return }
    closeMenu()
    withEditor { $0.showFindBar() }
  }

  /// ⌘P：固定 / 取消固定（那叠里：固定的点别处不收、别的屏展开时也不收；浮着的：固定的一直在别的窗口上面、
  /// 重启后回到原处）
  func togglePinned(_ id: String? = nil) {
    guard let note = target(id) else { return }
    store.setPinned(!note.isPinned, of: note.id)
    Island.announce(note.isPinned ? "已取消固定" : "已固定")
  }

  /// ⌘.：换下一种纸色
  func cycleColor() {
    if let note = current { setColor(NotesWindowModel.nextColor(after: note.color)) }
  }

  func setColor(_ color: Int, of id: String? = nil) {
    guard let note = target(id) else { return }
    store.setColor(color, of: note.id)
    Island.announce(NotePaper.all[Note.clamped(color: color)].name)
  }

  /// ⇧⌘A：归档（要找回到「全部便签」的「归档」里）。归档的是开着的那条就先从界面上拿走
  func archive(_ id: String? = nil) {
    guard let note = target(id) else { return }
    if note.id == noteID { retire() }
    store.setArchived(true, of: note.id)
    Island.announce("已归档")
  }

  /// 删除：进「最近删除」。这里没有列表、也没有 ⌘Z，放回的路由岛说
  func delete(_ id: String? = nil) {
    guard let note = target(id) else { return }
    if note.id == noteID { retire() }
    store.delete(note.id)
    island?.show("已删除", detail: "到「全部便签」的「最近删除」里放回", symbol: "trash.circle.fill")
  }

  func openInWindow() {
    guard let note = current else { return }
    close()
    showInWindow(note.id)
  }

  /// ⌘,、操作菜单的「便签设置…」：打开设置窗、落在「便签」那一页（手测反馈第 3 批）。那叠里打开的便签先用键盘的路子
  /// 收起（dismiss）：它在浮动层级，留着会压在设置窗上面。浮动便签不收（NoteFloatModel 重写：人自己留在屏幕上的东西，
  /// 同「在全部便签里打开」）
  func openSettings() {
    closeMenu()
    dismiss()
    showSettings()
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
      ActionMenu.Item(title: Names.taskTitle, symbol: Names.taskSymbol, shortcut: "⌘T") {
        [unowned self] in toggleTask()
      },
      ActionMenu.Item(
        title: Names.archiveTitle(note), symbol: "archivebox", shortcut: "⇧⌘A", section: 1
      ) { [unowned self] in archive() },
      ActionMenu.Item(
        title: Names.deleteTitle, symbol: "trash", section: 1, isDestructive: true
      ) { [unowned self] in delete() },
      ActionMenu.Item(
        title: Names.floatTitle(isFloating: isFloating, hasEdge: hasEdge),
        symbol: Names.floatSymbol(isFloating: isFloating, hasEdge: hasEdge, edge: tuckEdge),
        section: 2
      ) { [unowned self] in toggleFloating() },
      ActionMenu.Item(
        title: Self.openInWindowTitle, symbol: HotKeyAction.noteAll.symbol, section: 2
      ) { [unowned self] in openInWindow() },
      ActionMenu.Item(
        title: "\(Names.settingsTitle)…", symbol: Names.settingsSymbol, shortcut: "⌘,", section: 3
      ) { [unowned self] in openSettings() },
    ]
  }

  private func colorItems(_ note: Note) -> [ActionMenu.Item] {
    NotePaper.colorItems(current: note.color) { [unowned self] in setColor($0) }
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

  /// 鼠标移到操作菜单的某一行上：选中跟过去（ActionMenu.onHover）
  func menuHover(_ index: Int) {
    guard menu != nil, menuItems.indices.contains(index) else { return }
    menu?.selection = index
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
  /// ponytail: 不能打字过滤（别处的 ⌘K 菜单拿搜索框当过滤框，这里没有输入框；一共 7 项 + 8 种颜色，方向键够用）。
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

  /// 面板的 ⌘ 组合键：⌘W 关（同 Esc，用键盘关的）、⌘, 打开设置的「便签」页；便签开着时 ⌘P 固定、⌘K 操作菜单、
  /// ⌘. 换下一种纸色、⌘T 任务、⌘F 便签内查找、⇧⌘A 归档。⌘⌫ 不接：光标在标题、正文里时它是输入框的「删到行首」，
  /// 删整条便签走 ⌘K 和「⋯」
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = Int(event.keyCode)
    if flags == .command, key == kVK_ANSI_W, isShown {
      closeMenu()
      dismiss()
      return true
    }
    if flags == .command, key == kVK_ANSI_Comma, isShown {
      openSettings()
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
    case kVK_ANSI_T: toggleTask()
    case kVK_ANSI_F: find()
    default: return false
    }
    return true
  }
}
