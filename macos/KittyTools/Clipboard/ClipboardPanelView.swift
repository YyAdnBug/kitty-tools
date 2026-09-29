// 剪贴板面板根视图（透镜指令条 Lens Bar，mac-whisker §6 剪贴板）：宽 720、贴在屏幕上方 20%（和启动器同位置），
// 高度按条数伸缩、顶边不动、≤ 520（height(for:)；透镜预留是常数，↑↓ 永远不改窗口高度）。
// 56 pt 搜索线 = 放大镜 + 粉色筛选标签 + 输入框；单列满宽列表（始终按天分组吸顶，搜索只过滤，体检 A6），
// 行 40，选中行原地展开成透镜（LensView），一块中性高亮在行间滑动、和透镜一起伸缩（前缀和定位）；
// 片段范围第一行固定一条虚线的「＋ 新建片段 ⌘N」；底栏 36 = （已暂停记录）条数 / 修饰键提示 / 多选动词 ｜ 粘贴 ↩ · 操作 ⌘K ｜
// 齿轮 图钉。
// Tab 筛选面板从搜索栏左下长出、⌘K 操作面板从底栏右下长出、多选底栏「收藏夹…」的列表从按钮上方长出（共用 Shell/ActionMenu）；
// 右键菜单和 ⌘K 同一份动作表；行能拖到别的 App（ClipDrag）；对话框从搜索栏下沿落下。
// 状态和操作都在 ClipboardPanelModel。

import SwiftUI

struct ClipboardPanelView: View {
  /// day = 那天的零点：分组和行的身份按它，不按标题（过了午夜「今天」改叫「昨天」，还是同一组、同一批行）
  typealias DaySection = (day: Date, title: String, rows: [(offset: Int, element: ClipItem)])

  @Bindable var model: ClipboardPanelModel
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.clipboardShowPreview) private var showsLens = true
  /// 默认粘贴为纯文本：底栏按住 ⌥ 的提示、右键菜单的替代粘贴跟着换名字
  @AppStorage(Prefs.clipboardPastePlain) private var pastesPlain = false
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 正按着的 ⌘ / ⌥
  @State private var heldKeys: EventModifiers = []
  /// 按住超过 150 ms 才算「按住」（S4）：⌘ 亮出 ⌘1–9 键帽，⌘ / ⌥ 把底栏左边换成对应的替代动作。
  /// 按 ⌘K、⌘D 这类组合键时一闪而过的 ⌘ 不换，底栏不闪；松开立刻收
  @State private var shownKeys: EventModifiers = []
  /// 多选底栏「收藏夹…」按钮的左缘（面板坐标）：收藏夹列表锚在它上方
  @State private var groupsButtonX: CGFloat = 0
  /// 已经滚过顶部的分组数：这些分组的标题正吸顶（或已滚走），加材质底；平时没有灰条。
  /// 只存这个整数，别存滚动位置（每帧都会让整个面板重算）
  @State private var pinnedSections = 0
  @State private var position = ScrollPosition()
  /// 滚动位置放在不被观察的盒子里：只在选中变化时读，改它不重画面板
  @State private var viewport = Viewport()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  static let width: CGFloat = 720
  static let searchHeight: CGFloat = 56
  static let barHeight: CGFloat = 36
  static let headerHeight: CGFloat = 24
  static let bannerHeight: CGFloat = 30
  /// 列表四周内缩（面板圆角 16 − 6 = 高亮 / 透镜的圆角 10，同心）
  static let inset: CGFloat = 6
  /// 列表区最高 427.5：连同搜索线、发丝线、底栏正好 520
  static let maxListHeight: CGFloat = 427.5
  static let emptyListHeight: CGFloat = 140
  /// 筛选面板 / ⌘K 开着时列表区至少这么高（8.5 行菜单 + 上下余量），短列表时面板先长到放得下
  static let paletteListHeight: CGFloat = ActionMenu.rowHeight * 8.5 + 26
  /// 面板根视图的坐标系（多选底栏按钮报位置用）
  nonisolated private static let space = "clipboardPanel"

  var body: some View {
    let items = model.visibleItems
    let selected = model.selectedItem(in: items)
    let sections = Self.daySections(items)
    let lensOpen = showsLens && model.multiSelection.isEmpty
    let newSnippet = model.showsNewSnippetRow(in: items)
    let layout = ListLayout(
      leading: newSnippet ? ClipRowView.height : 0, sections: sections,
      lens: lensOpen
        ? selected.map { ($0.id, Lens.height(for: $0, form: model.contentForm(of: $0))) } : nil)
    VStack(spacing: 0) {
      searchBar
      Hairline()
      if !trusted { permissionBanner }
      listArea(items, layout: layout, selected: selected, lensOpen: lensOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { DialogOverlay(model: model) }
      bottomBar(count: items.count)
    }
    .overlay(alignment: .topLeading) {
      if model.palette == .filters {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: "没有匹配的筛选", anchor: .topLeading, maxRows: 8.5, onRun: model.run
        )
        .padding(.leading, 12)
        .padding(.top, 60 + (trusted ? 0 : Self.bannerHeight))
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if model.palette == .actions {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: model.submenuTitle == nil ? "没有匹配的操作" : "没有匹配的收藏夹",
          header: model.submenuTitle, onBack: model.leaveSubmenu, maxRows: 8.5, onRun: model.run
        )
        // 右缘对着底栏「操作 ⌘K」：右内边距 14 + 图钉 + 齿轮 + 竖线和间距
        .padding(.trailing, 80)
        .padding(.bottom, Self.barHeight + 4)
      }
    }
    // 多选底栏「收藏夹…」：锚在按钮上方（左缘对齐，放不下时往左挪）
    .overlay(alignment: .bottomLeading) {
      if model.palette == .groups {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: "没有匹配的收藏夹", anchor: .bottomLeading, maxRows: 8.5, onRun: model.run
        )
        .padding(
          .leading,
          min(max(groupsButtonX - 8, Self.inset), Self.width - ActionMenu.width - Self.inset)
        )
        .padding(.bottom, Self.barHeight + 4)
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: model.palette
    )
    .onChange(
      of: Self.height(
        rows: items.count + (newSnippet ? 1 : 0), sections: sections.count,
        reservesLens: showsLens && !items.isEmpty, banner: !trusted, model: model),
      initial: true
    ) { _, height in model.resize(height) }
    .onModifierKeysChanged(mask: [.command, .option]) { _, keys in heldKeys = keys }
    .task(id: heldKeys) {
      shownKeys.formIntersection(heldKeys)
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { shownKeys = heldKeys }
    }
    .onChange(of: model.store.items.first?.id) { model.itemsChanged() }
    .coordinateSpace(.named(Self.space))
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
  }

  // MARK: 高度

  /// 面板高度（窗口和截图自检同一个算法）：56 + 0.5 +（授权横幅）+ 列表区 + 36。列表区 =
  /// min(上下内缩 12 + 24 × 分组数 + 40 × 行数 + 透镜预留, 427.5)，空列表 140；对话框开着给满，浮起的菜单开着至少放得下 8.5 行
  static func height(
    rows: Int, sections: Int, reservesLens: Bool, banner: Bool, model: ClipboardPanelModel
  ) -> CGFloat {
    var list = listHeight(rows: rows, sections: sections, reservesLens: reservesLens)
    if model.dialog != nil {
      list = maxListHeight
    } else if model.palette != nil {
      list = max(list, paletteListHeight)
    }
    return searchHeight + 0.5 + (banner ? bannerHeight : 0) + list + barHeight
  }

  static func listHeight(rows: Int, sections: Int, reservesLens: Bool) -> CGFloat {
    guard rows > 0 else { return emptyListHeight }
    let content =
      inset * 2 + headerHeight * CGFloat(sections) + ClipRowView.height * CGFloat(rows)
      + (reservesLens ? Lens.reserve : 0)
    return min(content, maxListHeight)
  }

  /// 按模型现算（AppDelegate 建窗口、截图自检用）；视图里用上面那个，省一次搜索
  static func height(
    for model: ClipboardPanelModel,
    showsLens: Bool = UserDefaults.standard.bool(forKey: Prefs.clipboardShowPreview),
    banner: Bool = !Permissions.isAccessibilityTrusted
  ) -> CGFloat {
    let items = model.visibleItems
    return height(
      rows: items.count + (model.showsNewSnippetRow(in: items) ? 1 : 0),
      sections: daySections(items).count,
      reservesLens: showsLens && !items.isEmpty, banner: banner, model: model)
  }

  // MARK: 搜索线

  private var searchBar: some View {
    let tokens = model.tokens
    return HStack(spacing: 6) {
      Image(systemName: searchSymbol)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
      ForEach(tokens) { token in
        TokenChip(
          token: token, armed: model.armsLastToken && token.id == tokens.last?.id,
          open: { model.palette = .filters }, remove: { model.remove(token.kind) }
        )
        // 对话框开着时标签点不动：压暗只盖列表区，别在对话框上面再弹筛选面板
        .disabled(model.dialog != nil)
        .transition(
          .asymmetric(
            insertion: reduceMotion
              ? .opacity
              : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity)
                .animation(Style.Motion.pop.animation()),
            removal: reduceMotion ? .opacity : AnyTransition(TokenCollapse())))
      }
      // 筛选面板 / ⌘K 开着时，搜索框改成过滤它们的条目
      CommandTextField(
        text: model.palette != nil ? $model.actionQuery : $model.query,
        placeholder: placeholder, fontSize: 20, onCommand: model.handleCommand
      )
      .frame(maxWidth: .infinity)
      .padding(.leading, tokens.isEmpty ? 0 : 2)
    }
    .animation(
      Style.Motion.settle.animation(reduced: reduceMotion), value: tokens.map(\.id)
    )
    .padding(.horizontal, 18)
    .frame(height: Self.searchHeight)
  }

  private var searchSymbol: String {
    switch model.palette {
    case .filters: "line.3.horizontal.decrease"
    case .actions: "command"
    case .groups: "folder"
    case nil: "magnifyingglass"
    }
  }

  private var placeholder: String {
    switch model.palette {
    case .filters: "筛选范围、收藏夹、类型、来源"
    // 子列表只有「移到收藏夹」这一个
    case .actions: model.submenuTitle == nil ? "搜索操作" : "搜索收藏夹"
    case .groups: "搜索收藏夹"
    case nil: model.tokens.isEmpty ? "搜索剪贴板，Tab 筛选" : "搜索"
    }
  }

  private var permissionBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.shield").foregroundStyle(Color(nsColor: .systemOrange))
      Text("授权「辅助功能」后才能直接粘贴回原 App，现在只会写进剪贴板")
      Spacer()
      Button("去授权") {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
      }
      .buttonStyle(.plain)
      .foregroundStyle(Style.brandInk)
      .pointerStyle(.link)
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .padding(.horizontal, 16)
    .frame(height: Self.bannerHeight)
    .background(Color(nsColor: .systemOrange).opacity(0.08))
  }

  // MARK: 列表

  @ViewBuilder private func listArea(
    _ items: [ClipItem], layout: ListLayout, selected: ClipItem?, lensOpen: Bool
  ) -> some View {
    if items.isEmpty && layout.leading == 0 {
      emptyState
    } else {
      list(items, layout: layout, selected: selected, lensOpen: lensOpen)
    }
  }

  private func list(_ items: [ClipItem], layout: ListLayout, selected: ClipItem?, lensOpen: Bool)
    -> some View
  {
    let tops = layout.sectionTops.map { $0 + Self.inset }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
        if layout.leading > 0 { newSnippetRow }
        ForEach(Array(layout.sections.enumerated()), id: \.element.day) { index, section in
          Section {
            rows(section.rows, in: section.day, selected: selected, lensOpen: lensOpen)
          } header: {
            sectionHeader(section, pinned: index < pinnedSections)
          }
        }
      }
      .background(alignment: .topLeading) { highlight(layout: layout, selected: selected) }
      .animation(model.listMotion.animation(reduced: reduceMotion), value: items.map(\.id))
      // 透镜移动：高亮的 offset + height、旧行收起、新行展开同一个 transaction、同一条曲线
      .animation(
        model.selectionMotion.animation(reduced: reduceMotion),
        value: LensKey(id: selected?.id, isOpen: lensOpen)
      )
      .onChange(of: model.listGeneration) {
        model.settleList()
        position.scrollTo(edge: .top)
      }
      .padding(Self.inset)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: CGRect.self) {
      $0.visibleRect
    } action: { _, rect in
      viewport.rect = rect
    }
    .onScrollGeometryChange(for: Int.self) { geometry in
      let y = geometry.visibleRect.minY
      return tops.lastIndex { y > $0 + 0.5 }.map { $0 + 1 } ?? 0
    } action: { _, count in
      pinnedSections = count
    }
    .onChange(of: selected?.id) { _, id in
      if let id { reveal(id, layout: layout) }
    }
  }

  /// 让整块透镜露出来：只在它（连同吸顶的分组标题）被挡住时滚，按前缀和算目标位置，不量视图
  private func reveal(_ id: UUID, layout: ListLayout) {
    let visible = viewport.rect
    guard visible.height > 0, let offset = layout.offset(of: id) else { return }
    let top = offset + Self.inset
    let bottom = top + layout.height(of: id)
    let covered = Self.headerHeight
    var target: CGFloat
    if top - covered < visible.minY {
      target = top - covered
    } else if bottom > visible.maxY {
      target = bottom + Self.inset - visible.height
    } else {
      return
    }
    if target < Self.inset * 2 { target = 0 }
    withAnimation(model.selectionMotion.animation(reduced: reduceMotion)) {
      position.scrollTo(y: target)
    }
  }

  /// 一块中性高亮 = 透镜的底：按前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private func highlight(layout: ListLayout, selected: ClipItem?) -> some View {
    if let selected, let offset = layout.offset(of: selected.id) {
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      let height = layout.height(of: selected.id)
      if model.multiSelection.isEmpty {
        shape.fill(Style.selectedFill)
          // 降低透明度：透镜底提到 0.9 不透明（Whisker §7），不透出后面的材质
          .background {
            if reduceTransparency {
              shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            }
          }
          .overlay { shape.contrastSelectionBorder() }
          .frame(height: height)
          .offset(y: offset)
      }
      // 放大预览从透镜长出来（透镜关掉、多选时是选中行那一格）：按同样的前缀和报位置，只报列表可见区里的部分，
      // 滚出去的不当起点、退回面板。按选中项换一个新视图，一出现就报终点位置（不等高亮滑完），换下去的立刻拿掉
      // （不跟选中动画淡出：淡出中随滚动还会报旧 id，拿掉时再把新的清成 nil）；
      // 不交给行去报：行换分组时新旧两行短暂并存，旧行的退场会把新行报的位置冲掉
      Color.clear
        .frame(height: height)
        .onGeometryChange(for: CGRect.self) { proxy in
          let global = proxy.frame(in: .global)
          let visible = CGRect(origin: .zero, size: proxy.size)
            .intersection(proxy.bounds(of: .scrollView) ?? .infinite)
          return visible.isEmpty ? .null : visible.offsetBy(dx: global.minX, dy: global.minY)
        } action: { rect in
          model.cardFrame = rect.isNull ? nil : (selected.id, rect)
        }
        .offset(y: offset)
        .onDisappear { if model.cardFrame?.id == selected.id { model.cardFrame = nil } }
        .transition(.identity)
        .id(selected.id)
    }
  }

  private func sectionHeader(_ section: DaySection, pinned: Bool) -> some View {
    HStack(spacing: 8) {
      Text("\(section.title) · \(section.rows.count)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
      Hairline()
    }
    .padding(.horizontal, 10)
    // 高度必须正好是 headerHeight：高亮、滚动、吸顶都按它累加
    .frame(height: Self.headerHeight)
    .background(pinned ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear))
  }

  /// 片段范围第一行：一条虚线的「＋ 新建片段 ⌘N」（片段为空时就只有它，不另画空态）
  private var newSnippetRow: some View {
    Button {
      model.dialog = .newSnippet
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 24, height: 24)
        Text("新建片段").font(.system(size: 13))
        Text("支持 {date} {time} {clipboard} {cursor} 等").font(.system(size: 11)).foregroundStyle(
          .tertiary)
        Spacer(minLength: 8)
        KeyCap("⌘N")
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: ClipRowView.height)
      .background {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .padding(.vertical, 3)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// 行的身份 = 所在分组（那天的零点）+ 条目，行上也别再挂 `.id(item.id)`：条目换了分组（旧条目再次复制挪进「今天」）
  /// 就是删一行再插一行。身份只有条目 id 时 LazyVStack 会把旧行原样搬过去、之后不再跟着父视图更新：选中和透镜停在搬之前，
  /// 按前缀和走的高亮对不上行（高亮盖住下面几行、透镜不展开、时间也不刷新）
  private func rows(
    _ rows: [(offset: Int, element: ClipItem)], in section: Date, selected: ClipItem?,
    lensOpen: Bool
  ) -> some View {
    ForEach(rows.map { (id: RowID(section: section, item: $0.element.id), row: $0) }, id: \.id) {
      entry in
      let (index, item) = entry.row
      let isSelected = item.id == selected?.id
      ClipListRow(
        item: item, form: model.contentForm(of: item), model: model,
        shortcutIndex: index < 9 ? index : nil, showsShortcut: shownKeys.contains(.command),
        isSelected: isSelected, lensOpen: lensOpen && isSelected, groupName: groupBadge(for: item)
      )
      // 右键菜单和 ⌘K 同一份动作（体检 B12）；包成视图：菜单打开时才算，不在每次画行时建一遍
      .contextMenu { ActionContextMenu { model.actions(for: item, targets: [item]) } }
      .transition(rowTransition)
    }
  }

  /// 新条目从顶部挤入（图标 pop）、删除缩小淡出。换列表（搜索 / 筛选）那一帧插进来的行不带
  /// 插入过渡，否则每一行都按「新插入」播一次图标 pop。退场一直是缩小淡出：行的过渡在它插进来那一帧就定了，
  /// 跟着切成无过渡的话，这些行以后删掉时就没有退场
  private var rowTransition: AnyTransition {
    if reduceMotion { return .opacity }
    return .asymmetric(
      insertion: model.listMotion == .instant
        ? .identity
        : .move(edge: .top).combined(with: .opacity).combined(with: AnyTransition(IconPop())),
      removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
  }

  private func groupBadge(for item: ClipItem) -> String? {
    guard model.groupFilter == .all, let id = item.groupID else { return nil }
    return model.store.groups.first { $0.id == id }?.name
  }

  /// 按天分组：今天 / 昨天 / M月d日 / yyyy年M月d日（有搜索词时也是，标题后的数字就是命中条数）。
  /// 行号是在整个列表里的序号（⌘数字用）。列表按复制时间新→旧，同一天是连续的：只在换天时格式化一次
  static func daySections(_ items: [ClipItem]) -> [DaySection] {
    let calendar = Calendar.current
    var sections: [DaySection] = []
    var day: Date?
    for row in items.enumerated() {
      let start = calendar.startOfDay(for: row.element.copiedAt)
      if start == day {
        sections[sections.count - 1].rows.append(row)
      } else {
        day = start
        // 标题规则和翻译历史同一个纯函数（有单测）
        sections.append((start, HistoryView.dayTitle(start, now: .now, calendar: calendar), [row]))
      }
    }
    return sections
  }

  // MARK: 空态

  /// 翻译空态的规格：28 pt 符号 + 14 semibold 标题 + 说明 / 品牌粉文字按钮
  @ViewBuilder private var emptyState: some View {
    if model.isFiltered {
      EmptyState(symbol: "magnifyingglass", title: "没有匹配的条目") {
        Button("清除搜索和筛选", action: model.clearSearchAndFilters)
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
      }
    } else if model.scope == .favorites {
      EmptyState(symbol: "star", title: "还没有收藏") {
        Text("选中条目按 ⌘D 收藏；收藏不受保留天数影响").foregroundStyle(.secondary)
      }
    } else {
      EmptyState(symbol: "doc.on.clipboard", title: "还没有剪贴板历史") {
        Text("复制的文本、图片和文件会出现在这里").foregroundStyle(.secondary)
      }
    }
  }

  // MARK: 底栏

  private func bottomBar(count: Int) -> some View {
    HStack(spacing: 12) {
      barStatus(count: count)
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        .id(barState(count: count))
        // 对话框开着时只有「撤销」能点（管理收藏夹里删掉的收藏夹）；多选动词里的粘贴会收起面板、丢掉没保存的字
        .disabled(model.dialog != nil && model.toast == nil)
      Spacer(minLength: 8)
      Group {
        if count > 0 {
          if model.multiSelection.isEmpty {
            Button {
              model.pasteSelection()
            } label: {
              hint("粘贴", key: "↩", primary: true)
            }
            .help("粘贴到当前 App（↩）")
          }
          Button {
            model.palette = model.palette == .actions ? nil : .actions
          } label: {
            hint("操作", key: "⌘K")
          }
          .help("全部操作（⌘K 或 →）")
          Hairline(vertical: true).frame(height: 16)
        }
        Button("剪贴板设置", systemImage: "gearshape", action: model.openSettings)
          .labelStyle(.iconOnly)
          .help("剪贴板设置（⌘,）")
        // 固定只管点外面不收起（Esc、⌘W 照样关）；和 ⌘P 同一个开关，底栏就地提示
        Button(
          hideOnUnfocus ? "固定面板" : "取消固定", systemImage: hideOnUnfocus ? "pin" : "pin.fill",
          action: model.togglePinned
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(hideOnUnfocus ? AnyShapeStyle(.secondary) : AnyShapeStyle(Style.brandInk))
        .contentTransition(.symbolEffect(.replace))
        .help(hideOnUnfocus ? "固定面板（⌘P）" : "取消固定（⌘P）")
        .accessibilityAddTraits(hideOnUnfocus ? [] : .isSelected)
      }
      // 对话框开着时右边不接点击：点「粘贴」会收起面板、丢掉对话框里没保存的字，点「操作」会在对话框上面弹 ⌘K
      .disabled(model.dialog != nil)
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: barState(count: count))
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .frame(height: Self.barHeight)
    .overlay(alignment: .top) { Hairline() }
  }

  /// 底栏左边现在显示哪一种（换的时候 blurReplace）
  private func barState(count: Int) -> String {
    if let toast = model.toast { return "toast \(toast)" }
    if !model.multiSelection.isEmpty { return "multi" }
    if count > 0, shownKeys.contains(.option) { return "option" }
    if count > 0, shownKeys.contains(.command) { return "command" }
    return "count"
  }

  @ViewBuilder private func barStatus(count: Int) -> some View {
    if let toast = model.toast {
      BarNoticeView(notice: toast, undo: model.undoDelete)
    } else if !model.multiSelection.isEmpty {
      multiSelectVerbs
    } else if count > 0, shownKeys.contains(.option) {
      Button {
        model.pasteSelection(plainText: !pastesPlain)
      } label: {
        hint(model.alternatePasteTitle, key: "⌥↩", leadingKey: true)
      }
    } else if count > 0, shownKeys.contains(.command) {
      HStack(spacing: 12) {
        Button(action: { model.copySelection() }) {
          hint("仅复制", key: "⌘↩", leadingKey: true)
        }
        Text("·").foregroundStyle(.tertiary)
        HStack(spacing: 6) {
          KeyCap("⌘1–9")
          Text("直接粘贴")
        }
      }
    } else {
      HStack(spacing: 8) {
        // 菜单栏「暂停记录剪贴板」开着（D4）：复制的东西不会出现在这里，说一声
        if model.isRecordingPaused {
          Label("已暂停记录", systemImage: "pause.circle")
          Text("·").foregroundStyle(.tertiary)
        }
        Text(countText(count))
          .contentTransition(.numericText())
          .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: count)
      }
    }
  }

  /// 多选时底栏左边：一排「动词 + 键帽」按钮；对象是勾选项里看得见的（model.targets，搜索 / 筛选换了列表后不算看不见的）。
  /// 「收藏夹…」打开收藏夹列表（ActionMenu，和 ⌘K 的「移到收藏夹」子列表同一份）
  @ViewBuilder private var multiSelectVerbs: some View {
    let items = model.targets
    let ids = Set(items.map(\.id))
    HStack(spacing: 12) {
      Text("已选 \(items.count) 条")
      Button(action: { model.pasteSelection() }) {
        hint(ClipboardPanelModel.PasteMode(items).verb, key: "↩", primary: true)
      }
      Button(action: { model.toggleFavorite(ids) }) {
        hint(items.allSatisfy(\.favorite) ? "取消收藏" : "收藏", key: "⌘D")
      }
      Button {
        model.palette = model.palette == .groups ? nil : .groups
      } label: {
        Text("收藏夹…").foregroundStyle(.primary).contentShape(.rect)
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.frame(in: .named(Self.space)).minX
      } action: {
        groupsButtonX = $0
      }
      .accessibilityAddTraits(model.palette == .groups ? .isSelected : [])
      Button(action: { model.delete(ids) }) { hint("删除", key: "⌘⌫") }
      Button(action: { model.multiSelection = [] }) { hint("取消", key: "Esc") }
    }
  }

  /// 「动词 键帽」；primary：↩ 是品牌粉实心键帽（主按钮）；leadingKey：键帽在前（按住修饰键时的替代动作）
  private func hint(_ title: String, key: String, primary: Bool = false, leadingKey: Bool = false)
    -> some View
  {
    HStack(spacing: 6) {
      if leadingKey { KeyCap(key) }
      Text(title).foregroundStyle(.primary)
      if !leadingKey {
        KeyCap(key, primary: primary)
      }
    }
    .contentShape(.rect)
  }

  private func countText(_ count: Int) -> String {
    let total = model.store.items.count
    return count == total ? "\(total) 条" : "\(count) / \(total) 条"
  }
}

/// 列表几何（前缀和）：行 40、分组标题 24、透镜按类型的常数（Lens.height）；高亮、滚动、吸顶都从这里算，不量真实尺寸
struct ListLayout {
  /// 片段范围第一行「新建片段」的高度；0 = 不画这一行（别的范围，或片段范围里搜索 / 筛选没有结果，改画空态）
  var leading: CGFloat = 0
  /// 按天分组（有没有搜索词都一样）
  var sections: [ClipboardPanelView.DaySection]
  /// 展开透镜的那一行和它的总高
  var lens: (id: UUID, height: CGFloat)?

  func height(of id: UUID) -> CGFloat {
    if let lens, lens.id == id { lens.height } else { ClipRowView.height }
  }

  /// 行顶在列表内容里的 y（不含四周内缩）。透镜那一行上面都是普通行，所以不用加透镜多出的高度
  func offset(of id: UUID) -> CGFloat? {
    var y = leading
    for section in sections {
      y += ClipboardPanelView.headerHeight
      if let index = section.rows.firstIndex(where: { $0.element.id == id }) {
        return y + CGFloat(index) * ClipRowView.height
      }
      y += sectionBody(section)
    }
    return nil
  }

  /// 各分组标题的 y（不含四周内缩）：透镜所在分组之后的都往下挪透镜多出的高度
  var sectionTops: [CGFloat] {
    var y = leading
    return sections.map { section in
      defer { y += ClipboardPanelView.headerHeight + sectionBody(section) }
      return y
    }
  }

  private func sectionBody(_ section: ClipboardPanelView.DaySection) -> CGFloat {
    let extra =
      lens.map { lens in
        section.rows.contains { $0.element.id == lens.id } ? lens.height - ClipRowView.height : 0
      } ?? 0
    return CGFloat(section.rows.count) * ClipRowView.height + extra
  }
}

/// 列表的一行 + 选中时展开的透镜。整行是一个按钮（单击选中、双击粘贴），透镜里的值胶囊、「美化」是里面的小按钮
private struct ClipListRow: View {
  let item: ClipItem
  let form: ContentForm?
  let model: ClipboardPanelModel
  let shortcutIndex: Int?
  let showsShortcut: Bool
  let isSelected: Bool
  let lensOpen: Bool
  let groupName: String?
  @State private var hovered = false
  /// 这次按下已经起了拖放会话（手势结束或被 AppKit 接走后自动复位）
  @GestureState private var dragging = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      model.click(item)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        ClipRowView(
          item: item, form: form, query: model.query, shortcutIndex: shortcutIndex,
          showsShortcut: showsShortcut,
          isChecked: model.multiSelection.isEmpty ? nil : model.multiSelection.contains(item.id),
          groupName: groupName, images: model.store.images
        )
        // 悬停只出 fill.hover，不移动透镜（选中行下面已经有高亮）
        .background(
          hovered && !isSelected ? Style.hoverFill : .clear,
          in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
        if lensOpen {
          LensView(item: item, form: form, model: model).transition(lensTransition)
        }
      }
      .frame(
        height: lensOpen ? Lens.height(for: item, form: form) : ClipRowView.height, alignment: .top
      )
      .clipped()
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // 拖到别的 App（体检 D3）：拖开 6 pt 就起 AppKit 会话（ClipDrag），之后的鼠标事件归它；不改选中。
    // 放成了照常收起面板（固定着不收）
    .simultaneousGesture(
      DragGesture(minimumDistance: 6).updating($dragging) { _, started, _ in
        guard !started else { return }
        started = true
        ClipDrag.begin(
          model.dragItems(for: item),
          preview: ClipDrag.preview(item, form: form, images: model.store.images)
        ) { [model] in if !model.isPinned { model.hidePanel() } }
      }
    )
    .background {
      HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityValue(lensOpen ? Lens.accessibilityValue(for: item, form: form) : "")
    .accessibilityAction(named: "粘贴") { model.paste([item]) }
    .accessibilityAction(named: "放大预览") {
      model.select(item)
      model.toggleQuickLook()
    }
    .accessibilityAction(named: item.favorite ? "取消收藏" : "收藏") {
      model.toggleFavorite([item.id])
    }
  }

  /// 透镜换内容：opacity + y 4→0（≤ 0.18 s）；连发、换列表、减弱动态效果时瞬间展开收起
  private var lensTransition: AnyTransition {
    guard !reduceMotion, model.selectionMotion != .instant else { return .identity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.16)),
      removal: .opacity.animation(.easeIn(duration: Style.fadeOut)))
  }
}

/// 列表行的身份：所在分组（那天的零点）+ 条目（见 rows(_:in:selected:lensOpen:)）
private struct RowID: Hashable {
  let section: Date
  let item: UUID
}

/// 透镜移动的动画触发值：选中换了、或透镜开关变了（多选时收起）
private struct LensKey: Equatable {
  let id: UUID?
  let isOpen: Bool
}

/// 滚动视口（内容坐标）。故意不是 @Observable：滚动时改它不触发重画
private final class Viewport {
  var rect = CGRect.zero
}

/// 搜索框里的粉色筛选标签：高 22、12 medium、品牌粉 0.12 底 + brandInk 字（⌫ 待删时 0.30 底），尾部 8 pt ×。
/// 点标签打开筛选面板，点 × 移除
private struct TokenChip: View {
  let token: ClipboardPanelModel.Token
  let armed: Bool
  let open: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: open) {
        Text(token.title)
          .lineLimit(1)
          .padding(.leading, 10)
          .padding(.trailing, 5)
          .frame(height: 22)
          .contentShape(.rect)
      }
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 8, height: 22)
          .padding(.trailing, 8)
          .contentShape(.rect)
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Style.brandInk)
    .background(Style.brand.opacity(armed ? 0.30 : 0.12), in: .capsule)
    .fixedSize()
    .animation(Style.Motion.snap.animation(), value: armed)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("筛选：\(token.title)")
    .accessibilityHint("按删除键移除")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
    .accessibilityAction(named: "移除", remove)
  }
}

/// 标签移除 = 宽度收拢（settle，跟着搜索线 HStack 的动画走）：遮罩从右往左收到 0 + 淡出，
/// 被移除的标签不占布局，输入框同时滑过来，收拢的右边缘走在它前面，不叠在一起
private struct TokenCollapse: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .mask(alignment: .leading) {
        Rectangle().scaleEffect(x: phase.isIdentity ? 1 : 0.01, anchor: .leading)
      }
      .opacity(phase.isIdentity ? 1 : 0)
  }
}

/// 空状态：28 pt 符号 + 14 semibold 标题 + 下方说明或按钮（同翻译浮窗的空态）
private struct EmptyState<Detail: View>: View {
  let symbol: String
  let title: String
  @ViewBuilder var detail: Detail

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 28))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tertiary)
      Text(title).font(.system(size: 14, weight: .semibold))
      detail.font(.system(size: 12))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
