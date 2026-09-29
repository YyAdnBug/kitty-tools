// 启动器根视图（Whisker 设计语言，mac-whisker §6 启动器）：56 pt 大搜索框；单行 40 pt 结果（24 pt 图标 / 种类色块，
// 标题 14 medium 后面紧跟灰色副标题，右侧写类型；文件搜索的结果按 Spotlight 类型取图标、右侧写扩展名；网址 / 书签 /
// 历史 / 网页搜索行是网站图标（SiteIcons，没有才用家族色块，体检 D6），系统设置面板是系统设置的 App 图标），
// 空查询时带「收藏」「常用」、文件搜索只输关键词时带「最近打开和下载的文件」分组标题；计算结果是 64 pt 的大数字卡；
// 一块中性高亮在行间滑动（键盘 snap、连发不动画、点选 glide）；没选中的行悬停铺 fill.hover（HoverTracker，体检 B37）；
// 选中的内置动作右侧多一组全局快捷键键帽（N10）；按住修饰键时选中行的副标题换成替代动作，按住 ⌘ 150 ms 后类型依次
// 换成 ⌘1–9 键帽；系统命令上了膛（清倒废纸篓、全部退出、强制退出的第一下）时选中行副标题换成 systemRed 的「再按 ↩ …」。
// 行上右键是和 ⌘K 同一份动作（ActionContextMenu，体检 C8），VoiceOver 另有主动作、⌘↩、复制、收藏、移除几个动作。
// 底栏 36（N8，对标 Raycast）：左边选中项的种类（16 pt 家族色块 + 种类名；收藏、移除常用时换成就地提示，移除带
// 「撤销 ⌘Z」），右边「主动作 ↩」（品牌粉实心键帽）·「动作 ⌘K」，都能点；⌘K 动作菜单（共用 ActionMenu）锚在右下，
// 开着时面板至少高到放得下它。没有图钉、齿轮（⌘, 照样开设置）。面板高度随行数伸缩（带动画），顶边不动。
// 状态和操作都在 LauncherModel。⌘Y 快速查看的预览卡（LauncherQuickLookView）也在这里。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherPanelView: View {
  @Bindable var model: LauncherModel
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 按住 ⌘ 超过 150 ms：类型标签换成键帽
  @State private var showsShortcuts = false

  static let searchHeight: CGFloat = 56
  static let rowHeight: CGFloat = 40
  static let calcHeight: CGFloat = 64
  static let groupHeight: CGFloat = 28
  static let barHeight: CGFloat = 36
  /// 分组标题在列表里的 id（滚回顶部时滚到它，不然标题被滚出去）
  static func groupID(_ row: Int) -> String { "launcher-group-\(row)" }
  /// 多出半行，让人看得出下面还能滚（动作菜单同样）
  static let visibleRows = 8.5

  var body: some View {
    VStack(spacing: 0) {
      searchBar.frame(height: Self.searchHeight)
      Hairline()
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: .systemRed))
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          .padding(.horizontal, 16)
      }
      if showsNoResults {
        Text(model.emptyText)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 12)
      } else if !model.results.isEmpty {
        list
      }
      Spacer(minLength: 0)
      bar
    }
    .overlay(alignment: .bottomTrailing) { actionMenu }
    .onChange(of: Self.height(for: model), initial: true) { _, height in model.resize(height) }
    .onModifierKeysChanged(mask: [.command, .option, .control]) { _, keys in
      model.alternate =
        keys.contains(.command)
        ? .command : keys.contains(.option) ? .option : keys.contains(.control) ? .control : .none
    }
    .task(id: model.alternate == .command) {
      guard model.alternate == .command else {
        showsShortcuts = false
        return
      }
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { showsShortcuts = true }
    }
  }

  private var showsNoResults: Bool { !model.isShowingRecent && model.results.isEmpty }

  /// 行高：高亮的位置和面板高度都按它的前缀和算
  private func rowHeight(_ item: LauncherItem) -> CGFloat { Self.rowHeight(item) }

  static func rowHeight(_ item: LauncherItem) -> CGFloat {
    item.kind == .calculation ? calcHeight : rowHeight
  }

  /// 第 row 行的顶在列表里的位置：它和它前面的分组标题 + 前面各行的高
  static func offset(ofRow row: Int, in model: LauncherModel) -> CGFloat {
    CGFloat(model.groups.filter { $0.row <= row }.count) * groupHeight
      + model.results.prefix(row).map(rowHeight).reduce(0, +)
  }

  /// 面板高度 = 搜索栏 + 发丝线 +（错误）+ 列表（分组标题各 28 + 最多 8.5 行）+ 底栏；⌘K 菜单开着时至少放得下它
  static func height(for model: LauncherModel) -> CGFloat {
    var height = searchHeight + 0.5 + barHeight
    if model.error != nil { height += 28 }
    if !model.isShowingRecent && model.results.isEmpty {
      height += rowHeight + 12
    } else if !model.results.isEmpty {
      let heights = model.results.map(rowHeight)
      let full = Int(visibleRows)
      var rows = heights.prefix(full).reduce(0, +)
      if heights.count > full { rows += heights[full] / 2 }
      height += 12 + CGFloat(model.groups.count) * groupHeight + rows
    }
    // 菜单画在面板里、锚在底栏上方 4 pt，离搜索栏至少 8 pt；按没过滤的动作算，边打字过滤面板不跳。
    // 菜单高 = 行和分节线（最多 8.5 行高）+ 上下内缩各 5
    if model.showsActions {
      let menu = ActionMenu.height(model.actions, maxRows: visibleRows) + 10
      height = max(height, searchHeight + 0.5 + 8 + menu + 4 + barHeight)
    }
    return height
  }

  private var searchBar: some View {
    HStack(spacing: 12) {
      Image(systemName: model.showsActions ? "command" : "magnifyingglass")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
      // ⌘K 菜单开着时，搜索框改成过滤动作
      CommandTextField(
        text: model.showsActions ? $model.actionQuery : $model.query,
        placeholder: model.showsActions ? "搜索动作" : "搜索 App、网址、命令或文件", fontSize: 20,
        romanOnly: romanInput, onCommand: model.handleCommand)
    }
    .padding(.horizontal, 18)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          let groups = model.groups
          ForEach(Array(model.results.enumerated()), id: \.element.rowID) { index, item in
            if let group = groups.first(where: { $0.row == index }) {
              groupHeader(group)
            }
            Button {
              model.click(item)
            } label: {
              let isSelected = index == model.selection
              LauncherRow(
                item: item, index: index, showsShortcut: showsShortcuts && index < 9,
                isSelected: isSelected, isArmed: model.isArmed(item),
                alternate: isSelected ? model.alternateSubtitle(for: item) : nil,
                hotKey: isSelected ? item.hotKeyAction.flatMap(model.boundHotKey)?.display : nil
              )
              .frame(height: rowHeight(item))
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .id(item.rowID)
            // 右键和 ⌘K 同一份动作（体检 C8）；包成视图：菜单打开时才算，不在每次画行时建一遍
            .contextMenu { ActionContextMenu { model.actions(for: item) } }
            .accessibilityActions { accessibilityActions(for: item) }
          }
        }
        .background(alignment: .topLeading) { highlight }
        .padding(6)
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.selection) { _, selection in
        guard model.results.indices.contains(selection) else { return }
        withAnimation(
          model.selectionMotion == .instant
            ? nil : Style.Motion.snap.animation(reduced: reduceMotion)
        ) {
          // 回到一组的第一行时连分组标题一起露出来
          proxy.scrollTo(
            model.groups.contains { $0.row == selection }
              ? Self.groupID(selection) : model.results[selection].rowID)
        }
      }
      // 新结果时选中项回到第 0 行，但 selection 本来就是 0 时上面不触发：列表也要回到顶部（有分组标题就到标题）；
      // 文件结果后续批次保留了用户选的那行时滚到那行
      .onChange(of: model.results) {
        if model.selection > 0, model.results.indices.contains(model.selection) {
          proxy.scrollTo(model.results[model.selection].rowID)
        } else if let first = model.results.first {
          proxy.scrollTo(
            model.groups.first?.row == 0 ? Self.groupID(0) : first.rowID, anchor: .top)
        }
      }
    }
  }

  /// 分组标题：高度必须正好是 groupHeight（高亮和面板高度都按它算）
  private func groupHeader(_ group: LauncherModel.Group) -> some View {
    Text(group.title)
      .id(Self.groupID(group.row))
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tertiary)
      .padding(.leading, 12)
      .padding(.bottom, 2)
      .frame(
        maxWidth: .infinity, minHeight: Self.groupHeight, maxHeight: Self.groupHeight,
        alignment: .bottomLeading
      )
      .accessibilityAddTraits(.isHeader)
  }

  /// VoiceOver 的动作（体检 B37）：按一下行只是选中，这里给直接执行的；和 ⌘K 调的是同一批方法
  @ViewBuilder private func accessibilityActions(for item: LauncherItem) -> some View {
    Button(model.primaryAction(for: item).title) { model.execute(item) }
    if let secondary = model.commandReturnAction(for: item) {
      Button(secondary.title) { model.commandReturn(item) }
    }
    if let copy = model.copyTitle(for: item) {
      Button(copy) { model.copy(item) }
    }
    if model.canFavorite(item) {
      Button(model.isFavorite(item) ? "取消收藏" : "加入收藏") { model.toggleFavorite(item) }
    }
    if model.isCommon(item) {
      Button("从常用中移除") { model.forget(item) }
    }
  }

  /// 一块中性高亮，按前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private var highlight: some View {
    if let selected = model.selectedItem {
      let offset = Self.offset(ofRow: model.selection, in: model)
      let height = rowHeight(selected)
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      shape
        .fill(Style.selectedFill)
        .overlay { shape.contrastSelectionBorder() }
        .frame(height: height)
        .offset(y: offset)
        .animation(model.selectionMotion.animation(reduced: reduceMotion), value: model.selection)
        .animation(nil, value: model.results)
      // ⌘Y 预览从选中行长出来：按同样的前缀和报它在窗口里的位置，只报列表可见区里的部分（滚出去的不当起点）；
      // 按选中项换一个新视图，一出现就报终点位置（同剪贴板的透镜）
      Color.clear
        .frame(height: height)
        .onGeometryChange(for: CGRect.self) { proxy in
          let global = proxy.frame(in: .global)
          let visible = CGRect(origin: .zero, size: proxy.size)
            .intersection(proxy.bounds(of: .scrollView) ?? .infinite)
          return visible.isEmpty ? .null : visible.offsetBy(dx: global.minX, dy: global.minY)
        } action: { rect in
          model.rowFrame = rect.isNull ? nil : (selected.id, rect)
        }
        .offset(y: offset)
        .onDisappear { if model.rowFrame?.id == selected.id { model.rowFrame = nil } }
        .id(selected.id)
    }
  }

  /// ⌘K 动作菜单：从右下角放大出来（转场在 ActionMenu 里），锚在底栏「动作 ⌘K」的上方。
  /// 要撑高面板时是瞬间长高（AppDelegate 的 resize 在菜单开着时不动画），菜单一出来就在最终位置
  private var actionMenu: some View {
    ZStack(alignment: .bottomTrailing) {
      if model.showsActions {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          emptyText: "没有匹配的动作", maxRows: Self.visibleRows, onRun: model.run
        )
        .padding(.trailing, 12)
        .padding(.bottom, Self.barHeight + 4)
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: model.showsActions)
  }

  /// 底栏（N8）：左边选中项的种类（有就地提示时换成提示），右边主动作 ↩ 和动作菜单 ⌘K，都能点。没有选中项时空着
  private var bar: some View {
    HStack(spacing: 12) {
      if let notice = model.notice {
        BarNoticeView(notice: notice, undo: model.undoForget)
          .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
          .id(notice)
      }
      if let selected = model.selectedItem {
        if model.notice == nil {
          HStack(spacing: 8) {
            KindTile(symbol: selected.familySymbol, color: selected.familyColor, size: 16)
            Text(selected.kindTitle).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        Spacer(minLength: 8)
        let primary = model.primaryAction(for: selected).title
        Button {
          model.execute(selected)
        } label: {
          HStack(spacing: 6) {
            Text(primary)
            KeyCap("↩", primary: true).accessibilityHidden(true)
          }
        }
        .accessibilityLabel(primary)
        Hairline(vertical: true).frame(height: 16)
        Button(action: model.toggleActions) {
          HStack(spacing: 6) {
            Text("动作")
            KeyCap("⌘K")
          }
        }
        .accessibilityLabel("动作")
      } else {
        Spacer()
      }
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: model.notice)
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .frame(height: Self.barHeight)
    .overlay(alignment: .top) { Hairline() }
  }
}

/// ⌘Y 快速查看（体检 C7）：选中文件的 Quick Look 预览（和剪贴板 ⌘Y 大卡同一个单文件视图 QuickLookFile），
/// 浮层从选中行长出来、⌘Y / Esc 缩回；跟着启动器里的选中项换文件，选中的不是文件时写一句话
struct LauncherQuickLookView: View {
  let model: LauncherModel

  var body: some View {
    if model.showsQuickLookContent, let url = model.quickLookURL {
      QuickLookFile(url: url)
        .clipShape(.rect(cornerRadius: Style.Radius.card, style: .continuous))
        .padding(6)
    } else if model.showsQuickLookContent {
      Text("没有可预览的文件")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct LauncherRow: View {
  let item: LauncherItem
  let index: Int
  let showsShortcut: Bool
  let isSelected: Bool
  /// 不可撤销的系统命令等着再按一次：副标题（确认提示）用 systemRed，和 macOS 的破坏性按钮同色
  let isArmed: Bool
  /// 按住修饰键时的替代动作说明（只有选中行有）：换掉副标题，计算结果换掉算式
  let alternate: String?
  /// 选中的内置动作当前的全局快捷键（N10，没设就是 nil）
  let hotKey: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 悬停（没选中的行铺 fill.hover，0.10 s 淡入；浮层不激活本 App，SwiftUI 的 onHover 不可靠，用 HoverTracker）
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      icon
      if item.kind == .calculation {
        if let alternate {
          Text(alternate).font(.system(size: 13)).lineLimit(1)
        } else {
          Text(item.target)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: "arrow.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
        // 大字按千分位分组、单位换算带单位（体检 D11）；粘贴的是不分组的 payload
        Text(item.title)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: item.title)
      } else {
        Text(item.title)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1)
          .layoutPriority(1)
        if let subtitle = alternate ?? (item.subtitle.isEmpty ? nil : item.subtitle) {
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(
              isArmed
                ? AnyShapeStyle(Color(nsColor: .systemRed))
                : alternate == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
            )
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      if let hotKey, !showsShortcut {
        KeyCombo(hotKey).accessibilityLabel("快捷键 \(hotKey)")
      }
      kind
    }
    .padding(.horizontal, 10)
    .frame(maxHeight: .infinity)
    .background(
      hovered && !isSelected ? Style.hoverFill : .clear,
      in: .rect(cornerRadius: Style.Radius.card, style: .continuous)
    )
    .background {
      HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private var icon: some View {
    if item.contentType?.conforms(to: .volume) == true {
      // 宗卷（eject 列出来的）：磁盘色块，不读宗卷本身取图标（按类型取是个文件夹，读宗卷可能要授权）
      KindTile(symbol: item.tileSymbol, color: item.familyColor)
    } else if let type = item.contentType {
      Image(nsImage: LauncherIcons.icon(for: type)).resizable().frame(width: 24, height: 24)
    } else if item.kind == .app || item.kind == .path,
      let image = LauncherIcons.icon(for: item.target)
    {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else if item.isSettingsPane,
      let image = LauncherIcons.icon(for: AppCatalog.systemSettingsPath)
    {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else if item.kind == .url || item.kind == .search, let host = SiteIcons.host(of: item.target)
    {
      SiteIcon(host: host, fallback: KindTile(symbol: item.tileSymbol, color: item.familyColor))
    } else {
      KindTile(symbol: item.tileSymbol, color: item.familyColor)
    }
  }

  /// 右侧：类型标签；按住 ⌘ 时依次换成 ⌘1–9 键帽（每行错开 15 ms）
  private var kind: some View {
    ZStack(alignment: .trailing) {
      Text(item.kindTitle)
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .opacity(showsShortcut ? 0 : 1)
      KeyCap("⌘\(index + 1)")
        .opacity(showsShortcut ? 1 : 0)
        .scaleEffect(showsShortcut ? 1 : 0.9)
    }
    .animation(
      reduceMotion
        ? .easeOut(duration: 0.12) : .easeOut(duration: 0.12).delay(Double(index) * 0.015),
      value: showsShortcut)
  }
}

extension LauncherItem {
  /// 系统设置的一个面板（体检 D9）：kind 是 .url，右侧写「设置」、图标是系统设置的
  fileprivate var isSettingsPane: Bool { kind == .url && AppCatalog.isSettingsPane(target) }

  /// 行里种类色块的符号：内置动作用它自己的
  fileprivate var tileSymbol: String {
    switch kind {
    case .calculation: "equal"
    case .path where contentType?.conforms(to: .volume) == true: "externaldrive.fill"
    case .prompt where target == FileSearch.accessTarget: "lock.open.fill"
    case .prompt where target.hasPrefix("file-"): "doc.text.magnifyingglass"
    case .prompt where target.hasPrefix("system-"):
      SystemCommands.Verb(rawValue: String(target.dropFirst("system-".count)))?.symbol ?? "power"
    case .prompt where target == "translate-fy": "character.bubble.fill"
    case .search, .prompt: "magnifyingglass"
    default: symbol
    }
  }

  /// 底栏左边 16 pt 小色块的符号：只看种类，不看具体哪一项
  fileprivate var familySymbol: String {
    switch kind {
    case .app: "square.grid.2x2.fill"
    case .path where contentType?.conforms(to: .volume) == true: "externaldrive.fill"
    case .path: contentType?.conforms(to: .folder) == true ? "folder.fill" : "doc.fill"
    case .action: "command"
    case .system: "power"
    case .translate: "character.bubble.fill"
    case .url where isSettingsPane: "gearshape.fill"
    default: tileSymbol
    }
  }

  /// 功能家族色（mac-whisker §3）：行里的种类色块、底栏左边的小色块
  fileprivate var familyColor: Color {
    switch kind {
    // 内置动作按菜单栏的家族色（体检 A26）：对得上全局热键的用它的，其余用 MenuExtra 的（跟着菜单里所在那一节）
    case .action:
      hotKeyAction?.color ?? MenuExtra(rawValue: target)?.color ?? Style.Family.general
    case .translate: Style.Family.translate
    case .prompt where target == "translate-fy": Style.Family.translate
    case .system, .process: Style.Family.command
    case .prompt where target.hasPrefix("system-"): Style.Family.command
    case .url where isSettingsPane: Style.Family.general
    case .url: Style.Family.url
    // 配置 / 授权问题用橙色（Whisker §3 语义色）
    case .prompt where target == FileSearch.accessTarget: Color(nsColor: .systemOrange)
    case .prompt where target.hasPrefix("file-"): Style.Family.general
    case .search, .prompt: Style.Family.search
    case .calculation: Style.Family.keyboard
    case .clip: Style.Family.clipboard
    case .app, .path: Style.Family.general
    }
  }

  /// 行右侧的类型、底栏左边的种类名
  fileprivate var kindTitle: String {
    switch kind {
    case .app: "应用"
    case .path where contentType?.conforms(to: .volume) == true: "宗卷"
    case .path:
      contentType.map { FileSearch.kindTitle(path: target, contentType: $0.identifier) } ?? "文件"
    case .action: "命令"
    case .system: "系统"
    case .prompt where target.hasPrefix("system-"): "系统"
    case .translate: "翻译"
    case .prompt where target == "translate-fy": "翻译"
    case .url where isSettingsPane: "设置"
    case .url: "网址"
    case .prompt where target == FileSearch.accessTarget: "授权"
    case .search, .prompt: "搜索"
    case .calculation: "计算"
    case .clip: "剪贴板"
    case .process: "进程"
    }
  }
}

/// App / 文件图标（按路径缓存，面板每次重绘不重复读）
enum LauncherIcons {
  private static let cache = NSCache<NSString, NSImage>()

  /// 文件搜索的结果按类型取：不碰文件本身（桌面 / 文稿 / 下载里的文件读图标可能弹授权框）
  static func icon(for type: UTType) -> NSImage {
    let key = "type:" + type.identifier as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let image = NSWorkspace.shared.icon(for: type)
    cache.setObject(image, forKey: key)
    return image
  }

  /// 已经拿到的图标（正在运行的 App 从 NSRunningApplication 取）：放进缓存，行里就不按路径读文件
  static func remember(_ image: NSImage, for path: String) {
    cache.setObject(image, forKey: path as NSString)
  }

  static func icon(for path: String) -> NSImage? {
    if let cached = cache.object(forKey: path as NSString) { return cached }
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: path)
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

extension LauncherItem {
  /// 列表里的身份：计算结果行跨按键保持同一个（id 含算式，每敲一个字都会变），结果数字才能滚动变化
  fileprivate var rowID: String { kind == .calculation ? "calculation" : id }
}
