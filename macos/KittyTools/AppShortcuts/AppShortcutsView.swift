// App 快捷键的面板内容（拍板 C1–C3、D1–D3，mac-whisker/app-shortcuts.md；2026-11-20 改版拍板 A1–G1「全部按推荐」）：
// Panel 皮肤（OverlayPanel），顶上一行 App 图标、名字、多少个快捷键，右边一个搜索框；下面不画卡片，像系统菜单那样
// 连续分栏：组名一行小标题，组可以接到下一栏（栏顶写「续」），各栏差不多一样高、栏间一根发丝线；子菜单在组里起一行
// 小标题，下面几行缩进、带一根引导线。每行：标题（一行截断，末尾的「…」照菜单画回来），右边一串符号的快捷键（修饰键
// 次要色、主键主色，主键对成一列；🌐 🎤 是系统符号；两段式的两段）。灰着的不画灰（AXEnabled 靠不住，MenuShortcuts 文件头）。
// 点一行 = 执行它（AppShortcuts.perform）。按着 ⌘ 弹出时面板不拿键盘；点一下面板（多半是点搜索框）就「留住」：拿到键盘，
// 打字就搜（菜单标题、子菜单、菜单名，中文也认拼音全拼和首字母）、↑↓ 换选中、↩ 执行、Esc 先清空再收起；面板大小不跟着变。
// 读不到、一条都没有、没读完、搜不到各有一句话（拍板 E1）。
// 排版（AppShortcutsLayout）是纯函数，配单测：行高定死，栏宽按这个 App 最长的一行量（AppKit 的字体尺寸，不量 SwiftUI）。

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
  var layout = AppShortcutsLayout.make(
    groups: [], base: AppShortcutsLayout.minColumnWidth, available: NSSize(width: 1440, height: 900)
  )
  /// 留住了（点了面板、用快捷键打开的）：拿着键盘，能搜、↑↓、↩
  var isStaying = false
  /// 用快捷键打开的（不是按住修饰键弹的）：没响应时的提示不说「再按住 ⌘」
  var openedByKey = false
  /// 按住的是哪个键（「再按住 ⌥ 试试」）
  var holdSymbol = ModifierTaps.Key.command.symbol
  /// 按着那个键时又按住的修饰键（⇧ ⌥ ⌃ ⌘ 🌐 的符号）：只亮带着它们的行（拍板 F2）；空的时候都亮
  var heldModifiers: Set<String> = []
  /// 系统的「移动与调整大小」点开了（拍板 C2）
  private(set) var expanded = false
  /// 第几次弹出来：各栏依次浮现跟着它重来一遍（拍板 F1）
  private(set) var presentation = 0
  /// 刚弹出来、还没搜索或点开过：只有这时新出来的栏依次浮现（清空搜索后栏数变回来，那几栏直接出现）
  private(set) var entering = false
  private(set) var query = ""
  /// 选中的那一行（MenuShortcut.id）；没搜、也没按过 ↑↓ 时没有
  var selection: [Int]?
  /// 执行一行（点、↩、按它的组合）
  @ObservationIgnored var onPerform: ((MenuShortcut) -> Void)?
  /// 面板该换个大小（点开「移动与调整大小」后长高）
  @ObservationIgnored var onResize: ((NSSize) -> Void)?
  /// 打开时的屏幕可见区（点开后最高长到哪）
  @ObservationIgnored private var available = NSSize(width: 1440, height: 900)
  /// 打开时的排版：搜索时面板大小、列数照它，不跟着结果变
  @ObservationIgnored private var opened = AppShortcutsLayout.make(
    groups: [], base: AppShortcutsLayout.minColumnWidth, available: NSSize(width: 1440, height: 900)
  )
  /// 每一行搜索用的字（折叠过的标题、子菜单、菜单名、拼音）：第一次搜时才算
  @ObservationIgnored private var searchKeys: [[Int]: SearchKey] = [:]

  var count: Int { groups.reduce(0) { $0 + $1.items.count } }

  /// 看得见的各行，按排的先后（↑↓ 走这个顺序）：收起的「移动与调整大小」那些不算
  var flat: [MenuShortcut] {
    layout.columns.joined().compactMap { line in
      if case .item(let group, let index, _) = line {
        item(group: group, index: index)
      } else {
        nil
      }
    }
  }

  /// 收起的不收：搜索、点开了的时候
  private var folds: Bool { query.isEmpty && !expanded }

  /// 看得见的第 group 组第 index 条（排版里的一行指回来）
  func item(group: Int, index: Int) -> MenuShortcut? {
    guard visible.indices.contains(group), visible[group].items.indices.contains(index) else {
      return nil
    }
    return visible[group].items[index]
  }

  /// 换上新读的（available：鼠标所在屏的可见区大小）
  func load(_ reading: MenuReading, name: String, icon: NSImage?, available: NSSize) {
    self.available = available
    appName = name
    self.icon = icon
    groups = Self.groups(reading.shortcuts)
    visible = groups
    finished = reading.finished
    unreadable = reading.unreadable
    expanded = false
    heldModifiers = []
    presentation += 1
    entering = true
    layout = AppShortcutsLayout.make(
      groups: Self.lines(groups, folding: true),
      base: AppShortcutsLayout.baseWidth(for: reading.shortcuts), available: available)
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
    relayout()
    selection = text.isEmpty ? nil : visible.first?.items.first?.id
  }

  /// 打开时的样子就用打开时排好的；搜索、点开了「移动与调整大小」时照打开时的大小和栏数重排
  private func relayout() {
    entering = false
    layout =
      folds
      ? opened
      : AppShortcutsLayout.fitting(
        groups: Self.lines(visible, folding: false), columns: opened.columns.count,
        base: opened.base, size: opened.size)
  }

  /// 点开收起的「移动与调整大小」（拍板 C2）
  /// 面板跟着长高（栏数、宽度照打开时的，最高到一屏放得下的），再放不下才竖着滚：大小不变的话多出来的十几行全在
  /// 各栏底下、滚动条又只在滚的时候出来，看不出下面还有（2026-11-20 评审）
  func expand() {
    expanded = true
    opened = AppShortcutsLayout.grown(
      groups: Self.lines(groups, folding: false), columns: opened.columns.count, base: opened.base,
      width: opened.size.width, available: available)
    relayout()
    onResize?(opened.size)
  }

  /// 这一行亮着：没按住别的修饰键；或者它的快捷键带着按住的那个键和另外按住的几个（拍板 F2，纯函数）
  static func lit(_ item: MenuShortcut, hold: String, held: Set<String>) -> Bool {
    guard !held.isEmpty else { return true }
    let (keys, key) = MenuKeys.split(String(item.keys.split(separator: " ").first ?? ""))
    var modifiers = Set(keys)
    // 菜单里「⌘?」「⌘{」这类只报打出来的字、不带 ⇧ 位，按的时候却按着 ⇧（同 candidates）。
    // ponytail：按美式键盘的这几个字认，别的键盘布局上要按 ⇧ 的字不一样；要准得按当前布局反查键码
    if shiftedCharacters.contains(key) { modifiers.insert("⇧") }
    return modifiers.contains(hold) && held.isSubset(of: modifiers)
  }

  /// 美式键盘上要按着 ⇧ 才打得出的字
  static let shiftedCharacters = Set(#"~!@#$%^&*()_+{}|:"<>?"#.map(String.init))

  /// ↑↓：在看得见的各行里挪（没选中时从第一行起）
  func move(_ step: Int) {
    let rows = flat
    guard !rows.isEmpty else { return }
    let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
    let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? 0
    selection = rows[next].id
    // 焦点一直在搜索框：说出选中的那一项和它的快捷键（A1）
    Island.announceSettled(rows[next].title, rows[next].keys)
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

  /// 一组里排进栏的各行（组名不算，排版时加；纯函数）：进了一个子菜单先起一行小标题（拍板 C1），子菜单里的项缩进；
  /// folding 时系统的「移动与调整大小」收成一行（拍板 C2）
  static func lines(_ groups: [Group], folding: Bool) -> [[AppShortcutsLayout.Line]] {
    groups.enumerated().map { group, content in
      var lines: [AppShortcutsLayout.Line] = []
      let items = content.items
      var index = 0
      while index < items.count {
        let path = items[index].path
        guard !path.isEmpty else {
          lines.append(.item(group: group, item: index, nested: false))
          index += 1
          continue
        }
        let run = items[index...].prefix { $0.path == path }.count
        if folding, isSystemTiling(items[index..<index + run]) {
          lines.append(.folded(group: group, item: index, count: run))
        } else {
          lines.append(.submenu(group: group, item: index))
          lines += (index..<index + run).map { .item(group: group, item: $0, nested: true) }
        }
        index += run
      }
      return lines
    }
  }

  /// 系统给每个 App 的窗口菜单加的「移动与调整大小」（左、右、上、下、四等分……）：按组合认、不认名字（哪种语言都行）——
  /// 一段子菜单里每条都是 🌐⌃ 开头、至少 4 条
  static func isSystemTiling(_ items: ArraySlice<MenuShortcut>) -> Bool {
    items.count >= 4 && items.allSatisfy { $0.keys.hasPrefix("🌐⌃") }
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

/// 面板的尺寸和各行怎么分栏（纯函数，单测）。不画卡片：组名、子菜单的小标题、快捷键都是一行，按先后一栏栏往下排，
/// 各栏差不多一样高；组排到栏底放不下就接到下一栏（顶上写「续」）
struct AppShortcutsLayout: Equatable {
  /// 栏里的一行
  enum Line: Hashable {
    /// 组名（顶层菜单）；continued：接着上一栏那一组往下（写「续」）
    case menu(group: Int, continued: Bool)
    /// 子菜单的小标题（写 item 那一条的 path）
    case submenu(group: Int, item: Int)
    /// 一条快捷键；nested：在子菜单里（缩进、带引导线）
    case item(group: Int, item: Int, nested: Bool)
    /// 收起来的系统子菜单「移动与调整大小」（从 item 那一条起 count 条，拍板 C2）
    case folded(group: Int, item: Int, count: Int)

    var group: Int {
      switch self {
      case .menu(let group, _), .submenu(let group, _), .item(let group, _, _),
        .folded(let group, _, _):
        group
      }
    }

    /// 占一行的内容（快捷键或收起的那一行）：拆栏时按它数「几条」
    var isRow: Bool {
      switch self {
      case .item, .folded: true
      case .menu, .submenu: false
      }
    }

    var isMenu: Bool {
      if case .menu = self { true } else { false }
    }

    var isItem: Bool {
      if case .item = self { true } else { false }
    }
  }

  /// 栏宽按这个 App 最长的一行量，夹在这两个数之间（拍板 B2）
  static let minColumnWidth: CGFloat = 210
  static let maxColumnWidth: CGFloat = 300
  /// 栏间距（中间一根发丝线）
  static let gap: CGFloat = 28
  static let padding: CGFloat = 16
  /// 顶上那一行（高 32）连同它下面的间距（拍板 E1）
  static let header: CGFloat = 46
  static let rowHeight: CGFloat = 22
  /// 组名上面空的（栏顶那个不空）
  static let groupGap: CGFloat = 8
  /// 子菜单里的项缩进
  static let indent: CGFloat = 12
  /// 主键那一格最窄多宽：主键在这一格里靠左，一栏里的主键对成一列（比它宽的 F12、空格这些往左挤）
  static let keySlot: CGFloat = 18
  /// 标题和快捷键之间至少空多少
  static let titleGap: CGFloat = 12
  /// 一条都没有 / 读不到时的大小
  static let emptySize = NSSize(width: 380, height: 210)
  /// 面板最窄多宽：顶上那一行（图标、名字、条数、搜索框）放得下（2026-11-17 评审）
  static let minWidth: CGFloat = 440

  let columns: [[Line]]
  /// 量出来的栏宽
  let base: CGFloat
  /// 最高那一栏的高
  let contentHeight: CGFloat
  let size: NSSize

  /// 放不下、要竖着滚
  var scrolls: Bool { contentHeight > size.height - Self.header - Self.padding * 2 + 0.5 }

  /// 画的时候每栏多宽：面板比各栏加起来宽（只有一栏被最窄宽度撑开，或搜索后栏少了）时把栏放宽铺开，最多 2 倍
  /// （行高定死，放宽不影响排版）
  var columnWidth: CGFloat {
    guard !columns.isEmpty else { return base }
    let count = CGFloat(columns.count)
    let room = (size.width - Self.padding * 2 - (count - 1) * Self.gap) / count
    return min(max(base, room), base * 2)
  }

  /// 一行占多高：组名不在栏顶时上面空 groupGap
  static func height(_ line: Line, top: Bool) -> CGFloat {
    line.isMenu && !top ? rowHeight + groupGap : rowHeight
  }

  /// 栏宽：量最长的一行（标题 + 快捷键），夹在 minColumnWidth…maxColumnWidth（拍板 B2）。量字用 AppKit 的字体尺寸，
  /// 不量 SwiftUI；🌐 🎤 按 15 估、画出来和量的差一两 pt，多留 10
  static func baseWidth(for items: [MenuShortcut]) -> CGFloat {
    let regular = NSFont.systemFont(ofSize: 13)
    let medium = NSFont.systemFont(ofSize: 13, weight: .medium)
    func width(_ text: String, _ font: NSFont) -> CGFloat {
      MenuKeys.symbols[text] != nil
        ? 15 : (text as NSString).size(withAttributes: [.font: font]).width
    }
    var widest: CGFloat = 0
    for item in items {
      let parts = item.keys.split(separator: " ").map { part in
        let (modifiers, key) = MenuKeys.split(String(part))
        return modifiers.reduce(0) { $0 + width($1, regular) + MenuKeys.spacing }
          + max(keySlot, width(key, medium))
      }
      let keys = parts.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * MenuKeys.partGap
      let title = width(item.displayTitle, regular) + (item.path.isEmpty ? 0 : indent)
      widest = max(widest, title + titleGap + keys)
    }
    return min(max(ceil(widest) + 10, minColumnWidth), maxColumnWidth)
  }

  /// groups：各组排进栏的行（不含组名，排的时候加）；base：栏宽；available：屏幕可见区。最宽占 90%、最高 80%（拍板 C1）；
  /// 栏数取放得下的最少栏（只有一栏、又有两个以上菜单时分两栏，免得一栏被撑宽、标题和快捷键隔得老远），
  /// 都放不下就最多栏、竖着滚
  static func make(groups: [[Line]], base: CGFloat, available: NSSize) -> AppShortcutsLayout {
    guard !groups.isEmpty else {
      return AppShortcutsLayout(columns: [], base: base, contentHeight: 0, size: emptySize)
    }
    let maxColumns = max(1, Int((available.width * 0.9 - padding * 2 + gap) / (base + gap)))
    let maxBody = Self.maxBody(available)
    var best = flow(groups, into: maxColumns)
    for count in 1..<maxColumns {
      let tried = flow(groups, into: count)
      if tried.height <= maxBody {
        best = count == 1 && groups.count > 1 ? flow(groups, into: 2) : tried
        break
      }
    }
    let count = CGFloat(best.columns.count)
    let width = max(minWidth, padding * 2 + count * base + (count - 1) * gap)
    let height = padding * 2 + header + min(best.height, maxBody)
    return AppShortcutsLayout(
      columns: best.columns, base: base, contentHeight: best.height,
      size: NSSize(width: width, height: height))
  }

  /// 内容最高多高：屏幕可见区高的 80% 减去四周和顶上一行（拍板 C1）
  static func maxBody(_ available: NSSize) -> CGFloat {
    max(rowHeight * 6, available.height * 0.8 - header - padding * 2)
  }

  /// 点开「移动与调整大小」后：栏数、宽度照打开时的，高度跟着内容长，最高到 maxBody（再放不下竖着滚）
  static func grown(
    groups: [[Line]], columns: Int, base: CGFloat, width: CGFloat, available: NSSize
  ) -> AppShortcutsLayout {
    let flowed = flow(groups, into: max(columns, 1))
    let height = padding * 2 + header + min(flowed.height, maxBody(available))
    return AppShortcutsLayout(
      columns: flowed.columns, base: base, contentHeight: flowed.height,
      size: NSSize(width: width, height: height))
  }

  /// 搜索时：大小、最多几栏照打开时的，对上的那些排进放得下的最少栏（面板不跟着结果变大变小）。不直接排满打开时的栏数：
  /// 那样几条结果会摊到每一栏、出只有 1 行的「续」（2026-11-20 评审）
  static func fitting(groups: [[Line]], columns: Int, base: CGFloat, size: NSSize)
    -> AppShortcutsLayout
  {
    guard !groups.isEmpty else {
      return AppShortcutsLayout(columns: [], base: base, contentHeight: 0, size: size)
    }
    let body = size.height - header - padding * 2
    let most = max(columns, 1)
    let flowed =
      (1..<most).lazy.map { flow(groups, into: $0) }.first { $0.height <= body + 0.5 }
      ?? flow(groups, into: most)
    return AppShortcutsLayout(
      columns: flowed.columns, base: base, contentHeight: flowed.height, size: size)
  }

  /// 按先后一栏栏往下排，排进最多 count 栏里最矮的样子（二分找每栏的上限，各栏就差不多一样高）。拍板 D1：
  /// 组排到栏底放不下就接到下一栏，下一栏顶上写组名「续」（接着的是子菜单里的项时，小标题也再写一遍）；
  /// 栏底不留光杆组名（组名下面不到 2 条就整个挪走），组尾不只剩 1 条（前面够 3 条时拉 1 条下去）；
  /// 子菜单的小标题不留在栏底
  static func flow(_ groups: [[Line]], into count: Int) -> (columns: [[Line]], height: CGFloat) {
    let lines = groups.enumerated().flatMap { group, content in
      [Line.menu(group: group, continued: false)] + content
    }
    func columnHeight(_ column: [Line]) -> CGFloat {
      column.enumerated().reduce(0) { $0 + height($1.element, top: $1.offset == 0) }
    }
    func fill(limit: CGFloat) -> [[Line]] {
      var pending = lines
      var columns: [[Line]] = []
      var current: [Line] = []
      var used: CGFloat = 0
      var index = 0
      while index < pending.count {
        let line = pending[index]
        let top = current.isEmpty
        guard top || used + height(line, top: false) <= limit else {
          var carry: [Line] = []
          let heading = current.lastIndex(where: \.isMenu)
          let after = heading.map { current[($0 + 1)...].count(where: \.isRow) } ?? .max
          let remaining =
            line.isMenu ? 2 : pending[index...].prefix { !$0.isMenu }.count(where: \.isRow)
          if remaining < 2, after >= 3 {
            // 组尾只剩 1 条：前面拉 1 条下去（连着它上面的小标题）
            while let last = current.popLast() {
              carry.insert(last, at: 0)
              if last.isRow { break }
            }
          } else if let heading, heading > 0, after < 2 || remaining < 2 {
            // 组名下面不到 2 条，或者前面匀不出 1 条给组尾：整段挪到下一栏
            carry = Array(current[heading...])
            current.removeSubrange(heading...)
          }
          while let last = current.last, case .submenu = last {
            carry.insert(current.removeLast(), at: 0)
          }
          // 接下去的那条在子菜单里时，它的小标题是这一栏里最后一个（拉下去的那几行还排在 pending 里 index 前面，
          // 别从 pending 找：会找到拉下去的那个小标题，同一栏里出两个一样的行；2026-11-20 评审）
          let lastSubmenu = current.last { if case .submenu = $0 { true } else { false } }
          columns.append(current)
          current = []
          used = 0
          let next = carry.first ?? line
          if !next.isMenu {
            current.append(.menu(group: next.group, continued: true))
            used = rowHeight
            if case .item(let group, _, true) = next, let submenu = lastSubmenu,
              submenu.group == group
            {
              current.append(submenu)
              used += rowHeight
            }
          }
          pending.insert(contentsOf: carry, at: index)
          continue
        }
        current.append(line)
        used += height(line, top: top)
        index += 1
      }
      if !current.isEmpty { columns.append(current) }
      return columns
    }
    // 下限 3 行：栏顶的「续」+ 小标题 + 一条放得下，每一栏都排进至少一条，一定排得完
    var low = rowHeight * 3
    var high = lines.reduce(0) { $0 + height($1, top: false) }
    for _ in 0..<24 where high - low > 0.5 {
      let middle = (low + high) / 2
      if fill(limit: middle).count <= count { high = middle } else { low = middle }
    }
    let columns = fill(limit: high)
    return (columns, columns.map(columnHeight).max() ?? 0)
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
              let layout = model.layout
              // 按位置认栏：搜索时栏里换内容，栏不重建
              ForEach(layout.columns.indices, id: \.self) { index in
                ColumnView(
                  lines: layout.columns[index], index: index, height: layout.contentHeight,
                  model: model
                )
                .frame(width: layout.columnWidth)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 每次弹出来各栏重建一遍、依次浮现（拍板 F1）；搜索、点开时同一批栏换内容，不重来
            .id(model.presentation)
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
    HStack(spacing: 10) {
      if let icon = model.icon {
        Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
      }
      Text(model.appName)
        .font(.system(size: 17, weight: .semibold))
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
    .frame(height: 32)
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
    .frame(minWidth: 120, maxWidth: 240, minHeight: 28, maxHeight: 28)
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

/// 一栏：组名、子菜单的小标题、一行行快捷键，从上往下
private struct ColumnView: View {
  let lines: [AppShortcutsLayout.Line]
  /// 第几栏：浮现时晚 index × 22 ms
  let index: Int
  /// 最高那一栏的高：栏左边那根线（第一栏没有）画这么长
  let height: CGFloat
  let model: AppShortcutsModel
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .topLeading) {
        // 栏间一根发丝线，在间距正中；挂在栏上，跟着栏一起浮现
        if index > 0 {
          Hairline(vertical: true)
            .frame(height: height)
            .offset(x: -AppShortcutsLayout.gap / 2)
        }
      }
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : 5)
      .onAppear {
        // 弹出来那一下（同 S4「键帽依次浮现」：snap、每个晚一点，全部在 0.22 s 内）；减弱动态效果时直接出现
        guard !shown else { return }
        let animation =
          reduceMotion || !model.entering
          ? nil : Style.Motion.snap.animation()?.delay(Double(index) * 0.022)
        withAnimation(animation) { shown = true }
      }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.element) { offset, line in
        switch line {
        case .menu(let group, let continued):
          if model.visible.indices.contains(group) {
            MenuHeading(title: model.visible[group].title, continued: continued)
              .padding(.top, offset == 0 ? 0 : AppShortcutsLayout.groupGap)
          }
        case .submenu(let group, let index):
          if let item = model.item(group: group, index: index) {
            SubmenuHeading(path: item.path)
          }
        case .item(let group, let index, let nested):
          if let item = model.item(group: group, index: index) {
            ShortcutRow(
              item: item, nested: nested, isSelected: model.selection == item.id,
              query: model.query,
              lit: AppShortcutsModel.lit(item, hold: model.holdSymbol, held: model.heldModifiers)
            ) {
              model.onPerform?(item)
            }
            .id(item.id)
          }
        case .folded(let group, let index, let count):
          if let item = model.item(group: group, index: index) {
            // 按着 ⌘ 又按住别的修饰键时，里面一条都不亮就跟着淡下去
            let items = model.visible[group].items
            let lit = items[(index..<index + count).clamped(to: items.indices)].contains {
              AppShortcutsModel.lit($0, hold: model.holdSymbol, held: model.heldModifiers)
            }
            FoldedRow(path: item.path, count: count, lit: lit, expand: model.expand)
          }
        }
      }
    }
  }
}

/// 组名：11 semibold tertiary（同启动器的分组标题）；接到下一栏的写「续」。菜单名是那个 App 的，原样显示
private struct MenuHeading: View {
  let title: String
  let continued: Bool

  var body: some View {
    (continued ? Text("\(title)（续）") : Text(verbatim: title))
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(height: AppShortcutsLayout.rowHeight, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

/// 子菜单的小标题（拍板 C1）：小箭头 + 子菜单名（多级用 › 连起来），12 medium secondary
private struct SubmenuHeading: View {
  let path: [String]

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(verbatim: path.joined(separator: " › "))
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(height: AppShortcutsLayout.rowHeight, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// 一行：标题（一行截断，末尾的「…」照菜单画），右边一串符号的快捷键；点它执行。子菜单里的缩进 12、左边一根引导线。
/// 悬停 / 选中是一块中性灰底（mac-whisker §3 状态），左右各探出 6 pt
private struct ShortcutRow: View {
  let item: MenuShortcut
  let nested: Bool
  let isSelected: Bool
  /// 搜索词：标题里命中的字铺黄底（拍板 E2，同剪贴板透镜）
  let query: String
  /// 按着 ⌘ 时又按住了别的修饰键、这一行不带它们：淡下去（拍板 F2）
  let lit: Bool
  let perform: () -> Void
  @State private var hovered = false

  var body: some View {
    // 标题和快捷键之间至少 titleGap：间距放在 Spacer 上（HStack 的 spacing 会在 Spacer 两边各算一次，就成了 24）
    HStack(spacing: 0) {
      Text(title)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: AppShortcutsLayout.titleGap)
      MenuKeys(keys: item.keys).fixedSize()
    }
    .padding(.leading, nested ? AppShortcutsLayout.indent : 0)
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
      .padding(.horizontal, -6)
    }
    .overlay(alignment: .leading) {
      // 子菜单的引导线：上下接着下一行，连成一根
      if nested {
        Hairline(vertical: true).frame(height: AppShortcutsLayout.rowHeight).padding(.leading, 4)
      }
    }
    .opacity(lit ? 1 : Style.disabledOpacity)
    .animation(.easeOut(duration: 0.12), value: lit)
    .contentShape(.rect)
    .onTapGesture(perform: perform)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { perform() }
  }

  private var title: AttributedString {
    var title = AttributedString(item.displayTitle)
    if !query.isEmpty { title.highlight(query) }
    return title
  }
}

/// 收起来的系统子菜单「移动与调整大小」（拍板 C2）：小箭头 + 子菜单名，右边「N 个」；点一下就地展开
private struct FoldedRow: View {
  let path: [String]
  let count: Int
  let lit: Bool
  let expand: () -> Void
  @State private var hovered = false

  var body: some View {
    let name = path.joined(separator: " › ")
    HStack(spacing: 4) {
      Image(systemName: "chevron.right")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.tertiary)
      Text(verbatim: name)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: AppShortcutsLayout.titleGap)
      Text("\(count) 个")
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .fixedSize()
    }
    .frame(height: AppShortcutsLayout.rowHeight)
    .background {
      ZStack {
        if hovered {
          RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous).fill(
            Style.hoverFill)
        }
        HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } }
      }
      .padding(.horizontal, -6)
    }
    .opacity(lit ? 1 : Style.disabledOpacity)
    .animation(.easeOut(duration: 0.12), value: lit)
    .contentShape(.rect)
    .onTapGesture(perform: expand)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("展开\(name)"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { expand() }
  }
}

/// 一串符号的快捷键（拍板 B1，同系统菜单）：修饰键次要色、主键主色 medium，主键在一格里靠左，一栏里的主键对成一列；
/// 🌐 🎤 画成系统符号（单色、跟着字色）；两段式的（⌘K ⌘S）两段间空 6
struct MenuKeys: View {
  let keys: String

  /// 修饰键之间
  static let spacing: CGFloat = 1.5
  /// 两段式的两段之间
  static let partGap: CGFloat = 6
  /// 画成系统符号的：存的写法不变（搜索、按组合执行、单测靠它），只换画法
  static let symbols = ["🌐": "globe", "🎤": "mic"]

  /// 「⌥⇧⌘V」→ ([⌥, ⇧, ⌘], V)；没有修饰键、或者整个都是修饰键（只有一个符号）时整个当主键（纯函数）
  static func split(_ combo: String) -> (modifiers: [String], key: String) {
    let modifiers = combo.prefix { "🌐⌃⌥⇧⌘".contains($0) }
    let key = combo.dropFirst(modifiers.count)
    guard !key.isEmpty else { return ([], combo) }
    return (modifiers.map(String.init), String(key))
  }

  var body: some View {
    HStack(spacing: Self.partGap) {
      let parts = keys.split(separator: " ").map(String.init)
      // 两段式的两段可能一样（⌘K ⌘K），按位置认
      ForEach(parts.indices, id: \.self) { index in
        let (modifiers, key) = Self.split(parts[index])
        HStack(spacing: Self.spacing) {
          ForEach(modifiers.indices, id: \.self) {
            glyph(modifiers[$0]).foregroundStyle(.secondary)
          }
          glyph(key)
            .fontWeight(.medium)
            .frame(minWidth: AppShortcutsLayout.keySlot, alignment: .leading)
        }
      }
    }
    .font(.system(size: 13))
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(keys)
  }

  @ViewBuilder private func glyph(_ text: String) -> some View {
    if let symbol = Self.symbols[text] {
      Image(systemName: symbol).imageScale(.small)
    } else {
      Text(verbatim: text)
    }
  }
}
