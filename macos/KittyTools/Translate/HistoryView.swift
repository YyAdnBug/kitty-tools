// 翻译历史（N7，mac-whisker §6 翻译）：整块替换浮窗的结果区（原文区不动，开 / 关时结果区 settle 交叉淡变），
// 和剪贴板同一套键盘列表——顶上搜索框（CommandTextField，↑↓ / ↩ / ⇧Tab / Esc 走 doCommandBy）+ 全部 / 收藏两枚
// 范围胶囊（品牌粉 0.16 底 + brandInk 字）；按 今天 / 昨天 / 日期 分组（11 semibold tertiary，无灰条、无分割线）；
// 行 44（原文、译文各一行，右侧时间与星标）；一块中性高亮按前缀和定位、在行间滑动（键盘 snap、连发 instant、点选 glide）。
// ↩ / 双击重新翻译，⌘⌫ 删（不确认，⌘Z 撤销）、⌘C 复制译文、⇧⌘C 复制原文、⌘D 收藏（全 App 收藏都是 ⌘D，体检 A31）；
// ⌘K 从右下角弹动作菜单（共用 ActionMenu，体检 C6：单条操作 ｜ 导出 › / 清空历史…，开着时搜索框用来过滤它），
// 右键菜单是同一份；条数在浮窗的「⋯」菜单，没有「共 N 条 · 收藏 M」底栏。
// 列表一页 500 条、滚到底再取下一页，查询结果按 (revision, 搜索词, 范围, 页数) 记住（体检 B22）。
// 列表状态在 HistoryList（协调器持有，搜索框命令和 ⌘ 键由协调器转过来）。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 翻译历史的列表状态：搜索词、范围、选中（nil = 第一条）、撤销删除
@Observable final class HistoryList {
  let store: HistoryStore
  var query = "" { didSet { resetSelection() } }
  /// 范围：全部 / 收藏（生词本）
  var favoritesOnly = false { didSet { resetSelection() } }
  private(set) var selectedID: UUID?
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发与搜索 / 范围变化不动画，点选 glide
  private(set) var selectionMotion = Style.Motion.instant
  /// 刚复制了译文的那条：行尾的时间换成「✓ 已复制」（Style.copiedHold）
  private(set) var copiedID: UUID?
  /// 删掉的条目和删的时候 store 清空过几次（⌘Z 从后往前插回，清空之前删的不再插回）；开 / 关历史时清空
  @ObservationIgnored private var deleted: [(entry: HistoryStore.Entry, clears: Int)] = []
  @ObservationIgnored private var copyTask: Task<Void, Never>?
  /// 刘海岛（AppDelegate 给，单测里是 nil）：删除后告诉用户可以 ⌘Z
  @ObservationIgnored var island: Island?
  /// 重新翻译一条（↩、双击、⌘K / 右键），协调器接上
  @ObservationIgnored var retranslate: (HistoryStore.Entry) -> Void = { _ in }
  /// 「清空历史…」：开确认框（协调器接上，确认框挂在浮窗根视图上）
  @ObservationIgnored var confirmClear: () -> Void = {}

  /// ⌘K 动作菜单（体检 C6）开着：搜索框这时改成过滤它（actionQuery），↑↓ ↩ 选择执行
  var showsActions = false {
    didSet {
      actionQuery = ""
      actionSelection = 0
      actionSubmenu = nil
    }
  }
  var actionQuery = "" { didSet { actionSelection = 0 } }
  var actionSelection = 0
  /// 进了哪一行的子列表（「导出 ›」）；nil = 第一级
  private(set) var actionSubmenu: String?

  init(store: HistoryStore) {
    self.store = store
  }

  /// 一页多少条：滚到底（或 ↓ 走到最后一条）再取下一页（体检 B22；保留条数可以选「不限」）
  static let pageSize = 500
  /// 已经取了几页；搜索词、范围变了和复位时回到 1
  private(set) var pages = 1
  @ObservationIgnored private var cache: (key: CacheKey, entries: [HistoryStore.Entry])?

  private struct CacheKey: Equatable {
    let revision: Int
    let query: String
    let favoritesOnly: Bool
    let limit: Int
  }

  /// 当前搜索词和范围下的条目（新→旧，前 pages 页）。读 store.revision，增删改后刷新；
  /// 按 (revision, 搜索词, 范围, 页数) 记住上次的结果，↑↓、悬停这类重画不再查库
  var entries: [HistoryStore.Entry] {
    let key = CacheKey(
      revision: store.revision, query: query, favoritesOnly: favoritesOnly,
      limit: pages * Self.pageSize)
    if let cache, cache.key == key { return cache.entries }
    let entries = store.search(query, favoritesOnly: favoritesOnly, limit: key.limit)
    cache = (key, entries)
    return entries
  }

  /// 可能还有下一页（这一页取满了）
  var hasMore: Bool { entries.count >= pages * Self.pageSize }

  /// 取下一页（最后一行出现时、↓ 走过最后一条时）
  func loadMore() {
    if hasMore { pages += 1 }
  }

  var selected: HistoryStore.Entry? { Self.selected(selectedID, in: entries) }

  static func selected(_ id: UUID?, in entries: [HistoryStore.Entry]) -> HistoryStore.Entry? {
    entries.first { $0.id == id } ?? entries.first
  }

  /// 开 / 关历史时复位（和剪贴板面板隐藏时 reset 一样）
  func reset() {
    query = ""
    favoritesOnly = false
    showsActions = false
    pages = 1
    deleted = []
    copyTask?.cancel()
    copiedID = nil
  }

  private func resetSelection() {
    selectedID = nil
    selectionMotion = .instant
    pages = 1
  }

  /// ↑↓：首尾循环（同剪贴板；还有下一页时 ↓ 先取下一页再往下走）；按住连发时高亮不做动画
  func move(by offset: Int) {
    var entries = self.entries
    guard !entries.isEmpty else { return }
    let current = entries.firstIndex { $0.id == selectedID } ?? 0
    if offset > 0, current + offset >= entries.count, hasMore {
      loadMore()
      entries = self.entries
    }
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selectedID = entries[(current + offset + entries.count) % entries.count].id
  }

  /// 单击选中（指针驱动，glide）
  func select(_ entry: HistoryStore.Entry) {
    selectionMotion = .glide
    selectedID = entry.id
  }

  /// 删一条（不确认，⌘Z 撤销）
  func delete(_ entry: HistoryStore.Entry) {
    moveSelection(awayFrom: entry)
    deleted.append((entry, store.clears))
    withAnimation(Style.Motion.settle.animation()) { store.delete(entry.id) }
    // 行消失看得见，能 ⌘Z 撤销却只有读屏用户知道（岛自己也会播报）
    island?.show("已删除", detail: "⌘Z 撤销", tone: .info, symbol: "trash")
  }

  /// ⌘Z：插回最近删掉的一条并选中它；没有可撤销的返回 false（交还输入框自己的撤销）
  @discardableResult
  func undoDelete() -> Bool {
    deleted.removeAll { $0.clears != store.clears }
    guard let entry = deleted.popLast()?.entry else { return false }
    withAnimation(Style.Motion.settle.animation()) { store.restore(entry) }
    selectionMotion = .snap
    selectedID = entry.id
    Island.announce("已恢复")
    return true
  }

  /// ⌘C / 右键：复制译文（source：复制原文）；行尾同样换成「✓ 已复制」
  func copy(_ entry: HistoryStore.Entry, source: Bool = false) {
    // 原文、译文都是本 App 给出的文字：同时记进剪贴板历史（mac-native §5）
    Paster.write(string: source ? entry.source : entry.result, record: true)
    copiedID = entry.id
    copyTask?.cancel()
    copyTask = Task {
      try? await Task.sleep(for: Style.copiedHold)
      if !Task.isCancelled { copiedID = nil }
    }
    Island.announce(source ? "已复制原文" : "已复制译文")
  }

  /// 选中的这条要从列表里消失（删除、「收藏」范围里取消收藏）：选中挪到下一条（最后一条时挪到上一条）
  private func moveSelection(awayFrom entry: HistoryStore.Entry) {
    let entries = self.entries
    guard selectedID == entry.id, let index = entries.firstIndex(where: { $0.id == entry.id })
    else {
      return
    }
    let rest = entries.filter { $0.id != entry.id }
    selectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
    selectionMotion = .snap
  }

  func toggleFavorite(_ entry: HistoryStore.Entry) {
    // 「收藏」范围里取消收藏会让这行消失：选中和删除一样挪到下一条，不跳回第一条
    if favoritesOnly, entry.favorite { moveSelection(awayFrom: entry) }
    withAnimation(Style.Motion.settle.animation()) {
      store.setFavorite(entry.id, !entry.favorite)
    }
  }

  /// 历史开着时的 ⌘ 键：⌘K 开 / 关动作菜单、⌘⌫ 删、⌘Z 撤销删除、⌘C 复制译文、⇧⌘C 复制原文、⌘D 收藏 / 取消
  /// （⌘S 不再响应：全 App 的 ⌘S 只是存储，体检 A31）。修饰键不看大写锁定和 fn。
  /// 焦点在原文框（不是字段编辑器）时一律交还，免得在原文里按 ⌘⌫ 删掉历史；搜索框有选中文字时 ⌘C 交还系统；
  /// 动作菜单的过滤框里有字时 ⌘⌫ ⌘A ⌘V ⌘X ⌘Z 交给过滤框。做了才收起动作菜单
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let editor = event.window?.firstResponder as? NSTextView
    if let editor, !editor.isFieldEditor { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let code = Int(event.keyCode)
    if flags == [.command, .shift], code == kVK_ANSI_C {
      guard let entry = selected else {
        NSSound.beep()
        return true
      }
      showsActions = false
      copy(entry, source: true)
      return true
    }
    guard flags == .command else { return false }
    if code == kVK_ANSI_K {
      toggleActions()
      return true
    }
    if showsActions, !actionQuery.isEmpty,
      [kVK_Delete, kVK_ForwardDelete, kVK_ANSI_A, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z].contains(code)
    {
      return false
    }
    if code == kVK_ANSI_Z {
      guard undoDelete() else { return false }
      showsActions = false
      return true
    }
    if code == kVK_ANSI_C, (editor?.selectedRange().length ?? 0) > 0 { return false }
    guard [kVK_Delete, kVK_ForwardDelete, kVK_ANSI_C, kVK_ANSI_D].contains(code) else {
      return false
    }
    guard let entry = selected else {
      NSSound.beep()
      return true
    }
    showsActions = false
    switch code {
    case kVK_ANSI_C: copy(entry)
    case kVK_ANSI_D: toggleFavorite(entry)
    default: delete(entry)
    }
    return true
  }

  // MARK: ⌘K 动作菜单（体检 C6）

  /// 一条记录的动作（⌘K 和右键菜单同一份）：单条操作 ｜ 导出 ›（全部 / 只收藏 × CSV / Anki TSV）/ 清空历史…
  func actions(for entry: HistoryStore.Entry) -> [ActionMenu.Item] {
    typealias Item = ActionMenu.Item
    let exports = HistoryMenu.exports.map { favoritesOnly, anki in
      Item(
        title: (favoritesOnly ? "只导收藏" : "全部历史") + " · " + HistoryMenu.formatTitle(anki: anki),
        symbol: favoritesOnly ? "star" : "clock"
      ) { [unowned self] in
        HistoryMenu.export(store, favoritesOnly: favoritesOnly, anki: anki, island: island)
      }
    }
    var items = [
      Item(title: "重新翻译", symbol: "arrow.clockwise", shortcut: "↩") { [unowned self] in
        retranslate(entry)
      },
      Item(title: "复制译文", symbol: "doc.on.doc", shortcut: "⌘C") { [unowned self] in copy(entry) },
      Item(title: "复制原文", symbol: "text.quote", shortcut: "⇧⌘C") { [unowned self] in
        copy(entry, source: true)
      },
      Item(
        title: entry.favorite ? "取消收藏" : "收藏", symbol: entry.favorite ? "star.slash" : "star",
        shortcut: "⌘D"
      ) { [unowned self] in toggleFavorite(entry) },
      Item(title: "删除", symbol: "trash", shortcut: "⌘⌫", isDestructive: true) {
        [unowned self] in delete(entry)
      },
      Item(
        title: "导出", symbol: "square.and.arrow.up", id: "export", section: 1, submenu: exports),
    ]
    let counts = store.counts
    if counts.total > counts.favorites {
      items.append(
        Item(title: "清空历史…", symbol: "xmark.bin", section: 1, isDestructive: true) {
          [unowned self] in confirmClear()
        })
    }
    return items
  }

  /// 开着的这一级（进了「导出 ›」就是它的子列表），按过滤词过滤（ActionMenu.filter，同剪贴板 / 启动器）
  var filteredActions: [ActionMenu.Item] {
    guard let entry = selected else { return [] }
    let root = actions(for: entry)
    let items = actionSubmenu.flatMap { id in root.first { $0.id == id }?.submenu } ?? root
    return ActionMenu.filter(items, query: actionQuery)
  }

  /// 子列表顶上「‹ 导出」的标题；第一级时 nil
  var submenuTitle: String? {
    guard let actionSubmenu, let entry = selected else { return nil }
    return actions(for: entry).first { $0.id == actionSubmenu }?.title
  }

  /// ⌘K：没有选中的记录时不打开
  func toggleActions() {
    if showsActions || selected != nil { showsActions.toggle() }
  }

  /// 动作菜单开着时搜索框的编辑命令：↑↓ 选、↩ 执行（有子列表的进去）、→ 进子列表（光标在过滤词末尾时）、
  /// ← 在过滤词为空时回上一级、Esc 先回上一级再关菜单；其余（左右移光标、删字）交还输入框
  func handleMenuCommand(_ selector: Selector) -> Bool {
    let actions = filteredActions
    let selectedAction = actions.indices.contains(actionSelection) ? actions[actionSelection] : nil
    switch selector {
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
      guard !actions.isEmpty else { break }
      let offset = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
      actionSelection = (actionSelection + offset + actions.count) % actions.count
    case #selector(NSResponder.insertNewline(_:)):
      guard let selectedAction else {
        NSSound.beep()
        break
      }
      run(selectedAction)
    case #selector(NSResponder.moveRight(_:))
    where selectedAction?.submenu != nil && Self.caretAtEnd(of: actionQuery):
      if let selectedAction { run(selectedAction) }
    case #selector(NSResponder.moveLeft(_:)) where actionQuery.isEmpty,
      #selector(NSResponder.cancelOperation(_:)):
      if actionSubmenu != nil { leaveSubmenu() } else { showsActions = false }
    default: return false
    }
    return true
  }

  /// 有子列表的行：进去（过滤词清空、选第一行，菜单不关）；其余先关菜单再执行
  func run(_ action: ActionMenu.Item) {
    if action.submenu != nil {
      actionSubmenu = action.id
      actionQuery = ""
      actionSelection = 0
      return
    }
    showsActions = false
    action.run()
  }

  /// ← / Esc / 点「‹」：回到第一级，选中进去的那一行
  func leaveSubmenu() {
    guard let id = actionSubmenu else { return }
    actionSubmenu = nil
    actionQuery = ""
    let root = selected.map { actions(for: $0) } ?? []
    actionSelection = root.firstIndex { $0.id == id } ?? 0
  }

  /// 搜索框的光标在文字最后（没有选中文字）：→ 这时才开动作菜单 / 进子列表，否则照常往右移光标
  static func caretAtEnd(of text: String) -> Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return text.isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }
}

struct HistoryView: View {
  @Bindable var coordinator: TranslateCoordinator
  @State private var hovered: UUID?
  /// 搜索框拿着焦点：输入框底画焦点环（原文框和它只有一个亮）
  @State private var searchFocused = false
  /// 列表的滚动位置：选中跟随滚动按前缀和算目标 y（RevealsSelection），不按行 id 滚
  @State private var position = ScrollPosition()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 分组标题和行高：高亮按它们的前缀和定位，视图里的高度必须正好是这两个值
  static let headerHeight: CGFloat = 24
  static let rowHeight: CGFloat = 44
  /// 列表底下的内缩；选中跟随滚动时上下都留这么多（顶上没有内缩，往上滚时让出来）
  static let scrollMargin: CGFloat = 10

  struct DayGroup: Equatable {
    let title: String
    var entries: [HistoryStore.Entry]
  }

  var body: some View {
    @Bindable var list = coordinator.historyList
    let entries = list.entries
    VStack(spacing: 4) {
      HStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
          // 对话框式输入框：出现时抢焦点，关历史时把焦点还给原文框。⌘K 菜单开着时改成过滤动作
          CommandTextField(
            text: list.showsActions ? $list.actionQuery : $list.query,
            placeholder: list.showsActions ? "搜索动作" : "搜索原文或译文", isDialogField: true,
            fontSize: 13, onCommand: coordinator.handleHistoryCommand,
            onFocusChange: { searchFocused = $0 })
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .modifier(InputBox(isFocused: searchFocused))
        ScopeCapsule(title: "全部", isOn: !list.favoritesOnly) { list.favoritesOnly = false }
        ScopeCapsule(title: "收藏", isOn: list.favoritesOnly) { list.favoritesOnly = true }
      }
      .padding(.horizontal, 12)
      if entries.isEmpty {
        emptyState(list)
      } else {
        listView(entries, list: list)
      }
    }
    // ⌘K 从右下角弹出（同剪贴板 / 启动器的动作菜单）
    .overlay(alignment: .bottomTrailing) {
      if list.showsActions {
        ActionMenu(
          items: list.filteredActions, selection: list.actionSelection,
          header: list.submenuTitle, onBack: list.leaveSubmenu, maxRows: 8.5, onRun: list.run
        )
        .padding(.trailing, 12)
        .padding(.bottom, 12)
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: list.showsActions)
  }

  // MARK: 列表

  private func listView(_ entries: [HistoryStore.Entry], list: HistoryList) -> some View {
    let sections = Self.sections(entries)
    let selected = HistoryList.selected(list.selectedID, in: entries)
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(sections, id: \.title) { section in
          Text(section.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 10)
            .padding(.bottom, 3)
            .frame(
              maxWidth: .infinity, minHeight: Self.headerHeight, maxHeight: Self.headerHeight,
              alignment: .bottomLeading
            )
            .accessibilityAddTraits(.isHeader)
          ForEach(section.entries) { entry in
            row(entry, isSelected: entry.id == selected?.id, list: list)
              // 滚到最后一行时取下一页（体检 B22）
              .onAppear { if entry.id == entries.last?.id { list.loadMore() } }
          }
        }
      }
      .background(alignment: .topLeading) { highlight(selected, sections: sections, list: list) }
      .padding(.horizontal, 12)
      .padding(.bottom, Self.scrollMargin)
    }
    // 选中跟随滚动（共用 ListReveal，第 10 批）：回到一组的第一条时连分组标题一起露出来
    .modifier(
      RevealsSelection(
        position: $position, key: selected?.id, motion: list.selectionMotion,
        coveredTop: Self.scrollMargin, inset: Self.scrollMargin
      ) { selected.flatMap { Self.span(of: $0.id, in: sections) } }
    )
  }

  /// 一块中性高亮：按分组标题和行高的前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private func highlight(
    _ selected: HistoryStore.Entry?, sections: [DayGroup], list: HistoryList
  ) -> some View {
    if let selected, let offset = Self.offset(of: selected.id, in: sections) {
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      shape
        .fill(Style.selectedFill)
        .overlay { shape.contrastSelectionBorder() }
        .frame(height: Self.rowHeight)
        .offset(y: offset)
        .animation(list.selectionMotion.animation(reduced: reduceMotion), value: selected.id)
    }
  }

  /// 悬停底 0.10 s 淡入淡出；移出时只清自己（快速划过时下一行的「移入」可能先到）
  private func hover(_ id: UUID, inside: Bool) {
    withAnimation(.easeOut(duration: 0.10)) {
      if inside {
        hovered = id
      } else if hovered == id {
        hovered = nil
      }
    }
  }

  private func row(_ entry: HistoryStore.Entry, isSelected: Bool, list: HistoryList) -> some View {
    let hoverShape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    return Button {
      // 单击选中，双击重新翻译（和 ↩ 一样）
      list.showsActions = false
      if Style.isDoubleClick {
        coordinator.translate(entry.source)
      } else {
        list.select(entry)
      }
    } label: {
      HistoryRow(entry: entry, isCopied: list.copiedID == entry.id)
        .background(
          hovered == entry.id && !isSelected ? Style.hoverFill : .clear, in: hoverShape
        )
        // 翻译浮窗不激活本 App：SwiftUI 的 onHover 在这里不可靠，用 activeAlways 追踪区（同剪贴板行）
        .background(HoverTracker { hover(entry.id, inside: $0) })
    }
    .buttonStyle(.plain)
    // 和 ⌘K 同一份动作（分隔线、子菜单，不写键位）
    .contextMenu { ActionContextMenu { list.actions(for: entry) } }
    .transition(
      reduceMotion
        ? .opacity
        : .asymmetric(
          insertion: .move(edge: .top).combined(with: .opacity),
          removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
    )
    .accessibilityLabel("\(entry.source)，译文：\(entry.result)")
    .accessibilityValue(entry.favorite ? "已收藏" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: "重新翻译") { coordinator.translate(entry.source) }
    .accessibilityAction(named: "复制译文") { list.copy(entry) }
    .accessibilityAction(named: entry.favorite ? "取消收藏" : "收藏") { list.toggleFavorite(entry) }
    .accessibilityAction(named: "删除") { list.delete(entry) }
  }

  @ViewBuilder private func emptyState(_ list: HistoryList) -> some View {
    if !list.query.isEmpty {
      EmptyStateView(symbol: "magnifyingglass", title: "没有匹配的记录") { EmptyView() }
    } else if list.favoritesOnly {
      EmptyStateView(symbol: "star", title: "还没有收藏") {
        Text("翻译完按 ⌘D 收藏，收藏就是生词本").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    } else {
      EmptyStateView(symbol: "clock", title: "还没有翻译历史") {
        Text("翻译过的原文和译文会记在这里").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: 纯函数（配单测）

  /// 按天分组：今天 / 昨天 / M月d日 / yyyy年M月d日（条目已是新→旧）
  static func sections(
    _ entries: [HistoryStore.Entry], now: Date = .now, calendar: Calendar = .current
  ) -> [DayGroup] {
    var sections: [DayGroup] = []
    for entry in entries {
      let title = dayTitle(entry.createdAt, now: now, calendar: calendar)
      if sections.last?.title == title {
        sections[sections.count - 1].entries.append(entry)
      } else {
        sections.append(DayGroup(title: title, entries: [entry]))
      }
    }
    return sections
  }

  /// 分组标题（剪贴板按天分组也用它）
  static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "昨天"
    }
    var style = Date.FormatStyle(
      locale: Locale(identifier: "zh-Hans"), calendar: calendar, timeZone: calendar.timeZone)
    style =
      calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? style.month().day() : style.year().month().day()
    return date.formatted(style)
  }

  /// 行右侧的时间：时、分都写两位（18:07；分钟不指定两位会显示成「18:7」）
  static func rowTime(_ date: Date) -> String {
    date.formatted(
      .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        .locale(Locale(identifier: "zh-Hans")))
  }

  /// 高亮的 y：前面的分组标题和行高累加
  static func offset(of id: UUID, in sections: [DayGroup]) -> CGFloat? {
    var y: CGFloat = 0
    for section in sections {
      y += headerHeight
      if let index = section.entries.firstIndex(where: { $0.id == id }) {
        return y + CGFloat(index) * rowHeight
      }
      y += CGFloat(section.entries.count) * rowHeight
    }
    return nil
  }

  /// 选中跟随滚动要露出来的区间（滚动内容坐标；列表顶上没有内缩）：这一行；它是一组的第一条时连分组标题一起
  static func span(of id: UUID, in sections: [DayGroup]) -> ClosedRange<CGFloat>? {
    guard let top = offset(of: id, in: sections) else { return nil }
    let header = sections.contains { $0.entries.first?.id == id } ? headerHeight : 0
    return top - header...top + rowHeight
  }
}

/// 历史的导出和清空：浮窗「⋯」菜单、历史 ⌘K / 右键、设置 › 翻译共用（体检 B28 C6）
enum HistoryMenu {
  /// 能导出的四种：全部 / 只收藏 × CSV / Anki TSV（三处菜单同一张表）
  static let exports = [(false, false), (false, true), (true, false), (true, true)]

  static func scopeTitle(favoritesOnly: Bool) -> String {
    favoritesOnly ? "只导收藏（生词本）" : "全部历史"
  }

  static func formatTitle(anki: Bool) -> String {
    anki ? "TSV（Anki 卡片）…" : "CSV（表格）…"
  }

  /// 导出翻译历史 / 收藏：CSV 给表格（带 BOM，Excel 才认 UTF-8），TSV 给 Anki（正面原文、背面译文）。
  /// 结果（含没东西可导、写失败）用刘海说。从浮窗来的（本 App 不在前台）先激活本 App 才弹得出存储面板，
  /// 选完把前台还给原来的 App（同截图另存为）
  static func export(_ history: HistoryStore, favoritesOnly: Bool, anki: Bool, island: Island?) {
    let entries = history.search("", favoritesOnly: favoritesOnly, limit: 0)
    guard !entries.isEmpty else {
      island?.show(favoritesOnly ? "还没有收藏" : "还没有翻译历史", detail: "没有可导出的记录", tone: .warning)
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [anki ? .tabSeparatedText : .commaSeparatedText]
    panel.nameFieldStringValue = (favoritesOnly ? "翻译收藏" : "翻译历史") + (anki ? ".tsv" : ".csv")
    let previous = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
    if previous != nil {
      NSApp.activate()
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    panel.begin { response in
      previous?.activate()
      guard response == .OK, let url = panel.url else { return }
      let text = anki ? HistoryStore.tsv(entries) : "\u{FEFF}" + HistoryStore.csv(entries)
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        island?.show(
          "已导出 \(entries.count) 条", detail: url.lastPathComponent, symbol: "square.and.arrow.up")
      } catch {
        island?.show("导出失败", detail: error.localizedDescription, tone: .error)
      }
    }
  }

  /// 清空非收藏的历史（确认框由调用方弹，文案「清空翻译历史？」「收藏的记录会保留」）；结果用刘海说
  /// （历史列表多半没开着，清没清看不出来）
  static func clear(_ history: HistoryStore, island: Island?) {
    let kept = history.counts.favorites
    history.clearNonFavorites()
    island?.show(
      "已清空翻译历史", detail: kept > 0 ? "保留了 \(kept) 条收藏" : nil, symbol: "trash")
  }
}

/// 「导出」菜单的内容（SwiftUI 菜单：浮窗「⋯」、设置 › 翻译共用）：全部历史 / 只导收藏（生词本）两节，各 CSV / TSV
struct HistoryExportItems: View {
  let history: HistoryStore
  let island: Island?

  var body: some View {
    ForEach([false, true], id: \.self) { favoritesOnly in
      Section(HistoryMenu.scopeTitle(favoritesOnly: favoritesOnly)) {
        ForEach([false, true], id: \.self) { anki in
          Button(HistoryMenu.formatTitle(anki: anki)) {
            HistoryMenu.export(history, favoritesOnly: favoritesOnly, anki: anki, island: island)
          }
        }
      }
    }
  }
}

/// 一行 44：原文 13 + 译文 12 secondary 各一行；右侧时间 11 tertiary（分组已写日期，只写时:分）与黄色星标
private struct HistoryRow: View {
  let entry: HistoryStore.Entry
  let isCopied: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.oneLine(entry.source)).font(.system(size: 13))
        Text(Self.oneLine(entry.result)).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .truncationMode(.tail)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 4) {
        Group {
          if isCopied {
            Label("已复制", systemImage: "checkmark").labelStyle(.titleAndIcon)
          } else {
            Text(HistoryView.rowTime(entry.createdAt))
          }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .contentTransition(.opacity)
        if entry.favorite {
          Image(systemName: "star.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color(nsColor: .systemYellow))
            .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.easeOut(duration: Style.fadeIn), value: isCopied)
    }
    .padding(.horizontal, 10)
    .frame(height: HistoryView.rowHeight)
    .contentShape(.rect)
  }

  /// 多行原文压成一行（只取前 200 字，长文不必整段跑正则）
  private static func oneLine(_ text: String) -> String {
    String(text.prefix(200)).replacing(/\s+/, with: " ")
  }
}

/// 22 pt 范围胶囊：生效的品牌粉 0.16 底 + brandInk 字，没生效的无底 secondary（⇧Tab 在两者间切换）
private struct ScopeCapsule: View {
  let title: String
  let isOn: Bool
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .foregroundStyle(isOn ? Style.brandInk : .secondary)
        .background(isOn ? Style.brand.opacity(0.16) : .clear, in: .capsule)
        .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .fixedSize()
    .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: isOn)
    .help("范围（⇧Tab 切换）")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
