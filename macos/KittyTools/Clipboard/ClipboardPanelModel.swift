// 剪贴板面板的界面状态与操作：筛选、选中 / 多选、键盘命令、粘贴 / 复制 / 删除撤销。视图只负责画。
// 焦点始终在搜索框：方向键 / 回车 / Esc 从搜索框的 doCommandBy 进来，⌘ 组合键从面板的
// performKeyEquivalent 进来（handleKeyEquivalent）。交互按 macOS 习惯重新设计，不沿用旧版：
// 单击选中、双击或 ↩ 粘贴、⌥↩ 纯文本、⌘↩ 仅复制、⌘1–9 直接粘贴第 N 条、删除不确认可撤销。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class ClipboardPanelModel {
  enum Scope: String, CaseIterable {
    case all, favorites, snippets

    var title: String {
      switch self {
      case .all: "全部"
      case .favorites: "收藏"
      case .snippets: "片段"
      }
    }
  }

  enum GroupFilter: Hashable {
    case all, ungrouped
    case group(UUID)
  }

  enum Dialog: Identifiable {
    case note(UUID)
    case edit(UUID)
    case newSnippet, manageGroups
    case newGroup(Set<UUID>)

    var id: String { String(describing: self) }
  }

  enum Toast: Equatable {
    case message(String)
    case undo(count: Int)
  }

  let store: ClipboardStore
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var openTranslate: (String) -> Void = { _ in }
  @ObservationIgnored var openSettings: () -> Void = {}

  var query = "" { didSet { restartBrowsing() } }
  var scope = Scope.all { didSet { restartBrowsing() } }
  /// nil = 全部类型。选了图片 / 文件就清掉形态筛选（形态只对文本有意义）
  var kind: ClipItem.Kind? {
    didSet {
      if kind != .text && kind != nil { form = nil }
      restartBrowsing()
    }
  }
  /// 选了形态就把类型切到文本
  var form: ContentForm? {
    didSet {
      if form != nil { kind = .text }
      restartBrowsing()
    }
  }
  var sourceBundleID: String? { didSet { restartBrowsing() } }
  var groupFilter = GroupFilter.all { didSet { restartBrowsing() } }
  var multiSelection: Set<UUID> = []
  var dialog: Dialog?
  var toast: Toast?
  /// 预览里的 JSON 美化开关，切换条目时复位
  var prettyJSON = false

  private var selectedID: UUID?
  /// 用户在主动浏览（方向键、⌘数字、修饰键点击）时，新条目进来不抢选中
  private var isBrowsing = false
  private var anchorID: UUID?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var formCache: [UUID: ContentForm?] = [:]

  init(store: ClipboardStore) {
    self.store = store
  }

  // MARK: 列表

  var visibleItems: [ClipItem] {
    store.search(query).filter { item in
      switch scope {
      case .all: break
      case .favorites: guard item.favorite else { return false }
      case .snippets: guard item.isSnippet else { return false }
      }
      if let kind, item.kind != kind { return false }
      if let form, contentForm(of: item) != form { return false }
      if let sourceBundleID, item.sourceBundleID != sourceBundleID { return false }
      switch groupFilter {
      case .all: return true
      case .ungrouped: return item.groupID == nil
      case .group(let id): return item.groupID == id
      }
    }
  }

  var selectedItem: ClipItem? {
    let items = visibleItems
    return items.first { $0.id == selectedID } ?? items.first
  }

  /// 来源 App 筛选的候选（出现过的 App，按条目数多→少）
  var sources: [(bundleID: String, name: String)] {
    var counts: [String: (name: String, count: Int)] = [:]
    for item in store.items {
      guard let id = item.sourceBundleID else { continue }
      counts[id, default: (item.sourceName ?? id, 0)].count += 1
    }
    return counts.sorted { $0.value.count > $1.value.count }.map { ($0.key, $0.value.name) }
  }

  func contentForm(of item: ClipItem) -> ContentForm? {
    guard item.kind == .text, let text = item.text else { return nil }
    if let cached = formCache[item.id] { return cached }
    let form = ContentForm.detect(text)
    formCache[item.id] = form
    return form
  }

  func select(_ item: ClipItem) {
    selectedID = item.id
    prettyJSON = false
  }

  // MARK: 键盘

  /// 搜索框转来的编辑命令：↑↓ 移动（带 ⇧ 扩展多选）、↩ 粘贴、⌥↩ 纯文本粘贴、
  /// Esc 依次关对话框 → 清空搜索词 → 取消多选 → 交给面板关闭
  func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      if dialog != nil {
        dialog = nil
      } else if !query.isEmpty {
        query = ""
      } else if !multiSelection.isEmpty {
        multiSelection = []
      } else {
        return false
      }
    case _ where dialog != nil: return false
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    case #selector(NSResponder.moveUpAndModifySelection(_:)): move(by: -1, extending: true)
    case #selector(NSResponder.moveDownAndModifySelection(_:)): move(by: 1, extending: true)
    case #selector(NSResponder.insertNewline(_:)): pasteSelection()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      pasteSelection(plainText: true)
    default: return false
    }
    return true
  }

  /// 面板收到的 ⌘ 组合键；返回 false 交还系统（搜索框里的复制、粘贴、撤销等）
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard dialog == nil, modifiers == .command else { return false }
    let fieldEditor = event.window?.firstResponder as? NSTextView
    let fieldHasSelection = (fieldEditor?.selectedRange().length ?? 0) > 0
    switch Int(event.keyCode) {
    case kVK_Return: copySelection()
    case kVK_ANSI_C where !fieldHasSelection: copySelection()
    case kVK_ANSI_A where query.isEmpty: multiSelection = Set(visibleItems.map(\.id))
    case kVK_ANSI_D: store.toggleFavorite(targetIDs)
    case kVK_Delete, kVK_ForwardDelete: delete(targetIDs)
    case kVK_ANSI_Z where !store.pendingDeletion.isEmpty: undoDelete()
    case kVK_ANSI_E:
      guard let item = selectedItem, item.kind == .text, multiSelection.isEmpty else { return true }
      dialog = .edit(item.id)
    case kVK_ANSI_N: dialog = .newSnippet
    case kVK_ANSI_Comma: openSettings()
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      let items = visibleItems
      if digit < items.count { paste([items[digit]]) }
    }
    return true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  /// extending：⇧↑ / ⇧↓，从锚点到新位置整段选中（和系统列表一致）
  private func move(by offset: Int, extending: Bool = false) {
    let items = visibleItems
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == selectedItem?.id } ?? 0
    let next =
      extending
      ? min(max(current + offset, 0), items.count - 1)
      : (current + offset + items.count) % items.count
    isBrowsing = true
    if extending {
      if anchorID == nil || multiSelection.isEmpty { anchorID = items[current].id }
      let anchor = items.firstIndex { $0.id == anchorID } ?? current
      multiSelection = Set(items[min(anchor, next)...max(anchor, next)].map(\.id))
    } else {
      multiSelection = []
    }
    select(items[next])
  }

  // MARK: 鼠标

  /// 单击选中（预览），双击粘贴；⌘ 单击切换勾选，⇧ 单击从锚点选到这里
  func click(_ item: ClipItem) {
    let event = NSApp.currentEvent
    let modifiers = event?.modifierFlags ?? []
    isBrowsing = true
    if modifiers.contains(.command) {
      if multiSelection.isEmpty, let current = selectedItem { multiSelection = [current.id] }
      multiSelection.formSymmetricDifference([item.id])
      anchorID = item.id
    } else if modifiers.contains(.shift) {
      let items = visibleItems
      guard let from = items.firstIndex(where: { $0.id == (anchorID ?? selectedItem?.id) }),
        let to = items.firstIndex(where: { $0.id == item.id })
      else { return }
      multiSelection = Set(items[min(from, to)...max(from, to)].map(\.id))
    } else if event?.clickCount == 2 {
      paste([item])
      return
    } else {
      multiSelection = []
      anchorID = item.id
    }
    select(item)
  }

  // MARK: 粘贴 / 复制

  /// 操作对象：多选时是全部勾选项，否则是当前选中项
  var targetIDs: Set<UUID> {
    multiSelection.isEmpty ? Set(selectedItem.map { [$0.id] } ?? []) : multiSelection
  }

  private var targets: [ClipItem] {
    let ids = targetIDs
    return visibleItems.filter { ids.contains($0.id) }
  }

  func pasteSelection(plainText: Bool = false) { paste(targets, plainText: plainText) }

  /// 全是文本：按复制先后（旧→新）用换行拼成一条粘贴，并记成一条新历史；
  /// 含图片 / 文件：逐条粘贴，间隔 250ms（目标 App 要时间处理上一次 ⌘V）
  func paste(_ items: [ClipItem], plainText: Bool = false) {
    guard !items.isEmpty else { return }
    let payloads = pasteboardPayloads(items, plainText: plainText)
    guard Permissions.isAccessibilityTrusted else {
      Paster.write(payloads[0])
      showToast(.message("已写入剪贴板。授权辅助功能后才能直接粘贴"))
      Permissions.requestAccessibility()
      return
    }
    hidePanel()
    Task {
      for (index, payload) in payloads.enumerated() {
        if index > 0 { try? await Task.sleep(for: .milliseconds(250)) }
        Paster.write(payload)
        _ = Paster.pasteToFrontmost()
      }
    }
    if items.count == 1 {
      store.bump(items[0].id)
    } else if payloads.count == 1 {
      var merged = ClipItem(kind: .text)
      merged.text = mergedText(items)
      store.record(merged)
    }
  }

  /// ⌘C：只写剪贴板，不关面板、不置顶
  func copySelection(plainText: Bool = false) {
    let items = targets
    guard !items.isEmpty else { return }
    Paster.write(pasteboardPayloads(items, plainText: plainText)[0])
    showToast(.message("已复制"))
  }

  /// 启动器 cb 复制一条：和面板里一样展开片段占位符、带格式的连格式一起写
  func copy(_ item: ClipItem) {
    Paster.write(pasteboardPayloads([item], plainText: false)[0])
  }

  private func pasteboardPayloads(_ items: [ClipItem], plainText: Bool) -> [[NSPasteboardItem]] {
    if items.count > 1, items.allSatisfy({ $0.kind == .text }) {
      return [[plainItem(mergedText(items))]]
    }
    return items.map { item in
      if item.isSnippet, let text = item.text {  // 片段展开占位符，一律纯文本
        return [plainItem(Snippet.expand(text) { NSPasteboard.general.string(forType: .string) })]
      }
      if plainText, item.kind == .text { return [plainItem(item.text ?? "")] }
      return store.pasteboardItems(for: item)
    }
  }

  private func mergedText(_ items: [ClipItem]) -> String {
    items.sorted { $0.copiedAt < $1.copiedAt }.compactMap(\.text).joined(separator: "\n")
  }

  private func plainItem(_ text: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    return item
  }

  // MARK: 编辑类操作

  /// 删除一律不确认：底栏可撤销，⌘Z 也能撤销（面板收起时才真正删）
  func delete(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    store.deleteWithUndo(ids)
    multiSelection.subtract(ids)
    showToast(.undo(count: ids.count), seconds: 5)
  }

  func undoDelete() {
    toastTask?.cancel()
    store.undoDeletion()
    toast = nil
  }

  func edit(_ id: UUID, text: String) {
    formCache[id] = nil
    store.update([id]) { $0.text = text }
  }

  func assign(_ ids: Set<UUID>, to group: UUID?) {
    store.update(ids) { $0.groupID = group }
  }

  func translate(_ item: ClipItem) {
    guard let text = item.text ?? item.ocrText, !text.isEmpty else { return }
    openTranslate(text)
  }

  func showToast(_ toast: Toast, seconds: Double = 1.6) {
    toastTask?.cancel()
    self.toast = toast
    toastTask = Task {
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      if case .undo = toast { store.commitDeletion() }
      self.toast = nil
    }
  }

  // MARK: 显示 / 隐藏

  /// 每次隐藏都复位：搜索、筛选、多选、选中项回到第一条；没撤销的删除落库
  func reset() {
    toastTask?.cancel()
    store.commitDeletion()
    query = ""
    scope = .all
    kind = nil
    form = nil
    sourceBundleID = nil
    groupFilter = .all
    multiSelection = []
    dialog = nil
    toast = nil
    isBrowsing = false
    selectedID = nil
    anchorID = nil
    prettyJSON = false
  }

  /// 筛选 / 搜索变了：回到第一条
  private func restartBrowsing() {
    isBrowsing = false
    selectedID = nil
    prettyJSON = false
  }

  /// 新条目进来：用户没在浏览就让选中回到第一条
  func itemsChanged() {
    if !isBrowsing { selectedID = nil }
    if let sourceBundleID, !store.items.contains(where: { $0.sourceBundleID == sourceBundleID }) {
      self.sourceBundleID = nil
    }
  }
}
