// 翻译历史（N7，mac-whisker §6 翻译）：整块替换浮窗的结果区（原文区不动，开 / 关时结果区 settle 交叉淡变），
// 和剪贴板同一套键盘列表——顶上搜索框（CommandTextField，↑↓ / ↩ / ⇧Tab / Esc 走 doCommandBy）+ 全部 / 收藏两枚
// 范围胶囊（品牌粉 0.16 底 + brandInk 字）；按 今天 / 昨天 / 日期 分组（11 semibold tertiary，无灰条、无分割线）；
// 行 44（原文、译文各一行，右侧时间与星标）；一块中性高亮按前缀和定位、在行间滑动（键盘 snap、连发 instant、点选 glide）。
// ↩ / 双击重新翻译，⌘⌫ 删（不确认，⌘Z 撤销）、⌘C 复制译文、⌘S 收藏；单条操作在右键菜单，条数和清空历史在浮窗的
// 「⋯」菜单，没有「共 N 条 · 收藏 M」底栏。列表状态在 HistoryList（协调器持有，搜索框命令和 ⌘ 键由协调器转过来）。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// 翻译历史的列表状态：搜索词、范围、选中（nil = 第一条）、撤销删除
@Observable final class HistoryList {
  let store: HistoryStore
  var query = "" { didSet { resetSelection() } }
  /// 范围：全部 / 收藏（生词本）
  var favoritesOnly = false { didSet { resetSelection() } }
  private(set) var selectedID: UUID?
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发与搜索 / 范围变化不动画，点选 glide
  private(set) var selectionMotion = Style.Motion.instant
  /// 刚复制了译文的那条：行尾的时间换成「✓ 已复制」1.2 s
  private(set) var copiedID: UUID?
  /// 删掉的条目（⌘Z 从后往前插回）；开 / 关历史时清空
  @ObservationIgnored private var deleted: [HistoryStore.Entry] = []
  @ObservationIgnored private var copyTask: Task<Void, Never>?

  init(store: HistoryStore) {
    self.store = store
  }

  /// 当前搜索词和范围下的条目（新→旧，最多 200 条）；读 store.revision，增删改后刷新。
  /// ponytail: 每次读都查库（走 created_at 索引、最多 200 行，约 1 ms），视图每次重算都查一遍；
  /// 历史上限最多 2000 条用不着缓存，真卡了再按 (revision, query, favoritesOnly) 记住上次的结果
  var entries: [HistoryStore.Entry] {
    _ = store.revision
    return store.search(query, favoritesOnly: favoritesOnly)
  }

  var selected: HistoryStore.Entry? { Self.selected(selectedID, in: entries) }

  static func selected(_ id: UUID?, in entries: [HistoryStore.Entry]) -> HistoryStore.Entry? {
    entries.first { $0.id == id } ?? entries.first
  }

  /// 开 / 关历史时复位（和剪贴板面板隐藏时 reset 一样）
  func reset() {
    query = ""
    favoritesOnly = false
    deleted = []
    copyTask?.cancel()
    copiedID = nil
  }

  private func resetSelection() {
    selectedID = nil
    selectionMotion = .instant
  }

  /// ↑↓：首尾循环（同剪贴板）；按住连发时高亮不做动画
  func move(by offset: Int) {
    let entries = self.entries
    guard !entries.isEmpty else { return }
    let current = entries.firstIndex { $0.id == selectedID } ?? 0
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selectedID = entries[(current + offset + entries.count) % entries.count].id
  }

  /// 单击选中（指针驱动，glide）
  func select(_ entry: HistoryStore.Entry) {
    selectionMotion = .glide
    selectedID = entry.id
  }

  /// 删一条（不确认，⌘Z 撤销）：删的是选中的就把选中挪到下一条（最后一条时挪到上一条）
  func delete(_ entry: HistoryStore.Entry) {
    let entries = self.entries
    if selectedID == entry.id, let index = entries.firstIndex(where: { $0.id == entry.id }) {
      let rest = entries.filter { $0.id != entry.id }
      selectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
      selectionMotion = .snap
    }
    deleted.append(entry)
    withAnimation(Style.Motion.settle.animation()) { store.delete(entry.id) }
    Self.announce("已删除，⌘Z 撤销")
  }

  /// ⌘Z：插回最近删掉的一条并选中它；没有可撤销的返回 false（交还输入框自己的撤销）
  @discardableResult
  func undoDelete() -> Bool {
    guard let entry = deleted.popLast() else { return false }
    withAnimation(Style.Motion.settle.animation()) { store.restore(entry) }
    selectionMotion = .snap
    selectedID = entry.id
    Self.announce("已恢复")
    return true
  }

  /// ⌘C / 右键：复制译文
  func copy(_ entry: HistoryStore.Entry) {
    Paster.write(string: entry.result)
    copiedID = entry.id
    copyTask?.cancel()
    copyTask = Task {
      try? await Task.sleep(for: .seconds(1.2))
      if !Task.isCancelled { copiedID = nil }
    }
    Self.announce("已复制译文")
  }

  func toggleFavorite(_ entry: HistoryStore.Entry) {
    // 「收藏」范围里取消收藏会让这行消失：和删除一样收拢
    withAnimation(Style.Motion.settle.animation()) {
      store.setFavorite(entry.id, !entry.favorite)
    }
  }

  /// 历史开着时的 ⌘ 键（协调器只转纯 ⌘ 过来）：⌘⌫ 删、⌘Z 撤销删除、⌘C 复制译文、⌘S 收藏 / 取消。
  /// 焦点在原文框（不是字段编辑器）时一律交还，免得在原文里按 ⌘⌫ 删掉历史；搜索框有选中文字时 ⌘C 交还系统
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let editor = event.window?.firstResponder as? NSTextView
    if let editor, !editor.isFieldEditor { return false }
    let code = Int(event.keyCode)
    if code == kVK_ANSI_Z { return undoDelete() }
    if code == kVK_ANSI_C, (editor?.selectedRange().length ?? 0) > 0 { return false }
    guard [kVK_Delete, kVK_ForwardDelete, kVK_ANSI_C, kVK_ANSI_S].contains(code) else {
      return false
    }
    guard let entry = selected else {
      NSSound.beep()
      return true
    }
    switch code {
    case kVK_ANSI_C: copy(entry)
    case kVK_ANSI_S: toggleFavorite(entry)
    default: delete(entry)
    }
    return true
  }

  /// 没有底栏提示，删除 / 复制的结果主动播报给 VoiceOver
  private static func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}

struct HistoryView: View {
  @Bindable var coordinator: TranslateCoordinator
  @State private var hovered: UUID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  /// 分组标题和行高：高亮按它们的前缀和定位，视图里的高度必须正好是这两个值
  static let headerHeight: CGFloat = 24
  static let rowHeight: CGFloat = 44

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
          // 对话框式输入框：出现时抢焦点，关历史时把焦点还给原文框
          CommandTextField(
            text: $list.query, placeholder: "搜索原文或译文", isDialogField: true, fontSize: 13,
            onCommand: coordinator.handleHistoryCommand)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .modifier(InputBox())
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
  }

  // MARK: 列表

  private func listView(_ entries: [HistoryStore.Entry], list: HistoryList) -> some View {
    let sections = Self.sections(entries)
    let selected = HistoryList.selected(list.selectedID, in: entries)
    return ScrollViewReader { proxy in
      ScrollView {
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
              .id(section.title)
            ForEach(section.entries) { entry in
              row(entry, isSelected: entry.id == selected?.id, list: list)
            }
          }
        }
        .background(alignment: .topLeading) { highlight(selected, sections: sections, list: list) }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
      }
      .onChange(of: selected?.id) { _, id in
        guard let id else { return }
        withAnimation(
          list.selectionMotion == .snap ? Style.Motion.snap.animation(reduced: reduceMotion) : nil
        ) {
          // 回到第一条时连分组标题一起露出来
          if id == entries.first?.id, let first = sections.first {
            proxy.scrollTo(first.title, anchor: .top)
          } else {
            proxy.scrollTo(id)
          }
        }
      }
    }
  }

  /// 一块中性高亮：按分组标题和行高的前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private func highlight(
    _ selected: HistoryStore.Entry?, sections: [DayGroup], list: HistoryList
  ) -> some View {
    if let selected, let offset = Self.offset(of: selected.id, in: sections) {
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      shape
        .fill(Style.selectedFill)
        // 增强对比度：中性选中再加 1 pt 品牌粉 0.6 描边（Whisker §7）
        .overlay {
          if contrast == .increased { shape.strokeBorder(Style.brand.opacity(0.6), lineWidth: 1) }
        }
        .frame(height: Self.rowHeight)
        .offset(y: offset)
        .animation(list.selectionMotion.animation(reduced: reduceMotion), value: selected.id)
    }
  }

  private func row(_ entry: HistoryStore.Entry, isSelected: Bool, list: HistoryList) -> some View {
    let hoverShape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    return Button {
      // 单击选中，双击重新翻译（和 ↩ 一样）
      if Style.isDoubleClick {
        coordinator.translate(entry.source)
      } else {
        list.select(entry)
      }
    } label: {
      HistoryRow(entry: entry, isCopied: list.copiedID == entry.id)
        .background(
          hovered == entry.id && !isSelected ? Style.hoverFill : .clear, in: hoverShape)
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside {
        hovered = entry.id
      } else if hovered == entry.id {
        hovered = nil
      }
    }
    .animation(.easeOut(duration: 0.10), value: hovered == entry.id)
    .id(entry.id)
    .contextMenu {
      Button("重新翻译") { coordinator.translate(entry.source) }
      Divider()
      Button("复制原文") { Paster.write(string: entry.source) }
      Button("复制译文") { list.copy(entry) }
      Button(entry.favorite ? "取消收藏" : "收藏") { list.toggleFavorite(entry) }
      Divider()
      Button("删除", role: .destructive) { list.delete(entry) }
    }
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
        Text("翻译完按 ⌘S 收藏，收藏就是生词本").font(.system(size: 12)).foregroundStyle(.secondary)
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
            Text(
              entry.createdAt.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                  .locale(Locale(identifier: "zh-Hans")))
            )
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
