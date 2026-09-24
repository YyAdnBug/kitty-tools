// 启动器根视图（Spotlight 式，不沿用旧版样式）：顶部大号搜索框 + 设置 / 图钉；下方结果列表
// （图标、标题、副标题、⌘数字键帽），空查询时是「最近使用」。面板高度随行数伸缩，顶边不动。
// 状态和操作都在 LauncherModel。

import AppKit
import SwiftUI

struct LauncherPanelView: View {
  @Bindable var model: LauncherModel
  var openSettings: () -> Void = {}
  @AppStorage(Prefs.launcherHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false

  static let searchHeight: CGFloat = 56
  static let rowHeight: CGFloat = 44
  /// 多出半行，让人看得出下面还能滚
  static let visibleRows = 8.5

  var body: some View {
    VStack(spacing: 0) {
      searchBar.frame(height: Self.searchHeight)
      if let error = model.error {
        Divider()
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          .padding(.horizontal, 16)
      }
      if showsNoResults {
        Divider()
        Text("没有匹配的结果")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
      } else if !model.results.isEmpty {
        Divider()
        list
      }
      Spacer(minLength: 0)
    }
    .onChange(of: height, initial: true) { model.resize(height) }
    // 按住 ⌘ / ⌥ / ⌃ 时选中行的副标题换成替代动作
    .onModifierKeysChanged(mask: [.command, .option, .control]) { _, keys in
      model.alternate =
        keys.contains(.command)
        ? .command : keys.contains(.option) ? .option : keys.contains(.control) ? .control : .none
    }
  }

  private var showsNoResults: Bool { !model.isShowingRecent && model.results.isEmpty }

  private var height: CGFloat {
    var height = Self.searchHeight
    if model.error != nil { height += 29 }
    if showsNoResults {
      height += Self.rowHeight + 1
    } else if !model.results.isEmpty {
      height += 1 + min(Double(model.results.count), Self.visibleRows) * Self.rowHeight + 8
    }
    return height
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.secondary)
      CommandTextField(
        text: $model.query, placeholder: "搜索 App、网址或文件", fontSize: 20, romanOnly: romanInput,
        onCommand: model.handleCommand)
      Button("设置", systemImage: "gearshape", action: openSettings).help("设置（⌘,）")
      Toggle(isOn: pinned) { Image(systemName: hideOnUnfocus ? "pin" : "pin.fill") }
        .toggleStyle(.button)
        .help(hideOnUnfocus ? "固定面板：点外面不关闭" : "取消固定")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .imageScale(.large)
    .padding(.horizontal, 16)
  }

  private var pinned: Binding<Bool> {
    Binding {
      !hideOnUnfocus
    } set: {
      hideOnUnfocus = !$0
    }
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            Button {
              model.click(item)
            } label: {
              LauncherRow(
                item: item, shortcutIndex: index < 9 ? index : nil,
                isSelected: index == model.selection, isRecent: model.isShowingRecent,
                alternateSubtitle: index == model.selection
                  ? model.alternateSubtitle(for: item) : nil)
            }
            .buttonStyle(.plain)
            .id(item.id)
          }
        }
        .padding(4)
      }
      .onChange(of: model.selection) { _, selection in
        if model.results.indices.contains(selection) { proxy.scrollTo(model.results[selection].id) }
      }
      // 新结果时选中项回到第 0 行，但 selection 本来就是 0 时上面不触发：列表也要回到顶部
      .onChange(of: model.results) {
        if let first = model.results.first { proxy.scrollTo(first.id, anchor: .top) }
      }
    }
  }
}

private struct LauncherRow: View {
  let item: LauncherItem
  let shortcutIndex: Int?
  let isSelected: Bool
  let isRecent: Bool
  /// 按住修饰键时的替代动作说明（只给选中行）
  var alternateSubtitle: String?

  var body: some View {
    HStack(spacing: 10) {
      icon.frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 14))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(alternateSubtitle ?? (isRecent ? "最近使用 · \(item.subtitle)" : item.subtitle))
          .font(.system(size: 11))
          .foregroundStyle(
            isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
          )
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 6)
      if let shortcutIndex { KeyCap("⌘\(shortcutIndex + 1)", inverted: isSelected) }
    }
    .foregroundStyle(isSelected ? .white : .primary)
    .padding(.horizontal, 10)
    .frame(height: LauncherPanelView.rowHeight)
    .background(
      isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
      in: .rect(cornerRadius: 8)
    )
    .contentShape(.rect)
  }

  @ViewBuilder private var icon: some View {
    if item.kind == .app || item.kind == .path, let image = LauncherIcons.icon(for: item.target) {
      Image(nsImage: image).resizable()
    } else {
      Image(systemName: item.symbol)
        .font(.system(size: 17))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
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
