// App 快捷键的面板内容（拍板 C1–C3、D1–D3，mac-whisker/app-shortcuts.md）：Panel 皮肤（OverlayPanel），顶上一行 App 图标、
// 名字、多少个快捷键，右边一个搜索框；下面一个顶层菜单一张卡（.cardSurface()），卡片按菜单顺序一列列往下排，列底放不下的卡
// 拆到下一列接着排（标题写「续」），放得下几列就几列，一屏放不下整块竖着滚。每行：子菜单的路径灰字 + 标题（一行截断），
// 右边 Whisker 键帽（KeyCombo；两段式的两组）。灰着的不画灰（AXEnabled 靠不住，MenuShortcuts 文件头）。
// 点一行 = 执行它（AppShortcuts.perform）。按着 ⌘ 弹出时面板不拿键盘；点一下面板（多半是点搜索框）就「留住」：拿到键盘，
// 打字就搜（菜单标题、子菜单、菜单名，中文也认拼音全拼和首字母）、↑↓ 换选中、↩ 执行、Esc 先清空再收起；面板大小不跟着变。
// 读不到、一条都没有、没读完、搜不到各有一句话（拍板 E1）。
// 排版（AppShortcutsLayout）是纯函数，配单测：列宽、行高定死，卡片高度按条数算，不量 SwiftUI。

import AppKit
import Carbon.HIToolbox
import SwiftUI

@Observable final class AppShortcutsModel {
  /// 一个顶层菜单的一组
  struct Group: Identifiable, Equatable {
    /// 菜单栏里第几个（两个同名的菜单也分得开）
    let id: Int
    let title: String
    let items: [MenuShortcut]
  }

  var appName = ""
  var icon: NSImage?
  /// 读到的全部
  var groups: [Group] = []
  /// 看得见的：没搜时就是 groups，搜时是对上的
  private(set) var visible: [Group] = []
  var finished = true
  var unreadable = false
  var layout = AppShortcutsLayout.make(rows: [], available: NSSize(width: 1440, height: 900))
  /// 留住了（点了面板、用快捷键打开的）：拿着键盘，能搜、↑↓、↩
  var isStaying = false
  /// 用快捷键打开的（不是按住修饰键弹的）：没响应时的提示不说「再按住 ⌘」
  var openedByKey = false
  /// 按住的是哪个键（「再按住 ⌥ 试试」）
  var holdSymbol = ModifierTaps.Key.command.symbol
  private(set) var query = ""
  /// 选中的那一行（MenuShortcut.id）；没搜、也没按过 ↑↓ 时没有
  var selection: [Int]?
  /// 执行一行（点、↩、按它的组合）
  @ObservationIgnored var onPerform: ((MenuShortcut) -> Void)?
  /// 打开时的排版：搜索时面板大小、列数照它，不跟着结果变
  @ObservationIgnored private var opened = AppShortcutsLayout.make(
    rows: [], available: NSSize(width: 1440, height: 900))
  /// 每一行搜索用的字（折叠过的标题、子菜单、菜单名、拼音）：第一次搜时才算
  @ObservationIgnored private var searchKeys: [[Int]: SearchKey] = [:]

  var count: Int { groups.reduce(0) { $0 + $1.items.count } }

  /// 看得见的各行，按排的先后（↑↓ 走这个顺序）
  var flat: [MenuShortcut] { visible.flatMap(\.items) }

  /// 换上新读的（available：鼠标所在屏的可见区大小）
  func load(_ reading: MenuReading, name: String, icon: NSImage?, available: NSSize) {
    appName = name
    self.icon = icon
    groups = Self.groups(reading.shortcuts)
    visible = groups
    finished = reading.finished
    unreadable = reading.unreadable
    layout = AppShortcutsLayout.make(rows: groups.map(\.items.count), available: available)
    opened = layout
    isStaying = false
    query = ""
    selection = nil
    searchKeys = [:]
  }

  /// 搜索框改了：重新筛、排进打开时那么大的面板里，选中第一条对上的
  func search(_ text: String) {
    query = text
    visible = Self.filter(groups, query: text) { item in
      if let key = searchKeys[item.id] { return key }
      let key = SearchKey(item)
      searchKeys[item.id] = key
      return key
    }
    layout =
      text.isEmpty
      ? opened
      : AppShortcutsLayout.fitting(
        rows: visible.map(\.items.count), columns: opened.columns.count, size: opened.size)
    selection = text.isEmpty ? nil : visible.first?.items.first?.id
  }

  /// ↑↓：在看得见的各行里挪（没选中时从第一行起）
  func move(_ step: Int) {
    let rows = flat
    guard !rows.isEmpty else { return }
    let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
    let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? 0
    selection = rows[next].id
  }

  /// 搜索框的按键（CommandTextField）：↑↓ 换选中、↩ 执行、Esc 先清空搜索（清空了再按交给面板收起）
  func command(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(-1)
    case #selector(NSResponder.moveDown(_:)): move(1)
    case #selector(NSResponder.insertNewline(_:)):
      if let id = selection, let item = flat.first(where: { $0.id == id }) {
        onPerform?(item)
      } else {
        NSSound.beep()
      }
    case #selector(NSResponder.cancelOperation(_:)):
      guard !query.isEmpty else { return false }
      search("")
    default: return false
    }
    return true
  }

  /// 留住时按了一个组合：列表里有这个组合的那一项（先看得见的、再全部），没有 nil
  func item(forKeys keys: String) -> MenuShortcut? {
    flat.first { $0.keys == keys } ?? groups.lazy.flatMap(\.items).first { $0.keys == keys }
  }

  /// 按顶层菜单分组，保持菜单里的先后（纯函数）
  static func groups(_ shortcuts: [MenuShortcut]) -> [Group] {
    var result: [Group] = []
    for shortcut in shortcuts {
      let bar = shortcut.location.first ?? 0
      if let last = result.last, last.id == bar {
        result[result.count - 1] = Group(id: bar, title: last.title, items: last.items + [shortcut])
      } else {
        result.append(Group(id: bar, title: shortcut.menu, items: [shortcut]))
      }
    }
    return result
  }

  /// 一行搜索用的字：折叠过的标题、子菜单、菜单名（含拼音全拼）和首字母缩写（标题的、拼音的）
  struct SearchKey {
    let names: [String]
    let initials: [String]

    init(_ item: MenuShortcut) {
      let texts = [item.title, item.menu] + item.path
      let pinyins = texts.compactMap(AppCatalog.pinyin)
      names = (texts + pinyins.map(\.full)).map(LauncherMatch.fold)
      initials = [LauncherMatch.initials(item.title)] + pinyins.map(\.initials)
    }
  }

  /// 搜索（纯函数）：按空白分词，每个词都是某个名字的子串，或者（≥ 2 个字时）某个首字母缩写的开头（同启动器的粗筛）；
  /// 没有对上的行的组整组去掉
  static func filter(_ groups: [Group], query: String, key: (MenuShortcut) -> SearchKey) -> [Group]
  {
    let tokens = LauncherMatch.tokens(query)
    guard !tokens.isEmpty else { return groups }
    return groups.compactMap { group in
      let items = group.items.filter { item in
        let key = key(item)
        return tokens.allSatisfy { token in
          key.names.contains { $0.contains(token) }
            || (token.count >= 2 && key.initials.contains { $0.hasPrefix(token) })
        }
      }
      return items.isEmpty ? nil : Group(id: group.id, title: group.title, items: items)
    }
  }

  /// 留住时按的组合可能对得上的写法：键码那种（keys）之外，带 ⇧ 才打得出的标点再试「去掉 ⇧、用打出来的字」——菜单里
  /// 「⌘?」报的是 ? 这个字、不带 ⇧ 位，按键却是 ⇧⌘/
  static func candidates(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?)
    -> [String]
  {
    let plain = keys(keyCode: keyCode, flags: flags)
    guard flags.contains(.shift), let typed = characters, typed.count == 1,
      let name = MenuShortcuts.name(of: typed)
    else { return [plain] }
    var modifiers = ""
    if flags.contains(.control) { modifiers += "⌃" }
    if flags.contains(.option) { modifiers += "⌥" }
    if flags.contains(.command) { modifiers += "⌘" }
    let shifted = modifiers + name
    return shifted == plain ? [plain] : [plain, shifted]
  }

  /// 按键 → 和读出来的快捷键同一种写法（「⌘S」「🌐⌃F」）：修饰键和键名照 HotKey.display（当前键盘布局），🌐 另加在前面——
  /// 方向键、F 键这些本身就带着 fn 位的不算
  static func keys(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
    let intrinsic =
      HotKey.functionKeys[Int(keyCode)] != nil
      || [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp,
        kVK_PageDown, kVK_ForwardDelete, kVK_Help,
      ].contains(Int(keyCode))
    let globe = flags.contains(.function) && !intrinsic ? "🌐" : ""
    return globe + HotKey(keyCode: keyCode, flags: flags).display
  }
}

/// 面板的尺寸和卡片怎么分列（纯函数，单测）
struct AppShortcutsLayout: Equatable {
  /// 一列里的一段：哪一组的哪几行；continued = 接着上一列那一段往下（卡片标题写「续」）
  struct Segment: Hashable {
    let group: Int
    let rows: Range<Int>
    var continued: Bool { rows.lowerBound > 0 }
  }

  static let columnWidth: CGFloat = 248
  static let gap: CGFloat = 10
  static let padding: CGFloat = 14
  /// 顶上那一行连同它下面的间距
  static let header: CGFloat = 40
  static let rowHeight: CGFloat = 22
  /// 卡片除了行以外的高：组名 18 + 上下内边距各 8
  static let cardChrome: CGFloat = 34
  /// 一张卡拆到下一列时，前一段至少留几行（不在列底留一个标题加一两行）
  static let minSplit = 3
  /// 一条都没有 / 读不到时的大小
  static let emptySize = NSSize(width: 380, height: 210)
  /// 面板最窄多宽：只排一列时顶上那一行（图标、名字、条数、搜索框）也放得下（2026-11-17 评审）
  static let minWidth: CGFloat = 440

  let columns: [[Segment]]
  /// 最高那一列的高
  let contentHeight: CGFloat
  let size: NSSize

  /// 放不下、要竖着滚
  var scrolls: Bool { contentHeight > size.height - Self.header - Self.padding * 2 + 0.5 }

  /// 画的时候每列多宽：面板比各列加起来宽（只有一两列、被最窄宽度撑开，或搜索后列少了）时把列放宽铺开，最多 2 倍
  /// （行高定死，放宽不影响排版）
  var columnWidth: CGFloat {
    guard !columns.isEmpty else { return Self.columnWidth }
    let count = CGFloat(columns.count)
    let room = (size.width - Self.padding * 2 - (count - 1) * Self.gap) / count
    return min(max(Self.columnWidth, room), Self.columnWidth * 2)
  }

  static func cardHeight(rows: Int) -> CGFloat { cardChrome + CGFloat(rows) * rowHeight }

  /// rows：各组几条；available：屏幕可见区。最宽占 90%、最高 80%（拍板 C1）；列数取放得下的最少列，都放不下就最多列、竖着滚
  static func make(rows: [Int], available: NSSize) -> AppShortcutsLayout {
    guard !rows.isEmpty else {
      return AppShortcutsLayout(columns: [], contentHeight: 0, size: emptySize)
    }
    let maxColumns = max(
      1, Int((available.width * 0.9 - padding * 2 + gap) / (columnWidth + gap)))
    let maxBody = max(cardHeight(rows: minSplit * 2), available.height * 0.8 - header - padding * 2)
    var best = flow(rows, into: maxColumns)
    for count in 1..<maxColumns {
      let tried = flow(rows, into: count)
      if tried.height <= maxBody {
        best = tried
        break
      }
    }
    let count = best.columns.count
    let width = max(minWidth, padding * 2 + CGFloat(count) * columnWidth + CGFloat(count - 1) * gap)
    let height = padding * 2 + header + min(best.height, maxBody)
    return AppShortcutsLayout(
      columns: best.columns, contentHeight: best.height, size: NSSize(width: width, height: height))
  }

  /// 搜索时：大小、最多几列照打开时的，对上的那些重新排进去（面板不跟着结果变大变小）
  static func fitting(rows: [Int], columns: Int, size: NSSize) -> AppShortcutsLayout {
    guard !rows.isEmpty else {
      return AppShortcutsLayout(columns: [], contentHeight: 0, size: size)
    }
    let flowed = flow(rows, into: max(columns, 1))
    return AppShortcutsLayout(columns: flowed.columns, contentHeight: flowed.height, size: size)
  }

  /// 按先后一列列往下排，排进最多 count 列里最矮的样子（二分找每列的上限）。一组在列底放不下时，前面至少能放
  /// minSplit 行就拆到下一列接着排，不然整组挪到下一列
  static func flow(_ rows: [Int], into count: Int) -> (columns: [[Segment]], height: CGFloat) {
    func fill(limit: CGFloat) -> [[Segment]] {
      var columns: [[Segment]] = [[]]
      var used: CGFloat = 0
      for (group, total) in rows.enumerated() {
        var start = 0
        while start < total {
          let fresh = columns[columns.count - 1].isEmpty
          let room = limit - (fresh ? 0 : used + gap) - cardChrome
          let fits = max(0, Int((room + 0.001) / rowHeight))
          let left = total - start
          let take: Int
          if fits >= left {
            take = left
          } else if fits >= minSplit || (fresh && fits >= 1) {
            take = fits
          } else if fresh {
            take = left  // 上限比一张卡还矮：只能整张放
          } else {
            columns.append([])
            used = 0
            continue
          }
          columns[columns.count - 1].append(Segment(group: group, rows: start..<start + take))
          used += (fresh ? 0 : gap) + cardHeight(rows: take)
          start += take
          if start < total {
            columns.append([])
            used = 0
          }
        }
      }
      return columns.filter { !$0.isEmpty }
    }
    func height(_ columns: [[Segment]]) -> CGFloat {
      columns.map { column in
        column.map { cardHeight(rows: $0.rows.count) }.reduce(0, +)
          + CGFloat(max(column.count - 1, 0)) * gap
      }.max() ?? 0
    }
    var low = cardHeight(rows: minSplit)
    var high = rows.map(cardHeight).reduce(0, +) + CGFloat(rows.count) * gap
    for _ in 0..<24 where high - low > 0.5 {
      let middle = (low + high) / 2
      if fill(limit: middle).count <= count { high = middle } else { low = middle }
    }
    let columns = fill(limit: high)
    return (columns, height(columns))
  }
}

struct AppShortcutsView: View {
  @Bindable var model: AppShortcutsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .frame(height: AppShortcutsLayout.header, alignment: .top)
      if model.groups.isEmpty {
        empty.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.visible.isEmpty {
        EmptyState(symbol: "magnifyingglass", title: "没有对上的快捷键") {
          Text("换个词试试；Esc 清空").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            HStack(alignment: .top, spacing: AppShortcutsLayout.gap) {
              let width = model.layout.columnWidth
              ForEach(model.layout.columns, id: \.self) { column in
                VStack(spacing: AppShortcutsLayout.gap) {
                  ForEach(column, id: \.self) { segment in
                    if model.visible.indices.contains(segment.group) {
                      GroupCard(
                        group: model.visible[segment.group], segment: segment, model: model)
                    }
                  }
                }
                .frame(width: width)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .scrollDisabled(!model.layout.scrolls)
          .scrollIndicators(model.layout.scrolls ? .automatic : .never)
          // 键盘换选中时跟着滚到它（同启动器：连发、结果刷新不做动画）
          .onChange(of: model.selection) { _, id in
            guard let id, model.layout.scrolls else { return }
            proxy.scrollTo(id)
          }
        }
      }
    }
    .padding(AppShortcutsLayout.padding)
  }

  private var header: some View {
    HStack(spacing: 8) {
      if let icon = model.icon {
        Image(nsImage: icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
      }
      Text(model.appName)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
      if !model.groups.isEmpty {
        Text("\(model.count) 个快捷键").font(.system(size: 13)).foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      if !model.finished, !model.groups.isEmpty {
        Text("没读完：这个 App 没响应")
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: .systemOrange))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if !model.groups.isEmpty { searchField }
    }
    .frame(height: 24)
  }

  /// 搜索框：按着 ⌘ 弹出时没焦点、占位写「点这里搜索」（点它就留住，AppShortcuts.stay）；留住后拿着焦点
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      CommandTextField(
        text: Binding {
          model.query
        } set: {
          model.search($0)
        },
        placeholder: model.isStaying
          ? String(localized: "搜索快捷键") : String(localized: "点这里搜索"), fontSize: 13,
        onCommand: model.command)
    }
    .padding(.horizontal, 8)
    .frame(minWidth: 120, maxWidth: 200, minHeight: 24, maxHeight: 24)
    .background(Style.inputFill, in: .rect(cornerRadius: Style.Radius.control, style: .continuous))
  }

  @ViewBuilder private var empty: some View {
    if !model.finished {
      EmptyState(symbol: "hourglass", title: "这个 App 没响应") {
        (model.openedByKey ? Text("过一会儿再试试") : Text("过一会儿再按住 \(model.holdSymbol) 试试"))
          .foregroundStyle(.secondary)
      }
    } else if model.unreadable {
      EmptyState(symbol: "menubar.rectangle", title: "读不到这个 App 的菜单") {
        Text("有的 App 没有菜单栏").foregroundStyle(.secondary)
      }
    } else {
      EmptyState(symbol: "keyboard", title: "这个 App 的菜单里没有快捷键") {
        Text("有的 App 只在窗口里响应快捷键，菜单里看不到").foregroundStyle(.secondary)
      }
    }
  }
}

/// 一个顶层菜单一张卡（拆到下一列的那一段标题写「续」）
private struct GroupCard: View {
  let group: AppShortcutsModel.Group
  let segment: AppShortcutsLayout.Segment
  let model: AppShortcutsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 菜单名是那个 App 的，原样显示；「续」跟着界面语言
      (segment.continued ? Text("\(group.title)（续）") : Text(verbatim: group.title))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: 18, alignment: .top)
        .accessibilityAddTraits(.isHeader)
      ForEach(group.items[segment.rows.clamped(to: group.items.indices)]) { item in
        ShortcutRow(item: item, isSelected: model.selection == item.id) {
          model.onPerform?(item)
        }
        .id(item.id)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
  }
}

/// 一行：路径灰字 + 标题，右边键帽；点它执行。悬停 / 选中是一块中性灰底（mac-whisker §3 状态），左右各探出 4 pt
private struct ShortcutRow: View {
  let item: MenuShortcut
  let isSelected: Bool
  let perform: () -> Void
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      // 放不下时先截子菜单的路径，标题留着
      HStack(spacing: 0) {
        if !item.path.isEmpty {
          Text(item.path.joined(separator: " › ") + " › ")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Text(item.title)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
      }
      .font(.system(size: 13))
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        // 两段式的两组可能一样（⌘K ⌘K），按位置认
        let parts = item.keys.split(separator: " ").map(String.init)
        ForEach(parts.indices, id: \.self) { KeyCombo(parts[$0]) }
      }
      .fixedSize()
    }
    .frame(height: AppShortcutsLayout.rowHeight)
    .background {
      let shape = RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous)
      ZStack {
        if isSelected {
          shape.fill(Style.selectedFill).overlay(shape.contrastSelectionBorder())
        } else if hovered {
          shape.fill(Style.hoverFill)
        }
        HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } }
      }
      .padding(.horizontal, -4)
    }
    .contentShape(.rect)
    .onTapGesture(perform: perform)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { perform() }
  }
}
