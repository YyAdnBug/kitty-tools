// 启动器根视图（Whisker 设计语言，mac-whisker §6 启动器）：56 pt 大搜索框；单行 40 pt 结果（24 pt 图标 / 种类色块，
// 标题 14 medium 后面紧跟灰色副标题，右侧写类型），空查询时带「最近使用」分组标题；计算结果是 64 pt 的大数字卡；
// 一块中性高亮在行间滑动（键盘 snap、连发不动画、点选 glide）；按住 ⌘ 150 ms 后类型依次换成 ⌘1–9 键帽；
// 底栏：按住修饰键时的替代动作 + 主动作 ↩ + 设置 / 图钉。面板高度随行数伸缩（带动画），顶边不动。
// 状态和操作都在 LauncherModel。

import AppKit
import SwiftUI

struct LauncherPanelView: View {
  @Bindable var model: LauncherModel
  var openSettings: () -> Void = {}
  @AppStorage(Prefs.launcherHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 按住 ⌘ 超过 150 ms：类型标签换成键帽
  @State private var showsShortcuts = false

  static let searchHeight: CGFloat = 56
  static let rowHeight: CGFloat = 40
  static let calcHeight: CGFloat = 64
  static let groupHeight: CGFloat = 28
  static let barHeight: CGFloat = 36
  /// 多出半行，让人看得出下面还能滚
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
        Text("没有匹配的结果")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 12)
      } else if !model.results.isEmpty {
        list
      }
      Spacer(minLength: 0)
      bar
    }
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

  private var listTop: CGFloat { model.isShowingRecent ? Self.groupHeight : 0 }

  /// 面板高度 = 搜索栏 + 发丝线 +（错误）+ 列表（最多 8.5 行）+ 底栏
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
      height += 12 + (model.isShowingRecent ? groupHeight : 0) + rows
    }
    return height
  }

  private var searchBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tertiary)
      CommandTextField(
        text: $model.query, placeholder: "搜索 App、网址、命令或文件", fontSize: 20,
        romanOnly: romanInput, onCommand: model.handleCommand)
    }
    .padding(.horizontal, 18)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          if model.isShowingRecent {
            Text("最近使用")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, minHeight: Self.groupHeight, alignment: .bottomLeading)
              .padding(.leading, 12)
              .padding(.bottom, 2)
          }
          ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            Button {
              model.click(item)
            } label: {
              LauncherRow(
                item: item, index: index, showsShortcut: showsShortcuts && index < 9,
                isSelected: index == model.selection
              )
              .frame(height: rowHeight(item))
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .id(item.id)
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
          proxy.scrollTo(model.results[selection].id)
        }
      }
      // 新结果时选中项回到第 0 行，但 selection 本来就是 0 时上面不触发：列表也要回到顶部
      .onChange(of: model.results) {
        if let first = model.results.first { proxy.scrollTo(first.id, anchor: .top) }
      }
    }
  }

  /// 一块中性高亮，按前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private var highlight: some View {
    if model.results.indices.contains(model.selection) {
      let offset = listTop + model.results.prefix(model.selection).map(rowHeight).reduce(0, +)
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .fill(Style.selectedFill)
        .frame(height: rowHeight(model.results[model.selection]))
        .offset(y: offset)
        .animation(model.selectionMotion.animation(reduced: reduceMotion), value: model.selection)
        .animation(nil, value: model.results)
    }
  }

  /// 底栏：左边是按住修饰键时的替代动作（平时提示可以按），右边主动作 + 设置 / 图钉
  private var bar: some View {
    let selected =
      model.results.indices.contains(model.selection) ? model.results[model.selection] : nil
    let alternate = selected.flatMap(model.alternateSubtitle(for:))
    return HStack(spacing: 12) {
      Group {
        if let alternate {
          Text(alternate).foregroundStyle(.primary)
        } else {
          Text("按住 ⌘ ⌥ ⌃ 看更多动作").foregroundStyle(.tertiary)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .contentTransition(.opacity)
      .animation(.easeOut(duration: 0.12), value: alternate)
      Spacer(minLength: 8)
      if let selected {
        HStack(spacing: 6) {
          Text(Self.primaryAction(selected)).foregroundStyle(.primary)
          KeyCap("↩")
        }
      }
      Style.hairline.frame(width: 0.5, height: 16)
      Button("设置", systemImage: "gearshape", action: openSettings).help("设置（⌘,）")
      Toggle(isOn: pinned) { Image(systemName: hideOnUnfocus ? "pin" : "pin.fill") }
        .toggleStyle(.button)
        .help(hideOnUnfocus ? "固定面板：点外面不关闭" : "取消固定")
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 14)
    .frame(height: Self.barHeight)
    .overlay(alignment: .top) { Style.hairline.frame(height: 0.5) }
  }

  private var pinned: Binding<Bool> {
    Binding {
      !hideOnUnfocus
    } set: {
      hideOnUnfocus = !$0
    }
  }

  /// 底栏右侧的主动作（↩ 做什么）
  static func primaryAction(_ item: LauncherItem) -> String {
    switch item.kind {
    case .app, .path: "打开"
    case .action: "运行"
    case .url: "打开网址"
    case .search: "搜索"
    case .prompt: "补全关键词"
    case .calculation, .clip: "粘贴"
    }
  }
}

private struct LauncherRow: View {
  let item: LauncherItem
  let index: Int
  let showsShortcut: Bool
  let isSelected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      icon
      if item.kind == .calculation {
        Text(item.target)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
        if !item.subtitle.isEmpty {
          Text(item.subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      kind
    }
    .padding(.horizontal, 10)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private var icon: some View {
    if item.kind == .app || item.kind == .path, let image = LauncherIcons.icon(for: item.target) {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else {
      KindTile(symbol: tileSymbol, color: tileColor)
    }
  }

  /// 右侧：类型标签；按住 ⌘ 时依次换成 ⌘1–9 键帽（每行错开 15 ms）
  private var kind: some View {
    ZStack(alignment: .trailing) {
      Text(Self.kindTitle(item))
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

  private var tileSymbol: String {
    switch item.kind {
    case .calculation: "equal"
    case .search, .prompt: "magnifyingglass"
    default: item.symbol
    }
  }

  private var tileColor: Color {
    switch item.kind {
    case .action: item.target == "settings" ? Style.Family.general : Style.Family.command
    case .url: Style.Family.url
    case .search, .prompt: Style.Family.search
    case .calculation: Style.Family.keyboard
    case .clip: Style.Family.clipboard
    case .app, .path: Style.Family.general
    }
  }

  static func kindTitle(_ item: LauncherItem) -> String {
    switch item.kind {
    case .app: "应用"
    case .path: "文件"
    case .action: "命令"
    case .url: "网址"
    case .search, .prompt: "搜索"
    case .calculation: "计算"
    case .clip: "剪贴板"
    }
  }
}

/// App / 文件图标（按路径缓存，面板每次重绘不重复读）
enum LauncherIcons {
  private static let cache = NSCache<NSString, NSImage>()

  static func icon(for path: String) -> NSImage? {
    if let cached = cache.object(forKey: path as NSString) { return cached }
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: path)
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}
