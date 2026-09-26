// 面板里的动作菜单（mac-whisker §6）：剪贴板 ⌘K、剪贴板 Tab 筛选面板、启动器 ⌘K 共用。画在面板里而不是 NSMenu，
// 焦点一直留在搜索框：搜索框里的字由调用方拿来过滤 items，↑↓ 改 selection，↩ / 单击执行。这里只画，不存状态。
// 宽 260、行高 28、中性高亮（不填强调色、不反白）；出现时 snap 从 anchor 0.92→1 放大 + 淡入，消失淡出 fadeOut。

import SwiftUI

struct ActionMenu: View {
  /// 一行：[✓] [图标] 标题 ⋯ 说明 快捷键
  struct Item: Identifiable {
    /// 同一个菜单里不能重复（默认取标题；标题可能撞，比如同名的来源 App 和分组，就自己给）
    var id: String
    var title: String
    /// SF Symbol 名；和 image 都没有时留空位对齐
    var symbol: String?
    /// 比 symbol 优先，16 × 16（来源 App 图标之类）
    var image: NSImage?
    /// 靠右的 tertiary 小字（「来源 42」「分组」）
    var detail: String?
    /// 行尾的键位提示（「⌘↩」）
    var shortcut: String?
    /// nil = 不能勾选；菜单里有一项不是 nil，每行前面就留 12 pt 勾选列，true 画品牌粉 ✓
    var isChecked: Bool?
    var run: () -> Void

    init(
      title: String, symbol: String? = nil, image: NSImage? = nil, detail: String? = nil,
      shortcut: String? = nil, isChecked: Bool? = nil, id: String? = nil,
      run: @escaping () -> Void
    ) {
      self.id = id ?? title
      self.title = title
      self.symbol = symbol
      self.image = image
      self.detail = detail
      self.shortcut = shortcut
      self.isChecked = isChecked
      self.run = run
    }
  }

  let items: [Item]
  /// 当前选中行在 items 里的下标（越界就是没选中）
  let selection: Int
  var emptyText = "没有匹配的操作"
  /// 放大的锚点：菜单从哪个角长出来（⌘K 右下、筛选面板左上）
  var anchor: UnitPoint = .bottomTrailing
  /// 超过这么多行就在菜单里滚动（给半行，露出下面还有），选中行自动滚进来
  var maxRows: CGFloat = .infinity
  /// 单击一行；执行前关菜单由调用方做
  let onRun: (Item) -> Void

  static let width: CGFloat = 260
  static let rowHeight: CGFloat = 28

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let checkable = items.contains { $0.isChecked != nil }
    let hasIcons = items.contains { $0.symbol != nil || $0.image != nil }
    let rows = CGFloat(max(items.count, 1))
    let appear: AnyTransition =
      reduceMotion ? .opacity : .scale(scale: 0.92, anchor: anchor).combined(with: .opacity)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if items.isEmpty {
            Text(emptyText)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
          }
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            row(item, isSelected: index == selection, checkable: checkable, hasIcons: hasIcons)
              .id(item.id)
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(rows, maxRows) * Self.rowHeight)
      .onChange(of: selection) { _, index in
        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
      }
    }
    .padding(5)
    .frame(width: Self.width)
    .background(.regularMaterial, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous).strokeBorder(
        Style.hairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    // 转场绑在这里：调用方只要 if 显示 + 用动画改那个开关（出现 snap，减弱动态效果时只淡入）
    .transition(
      .asymmetric(
        insertion: appear.animation(
          Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn)),
        removal: .opacity.animation(.easeIn(duration: Style.fadeOut))))
  }

  private func row(_ item: Item, isSelected: Bool, checkable: Bool, hasIcons: Bool) -> some View {
    Button {
      onRun(item)
    } label: {
      HStack(spacing: 8) {
        if checkable {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Style.brandInk)
            .frame(width: 12)
            .opacity(item.isChecked == true ? 1 : 0)
        }
        if let image = item.image {
          Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else if let symbol = item.symbol {
          Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
        } else if hasIcons {
          Color.clear.frame(width: 16, height: 1)
        }
        Text(item.title).lineLimit(1)
        Spacer(minLength: 8)
        if let detail = item.detail {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        if let shortcut = item.shortcut {
          Text(shortcut)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 13))
      .padding(.horizontal, 8)
      .frame(height: Self.rowHeight)
      // 和列表一样是中性高亮（面板内缩 5，圆角 10 − 5 同心 ≈ control）
      .background(
        isSelected ? Style.selectedFill : .clear,
        in: .rect(cornerRadius: Style.Radius.control, style: .continuous)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(item.isChecked == true ? .isSelected : [])
  }
}
