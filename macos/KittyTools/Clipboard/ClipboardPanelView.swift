// 剪贴板面板根视图（透镜指令条 Lens Bar，mac-whisker §6 剪贴板）：宽 720、贴在屏幕上方 20%（和启动器同位置），
// 高度按条数伸缩、顶边不动、≤ 520（height(for:)；透镜预留是常数，↑↓ 永远不改窗口高度）。
// 56 pt 搜索线 = 放大镜 + 粉色筛选标签 + 输入框；单列满宽列表（始终按天分组吸顶，搜索只过滤，体检 A6），
// 行 40（图片行 64：设置「列表里直接显示图片」，默认开），选中行原地展开成透镜（LensView），一块中性高亮在行间滑动、
// 和透镜一起伸缩（前缀和定位）；列表只画可见区附近的项、
// 上下按前缀和撑开，吸顶的分组标题自己画（list，2026-10-03：交给 LazyVStack 时条目多了高亮错位、越往后越卡）；
// 片段范围第一行固定一条虚线的「＋ 新建片段 ⌘N」；底栏 36 = （已暂停记录）条数 / 修饰键提示 / 多选动词 ｜ 粘贴 ↩ · 操作 ⌘K ｜
// 齿轮 图钉。
// Tab 筛选面板从搜索栏左下长出、⌘K 操作面板从底栏右下长出、多选底栏「收藏夹…」的列表从按钮上方长出（共用 Shell/ActionMenu）；
// 右键菜单和 ⌘K 同一份动作表；行能拖到别的 App（ClipDrag）；对话框从搜索栏下沿落下。
// 状态和操作都在 ClipboardPanelModel。

import SwiftUI

struct ClipboardPanelView: View {
  /// day = 那天的零点：分组和行的身份按它，不按标题（过了午夜「今天」改叫「昨天」，还是同一组、同一批行）
  typealias DaySection = (day: Date, title: String, rows: [(offset: Int, element: ClipItem)])
  /// 列表的第一条和条数：新条目进来的信号（itemsChanged）
  private struct FirstAndCount: Equatable {
    var id: UUID?
    var count: Int
  }

  @Bindable var model: ClipboardPanelModel
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.clipboardShowPreview) private var showsLens = true
  /// 图片条目在列表里直接画图（64 高的图片行，选中时图在原地长大）；关掉就和别的条目一样是 24 pt 小方块
  @AppStorage(Prefs.clipboardImageRows) private var imageRows = true
  /// 拖下边定的最多几行（W2，0 = 默认）
  @AppStorage(Prefs.clipboardPanelRows) private var maxRows = 0.0
  /// 默认粘贴为纯文本：底栏按住 ⌥ 的提示、右键菜单的替代粘贴跟着换名字
  @AppStorage(Prefs.clipboardPastePlain) private var pastesPlain = false
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 这次呼出的时刻（面板当 key 时记）：分组标题「今天 / 昨天」按它算，传给列表和行当刷新的由头——收起再呼出时可见的行重画一次，
  /// 「多久前」、透镜的「今天 14:02」都是新的（行按值比较，不传的话条目没变就一直是上次画的字）
  @State private var shownAt = Date.now
  /// 正按着的 ⌘ / ⌥
  @State private var heldKeys: EventModifiers = []
  /// 按住超过 150 ms 才算「按住」（S4）：⌘ 亮出 ⌘1–9 键帽，⌘ / ⌥ 把底栏左边换成对应的替代动作。
  /// 按 ⌘K、⌘D 这类组合键时一闪而过的 ⌘ 不换，底栏不闪；松开立刻收
  @State private var shownKeys: EventModifiers = []
  /// 多选底栏「收藏夹…」按钮的左缘（面板坐标）：收藏夹列表锚在它上方
  @State private var groupsButtonX: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  /// 和启动器同宽（两块面板同位置同宽，数只写在 Style 里）
  static let width = Style.listPanelWidth
  static let searchHeight: CGFloat = 56
  static let barHeight: CGFloat = 36
  static let headerHeight: CGFloat = 24
  static let bannerHeight: CGFloat = 30
  /// 列表四周内缩（面板圆角 16 − 6 = 高亮 / 透镜的圆角 10，同心）
  static let inset: CGFloat = 6
  /// 列表区最高 427.5：连同搜索线、发丝线、底栏正好 520
  static let maxListHeight: CGFloat = 427.5
  /// 拖下边能定的行数（W2）：默认 8.5 行就是 427.5；按半行吸附
  static let rowRange = 6.5...14.5

  /// 列表区最高多高：拖出来的行数（0 = 默认）每多一行加一行高
  static func maxListHeight(rows: Double) -> CGFloat {
    rows > 0 ? maxListHeight + CGFloat(rows - 8.5) * ClipRowView.height : maxListHeight
  }

  /// 面板里列表区以外的高度：搜索栏、发丝线、授权横幅、底栏
  static func chrome(banner: Bool) -> CGFloat {
    searchHeight + 0.5 + (banner ? bannerHeight : 0) + barHeight
  }

  /// 拖下边时面板能多高（W2）：列表区 6.5 到 14.5 行
  static func heightRange(banner: Bool) -> ClosedRange<CGFloat> {
    chrome(banner: banner) + maxListHeight(rows: rowRange.lowerBound)...chrome(banner: banner)
      + maxListHeight(rows: rowRange.upperBound)
  }

  /// 拖到这么高对应最多几行：按半行吸附，夹在 rowRange 里（纯函数，配单测）
  static func rows(forHeight height: CGFloat, banner: Bool) -> Double {
    let rows = 8.5 + Double((height - chrome(banner: banner) - maxListHeight) / ClipRowView.height)
    return min(max((rows - 0.5).rounded() + 0.5, rowRange.lowerBound), rowRange.upperBound)
  }
  static let emptyListHeight: CGFloat = 140
  /// 筛选面板 / ⌘K 开着时列表区至少这么高（8.5 行菜单 + 上下余量），短列表时面板先长到放得下
  static let paletteListHeight: CGFloat = ActionMenu.rowHeight * 8.5 + 26
  /// 面板根视图的坐标系（多选底栏按钮报位置用）
  nonisolated private static let space = "clipboardPanel"

  var body: some View {
    let items = model.visibleItems
    let sections = Self.daySections(items, now: shownAt)
    let lensOpen = showsLens && model.multiSelection.isEmpty
    let newSnippet = model.showsNewSnippetRow(in: items)
    VStack(spacing: 0) {
      searchBar
      Hairline()
      if !trusted { permissionBanner }
      listArea(items, sections: sections, newSnippet: newSnippet, lensOpen: lensOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { DialogOverlay(model: model) }
      bottomBar(count: items.count)
    }
    .overlay(alignment: .topLeading) {
      if model.palette == .filters {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: "没有匹配的筛选", anchor: .topLeading, maxRows: 8.5,
          onHover: { model.actionSelection = $0 }, onRun: model.run
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
          header: model.submenuTitle, onBack: model.leaveSubmenu, maxRows: 8.5,
          onHover: { model.actionSelection = $0 }, onRun: model.run
        )
        // 右缘对着底栏「操作 ⌘K」的键帽：右内边距 16 + 图钉 + 齿轮 + 竖线和间距
        .padding(.trailing, 82)
        .padding(.bottom, Self.barHeight + 4)
      }
    }
    // 多选底栏「收藏夹…」：锚在按钮上方（左缘对齐，放不下时往左挪）
    .overlay(alignment: .bottomLeading) {
      if model.palette == .groups {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: "没有匹配的收藏夹", anchor: .bottomLeading, maxRows: 8.5,
          onHover: { model.actionSelection = $0 }, onRun: model.run
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
        rowsHeight: Self.rowsHeight(items, newSnippet: newSnippet, imageRows: imageRows),
        sections: sections.count, reservesLens: showsLens && !items.isEmpty, banner: !trusted,
        model: model, maxRows: maxRows),
      initial: true
    ) { _, height in model.resize(height) }
    .onModifierKeysChanged(mask: [.command, .option]) { _, keys in heldKeys = keys }
    .task(id: heldKeys) {
      shownKeys.formIntersection(heldKeys)
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { shownKeys = heldKeys }
    }
    // 第一条和条数一起看：图片按复制时间插到第 2 条时第一条没变（第四轮体检 E24①）
    .onChange(of: FirstAndCount(id: model.store.items.first?.id, count: model.store.items.count)) {
      model.itemsChanged()
    }
    .coordinateSpace(.named(Self.space))
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
      shownAt = .now
    }
  }

  // MARK: 高度

  /// 面板高度（窗口和截图自检同一个算法）：56 + 0.5 +（授权横幅）+ 列表区 + 36。列表区 =
  /// min(上下内缩 12 + 24 × 分组数 + 各行高之和 + 透镜预留, 427.5)，空列表 140；对话框开着给满，浮起的菜单开着至少放得下 8.5 行
  /// rowsHeight：各行（没展开时）的高加起来（同名函数）；maxRows：拖下边定的最多几行（0 = 默认 8.5）
  static func height(
    rowsHeight: CGFloat, sections: Int, reservesLens: Bool, banner: Bool,
    model: ClipboardPanelModel,
    maxRows: Double = 0
  ) -> CGFloat {
    var list = listHeight(
      rowsHeight: rowsHeight, sections: sections, reservesLens: reservesLens, maxRows: maxRows)
    if model.dialog != nil {
      list = maxListHeight(rows: maxRows)
    } else if model.palette != nil {
      list = max(list, paletteListHeight)
    }
    return chrome(banner: banner) + list
  }

  /// rowsHeight：各行（没展开时）的高加起来（同名函数），0 = 空列表
  static func listHeight(
    rowsHeight: CGFloat, sections: Int, reservesLens: Bool, maxRows: Double = 0
  ) -> CGFloat {
    guard rowsHeight > 0 else { return emptyListHeight }
    let content =
      inset * 2 + headerHeight * CGFloat(sections) + rowsHeight
      + (reservesLens ? Lens.reserve : 0)
    return min(content, maxListHeight(rows: maxRows))
  }

  /// 各行（没展开时）的高加起来：「新建片段」40、图片行 64（开着「列表里直接显示图片」）、其余 40。
  /// 透镜预留（Lens.reserve，按最高的代码透镜比普通行多出的 158）也盖得住图片行展开多出的 82
  static func rowsHeight(_ items: [ClipItem], newSnippet: Bool, imageRows: Bool) -> CGFloat {
    items.reduce(newSnippet ? ClipRowView.height : 0) {
      $0 + ClipRowView.height(of: $1, imageRows: imageRows)
    }
  }

  /// 按模型现算（AppDelegate 建窗口、截图自检用）；视图里用上面那个，省一次搜索
  static func height(
    for model: ClipboardPanelModel,
    showsLens: Bool = UserDefaults.standard.bool(forKey: Prefs.clipboardShowPreview),
    banner: Bool = !Permissions.isAccessibilityTrusted,
    maxRows: Double = UserDefaults.standard.double(forKey: Prefs.clipboardPanelRows),
    imageRows: Bool = UserDefaults.standard.bool(forKey: Prefs.clipboardImageRows)
  ) -> CGFloat {
    let items = model.visibleItems
    return height(
      rowsHeight: rowsHeight(
        items, newSnippet: model.showsNewSnippetRow(in: items), imageRows: imageRows),
      sections: daySections(items).count,
      reservesLens: showsLens && !items.isEmpty, banner: banner, model: model, maxRows: maxRows)
  }

  // MARK: 搜索线

  private var searchBar: some View {
    let tokens = model.tokens
    // 线头（符号定宽）和左右内边距在 SearchLine 里，和启动器的搜索线是同一个
    return SearchLine(symbol: searchSymbol) {
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
        placeholder: placeholder, fontSize: 20, onCommand: model.handleCommand,
        onSpace: model.handleSpace
      )
      .frame(maxWidth: .infinity)
      .padding(.leading, tokens.isEmpty ? 0 : 2)
    }
    .animation(
      Style.Motion.settle.animation(reduced: reduceMotion), value: tokens.map(\.id)
    )
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
    let text: LocalizedStringResource =
      switch model.palette {
      case .filters: "筛选范围、收藏夹、类型、来源"
      // 子列表只有「移到收藏夹」这一个
      case .actions: model.submenuTitle == nil ? "搜索操作" : "搜索收藏夹"
      case .groups: "搜索收藏夹"
      case nil: model.tokens.isEmpty ? "搜索剪贴板，Tab 筛选" : "搜索"
      }
    return String(localized: text)
  }

  private var permissionBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.shield").foregroundStyle(Color(nsColor: .systemOrange))
      Text("授权「辅助功能」后才能直接粘贴回原 App，现在只会写进剪贴板")
      Spacer()
      // 没问过只弹系统框、问过了才打开系统设置（第五轮体检 U11：原来两样一起来）
      Button("去授权") { Permissions.grant(.accessibility) }
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
    _ items: [ClipItem], sections: [DaySection], newSnippet: Bool, lensOpen: Bool
  ) -> some View {
    if items.isEmpty && !newSnippet {
      emptyState
    } else {
      ClipList(
        model: model, items: items, sections: sections, newSnippet: newSnippet,
        lensOpen: lensOpen, showsShortcut: shownKeys.contains(.command), imageRows: imageRows,
        viewport: Self.maxListHeight(rows: maxRows), shownAt: shownAt
      )
      .equatable()
    }
  }

  /// 按天分组：今天 / 昨天 / M月d日 / yyyy年M月d日（有搜索词时也是，标题后的数字就是命中条数）。
  /// 行号是在整个列表里的序号（⌘数字用）。列表按复制时间新→旧，同一天是连续的：只在换天时算零点、格式化一次，
  /// 落在当前这组那天里的直接归进去（每条都算 startOfDay 的话 800 条要 3 ms，每次按键都重算一遍）
  static func daySections(_ items: [ClipItem], now: Date = .now) -> [DaySection] {
    let calendar = Calendar.current
    var sections: [DaySection] = []
    var day: Range<Date>?
    for row in items.enumerated() {
      if let day, day.contains(row.element.copiedAt) {
        sections[sections.count - 1].rows.append(row)
      } else {
        let start = calendar.startOfDay(for: row.element.copiedAt)
        day = start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture)
        // 标题规则和翻译历史同一个纯函数（有单测）
        sections.append((start, HistoryView.dayTitle(start, now: now, calendar: calendar), [row]))
      }
    }
    return sections
  }

  // MARK: 空态

  /// 共用的空状态（Shell/Style 的 EmptyState）：28 pt 符号 + 14 semibold 标题 + 说明 / 品牌粉文字按钮
  @ViewBuilder private var emptyState: some View {
    if model.isEmptyGroup {
      EmptyState(symbol: "folder", title: "这个收藏夹还是空的") {
        Text("在别的条目上按 ⌘K，选「移到收藏夹」放进来").foregroundStyle(.secondary)
      }
    } else if model.isFiltered {
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
      // 左边先分宽度（英文的动词长：不先分的话 HStack 只给它剩下的一半，还有空也被截断）；中文本来就放得下，样子不变
      barStatus(count: count)
        .layoutPriority(1)
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        .id(barState(count: count))
        // 对话框开着时只有「撤销」能点（管理收藏夹里删掉的收藏夹）；多选动词里的粘贴会收起面板、丢掉没保存的字
        .disabled(model.dialog != nil && model.toast == nil)
      // 有新版本：条数后面常驻「更新到 x」；提示、多选动词、按住修饰键的替代动作出来时让开
      if barState(count: count) == "count" {
        UpdateBarHint { model.hidePanel() }.disabled(model.dialog != nil)
      }
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
    // 整条默认 secondary（条数、「已选 N 条」、「⌘1–9 直接粘贴」这些状态和键位提示）；能点的动词在 hint 里单独给 primary
    // （mac-whisker §3「面板里共用的几件」）
    .foregroundStyle(.secondary)
    .buttonStyle(.plain)
    // 左右 16 = 列表四周内缩 6 + 行内边距 10：和行图标、行右缘共用左右边线
    .padding(.horizontal, 16)
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
      // 实在放不下时先截它（勾选标记看得见选了哪些），动词不截
      Text("已选 \(items.count) 条").lineLimit(1).layoutPriority(-1)
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
      Button(action: { model.delete(ids) }) { hint("删除", key: "⌘⌫", danger: true) }
      Button(action: { model.multiSelection = [] }) { hint("取消", key: "Esc") }
    }
  }

  /// 「动词 键帽」；primary：↩ 是品牌粉实心键帽（主按钮）；leadingKey：键帽在前（按住修饰键时的替代动作）；
  /// danger：删除这类，动词用危险色（mac-whisker §3「危险色」）
  private func hint(
    _ title: LocalizedStringResource, key: String, primary: Bool = false, leadingKey: Bool = false,
    danger: Bool = false
  ) -> some View {
    HStack(spacing: 6) {
      if leadingKey { KeyCap(key) }
      // 一行：英文的动词长，挤的时候截断，别从词中间折成两行
      Text(title).lineLimit(1)
        .foregroundStyle(danger ? AnyShapeStyle(Style.danger) : AnyShapeStyle(.primary))
      if !leadingKey {
        KeyCap(key, primary: primary)
      }
    }
    .contentShape(.rect)
  }

  private func countText(_ count: Int) -> LocalizedStringResource {
    let total = model.store.items.count
    return count == total ? "\(total) 条" : "\(count) / \(total) 条"
  }
}

/// 列表（美化与提速 P1–P3，2026-11-23）：选中、滚动段、悬停都只在这里读——↑↓、滚动跨段、鼠标在行间移动只重画列表，
/// 不重算整块面板（搜索线、底栏和它们的布局）；面板那边只是按住修饰键、提示这类变化时，按值比较（==）没变就不重画列表。
/// 只画可见区附近的那些项（行、分组标题、「新建片段」），上下按前缀和算出的高度撑开（ListWindow，为什么不用 LazyVStack
/// 见那里；2026-10-03 用户报条目多了高亮错位、滚动和 ↑↓ 卡）：画出来的位置就是 ListLayout 算的，和高亮、滚动、吸顶
/// 对得上；按键、滚动的开销只和画出来的二十来项有关。吸顶的分组标题因此自己画（StickyHeaders）
private struct ClipList: View, Equatable {
  let model: ClipboardPanelModel
  let items: [ClipItem]
  let sections: [ClipboardPanelView.DaySection]
  /// 片段范围第一行「＋ 新建片段」
  let newSnippet: Bool
  /// 选中行展开透镜（「显示透镜」开着、没有勾选）
  let lensOpen: Bool
  /// 按住 ⌘：亮出 ⌘1–9 键帽
  let showsShortcut: Bool
  /// 设置「列表里直接显示图片」
  let imageRows: Bool
  /// 列表区最高多高（拖下边定的行数）：画到哪
  let viewport: CGFloat
  /// 这次呼出的时刻：只当刷新的由头，传给每一行（ClipboardPanelView.shownAt）
  let shownAt: Date
  /// 滚动位置落在第几段（ListWindow）：列表只画这一段附近的项，跨段时才重画列表。
  /// 别存滚动位置本身（每帧都会重画）；吸顶标题逐帧的位置按几何算（StickyHeaders）
  @State private var band = 0
  @State private var position = ScrollPosition()
  /// 鼠标悬停在哪一行（整块列表一块追踪区，ListHoverTracker）：只有悬停那层底读它，鼠标在行间移动不重画列表和行
  @State private var hover = ListHover()
  /// 滚动视图实际多高（按 80 pt 往上取整，拖下边时每长 80 pt 才重画一次）：比设置里存的行数高（正拖着把面板拉高）时按它画，
  /// 不然拉高的那一截底下是空的，要等松手
  @State private var visibleHeight: CGFloat = 0
  /// 不带透镜的前缀和（ListLayout.Base）：条目没变就接着用（↑↓、滚动跨段时不把几千条重新累加一遍）
  @State private var bases = BaseCache()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  /// 上一次算的 ListLayout.Base 和算它用的条目、设置；不被观察（只在列表重画时读、写）
  final class BaseCache {
    private var key: (items: [ClipItem], newSnippet: Bool, imageRows: Bool)?
    private var base: ListLayout.Base?

    func base(for list: ClipList) -> ListLayout.Base {
      if let key, let base, key.newSnippet == list.newSnippet, key.imageRows == list.imageRows,
        key.items == list.items, base.sections.map(\.day) == list.sections.map(\.day),
        base.sections.map(\.title) == list.sections.map(\.title)
      {
        return base
      }
      let base = ListLayout.Base(
        leading: list.newSnippet ? ClipRowView.height : 0, sections: list.sections,
        imageRows: list.imageRows)
      (key, self.base) = ((list.items, list.newSnippet, list.imageRows), base)
      return base
    }
  }

  /// 比的是面板传进来的值（model 只认是不是同一个）；分组比标题：过了午夜「今天」改叫「昨天」，条目没变也要重画
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model === rhs.model && lhs.items == rhs.items
      && lhs.sections.map(\.day) == rhs.sections.map(\.day)
      && lhs.sections.map(\.title) == rhs.sections.map(\.title)
      && lhs.newSnippet == rhs.newSnippet && lhs.lensOpen == rhs.lensOpen
      && lhs.showsShortcut == rhs.showsShortcut && lhs.imageRows == rhs.imageRows
      && lhs.viewport == rhs.viewport && lhs.shownAt == rhs.shownAt
  }

  var body: some View {
    let selected = model.selectedItem(in: items)
    let layout = ListLayout(
      base: bases.base(for: self),
      lens: lensOpen
        ? selected.map {
          ($0.id, Lens.height(for: $0, form: model.contentForm(of: $0), imageRows: imageRows))
        } : nil)
    let range = layout.window(band: band, viewport: max(viewport, visibleHeight))
    ScrollView {
      ListColumn(height: layout.totalHeight) {
        ForEach(range.map { (id: entryID($0, in: layout), index: $0) }, id: \.id) { entry in
          self.entry(entry.index, in: layout, selected: selected)
            .layoutValue(
              key: ListColumn.Slot.self,
              value: ListColumn.Slot(
                top: layout.top(of: entry.index),
                height: layout.top(of: entry.index + 1) - layout.top(of: entry.index)))
        }
      }
      .background(alignment: .topLeading) {
        ZStack(alignment: .topLeading) {
          HoverHighlight(hover: hover, layout: layout, selectedID: selected?.id)
          highlight(layout: layout, selected: selected)
        }
      }
      // 吸顶的分组标题在滚动内容里（滚动条照样画在它上面）：只给画出来的这一段涉及的那一两组画
      .overlay(alignment: .top) {
        if let shown = layout.sections(in: range) {
          StickyHeaders(
            sections: layout.sections, bounds: layout.sectionTops + [layout.totalHeight],
            shown: shown)
        }
      }
      .animation(model.listMotion.animation(reduced: reduceMotion), value: items.map(\.id))
      // 透镜移动：高亮的 offset + height、旧行收起、新行展开同一个 transaction、同一条曲线
      .animation(
        model.selectionMotion.animation(reduced: reduceMotion),
        value: LensKey(id: selected?.id, isOpen: lensOpen)
      )
      // 换了列表（搜索、筛选）：回顶。已经在顶上（连着打字）就什么都不写，不平白再画一遍
      .onChange(of: model.listGeneration) {
        model.settleList()
        if band != 0 { band = 0 }
        var top = position
        top.scrollTo(edge: .top)
        if top != position || hover.offset > 0.5 { position = top }
      }
      .padding(ClipboardPanelView.inset)
    }
    // 让整块透镜露出来：只在它（连同吸顶的分组标题）被挡住时滚，按前缀和算（共用 ListReveal）
    .modifier(
      RevealsSelection(
        position: $position, key: selected?.id, motion: model.selectionMotion,
        coveredTop: ClipboardPanelView.headerHeight, inset: ClipboardPanelView.inset
      ) {
        guard let id = selected?.id, let offset = layout.offset(of: id) else { return nil }
        let top = offset + ClipboardPanelView.inset
        return top...top + layout.height(of: id)
      }
    )
    .modifier(TracksScrollBand(band: $band, height: ListLayout.bandHeight))
    // 悬停：整块列表一块追踪区，垫在滚动视图后面（每行一块时每行一个 NSView，跨段时一行一行地建、拆）；
    // 位置按前缀和换算成哪一行，滚动时鼠标没动也按新的滚动位置再算一次
    .background {
      ListHoverTracker(inset: ClipboardPanelView.inset) { [hover] in hover.move(to: $0, in: layout)
      }
    }
    .onScrollGeometryChange(for: CGFloat.self) {
      $0.visibleRect.minY
    } action: { [hover] _, y in
      hover.scroll(to: y, in: layout)
    }
    .onScrollGeometryChange(for: CGFloat.self) {
      ($0.containerSize.height / 80).rounded(.up) * 80
    } action: { _, height in
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { visibleHeight = height }
    }
  }

  @ViewBuilder private func entry(_ index: Int, in layout: ListLayout, selected: ClipItem?)
    -> some View
  {
    switch layout.entries[index] {
    case .newSnippet: newSnippetRow
    case .header(let section): SectionHeader(section: layout.sections[section])
    case .row(let section, let row): clipRow(layout.sections[section].rows[row], selected: selected)
    }
  }

  /// ForEach 的身份：标题 = 那一天，行 = 所在分组 + 条目（为什么带分组见 clipRow）
  private func entryID(_ index: Int, in layout: ListLayout) -> EntryID {
    switch layout.entries[index] {
    case .newSnippet: .newSnippet
    case .header(let section): .header(layout.sections[section].day)
    case .row(let section, let row):
      .row(
        RowID(
          section: layout.sections[section].day,
          item: layout.sections[section].rows[row].element.id))
    }
  }

  /// 一块中性高亮 = 透镜的底：按前缀和定位，在行间滑动（不用 matchedGeometryEffect：行离开可见区附近就被拿掉，跟着它会跳）
  @ViewBuilder private func highlight(layout: ListLayout, selected: ClipItem?) -> some View {
    if let selected, let offset = layout.offset(of: selected.id) {
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      let height = layout.height(of: selected.id)
      if model.multiSelection.isEmpty {
        shape.fill(Style.selectedFill)
          // 降低透明度：透镜底提到 0.9 不透明（Whisker §7），不透出后面的材质（只在 15；26 的玻璃自己变实）
          .background {
            if Style.opaqueUnderlay(reduceTransparency: reduceTransparency) {
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
          .padding(.vertical, 2)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  /// 一行。身份 = 所在分组（那天的零点）+ 条目（EntryID.row），行上也别再挂 `.id(item.id)`：条目换了分组（旧条目再次复制
  /// 挪进「今天」）就是删一行再插一行。身份只有条目 id 时旧行会被原样搬过去、之后不再跟着父视图更新：选中和透镜停在
  /// 搬之前，按前缀和走的高亮对不上行（高亮盖住下面几行、透镜不展开、时间也不刷新）
  private func clipRow(
    _ row: (offset: Int, element: ClipItem), selected: ClipItem?
  ) -> some View {
    let (index, item) = row
    let isSelected = item.id == selected?.id
    return ClipListRow(
      item: item, form: model.contentForm(of: item), query: model.query,
      shortcutIndex: index < 9 ? index : nil, showsShortcut: showsShortcut,
      isChecked: model.multiSelection.isEmpty ? nil : model.multiSelection.contains(item.id),
      isSelected: isSelected, lensOpen: lensOpen && isSelected, groupName: groupBadge(for: item),
      imageRows: imageRows, shownAt: shownAt, model: model
    )
    .equatable()
    .transition(rowTransition)
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

}

/// 列表几何（前缀和）：行 40（图片行 64）、分组标题 24、透镜按类型的常数（Lens.height）；不量真实尺寸。列表就按它排（只画可见区附近的项，
/// 每项按它的位置摆，见 ClipList、ListColumn），高亮、滚动、吸顶也都从这里算，所以算出来的位置就是画出来的位置。
/// 分两层（美化与提速 P1–P2）：不带透镜的前缀和（Base，跟着条目变，O(n)）由列表缓存着，透镜是在它上面加的一段（O(1)）——
/// ↑↓ 只换透镜、滚动跨段什么都不换，都不用把几千条重新累加一遍
struct ListLayout {
  /// 列表里的一项：「新建片段」行、分组标题（第几组）、条目行（第几组的第几行）
  enum Entry: Equatable {
    case newSnippet
    case header(Int)
    case row(Int, Int)
  }

  /// 不带透镜的那一层：每项的顶、各组标题的顶、条目 id → 下标
  struct Base {
    let leading: CGFloat
    let sections: [ClipboardPanelView.DaySection]
    let entries: [Entry]
    /// 每一项的顶，比 entries 多一个：最后一个是总高
    let tops: [CGFloat]
    let sectionTops: [CGFloat]
    let rowIndex: [UUID: Int]

    /// imageRows：设置「列表里直接显示图片」开着（图片行 64）
    init(leading: CGFloat = 0, sections: [ClipboardPanelView.DaySection], imageRows: Bool = false) {
      self.leading = leading
      self.sections = sections
      var entries: [Entry] = []
      var tops: [CGFloat] = []
      var sectionTops: [CGFloat] = []
      var rowIndex: [UUID: Int] = [:]
      var y: CGFloat = 0
      if leading > 0 {
        entries.append(.newSnippet)
        tops.append(0)
        y = leading
      }
      for (section, day) in sections.enumerated() {
        entries.append(.header(section))
        tops.append(y)
        sectionTops.append(y)
        y += ClipboardPanelView.headerHeight
        for (row, entry) in day.rows.enumerated() {
          rowIndex[entry.element.id] = entries.count
          entries.append(.row(section, row))
          tops.append(y)
          y += ClipRowView.height(of: entry.element, imageRows: imageRows)
        }
      }
      tops.append(y)
      self.entries = entries
      self.tops = tops
      self.sectionTops = sectionTops
      self.rowIndex = rowIndex
    }
  }

  let base: Base
  /// 展开透镜的那一行和它的总高
  let lens: (id: UUID, height: CGFloat)?
  /// 透镜那一项的下标、比它没展开时多出的高：它后面的每一项都往下挪这么多
  private let lensIndex: Int?
  private let extra: CGFloat

  init(base: Base, lens: (id: UUID, height: CGFloat)?) {
    self.base = base
    let index = lens.flatMap { base.rowIndex[$0.id] }
    self.lens = index == nil ? nil : lens
    lensIndex = index
    extra = index.map { (lens?.height ?? 0) - (base.tops[$0 + 1] - base.tops[$0]) } ?? 0
  }

  /// imageRows：设置「列表里直接显示图片」开着（图片行 64）
  init(
    leading: CGFloat = 0, sections: [ClipboardPanelView.DaySection],
    lens: (id: UUID, height: CGFloat)?, imageRows: Bool = false
  ) {
    self.init(
      base: Base(leading: leading, sections: sections, imageRows: imageRows), lens: lens)
  }

  /// 片段范围第一行「新建片段」的高度；0 = 不画这一行（别的范围，或片段范围里搜索 / 筛选没有结果，改画空态）
  var leading: CGFloat { base.leading }
  /// 按天分组（有没有搜索词都一样）
  var sections: [ClipboardPanelView.DaySection] { base.sections }
  /// 从上到下的每一项
  var entries: [Entry] { base.entries }

  /// 各分组标题的 y（不含四周内缩）：透镜所在分组之后的都往下挪了透镜多出的高度
  var sectionTops: [CGFloat] {
    guard let lensIndex else { return base.sectionTops }
    return base.sectionTops.map { $0 > base.tops[lensIndex] ? $0 + extra : $0 }
  }

  /// 总高（不含四周内缩）
  var totalHeight: CGFloat { top(of: base.entries.count) }

  /// 第 index 项的顶（不含四周内缩）；index == entries.count 是总高
  func top(of index: Int) -> CGFloat {
    base.tops[index] + (lensIndex.map { index > $0 } == true ? extra : 0)
  }

  /// 这一行（展开透镜的就是透镜）的高：相邻两项的顶相减
  func height(of id: UUID) -> CGFloat {
    base.rowIndex[id].map { top(of: $0 + 1) - top(of: $0) } ?? ClipRowView.height
  }

  /// 行顶在列表内容里的 y（不含四周内缩）
  func offset(of id: UUID) -> CGFloat? {
    base.rowIndex[id].map { top(of: $0) }
  }

  /// 每一项的顶（带上透镜），比项数多一个：二分查找用，不另存一份
  private var tops: LazyMapCollection<Range<Int>, CGFloat> {
    (0..<base.tops.count).lazy.map(top(of:))
  }

  /// 列表坐标 y 处是哪一行（分组标题、「新建片段」、列表外是 nil）：悬停按它算（二分）
  func rowID(atY y: CGFloat) -> UUID? {
    guard y >= 0, y < totalHeight else { return nil }
    // 最后一个顶不超过 y 的项
    var (low, high) = (0, entries.count - 1)
    while low < high {
      let middle = (low + high + 1) / 2
      if top(of: middle) <= y { low = middle } else { high = middle - 1 }
    }
    guard case .row(let section, let row) = entries[low] else { return nil }
    return sections[section].rows[row].element.id
  }

  /// 这一段项涉及的分组（第一项和最后一项所在的组，「新建片段」算第一组）；没有分组时 nil
  func sections(in range: Range<Int>) -> ClosedRange<Int>? {
    guard !sections.isEmpty, !range.isEmpty else { return nil }
    func section(_ index: Int) -> Int {
      switch entries[index] {
      case .newSnippet: 0
      case .header(let section), .row(let section, _): section
      }
    }
    return section(range.lowerBound)...section(range.upperBound - 1)
  }

  /// 剪贴板列表的段高和上下多画多少（ListWindow 的默认是 240 / 320，翻译历史、便签照旧用它）：按一行普通行的高一段，
  /// 跨一段只在两头补进、拿掉一两行（原来 240 一段，一次换六行，滚动时每隔十来帧一下 30–45 ms，美化与提速 P2）；
  /// 上下各多画约半屏
  static let bandHeight: CGFloat = 40
  static let overscan: CGFloat = 240

  /// 滚动位置落在第 band 段时要画的项（ListWindow：上下各多画 overscan）；viewport：列表区最高多高（拖出来的行数）
  func window(band: Int, viewport: CGFloat) -> Range<Int> {
    ListWindow.range(
      tops, band: band, inset: ClipboardPanelView.inset, viewport: viewport,
      bandHeight: Self.bandHeight, overscan: Self.overscan)
  }
}

/// 列表的一行 + 选中时展开的透镜。整行接一个按下手势（RowPress：松手算点按——单击选中、双击粘贴，或按设置点一下就粘贴，
/// model.click；拖开 6 pt 起拖放会话），透镜里的值胶囊、「美化」是里面的小按钮、优先于整行。
/// 只收值、按值比较（.equatable()，美化与提速 P1）：选中、搜索词、勾选都由列表算好传进来，行自己不读 model 上会随按键变的属性——
/// ↑↓ 时只有新旧两行的值变了，别的行不重算 body（透镜那一行另读 selectionMotion、搜索词，只它一行跟着变）
private struct ClipListRow: View, Equatable {
  let item: ClipItem
  let form: ContentForm?
  /// 搜索词：标题摘录、命中高亮（没有搜索词时是空串，所有行都一样）
  let query: String
  let shortcutIndex: Int?
  let showsShortcut: Bool
  /// nil = 不在多选状态
  let isChecked: Bool?
  let isSelected: Bool
  let lensOpen: Bool
  let groupName: String?
  /// 设置「列表里直接显示图片」：图片条目画成图片行
  let imageRows: Bool
  /// 这次呼出的时刻：只当刷新的由头（收起再呼出时「多久前」、透镜的时间重算）
  let shownAt: Date
  /// 点按、拖动、右键菜单、透镜里的动作都经它；不参与比较（一块面板一直是同一个）
  let model: ClipboardPanelModel
  /// 这一下按着没有、已经起了拖放会话没有（手势结束或被 AppKit 接走后自动复位）
  @GestureState private var press = RowPress()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let picture = imageRows && item.kind == .image
    VStack(alignment: .leading, spacing: 0) {
      ClipRowView(
        item: item, form: form, query: query, shortcutIndex: shortcutIndex,
        showsShortcut: showsShortcut, isChecked: isChecked,
        groupName: groupName, images: model.store.images, picture: picture,
        expanded: picture && lensOpen, shownAt: shownAt
      )
      if lensOpen {
        LensView(item: item, form: form, model: model, imageRows: imageRows, shownAt: shownAt)
          .transition(lensTransition)
      }
    }
    // 里面按自己的高排（行头、透镜各段都是定高），外面这一格的高跟着透镜开合动画、只裁切：开合那十来帧不按每一帧的高
    // 把行和透镜重排一遍（原来每帧都要，美化与提速 P1）
    .fixedSize(horizontal: false, vertical: true)
    .frame(
      height: lensOpen
        ? Lens.height(for: item, form: form, imageRows: imageRows)
        : ClipRowView.height(of: item, imageRows: imageRows),
      alignment: .top
    )
    .clipped()
    .contentShape(.rect)
    // 按着的那一行变暗（同原来 .plain 按钮按住时的观感），拖出去之后不暗
    .opacity(press.isDown && !press.isDragging ? 0.75 : 1)
    // 整行一个按下手势：拖开 6 pt 起 AppKit 拖放会话（ClipDrag，体检 D3；之后的鼠标事件归它，不改选中，放成了照常收起面板、
    // 固定着不收），松手时没拖、挪了不到 6 pt、还在这一行里就算点按（model.click 看松手那个事件的连击数和 ⌘ ⇧；
    // ⌃ 单击是右键菜单，不算）。不限按多久、挪 5 pt 照样算点按，同原来的按钮。
    // 不用 Button（美化与提速 P1–P2，例外写在 mac-clipboard §5）：每行一个按钮时它们都在键盘焦点链里，行一进一出、一挪位置，
    // SwiftUI 就把整个面板的焦点链（每个能拿焦点的东西一个代理视图）重排一遍；焦点一直在搜索框、Tab 被拿去开筛选面板，
    // 本来也走不到行上。也不用 onTapGesture：按住 0.75 s 以上、挪 5 pt 再松手都不算点，按下不变暗
    .gesture(
      DragGesture(minimumDistance: 0)
        .updating($press) { value, state, _ in
          state.isDown = true
          guard !state.isDragging, RowPress.distance(value.translation) >= RowPress.dragDistance
          else { return }
          state.isDragging = true
          ClipDrag.begin(
            model.dragItems(for: item),
            previews: [ClipDrag.preview(item, form: form, images: model.store.images)]
          ) { [model] in if !model.isPinned { model.hidePanel() } }
        }
        .onEnded { value in
          let height =
            lensOpen
            ? Lens.height(for: item, form: form, imageRows: imageRows)
            : ClipRowView.height(of: item, imageRows: imageRows)
          guard RowPress.distance(value.translation) < RowPress.dragDistance,
            value.location.x >= 0, value.location.y >= 0, value.location.y < height,
            NSApp.currentEvent?.modifierFlags.contains(.control) != true
          else { return }
          model.click(item)
        }
    )
    // 面板不是 key 时（固定着点过别的 App、点过 ⌘Y 大卡）第一下就生效，同原来的按钮（first mouse）
    .allowsWindowActivationEvents()
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityValue(lensOpen ? Lens.accessibilityValue(for: item, form: form) : "")
    // 旁白「按下」= 只选中（不看 NSApp.currentEvent：最后一个事件刚好是双击松开时会被当成粘贴），粘贴在动作列表里
    .accessibilityAction { model.click(item, as: .select) }
    .accessibilityActions {
      Button("粘贴") { model.paste([item]) }
      Button("放大预览") {
        model.select(item)
        model.toggleQuickLook()
      }
      Button(item.favorite ? "取消收藏" : "收藏") { model.toggleFavorite([item.id]) }
    }
    // 右键菜单和 ⌘K 同一份动作（体检 B12）；包成视图：菜单打开时才算，不在每次画行时建一遍。挂在无障碍那几样外面
    // （同原来）：在合并朗读的元素里面的话，旁白 VO-⇧-M 可能打不开
    .contextMenu { ActionContextMenu { model.actions(for: item, targets: [item]) } }
    #if DEBUG
      .modifier(ReportsRowFrame(item: item.id))
    #endif
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.form == rhs.form && lhs.query == rhs.query
      && lhs.shortcutIndex == rhs.shortcutIndex && lhs.showsShortcut == rhs.showsShortcut
      && lhs.isChecked == rhs.isChecked && lhs.isSelected == rhs.isSelected
      && lhs.lensOpen == rhs.lensOpen && lhs.groupName == rhs.groupName
      && lhs.imageRows == rhs.imageRows && lhs.shownAt == rhs.shownAt && lhs.model === rhs.model
  }

  /// 透镜换内容：opacity + y 4→0（≤ 0.18 s）；连发、换列表、减弱动态效果时瞬间展开收起
  private var lensTransition: AnyTransition {
    guard !reduceMotion, model.selectionMotion != .instant else { return .identity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.16)),
      removal: .opacity.animation(.easeIn(duration: Style.fadeOut)))
  }
}

#if DEBUG
  /// 单测用（ClipboardStoreTests 的透镜位置那几条）：打开后每个行视图把自己实际画在哪（窗口坐标，原点左上）报进来，
  /// 核对画出来的位置就是前缀和算的、没有搬走没清掉的旧行。原来找每行背景里的悬停追踪视图（一个和整行一样大的 NSView），
  /// 悬停收成整块列表一块之后（美化与提速 P2）行里没有 NSView 了。没打开时行上什么都不挂
  enum ClipRowFrames {
    /// 正在用它的测试有几个（同进程里几个测试可能叠着跑）：都用完了清掉记下的、行上不再挂
    static var users = 0 {
      didSet { if users == 0 { frames = [:] } }
    }
    static var isOn: Bool { users > 0 }
    /// 每个行视图一条（同一条目在新旧两个分组里各有一行时是两条）：条目、frame
    static var frames: [UUID: (item: UUID, frame: CGRect)] = [:]
  }

  private struct ReportsRowFrame: ViewModifier {
    let item: UUID
    @State private var token = UUID()

    func body(content: Content) -> some View {
      if ClipRowFrames.isOn {
        content
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            ClipRowFrames.frames[token] = (item, $0)
          }
          .onDisappear { ClipRowFrames.frames[token] = nil }
      } else {
        content
      }
    }
  }
#endif

/// 一行的按下手势的状态（ClipListRow）：按着没有、已经起了拖放会话没有
private struct RowPress: Equatable {
  var isDown = false
  var isDragging = false
  /// 拖开这么远起拖放会话；挪得比它少松手算点按
  static let dragDistance: CGFloat = 6

  static func distance(_ translation: CGSize) -> CGFloat {
    (translation.width * translation.width + translation.height * translation.height).squareRoot()
  }
}

/// 列表行的身份：所在分组（那天的零点）+ 条目（见 rows(_:in:selected:lensOpen:)）
private struct RowID: Hashable {
  let section: Date
  let item: UUID
}

/// ForEach 的身份（list）：「新建片段」、分组标题（那一天）、行（所在分组 + 条目）
private enum EntryID: Hashable {
  case newSnippet
  case header(Date)
  case row(RowID)
}

/// 分组标题「今天 · 12」+ 一条发丝线。高度必须正好是 headerHeight：高亮、滚动、吸顶都按它累加。
/// 吸顶时加底，平时没有灰条：15 是材质；macOS 26 起（2026-11-23 美化 V5）材质在玻璃上是一条颜色不一样的带子（深色时
/// 发黑）、下面那行字从它下沿露出半截，改成面板的底色、下沿 fade 淡出（滚动边缘效果的观感）
private struct SectionHeader: View {
  let section: ClipboardPanelView.DaySection
  var pinned = false
  /// 26 起吸顶时底色往下多铺这么高、从实淡到透明
  private static let fade: CGFloat = 12
  private static let fill = Color(nsColor: Style.stickyHeaderFill)

  var body: some View {
    HStack(spacing: 8) {
      Text("\(section.title) · \(section.rows.count)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Style.metaText)
      Hairline()
    }
    .padding(.horizontal, 10)
    .frame(height: ClipboardPanelView.headerHeight)
    .background(alignment: .top) {
      if !pinned {
        Color.clear
      } else if #available(macOS 26, *) {
        let height = ClipboardPanelView.headerHeight + Self.fade
        LinearGradient(
          stops: [
            .init(color: Self.fill, location: 0),
            .init(color: Self.fill, location: ClipboardPanelView.headerHeight / height),
            .init(color: Self.fill.opacity(0), location: 1),
          ], startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        // 铺到列表左右的边（四周内缩 inset 那一条也盖住），不然两侧露出两道竖边
        .padding(.horizontal, -ClipboardPanelView.inset)
      } else {
        Rectangle().fill(.ultraThinMaterial)
      }
    }
  }
}

/// 吸顶的分组标题（同系统列表）：哪一组的标题滚过了列表顶，就把它停在顶上（材质底），下一组的标题顶上来时把它推上去。
/// 放在滚动内容里（叠在列表外面会挡住滚动条，2026-10-03 用户指出），每一组的位置按几何每帧算（visualEffect，不重画面板）：
/// 停在可见区的顶，夹在它自己标题的位置和下一组标题上面一格之间；没滚过自己的标题时透明（列表里那条在原处）。
/// 只画 shown 这几组（画出来的那一段涉及的组，可见区顶上那组一定在里面）
private struct StickyHeaders: View {
  let sections: [ClipboardPanelView.DaySection]
  /// 各组标题的顶（列表坐标），最后多一个总高：第 k 组吸顶时夹在 bounds[k] 和 bounds[k + 1] − 标题高之间
  let bounds: [CGFloat]
  let shown: ClosedRange<Int>

  var body: some View {
    let header = ClipboardPanelView.headerHeight
    ZStack(alignment: .top) {
      ForEach(Array(shown), id: \.self) { k in
        let (top, bottom) = (bounds[k], bounds[k + 1] - header)
        SectionHeader(section: sections[k], pinned: true)
          .visualEffect { content, proxy in
            // 这一层的顶就是列表的顶：它在滚动视图里往上出去多少，可见区的顶就在列表坐标的多少
            let visible = -proxy.frame(in: .scrollView).minY
            return content.offset(y: min(max(visible, top), bottom))
              .opacity(visible > top + 0.5 ? 1 : 0)
          }
      }
    }
    // 不接点击（点在吸顶标题上照常点到下面那一行）；旁白读列表里那一条
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// 列表的一列（美化与提速 P1–P2）：画出来的那几项按前缀和摆（每项带着自己的 Slot：顶和高），整列的高就是列表总高，
/// 不量子视图。原来是 VStack + 上下两块撑高的空档：VStack 每排一次都要问每一项「最矮 / 最高能多少」（StackLayout.prioritize），
/// 一行要从外到里一路量到里面的字，↑↓ 时它占主线程忙的约四分之一、滚动跨段时约一成半；这里只把每一项按算好的位置和高摆上去。
/// 位置变了（透镜开合、增删）跟着那次 transaction 的动画走，和 VStack 一样
private struct ListColumn: Layout {
  /// 一项的顶（列表坐标）和高
  struct Slot: LayoutValueKey {
    static let defaultValue = Slot(top: 0, height: 0)
    var top: CGFloat
    var height: CGFloat
  }

  /// 整列的高（= 列表总高，ListLayout.totalHeight）
  let height: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: proposal.width ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      let slot = subview[Slot.self]
      subview.place(
        at: CGPoint(x: bounds.minX, y: bounds.minY + slot.top), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: slot.height))
    }
  }
}

/// 悬停在哪一行：ListHoverTracker 报鼠标在可见区里的位置，加上滚动位置、按前缀和换算。只有悬停那层底（HoverHighlight）
/// 读 id，鼠标在行间移动只重画那一层
@Observable private final class ListHover {
  /// 鼠标底下的行（按报位置那一刻的列表几何）；nil = 不在列表上，或在分组标题、「新建片段」上
  private(set) var id: UUID?
  /// 鼠标在可见区里的位置（y 朝下）、可见区的顶在滚动内容里的 y：滚动、列表变了时按它们重算
  @ObservationIgnored private var point: CGPoint?
  /// 可见区的顶（滚动内容坐标）：换列表回顶时看一眼已经在不在顶上
  @ObservationIgnored private(set) var offset: CGFloat = 0

  func move(to point: CGPoint?, in layout: ListLayout) {
    self.point = point
    id = row(in: layout)
  }

  /// 按住鼠标键滚的（拖滚动条）：收不到 mouseMoved，鼠标底下的行在固定高度上一行行扫过去，这时不出悬停
  func scroll(to offset: CGFloat, in layout: ListLayout) {
    self.offset = offset
    if NSEvent.pressedMouseButtons != 0 { point = nil }
    id = row(in: layout)
  }

  /// 按这份几何，鼠标底下是哪一行（滚动内容 − 四周内缩 = 列表坐标）
  func row(in layout: ListLayout) -> UUID? {
    point.flatMap { layout.rowID(atY: $0.y + offset - ClipboardPanelView.inset) }
  }
}

/// 悬停底：鼠标底下那一行（选中行除外，它下面已经是透镜的底）铺 fill.hover，0.10 s 淡入淡出；按前缀和定位，
/// 原来每行各自一块（美化与提速 P2 收成一块）。透镜开合、滚动让别的行挪到鼠标底下时按新的几何重算（row(in:)）
private struct HoverHighlight: View {
  let hover: ListHover
  let layout: ListLayout
  let selectedID: UUID?

  var body: some View {
    let id = hover.id == nil ? nil : hover.row(in: layout)
    ZStack(alignment: .topLeading) {
      if let id, id != selectedID, let y = layout.offset(of: id) {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(Style.hoverFill)
          .frame(height: layout.height(of: id))
          .offset(y: y)
          .id(id)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .animation(.easeOut(duration: 0.10), value: id)
    .allowsHitTesting(false)
  }
}

/// 透镜移动的动画触发值：选中换了、或透镜开关变了（多选时收起）
private struct LensKey: Equatable {
  let id: UUID?
  let isOpen: Bool
}

/// 搜索框里的粉色筛选标签：高 22、12 medium、品牌粉 0.12 底 + brandInk 字（⌫ 待删时 0.30 底），尾部 8 pt ×（字到 × 6）。
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
          .padding(.trailing, 6)
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
