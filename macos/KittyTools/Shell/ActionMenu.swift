// 面板里的动作菜单（mac-whisker §6）：剪贴板 ⌘K、剪贴板 Tab 筛选面板、剪贴板多选底栏「收藏夹…」、启动器 ⌘K、
// 翻译历史 ⌘K 共用；同一份条目当右键菜单用见 ActionContextMenu。
// 画在面板里而不是 NSMenu，焦点一直留在搜索框：搜索框里的字由调用方拿来过滤 items（共用 filter：标题 / 说明子串，
// 中文标题的全拼和首字母前缀），↑↓ 改 selection，↩ / 单击执行。这里只画，不存状态。
// 宽 260、行高 28、中性高亮（不填强调色、不反白）；section 变了的两行之间一条 0.5 pt 发丝线（上下各 4 pt）；
// 行多了在菜单里滚：滚动区铺满菜单宽、行的左右内缩 5 在滚动区里面，滚动条贴菜单右边（2026-10-03 用户要求「在最外层」）；
// 带子列表的行尾是 ›（一级子列表，进去后顶上一行「‹ 标题」点一下回上一级）。出现时 snap 从 anchor 0.92→1 放大 + 淡入，消失淡出 fadeOut。

import SwiftUI

struct ActionMenu: View {
  /// 一行：[✓] [图标] 标题 ⋯ 说明 快捷键 / ›
  struct Item: Identifiable {
    /// 同一个菜单里不能重复（默认取标题；标题可能撞，比如同名的来源 App 和收藏夹，就自己给）
    var id: String
    var title: String
    /// SF Symbol 名；和 image 都没有时留空位对齐
    var symbol: String?
    /// 比 symbol 优先，16 × 16（来源 App 图标之类）
    var image: NSImage?
    /// 靠右的 tertiary 小字（「来源 42」「收藏夹」）
    var detail: String?
    /// 行尾的键位提示（「⌘↩」）；右键菜单里不显示（HIG）
    var shortcut: String?
    /// nil = 不能勾选；菜单里有一项不是 nil，每行前面就留 12 pt 勾选列，true 画品牌粉 ✓
    var isChecked: Bool?
    /// 分节：和上一行不同时中间画一条发丝线（右键菜单里是分隔线）
    var section = 0
    /// 一级子列表（「移到收藏夹 ›」）：执行 = 进去，run 不用
    var submenu: [Item]?
    /// 删除这类：右键菜单里是 .destructive 的按钮
    var isDestructive = false
    var run: () -> Void

    init(
      title: String, symbol: String? = nil, image: NSImage? = nil, detail: String? = nil,
      shortcut: String? = nil, isChecked: Bool? = nil, id: String? = nil, section: Int = 0,
      submenu: [Item]? = nil, isDestructive: Bool = false, run: @escaping () -> Void = {}
    ) {
      self.id = id ?? title
      self.title = title
      self.symbol = symbol
      self.image = image
      self.detail = detail
      self.shortcut = shortcut
      self.isChecked = isChecked
      self.section = section
      self.submenu = submenu
      self.isDestructive = isDestructive
      self.run = run
    }
  }

  let items: [Item]
  /// 当前选中行在 items 里的下标（越界就是没选中）
  let selection: Int
  var emptyText = "没有匹配的操作"
  /// 在子列表里：顶上一行「‹ 标题」，点一下回上一级（onBack）
  var header: String?
  var onBack: () -> Void = {}
  /// 放大的锚点：菜单从哪个角长出来（⌘K 右下、筛选面板左上）
  var anchor: UnitPoint = .bottomTrailing
  /// 超过这么多行高就在菜单里滚动（给半行，露出下面还有），选中行自动滚进来
  var maxRows: CGFloat = .infinity
  /// 单击一行；执行前关菜单（或进子列表）由调用方做
  let onRun: (Item) -> Void

  static let width: CGFloat = 260
  static let rowHeight: CGFloat = 28
  /// 分节线上下各留的空
  static let sectionGap: CGFloat = 4

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let checkable = items.contains { $0.isChecked != nil }
    let hasIcons = items.contains { $0.symbol != nil || $0.image != nil }
    let appear: AnyTransition =
      reduceMotion ? .opacity : .scale(scale: 0.92, anchor: anchor).combined(with: .opacity)
    VStack(spacing: 0) {
      if let header {
        headerRow(header).padding(.horizontal, 5)
        separator.padding(.horizontal, 5)
      }
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
              // 分节线和它下面那一行包成一个视图：分开放时 scrollTo 按这个 id 先找到的是打头的分节线，
              // ↓ 选到一节的第一行只把线滚出来、行还在菜单外面（2026-10-07 用户报：⌘K 里选到「删除」却看不到）。
              // 包起来后整行露出来；↑ 选到它时上面的分节线照旧一起露出来
              VStack(spacing: 0) {
                if index > 0, items[index - 1].section != item.section { separator }
                row(item, isSelected: index == selection, checkable: checkable, hasIcons: hasIcons)
              }
              .id(item.id)
            }
          }
          // 左右内缩放在滚动区里面：滚动条贴着菜单右边，不压在行上。上下的内缩留在外面：
          // 放进来的话 ↑↓ 选到头尾时滚动只露出那一行，内缩被滚出去、行贴着菜单边
          .padding(.horizontal, 5)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
          height: Self.height(items, maxRows: maxRows, header: header != nil, contrast: contrast)
        )
        .onChange(of: selection) { _, index in
          if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
        }
      }
    }
    .padding(.vertical, 5)
    .frame(width: Self.width)
    .background(.regularMaterial, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous).hairlineBorder()
    )
    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    // 转场绑在这里：调用方只要 if 显示 + 用动画改那个开关（出现 snap，减弱动态效果时只淡入）
    .transition(
      .asymmetric(
        insertion: appear.animation(
          Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn)),
        removal: .opacity.animation(.easeIn(duration: Style.fadeOut))))
  }

  /// 滚动区的高：行和分节线的总高（空菜单一行）；超过 maxRows 个行高时截在某一行的一半，露出下面还有
  /// （分节线也占高，直接按 maxRows × 行高截可能正好截在行缝上，看不出能滚）。截出来的高不超过 maxRows 个行高：
  /// 放不下的那行半行也超了，就截在上一行的一半。子列表顶上「‹ 标题」和它下面的分节线（≤ 37）也算在里面，
  /// 滚动区少给 1.5 行（42），整个菜单不比第一级高，调用方按 maxRows 留的地方够用
  static func height(
    _ items: [Item], maxRows: CGFloat = .infinity, header: Bool = false,
    contrast: ColorSchemeContrast = .standard
  ) -> CGFloat {
    let limit = (header ? maxRows - 1.5 : maxRows) * rowHeight
    let line = Style.hairlineWidth(contrast) + sectionGap * 2
    var y: CGFloat = 0
    var previousTop: CGFloat = 0
    for (index, item) in items.enumerated() {
      if index > 0, items[index - 1].section != item.section { y += line }
      if y + rowHeight > limit {
        return y + rowHeight / 2 <= limit ? y + rowHeight / 2 : previousTop + rowHeight / 2
      }
      previousTop = y
      y += rowHeight
    }
    return max(y, rowHeight)
  }

  private var separator: some View {
    Hairline().padding(.horizontal, 8).padding(.vertical, Self.sectionGap)
  }

  /// 子列表顶上的「‹ 标题」：点一下回上一级（← / Esc 同样）
  private func headerRow(_ title: String) -> some View {
    Button(action: onBack) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .frame(height: Self.rowHeight)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("返回上一级：\(title)")
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
        if item.submenu != nil {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        } else if let shortcut = item.shortcut {
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
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
            .contrastSelectionBorder()
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(item.isChecked == true ? .isSelected : [])
    .accessibilityHint(item.submenu != nil ? "打开子列表" : "")
  }

  // MARK: 过滤（体检 C4）

  /// 三个菜单共用的过滤：标题 / 说明按 LauncherMatch.fold 做子串（不分大小写、全半角、变音符号；输「来源」列出全部来源），
  /// 中文标题另认全拼和首字母的前缀（fy → 翻译、zfd → 在访达中显示，启动器开着「只用英文输入法」时也找得到）。
  /// 结果保持原顺序，菜单项位置不乱跳
  static func filter(_ items: [Item], query: String) -> [Item] {
    let folded = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    guard !folded.isEmpty else { return items }
    let latin = folded.filter { !$0.isWhitespace }
    return items.filter { item in
      if LauncherMatch.fold(item.title).contains(folded) { return true }
      if let detail = item.detail, LauncherMatch.fold(detail).contains(folded) { return true }
      guard let pinyin = pinyin(of: item.title) else { return false }
      return pinyin.full.hasPrefix(latin) || pinyin.initials.hasPrefix(latin)
    }
  }

  /// 标题的拼音（按标题缓存：菜单每次打字都过滤一遍，转写不便宜）。ponytail: 只增不减，菜单标题就那么些
  private static var pinyinCache: [String: (full: String, initials: String)?] = [:]

  private static func pinyin(of title: String) -> (full: String, initials: String)? {
    if let cached = pinyinCache[title] { return cached }
    let value = AppCatalog.pinyin(title)
    pinyinCache[title] = value
    return value
  }
}

/// 同一份动作条目画成右键菜单（剪贴板行、翻译历史行）：section 变了加分隔线、子列表是子菜单、删除类 destructive，
/// 不写键位（HIG）
struct ActionContextMenu: View {
  /// 闭包：动作表在菜单内容真要画时才建
  let items: () -> [ActionMenu.Item]

  var body: some View {
    let items = items()
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      if index > 0, items[index - 1].section != item.section { Divider() }
      if let submenu = item.submenu {
        Menu(item.title) { ActionContextMenu { submenu } }
      } else if let checked = item.isChecked {
        Toggle(item.title, isOn: Binding(get: { checked }, set: { _ in item.run() }))
      } else {
        Button(item.title, role: item.isDestructive ? .destructive : nil, action: item.run)
      }
    }
  }
}
