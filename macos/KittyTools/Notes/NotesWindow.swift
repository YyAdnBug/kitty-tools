// 全部便签窗口（PLAN §10「便签」，mac-whisker-notes.mdc「全部便签」）：普通 NSWindow，不是浮层——打开方式同设置窗
// （先收起浮层 → 切成 .regular 并激活；关掉时设置窗也没开着才切回 .accessory，NSApplication.leaveDockIfNoWindows）。
// 这里是窗口和它的状态（NotesWindowModel）：三个视图（全部 / 归档 / 最近删除）和搜索、选中项跟着列表怎么变、
// 各种操作、删除的撤销栈（⌘Z 一条条放回，窗口关掉时清空）、拖动排序、底下那行小字。界面在 NotesWindowView.swift。
// 落盘：打字走仓库的 setBody / setTitle（它自己停手再落）；换一条便签、窗口失去 key、窗口关闭时 flush。

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

  let store: NoteStore
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
  /// 正文打到上限了、这一次输入没进（底下那行小字换成警告）；再打进去字、换一条就收
  private(set) var isOverLimit = false
  /// 等确认永久删除的那条、等确认清空最近删除
  var erasing: String?
  var isEmptyingTrash = false
  /// ⌘F：数变一次，搜索框拿一次焦点
  private(set) var searchFocus = 0
  @ObservationIgnored var island: Island?
  /// 把焦点放进正文框（新建之后）；焦点是不是在标题 / 正文框里（⌘Z 归谁）
  @ObservationIgnored var focusBody: () -> Void = {}
  @ObservationIgnored var isEditingText: () -> Bool = { false }
  /// 标题框和正文框的撤销栈（窗口的 undoManager 就是它，NotesWindow.windowWillReturnUndoManager）。换一条便签换一个新的：
  /// 上一条里打的字不能撤到这一条上
  @ObservationIgnored private(set) var textUndo = UndoManager()

  init(store: NoteStore) {
    self.store = store
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

  /// 左边现在列的：当前视图里搜出来的
  var notes: [Note] { NoteStore.search(query, in: list(scope)) }

  /// 右边编辑的那条：选中的、而且属于当前视图（别处把它删了、归档了就不再显示）
  var current: Note? {
    selection.flatMap(store.note).flatMap { Self.belongs($0, to: scope) ? $0 : nil }
  }

  static func belongs(_ note: Note, to scope: Scope) -> Bool {
    switch scope {
    case .all: note.deletedAt == nil && !note.isArchived
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
    isOverLimit = false
    textUndo = UndoManager()
  }

  // MARK: 操作（工具栏、右键菜单、键盘同一份）

  static let newTitle = "新建便签"
  static let deleteTitle = "删除"
  static let restoreTitle = "放回"
  static let eraseTitle = "永久删除…"
  static let emptyTrashTitle = "清空最近删除…"
  static let colorTitle = "颜色"
  static func pinTitle(_ note: Note?) -> String { note?.isPinned == true ? "取消固定" : "固定" }
  static func archiveTitle(_ note: Note?) -> String {
    note?.isArchived == true ? "取消归档" : "归档"
  }

  /// ⌘N：新建一条（排最前）、选中、焦点进正文。最前面那条还是空白的就用它，不再多建一条
  func create() {
    let blank = store.active.first.flatMap { $0.title.isEmpty && $0.body.isEmpty ? $0 : nil }
    let note = blank ?? store.create()
    query = ""
    scope = .all
    selection = note.id
    focusBody()
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
    island?.show("已删除", detail: "⌘Z 撤销，或到「最近删除」里放回", symbol: "trash.circle.fill")
  }

  /// ⌘⌫（NotesWindow 的按键监听按键码认）：焦点在列表上（不在任何输入框里）才是删除这条便签。光标在标题、正文、
  /// 搜索框里时不接——那是输入框自己的「删到行首」（同剪贴板面板：输入框里有字时 ⌘⌫ 归输入框，mac-clipboard §4）；
  /// 在正文里删整条便签走工具栏、右键。返回接没接
  func handleDeleteKey(inTextField: Bool) -> Bool {
    guard !inTextField, let id = selection else { return false }
    delete(id)
    return true
  }

  /// ⌘Z：焦点在标题 / 正文框里、它自己还有可撤销的打字，归它；否则放回刚删的；都没有再看打的字
  func undo() {
    if isEditingText(), textUndo.canUndo { return textUndo.undo() }
    if undoDelete() { return }
    if textUndo.canUndo { textUndo.undo() } else { NSSound.beep() }
  }

  /// 放回最近删的那一条并选中它（连着删了几条就连着撤）。栈里那条已经不在「最近删除」里了（自己放回了、永久删了）就跳过。
  /// 返回放没放回
  @discardableResult
  func undoDelete() -> Bool {
    while let id = undoStack.popLast() {
      guard let note = store.note(id), note.deletedAt != nil else { continue }
      store.restore(id)
      scope = note.isArchived ? .archive : .all
      if !notes.contains(where: { $0.id == id }) { query = "" }
      selection = id
      Island.announce("已放回「\(note.displayTitle)」")
      return true
    }
    return false
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

  static func nextColor(after color: Int) -> Int { (max(color, 0) + 1) % Note.colorCount }

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

  func focusSearch() { searchFocus += 1 }

  /// 窗口失去 key：攒着的改动落下去
  func resignedKey() { store.flush() }

  /// 窗口关了：落盘，撤销栈清空
  func closed() {
    store.flush()
    undoStack = []
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
      let count = note.body.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
      return "改于 \(SettingsBackup.when(note.modifiedAt, now: now, calendar: calendar)) · \(count) 字"
    }
    let left = deleted.addingTimeInterval(Double(NoteStore.trashDays) * 86_400)
      .timeIntervalSince(now)
    let days = Int((left / 86_400).rounded(.up))
    return "删于 \(SettingsBackup.when(deleted, now: now, calendar: calendar)) · "
      + (days > 0 ? "\(days) 天后永久删除" : "即将永久删除")
  }
}

/// 窗口本身：建、显示、记位置；窗口的委托（key 进出、关闭、撤销栈）；⌘⌫ 的按键监听
final class NotesWindow: NSObject, NSWindowDelegate {
  private let window: NSWindow
  let model: NotesWindowModel
  /// ⌘⌫ 的本地按键监听：窗口是 key 时装着，不是了就卸（成对）
  private var keyMonitor: Any?

  var isVisible: Bool { window.isVisible }

  init(model: NotesWindowModel) {
    self.model = model
    let hosting = NSHostingController(rootView: NotesWindowView(model: model))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    window = NSWindow(contentViewController: hosting)
    window.title = HotKeyAction.noteAll.title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 940, height: 580))
    window.contentMinSize = NSSize(width: 720, height: 420)
    super.init()
    window.delegate = self
    if !window.setFrameUsingName("Notes") { window.center() }
    window.setFrameAutosaveName("Notes")
    model.focusBody = { [unowned self] in
      // 晚一拍：新选中的那条的编辑区这时还没建出来
      perform(#selector(focusBodyNow), with: nil, afterDelay: 0)
    }
    model.isEditingText = { [unowned self] in window.firstResponder is NSText }
  }

  /// 显示并激活（调用方先把浮层收起，同 SettingsWindow.show）
  func show() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时可能到不了最前：退回旧 API（同设置窗）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  /// 正文框（窗口里唯一的多行输入框）拿焦点
  @objc private func focusBodyNow() {
    window.contentView?.layoutSubtreeIfNeeded()
    if let editor = Self.editor(in: window.contentView) { window.makeFirstResponder(editor) }
  }

  private static func editor(in view: NSView?) -> SourceTextView.FocusTextView? {
    guard let view else { return nil }
    return (view as? SourceTextView.FocusTextView)
      ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
  }

  /// ⌘⌫ 按键码认（别的键是 SwiftUI 的 keyboardShortcut，见 NotesWindowView.shortcuts）。挂着确认框（sheet）时按键是
  /// 给它的，不接；焦点在输入框里（搜索框、标题框的字段编辑器，正文的文本框）交还给输入框
  private func handlesKeyDown(_ event: NSEvent) -> Bool {
    guard event.window === window, Int(event.keyCode) == kVK_Delete,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    else { return false }
    return model.handleDeleteKey(inTextField: window.firstResponder is NSText)
  }

  private func removeKeyMonitor() {
    keyMonitor.map(NSEvent.removeMonitor)
    keyMonitor = nil
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.textUndo }

  func windowDidBecomeKey(_ notification: Notification) {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handlesKeyDown(event) ?? false }
      return handled ? nil : event
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    removeKeyMonitor()
    model.resignedKey()
  }

  func windowWillClose(_ notification: Notification) {
    removeKeyMonitor()
    model.closed()
    NSApp.leaveDockIfNoWindows(closing: window)
  }
}
