// 启动器根视图（Whisker 设计语言，mac-whisker §6 启动器）：56 pt 大搜索框；单行 40 pt 结果（24 pt 图标 / 种类色块，
// 标题 14 medium 后面紧跟灰色副标题，右侧写类型；文件搜索的结果按 Spotlight 类型取图标、右侧写扩展名），
// 空查询时带「最近使用」、文件搜索只输关键词时带「最近打开和下载的文件」分组标题；计算结果是 64 pt 的大数字卡；
// 一块中性高亮在行间滑动（键盘 snap、连发不动画、点选 glide）；选中的内置动作右侧多一组全局快捷键键帽（N10）；
// 按住修饰键时选中行的副标题换成替代动作，按住 ⌘ 150 ms 后类型依次换成 ⌘1–9 键帽。
// 底栏 36（N8，对标 Raycast）：左边选中项的种类（16 pt 家族色块 + 种类名），右边「主动作 ↩」（品牌粉实心键帽）·
// 「动作 ⌘K」，都能点；⌘K 动作菜单（共用 ActionMenu）锚在右下，开着时面板至少高到放得下它。没有图钉、齿轮
// （⌘, 照样开设置）。面板高度随行数伸缩（带动画），顶边不动。状态和操作都在 LauncherModel。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherPanelView: View {
  @Bindable var model: LauncherModel
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  /// 按住 ⌘ 超过 150 ms：类型标签换成键帽
  @State private var showsShortcuts = false

  static let searchHeight: CGFloat = 56
  static let rowHeight: CGFloat = 40
  static let calcHeight: CGFloat = 64
  static let groupHeight: CGFloat = 28
  static let barHeight: CGFloat = 36
  /// 分组标题在列表里的 id（滚回顶部时滚到它，不然标题被滚出去）
  static let groupID = "launcher-group-title"
  /// 多出半行，让人看得出下面还能滚（动作菜单同样）
  static let visibleRows = 8.5

  var body: some View {
    VStack(spacing: 0) {
      searchBar.frame(height: Self.searchHeight)
      Style.hairline.frame(height: 0.5)
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

  private var listTop: CGFloat { model.groupTitle != nil ? Self.groupHeight : 0 }

  /// 面板高度 = 搜索栏 + 发丝线 +（错误）+ 列表（最多 8.5 行）+ 底栏；⌘K 菜单开着时至少放得下它
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
      height += 12 + (model.groupTitle != nil ? groupHeight : 0) + rows
    }
    // 菜单画在面板里、锚在底栏上方 4 pt，离搜索栏至少 8 pt；按没过滤的行数算，边打字过滤面板不跳。
    // 菜单高 = 行数 × 28 + 上下内缩各 5
    if model.showsActions {
      let menu = min(CGFloat(model.actions.count), visibleRows) * ActionMenu.rowHeight + 10
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
          if let groupTitle = model.groupTitle {
            Text(groupTitle)
              .id(Self.groupID)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.tertiary)
              .padding(.leading, 12)
              .padding(.bottom, 2)
              // 高度必须正好是 groupHeight：高亮和面板高度都按它算
              .frame(
                maxWidth: .infinity, minHeight: Self.groupHeight, maxHeight: Self.groupHeight,
                alignment: .bottomLeading)
          }
          ForEach(Array(model.results.enumerated()), id: \.element.rowID) { index, item in
            Button {
              model.click(item)
            } label: {
              let isSelected = index == model.selection
              LauncherRow(
                item: item, index: index, showsShortcut: showsShortcuts && index < 9,
                isSelected: isSelected,
                alternate: isSelected ? model.alternateSubtitle(for: item) : nil,
                hotKey: isSelected ? item.hotKeyAction.flatMap(model.boundHotKey)?.display : nil
              )
              .frame(height: rowHeight(item))
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .id(item.rowID)
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
          // 回到第一行时连分组标题一起露出来
          proxy.scrollTo(
            selection == 0 && model.groupTitle != nil
              ? Self.groupID : model.results[selection].rowID)
        }
      }
      // 新结果时选中项回到第 0 行，但 selection 本来就是 0 时上面不触发：列表也要回到顶部（有分组标题就到标题）；
      // 文件结果后续批次保留了用户选的那行时滚到那行
      .onChange(of: model.results) {
        if model.selection > 0, model.results.indices.contains(model.selection) {
          proxy.scrollTo(model.results[model.selection].rowID)
        } else if let first = model.results.first {
          proxy.scrollTo(model.groupTitle != nil ? Self.groupID : first.rowID, anchor: .top)
        }
      }
    }
  }

  /// 一块中性高亮，按前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private var highlight: some View {
    if model.results.indices.contains(model.selection) {
      let offset = listTop + model.results.prefix(model.selection).map(rowHeight).reduce(0, +)
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      shape
        .fill(Style.selectedFill)
        // 增强对比度：中性高亮加 1 pt 品牌粉 0.6 描边（mac-whisker §7）
        .overlay { if contrast == .increased { shape.strokeBorder(Style.brand.opacity(0.6)) } }
        .frame(height: rowHeight(model.results[model.selection]))
        .offset(y: offset)
        .animation(model.selectionMotion.animation(reduced: reduceMotion), value: model.selection)
        .animation(nil, value: model.results)
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

  /// 底栏（N8）：左边选中项的种类，右边主动作 ↩ 和动作菜单 ⌘K，都能点。没有选中项时空着
  private var bar: some View {
    HStack(spacing: 12) {
      if let selected = model.selectedItem {
        HStack(spacing: 8) {
          KindTile(symbol: selected.familySymbol, color: selected.familyColor, size: 16)
          Text(selected.kindTitle).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
        Style.hairline.frame(width: 0.5, height: 16)
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
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .frame(height: Self.barHeight)
    .overlay(alignment: .top) { Style.hairline.frame(height: 0.5) }
  }
}

private struct LauncherRow: View {
  let item: LauncherItem
  let index: Int
  let showsShortcut: Bool
  let isSelected: Bool
  /// 按住修饰键时的替代动作说明（只有选中行有）：换掉副标题，计算结果换掉算式
  let alternate: String?
  /// 选中的内置动作当前的全局快捷键（N10，没设就是 nil）
  let hotKey: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        Text(item.payload ?? item.title)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: item.payload)
      } else {
        Text(item.title)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1)
          .layoutPriority(1)
        if let subtitle = alternate ?? (item.subtitle.isEmpty ? nil : item.subtitle) {
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(alternate == nil ? .secondary : .primary)
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
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private var icon: some View {
    if let type = item.contentType {
      Image(nsImage: LauncherIcons.icon(for: type)).resizable().frame(width: 24, height: 24)
    } else if item.kind == .app || item.kind == .path,
      let image = LauncherIcons.icon(for: item.target)
    {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
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
  /// 行里种类色块的符号：内置动作用它自己的
  fileprivate var tileSymbol: String {
    switch kind {
    case .calculation: "equal"
    case .prompt where target == FileSearch.accessTarget: "lock.open.fill"
    case .prompt where target.hasPrefix("file-"): "doc.text.magnifyingglass"
    case .search, .prompt: "magnifyingglass"
    default: symbol
    }
  }

  /// 底栏左边 16 pt 小色块的符号：只看种类，不看具体哪一项
  fileprivate var familySymbol: String {
    switch kind {
    case .app: "square.grid.2x2.fill"
    case .path: contentType?.conforms(to: .folder) == true ? "folder.fill" : "doc.fill"
    case .action: "command"
    default: tileSymbol
    }
  }

  /// 功能家族色（mac-whisker §3）：行里的种类色块、底栏左边的小色块
  fileprivate var familyColor: Color {
    switch kind {
    case .action: target == "settings" ? Style.Family.general : Style.Family.command
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
    case .path:
      contentType.map { FileSearch.kindTitle(path: target, contentType: $0.identifier) } ?? "文件"
    case .action: "命令"
    case .url: "网址"
    case .prompt where target == FileSearch.accessTarget: "授权"
    case .search, .prompt: "搜索"
    case .calculation: "计算"
    case .clip: "剪贴板"
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
