// 剪贴板面板根视图（Whisker，mac-whisker §6 剪贴板）：760×480。56 pt 搜索框 + 设置 / 图钉；一行 22 pt 范围胶囊
// （全部 / 收藏 / 片段）+ 生效筛选标签 +「筛选」菜单；左列表 320（无搜索词按天分组吸顶，有搜索词按相关度，
// 一块中性高亮在行间滑动，新条目从顶部挤入、删除缩小淡出），右检查器卡片；底栏只留「条数 / 提示 ｜ 粘贴 ↩ · 操作 ⌘K」，
// ⌘K 操作面板从右下角放大（搜索框这时用来过滤操作）。按住 ⌘ 150 ms 后亮出 ⌘1–9。状态和操作都在 ClipboardPanelModel。

import SwiftUI

struct ClipboardPanelView: View {
  @Bindable var model: ClipboardPanelModel
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.clipboardShowPreview) private var showPreview = true
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 按住 ⌘ 超过 150 ms：亮出 ⌘1–9 键帽
  @State private var holdsCommand = false
  @State private var showsShortcuts = false
  /// 已经滚过顶部的分组数：这些分组的标题正吸顶（或已滚走），加材质底；平时没有灰条。
  /// 只存这个整数，别存滚动位置（每帧都会让整个面板重算）
  @State private var pinnedSections = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let listWidth: CGFloat = 320
  static let headerHeight: CGFloat = 24

  var body: some View {
    let items = model.visibleItems
    let selected = model.selectedItem
    VStack(spacing: 0) {
      searchBar
      filterBar
      Style.hairline.frame(height: 0.5)
      if !trusted { permissionBanner }
      HStack(spacing: 0) {
        list(items, selected: selected)
          .frame(width: showPreview && selected != nil ? Self.listWidth : nil)
          .frame(maxWidth: showPreview && selected != nil ? nil : .infinity)
        if showPreview, let selected {
          Style.hairline.frame(width: 0.5)
          PreviewView(item: selected, model: model)
            // 卡片（去掉内缩 6）的位置：⌘Y 放大预览从这里长出来
            .onGeometryChange(for: CGRect.self) {
              $0.frame(in: .global).insetBy(dx: 6, dy: 6)
            } action: {
              model.cardFrame = $0
            }
            .onDisappear { model.cardFrame = nil }
        }
      }
      bottomBar(count: items.count)
    }
    .overlay(alignment: .bottomTrailing) {
      if model.showsActions {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection, onRun: model.run
        )
        .padding(.trailing, 12)
        .padding(.bottom, 40)
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: 0.15),
      value: model.showsActions
    )
    .overlay {
      if let dialog = model.dialog { DialogOverlay(model: model, dialog: dialog) }
    }
    .onModifierKeysChanged(mask: [.command]) { _, keys in holdsCommand = keys.contains(.command) }
    .task(id: holdsCommand) {
      guard holdsCommand else {
        showsShortcuts = false
        return
      }
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { showsShortcuts = true }
    }
    .onChange(of: model.store.items.first?.id) { model.itemsChanged() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
  }

  // MARK: 搜索与筛选

  private var searchBar: some View {
    HStack(spacing: 12) {
      Image(systemName: model.showsActions ? "command" : "magnifyingglass")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentTransition(.symbolEffect(.replace))
      // ⌘K 面板开着时，搜索框改成过滤操作
      CommandTextField(
        text: model.showsActions ? $model.actionQuery : $model.query,
        placeholder: model.showsActions ? "搜索操作" : "搜索剪贴板历史", fontSize: 20,
        onCommand: model.handleCommand)
      Button("设置", systemImage: "gearshape", action: model.openSettings)
        .help("设置（⌘,）")
      Toggle(isOn: pinned) { Image(systemName: hideOnUnfocus ? "pin" : "pin.fill") }
        .toggleStyle(.button)
        .help(hideOnUnfocus ? "固定面板：点外面不关闭" : "取消固定")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .frame(height: 56)
  }

  private var filterBar: some View {
    HStack(spacing: 6) {
      ForEach(ClipboardPanelModel.Scope.allCases, id: \.self) { scope in
        Chip(title: scope.title, isOn: model.scope == scope) { model.scope = scope }
      }
      if !activeFilters.isEmpty {
        Divider().frame(height: 14).padding(.horizontal, 2)
        ForEach(activeFilters, id: \.title) { filter in
          Chip(title: filter.title, isOn: true, removable: true, action: filter.clear)
        }
      }
      Spacer(minLength: 0)
      filterMenu
      Button("新建片段（⌘N）", systemImage: "plus") { model.dialog = .newSnippet }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("新建片段（⌘N）")
    }
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 12)
    .frame(height: 30, alignment: .top)
  }

  /// 「筛选」菜单：类型 / 形态 / 来源 / 分组，各是一个带勾选的子菜单
  private var filterMenu: some View {
    Menu {
      Picker("类型", selection: $model.kind) {
        Text("全部").tag(ClipItem.Kind?.none)
        Text("文本").tag(ClipItem.Kind?.some(.text))
        Text("图片").tag(ClipItem.Kind?.some(.image))
        Text("文件").tag(ClipItem.Kind?.some(.file))
      }
      Picker("形态", selection: $model.form) {
        Text("全部").tag(ContentForm?.none)
        ForEach(ContentForm.allCases, id: \.self) { Text($0.title).tag(ContentForm?.some($0)) }
      }
      Picker("来源", selection: $model.sourceBundleID) {
        Text("全部").tag(String?.none)
        ForEach(model.sources, id: \.bundleID) { Text($0.name).tag(String?.some($0.bundleID)) }
      }
      Picker("分组", selection: $model.groupFilter) {
        Text("全部").tag(ClipboardPanelModel.GroupFilter.all)
        Text("未分组").tag(ClipboardPanelModel.GroupFilter.ungrouped)
        ForEach(model.store.groups) {
          Text($0.name).tag(ClipboardPanelModel.GroupFilter.group($0.id))
        }
      }
      Divider()
      Button("管理分组…") { model.dialog = .manageGroups }
    } label: {
      Label("筛选", systemImage: "line.3.horizontal.decrease")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("按类型、形态、来源、分组筛选")
  }

  /// 生效中的筛选条件，每个一个可移除的标签
  private var activeFilters: [(title: String, clear: () -> Void)] {
    var filters: [(String, () -> Void)] = []
    if let kind = model.kind, model.form == nil {
      filters.append(([.text: "文本", .image: "图片", .file: "文件"][kind] ?? "", { model.kind = nil }))
    }
    if let form = model.form { filters.append((form.title, { model.form = nil })) }
    if let source = model.sourceBundleID {
      let name = model.sources.first { $0.bundleID == source }?.name ?? source
      filters.append((name, { model.sourceBundleID = nil }))
    }
    switch model.groupFilter {
    case .all: break
    case .ungrouped: filters.append(("未分组", { model.groupFilter = .all }))
    case .group(let id):
      let name = model.store.groups.first { $0.id == id }?.name ?? "分组"
      filters.append((name, { model.groupFilter = .all }))
    }
    return filters
  }

  private var pinned: Binding<Bool> {
    Binding(get: { !hideOnUnfocus }, set: { hideOnUnfocus = !$0 })
  }

  private var permissionBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.shield").foregroundStyle(.orange)
      Text("授权「辅助功能」后才能直接粘贴回原 App，现在只会写进剪贴板")
      Spacer()
      Button("去授权") {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
      }
      .controlSize(.small)
    }
    .font(.system(size: 12))
    .padding(.horizontal, 16)
    .padding(.vertical, 7)
    .background(Color(nsColor: .systemOrange).opacity(0.08))
  }

  // MARK: 列表

  @ViewBuilder private func list(_ items: [ClipItem], selected: ClipItem?) -> some View {
    if items.isEmpty {
      emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      let sections = model.query.isEmpty ? Self.daySections(items) : nil
      let tops = sections.map(Self.sectionTops) ?? []
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if let sections {
              ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                Section {
                  rows(section.rows, selected: selected)
                } header: {
                  Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                    // 高度必须正好是 headerHeight：高亮按它累加定位
                    .frame(
                      maxWidth: .infinity, minHeight: Self.headerHeight,
                      maxHeight: Self.headerHeight,
                      alignment: .bottomLeading
                    )
                    .background(
                      index < pinnedSections
                        ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear))
                }
              }
            } else {
              rows(Array(items.enumerated()), selected: selected)
            }
          }
          .background(alignment: .topLeading) {
            highlight(items: items, sections: sections, selected: selected)
          }
          .animation(model.listMotion.animation(reduced: reduceMotion), value: items.map(\.id))
          .onChange(of: model.listGeneration) { model.settleList() }
          .padding(.horizontal, 6)
          .padding(.bottom, 6)
        }
        .onScrollGeometryChange(for: Int.self) { geometry in
          let y = geometry.contentOffset.y + geometry.contentInsets.top
          return tops.lastIndex { y > $0 + 0.5 }.map { $0 + 1 } ?? 0
        } action: { _, count in
          pinnedSections = count
        }
        .onChange(of: selected?.id) { _, id in
          guard let id else { return }
          withAnimation(
            model.selectionMotion == .instant
              ? nil : Style.Motion.snap.animation(reduced: reduceMotion)
          ) {
            proxy.scrollTo(id)
          }
        }
      }
    }
  }

  /// 一块中性高亮：按分组标题和行高的前缀和定位，在行间滑动（不用 matchedGeometryEffect）
  @ViewBuilder private func highlight(
    items: [ClipItem], sections: [(title: String, rows: [(offset: Int, element: ClipItem)])]?,
    selected: ClipItem?
  ) -> some View {
    if let selected, model.multiSelection.isEmpty,
      let offset = Self.offset(of: selected.id, items: items, sections: sections)
    {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .fill(Style.selectedFill)
        .frame(height: ClipRowView.height)
        .offset(y: offset)
        .animation(model.selectionMotion.animation(reduced: reduceMotion), value: selected.id)
    }
  }

  /// 各分组在列表里的起始 y（标题 + 行高累加）
  static func sectionTops(_ sections: [(title: String, rows: [(offset: Int, element: ClipItem)])])
    -> [CGFloat]
  {
    var y: CGFloat = 0
    return sections.map { section in
      defer { y += headerHeight + CGFloat(section.rows.count) * ClipRowView.height }
      return y
    }
  }

  static func offset(
    of id: UUID, items: [ClipItem],
    sections: [(title: String, rows: [(offset: Int, element: ClipItem)])]?
  ) -> CGFloat? {
    guard let sections else {
      return items.firstIndex { $0.id == id }.map { CGFloat($0) * ClipRowView.height }
    }
    var y: CGFloat = 0
    for section in sections {
      y += headerHeight
      if let index = section.rows.firstIndex(where: { $0.element.id == id }) {
        return y + CGFloat(index) * ClipRowView.height
      }
      y += CGFloat(section.rows.count) * ClipRowView.height
    }
    return nil
  }

  private func rows(_ rows: [(offset: Int, element: ClipItem)], selected: ClipItem?) -> some View {
    ForEach(rows, id: \.element.id) { index, item in
      Button {
        model.click(item)
      } label: {
        ClipRowView(
          item: item, form: model.contentForm(of: item),
          shortcutIndex: index < 9 ? index : nil, showsShortcut: showsShortcuts,
          isSelected: item.id == selected?.id,
          isChecked: model.multiSelection.isEmpty ? nil : model.multiSelection.contains(item.id),
          groupName: groupBadge(for: item), images: model.store.images)
      }
      .buttonStyle(.plain)
      .id(item.id)
      .contextMenu { contextMenu(for: item) }
      .transition(
        reduceMotion
          ? .opacity
          : .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
    }
  }

  private func groupBadge(for item: ClipItem) -> String? {
    guard model.groupFilter == .all, let id = item.groupID else { return nil }
    return model.store.groups.first { $0.id == id }?.name
  }

  /// 无搜索词时按天分组：今天 / 昨天 / M月d日 / yyyy年M月d日。行号是在整个列表里的序号（⌘数字用）
  private static func daySections(_ items: [ClipItem]) -> [(
    title: String, rows: [(offset: Int, element: ClipItem)]
  )] {
    var sections: [(title: String, rows: [(offset: Int, element: ClipItem)])] = []
    for row in items.enumerated() {
      let title = dayTitle(row.element.copiedAt)
      if sections.last?.title == title {
        sections[sections.count - 1].rows.append(row)
      } else {
        sections.append((title, [row]))
      }
    }
    return sections
  }

  private static func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    let chinese = Locale(identifier: "zh-Hans")
    return calendar.isDate(date, equalTo: .now, toGranularity: .year)
      ? date.formatted(.dateTime.month().day().locale(chinese))
      : date.formatted(.dateTime.year().month().day().locale(chinese))
  }

  @ViewBuilder private func contextMenu(for item: ClipItem) -> some View {
    Button("粘贴") { model.paste([item]) }
    if item.richType != nil { Button("粘贴为纯文本") { model.paste([item], plainText: true) } }
    Button("复制") {
      model.select(item)
      model.copySelection()
    }
    Divider()
    Button(item.favorite ? "取消收藏" : "收藏") { model.store.toggleFavorite([item.id]) }
    if item.favorite || item.isSnippet { Button("备注…") { model.dialog = .note(item.id) } }
    if item.kind == .text {
      if !item.isSnippet {
        Button("存为片段") { model.store.update([item.id]) { $0.isSnippet = true } }
      }
      Button("编辑内容…") { model.dialog = .edit(item.id) }
      Button("翻译") { model.translate(item) }
    }
    Menu("分组") {
      ForEach(model.store.groups) { group in
        Button(group.name) { model.assign([item.id], to: group.id) }.disabled(
          item.groupID == group.id)
      }
      if item.groupID != nil { Button("移出分组") { model.assign([item.id], to: nil) } }
      Divider()
      Button("新建分组…") { model.dialog = .newGroup([item.id]) }
    }
    if item.kind == .file {
      Button("在访达中显示") {
        NSWorkspace.shared.activateFileViewerSelecting(
          (item.filePaths ?? []).map { URL(filePath: $0) })
      }
    }
    Divider()
    Button("删除", role: .destructive) { model.delete([item.id]) }
  }

  // MARK: 空态与底栏

  @ViewBuilder private var emptyState: some View {
    let filtered =
      !model.query.isEmpty || model.kind != nil || model.form != nil
      || model.sourceBundleID != nil || model.groupFilter != .all
    if filtered {
      ContentUnavailableView {
        Label("没有匹配的条目", systemImage: "magnifyingglass")
      } actions: {
        Button("清除搜索和筛选") { model.reset() }
      }
    } else {
      switch model.scope {
      case .all:
        ContentUnavailableView(
          "还没有剪贴板历史", systemImage: "doc.on.clipboard",
          description: Text("复制的文本、图片和文件会出现在这里"))
      case .favorites:
        ContentUnavailableView(
          "还没有收藏", systemImage: "star", description: Text("选中条目按 ⌘D 收藏；收藏不受条数和天数上限影响"))
      case .snippets:
        ContentUnavailableView {
          Label("还没有片段", systemImage: "text.badge.star")
        } description: {
          Text("片段是常用文本，支持 {date}、{clipboard} 占位符")
        } actions: {
          Button("新建片段") { model.dialog = .newSnippet }
        }
      }
    }
  }

  @ViewBuilder private func bottomBar(count: Int) -> some View {
    HStack(spacing: 12) {
      if let toast = model.toast {
        Group {
          switch toast {
          case .message(let text):
            Label(text, systemImage: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color(nsColor: .systemGreen), Color(nsColor: .systemGreen))
              .symbolEffect(.bounce, value: text)
          case .undo(let count):
            HStack(spacing: 8) {
              Text("已删除 \(count) 条").foregroundStyle(.secondary)
              Button("撤销（⌘Z）", action: model.undoDelete)
                .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
            }
          }
        }
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        Spacer()
      } else if !model.multiSelection.isEmpty {
        multiSelectBar
      } else {
        Text(countText(count))
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        Spacer()
        if count > 0 {
          hint("↩", "粘贴")
          Button {
            model.showsActions.toggle()
          } label: {
            hint("⌘K", "操作")
          }
          .buttonStyle(.plain)
        }
      }
    }
    .animation(.smooth(duration: 0.24), value: model.toast)
    .font(.system(size: 12))
    .buttonStyle(.borderless)
    .padding(.horizontal, 14)
    .frame(height: 36)
    .overlay(alignment: .top) { Style.hairline.frame(height: 0.5) }
  }

  private func hint(_ key: String, _ title: String) -> some View {
    HStack(spacing: 6) {
      Text(title).foregroundStyle(.primary)
      KeyCap(key)
    }
  }

  private func countText(_ count: Int) -> String {
    let total = model.store.items.count
    return count == total ? "\(total) 条" : "\(count) / \(total) 条"
  }

  @ViewBuilder private var multiSelectBar: some View {
    let ids = model.multiSelection
    let items = model.store.items.filter { ids.contains($0.id) }
    Text("已选 \(ids.count) 条").foregroundStyle(.secondary)
    Button("取消选择") { model.multiSelection = [] }
    Spacer()
    Button(items.allSatisfy { $0.kind == .text } ? "合并粘贴" : "依次粘贴") { model.pasteSelection() }
    Button(items.allSatisfy(\.favorite) ? "取消收藏" : "收藏") { model.store.toggleFavorite(ids) }
    Menu("分组") {
      ForEach(model.store.groups) { group in Button(group.name) { model.assign(ids, to: group.id) }
      }
      Button("移出分组") { model.assign(ids, to: nil) }
      Divider()
      Button("新建分组…") { model.dialog = .newGroup(ids) }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    Button("删除", role: .destructive) { model.delete(ids) }
  }
}

/// 22 pt 胶囊：范围切换（选中品牌粉 0.16 底 + 粉字，未选中无底色）与生效筛选标签
private struct Chip: View {
  let title: String
  let isOn: Bool
  var removable = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title).lineLimit(1)
        if removable { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
      }
      .padding(.horizontal, 10)
      .frame(height: 22)
      .foregroundStyle(isOn ? Style.brandInk : .secondary)
      .background(isOn ? Style.brand.opacity(0.16) : .clear, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .animation(Style.Motion.snap.animation(), value: isOn)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityHint(removable ? "移除这个筛选" : "")
  }
}
