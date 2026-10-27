// 全部便签窗口（PLAN §10「便签」，mac-whisker-notes.mdc「全部便签」）：普通 NSWindow，不是浮层——打开方式同设置窗
// （先收起浮层 → 切成 .regular 并激活；关掉时设置窗也没开着才切回 .accessory，NSApplication.leaveDockIfNoWindows）。
// 这里是窗口和它的状态（NotesWindowModel）：三个视图（全部 / 归档 / 最近删除）和搜索、选中项跟着列表怎么变、
// 各种操作、删除的撤销栈（⌘Z 一条条放回，窗口关掉时清空）、拖动排序、底下那行小字；两种显示方式（便签墙 / 列表，
// 默认便签墙，记住上次选的）和便签墙上放大着的那张（编辑卡）、墙怎么排（卡片的高：可见区附近的当场建、其余分批在后面
// 几轮建，卡片缓存在仓库那一层 NoteStore.wallCard）、方向键、拖动排序落到仓库的哪里。
// 界面在 NotesWindowView.swift（列表）和 NotesWallView.swift（便签墙）。
// 落盘：打字走仓库的 setBody / setTitle（它自己停手再落）；换一条便签、收回编辑卡、窗口失去 key、窗口关闭时 flush。

import AppKit
import Carbon.HIToolbox
import SwiftUI

@Observable final class NotesWindowModel {
  enum Scope: String, CaseIterable, Identifiable {
    case all, archive, trash

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: "全部"
      case .archive: "归档"
      case .trash: "最近删除"
      }
    }
  }

  /// 两种显示方式：便签墙（默认）、列表（左栏列表 + 右栏编辑区）
  enum Layout: String, CaseIterable, Identifiable {
    case wall, list

    var id: String { rawValue }

    var title: String {
      switch self {
      case .wall: "便签墙"
      case .list: "列表"
      }
    }

    var symbol: String {
      switch self {
      case .wall: "square.grid.2x2"
      case .list: "list.bullet"
      }
    }
  }

  let store: NoteStore
  /// 便签墙 / 列表（Prefs.notesWindowLayout：这台电脑自己的状态，不注册默认值；没存过 = 便签墙）。
  /// 换到列表时收回编辑卡；选中的那条两边共用、不变
  var layout = Layout.wall {
    didSet {
      guard layout != oldValue else { return }
      defaults?.set(layout.rawValue, forKey: Prefs.notesWindowLayout)
      if layout == .list { collapse() }
    }
  }
  /// 便签墙上放大成编辑卡的那条（编号）；nil = 没有。开着时它就是选中的那条：换了选中的就收回。
  /// 它在别处被删了 / 归档了的那一下这里还留着（墙看着 current 的变化去收回）：判断「编辑卡开着没有」用 isEditing
  private(set) var expanded: String?
  /// 数变一次，便签墙拿一次焦点：打开编辑卡却不给正文焦点时（从那叠「在全部便签里打开」、最近删除里只读的）——墙的
  /// Esc 能收回它，焦点也不会留在被暗层盖住的搜索框里（收回时墙自己拿：NotesWall 看着 expanded）
  private(set) var wallFocus = 0
  var scope = Scope.all {
    didSet { if scope != oldValue { reconcile() } }
  }
  /// 搜索词（标题和正文，NoteStore.search）
  var query = "" {
    didSet { if query != oldValue { reconcile() } }
  }
  /// 选中的便签（编号）。它不在当前列表里也可以：正在改的那条被搜索词筛掉时，编辑区还是它
  var selection: String? {
    didSet { if selection != oldValue { selectionChanged() } }
  }
  /// 刚删的便签（编号，后删的在后）：⌘Z 一条条放回；窗口关掉时清空
  private(set) var undoStack: [String] = []
  /// 连着删的这一串（岛上的「放回」）
  @ObservationIgnored private var deletions = Deletions()
  /// 正文打到上限了、这一次输入没进（底下那行小字换成警告）；再打进去字、换一条就收
  private(set) var isOverLimit = false
  /// 等确认永久删除的那条、等确认清空最近删除
  var erasing: String?
  var isEmptyingTrash = false
  /// ⌘F：数变一次，搜索框拿一次焦点
  private(set) var searchFocus = 0
  @ObservationIgnored var island: Island?
  /// 把焦点放进正文框（新建之后）；撤销（true = 重做）焦点所在的输入框——正文、标题、搜索框——里打的字，返回做没做
  /// （NSWindow.undoFocusedText：焦点不在输入框里、没有可撤销的是 false）
  @ObservationIgnored var focusBody: () -> Void = {}
  @ObservationIgnored var undoFocusedText: (Bool) -> Bool = { _ in false }
  /// 焦点是不是在正文里（或者它的查找条里）：⌘F 这时是便签内查找，否则去搜索框
  @ObservationIgnored var isEditingBody: () -> Bool = { false }
  /// 拿右边那条便签的正文编辑器做一件事（没有就不做：没选中、最近删除里的是只读的）
  @ObservationIgnored var withEditor: ((NoteTextView) -> Void) -> Void = { _ in }
  /// 在选中那条的正文里标出搜索词的第一处命中（NotesWindow 给：晚一拍，新选中那条的正文框这时还没建出来 / 没换上字）
  @ObservationIgnored var revealMatch: () -> Void = {}
  /// 浮动便签（第 4 批；2026-10-22 起同时可以浮几张）：浮着的是哪几条、屏幕边缘有没有那叠——工具栏和右键菜单里那一项
  /// 叫什么看它，界面读得到它的变化；让一条便签浮出来 / 收回去。AppDelegate 接到 NoteEdge 的那一份；没接（便签用不了）
  /// 时不做事
  @ObservationIgnored var floats: NoteFloats?
  @ObservationIgnored var toggleFloat: (String) -> Void = { _ in }
  /// 打开设置窗、落在「便签」那一页（AppDelegate 接；⌘,、工具栏的「便签设置」）
  @ObservationIgnored var showSettings: () -> Void = {}
  /// 颜色菜单的「其他颜色…」：打开系统取色面板改这一条（NotesWindow 给：从这扇窗口打开，关掉后键盘还给它）
  @ObservationIgnored var pickColor: (String) -> Void = { _ in }
  /// 正文的撤销栈（正文框建出来时拿到它，NoteTextView.noteUndo；窗口的 undoManager 也是它，
  /// NotesWindow.windowWillReturnUndoManager）。换一条便签换一个新的：上一条里打的字不能撤到这一条上。
  /// 标题框、搜索框用的是各自字段编辑器的栈（系统给的，结束编辑就丢）
  @ObservationIgnored private(set) var textUndo = UndoManager()
  /// 记显示方式的偏好域（nil = 不记：单测、截图自检）
  @ObservationIgnored private let defaults: UserDefaults?
  /// 便签墙上还没建好的卡片在后面几轮分批建（buildCards）：都建好了数变一次，墙按真的高重排（中间不重排：
  /// 可见区附近的排的时候当场就建了，往下的挪一挪看不见，每批都重排一次墙比建卡片还贵）
  private(set) var cardBatches = 0
  @ObservationIgnored private var cardTimer: Timer?
  @ObservationIgnored private var cardMarkdown: Bool?
  #if DEBUG
    /// 便签墙（WallBoard）的 body 求值了几次：单测数它——开 / 关编辑卡、放大收回的动画期间墙不该重新求值
    @ObservationIgnored var wallEvaluations = 0
  #endif

  init(store: NoteStore, defaults: UserDefaults? = nil) {
    self.store = store
    self.defaults = defaults
    if let stored = defaults?.string(forKey: Prefs.notesWindowLayout),
      let layout = Layout(rawValue: stored)
    {
      self.layout = layout
    }
    selection = notes.first?.id
  }

  // MARK: 列表

  func list(_ scope: Scope) -> [Note] {
    switch scope {
    case .all: store.active
    case .archive: store.archived
    case .trash: store.trashed
    }
  }

  /// 左边现在列的：当前视图里搜出来的。仓库、视图、搜索词都没变就用上次算好的（listed）——换一次搜索词、一次重画
  /// 要问它好几遍（手测反馈第 3 批）；正文折叠另有一层按「编号 + 标题、正文」的缓存（NoteStore.folded），
  /// 所以搜着的时候在正文里打字只折改过的那条：-O 5000 搜着时打一个字 1087 → 35 ms（2026-10-21）
  var notes: [Note] {
    _ = store.notes  // 界面看着仓库变（generation 不被看着）
    if let listed, listed.generation == store.generation, listed.scope == scope,
      listed.query == query
    {
      return listed.notes
    }
    let notes = store.search(query, in: list(scope))
    listed = (store.generation, scope, query, notes)
    return notes
  }

  /// 上次算好的 notes 和那时的仓库代数、视图、搜索词
  @ObservationIgnored private var listed:
    (generation: Int, scope: Scope, query: String, notes: [Note])?

  /// 右边编辑的那条：选中的、而且属于当前视图（别处把它删了、归档了就不再显示）
  var current: Note? {
    selection.flatMap(store.note).flatMap { Self.belongs($0, to: scope) ? $0 : nil }
  }

  static func belongs(_ note: Note, to scope: Scope) -> Bool {
    switch scope {
    case .all: note.isActive
    case .archive: note.deletedAt == nil && note.isArchived
    case .trash: note.deletedAt != nil
    }
  }

  /// 「全部」里没在搜索时才能拖动排序（归档按改的时间排、最近删除按删的时间排，搜索结果是筛过的）
  var canReorder: Bool {
    scope == .all && query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 列表换了（换视图、改搜索词）：原来选中的还在就不动，不在了选第一条
  private func reconcile() {
    selection = Self.selection(keeping: selection, in: notes.map(\.id))
  }

  /// 列表换了之后选中谁（纯函数）：原来那条还在就不动，不在了选第一条，空的就不选
  static func selection(keeping id: String?, in ids: [String]) -> String? {
    id.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
  }

  /// 一条从列表里拿走（删除、归档、放回）之后选中谁（纯函数）：顶上来的那条（原来在它下面的），它是最后一条就选上一条；
  /// 它本来就不在列表里则选中的不用动（返回 nil 由调用方看着办）
  static func selection(afterRemoving id: String, from ids: [String]) -> String? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    return index + 1 < ids.count ? ids[index + 1] : index > 0 ? ids[index - 1] : nil
  }

  /// 把 id 这条从当前列表里拿走（change 里做真的改动），选中的是它就挪到旁边那条
  private func removing(_ id: String, _ change: () -> Void) {
    let next = Self.selection(afterRemoving: id, from: notes.map(\.id))
    change()
    if selection == id { selection = next }
  }

  private func selectionChanged() {
    store.flush()
    // 从这扇窗口打开的取色面板改的是上一条：换了一条就关掉（选中的正是它在改的那条不关）
    NoteColorPicker.shared.close(owner: self, keeping: selection)
    isOverLimit = false
    textUndo = UndoManager()
    // 编辑卡开着的那条不再是选中的（删了、归档了、放回了、换了视图、换了一条）：收回
    if expanded != nil, expanded != selection { expanded = nil }
    revealSearchHit()
  }

  /// 在搜着的时候换了一条 / 打开了编辑卡：正文里标出第一处命中（第三轮体检 U3；NotesWindow 晚一拍去做）
  private func revealSearchHit() {
    if !Search.tokens(query).isEmpty { revealMatch() }
  }

  // MARK: 操作（工具栏、右键菜单、键盘同一份）

  static let newTitle = "新建便签"
  static let deleteTitle = "删除"
  static let restoreTitle = "放回"
  static let eraseTitle = "永久删除…"
  static let emptyTrashTitle = "清空最近删除…"
  static let colorTitle = "颜色"
  /// 「任务」：全部便签窗口的工具栏、屏幕边缘那叠的便签头部和操作菜单、正文的右键菜单同名同符号（键位 ⌘T）
  static let taskTitle = "任务"
  static let taskSymbol = "checklist"
  static let taskHelp = "任务：把这一行变成任务，或变回普通行（⌘T）"
  /// 「浮在屏幕上」/「收回边缘」：屏幕边缘那叠和浮动便签的操作菜单、全部便签窗口的工具栏和右键菜单同名（浮动便签的
  /// 关闭钮、它带着的标签也叫这个名字）。浮着的那条收回时，屏幕边缘没有那叠（总开关关着）就没有「边缘」可回，
  /// 叫「取消浮动」
  static func floatTitle(isFloating: Bool, hasEdge: Bool = true) -> String {
    isFloating ? (hasEdge ? "收回边缘" : "取消浮动") : "浮在屏幕上"
  }
  /// 符号：「收回边缘」朝那一叠实际在的那条边（edge；两块屏相接时那叠会换到另一侧）
  static func floatSymbol(
    isFloating: Bool, hasEdge: Bool = true, edge: NoteDeckOptions.Edge = .right
  ) -> String {
    guard isFloating else { return "macwindow.on.rectangle" }
    guard hasEdge else { return "xmark.rectangle" }
    return edge == .left ? "sidebar.left" : "sidebar.right"
  }
  /// 「便签设置」：全部便签窗口的工具栏（最右边一组的最后）、屏幕边缘那叠和浮动便签的操作菜单（「便签设置…」）同名
  /// 同符号，键位 ⌘,——打开设置窗、落在「便签」那一页
  static let settingsTitle = "便签设置"
  static let settingsSymbol = "gearshape"
  static func pinTitle(_ note: Note?) -> String { note?.isPinned == true ? "取消固定" : "固定" }
  static func archiveTitle(_ note: Note?) -> String {
    note?.isArchived == true ? "取消归档" : "归档"
  }

  /// 工具栏上画出来的那几样：名字、符号、能不能点。工具栏是单独的一个视图、只拿它（NotesWindowView 的 NotesToolbar）——
  /// 换一条便签时这些多半没变，工具栏就不跟着重建：重建一次是换一条时主线程上最大的一块（SwiftUI 把每一项重新桥成
  /// 系统的工具栏项、重新找符号图、工具栏重新排一遍；手测反馈第 3 批屏外量的，约占一半）
  nonisolated struct ToolbarState: Equatable, Sendable {
    var layout = Layout.wall
    var isTrash = false
    var hasNote = false
    /// 「任务」（⌘T）点不点得了：它动的是正文里光标所在的那一行，得有正文框——列表右栏、便签墙上开着的编辑卡；
    /// 墙上没开编辑卡时置灰（没有「哪一行」可言）
    var canTask = false
    var pinTitle = ""
    var pinSymbol = ""
    var archiveTitle = ""
    var canFloat = false
    var floatTitle = ""
    var floatSymbol = ""
  }

  var toolbarState: ToolbarState {
    let note = current
    return ToolbarState(
      layout: layout, isTrash: scope == .trash, hasNote: note != nil,
      canTask: note.map { $0.deletedAt == nil } == true && (layout == .list || isEditing),
      pinTitle: Self.pinTitle(note),
      pinSymbol: note?.isPinned == true ? "pin.slash" : "pin",
      archiveTitle: Self.archiveTitle(note),
      canFloat: note.map { !$0.isArchived } ?? false, floatTitle: floatTitle(note),
      floatSymbol: floatSymbol(note))
  }

  /// ⌘,、工具栏的「便签设置」：攒着的改动先落下去，再打开设置窗的「便签」页
  func openSettings() {
    store.flush()
    showSettings()
  }

  /// ⌘N：新建一条（排最前）、选中、焦点进正文（便签墙上直接放大成编辑卡）。最前面那条还是空白的就用它，
  /// 不再多建一条（NoteStore.blankOrNew）
  func create() {
    let note = store.blankOrNew()
    query = ""
    scope = .all
    open(note.id)
  }

  /// 从屏幕边缘那叠「在全部便签里打开」：换到它所在的视图、清掉搜索词、选中它（便签墙上放大成编辑卡）
  func reveal(_ id: String) {
    guard let note = store.note(id) else { return }
    query = ""
    scope = note.deletedAt != nil ? .trash : note.isArchived ? .archive : .all
    open(id, focus: false)
  }

  // MARK: 便签墙

  /// 选中这条；便签墙上把它放大成编辑卡、焦点进正文（focus）。列表视图里就是选中。
  /// 便签墙上不给正文焦点时（focus 是 false：从那叠打开的；最近删除里的只读、没有正文框）让墙拿焦点：焦点不会留在被暗层
  /// 盖住的搜索框里（Esc 成了清空搜索、打的字进了搜索词），墙的 Esc 能收回编辑卡
  func open(_ id: String, focus: Bool = true) {
    selection = id
    if layout == .wall, current?.id == id { expanded = id }
    if focus, current?.deletedAt == nil {
      focusBody()
    } else if layout == .wall {
      wallFocus += 1
    }
    revealSearchHit()
  }

  /// 编辑卡开着：放大着的那条还是这个视图里选中的那条（它在别处被删了、归档了的那一下 expanded 还留着，不算）。
  /// 方向键、↩、空格、⌫ 在墙上让着它，⌘W 先收回它（NotesWindow.handlesKeyDown）
  var isEditing: Bool { expanded != nil && current?.id == expanded }

  /// 收回编辑卡（Esc、点暗处、⌘W；换到列表时；开着的那条在别处没了时由墙调）：攒着的改动先落下去。焦点回到便签墙
  /// 由墙自己看着 expanded 拿（不管从哪条路收回的：删除、归档、放回也是）
  func collapse() {
    guard expanded != nil else { return }
    store.flush()
    expanded = nil
  }

  /// 便签墙上分几段：固定的、其他，段里照列表的顺序（最近删除里不分：固定在那里没有意义）
  var wallGroups: [(title: String?, notes: [Note])] {
    let notes = notes
    guard scope != .trash, notes.contains(where: \.isPinned) else { return [(nil, notes)] }
    return [("已固定", notes.filter(\.isPinned)), ("其他", notes.filter { !$0.isPinned })]
  }

  /// 便签墙怎么排（groups：分段和段里的便签；width：墙多宽；reach：可见区附近到哪——墙的坐标，往下多少都算；
  /// markdown：设置里的开关）。卡片的高：建好了的用量好的（NoteStore.wallCard，按便签缓存）；没建好的，顶落在 reach
  /// 以内的当场建（它们要画出来，位置得准），往下的先按估计的高排、交给 buildCards 在后面几轮分批建好——第一次进墙、
  /// 开关 Markdown 时不再一口气把几百张都建出来（评审量的：300 条约 0.45 s、1000 条约 1.5 s，卡在主线程上）。
  /// 卡片的顶按排的顺序只增不减，所以当场建的是开头连着的一段，可见区里的位置都是准的；往下的都建好了一起挪一次（看不见）
  func wallLayout(
    _ groups: [(title: String?, notes: [Note])], width: CGFloat, reach: CGFloat, markdown: Bool
  ) -> NoteWall.Layout {
    _ = cardBatches  // 墙看着它：分批的都建好了重排一次
    let notes = groups.flatMap(\.notes)
    var missing = false
    let layout = NoteWall.layout(groups.map { ($0.title, $0.notes.map(\.id)) }, width: width) {
      index, top in
      let note = notes[index]
      if let card = store.cachedWallCard(of: note, markdown: markdown) { return card.height }
      if top <= reach { return store.wallCard(of: note, markdown: markdown).height }
      missing = true
      return NoteWall.estimatedHeight
    }
    if missing { buildCards(markdown: markdown) }
    return layout
  }

  /// 分批建卡片时一批最多建多久：之间让主线程转一轮（画一帧、接按键、滚动）
  static let cardSlice: Duration = .milliseconds(8)

  /// 便签墙上还有没建好的卡片：在后面几轮分批建好（按墙上的顺序，一批最多 cardSlice），都建好了 cardBatches 变一次。
  /// 已经在建同一种（Markdown 开关一样）的就不另起；开关换了，换成按新的建。
  /// 一批一个跑环上的定时器（默认模式：拖着滚动条、拉窗口的时候不建，停手再接着建——要画的那些排的时候当场就建了）
  func buildCards(markdown: Bool) {
    guard cardTimer == nil || cardMarkdown != markdown else { return }
    cardTimer?.invalidate()
    cardMarkdown = markdown
    scheduleCardBatch()
  }

  private func scheduleCardBatch() {
    cardTimer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.cardBatchFired() }
    }
  }

  private func cardBatchFired() {
    guard let markdown = cardMarkdown else { return }
    if buildCardBatch(markdown: markdown) {
      scheduleCardBatch()
    } else {
      cardTimer = nil
      cardMarkdown = nil
      cardBatches &+= 1
    }
  }

  /// 按墙上现在的顺序建一批还没建好的卡片（最多 cardSlice 那么久）；返回还有没有没建的
  private func buildCardBatch(markdown: Bool) -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    for note in wallGroups.flatMap(\.notes)
    where store.cachedWallCard(of: note, markdown: markdown) == nil {
      guard clock.now - start < Self.cardSlice else { return true }
      _ = store.wallCard(of: note, markdown: markdown)
    }
    return false
  }

  /// 方向键：在便签墙上从选中的那张往 direction 走（NoteWall.neighbor）；没有选中的选第一张。编辑卡开着时不走
  func moveSelection(_ direction: NoteWall.Direction, in layout: NoteWall.Layout) {
    guard !isEditing, !layout.ids.isEmpty else { return }
    guard let index = selection.flatMap(layout.index(of:)) else {
      selection = layout.ids[0]
      return
    }
    if let next = NoteWall.neighbor(of: index, direction, in: layout) {
      selection = layout.ids[next]
    }
  }

  /// 便签墙上拖动排序松手：order 是拖完之后墙上的顺序、section 是它所在的那一段（下标范围），按它在段里挨着的那张
  /// 写回仓库的顺序（NoteStore.move）。只在「全部」里、没在搜索时
  func reorder(_ id: String, in order: [String], section: Range<Int>) {
    guard canReorder,
      let index = NoteWall.storeIndex(
        of: id, in: order, section: section, active: store.active.map(\.id))
    else { return }
    store.move(id, to: index)
  }

  /// ⌘⌫：删除（进「最近删除」，⌘Z 放回）；已经在最近删除里的是永久删除，先确认
  func delete(_ id: String) {
    guard let note = store.note(id) else { return }
    guard note.deletedAt == nil else {
      erasing = id
      return
    }
    removing(id) { store.delete(id) }
    undoStack.append(id)
    // 这一串里已经放回 / 永久删了的不算（不然删 A、⌘Z、再删 B 会写成「已删除 2 条」）
    let ids = deletions.add(id).filter { store.note($0)?.deletedAt != nil }
    island?.show(
      Self.deletedTitle(ids.count), detail: "⌘Z 撤销，或到「最近删除」里放回",
      symbol: "trash.circle.fill",
      actions: [.init(Self.restoreTitle) { [weak self] in self?.restoreDeleted(ids) }])
  }

  /// 岛上的「放回」（第三轮体检 U2）：这一串里还在「最近删除」里的都放回原处（顺序、归档照旧），选中最后删的那条（同 ⌘Z）
  func restoreDeleted(_ ids: [String]) {
    let back = NoteSheetModel.restore(ids, in: store)
    guard let id = back.last, let note = store.note(id) else { return }
    undoStack.removeAll(where: ids.contains)
    select(restored: id)
    // 结果就在列表上：只播报（同 ⌘Z）
    Island.announce(NoteSheetModel.restoredTitle(back.count, first: note))
  }

  /// 删除的提示：一条是「已删除」，连着删了几条（岛上的「放回」放回这一串）带上条数
  static func deletedTitle(_ count: Int) -> String {
    count > 1 ? "已删除 \(count) 条" : "已删除"
  }

  /// 连着删的几条（岛上的「放回」放回这一串，第三轮体检 U2）：上一条删了不到 window 秒（带按钮的岛停多久）就接着记，
  /// 不然重新起一串。全部便签窗口、屏幕边缘那叠、每张浮动便签各记各的
  struct Deletions {
    static let window: TimeInterval = 6
    private var ids: [String] = []
    private var last: Date?

    /// 记一条，返回这一串（含这一条，按删的先后）
    mutating func add(_ id: String, now: Date = .now) -> [String] {
      if let last, now.timeIntervalSince(last) > Self.window { ids = [] }
      ids.removeAll { $0 == id }
      ids.append(id)
      last = now
      return ids
    }
  }

  /// ⌘⌫（NotesWindow 的按键监听按键码认）：焦点在列表上（不在任何输入框里）才是删除这条便签。光标在标题、正文、
  /// 搜索框里时不接——那是输入框自己的「删到行首」（同剪贴板面板：输入框里有字时 ⌘⌫ 归输入框，mac-clipboard §4）；
  /// 在正文里删整条便签走工具栏、右键。返回接没接
  func handleDeleteKey(inTextField: Bool) -> Bool {
    guard !inTextField, let id = selection else { return false }
    delete(id)
    return true
  }

  /// ⌘Z：焦点所在的输入框（正文、标题、搜索框）自己还有可撤销的打字，归它；否则放回刚删的；都没有再看正文里打的字
  func undo() {
    if undoFocusedText(false) || undoDelete() { return }
    if textUndo.canUndo { textUndo.undo() } else { NSSound.beep() }
  }

  /// ⇧⌘Z（NotesWindow 的按键监听认）：重做焦点所在的输入框里刚撤销的打字；焦点不在输入框里就看正文的
  /// （放回删掉的便签没有重做）
  func redo() {
    if undoFocusedText(true) { return }
    if textUndo.canRedo { textUndo.redo() } else { NSSound.beep() }
  }

  /// 放回最近删的那一条并选中它（连着删了几条就连着撤）。栈里那条已经不在「最近删除」里了（自己放回了、永久删了）就跳过。
  /// 返回放没放回
  @discardableResult
  func undoDelete() -> Bool {
    while let id = undoStack.popLast() {
      guard let note = store.note(id), note.deletedAt != nil else { continue }
      store.restore(id)
      select(restored: id)
      Island.announce("已放回「\(note.displayTitle)」")
      return true
    }
    return false
  }

  /// 放回之后选中它：去它在的那个视图（归档的去归档），搜索词筛掉了它就清掉搜索
  private func select(restored id: String) {
    guard let note = store.note(id) else { return }
    scope = note.isArchived ? .archive : .all
    if !notes.contains(where: { $0.id == id }) { query = "" }
    selection = id
  }

  /// ⇧⌘A：归档 / 取消归档（取消归档的排回「全部」最前）
  func toggleArchived(_ id: String) {
    guard let note = store.note(id), note.deletedAt == nil else { return }
    removing(id) { store.setArchived(!note.isArchived, of: id) }
    Island.announce(note.isArchived ? "已取消归档" : "已归档")
  }

  /// ⌘P：固定 / 取消固定
  func togglePinned(_ id: String) {
    guard let note = store.note(id), note.deletedAt == nil else { return }
    store.setPinned(!note.isPinned, of: id)
  }

  func setColor(_ color: Int, of id: String) {
    guard store.note(id)?.deletedAt == nil else { return }
    store.setColor(color, of: id)
  }

  /// ⌘.：轮到下一种纸色
  func cycleColor(_ id: String) {
    guard let note = store.note(id) else { return }
    setColor(Self.nextColor(after: note.color), of: id)
  }

  static func nextColor(after color: Int) -> Int { Note.nextPreset(after: color) }

  /// 这条便签是不是正浮在屏幕上；工具栏、右键菜单里那一项现在叫什么
  func isFloating(_ note: Note?) -> Bool {
    note.map { floats?.floatingIDs.contains($0.id) ?? false } ?? false
  }

  func floatTitle(_ note: Note?) -> String {
    Self.floatTitle(isFloating: isFloating(note), hasEdge: floats?.edgeShown ?? true)
  }

  func floatSymbol(_ note: Note?) -> String {
    Self.floatSymbol(
      isFloating: isFloating(note), hasEdge: floats?.edgeShown ?? true,
      edge: note.flatMap { floats?.float(of: $0.id)?.model.tuckEdge } ?? .right)
  }

  /// 浮在屏幕上 / 收回边缘：只有没归档、没删的便签能浮着
  func toggleFloating(_ id: String) {
    guard let note = store.note(id), Self.belongs(note, to: .all) else { return }
    toggleFloat(id)
  }

  /// 选颜色的那份表（工具栏的颜色下拉、右键菜单里的「颜色」；每项前面是纸色圆点，NotePaper.colorItems）：预设、
  /// 自定义的那一节（最近用过按这扇窗口的偏好域读，没有偏好域的单测、截图自检是空的）、「其他颜色…」
  func colorItems(_ note: Note) -> [ActionMenu.Item] {
    let id = note.id
    return NotePaper.colorItems(
      current: note.color, recent: defaults.map { NoteColorPicker.recentColors(in: $0) } ?? [],
      choose: { [weak self] in self?.setColor($0, of: id) },
      other: { [weak self] in self?.pickColor(id) })
  }

  /// 一行的右键菜单：和工具栏同名的那几项（不写键位，HIG）；最近删除里的是放回 / 永久删除 / 清空。
  /// colors 是 false 时不带「颜色」那一级（便签墙卡片的旁白「更多动作」：每次重画都要，8 个纸色圆点的图不白建）
  func rowItems(_ note: Note, colors: Bool = true) -> [ActionMenu.Item] {
    let id = note.id
    guard note.deletedAt == nil else {
      return [
        ActionMenu.Item(title: Self.restoreTitle) { [weak self] in self?.restore(id) },
        ActionMenu.Item(title: Self.eraseTitle, section: 1, isDestructive: true) { [weak self] in
          self?.delete(id)
        },
        ActionMenu.Item(title: Self.emptyTrashTitle, section: 1, isDestructive: true) {
          [weak self] in self?.isEmptyingTrash = true
        },
      ]
    }
    var items = [
      ActionMenu.Item(title: Self.pinTitle(note)) { [weak self] in self?.togglePinned(id) },
      ActionMenu.Item(title: Self.archiveTitle(note)) { [weak self] in self?.toggleArchived(id) },
      ActionMenu.Item(
        title: NoteMarkdownFiles.singleExportTitle, symbol: "square.and.arrow.up"
      ) { [weak self] in self?.exportMarkdown(id) },
    ]
    if colors { items.append(ActionMenu.Item(title: Self.colorTitle, submenu: colorItems(note))) }
    // 归档里的不能浮着
    if !note.isArchived {
      items.append(
        ActionMenu.Item(title: floatTitle(note)) { [weak self] in self?.toggleFloating(id) })
    }
    items.append(
      ActionMenu.Item(title: Self.deleteTitle, section: 1, isDestructive: true) { [weak self] in
        self?.delete(id)
      })
    return items
  }

  /// 「导出为 Markdown…」：先让仓库落盘（导出的是现在的样子），再开存储面板；写完用刘海岛说一句
  func exportMarkdown(_ id: String) {
    guard let note = store.note(id) else { return }
    store.flush()
    NoteMarkdownFiles.exportPanel(
      note, imageDirectory: store.images?.directory, island: island)
  }

  /// 从「最近删除」放回原处
  func restore(_ id: String) {
    guard store.note(id)?.deletedAt != nil else { return }
    removing(id) { store.restore(id) }
    Island.announce("已放回")
  }

  /// 永久删除（确认之后）
  func erase(_ id: String) {
    removing(id) { store.erase(id) }
  }

  /// 清空最近删除（确认之后）
  func emptyTrash() {
    store.emptyTrash()
    if scope == .trash { selection = nil }
  }

  /// 拖动排序（List 的 onMove：拖走的行、落点在原列表里的下标）
  func move(from source: IndexSet, to destination: Int) {
    let list = notes
    guard canReorder, let from = source.first, list.indices.contains(from) else { return }
    store.move(list[from].id, to: Self.landingIndex(from: from, to: destination))
  }

  /// onMove 的落点是「拿走之前」的下标，仓库要的是「挪完之后」的（纯函数）：往下拖的少算一格
  static func landingIndex(from: Int, to destination: Int) -> Int {
    destination > from ? destination - 1 : destination
  }

  // MARK: 编辑

  func setTitle(_ title: String, of id: String) { store.setTitle(title, of: id) }

  func setBody(_ body: String, of id: String) {
    isOverLimit = false
    store.setBody(body, of: id)
  }

  /// 正文框拦下了会超上限的一次输入
  func overflowed() {
    isOverLimit = true
    Island.announce(Self.overLimitText)
  }

  static let overLimitText = "一条便签最多 1 MB，这次输入没有记进去"

  /// 正文里插图被拒 / 存图没成：用刘海岛说一句（标题 + 说明分开，F9）
  func imageProblem(_ title: String, _ detail: String) {
    island?.show(title, detail: detail, tone: .warning, symbol: "photo.badge.exclamationmark")
  }

  func focusSearch() { searchFocus += 1 }

  /// ⌘F：焦点在正文里（或它的查找条里）是便签内查找（系统的查找条），否则去搜索框。便签墙上开着编辑卡时搜索框被
  /// 暗层盖着：是编辑卡正文的查找条（最近删除里只读的没有正文，不做）
  func find() {
    guard isEditing || isEditingBody() else { return focusSearch() }
    withEditor { editor in
      editor.window?.makeFirstResponder(editor)
      editor.showFindBar()
    }
  }

  /// ⌘T、工具栏的「任务」：正文里光标所在行（有选区时是选区碰到的每一行）在普通行和任务之间切换，焦点进正文
  func toggleTask() {
    withEditor { editor in
      editor.toggleTask()
      editor.window?.makeFirstResponder(editor)
    }
  }

  /// 窗口失去 key：攒着的改动落下去
  func resignedKey() { store.flush() }

  /// 窗口关了：落盘，撤销栈清空，编辑卡收回（下次打开是墙），分批建卡片的停下（建好的留在仓库里，下次打开接着建）
  func closed() {
    store.flush()
    undoStack = []
    expanded = nil
    cardTimer?.invalidate()
    cardTimer = nil
    cardMarkdown = nil
  }

  // MARK: 文字（纯函数）

  /// 列表行右边的相对时间：「现在」「3分钟前」「昨天」「上周」（同剪贴板行）。最近删除里看删的时间，别处看改的时间
  static func ago(_ note: Note, now: Date = .now) -> String {
    let date = note.deletedAt ?? note.modifiedAt
    // 相对时间的格式总是对着「现在」算：按 now 平移过去（平时 now 就是现在，单测能摆固定的时刻）
    return Date.now.addingTimeInterval(min(date.timeIntervalSince(now), 0)).formatted(
      .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
  }

  /// 右边最底下那行小字：「改于 今天 09:12 · 128 字」；最近删除里是「删于 昨天 22:40 · 29 天后永久删除」
  static func footnote(_ note: Note, now: Date = .now, calendar: Calendar = .current) -> String {
    guard let deleted = note.deletedAt else {
      // 字数**不数图片的令牌**（一张图算 0 个字）：不然一张图让底下多出六七十个字（F19）；**也不数颜色的标记**
      // （第 8 批：`[` 和 `]{red}` 是显示时才露出来的标记，不算用户写的字）
      let count = NoteMarkdown.strippingColors(from: NoteImages.stripping(note.body))
        .reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
      return "改于 \(SettingsBackup.when(note.modifiedAt, now: now, calendar: calendar)) · \(count) 字"
    }
    let left = deleted.addingTimeInterval(Double(NoteStore.trashDays) * 86_400)
      .timeIntervalSince(now)
    let days = Int((left / 86_400).rounded(.up))
    return "删于 \(SettingsBackup.when(deleted, now: now, calendar: calendar)) · "
      + (days > 0 ? "\(days) 天后永久删除" : "即将永久删除")
  }
}

/// 窗口本身：建、显示、记位置；窗口的委托（key 进出、关闭、撤销栈）；⌘⌫ 和 ⇧⌘Z 的按键监听
final class NotesWindow: NSObject, NSWindowDelegate {
  /// 最小的内容尺寸（SwiftUI 自己算的最小：墙 532 × 97–188、列表 300–346 × 179–260，2026-10-18 量）
  static let minSize = NSSize(width: 720, height: 420)
  /// 窗口的标识：空闲回收认它（开着时不算闲，AppDelegate.isIdle）
  static let identifier = NSUserInterfaceItemIdentifier("notes")

  /// 只读：单测看窗口的内容和最小尺寸
  let window: NSWindow
  let model: NotesWindowModel
  /// ⌘⌫ 和 ⇧⌘Z 的本地按键监听：窗口是 key 时装着，不是了就卸（成对）
  private var keyMonitor: Any?
  /// 关掉了（AppDelegate 排空闲回收）
  var onClose: () -> Void = {}

  var isVisible: Bool { window.isVisible }

  /// frameName：记住窗口位置和大小用的名字（单测传 nil：不写偏好）
  init(model: NotesWindowModel, frameName: String? = "Notes") {
    self.model = model
    // 内容包在普通容器里：宿主视图当窗口的 contentView 会闪退（见 windowContent）
    window = NSWindow(contentViewController: .windowContent(NotesWindowView(model: model)))
    window.title = HotKeyAction.noteAll.title
    window.identifier = Self.identifier
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 940, height: 580))
    window.contentMinSize = Self.minSize
    super.init()
    window.delegate = self
    if let frameName {
      if !window.setFrameUsingName(frameName) { window.center() }
      window.setFrameAutosaveName(frameName)
    }
    // 都弱引用：模型比窗口活得久（关着的窗口空闲时整个放掉，模型留着，下次打开接着用，AppDelegate.notesModel）
    model.focusBody = { [weak self] in
      // 晚一拍：新选中的那条的编辑区这时还没建出来
      guard let self else { return }
      perform(#selector(focusBodyNow), with: nil, afterDelay: 0)
    }
    model.undoFocusedText = { [weak self] redo in
      guard let window = self?.window else { return false }
      // 裁图的那一层拿着键盘：⌘Z / ⇧⌘Z 什么都不动（不改藏着的正文、不放回删掉的便签）
      if NoteImageCropView.holdsKeyboard(in: window) {
        NSSound.beep()
        return true
      }
      return window.undoFocusedText(redo: redo)
    }
    model.isEditingBody = { [weak self] in
      guard let self else { return false }
      return Self.isInBody(window.firstResponder, editor: selectedEditor())
    }
    model.withEditor = { [weak self] body in
      if let editor = self?.selectedEditor() { body(editor) }
    }
    model.revealMatch = { [weak self] in
      guard let self else { return }
      // 换一条和打开编辑卡在同一下里各要一次：只做最后那次（排在拿焦点之后）
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(revealMatchNow), object: nil)
      perform(#selector(revealMatchNow), with: nil, afterDelay: 0)
    }
    model.pickColor = { [weak self] id in
      guard let self else { return }
      NoteColorPicker.shared.open(id, in: model.store, owner: model, from: window)
    }
  }

  /// 选中的那条的正文框（没选中、它没有正文框——最近删除里只读的、墙上没开编辑卡——是 nil）
  private func selectedEditor() -> NoteTextView? {
    model.selection.flatMap { Self.editor(in: window.contentView, for: $0) }
  }

  /// 显示并激活（调用方先把浮层收起，同 SettingsWindow.show）
  func show() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时可能到不了最前：退回旧 API（同设置窗）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  /// 选中的那条的正文里标出搜索词的第一处命中（不拿焦点、不动选区；NoteTextView.revealMatch）
  @objc private func revealMatchNow() {
    window.contentView?.layoutSubtreeIfNeeded()
    selectedEditor()?.revealMatch(of: model.query)
  }

  /// 选中的那条的正文框拿焦点
  @objc private func focusBodyNow() {
    window.contentView?.layoutSubtreeIfNeeded()
    if let editor = selectedEditor() { window.makeFirstResponder(editor) }
  }

  /// 视图树里的正文框（便签专用的编辑器）。平时只有一个；便签墙上一张编辑卡正收回、另一张正放大时有两个。
  /// 给了 id 就只要这条便签的（正文框的 identifier 是便签的编号），没有就是 nil——不拿别的那条凑数（⌘T、查找、拿焦点
  /// 落到正淡出的那张上就是改错了便签）；不给 id 是随便一个
  static func editor(in view: NSView?, for id: String? = nil) -> NoteTextView? {
    var found: [NoteTextView] = []
    func collect(_ view: NSView) {
      if let editor = view as? NoteTextView { found.append(editor) }
      view.subviews.forEach(collect)
    }
    view.map(collect)
    guard let id else { return found.first }
    return found.first { $0.identifier?.rawValue == id }
  }

  /// 第一响应者是不是在正文里：正文框自己，或者它的滚动区里的东西（查找条的搜索框——正在编辑的是字段编辑器，
  /// 它也在那个搜索框的视图树里）
  static func isInBody(_ responder: NSResponder?, editor: NoteTextView?) -> Bool {
    guard let editor, let view = responder as? NSView else { return false }
    return view === editor || (editor.enclosingScrollView.map(view.isDescendant(of:)) ?? false)
  }

  /// 窗口的按键监听认的三个键（别的键是 SwiftUI 的 keyboardShortcut，见 NotesWindowView.shortcuts）；返回接没接。
  /// 挂着确认框（sheet）时按键是给它的，不接。
  /// - ⌘W：便签墙上开着编辑卡时收回编辑卡（不关窗口）；没开着照常关窗口；
  /// - ⌘⌫ 按键码认：焦点在输入框里（搜索框、标题框的字段编辑器，正文的文本框）交还给输入框；
  /// - ⇧⌘Z 重做：不挂 SwiftUI 的隐藏按钮——同一个字母上挂 ⌘Z、⇧⌘Z 两个按钮，实测 ⌘Z 会被后挂的那个抢走
  ///   （macOS 15.7，屏外窗口里把按键交给 performKeyEquivalent）
  static func handlesKeyDown(_ event: NSEvent, in window: NSWindow, model: NotesWindowModel)
    -> Bool
  {
    guard event.window === window else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    // ⌘W：便签墙上开着编辑卡时先收回它，不关窗口（开着的那条在别处没了的那一下不算开着：墙会收回它）
    if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w",
      model.isEditing
    {
      model.collapse()
      return true
    }
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
      model.redo()
      return true
    }
    guard Int(event.keyCode) == kVK_Delete, flags == .command else { return false }
    // 正在裁图（裁切层或它的控件拿着键盘）也不删这条便签
    return model.handleDeleteKey(
      inTextField: window.firstResponder is NSText || NoteImageCropView.holdsKeyboard(in: window))
  }

  private func removeKeyMonitor() {
    keyMonitor.map(NSEvent.removeMonitor)
    keyMonitor = nil
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.textUndo }

  func windowDidBecomeKey(_ notification: Notification) {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        self.map { Self.handlesKeyDown(event, in: $0.window, model: $0.model) } ?? false
      }
      return handled ? nil : event
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    removeKeyMonitor()
    model.resignedKey()
  }

  func windowWillClose(_ notification: Notification) {
    NoteColorPicker.shared.close(owner: model)
    removeKeyMonitor()
    model.closed()
    NSApp.leaveDockIfNoWindows(closing: window)
    onClose()
  }
}
